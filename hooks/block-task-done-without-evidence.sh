#!/bin/bash
# Hook: Block issue-tracker transitions to a "Done"-class state unless a verifiable artifact is present.
# Enforces: a ticket can't move to Done/Released/Shipped/Verified/Closed without proof — a merged PR
#           URL (with green CI), a 200-returning deploy URL, or an on-disk artifact.
# Trigger: PreToolUse on the tracker's issue-save tool. This example matches the Linear MCP tool
#          `mcp__claude_ai_Linear__save_issue`; adapt the matcher + field extraction for your tracker.
# Exit codes:
#   0 — allow (state not Done-class, or artifact verified)
#   2 — block (Done-class state, no verifiable artifact found)
#
# REFERENCE IMPLEMENTATION — adapt to your environment.
#
# Why this exists: issues get marked Done immediately after merge, before real verification. Text
# rules ("NEVER mark issues Done until verified") fail across model versions. This gate enforces it
# structurally.
#
# Artifact accepted (any ONE of these passes):
#   (a) PR URL: github.com/.*/pull/\d+ — validated via `gh pr view` (merged + green CI)
#   (b) Deploy URL: https?://... returning HTTP 200 within 5s
#   (c) Screenshot/file path: any \S+\.(png|jpg|jpeg|webp|html|json|log) that exists on disk
#
# Wiring (see hooks/settings.example.json): PreToolUse with matcher set to your tracker's issue-save
# tool name.
#
# Self-test:
#   printf '{"tool_name":"mcp__claude_ai_Linear__save_issue","tool_input":{"state":"Done","description":"no artifact here"}}' \
#     | bash block-task-done-without-evidence.sh
#   (should exit 2 and print a BLOCK message)
#
# Env vars honored:
#   AUTOPILOT_GATES_DIR   dir holding gate-log.sh  (default: $HOME/.autopilot/gates)

set -euo pipefail

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"

INPUT=$(cat)

# Defensive multi-path extraction — tracker MCP schemas are not guaranteed stable.
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
STATE=$(echo "$INPUT" | jq -r '
  .tool_input.state //
  .tool_input.status //
  .tool_input.params.state //
  .tool_input.params.status //
  empty
' 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

DESCRIPTION=$(echo "$INPUT" | jq -r '
  .tool_input.description //
  .tool_input.params.description //
  ""
' 2>/dev/null)

# Gate telemetry — never affects exit codes.
GLOG() { "$GATES_DIR/gate-log.sh" task-done-without-evidence PreToolUse-Tracker "$1" "$2" || true; }

# Fast path: if we can't read a state field, this is not a state mutation — allow.
if [ -z "$STATE" ]; then
  exit 0
fi

# Check if this is a Done-class state transition.
# Matches: done, released, shipped, verified, closed (case-insensitive, already lowercased above).
if ! echo "$STATE" | grep -qE '^(done|released|shipped|verified|closed)$'; then
  exit 0
fi

# We have a Done-class transition. Require a verifiable artifact.

_block() {
  GLOG catch "state=$STATE no verifiable artifact"
  echo "" >&2
  echo "BLOCK: issue transition to '${STATE}' requires a verifiable artifact." >&2
  echo "" >&2
  echo "Provide ONE of the following in the description field:" >&2
  echo "  (a) Merged PR URL:  https://github.com/<owner>/<repo>/pull/<N>" >&2
  echo "      (will validate merged status + green CI via gh pr view)" >&2
  echo "  (b) Deploy URL returning HTTP 200: https://your-app.example.com/health" >&2
  echo "  (c) Absolute path to an existing screenshot/log: /path/to/screen.png" >&2
  echo "" >&2
  echo "Current description (first 200 chars):" >&2
  echo "$DESCRIPTION" | head -c 200 >&2
  echo "" >&2
  echo "Prevents: premature Done before real verification." >&2
  exit 2
}

# Artifact check (a): GitHub PR URL
PR_URL=$(echo "$DESCRIPTION" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | head -1 || true)
if [ -n "$PR_URL" ]; then
  # Extract owner/repo and PR number
  PR_NUM=$(echo "$PR_URL" | grep -oE '/pull/[0-9]+$' | grep -oE '[0-9]+' || true)
  REPO=$(echo "$PR_URL" | grep -oE 'github\.com/[^/]+/[^/]+' | sed 's|github\.com/||' || true)
  if [ -n "$PR_NUM" ] && [ -n "$REPO" ]; then
    PR_STATE=$(gh pr view "$PR_NUM" -R "$REPO" --json state -q .state 2>/dev/null || echo "")
    if [ "$PR_STATE" = "MERGED" ]; then
      # Also verify CI was green on this PR's head SHA (mirrors block-unverified-merge.sh)
      HEAD_SHA=$(gh pr view "$PR_NUM" -R "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || echo "")
      if [ "${#HEAD_SHA}" -eq 40 ]; then
        RUNS_JSON=$(gh run list --commit "$HEAD_SHA" -R "$REPO" --limit 20 --json conclusion,status 2>/dev/null || echo "[]")
        TOTAL=$(echo "$RUNS_JSON" | jq 'length')
        SUCCESS=$(echo "$RUNS_JSON" | jq '[.[] | select(.conclusion == "success")] | length')
        COMPLETED=$(echo "$RUNS_JSON" | jq '[.[] | select(.status == "completed")] | length')
        # No CI configured = allow; all green = allow; otherwise fall through to block
        if [ "$TOTAL" -eq 0 ] || { [ "$COMPLETED" -eq "$TOTAL" ] && [ "$SUCCESS" -eq "$TOTAL" ]; }; then
          GLOG pass "merged PR #$PR_NUM CI green"
          exit 0
        fi
        GLOG catch "PR #$PR_NUM merged but CI not green"
        echo "BLOCK: PR #$PR_NUM is merged but CI is not all green (total=$TOTAL success=$SUCCESS completed=$COMPLETED)." >&2
        echo "Fix CI before marking this issue ${STATE}." >&2
        exit 2
      fi
      # SHA unresolvable — merged PR present, trust it (edge case)
      exit 0
    fi
    echo "BLOCK: PR URL found but PR #$PR_NUM is not merged (state=${PR_STATE:-unknown})." >&2
    exit 2
  fi
fi

# Artifact check (b): Deploy URL returning HTTP 200
DEPLOY_URL=$(echo "$DESCRIPTION" | grep -oE 'https?://[^[:space:]"]+' | grep -v 'github\.com' | head -1 || true)
if [ -n "$DEPLOY_URL" ]; then
  HTTP_CODE=$(curl -fsS -m 5 -o /dev/null -w "%{http_code}" "$DEPLOY_URL" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    GLOG pass "deploy url 200"
    exit 0
  fi
  GLOG catch "deploy url HTTP $HTTP_CODE"
  echo "BLOCK: Deploy URL $DEPLOY_URL returned HTTP $HTTP_CODE (need 200)." >&2
  exit 2
fi

# Artifact check (c): File path on disk
FILE_PATH=$(echo "$DESCRIPTION" | grep -oE '\S+\.(png|jpg|jpeg|webp|html|json|log)\b' | head -1 || true)
if [ -n "$FILE_PATH" ]; then
  if [ -f "$FILE_PATH" ]; then
    GLOG pass "artifact exists: $FILE_PATH"
    exit 0
  fi
  GLOG catch "artifact path missing: $FILE_PATH"
  echo "BLOCK: Screenshot/artifact path '$FILE_PATH' does not exist on disk." >&2
  echo "Prevents: a sub-agent reporting screenshots saved when the files were text-file fakes or 404s." >&2
  exit 2
fi

# No artifact found at all.
_block

# --- Self-test mode ---
if [[ "${1:-}" == "--self-test" ]]; then
  echo "[self-test] Run with piped input. Example:" >&2
  echo "  printf '{\"tool_name\":\"mcp__claude_ai_Linear__save_issue\",\"tool_input\":{\"state\":\"Done\",\"description\":\"no artifact\"}}' | bash $0" >&2
fi
