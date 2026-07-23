# Autopilot

**An opinionated overnight orchestrator that drives a coding agent from _"ticket on the board"_ to _"pull request open, waiting for a human to merge"_ — with real quality gates, layered review, and a hard rule that it never merges its own work.**

Autopilot is a thin control layer on top of [Claude Code](https://www.anthropic.com/claude-code). You point it at a product repo and an issue tracker; it picks the next unblocked ticket, writes a spec, implements it in an isolated git worktree, runs _your_ quality gates, reviews the diff from several independent angles, opens a pull request — and then **stops**, holding for a human to review and merge.

It is **not** a general-purpose agent framework. It is one specific, load-bearing workflow: **build one unit of work, prove it, hand it over.**

---

## What it does

```
ticket → spec → isolate → implement → verify → review → PR → HOLD for human
```

1. **Pick** — the next unblocked ticket from your tracker (or a themed bundle of related tickets → one PR).
2. **Spec** — a binding spec is written and reviewed _before_ any code is touched.
3. **Isolate** — the unit runs in its own git worktree; your working copy is never touched.
4. **Implement** — spawned implementer agents write the code. The orchestrator itself never hand-writes product code.
5. **Verify** — your real gates run (typecheck, lint, unit tests, migrations, end-to-end) — and are **re-run by the orchestrator itself**, never taken on a sub-agent's word.
6. **Review — muscle before net** — the verified diff gets a strong, independent pre-PR review pass (the _muscle_) that must clear before the PR exists; a code-review bot (e.g. CodeRabbit) then reviews the opened PR (the _net_). Findings are recorded and dispositioned in an auditable ledger.
7. **Hold** — the PR is opened, marked ready, CI is watched to green, and then it **waits for you**. Autopilot does not merge, does not push to your default branch, and does not touch production.

---

## Why it's different

- **It never merges.** Every PR is held for a human. Merging, pushing to the default branch, and running production/cloud migrations are **hard stops** the engine cannot cross.
- **Sub-agent claims are hypotheses, not facts.** The orchestrator independently re-runs every gate a sub-agent says it passed. A sub-agent reporting "verified" is not evidence — a re-run is. Screenshots and logs are validated, not trusted.
- **Muscle before net.** The strongest review runs _before_ the PR is opened, so a serious problem is caught by the muscle — not left for the review bot, or for you, to find at merge time.
- **Worktree-native isolation.** Each unit runs in its own git worktree off a fresh base. Background and foreground runs behave identically, and your main checkout stays read-only for the run — your in-progress work is never disturbed.
- **Honesty over green.** It flags what it could not verify, records what it deliberately deferred, and never dresses a guess as a fact. A PR that isn't genuinely one-click-mergeable is held _and said so_, loudly, rather than closed quietly.
- **It's thin.** Not LangGraph, not CrewAI — a small, opinionated prompt plus a handful of hooks on top of Claude Code's own primitives (sub-agents, slash commands, hooks, MCP).

---

## How it works

Autopilot runs as a loop of **units**. Each unit is one ticket (or one bundle of related tickets) → one branch → one PR.

**Night / preflight phases** set up the run: check the kill-switch, load the active profile, take a mutex so two runs can't collide, confirm the tracker and git are reachable, and probe that the reserved review model is actually available before spending any work.

**Execute phases** drive one unit end-to-end: gather context, write and check the spec, enter a per-unit worktree, implement in waves, run the full verification protocol, run the layered review, open and ready the PR, watch CI, reconcile the review bot, and **hold** at the correct terminal state — a PR a human can merge with one click.

If anything can't be resolved safely — a contested critical finding, a missing dependency, a genuinely hard ticket — the run **HALTs and hands it to a human** rather than guessing. It's designed to fail loudly and early, not silently and late.

---

## Safety model

Autopilot is built to be trusted to run unattended. The guarantees that make that reasonable:

- **Hard stops** (the engine will not do these under any circumstances): merge a PR, push to the default branch, run a production/cloud database migration, install dependencies, edit CI config or secret files from the orchestrator seat, or force-push a shared branch.
- **HOLD for human** — every PR waits for a human decision. The engine's job ends at "ready to merge."
- **Gate re-verification** — every quality gate a sub-agent claims to pass is re-run by the orchestrator before it's believed.
- **Auditable trail** — each unit leaves a spec, an arbitration ledger of every review finding and its disposition, and a run log that records what was verified, what was deferred, and what was held.

---

## Quick start

1. Install [Claude Code](https://www.anthropic.com/claude-code).
2. Copy `profiles/example.yml` → `profiles/<your-product>.yml` and fill in: your target repo path, your tracker's team/project, your branch convention, and your quality-gate commands (typecheck / lint / test / e2e / migrations).
3. From your product repo, run the build slash command with your profile:
   ```
   /run-build --profile <your-product>
   ```
4. In the morning, open the held PR, read the brief in its body, and merge if you're happy with it.

The profile is the only project-specific configuration; the framework itself is generic. See `profiles/example.yml` for every field, documented inline.

---

## Requirements

- **Claude Code** (the agent runtime this is built on).
- A **target git repo** with CI configured (the required checks are what the run watches to green).
- An **issue tracker** for picking work and recording outcomes (Linear is supported today).
- Your **quality gates expressed as commands** — whatever "done and correct" means for your codebase.
- Optionally, a **code-review bot** on your PRs (e.g. CodeRabbit) as the post-PR net.

---

## What this repo contains

| File | What it is |
|---|---|
| `ORCHESTRATOR-V2.md` | The current engine — the prompt the build command executes, phase by phase. |
| `ORCHESTRATOR.md` | The previous-generation engine, kept for reference. |
| `subagent-templates.md` | The briefs for the spawned sub-agents (explorer, architect, implementers, test engineer). |
| `grumpy-designer.md` | The brief for the adversarial design-review pass. |
| `profiles/example.yml` | A fully-commented profile template — copy it to configure your own target. |

Per-run state (specs, ledgers, logs) is written under a gitignored `state/` directory and never committed.

---

## Status

Autopilot is a **working framework under active development**. It has driven real feature work to merge-ready pull requests on live repositories, but it is opinionated and assumes a workflow close to the one described here. Treat the profile as the seam you adapt; expect to tune the gate commands and review model to your stack.

## License

MIT — see [`LICENSE`](./LICENSE).
