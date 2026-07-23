---
argument-hint: [--profile <name>] [--unit <id1>+<id2> | --ticket <id>]
description: Run one autopilot iteration against the given profile — pick the next ticket, ship to PR-ready, HOLD for human merge.
---

Install this as a Claude Code slash command (e.g. `~/.claude/commands/run-build.md`, or a project-scoped `.claude/commands/`). It is the entry point that loads the orchestrator with your profile.

**Resolve the profile.** Parse `$ARGUMENTS` for `--profile <name>`. Then:

1. Confirm `<autopilot-dir>/profiles/<name>.yml` exists (where `<autopilot-dir>` is wherever you cloned this repo). If it does not, STOP and report `[run-build] unknown profile: <name> — expected <autopilot-dir>/profiles/<name>.yml`. Do NOT fall back to a different profile and do NOT invent one.
2. Read that file's `target.repo_path` field.
3. `cd` to that path (expand `~`) so all relative paths resolve against the correct target repo.

**Operator unit selection (optional).** Also parse `$ARGUMENTS` for `--unit <prefix>-<id1>+<prefix>-<id2>[+…]` (an operator-directed themed bundle → ONE PR) or `--ticket <prefix>-<id>` (one explicit ticket). Whichever is present is honored by the orchestrator's §N2 over its rubric pick (absent → §N2 picks the next unblocked item by rubric).

Then read `<autopilot-dir>/ORCHESTRATOR-V2.md` in full and execute the **RUN-BUILD PROMPT** block (§4 onward) verbatim, with `<name>` as the active profile (phase N0 loads the profile and resolves every `{{profile.<dotted.key>}}` reference from it for the rest of the run). Treat `ORCHESTRATOR-V2.md` as your operating instructions for this iteration.

The orchestrator file lives in this framework repo; the run targets whichever product repo the active profile's `target.repo_path` names. Never assume the target; always resolve it from the active profile.

**Binding rules (see `ORCHESTRATOR-V2.md` §3 for the full list):**
- HOLD every PR for human merge — the engine does NOT `gh pr merge` and does NOT push to the default branch.
- HALT before any cloud-migration push, and before every other unconditional hard stop.
- Every sub-agent spawn MUST pin an explicit `model:` (the `block-unpinned-spawn.sh` hook rejects unpinned spawns).
- The orchestrator does NOT hand-write the target's product or CI code — it spawns an implementer. The `block-orchestrator-product-write.sh` hook enforces this once the run-active sentinel is armed.
- Each unit runs in its own git worktree; the main checkout is read-only for the run.
- No AI attribution on commits or PRs.
- Concurrency cap: max 3 parallel sub-agents.
- Any profile field prefixed `TODO:` blocks the phase that needs it — never guess a value.

Begin at N0 (mint run-id, arm sentinel, tracker probe) immediately.
