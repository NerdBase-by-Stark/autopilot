#!/bin/bash
# Hook: Block agent spawns / workflow scripts that don't pin a model explicitly.
# Enforces: every sub-agent spawn names its model — an unpinned spawn silently inherits the driver's
#           (expensive) model.
# Trigger: PreToolUse on Agent | Task | Workflow — exit 2 blocks the tool call.
# Scope: SYSTEM-WIDE, GLOBAL. The silent-model-inheritance footgun is model-agnostic, so the gate is
#        armed always (not only during a run).
#
# REFERENCE IMPLEMENTATION — adapt to your environment. Tool names (Agent/Task/Workflow) and the
# `fork` subagent_type are runtime-specific; adjust to your agent runtime.
#
# Why:
# - An Agent/Task spawn with no `model` param inherits the DRIVER's model silently, so mechanical work
#   ends up billed at premium rates.
# - The SAME footgun exists in the Workflow tool: an `agent()` call inside a script with no `model:`
#   inherits the driver's model.
#
# Coverage & honest limits:
# - Agent/Task: exact — reads tool_input.model. EXEMPTS subagent_type "fork" (a fork always inherits
#   its parent's model by design, so a missing model is legal there).
# - Workflow: BEST-EFFORT static lint of the script (inline `script` or on-disk `scriptPath`). Counts
#   `agent(` call sites vs `model:` pins; call sites > pins => block. Dynamic model strings and
#   meta-block `model:` keys can skew the count toward FALSE-NEGATIVE (lint passes when it shouldn't) —
#   that is the intended safe direction; the end-of-run model watchdog is the post-hoc backstop.
#
# Env vars honored:
#   AUTOPILOT_GATES_DIR   dir holding gate-log.sh  (default: $HOME/.autopilot/gates)

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

GLOG() { "$GATES_DIR/gate-log.sh" unpinned-spawn "PreToolUse-$TOOL" "$1" "$2" || true; }

case "$TOOL" in
  Agent|Task)
    SUBTYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)
    if [ "$SUBTYPE" = "fork" ]; then
      GLOG pass "fork spawn — model param exempt"
      exit 0
    fi
    MODEL=$(echo "$INPUT" | jq -r '.tool_input.model // empty' 2>/dev/null)
    if [ -z "$MODEL" ]; then
      GLOG catch "Agent/Task spawn with no model (subagent_type=${SUBTYPE:-none})"
      echo "BLOCK: this $TOOL spawn does not pin a model." >&2
      echo "" >&2
      echo "An unpinned spawn silently inherits the driver's model (a premium-token leak)." >&2
      echo "Add an explicit model, e.g.  model: \"sonnet\"  (or opus/haiku)." >&2
      echo "Routing norm: scout/lookup=haiku, implement/bulk=sonnet, architecture/net-new=opus," >&2
      echo "security-audit/arbitration=your strongest tier." >&2
      echo "(The 'fork' subagent_type is exempt — it legitimately inherits.)" >&2
      exit 2
    fi
    GLOG pass "pinned model=$MODEL"
    exit 0
    ;;

  Workflow)
    # Get the script text: inline .tool_input.script, else read .tool_input.scriptPath.
    SCRIPT=$(echo "$INPUT" | jq -r '.tool_input.script // empty' 2>/dev/null)
    if [ -z "$SCRIPT" ]; then
      SPATH=$(echo "$INPUT" | jq -r '.tool_input.scriptPath // empty' 2>/dev/null)
      if [ -n "$SPATH" ] && [ -f "$SPATH" ]; then
        SCRIPT=$(cat "$SPATH" 2>/dev/null)
      fi
    fi
    if [ -z "$SCRIPT" ]; then
      # Can't see the script (e.g. resumeFromRunId with neither field) — nothing to lint.
      GLOG pass "no script body to lint"
      exit 0
    fi
    # Strip // line comments so commented-out examples don't count.
    CLEAN=$(printf '%s' "$SCRIPT" | sed 's://.*$::')
    CALLS=$(printf '%s' "$CLEAN" | grep -oE '\bagent[[:space:]]*\(' | wc -l | tr -d ' ')
    PINS=$(printf '%s' "$CLEAN" | grep -oE '\bmodel[[:space:]]*:' | wc -l | tr -d ' ')
    if [ "${CALLS:-0}" -gt "${PINS:-0}" ]; then
      GLOG catch "workflow: $CALLS agent() calls but only $PINS model: pins"
      echo "BLOCK: this Workflow script has $CALLS agent() call site(s) but only $PINS model: pin(s)." >&2
      echo "" >&2
      echo "EVERY agent() call must pin model: explicitly — an unpinned agent() inherits the driver's" >&2
      echo "model (the same footgun as the Agent tool). Add a model: key to every agent() opts object," >&2
      echo "e.g. agent(prompt, {model:'sonnet', ...})." >&2
      echo "(Static best-effort lint: if this is a false positive from a helper/meta pattern," >&2
      echo " restructure so each agent() opts literal carries model: — the count must not go negative.)" >&2
      exit 2
    fi
    GLOG pass "workflow: $CALLS agent() calls, $PINS model: pins"
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
