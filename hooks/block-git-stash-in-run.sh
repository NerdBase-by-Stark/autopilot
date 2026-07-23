#!/bin/bash
# Hook: Block `git stash` (mutating forms) while an autopilot run is active.
# Enforces: no mid-run stash, because refs/stash is repo-global and cross-contaminates worktrees.
# Trigger: PreToolUse on Bash — exit 2 blocks the tool call.
# Scope: SYSTEM-WIDE, but ARMED ONLY during an autopilot run (run-active sentinel present).
#        Outside a run, humans keep `git stash` — no friction.
#
# REFERENCE IMPLEMENTATION — adapt to your environment.
#
# Why:
# - `refs/stash` is REPO-GLOBAL, not per-worktree. During multi-worktree agent fan-out, a concurrent
#   `git stash` in one worktree (or in the main checkout) cross-contaminates every other worktree
#   sharing that repo (verified live incident). Use worktree-local `git diff > patch / checkout /
#   test / apply` instead.
# - Read-only `git stash list` / `git stash show` are harmless and stay allowed.
#
# Matching is anchored to a command position and tolerates `git -C <path> stash` and other global
# flags between `git` and `stash`.
#
# Env vars honored:
#   AUTOPILOT_GATES_DIR   dir holding the gate scripts  (default: $HOME/.autopilot/gates)

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

GLOG() { "$GATES_DIR/gate-log.sh" git-stash-in-run PreToolUse-Bash "$1" "$2" || true; }

# Fast path: no `stash` token at all -> not our concern.
echo "$CMD" | grep -q 'stash' || exit 0

# Is there a `git ... stash` at a command position? Allow flags/`-C <path>` between git and stash,
# but do not cross a command separator (; & | && ||).
if ! echo "$CMD" | grep -qE '(^|[;&|])[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?stash\b'; then
  exit 0
fi

# Read-only stash subcommands are always fine (list/show).
if echo "$CMD" | grep -qE 'stash[[:space:]]+(list|show)\b'; then
  exit 0
fi

# Mutating stash. Only enforce while an autopilot run is active (sentinel fresh).
if ! "$GATES_DIR/autopilot-run-active.sh" check; then
  # No active run — humans keep stash. Silent allow.
  exit 0
fi

RUN_ID=$("$GATES_DIR/autopilot-run-active.sh" run-id 2>/dev/null)
GLOG catch "git stash during active run ${RUN_ID:-?}"
echo "BLOCK: 'git stash' is forbidden during an active autopilot run (run_id=${RUN_ID:-?})." >&2
echo "" >&2
echo "refs/stash is repo-global — a stash here cross-contaminates every worktree sharing this" >&2
echo "repo (verified incident). Use a worktree-local patch instead:" >&2
echo "  git -C <worktree> diff > /tmp/wt.patch  # save" >&2
echo "  git -C <worktree> checkout -- .          # revert" >&2
echo "  git -C <worktree> apply /tmp/wt.patch    # restore" >&2
echo "(git stash list / show remain allowed. Outside a run, stash is unrestricted.)" >&2
exit 2
