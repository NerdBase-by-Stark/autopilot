#!/usr/bin/env bash
# autopilot-run-active.sh — the run-active sentinel primitive.
#
# REFERENCE IMPLEMENTATION — adapt to your environment.
#
# A single shared answer to "is an autopilot run in flight right now, and what may it touch?"
# The run-scoped hooks gate on it so they DON'T fire during ordinary attended human sessions:
#   - block-orchestrator-product-write.sh : only bans main-seat product writes DURING a run
#   - block-git-stash-in-run.sh           : only bans git stash DURING a run
#   - the end-of-run audit Stop hook        : only runs the isolation/model sweep DURING a run
#
# The engine writes the sentinel at run start (Phase 0) and removes it at EXIT.
#
# ── LIVENESS MODEL ────────────────────────────────────────────────────────────────────────────
# A naive model that records pid=$PPID and gates `check` on `kill -0 $PPID` is fragile: $PPID at
# start time is the persistent agent-runtime process ONLY for an attended terminal launch. Under a
# background/daemon launch, $PPID is a per-tool-call transient wrapper that dies before the next
# call → `check` would return "dead" during a LIVE run → all run-scoped safety hooks + the Stop
# audit SILENTLY DISARM mid-run.
#
# Root-cause fix — a durable IDENTITY plus a topology-independent LIVENESS signal:
#   IDENTITY  = $CLAUDE_CODE_SESSION_ID (== the session/transcript UUID). Present in EVERY tool
#               call, stable for the whole session, unique per run. This is what makes a new run
#               MINT a fresh sentinel and never "reuse" an old one, and lets `check-owner` tell
#               "my run" from a concurrent/other session — regardless of process-tree shape.
#   LIVENESS  = the run's transcript-tree heartbeat: the newest mtime across
#               <projects-dir>/*/<sid>.jsonl AND its <sid>/subagents/*.jsonl. A live run appends
#               continuously (driver + subagents); a dead one goes stale. This is self-healing for
#               the write-gate: a PreToolUse write-hook fires AFTER the assistant's tool_use is
#               written to the transcript, so any write that needs gating is preceded by a
#               heartbeat refresh — a heartbeat lapse can never let an ungated write through.
#   pid       = best-effort persistent-runtime-ancestor pid, kept as a SECONDARY liveness proof
#               (exact for attended terminal runs) and for backward compatibility. Never the sole gate.
#   TTL       = started_at age (12h default) is the hard crash backstop.
#
# Sentinel file (default): $AUTOPILOT_STATE_DIR/run-active.json
#   { "run_id","session_id","started_at","mint_nonce","pid","owner_starttime","product_globs":[…] }
# Old-format sentinels (no session_id) degrade gracefully to the pid+TTL behaviour.
#
# Usage:
#   autopilot-run-active.sh start <run-id> [glob1,glob2,...]   # write sentinel (globs optional)
#   autopilot-run-active.sh stop                               # remove sentinel
#   autopilot-run-active.sh check                              # exit 0 if active+fresh+alive, 1 else
#   autopilot-run-active.sh check-owner                        # like check + THIS session owns it
#   autopilot-run-active.sh path | run-id | session-id | globs # introspection
#
# CONTRACT: `check`/`check-owner` NEVER print to stdout/stderr (hooks call them in a condition);
# they only set an exit code. Other subcommands may print. Nothing here mutates a repo.
#
# Env vars honored (override to relocate):
#   AUTOPILOT_STATE_DIR       state dir holding the sentinel  (default: $HOME/.autopilot/state)
#   AUTOPILOT_SENTINEL_PATH   full path to the sentinel file  (default: $AUTOPILOT_STATE_DIR/run-active.json)
#   AUTOPILOT_PROJECTS_DIR    agent-runtime transcripts dir   (default: $HOME/.claude/projects)
#   AUTOPILOT_RUN_TTL         hard crash-stale backstop, secs (default: 43200 == 12h)
#   AUTOPILOT_RUN_HEARTBEAT_TTL  transcript-quiet tolerance   (default: 1800 == 30m)
#   AUTOPILOT_RUN_CLOCK_SKEW  clock-skew tolerance, secs      (default: 300 == 5m)

set -u

SENTINEL="${AUTOPILOT_SENTINEL_PATH:-${AUTOPILOT_STATE_DIR:-$HOME/.autopilot/state}/run-active.json}"
PROJECTS_DIR="${AUTOPILOT_PROJECTS_DIR:-$HOME/.claude/projects}"
TTL_SECONDS="${AUTOPILOT_RUN_TTL:-43200}"              # 12h default; crash-stale hard backstop
HEARTBEAT_TTL="${AUTOPILOT_RUN_HEARTBEAT_TTL:-1800}"   # 30m default; transcript-quiet tolerance
CLOCK_SKEW="${AUTOPILOT_RUN_CLOCK_SKEW:-300}"          # 5m; a modestly-future started_at (NTP step
                                                        # back) must NOT read as stale
# Default product globs whose main-seat writes are banned mid-run: the target's product code (and
# its CI config) must come from a spawned agent, not hand-written by the orchestrator. CI-config +
# supply-chain paths are included so the orchestrator can't hand-write its own CI (false-green).
# These are EXAMPLES — the engine normally passes the real set from the active profile; tune to your
# stack (e.g. add your migrations dir).
DEFAULT_GLOBS='["src/**","e2e/**",".github/**",".gates.conf","package.json","package-lock.json"]'

cmd="${1:-}"

_now_epoch() { date -u +%s; }

_iso_to_epoch() { date -u -d "$1" +%s 2>/dev/null || true; }

_ppid_of()  { awk '/^PPid:/{print $2; exit}' "/proc/$1/status" 2>/dev/null; }
_comm_of()  { awk '/^Name:/{print $2; exit}' "/proc/$1/status" 2>/dev/null; }
# starttime (jiffies since boot, field 22 of /proc/<pid>/stat) — pid-recycle discriminator.
_starttime_of() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }

# Only accept a well-formed session id before it ever touches a find pattern. Charset alone is
# NOT enough: a degenerate-but-legal id like "-" or "a" becomes a `-path "*-*"` glob that matches
# EVERY project dir → fake box-wide liveness. Require the full UUID shape (36 chars, hex, 8-4-4-4-12)
# — which is exactly what $CLAUDE_CODE_SESSION_ID always is.
_valid_sid() {
  local s="$1"
  [ "${#s}" -eq 36 ] || return 1
  case "$s" in *[!a-fA-F0-9-]*) return 1;; esac
  [ "${s:8:1}" = "-" ] && [ "${s:13:1}" = "-" ] && [ "${s:18:1}" = "-" ] && [ "${s:23:1}" = "-" ]
}

# Highest (nearest-root) agent-runtime ancestor of THIS process. In a background launch the
# per-call transient wrappers sit LOW in the tree; the persistent session process sits higher — so
# the topmost runtime ancestor is the durable one. Falls back to $PPID if none is found.
_persistent_claude_pid() {
  local p=$$ best="" hop=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$hop" -lt 40 ]; do
    [ "$(_comm_of "$p")" = "claude" ] && best="$p"
    p=$(_ppid_of "$p"); hop=$((hop+1))
  done
  [ -n "$best" ] && printf '%s' "$best" || printf '%s' "$PPID"
}

# True (0) iff the run's transcript tree was appended within HEARTBEAT_TTL. Keyed by session id.
_heartbeat_fresh() {
  local sid="$1" newest now age
  _valid_sid "$sid" || return 1
  newest=$(find "$PROJECTS_DIR" -path "*$sid*" -name '*.jsonl' -printf '%T@\n' 2>/dev/null \
             | sort -rn | head -1)
  newest=${newest%.*}
  [ -n "$newest" ] || return 1
  now=$(_now_epoch); age=$(( now - newest ))
  # fresh = within TTL and not absurdly future (clock-skew guard)
  [ "$age" -lt "$HEARTBEAT_TTL" ] && [ "$age" -ge -30 ]
}

# True (0) iff THIS process descends from pid $1 (pure ancestry; relatedness guard).
_is_ancestor() {
  local target="$1" p=$$ hop=0
  [ -n "$target" ] && [ "$target" -gt 0 ] 2>/dev/null || return 1
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$hop" -lt 50 ]; do
    [ "$p" = "$target" ] && return 0
    p=$(_ppid_of "$p"); hop=$((hop+1))
  done
  return 1
}

# True (0) iff the recorded pid is a live agent-runtime that genuinely belongs to this run.
#   - New-format sentinel: a non-zero owner_starttime is the pid-recycle discriminator (must match).
#   - Legacy sentinel (no owner_starttime field, want_start=""): comm-alone is NOT enough (a FOREIGN
#     runtime process would satisfy it), so require the pid to be an ANCESTOR of the caller. That
#     preserves legacy liveness for the owning session while rejecting unrelated processes. `start`
#     records pid=0 whenever it cannot resolve a starttime, so a new-format sentinel never carries an
#     unguarded live pid.
_pid_alive() {
  local pid="$1" want_start="$2" have_start
  [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ "$(_comm_of "$pid")" = "claude" ] || return 1
  if [ -n "$want_start" ] && [ "$want_start" != "0" ]; then
    have_start=$(_starttime_of "$pid")
    [ -n "$have_start" ] && [ "$have_start" = "$want_start" ] || return 1
    return 0
  fi
  if [ "$want_start" = "0" ]; then return 1; fi   # new-format-but-unresolvable → don't trust the pid
  _is_ancestor "$pid"                              # legacy path: relatedness instead of starttime
}

# True (0) iff the sentinel exists AND started_at is within TTL. Echoes nothing.
_fresh() {
  local started_at started_epoch age
  [ -f "$SENTINEL" ] || return 1
  started_at=$(jq -r '.started_at // empty' "$SENTINEL" 2>/dev/null)
  [ -n "$started_at" ] || return 1
  started_epoch=$(_iso_to_epoch "$started_at")
  [ -n "$started_epoch" ] || return 1
  age=$(( $(_now_epoch) - started_epoch ))
  # Symmetric skew tolerance: a modestly-future started_at (clock stepped back mid-run) is fresh,
  # not stale. Still bounded by the 12h TTL on the forward side.
  [ "$age" -ge "-$CLOCK_SKEW" ] && [ "$age" -lt "$TTL_SECONDS" ]
}

# Shared liveness core used by check + check-owner. Exit 0 iff sentinel is fresh AND alive.
_is_active() {
  _fresh || return 1
  local sid pid ost
  sid=$(jq -r '.session_id // empty' "$SENTINEL" 2>/dev/null)
  pid=$(jq -r '.pid // empty'        "$SENTINEL" 2>/dev/null)
  ost=$(jq -r '.owner_starttime // empty' "$SENTINEL" 2>/dev/null)
  # Primary: session-keyed transcript heartbeat (topology-independent).
  if [ -n "$sid" ] && _heartbeat_fresh "$sid"; then return 0; fi
  # Secondary / legacy: a recorded pid that is still a live runtime (exact on terminal launches;
  # also the ONLY signal for old-format sentinels that predate session_id).
  if _pid_alive "$pid" "$ost"; then return 0; fi
  return 1
}

# True (0) iff THIS process belongs to the sentinel's owning session.
#   Primary : $CLAUDE_CODE_SESSION_ID == recorded session_id (exact, topology-independent).
#   Fallback: ancestry — THIS process descends from the recorded owner pid (for hook contexts that
#             may lack the env var; preserves the cross-session-clobber fix).
_is_owner_session() {
  local rec_sid="$1" rec_pid="$2" p=$$ hop=0
  if [ -n "$rec_sid" ] && _valid_sid "${CLAUDE_CODE_SESSION_ID:-}"; then
    [ "${CLAUDE_CODE_SESSION_ID:-}" = "$rec_sid" ] && return 0
    # env present but mismatched → a different session; do NOT fall through to ancestry.
    return 1
  fi
  # No usable env identity → ancestry check against the recorded owner pid.
  [ -n "$rec_pid" ] && [ "$rec_pid" -gt 0 ] 2>/dev/null || return 1
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$hop" -lt 50 ]; do
    [ "$p" = "$rec_pid" ] && return 0
    p=$(_ppid_of "$p"); hop=$((hop+1))
  done
  return 1
}

case "$cmd" in
  start)
    run_id="${2:-unknown}"
    globs_csv="${3:-}"
    mkdir -p "$(dirname "$SENTINEL")" 2>/dev/null
    if [ -n "$globs_csv" ]; then
      globs_json=$(printf '%s' "$globs_csv" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";""))')
    else
      globs_json="$DEFAULT_GLOBS"
    fi
    command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found — cannot mint sentinel" >&2; exit 3; }
    sid="${CLAUDE_CODE_SESSION_ID:-}"
    _valid_sid "$sid" || sid=""
    owner_pid=$(_persistent_claude_pid)
    owner_start=$(_starttime_of "$owner_pid")
    # A pid with no resolvable starttime has no recycle guard — record pid=0 so `check` never trusts
    # an unguarded pid. Liveness then rests on the session-keyed heartbeat.
    if [ -z "$owner_start" ] || [ "$owner_start" = "0" ]; then owner_pid=0; owner_start=0; fi
    nonce="$(_now_epoch)-$$-${RANDOM:-0}"
    jq -cn \
      --arg run_id "$run_id" \
      --arg session_id "$sid" \
      --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg mint_nonce "$nonce" \
      --argjson pid "${owner_pid:-0}" \
      --argjson owner_starttime "${owner_start:-0}" \
      --argjson globs "$globs_json" \
      '{run_id:$run_id, session_id:$session_id, started_at:$started_at, mint_nonce:$mint_nonce,
        pid:$pid, owner_starttime:$owner_starttime, product_globs:$globs}' \
      > "$SENTINEL"
    echo "run-active sentinel written: $SENTINEL (run_id=$run_id, session_id=${sid:-<none>}, pid=$owner_pid)"
    ;;

  stop)
    rm -f "$SENTINEL" 2>/dev/null
    echo "run-active sentinel cleared"
    ;;

  check)
    # Silent. Exit 0 iff sentinel exists AND fresh (<TTL) AND alive (heartbeat OR live-runtime pid).
    _is_active && exit 0 || exit 1
    ;;

  check-owner)
    # Silent. Like check, and additionally THIS session must own the run. Run-scoped Stop/write
    # hooks use this so a concurrent unrelated session cannot trip the run's gates.
    _is_active || exit 1
    rec_sid=$(jq -r '.session_id // empty' "$SENTINEL" 2>/dev/null)
    rec_pid=$(jq -r '.pid // empty'        "$SENTINEL" 2>/dev/null)
    _is_owner_session "$rec_sid" "$rec_pid" && exit 0 || exit 1
    ;;

  path)
    echo "$SENTINEL"
    ;;

  run-id)
    [ -f "$SENTINEL" ] && jq -r '.run_id // empty' "$SENTINEL" 2>/dev/null || true
    ;;

  session-id)
    [ -f "$SENTINEL" ] && jq -r '.session_id // empty' "$SENTINEL" 2>/dev/null || true
    ;;

  globs)
    [ -f "$SENTINEL" ] && jq -r '.product_globs[]? // empty' "$SENTINEL" 2>/dev/null || true
    ;;

  *)
    echo "usage: autopilot-run-active.sh {start <run-id> [globs_csv]|stop|check|check-owner|path|run-id|session-id|globs}" >&2
    exit 2
    ;;
esac
