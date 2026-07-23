#!/bin/bash
# Hook: Block MAIN-AGENT (orchestrator) Write/Edit to product code during an autopilot run.
# Enforces: the orchestrator ORCHESTRATES; it must not hand-write the target's product/CI code —
#           that comes from a spawned implementer agent.
# Trigger: PreToolUse on Write | Edit | NotebookEdit — exit 2 blocks the tool call.
# Scope: SYSTEM-WIDE, ARMED ONLY during an autopilot run OWNED BY THIS SESSION (run-active sentinel).
#
# REFERENCE IMPLEMENTATION — adapt to your environment.
#
# Why: the orchestrator hand-writing product code (a real observed incident: dozens of product files
# written from the main seat) defeats the whole spawn-and-verify model. Product code must come from a
# spawned implementer agent.
#
# HOW IT DISCRIMINATES (the load-bearing fact):
# - A SUBAGENT's tool call carries `agent_id` in the PreToolUse payload; the MAIN agent's own calls
#   do NOT. So: payload HAS agent_id => spawned agent => ALLOW (agents may write product code).
#   Payload LACKS agent_id => main/orchestrator => candidate for the ban.
#   (Use the PAYLOAD field, not a secondary telemetry DB's agent_id column — such a column can
#    mislabel subagents as `-main`. The payload field is the truth.)
#
# THREE HONEST LIMITS (do not overclaim this hook):
#  1. BASH-WRITE BYPASS: this sees Write/Edit/NotebookEdit only. `sed -i`, `tee`, heredocs,
#     `python -c` writing product files are invisible here. The end-of-run isolation audit (Stop
#     hook) is the named backstop for that class. This does NOT attempt a Bash-redirect regex ban
#     (rot-prone, high false-positive).
#  2. It "reduces", not "prevents", the hand-write class — a Bash-surface write still slips past to
#     the end-of-run audit.
#  3. ACTOR != ROLE: the discriminator is main-vs-spawned, not orchestrator-vs-implementer. It
#     constrains the intended party ONLY while the engine drives from the main seat. If a future
#     architecture puts the engine in a subagent seat, this hook silently stops constraining it —
#     revisit then.
#
# Env vars honored:
#   AUTOPILOT_GATES_DIR   dir holding the gate scripts  (default: $HOME/.autopilot/gates)

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"

INPUT=$(cat)

GLOG() { "$GATES_DIR/gate-log.sh" orchestrator-product-write "PreToolUse-$(echo "$INPUT" | jq -r '.tool_name // "?"' 2>/dev/null)" "$1" "$2" || true; }

# Spawned agent? Payload has agent_id -> allow (agents write product code by design).
if echo "$INPUT" | jq -e 'has("agent_id")' >/dev/null 2>&1; then
  exit 0
fi

# Main-agent write. Only enforce during an active autopilot run OWNED BY THIS SESSION.
# `check-owner` (not `check`) so a CONCURRENT unrelated session (e.g. a human's manual work on the
# same repo, or another worktree) is NOT gated by this run's sentinel — only the run's own
# orchestrator seat is.
if ! "$GATES_DIR/autopilot-run-active.sh" check-owner; then
  exit 0
fi

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
if [ -z "$FILE" ]; then
  # Unparsable target during a run — fail closed, but only for main-agent writes.
  GLOG catch "main-agent write with unresolvable file_path during run"
  echo "BLOCK: cannot resolve the write target's path during an active autopilot run." >&2
  echo "Product writes must come from a spawned agent; if this is a plan/state/doc write, retry" >&2
  echo "with an explicit file_path." >&2
  exit 2
fi

# Does FILE fall under a product glob? Globs are repo-relative dir prefixes (e.g. src/**).
# Match by dir-segment containment on the absolute path (over-match errs toward blocking a main-seat
# product write during a run — the safe direction; globs are profile-tunable).
MATCHED_GLOB=""
while IFS= read -r glob; do
  [ -n "$glob" ] || continue
  prefix=$(printf '%s' "$glob" | sed -E 's:/\*+$::; s:/+$::')   # src/** -> src ; a/b/** -> a/b
  [ -n "$prefix" ] || continue
  case "/$FILE/" in
    */"$prefix"/*) MATCHED_GLOB="$glob"; break ;;
  esac
done < <("$GATES_DIR/autopilot-run-active.sh" globs)

if [ -n "$MATCHED_GLOB" ]; then
  RUN_ID=$("$GATES_DIR/autopilot-run-active.sh" run-id 2>/dev/null)
  GLOG catch "orchestrator wrote product path ($MATCHED_GLOB): $FILE"
  echo "BLOCK: the orchestrator may not hand-write product code during an autopilot run." >&2
  echo "" >&2
  echo "  file: $FILE" >&2
  echo "  matched product glob: $MATCHED_GLOB (run_id=${RUN_ID:-?})" >&2
  echo "" >&2
  echo "Dispatch a spawned implementer agent (model pinned) to write this file. The orchestrator" >&2
  echo "writes plans/state/docs only — NOT CI config. (Spawned-agent writes to this same path are" >&2
  echo "allowed — the ban is on the main/orchestrator seat.)" >&2
  exit 2
fi

# Main-agent write to a non-product path (plan/state/doc) — allowed. Note CI config (.github/**,
# .gates.conf, package.json and the lockfile) are product globs and DO block here.
exit 0
