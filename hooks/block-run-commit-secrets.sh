#!/bin/bash
# Hook: Block the AUTOPILOT RUN from committing secrets / secret-bearing files.
# Enforces: no credentials or secret-bearing files land in a commit made during a run.
# Trigger: PreToolUse on Bash — exit 2 blocks the tool call (the `git commit`).
# Scope: SYSTEM-WIDE, ARMED ONLY during an autopilot run OWNED BY THIS SESSION (check-owner).
#        A human's commits are NOT gated.
#
# REFERENCE IMPLEMENTATION — adapt to your environment.
#
# Why: if the target repo has no pre-commit secret scanner, a run committing a secret into the diff
# is prompt-only. This scans the STAGED diff on `git commit` for high-confidence secret markers +
# secret-bearing filenames and blocks the commit.
# HIGH-CONFIDENCE ONLY (private-key blocks, AWS access-key ids, GitHub/Slack tokens, .env/key files)
# to keep false positives near zero. HONEST LIMIT: not a full entropy scanner; a novel credential
# format can slip — the end-of-run audit + human review are the backstops.
#
# NOTE ON THE REGEXES BELOW: the strings like `AKIA...`, `gh[pousr]_...`, `xox[baprs]-...` are
# DETECTION PATTERNS (what a leaked credential looks like), NOT real credentials. Keep them intact —
# they are the value of this hook. Extend the set for your own providers as needed.
#
# Env vars honored:
#   AUTOPILOT_GATES_DIR   dir holding the gate scripts  (default: $HOME/.autopilot/gates)

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

GLOG() { "$GATES_DIR/gate-log.sh" run-commit-secrets PreToolUse-Bash "$1" "$2" || true; }

# Fast path: only a `git commit` at a command position concerns us.
echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*)git[[:space:]]+([^;&|]*[[:space:]])?commit\b' || exit 0

# Only during an owned run.
if ! "$GATES_DIR/autopilot-run-active.sh" check-owner; then
  exit 0
fi
RUN_ID=$("$GATES_DIR/autopilot-run-active.sh" run-id 2>/dev/null)

# Resolve the repo: `git -C <path>` in the command wins, else the session cwd, else $PWD.
REPO=$(echo "$CMD" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $3}')
[ -n "$REPO" ] || REPO="${CWD:-$PWD}"
git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1 || exit 0   # not a repo we can read -> don't false-block

NAMES=$(git -C "$REPO" diff --cached --name-only 2>/dev/null)
DIFF=$(git -C "$REPO" diff --cached 2>/dev/null)

# (1) Secret-bearing FILE names (allow .env.example / .sample / .template).
BADFILE=$(printf '%s\n' "$NAMES" \
  | grep -iE '(^|/)(\.env(\.[a-z0-9]+)?|id_rsa[^/]*|.*\.pem|.*\.key|credentials\.json|service[-_]account[^/]*\.json)$' \
  | grep -vEi '\.env\.(example|sample|template)$' | head -4)

# (2) Secret CONTENT markers in the staged diff (added lines).
BADCONTENT=$(printf '%s\n' "$DIFF" | grep -E '^\+' \
  | grep -EnA0 'BEGIN (RSA |EC |OPENSSH |PGP |DSA )?PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|xox[baprs]-[A-Za-z0-9]{10,}|-----BEGIN' \
  | head -3)

if [ -n "$BADFILE" ] || [ -n "$BADCONTENT" ]; then
  GLOG catch "run ${RUN_ID:-?} commit blocked — secret in staged diff"
  echo "BLOCK: this commit stages secrets — forbidden during an autopilot run (run_id=${RUN_ID:-?})." >&2
  echo "" >&2
  [ -n "$BADFILE" ] && { echo "  secret-bearing file(s) staged:" >&2; printf '    %s\n' $BADFILE >&2; }
  [ -n "$BADCONTENT" ] && { echo "  secret marker(s) in the staged diff (private key / token)." >&2; }
  echo "" >&2
  echo "Unstage them (git reset <file>), remove the secret, and use an env var / secrets manager." >&2
  echo "(Outside a run, commits are unrestricted. .env.example / .sample files are allowed.)" >&2
  exit 2
fi
exit 0
