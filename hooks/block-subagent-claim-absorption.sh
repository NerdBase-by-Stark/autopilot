#!/bin/bash
# Hook: Block the orchestrator from absorbing an unverified sub-agent completion claim.
# Enforces: a sub-agent saying "done/verified" while referencing an artifact that doesn't exist on
#           disk is treated as fabricated evidence, not a fact.
# Trigger: SubagentStop (falls back to Stop if SubagentStop is unavailable in this agent-runtime build).
# Exit codes:
#   0 — allow (no completion language + file references, or all referenced files exist)
#   2 — block (completion language present, referenced file path(s) do not exist on disk)
#
# REFERENCE IMPLEMENTATION — adapt to your environment.
#
# Why exit 2 (hard block) vs advisory: text rules don't stop the "just say done" shortcut; structural
# defenses do. A verified fabricated-screenshot incident (a sub-agent reported a PNG saved; the file
# was a renamed text file / 404) codified the rule: fabricated-artifact = HALT on first occurrence.
# An advisory here would be ignored the vast majority of the time. Hence a hard block.
#
# What this catches: a sub-agent message says "verified", "all green", "confirmed passing" AND
# references a file path like `/path/to/screenshot.png` — but that file doesn't exist. Classic shape:
# claim + path reference + missing artifact = fabricated evidence.
#
# Limitation: does not re-run tests. It only verifies that artifact files exist. The orchestrator
# still MUST re-run the test command independently.
#
# Wiring (see hooks/settings.example.json): register under SubagentStop (preferred), or under Stop if
# SubagentStop isn't available in your build.
#
# Self-test:
#   printf '{"last_assistant_message":"Tests verified and passing. Screenshot at /tmp/does-not-exist.png confirms green."}' \
#     | bash block-subagent-claim-absorption.sh
#   (should exit 2 with BLOCK message)
#
# Env vars honored:
#   AUTOPILOT_GATES_DIR   dir holding gate-log.sh  (default: $HOME/.autopilot/gates)

set -euo pipefail

GATES_DIR="${AUTOPILOT_GATES_DIR:-$HOME/.autopilot/gates}"

INPUT=$(cat)

# Extract the last assistant message.
MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)

if [ -z "$MSG" ]; then
  exit 0
fi

# Detect completion language. Case-insensitive.
COMPLETION_PATTERN='verified|confirmed|tested|passing|all green|fixed|complete|done|succeeded|successful'
if ! echo "$MSG" | grep -qiE "$COMPLETION_PATTERN"; then
  exit 0
fi

# Detect file path references with verifiable artifact extensions.
# Intentionally limited to binary/rendered output artifacts (screenshots, images). Source files
# (.md, .json, .html, .log, .sh, .ts, etc.) are excluded because they appear constantly in
# explanatory text referencing the codebase and produce pervasive false positives — the failure
# shape this guards is fabricated .png screenshots, not missing source docs. Extend this list only
# for output artifact types.
# Require path-like structure (contains "/" or starts with "~") and exclude tokens containing
# regex/enumeration metacharacters ( | ( ) [ ] { } * ). Real artifact claims are paths like
# /tmp/shot.png; bare extension mentions in prose ("extensions: png, jpg") and quoted regex patterns
# must not fire. Accepted narrowing: a pathless "screenshot.png" mention no longer triggers — genuine
# artifact claims include a path.
FILE_PATHS=$(echo "$MSG" | grep -oE '\S+\.(png|jpg|jpeg|webp)\b' | grep -E '(^~|/)' | grep -vE '[][|(){}*]' | sort -u || true)

if [ -z "$FILE_PATHS" ]; then
  # Completion claim without any file reference — advisory only (can't verify without a path). The
  # orchestrator is responsible for re-running tests independently.
  exit 0
fi

# We have completion language AND file references. Check every one.
MISSING_FILES=""
while IFS= read -r fpath; do
  # Strip surrounding punctuation (leading backticks/quotes, trailing ) . , " ')
  fpath=$(echo "$fpath" | sed "s/^['\"\`]//g; s/[).,\"'\`]$//g")
  # Expand leading ~ to $HOME
  fpath="${fpath/#\~/$HOME}"
  if [ ! -f "$fpath" ]; then
    MISSING_FILES="${MISSING_FILES}  ${fpath}\n"
  fi
done <<< "$FILE_PATHS"

if [ -z "$MISSING_FILES" ]; then
  # All referenced files exist. Allow — but warn that test re-run is still required.
  echo "[block-subagent-claim-absorption] All ${#FILE_PATHS} referenced artifact(s) exist on disk." >&2
  echo "  REMINDER: File existence != correct content. Orchestrator must independently re-run tests." >&2
  exit 0
fi

# One or more artifact files are missing — hard block.
"$GATES_DIR/gate-log.sh" subagent-claim-absorption SubagentStop catch "missing artifacts: $(printf '%b' "$MISSING_FILES" | head -3 | tr '\n' ' ')" || true
echo "" >&2
echo "BLOCK: Sub-agent claims completion but referenced artifact file(s) do not exist on disk." >&2
echo "" >&2
echo "Missing files:" >&2
printf "%b" "$MISSING_FILES" >&2
echo "" >&2
echo "Completion language detected:" >&2
echo "$MSG" | grep -iE "$COMPLETION_PATTERN" | head -3 >&2
echo "" >&2
echo "This matches the fabricated-evidence failure shape: sub-agent reports a screenshot/test saved;" >&2
echo "the files were fabricated (text files with .png extension, 404 pages, etc.)." >&2
echo "" >&2
echo "Resolution:" >&2
echo "  1. Have the sub-agent re-run and re-save the artifacts at the claimed paths." >&2
echo "  2. Orchestrator independently re-runs the test/check command." >&2
echo "  3. Do NOT absorb the sub-agent's completion claim until both pass." >&2
exit 2
