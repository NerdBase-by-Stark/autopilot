#!/usr/bin/env bash
# gate-log.sh — shared gate telemetry helper.
#
# REFERENCE IMPLEMENTATION — adapt to your environment. This is the append-only
# telemetry sink every other gate/hook calls to record its pass/catch/error/
# false_positive verdicts. It is intentionally a plain JSONL file so it has zero
# external dependencies; swap the sink for a DB or a monitor if you want, but keep
# the contract below.
#
# Not itself a hook — it is invoked BY the gates and hooks (never wired directly).
#
# Usage: gate-log.sh <gate-name> <event> <verdict> [detail]
#   verdict: pass | catch | error | false_positive
# Appends one JSONL line to $AUTOPILOT_STATE_DIR/gate-log.jsonl.
#
# CONTRACT: never fails the caller, never writes to stdout/stderr — hook output
# channels are semantically live and exit codes gate real actions, so this helper
# must be invisible.
#
# Env vars honored (override to relocate):
#   AUTOPILOT_STATE_DIR   per-run state + telemetry log dir  (default: $HOME/.autopilot/state)

{
  GATE="${1:-unknown}"
  EVENT="${2:-unknown}"
  VERDICT="${3:-unknown}"
  DETAIL="${4:-}"
  DIR="${AUTOPILOT_STATE_DIR:-$HOME/.autopilot/state}"
  FILE="$DIR/gate-log.jsonl"
  REPO=""
  if command -v git >/dev/null 2>&1; then
    REPO=$(git rev-parse --show-toplevel 2>/dev/null | xargs -r basename 2>/dev/null) || REPO=""
  fi
  mkdir -p "$DIR" 2>/dev/null
  if command -v jq >/dev/null 2>&1; then
    jq -cn \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg gate "$GATE" --arg repo "$REPO" \
      --arg event "$EVENT" --arg verdict "$VERDICT" --arg detail "$DETAIL" \
      '{ts:$ts, gate:$gate, repo:$repo, event:$event, verdict:$verdict, detail:$detail}' \
      >> "$FILE" 2>/dev/null
  fi
} >/dev/null 2>&1 || true
exit 0
