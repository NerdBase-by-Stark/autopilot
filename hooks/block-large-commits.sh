#!/bin/bash
# Hook: Block git commits with staged files >2MB.
# Enforces: no oversized binary/asset blobs land in a commit.
# Trigger: PreToolUse on Bash — exit 2 blocks the tool call.
#
# REFERENCE IMPLEMENTATION — adapt to your environment (e.g. tune the 2MB threshold).
#
# Env vars honored:
#   AUTOPILOT_GATES_DIR   dir holding gate-log.sh  (default: $HOME/.autopilot/gates)

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if echo "$CMD" | grep -q 'git commit'; then
  LARGE=$(git diff --cached --name-only 2>/dev/null | while read -r f; do
    [ -f "$f" ] && size=$(du -b "$f" | cut -f1) && [ "$size" -gt 2097152 ] && echo "  $f ($((size/1024/1024))MB)"
  done)
  if [ -n "$LARGE" ]; then
    "$GATES_DIR/gate-log.sh" large-commits PreToolUse-Bash catch "$(echo "$LARGE" | head -3 | tr '\n' ' ')" || true
    echo "BLOCK: staged file(s) exceed 2MB — commit aborted:" >&2
    echo "$LARGE" >&2
    exit 2
  fi
fi
exit 0
