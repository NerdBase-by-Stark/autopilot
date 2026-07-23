#!/usr/bin/env bash
# pre-pr-gate.sh — the pre-PR gate suite.
#
# REFERENCE IMPLEMENTATION — adapt to your environment.
#
# Not a hook itself — a runner you invoke (from the profile's pre_pr_gate command, or by hand)
# before opening a PR. Run from a repo root (or anywhere inside one — it cd's to the repo root via
# `git rev-parse --show-toplevel`). Reads the per-repo gate suite from `.gates.conf` (JSON, repo
# root), runs every check in order, and writes `.gate-evidence.json` (repo root) with the full
# result set. The PreToolUse hook `check-pr-evidence.sh` requires this evidence file — fresh,
# matching HEAD, all-green — before it will let `gh pr create` through, and it independently re-runs
# one check itself (anti-forgery) rather than trusting this file alone.
#
# .gates.conf format (JSON) — these commands are EXAMPLES; declare your own stack's checks:
# {
#   "checks": [
#     {"name": "tsc",       "cmd": "npx tsc -p tsconfig.json --noEmit",       "rederive": false},
#     {"name": "eslint",    "cmd": "npx eslint src/",                          "rederive": true},
#     {"name": "coderabbit","cmd": "coderabbit review --agent --base main",    "rederive": false}
#   ]
# }
# Exactly one check should carry "rederive": true — pick the fastest *reliable/deterministic* one (a
# pure static check, not a test suite with I/O) since check-pr-evidence.sh re-runs it live on every
# `gh pr create`. A check named "coderabbit" is special-cased below: it is skipped (not failed) if
# `coderabbit doctor` doesn't show it signed in, so an unauthenticated box doesn't hard-block every
# PR. (CodeRabbit is one optional AI code-review CLI; drop the check or swap the tool as you like.)
#
# Evidence file written (repo root): .gate-evidence.json
#   {head_sha, ts, results: [{check, cmd, exit, duration_s}], gate_version}
#
# Telemetry: logs via gate-log.sh. Degrades gracefully if that helper is missing — this script's own
# exit code and evidence file remain the source of truth either way.
#
# Exit: 0 if every non-skipped check passed, 1 otherwise (or on structural errors like a
# missing/invalid .gates.conf).
#
# Env vars honored (override to relocate):
#   AUTOPILOT_GATES_DIR   dir holding gate-log.sh  (default: $HOME/.autopilot/gates)

set -uo pipefail

GATE_VERSION="1.0.0"
GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "pre-pr-gate: not inside a git repository" >&2
  exit 1
fi
cd "$REPO_ROOT" || exit 1

CONF="$REPO_ROOT/.gates.conf"
if [[ ! -f "$CONF" ]]; then
  echo "pre-pr-gate: no .gates.conf found at $CONF — nothing to run." >&2
  echo "  See the format documented in this script's header." >&2
  exit 1
fi

if ! jq empty "$CONF" 2>/dev/null; then
  echo "pre-pr-gate: $CONF is not valid JSON" >&2
  exit 1
fi

NUM_CHECKS=$(jq '.checks | length' "$CONF" 2>/dev/null)
if [[ -z "$NUM_CHECKS" || "$NUM_CHECKS" -eq 0 ]]; then
  echo "pre-pr-gate: .gates.conf has zero checks defined" >&2
  exit 1
fi

HEAD_SHA="$(git rev-parse HEAD)"
REPO_NAME="$(basename "$REPO_ROOT")"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

RESULTS_JSON="[]"
OVERALL_RC=0
FAILED_NAMES=()

echo "pre-pr-gate: $REPO_NAME @ ${HEAD_SHA:0:8} — running $NUM_CHECKS check(s)"

for i in $(seq 0 $((NUM_CHECKS - 1))); do
  NAME=$(jq -r ".checks[$i].name" "$CONF")
  CMD=$(jq -r ".checks[$i].cmd" "$CONF")

  if [[ "$NAME" == "coderabbit" ]]; then
    if ! coderabbit doctor 2>/dev/null | grep -q "Signed in"; then
      echo
      echo "=== CHECK: $NAME — SKIPPED (coderabbit not authed; run 'coderabbit doctor') ==="
      RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --arg name "$NAME" --arg cmd "$CMD" \
        '. + [{"check": $name, "cmd": $cmd, "exit": null, "duration_s": 0, "skipped": true, "skip_reason": "coderabbit not authed"}]')
      continue
    fi
  fi

  echo
  echo "=== CHECK: $NAME ==="
  echo "\$ $CMD"
  START=$(date +%s.%N)
  bash -c "$CMD"
  RC=$?
  END=$(date +%s.%N)
  DUR=$(awk -v s="$START" -v e="$END" 'BEGIN{printf "%.2f", e-s}')

  if [[ $RC -eq 0 ]]; then
    echo "=== $NAME: PASS (${DUR}s) ==="
  else
    echo "=== $NAME: FAIL exit $RC (${DUR}s) ==="
    OVERALL_RC=1
    FAILED_NAMES+=("$NAME")
  fi

  RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --arg name "$NAME" --arg cmd "$CMD" --argjson rc "$RC" --argjson dur "$DUR" \
    '. + [{"check": $name, "cmd": $cmd, "exit": $rc, "duration_s": $dur}]')
done

EVIDENCE_FILE="$REPO_ROOT/.gate-evidence.json"
jq -n --arg head_sha "$HEAD_SHA" --arg ts "$TS" --argjson results "$RESULTS_JSON" --arg gate_version "$GATE_VERSION" \
  '{head_sha: $head_sha, ts: $ts, results: $results, gate_version: $gate_version}' > "$EVIDENCE_FILE"

echo
echo "pre-pr-gate: evidence written to $EVIDENCE_FILE"

# --- telemetry (degrade gracefully if absent) ---
GATE_LOG="$GATES_DIR/gate-log.sh"
VERDICT="pass"
[[ $OVERALL_RC -ne 0 ]] && VERDICT="catch"
DETAIL="head_sha=${HEAD_SHA:0:8} checks=$NUM_CHECKS"
[[ ${#FAILED_NAMES[@]} -gt 0 ]] && DETAIL="$DETAIL failed=$(IFS=,; echo "${FAILED_NAMES[*]}")"
if [[ -x "$GATE_LOG" ]]; then
  "$GATE_LOG" "pre-pr-gate" "gate-suite" "$VERDICT" "$DETAIL" || \
    echo "pre-pr-gate: gate-log.sh call failed (non-fatal — evidence file above is the record of truth)" >&2
else
  echo "pre-pr-gate: $GATE_LOG not present — skipping telemetry" >&2
fi

echo
echo "──────── pre-pr-gate summary ────────"
jq -r '.results[] | "\(.check): " + (if .skipped then "SKIPPED (" + .skip_reason + ")" elif .exit == 0 then "PASS" else "FAIL(\(.exit))" end) + "  [\(.duration_s)s]"' "$EVIDENCE_FILE"

if [[ $OVERALL_RC -eq 0 ]]; then
  echo "pre-pr-gate: ALL CHECKS PASSED"
else
  echo "pre-pr-gate: FAILURES PRESENT (${FAILED_NAMES[*]}) — do not open PR until fixed"
fi

exit $OVERALL_RC
