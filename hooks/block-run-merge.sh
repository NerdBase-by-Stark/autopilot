#!/bin/bash
# Hook: Block the AUTOPILOT RUN from MERGING a PR or PUSHING to the default branch.
# Enforces: the run HOLDS every PR for a human — it never merges its own work or pushes to default.
# Trigger: PreToolUse on Bash — exit 2 blocks the tool call.
# Scope: SYSTEM-WIDE, but ARMED ONLY during an autopilot run OWNED BY THIS SESSION (check-owner).
#        A CONCURRENT human session (e.g. a human merging the held PR from their own terminal) is
#        NOT gated — only the run's own seat.
#
# REFERENCE IMPLEMENTATION — adapt to your environment.
#
# Why: the engine must HOLD every PR for a human and never push to the default branch, but that is
# otherwise prompt-only. Nothing structural stops an overnight run from `gh pr merge`-ing its OWN
# green PR (a human wakes to already-merged, unreviewed code) or pushing straight to main.
# block-unverified-merge.sh only blocks RED-CI merges — a green SELF-merge was still allowed. This
# hook binds "HOLD for human" to enforcement.
# The legitimate PR-open flow is unaffected: `gh pr create`, `gh pr ready`, and
# `git push -u origin <feature-branch>` all pass. Only merge + push-to-default are blocked.
#
# Env vars honored:
#   AUTOPILOT_GATES_DIR   dir holding the gate scripts  (default: $HOME/.autopilot/gates)

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

GLOG() { "$GATES_DIR/gate-log.sh" run-merge-block PreToolUse-Bash "$1" "$2" || true; }

# Fast path: neither a PR merge nor a git push anywhere in the command -> not our concern.
echo "$CMD" | grep -qE 'gh[[:space:]]+pr[[:space:]]+merge|git[[:space:]]+([^;&|]*[[:space:]])?push' || exit 0

# Only enforce while an autopilot run OWNED BY THIS SESSION is active.
# `check-owner` (not `check`) so a concurrent unrelated/human session is never gated.
if ! "$GATES_DIR/autopilot-run-active.sh" check-owner; then
  exit 0
fi
RUN_ID=$("$GATES_DIR/autopilot-run-active.sh" run-id 2>/dev/null)

# (1) `gh pr merge` at a command position -> BLOCK unconditionally. The run HOLDS for a human, even
#     on green CI. Anchored to start-of-line or after a chain op so `echo "gh pr merge"` and
#     commit-message substrings don't false-positive.
if echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*)gh[[:space:]]+pr[[:space:]]+merge'; then
  GLOG catch "run ${RUN_ID:-?} attempted gh pr merge"
  echo "BLOCK: the autopilot run may NOT merge a PR — it HOLDS every PR for a human (run_id=${RUN_ID:-?})." >&2
  echo "" >&2
  echo "This is the hold-for-human rule, now structural. The PR stays OPEN for a human to review and" >&2
  echo "merge. A human in a SEPARATE session is not gated by this — only the run's seat." >&2
  exit 2
fi

# (2) `git push` targeting the DEFAULT branch (main/master) -> BLOCK. The run legitimately pushes its
#     FEATURE branch (`git push -u origin <feature-branch>`) — that is ALLOWED. Only an explicit
#     main/master target (as an arg or a refspec side) is blocked. `main` is bounded by whitespace/
#     colon/end so `feature-main-fix`, `src/main.ts`, `main-feature` do NOT trip it.
if echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*)git[[:space:]]+([^;&|]*[[:space:]])?push\b'; then
  if echo "$CMD" | grep -qE '[[:space:]:](main|master)([[:space:]:]|$)'; then
    GLOG catch "run ${RUN_ID:-?} attempted push to default branch"
    echo "BLOCK: the autopilot run may NOT push to the default branch (main/master) (run_id=${RUN_ID:-?})." >&2
    echo "" >&2
    echo "The run works on a feature branch and opens a PR; it never pushes default." >&2
    echo "Push the feature branch instead: git push -u origin <feature-branch>." >&2
    exit 2
  fi
fi

exit 0
