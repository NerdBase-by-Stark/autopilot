#!/usr/bin/env bash
# check-pr-evidence.sh — pre-PR gate hook.
#
# REFERENCE IMPLEMENTATION — adapt to your environment.
#
# Trigger: PreToolUse on Bash. Blocks `gh pr create` unless pre-pr-gate.sh has been run recently,
# cleanly, against the exact commit being PR'd.
#
# Design decision: on a single-user box an HMAC key is readable by the same agent it polices, so an
# HMAC over the evidence file buys nothing — the agent could just forge a file that also carries a
# valid signature. Forgery-resistance instead comes from RE-DERIVATION: this hook does not trust
# .gate-evidence.json alone. It independently re-runs one fast, deterministic check from .gates.conf
# (the one marked "rederive": true) right now, in the same process, and requires it to pass. An
# agent can Write a fake evidence file, but it cannot Write a fake exit code for a command this hook
# re-executes itself. (Sibling hook block-unverified-merge.sh uses the same pattern — re-derives via
# `gh api` instead of trusting a claim.)
#
# Detection: matches `gh pr create` as a real invocation (not a substring inside a commit message,
# echo, heredoc, etc.) after stripping, per shell segment (split on && ; | and newline): leading
# env-var assignments, sudo/env wrappers, and preceding `cd <dir>` segments in the same command
# chain (tracked in order, so `cd /path/to/repo && gh pr create ...` resolves evidence against
# /path/to/repo, not this hook's own cwd).
#
# Known residual gaps (accepted): `gh -R owner/repo pr create` (global -R flag BEFORE the subcommand)
# is not detected; `eval "$x"`, invocation from inside a script file, and command substitution that
# changes directory (`$(cd x; ...)`) are not tracked.
#
# Evidence requirements (ALL must hold, or this blocks):
#   1. .gate-evidence.json exists in the resolved repo root
#   2. head_sha in it == `git rev-parse HEAD` for that repo, right now
#   3. ts is within the last 30 minutes (small negative/future-clock tolerance of 120s to absorb
#      clock skew; larger negative = suspicious, fails closed)
#   4. every non-skipped result has exit == 0
#   5. RE-DERIVE: the .gates.conf check marked "rederive": true is re-run right now, from the
#      resolved repo root, and must exit 0
#
# Any failure -> exit 2 (block) with a message pointing at pre-pr-gate.sh. Unknown/error states
# (malformed JSON, missing .gates.conf, no rederive check defined, git failures, etc.) fail CLOSED ->
# exit 2 for matched commands. Non-matching commands -> exit 0 fast path.
#
# Env vars honored (override to relocate):
#   AUTOPILOT_GATES_DIR   dir holding pre-pr-gate.sh + gate-log.sh  (default: $HOME/.autopilot/gates)

set -uo pipefail

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Fast path: cheap substring pre-filter before paying for perl parsing below.
if [[ -z "$CMD" ]] || ! echo "$CMD" | grep -qE 'gh[[:space:]]+pr[[:space:]]+create'; then
  exit 0
fi

START_DIR=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
if [[ -z "$START_DIR" ]]; then
  START_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

block() {
  local msg="$1"
  echo "BLOCK: $msg" >&2
  echo "" >&2
  echo "Run: bash $GATES_DIR/pre-pr-gate.sh   (from the repo root you're about to PR from)" >&2
  echo "Then retry gh pr create once it prints ALL CHECKS PASSED." >&2
}

log_telemetry() {
  # $1=verdict $2=detail, run from $TARGET_DIR (falls back silently if unset)
  local verdict="$1" detail="$2"
  local gate_log="$GATES_DIR/gate-log.sh"
  [[ -x "$gate_log" ]] || return 0
  ( cd "${TARGET_DIR:-$START_DIR}" 2>/dev/null && "$gate_log" "check-pr-evidence" "gh-pr-create" "$verdict" "$detail" ) || true
}

# --- Precise detection + cd-chain tracking -------------------------------
# Walk shell segments in order, tracking cwd across `cd` segments (bash executes them sequentially in
# the same process). Prints the resolved target dir on stdout and exits 0 if a real `gh pr create`
# invocation is found; exits 1 if not (so the outer fast-path substring match was a false positive —
# e.g. a commit message merely mentioning the command).
TARGET_DIR=$(HOOK_START_DIR="$START_DIR" perl -e '
  local $/ = undef;
  my $cmd = <STDIN>;
  my $dir = $ENV{HOOK_START_DIR};
  for my $seg (split /(?:&&|\|\||;|\||\n)/, $cmd) {
      my $changed = 1;
      while ($changed) {
          $changed = 0;
          $changed = 1 if $seg =~ s/^\s+//;
          while ($seg =~ s/^([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|\x27[^\x27]*\x27|\S+)\s+//) {
              $changed = 1;
          }
          $changed = 1 if $seg =~ s/^(?:sudo|env)\s+//;
      }
      $seg =~ s/\s+$//;

      if ($seg =~ /^cd\s+(\S+)/) {
          my $target = $1;
          $target =~ s/^["\x27]|["\x27]$//g;
          $target =~ s/^~/$ENV{HOME}/;
          if ($target =~ m{^/}) { $dir = $target; }
          else { $dir = "$dir/$target"; }
          next;
      }

      if ($seg =~ /^gh\s+pr\s+create\b/) {
          print "$dir\n";
          exit 0;
      }
  }
  exit 1;
' <<< "$CMD")
DETECT_RC=$?

if [[ $DETECT_RC -ne 0 ]]; then
  # Substring matched somewhere (comment/string) but no real invocation as the leading command of
  # any segment — allow.
  exit 0
fi

if [[ -z "$TARGET_DIR" ]]; then
  block "cannot resolve target directory for gh pr create — failing closed"
  log_telemetry "error" "empty target dir resolved"
  exit 2
fi

REPO_ROOT=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null)
if [[ -z "$REPO_ROOT" ]]; then
  block "resolved directory '$TARGET_DIR' is not inside a git repository — failing closed"
  log_telemetry "error" "target dir not a git repo: $TARGET_DIR"
  exit 2
fi
TARGET_DIR="$REPO_ROOT"

CURRENT_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)
if [[ -z "$CURRENT_SHA" ]]; then
  block "cannot resolve current HEAD sha in $REPO_ROOT — failing closed"
  log_telemetry "error" "HEAD resolution failed in $REPO_ROOT"
  exit 2
fi

EVIDENCE_FILE="$REPO_ROOT/.gate-evidence.json"
if [[ ! -f "$EVIDENCE_FILE" ]]; then
  block "no .gate-evidence.json in $REPO_ROOT — pre-pr-gate.sh has not been run"
  log_telemetry "catch" "no evidence file in $REPO_ROOT"
  exit 2
fi

if ! jq empty "$EVIDENCE_FILE" 2>/dev/null; then
  block "$EVIDENCE_FILE is not valid JSON — failing closed"
  log_telemetry "error" "evidence file malformed JSON: $EVIDENCE_FILE"
  exit 2
fi

EV_SHA=$(jq -r '.head_sha // empty' "$EVIDENCE_FILE")
EV_TS=$(jq -r '.ts // empty' "$EVIDENCE_FILE")

if [[ -z "$EV_SHA" || -z "$EV_TS" ]]; then
  block "$EVIDENCE_FILE is missing head_sha or ts — failing closed"
  log_telemetry "error" "evidence file missing required fields"
  exit 2
fi

if [[ "$EV_SHA" != "$CURRENT_SHA" ]]; then
  block "evidence head_sha ($EV_SHA) != current HEAD ($CURRENT_SHA) in $REPO_ROOT — evidence is for a different commit"
  log_telemetry "catch" "stale sha: evidence=$EV_SHA current=$CURRENT_SHA"
  exit 2
fi

NOW_EPOCH=$(date -u +%s)
EV_EPOCH=$(date -u -d "$EV_TS" +%s 2>/dev/null)
if [[ -z "$EV_EPOCH" ]]; then
  block "cannot parse evidence timestamp '$EV_TS' — failing closed"
  log_telemetry "error" "unparseable ts: $EV_TS"
  exit 2
fi
AGE=$(( NOW_EPOCH - EV_EPOCH ))
if [[ $AGE -gt 1800 || $AGE -lt -120 ]]; then
  block "evidence is ${AGE}s old (must be <= 1800s, allowing 120s clock-skew tolerance) — stale, re-run pre-pr-gate.sh"
  log_telemetry "catch" "stale ts: age=${AGE}s"
  exit 2
fi

NUM_RESULTS=$(jq '.results | length' "$EVIDENCE_FILE" 2>/dev/null)
if [[ -z "$NUM_RESULTS" || "$NUM_RESULTS" -eq 0 ]]; then
  block "$EVIDENCE_FILE has zero results — failing closed"
  log_telemetry "error" "empty results array"
  exit 2
fi

FAILED_CHECKS=$(jq -r '[.results[] | select(.skipped != true) | select(.exit != 0) | .check] | join(",")' "$EVIDENCE_FILE" 2>/dev/null)
if [[ -n "$FAILED_CHECKS" ]]; then
  block "evidence shows failing check(s): $FAILED_CHECKS — fix and re-run pre-pr-gate.sh"
  log_telemetry "catch" "evidence has failing checks: $FAILED_CHECKS"
  exit 2
fi

# --- anti-forgery: re-derive one check live, right now --------------------
CONF="$REPO_ROOT/.gates.conf"
if [[ ! -f "$CONF" ]] || ! jq empty "$CONF" 2>/dev/null; then
  block "$CONF missing or invalid — cannot re-derive, failing closed"
  log_telemetry "error" "gates.conf missing/invalid for re-derive"
  exit 2
fi

RD_NAME=$(jq -r '[.checks[] | select(.rederive == true)][0].name // empty' "$CONF")
RD_CMD=$(jq -r '[.checks[] | select(.rederive == true)][0].cmd // empty' "$CONF")
if [[ -z "$RD_NAME" || -z "$RD_CMD" ]]; then
  block "$CONF has no check marked rederive:true — cannot re-derive, failing closed"
  log_telemetry "error" "no rederive check defined in gates.conf"
  exit 2
fi

if ! ( cd "$REPO_ROOT" && bash -c "$RD_CMD" ) >/tmp/check-pr-evidence-rederive.log 2>&1; then
  block "re-derive check '$RD_NAME' ($RD_CMD) FAILED just now in $REPO_ROOT — evidence file does not match live repo state. See /tmp/check-pr-evidence-rederive.log"
  log_telemetry "catch" "rederive check '$RD_NAME' failed live — evidence forged or stale despite matching sha/ts"
  exit 2
fi

log_telemetry "pass" "evidence valid, rederive '$RD_NAME' passed, sha=${CURRENT_SHA:0:8}"
exit 0
