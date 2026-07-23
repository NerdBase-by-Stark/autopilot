#!/bin/bash
# Hook: Block the AUTOPILOT RUN from MUTATING GitHub branch-protection or rulesets.
# Enforces: a run may not weaken the gates that police its own PR (drop a required check, delete a
#           merge-block ruleset). Gate changes are a human action.
# Trigger: PreToolUse on Bash — exit 2 blocks the tool call.
# Scope: SYSTEM-WIDE, ARMED ONLY during an autopilot run OWNED BY THIS SESSION (check-owner).
#        A human in their own session (managing rulesets) is NOT gated.
#
# REFERENCE IMPLEMENTATION — adapt to your environment.
#
# Why: the token a run holds can `gh api --method PUT …/branches/main/protection` or DELETE a ruleset
# to DROP the required CI check (or a review-bot merge-block ruleset), so a red/absent gate no longer
# blocks and the PR reads mergeable-green. This makes that structural.
# - Reads (GET) are harmless and stay allowed. Only WRITES to protection/rulesets are blocked.
# HONEST LIMIT: matches `gh api` REST calls; a raw `curl` to api.github.com or a GraphQL mutation
# would bypass this (same Bash-surface limit as the other command hooks) — the end-of-run audit +
# GitHub's own audit log are the backstops.
#
# Env vars honored:
#   AUTOPILOT_GATES_DIR   dir holding the gate scripts  (default: $HOME/.autopilot/gates)

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

GLOG() { "$GATES_DIR/gate-log.sh" run-ruleset-mutation PreToolUse-Bash "$1" "$2" || true; }

# Fast path: must be a gh api call that mentions protection or rulesets.
echo "$CMD" | grep -qE 'gh[[:space:]]+api' || exit 0
echo "$CMD" | grep -qE '(branches/[^[:space:]/]+/protection|/rulesets?(/|[[:space:]]|$))' || exit 0

# Only enforce during an owned run.
if ! "$GATES_DIR/autopilot-run-active.sh" check-owner; then
  exit 0
fi
RUN_ID=$("$GATES_DIR/autopilot-run-active.sh" run-id 2>/dev/null)

# Is it a WRITE? A non-GET --method / -X, OR field flags (-f/-F/--field/--raw-field/--input) which
# make `gh api` default to POST. Pure GETs (reads) pass.
IS_WRITE=0
echo "$CMD" | grep -qiE '(--method|-X)[[:space:]=]*(PUT|POST|PATCH|DELETE)' && IS_WRITE=1
echo "$CMD" | grep -qiE '(-X)(PUT|POST|PATCH|DELETE)' && IS_WRITE=1
echo "$CMD" | grep -qE '([[:space:]](-f|-F|--field|--raw-field|--input)[[:space:]=])' && IS_WRITE=1

if [ "$IS_WRITE" = 1 ]; then
  GLOG catch "run ${RUN_ID:-?} attempted branch-protection/ruleset mutation"
  echo "BLOCK: the autopilot run may NOT modify branch protection or rulesets (run_id=${RUN_ID:-?})." >&2
  echo "" >&2
  echo "Dropping/altering a required check or a review-bot merge-block ruleset would let the run's own" >&2
  echo "PR read mergeable while ungated. Gate changes are a human action." >&2
  echo "(Read-only 'gh api …' GETs remain allowed. Outside a run, this is unrestricted.)" >&2
  exit 2
fi
exit 0
