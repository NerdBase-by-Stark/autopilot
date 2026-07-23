#!/usr/bin/env bash
# autopilot-end-of-run-audit.sh — the end-of-run sweep.
#
# REFERENCE IMPLEMENTATION — adapt to your environment.
#
# Trigger: invoked at run close by a Stop hook (the operator wraps it so it fires only during an
# owned run and passes the session transcript path). Two deterministic checks over a completed run,
# one report, gate-logged:
#   PART A — MODEL WATCHDOG: every subagent's DELIVERED model(s) vs its REQUESTED model. Catches the
#            resume model-leak (a resumed continuation bills at the driver's rates, not the agent's
#            spawn model) — signature: a single agent-<id>.jsonl containing >1 delivered model family.
#   PART B — ISOLATION SWEEP: git status of the main checkout + each run worktree vs its expected
#            file set. Catches product code hand-written into the wrong tree / main checkout — the
#            class the Write/Edit hook cannot see when writes go via Bash (sed -i, tee, heredocs).
#
# Reads the FILESYSTEM only (transcripts + git), NEVER a secondary telemetry/monitoring store — an
# aggregate DB can silently drop subagent models or mislabel them, so the raw transcript tree is the
# only trustworthy source here.
#
# Usage:
#   autopilot-end-of-run-audit.sh <session-transcript-path> [target-repo-cwd]
#     - Model watchdog runs off the session's subagents/ dir (derived from the transcript path).
#     - Isolation sweep runs off $AUTOPILOT_STATE_DIR/run-worktrees.json if present (the engine
#       writes it: [{"path": "...", "expected_globs": ["..."]}]). If ABSENT, it falls back to a
#       `git status --porcelain` of [target-repo-cwd] (the session's cwd, passed by the Stop hook) —
#       the non-forgeable main-checkout signal. Only if neither a manifest NOR a resolvable repo cwd
#       is available is the sweep reported SKIPPED.
#
# Output: report to $AUTOPILOT_STATE_DIR/end-of-run-audit-<runid|ts>.md ; path echoed to stdout.
# Exit: 0 if clean or only-skipped ; 1 if any FINDING (leak/mismatch/stray-edit/unknown).
#       (The Stop hook decides whether a nonzero maps to a block.)
#
# DISCIPLINE RULE: this report — and any durable/"verified" copy of it preserved elsewhere (e.g.
# under state/<run-id>/) — is only ever REGENERATED wholesale by rerunning this script and
# overwriting the file. NEVER hand-edit a copy (sed/manual patch) to fix a stale or wrong value: a
# report titled "verified" that was hand-patched contradicts its own content even when the patched
# claim is true. If a number in it is wrong, rerun, don't patch it.
#
# Env vars honored (override to relocate):
#   AUTOPILOT_STATE_DIR   state dir for the manifest + report  (default: $HOME/.autopilot/state)
#   AUTOPILOT_GATES_DIR   dir holding the sibling gate scripts (default: $HOME/.autopilot/gates)

set -u

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"
STATE_DIR="${AUTOPILOT_STATE_DIR:-$HOME/.autopilot/state}"

TRANSCRIPT="${1:-}"
REPO_CWD="${2:-}"
WORKTREES_MANIFEST="$STATE_DIR/run-worktrees.json"
RUN_ID=$("$GATES_DIR/autopilot-run-active.sh" run-id 2>/dev/null)
STAMP="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
REPORT="$STATE_DIR/end-of-run-audit-$STAMP.md"
GLOG() { "$GATES_DIR/gate-log.sh" end-of-run-audit Stop "$1" "$2" || true; }

mkdir -p "$STATE_DIR" 2>/dev/null
FINDINGS=0

# family <str> -> haiku|sonnet|opus|UNKNOWN. Add your own higher-tier model aliases to the regex if
# you use custom names.
family() { echo "$1" | grep -oiE 'haiku|sonnet|opus' | head -1 | tr 'A-Z' 'a-z'; }

{
  echo "# Autopilot end-of-run audit"
  echo ""
  echo "- run_id: \`${RUN_ID:-unknown}\`"
  echo "- generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- transcript: \`${TRANSCRIPT:-none}\`"
  echo ""
  echo "## Part A — model watchdog"
  echo ""

  SUBDIR=""
  if [ -n "$TRANSCRIPT" ]; then
    SUBDIR="${TRANSCRIPT%.jsonl}/subagents"
  fi

  if [ -z "$SUBDIR" ] || [ ! -d "$SUBDIR" ]; then
    echo "_No subagents directory for this session — nothing to check._"
  else
    # Collect agent transcripts: direct subagents + workflow subagents.
    mapfile -t AGENTS < <(find "$SUBDIR" -maxdepth 1 -name 'agent-*.jsonl' 2>/dev/null; \
                          find "$SUBDIR/workflows" -path '*/agent-*.jsonl' 2>/dev/null)
    if [ "${#AGENTS[@]}" -eq 0 ]; then
      echo "_No agent transcripts found._"
    else
      echo "| agent | requested | delivered families | verdict |"
      echo "|---|---|---|---|"
      for f in "${AGENTS[@]}"; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        meta="${f%.jsonl}.meta.json"
        req_raw=""
        [ -f "$meta" ] && req_raw=$(jq -r '.model // empty' "$meta" 2>/dev/null)
        # delivered families (unique)
        delivered=$(jq -r 'select(.message.model) | .message.model' "$f" 2>/dev/null | sort -u)
        dfam=$(for d in $delivered; do family "$d"; done | sort -u | tr '\n' ',' | sed 's/,$//')
        dcount=$(echo "$dfam" | tr ',' '\n' | grep -c .)

        verdict="ok"
        if [ -z "$req_raw" ]; then
          reqf="REQUESTED-UNKNOWN"
          verdict="requested-unknown"
          FINDINGS=$((FINDINGS+1))
        else
          reqf=$(family "$req_raw"); [ -z "$reqf" ] && reqf="UNKNOWN"
        fi

        # >1 delivered family in one transcript = resume-leak signature.
        if [ "${dcount:-0}" -gt 1 ]; then
          verdict="RESUME-LEAK (mixed families)"
          FINDINGS=$((FINDINGS+1))
        elif [ "$reqf" != "REQUESTED-UNKNOWN" ] && [ "$reqf" != "UNKNOWN" ] && [ -n "$dfam" ] && [ "$dfam" != "$reqf" ]; then
          verdict="MISMATCH (req=$reqf del=$dfam)"
          FINDINGS=$((FINDINGS+1))
        elif echo "$dfam" | grep -q 'UNKNOWN' || [ "$reqf" = "UNKNOWN" ]; then
          verdict="unknown-family (inspect)"
          FINDINGS=$((FINDINGS+1))
        fi
        echo "| \`$base\` | ${req_raw:-—} | ${dfam:-—} | $verdict |"
      done
    fi
  fi

  echo ""
  echo "## Part B — isolation sweep"
  echo ""
  if [ ! -f "$WORKTREES_MANIFEST" ]; then
    # Fallback: no manifest → git status the target repo (non-forgeable main-checkout signal).
    SWEEP_REPO="$REPO_CWD"
    [ -z "$SWEEP_REPO" ] && SWEEP_REPO="$(pwd)"
    if git -C "$SWEEP_REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
      ROOT=$(git -C "$SWEEP_REPO" rev-parse --show-toplevel 2>/dev/null)
      dirty=$(git -C "$ROOT" status --porcelain 2>/dev/null | grep -v '^?? \.claude/worktrees/' || true)
      echo "_No \`run-worktrees.json\` manifest — fell back to \`git status\` of the target repo \`$ROOT\`._"
      echo ""
      if [ -z "$dirty" ]; then
        echo "- \`$ROOT\` — clean"
      else
        echo "- \`$ROOT\` — **CHANGES PRESENT** (uncommitted work at end of run — inspect for stray hand-writes):"
        echo '```'
        echo "$dirty"
        echo '```'
        FINDINGS=$((FINDINGS+1))
      fi
    else
      echo "_SKIPPED: no \`run-worktrees.json\` manifest and no resolvable git repo at \`$SWEEP_REPO\`._"
    fi
  else
    # For each declared worktree, git status --porcelain; any change outside expected globs = stray.
    n=$(jq 'length' "$WORKTREES_MANIFEST" 2>/dev/null || echo 0)
    if [ "${n:-0}" -eq 0 ]; then
      echo "_Manifest present but empty._"
    fi
    for i in $(seq 0 $(( n - 1 )) 2>/dev/null); do
      wt=$(jq -r ".[$i].path // empty" "$WORKTREES_MANIFEST" 2>/dev/null)
      [ -n "$wt" ] && [ -d "$wt" ] || { echo "- \`$wt\` — missing dir, skipped"; continue; }
      dirty=$(git -C "$wt" status --porcelain 2>/dev/null | grep -v '^?? \.claude/worktrees/' || true)
      if [ -z "$dirty" ]; then
        echo "- \`$wt\` — clean"
      else
        echo "- \`$wt\` — **CHANGES PRESENT:**"
        echo '```'
        echo "$dirty"
        echo '```'
        # NOTE: git status on the MAIN checkout catches main-checkout edits regardless of what the
        # (forgeable) expected set claims. Expected-glob filtering is a refinement; reporting raw
        # dirty state is the strong, non-forgeable signal.
        FINDINGS=$((FINDINGS+1))
      fi
    done
  fi

  echo ""
  echo "## Summary"
  echo ""
  echo "- findings: **$FINDINGS**"
  [ "$FINDINGS" -eq 0 ] && echo "- verdict: clean" || echo "- verdict: **$FINDINGS finding(s) — inspect above**"
} > "$REPORT" 2>&1

if [ "$FINDINGS" -gt 0 ]; then
  GLOG catch "end-of-run audit: $FINDINGS finding(s) — $REPORT"
else
  GLOG pass "end-of-run audit clean — $REPORT"
fi

echo "$REPORT"
[ "$FINDINGS" -eq 0 ]
