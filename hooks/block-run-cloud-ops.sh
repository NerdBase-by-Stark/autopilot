#!/bin/bash
# Hook: Block the AUTOPILOT RUN from CLOUD DB migrations and DNS/zone changes.
# Enforces: a run may not migrate a production/cloud database or touch DNS/zone records — human-only.
# Trigger: PreToolUse on Bash — exit 2 blocks the tool call.
# Scope: SYSTEM-WIDE, ARMED ONLY during an autopilot run OWNED BY THIS SESSION (check-owner).
#        A human in their own session is NOT gated.
#
# REFERENCE IMPLEMENTATION — adapt to your environment. The command shapes below are EXAMPLES for a
# Supabase + Cloudflare stack; swap `supabase`/`safe-migrate`/`dns_records`/`/zones/` for whatever
# your migration + DNS tooling looks like.
#
# Why:
# - A cloud migration (e.g. `supabase db push --linked`, or a `safe-migrate --linked` wrapper)
#   mutates the LIVE cloud DB — an unconditional hard stop for an unattended run. DNS/zone records
#   must never be touched by an agent. Making these structural (not prompt-only) is the point.
# HONEST LIMIT: matches these command shapes on the Bash surface; a raw curl to a provider API would
# bypass it — the end-of-run audit is the backstop, and the local/dev migration path against the
# LOCAL stack stays allowed.
# NOTE: any `supabase db push` — even local, no --linked — is deliberately BLOCKED as a fail-safe
# (the harness never needs a local `db push`); this is stricter than "--linked only".
#
# Env vars honored:
#   AUTOPILOT_GATES_DIR   dir holding the gate scripts  (default: $HOME/.autopilot/gates)

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

GLOG() { "$GATES_DIR/gate-log.sh" run-cloud-ops PreToolUse-Bash "$1" "$2" || true; }

# Fast path: nothing cloud-migration / DNS-shaped -> not our concern.
echo "$CMD" | grep -qE 'supabase|safe-migrate|dns_records|/zones/' || exit 0

# Only enforce during an owned run.
if ! "$GATES_DIR/autopilot-run-active.sh" check-owner; then
  exit 0
fi
RUN_ID=$("$GATES_DIR/autopilot-run-active.sh" run-id 2>/dev/null)

REASON=""
# (1) Cloud DB migration — the unconditional hard stop.
if echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*)(supabase[[:space:]]+db[[:space:]]+push|supabase[[:space:]]+migration[[:space:]]+up|safe-migrate)\b'; then
  # A push/up to the LINKED (cloud) project, or safe-migrate --linked. NOTE: a bare
  # `supabase db push` is ALSO caught below even WITHOUT --linked (deliberate fail-safe);
  # `migration up --local` is what stays allowed.
  if echo "$CMD" | grep -qE '\-\-linked\b' || echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*)supabase[[:space:]]+db[[:space:]]+push([[:space:]]|$)'; then
    REASON="cloud DB migration (supabase db push / safe-migrate --linked)"
  fi
fi
# (2) DNS / zone record change.
if [ -z "$REASON" ] && echo "$CMD" | grep -qE 'dns_records|/zones/[^[:space:]/]+/dns'; then
  REASON="DNS/zone record change"
fi

if [ -n "$REASON" ]; then
  GLOG catch "run ${RUN_ID:-?} attempted $REASON"
  echo "BLOCK: the autopilot run may NOT perform: $REASON (run_id=${RUN_ID:-?})." >&2
  echo "" >&2
  echo "Cloud migration is an unconditional hard stop and DNS/zone records are never agent-touched." >&2
  echo "These are human actions. Local supabase start/reset and 'migration up --local' stay allowed," >&2
  echo "but a bare 'supabase db push' is blocked even without --linked (deliberate fail-safe)." >&2
  exit 2
fi
exit 0
