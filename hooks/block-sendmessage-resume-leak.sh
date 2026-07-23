#!/bin/bash
# Hook: Block a SendMessage resume that would run a cheap agent's continuation under a more
#       expensive driver.
# Enforces: fix-round loops use FRESH PINNED spawns, never resumes — a resumed continuation bills at
#           the DRIVER's rates, not the agent's spawn model.
# Trigger: PreToolUse on SendMessage — exit 2 blocks the tool call.
# Scope: SYSTEM-WIDE, ARMED ONLY during an autopilot run (run-active sentinel present). Outside a
#        run, humans resume agents freely.
#
# REFERENCE IMPLEMENTATION — adapt to your environment.
#
# Why: resuming a subagent via SendMessage runs its continuation on the CURRENT DRIVER model, not the
# agent's spawn model (verified: a resumed "cheap" agent billed a large token volume at the driver's
# premium rate). The discipline: fix-round loops use FRESH PINNED spawns, never resumes. This gate
# PREVENTS the leak; the end-of-run model watchdog DETECTS whatever slips past.
#
# Decision rule: block iff  rank(driver) > rank(target's spawn tier).  Ranks:
#   haiku=1 < sonnet=2 < opus=3.  A same-tier-or-cheaper driver resume is fine. If you use custom
#   higher-tier model aliases, add them to rank() with a higher number.
#
# FAIL-OPEN by design: this is a COST gate, not a safety gate. If either model can't be determined
# from disk, ALLOW (the watchdog still catches the leak post-hoc). Never block a legitimate resume on
# a data-read hiccup.
#
# Env vars honored:
#   AUTOPILOT_GATES_DIR   dir holding the gate scripts  (default: $HOME/.autopilot/gates)

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"

INPUT=$(cat)

# Only during an autopilot run.
"$GATES_DIR/autopilot-run-active.sh" check || exit 0

GLOG() { "$GATES_DIR/gate-log.sh" sendmessage-resume-leak PreToolUse-SendMessage "$1" "$2" || true; }

rank() { case "$(echo "$1" | grep -oiE 'haiku|sonnet|opus' | head -1 | tr 'A-Z' 'a-z')" in
  haiku) echo 1;; sonnet) echo 2;; opus) echo 3;; *) echo 0;; esac; }

TO=$(echo "$INPUT" | jq -r '.tool_input.to // empty' 2>/dev/null)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$TO" ] && [ -n "$TRANSCRIPT" ] || { GLOG pass "insufficient data (fail-open)"; exit 0; }

# Driver family = last model recorded in the sender's (driver's) transcript.
DRIVER_MODEL=$(jq -r 'select(.message.model) | .message.model' "$TRANSCRIPT" 2>/dev/null | tail -1)
DRIVER_RANK=$(rank "$DRIVER_MODEL")
[ "$DRIVER_RANK" -gt 0 ] || { GLOG pass "driver model unknown (fail-open)"; exit 0; }

# Target agent's spawn tier: prefer its meta.model; else the lowest-rank delivered family in its
# transcript (its original cheap tier — a prior leak only ADDS higher families).
SUBDIR="${TRANSCRIPT%.jsonl}/subagents"
TARGET_TS="$SUBDIR/agent-${TO}.jsonl"
TARGET_META="$SUBDIR/agent-${TO}.meta.json"
TARGET_MODEL=""
[ -f "$TARGET_META" ] && TARGET_MODEL=$(jq -r '.model // empty' "$TARGET_META" 2>/dev/null)
if [ -z "$TARGET_MODEL" ] && [ -f "$TARGET_TS" ]; then
  # lowest-rank delivered family present
  best=99
  for m in $(jq -r 'select(.message.model) | .message.model' "$TARGET_TS" 2>/dev/null | sort -u); do
    r=$(rank "$m"); [ "$r" -gt 0 ] && [ "$r" -lt "$best" ] && best=$r
  done
  [ "$best" -lt 99 ] && TARGET_RANK=$best || TARGET_RANK=0
else
  TARGET_RANK=$(rank "$TARGET_MODEL")
fi
[ "${TARGET_RANK:-0}" -gt 0 ] || { GLOG pass "target tier unknown (fail-open)"; exit 0; }

if [ "$DRIVER_RANK" -gt "$TARGET_RANK" ]; then
  GLOG catch "resume of tier-$TARGET_RANK agent $TO under tier-$DRIVER_RANK driver ($DRIVER_MODEL)"
  echo "BLOCK: this SendMessage resumes a cheaper agent under a more expensive driver." >&2
  echo "" >&2
  echo "  target agent: $TO (spawn tier rank $TARGET_RANK)" >&2
  echo "  current driver: $DRIVER_MODEL (rank $DRIVER_RANK)" >&2
  echo "" >&2
  echo "A resumed agent's continuation bills at the DRIVER's rates, not its spawn model's." >&2
  echo "Fix-round loops must use a FRESH PINNED agent spawn, never a resume. Spawn a new agent with" >&2
  echo "the intended model instead." >&2
  echo "(Outside an autopilot run this is unrestricted; same-tier-or-cheaper driver resumes pass.)" >&2
  exit 2
fi

GLOG pass "resume driver-rank $DRIVER_RANK <= target-rank $TARGET_RANK"
exit 0
