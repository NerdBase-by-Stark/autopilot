#!/bin/bash
# Hook: Block the AUTOPILOT RUN from CLOSING while its held PR is not one-click-mergeable.
# Enforces: a run may not EXIT leaving a draft PR, an unaddressed review-bot CHANGES_REQUESTED, or a
#           failed/skipped/pending required check — i.e. the held PR must be genuinely mergeable.
# Trigger: Stop — exit 2 blocks the stop (surfaces to the model); exit 0 allows it.
# Scope: ARMED ONLY during an autopilot run OWNED BY THIS SESSION (check-owner).
#
# REFERENCE IMPLEMENTATION — adapt to your environment. This example reconciles against CodeRabbit
# (a review bot); swap the review-author match if you use a different one, or drop that clause.
#
# Why: the run's "the PR is ready + green + review-reconciled" claim is otherwise PROMPT-only. A run
# could EXIT leaving a DRAFT PR, a review bot's CHANGES_REQUESTED unaddressed, or a failed/SKIPPED
# required check — handing a human a PR that is NOT one-click-mergeable. This gate independently
# queries the PR at run-close and blocks + flags if so.
#
# Where it gets the PR: the orchestrator writes state/<run-id>/held-pr.json = {number,repo} when it
# opens the PR. No file (run halted before opening a PR, or a non-PR exit) -> nothing to gate -> allow.
#
# Loop guard: block ONCE (surface loudly + write a morning-visible night-log flag), then allow on the
# stop-continuation (stop_hook_active) so the session can't hang. The night-log flag persists even if
# the model stops through the second time — so the morning always sees an un-mergeable PR.
#
# Env vars honored:
#   AUTOPILOT_GATES_DIR   dir holding the gate scripts   (default: $HOME/.autopilot/gates)
#   AUTOPILOT_STATE_DIR   per-run state (held-pr, night-log)  (default: $HOME/.autopilot/state)

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"
STATE_DIR="${AUTOPILOT_STATE_DIR:-$HOME/.autopilot/state}"

INPUT=$(cat)

# Not an owned autopilot run -> do nothing.
if ! "$GATES_DIR/autopilot-run-active.sh" check-owner; then
  exit 0
fi
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // empty' 2>/dev/null)
RUN_ID=$("$GATES_DIR/autopilot-run-active.sh" run-id 2>/dev/null)
GLOG() { "$GATES_DIR/gate-log.sh" complete-without-cr-reconcile Stop "$1" "$2" || true; }

PR_FILE="$STATE_DIR/${RUN_ID}/held-pr.json"
[ -f "$PR_FILE" ] || exit 0            # no PR opened this run -> nothing to gate

NUM=$(jq -r '.number // empty' "$PR_FILE" 2>/dev/null)
REPO=$(jq -r '.repo // empty'   "$PR_FILE" 2>/dev/null)
{ [ -n "$NUM" ] && [ -n "$REPO" ]; } || exit 0   # malformed record -> don't gate on our own bug

NIGHTLOG="$STATE_DIR/${RUN_ID}/night-log.md"
_flag() { [ -f "$NIGHTLOG" ] && printf '\n- **[LAYER: cr-pr-review] HELD PR #%s NOT ONE-CLICK-MERGEABLE at run-close:** %s\n' "$NUM" "$1" >> "$NIGHTLOG" 2>/dev/null || true; }
_block() {  # $1 = reason
  _flag "$1"; GLOG catch "run ${RUN_ID:-?} tried to close with un-mergeable PR #$NUM: $1"
  if [ "$STOP_ACTIVE" = "true" ]; then exit 0; fi   # already surfaced once -> allow (no hang)
  echo "BLOCK: the held PR #$NUM ($REPO) is NOT one-click-mergeable — do not close the run yet." >&2
  echo "" >&2
  echo "  $1" >&2
  echo "" >&2
  echo "Bring the PR to: NOT draft + full CI green (no SKIPPED required check) + review bot" >&2
  echo "reconciled (not CHANGES_REQUESTED). Then stop again." >&2
  exit 2
}

PRJSON=$(timeout 30 gh pr view "$NUM" -R "$REPO" --json isDraft,state,mergeStateStatus,statusCheckRollup,reviews 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$PRJSON" ]; then
  _block "could not verify PR state (gh pr view failed/timed out) — verify manually before closing"
fi
# Fail CLOSED on unparseable output. Any stdout that is not clean JSON (a gh update notice, a
# truncated body) must BLOCK — never be silently read as STATE="" and mistaken for a resolved PR,
# which would ALLOW a draft/SKIPPED PR through.
if ! echo "$PRJSON" | jq -e '.state' >/dev/null 2>&1; then
  _block "PR state unparseable (gh output not clean JSON) — verify manually before closing"
fi

STATE=$(echo "$PRJSON" | jq -r '.state // empty' 2>/dev/null)
# PR already resolved (merged/closed by a human) -> nothing to gate.
[ "$STATE" = "OPEN" ] || exit 0

# mergeStateStatus backstop — SAFE form. It catches merge conflict (DIRTY), out-of-date base
# (BEHIND), and required-check-missing/failing (BLOCKED) — states the per-name rollup below doesn't
# model. BUT it is computed LAZILY and can sit at UNKNOWN indefinitely for a held/untouched PR, so
# UNKNOWN is NOT trusted and NOT retried (retrying just burns time then cries wolf). UNKNOWN ALLOWs;
# the deterministic rollup checks below carry the load. MSS only BLOCKS on a state GitHub has
# definitively computed as un-mergeable (case at bottom).
MSS=$(echo "$PRJSON" | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null)

DRAFT=$(echo "$PRJSON" | jq -r '.isDraft // false' 2>/dev/null)
# Take the review bot's last DECISION (APPROVED/CHANGES_REQUESTED/DISMISSED), not its last review of
# any kind — a COMMENTED review posted AFTER a CHANGES_REQUESTED must not mask the un-dismissed block.
CR_STATE=$(echo "$PRJSON" | jq -r '[.reviews[]?|select((.author.login//"")|test("coderabbit";"i"))|select(.state|test("^(APPROVED|CHANGES_REQUESTED|DISMISSED)$"))]|sort_by(.submittedAt)|last|.state // empty' 2>/dev/null)
# Evaluate the EFFECTIVE (latest) run per check name. GitHub branch protection uses the most recent
# run per name, so a SUPERSEDED draft-lane run — SKIPPED, or CANCELLED via the workflow's
# cancel-in-progress concurrency — sitting next to the ready-lane SUCCESS must NOT trip the gate,
# else it false-alarms on EVERY run (every run leaves exactly that pair). group_by name -> keep the
# latest by startedAt (fallback completedAt) -> evaluate only that one.
# CheckRuns carry .conclusion; legacy StatusContexts (e.g. a required review-bot context) carry
# .state with NO .conclusion — so the FAILED and PENDING tests cover BOTH shapes.
FAILED=$(echo "$PRJSON" | jq -r '
  [ .statusCheckRollup[]? ] | group_by(.name // .context // "")
  | map( sort_by(.startedAt // .completedAt // "") | last )
  | [ .[] | select(
        ((.conclusion//"")|test("FAILURE|CANCELLED|TIMED_OUT|STARTUP_FAILURE|ACTION_REQUIRED"))
        or ((.conclusion==null) and ((.state//"")|test("^(FAILURE|ERROR)$")))
      ) | (.name//.context) ]
  | join(", ")' 2>/dev/null)
SKIPPED=$(echo "$PRJSON" | jq -r '
  [ .statusCheckRollup[]? ] | group_by(.name // .context // "")
  | map( sort_by(.startedAt // .completedAt // "") | last )
  | [ .[] | select((.conclusion//"")|test("^(SKIPPED|NEUTRAL)$")) | (.name//.context) ]
  | join(", ")' 2>/dev/null)
# PENDING: a required check still QUEUED/IN_PROGRESS (CheckRun, conclusion null) or a required
# status-context still PENDING/EXPECTED (review mid-flight) means the PR is NOT yet mergeable — the
# run closed before CI/review finished. A correctly-behaved run (watches CI to completion, waits for
# the review) leaves none, so this does not false-alarm on a clean run.
PENDING=$(echo "$PRJSON" | jq -r '
  [ .statusCheckRollup[]? ] | group_by(.name // .context // "")
  | map( sort_by(.startedAt // .completedAt // "") | last )
  | [ .[] | select(
        (((.status//"")|test("^(QUEUED|IN_PROGRESS|WAITING|PENDING|REQUESTED)$")) and (.conclusion==null))
        or ((.conclusion==null) and ((.state//"")|test("^(PENDING|EXPECTED)$")))
      ) | (.name//.context) ]
  | join(", ")' 2>/dev/null)

REASONS=""
[ "$DRAFT" = "true" ] && REASONS="${REASONS}PR is still a DRAFT (CI security-spine skipped + the review bot never reviews drafts). "
[ "$CR_STATE" = "CHANGES_REQUESTED" ] && REASONS="${REASONS}The review bot's latest review is CHANGES_REQUESTED — findings not reconciled. "
[ -n "$FAILED" ] && REASONS="${REASONS}CI check(s) not green: ${FAILED}. "
[ -n "$SKIPPED" ] && REASONS="${REASONS}Check(s) SKIPPED/NEUTRAL (a required check in either state is satisfied-but-ungated): ${SKIPPED}. "
[ -n "$PENDING" ] && REASONS="${REASONS}Check(s) still pending/in-progress at run-close (CI or review not finished): ${PENDING}. "
# MSS only BLOCKS on a definitively-un-mergeable computed state; UNKNOWN/CLEAN/UNSTABLE/HAS_HOOKS/DRAFT
# are not blocked here (DRAFT is caught above; UNKNOWN can't be trusted — the checks above carry it).
case "$MSS" in
  BLOCKED|DIRTY|BEHIND) REASONS="${REASONS}GitHub mergeStateStatus=${MSS} (merge blocked / conflict / behind base — not one-click-mergeable). " ;;
esac

if [ -n "$REASONS" ]; then
  _block "$REASONS"
fi

# Clean, mergeable, held -> allow the stop.
GLOG pass "held PR #$NUM one-click-mergeable at close"
exit 0
