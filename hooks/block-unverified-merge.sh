#!/bin/bash
# Hook: Block `gh pr merge <N>` if the PR's CI workflow runs are not all green.
# Enforces: no merge without verified green CI (independent of whether branch protection exists).
# Trigger: PreToolUse on Bash — exit 2 blocks the tool call.
# Scope: SYSTEM-WIDE (wire it under the PreToolUse > Bash matcher in settings.json).
#
# REFERENCE IMPLEMENTATION — adapt to your environment.
#
# Why this exists:
# - A repo may not have branch protection. Without enforcement, `gh pr merge` will silently merge a
#   PR with red/pending CI.
# - `gh pr checks <N>` requires statusCheckRollup scope on the token; if yours lacks it (GraphQL:
#   "Resource not accessible by personal access token"), it fails. So this reads the PR's head SHA
#   and queries `gh run list --commit <sha>` instead, which works with a more narrowly-scoped token.
#
# Env vars honored:
#   AUTOPILOT_GATES_DIR   dir holding gate-log.sh  (default: $HOME/.autopilot/gates)

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Gate telemetry — never affects exit codes.
GLOG() { "$GATES_DIR/gate-log.sh" unverified-merge PreToolUse-Bash "$1" "$2" || true; }

# Fast path: not a PR merge — exit silently. Anchor `gh pr merge` to a command position (start of
# line OR after chain operator ; && || |) so we don't false-positive on substrings inside
# `echo "gh pr merge"`, commit messages, comments, etc.
if ! echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*)gh[[:space:]]+pr[[:space:]]+merge'; then
  exit 0
fi

# Extract PR number — first integer after `gh pr merge`
PR=$(echo "$CMD" | grep -oE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' | head -1)

if [ -z "$PR" ]; then
  GLOG catch "implicit merge without PR number"
  echo "BLOCK: gh pr merge requires an explicit PR number — implicit merges of the current branch are not permitted (no way to verify CI)" >&2
  echo "  Use: gh pr merge <N> --squash --delete-branch" >&2
  exit 2
fi

# Honor explicit -R / --repo flag if present in the command
REPO_FLAG=""
if REPO_VAL=$(echo "$CMD" | grep -oE '(-R|--repo)[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $2}'); then
  if [ -n "$REPO_VAL" ]; then
    REPO_FLAG="-R $REPO_VAL"
  fi
fi

# Get PR's current head SHA (the commit CI ran against)
HEAD_SHA=$(gh pr view "$PR" $REPO_FLAG --json headRefOid -q .headRefOid 2>&1)
GH_RC=$?
if [ "$GH_RC" -ne 0 ] || [ -z "$HEAD_SHA" ] || [ "${#HEAD_SHA}" -ne 40 ]; then
  echo "BLOCK: cannot resolve PR #$PR head SHA (gh pr view rc=$GH_RC)" >&2
  echo "" >&2
  echo "$HEAD_SHA" | head -3 >&2
  echo "" >&2
  echo "Either the PR doesn't exist, the repo isn't accessible, or you need -R owner/repo." >&2
  exit 2
fi

# Query workflow runs for that exact SHA. Use commit filter so we get the runs CI fired for THIS PR
# head (not stale runs on the branch).
RUNS_JSON=$(gh run list --commit "$HEAD_SHA" $REPO_FLAG --limit 20 --json conclusion,status,name,createdAt 2>&1)
GH_RC=$?
if [ "$GH_RC" -ne 0 ]; then
  echo "BLOCK: cannot read workflow runs for PR #$PR head $HEAD_SHA (gh run list rc=$GH_RC)" >&2
  echo "$RUNS_JSON" | head -5 >&2
  exit 2
fi

# Count: total runs, completed runs, successful runs
TOTAL=$(echo "$RUNS_JSON" | jq 'length')
COMPLETED=$(echo "$RUNS_JSON" | jq '[.[] | select(.status == "completed")] | length')
SUCCESS=$(echo "$RUNS_JSON" | jq '[.[] | select(.conclusion == "success")] | length')

# No runs at all — repo has no CI configured for this branch. Allow but warn.
if [ "$TOTAL" -eq 0 ]; then
  GLOG pass "PR #$PR no CI configured — allowed with warning"
  echo "[block-unverified-merge] no workflow runs found for PR #$PR head $HEAD_SHA — repo has no CI configured for this commit. Allowing merge." >&2
  exit 0
fi

# Some runs still pending (status != completed)
if [ "$COMPLETED" -lt "$TOTAL" ]; then
  PENDING=$((TOTAL - COMPLETED))
  GLOG catch "PR #$PR merge attempted with $PENDING/$TOTAL runs pending"
  echo "BLOCK: gh pr merge $PR — CI not finished ($PENDING of $TOTAL workflow runs still pending)" >&2
  echo "" >&2
  echo "$RUNS_JSON" | jq -r '.[] | "  [\(.status)/\(.conclusion // "n/a")] \(.name) (\(.createdAt))"' >&2
  echo "" >&2
  echo "Wait for runs to complete, then re-attempt merge." >&2
  exit 2
fi

# All completed but not all successful (failures, cancellations, timeouts, etc.)
if [ "$SUCCESS" -lt "$COMPLETED" ]; then
  FAILED=$((COMPLETED - SUCCESS))
  GLOG catch "PR #$PR merge attempted with $FAILED/$COMPLETED runs not green"
  echo "BLOCK: gh pr merge $PR — CI is not green ($FAILED of $COMPLETED completed runs are not 'success')" >&2
  echo "" >&2
  echo "$RUNS_JSON" | jq -r '.[] | "  [\(.status)/\(.conclusion // "n/a")] \(.name) (\(.createdAt))"' >&2
  echo "" >&2
  echo "Fix the failing checks first, then re-run CI, then merge." >&2
  echo "If you must override (rare), use --admin AND state the reason in the next message." >&2
  exit 2
fi

# All runs completed AND all successful — allow merge
GLOG pass "PR #$PR CI all green ($SUCCESS/$TOTAL)"
exit 0
