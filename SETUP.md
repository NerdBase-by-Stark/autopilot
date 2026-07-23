# Setup — the full stack autopilot runs on

Autopilot is the **orchestration layer**: the prompt (`ORCHESTRATOR-V2.md`), the sub-agent briefs (`subagent-templates.md`, `grumpy-designer.md`), the entry command (`commands/run-build.md`), and the profile schema (`profiles/example.yml`). It sits on top of a supporting stack that **you provide**. This file names every piece so you don't have to guess.

Nothing here needs an HTTP proxy (`squid`), local model servers, a monitoring stack, or any particular host/hardware. Autopilot talks to your repo, your tracker, and your CI — that's the whole external surface.

---

## 1. Required to run at all

| Piece | What it is | Where it comes from |
|---|---|---|
| **Claude Code** | The agent runtime everything is built on (sub-agents, slash commands, hooks, MCP). | <https://www.anthropic.com/claude-code> |
| **The `/run-build` command** | The entry point — loads the orchestrator with your profile. | Ships here: `commands/run-build.md`. Install it as a Claude Code command (`~/.claude/commands/` or a project `.claude/commands/`). |
| **A profile** | Your target repo path, tracker coordinates, branch convention, and gate commands. | Copy `profiles/example.yml` → `profiles/<your-product>.yml` and fill it in. |
| **A target git repo with CI** | The product autopilot builds. The required CI checks are what a run watches to green before it holds the PR. | Yours. |
| **An issue tracker with an MCP integration** | Autopilot picks the next ticket and records outcomes through it. The templates assume **Linear** (via the Linear MCP server); adapt the tracker calls for another. | Your tracker + its MCP server. |
| **Your quality gates, as commands** | typecheck / lint / tests / migrations / e2e — whatever "done and correct" means for your codebase. | You declare these in the profile; the orchestrator runs and re-verifies them. |

With just the above, autopilot runs and its hard stops are enforced **by the prompt**. To make those stops *structural* (enforced by the runtime, not just instructions), add the layer below.

---

## 2. Recommended — the enforcement layer (what makes it safe to run unattended)

These **ship in this repo** — `gates/` (5 scripts) and `hooks/` (13 scripts) — and wire in as Claude Code hooks via [`hooks/settings.example.json`](./hooks/settings.example.json). Every box-specific path is a configurable env var with a sane default (`AUTOPILOT_GATES_DIR`, `AUTOPILOT_STATE_DIR`, `AUTOPILOT_DIR`), so you drop them in and point those at wherever you put them. You can also run *without* this layer and rely on the prompt-level stops — but wiring it is what makes the hard stops structural rather than advisory. Here is what each one enforces:

### Gate scripts (`gates/`)

| Script | Job |
|---|---|
| `autopilot-run-active.sh` | The **run sentinel**. `start`/`check`/`check-owner` — arms the run-scoped hooks for the session and holds the single-run mutex. Everything below is dormant until this is armed. |
| `gate-log.sh` | Append-only **telemetry** for each gate's pass/catch outcome. Degrades silently; never blocks the run. |
| `pre-pr-gate.sh` | The **pre-PR gate suite** — runs your gate commands (+ an optional CodeRabbit CLI pass) on the committed diff and writes an evidence file. |
| `check-pr-evidence.sh` | Independently **re-derives** the gate evidence on `gh pr create`, so the PR can't be opened on a stale or hand-written pass. |
| `autopilot-end-of-run-audit.sh` | The **Stop-hook sweep** — an end-of-run isolation + model-watchdog audit (did any write escape the worktree? did a pinned model silently downgrade?). |

### Hooks (`hooks/` — PreToolUse / Stop, registered via `settings.example.json`)

Each turns a rule the prompt states into a block the runtime enforces:

- `block-run-merge.sh` — the run may not `gh pr merge`.
- `block-run-cloud-ops.sh` — no production/cloud DB migration or DNS/zone change from a run.
- `block-run-commit-secrets.sh` — no committing secrets/credentials.
- `block-run-ruleset-mutation.sh` — no mutating branch-protection / required-check rulesets.
- `block-orchestrator-product-write.sh` — the orchestrator (main seat) may not hand-write product or CI code; it must spawn an implementer sub-agent.
- `block-unpinned-spawn.sh` — every sub-agent spawn must pin an explicit `model:`.
- `block-unverified-merge.sh` — no merge without verified green CI.
- `block-task-done-without-evidence.sh` — a tracker ticket can't move to Done without a verifiable artifact (a merged PR URL, a 200-returning deploy URL, or an on-disk log/screenshot).
- `block-complete-without-cr-reconcile.sh` — a **Stop** gate: the run may not close unless its held PR is genuinely one-click-mergeable and the review bot is reconciled.
- `block-git-stash-in-run.sh`, `block-sendmessage-resume-leak.sh`, `block-subagent-claim-absorption.sh`, `block-large-commits.sh` — smaller hygiene guards (no mid-run stash; no resuming a cheap agent under an expensive driver; don't absorb a sub-agent's unverified "done"; no oversized binary commits).

### Optional — the review "net"

A code-review bot on your PRs (e.g. [CodeRabbit](https://coderabbit.ai)) is the post-PR net that complements the pre-PR review "muscle." Autopilot reconciles its findings before holding the PR, but runs fine without one.

---

## 3. Wiring it up

1. Install Claude Code and clone this repo.
2. Install `commands/run-build.md` as a Claude Code slash command.
3. Set up your tracker's MCP server (Linear, or adapt).
4. Copy `profiles/example.yml` → `profiles/<your-product>.yml`; fill in the target repo, tracker, branch convention, and gate commands.
5. *(Recommended)* Wire the shipped gate + hook layer: put `gates/` + `hooks/` where you want them, set `AUTOPILOT_GATES_DIR` / `AUTOPILOT_STATE_DIR` to match, and register the hooks by merging [`hooks/settings.example.json`](./hooks/settings.example.json) into your Claude Code `settings.json`. Without this, autopilot still runs — the hard stops are just prompt-enforced, not structural.
6. From anywhere: `/run-build --profile <your-product>`.
7. In the morning, review the held PR and merge if you're happy.

---

## 4. Optional add-ons (box-specific — wire up for your environment)

None of these are required, and this repo deliberately does **not** ship them — they're specific to how you operate your box, not to the framework. But if you're standing autopilot up for real (especially if an **agent** is doing the setup), they're worth adding for your environment. The shipped core gives you the seams they attach to.

- **Run observability / metrics** — `gate-log.sh` (shipped) already writes an append-only JSONL of every gate's pass/catch outcome. Point a dashboard or metrics scraper at that file, or swap its sink for your store.
- **Alerting on run failure** — fire a notification when a run HALTs, holds a not-one-click-mergeable PR, or the end-of-run audit finds something. Wire whatever your environment uses — Alertmanager + a chat webhook, Slack, PagerDuty, or email.
- **A watchdog sweep** — a periodic job that catches a run that stalled, ran long, or left stray worktrees, and reports or cleans up. Pairs with `autopilot-end-of-run-audit.sh`.
- **State backup + restore-verify** — the run state under `AUTOPILOT_STATE_DIR` (specs, ledgers, logs, held-PR pointers) is worth backing up; a restore-verify step confirms a backup is actually usable.
- **Heavy-job capping** — if your gates spawn heavy local work (big test matrices, local model calls), cap them (cgroups / `systemd-run` / your scheduler) so a run can't saturate the box.

Each is a few lines against your own infrastructure. An agent implementing autopilot should treat these as the "make it production-grade for this box" checklist, separate from the framework itself.

## What autopilot does NOT need

To **run**, autopilot needs nothing beyond §1 (and, for the structural guarantees, §2). It does **not** require an HTTP proxy (`squid`), local model servers (Ollama etc.), or any specific hardware — those are incidental to the author's box. The §4 items are optional operational polish, not dependencies.
