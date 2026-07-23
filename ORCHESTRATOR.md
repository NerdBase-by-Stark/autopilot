# Autopilot Orchestrator (v1)

A self-driving prompt for the orchestrator session. Generic across product targets — see "Profile" below.

> **v2 is the active path.** The v2 engine (`ORCHESTRATOR-V2.md`, invoked by `/run-build`) is under active development and is the recommended engine. This v1 file (invoked by `/run-autopilot`) is self-contained and still works; it is kept for reference and for setups that prefer the simpler single-PR flow.

**This file lives at `~/autopilot/ORCHESTRATOR.md`** (a separate tooling repo — kept out of every target product's git history).

**The orchestrator must run with cwd = `{{profile.target.repo_path}}`** so the target's relative paths (`{{profile.artifacts.dir}}`, `src/...`, `supabase/...`) resolve correctly. State files live in the tooling repo at `~/autopilot/state/` (always referenced by absolute path) — they never touch the target repo. The `/run-autopilot` slash command does the `cd` for you.

Paste the **AUTOPILOT PROMPT** block below into a fresh Claude Code session inside `{{profile.target.repo_path}}`. Designed to take the next backlog ticket from cold start to PR-ready, with all quality gates, dual review, Playwright verification, and design-faithful implementation, then HALT for human merge + cloud-push approval.

Built from the lessons of shipping real product PRs and every gotcha in the target's own memory dir (`{{profile.memory.target_memory_dir}}`).

---

## Profile

The orchestrator is generic; every project-specific value (Linear team/project, branch convention, memory/artifact paths, design-source path, gate commands, hard-stop scripts, stack gotchas) lives in `~/autopilot/profiles/<name>.yml`, not in this file.

**Resolution rule (binding — read this once, apply for the whole session):** there is no template engine. In Phase 0 the orchestrator reads `~/autopilot/profiles/<name>.yml` in full (part of the cache-anchor batch) and holds its values in context for the rest of the run. Every `{{profile.<dotted.key>}}` token appearing anywhere below in this file is a reference into that YAML — read it as "substitute the value at this YAML path, mentally, right now." `<ticket-id>` (no `profile.` prefix) is shorthand for `{{profile.linear.ticket_id_prefix}}-<numeric-id>` once Phase 1 has picked a ticket.

**Which profile:** `/run-autopilot [--profile <name>]`. The slash command resolves the profile name and `cd`s to that profile's `{{profile.target.repo_path}}` before this prompt starts. If `~/autopilot/profiles/<name>.yml` does not exist, EXIT immediately with `[autopilot] unknown profile: <name> — expected a file at ~/autopilot/profiles/<name>.yml`.

**Value with a `TODO:` placeholder in the active profile:** if a phase needs a field and finds a `TODO:` placeholder instead of a real value, that phase HALT-PHASEs with diagnosis `profile <name> missing required field: <dotted.key>` rather than guessing or skipping the check silently — UNLESS the phase explicitly documents a degrade-and-continue rule for that field (several phases below do, e.g. Phase 2.3.5's CSS-audit skip, Phase 4.0.5's HIGH-tier-Workflow skip, Phase 6.4/6.5's template/mapping-doc skip); those explicit rules win over this default.

**List-valued fields** (e.g. `sensitive_surfaces.risk_tier_high_path_patterns`, `design.css_authoritative_paths`, `sensitive_surfaces.money_keywords`) are YAML arrays — a `{{profile.<key>}}` reference to one resolves to every item, comma-or-space-joined as the surrounding prose/command needs (a grep alternation, an `-e` list, a bullet list — use judgment matching the syntax context).

---

## What this prompt does

1. **Cold-bootstrap context** from CLAUDE.md, the memory index, the running log, the Linear-mapping doc, and the current Linear board.
2. **Pick the next ticket** using a priority rubric (urgent regressions first, then in-progress, then high-priority backlog, then sprint flow).
3. **Write a bound spec** to `{{profile.artifacts.spec_file_template}}` covering Visual deltas + Dialog contract per `{{profile.artifacts.pr_template}}`.
4. **Spawn an agent team in waves** (architect → frontend → parallel reviewers → test engineer), looping until every gate is green.
5. **Open a PR** via `gh pr create` with the full template body, label `In Review` on Linear.
6. **HALT** for human approval before merging and before cloud-pushing migrations.

It does not push to the default branch, does not run `{{profile.hard_stops.cloud_migration_linked_cmd}}`, does not install packages without confirmation. Those remain orchestrator-only after explicit user OK.

---

## How to run it

**One-shot, fresh session:**
```
cd {{profile.target.repo_path}} && claude
> [paste AUTOPILOT PROMPT below]
```

**Self-paced loop** (model decides cadence between iterations, picks the next ticket on each wake):
```
/loop /run-autopilot [--profile <name>]
```
…where `/run-autopilot` resolves the profile, `cd`s to that profile's `{{profile.target.repo_path}}`, then reads `~/autopilot/ORCHESTRATOR.md` and executes the AUTOPILOT PROMPT block.

**Scheduled** (e.g., every weekday 09:00 in your timezone):
Use the `schedule` skill to fire the same prompt on a cron. Each run ships at most one PR; if the previous PR is still open in review, the run reports status and exits clean.

---

## Preconditions (one-time, human)

- **CodeRabbit CLI** (optional AI-review gate) must be installed (`~/.local/bin/coderabbit`, on PATH) AND authenticated (`coderabbit auth login` — browser). Verify with `coderabbit doctor` (want `0 failed`; the Authentication line must be a `[pass]`, not `[warn] Not signed in`). If unauthenticated at run time, Phase 4.1.5 skips the CodeRabbit gate with a WARN and falls back to the sub-agent reviewers — it does not block.

---

## Quality gates (every PR must clear ALL)

Every command below is a **literal, runnable, copy-paste command** — MUST — do not proceed past a gate on narrative alone ("verify X passes" is not a gate; running the command in this row is). Values in `{{profile.gates.*}}` come from the active profile's `gates:` block; if a field there is a `TODO:` placeholder, this gate cannot run — HALT-PHASE with diagnosis `profile <name> missing gate: <gate-name>`.

**Telemetry (MUST, non-skippable — if your setup provides a gate-logger):** immediately after every gate's outcome is known (pass or fail), the orchestrator runs:
```
<gates-dir>/gate-log.sh autopilot-<gate-name> orchestrator <pass|catch> "<one-line detail: exit code + any counted axis>"
```
`<gate-name>` = the row's short name (`tsc`, `eslint`, `lint-migrations`, `migration-up-local`, `types-regen`, `bundle-ceiling`, `playwright`, `code-review`, `design-review`, `coderabbit`, `visual-proof`). `catch` = gate failed on this attempt (an actual defect caught before merge, not an orchestrator error); `pass` = gate passed. This call never blocks the run (the logger degrades silently) — MUST fire regardless. (If your setup has no gate-logger, drop this step.)

| Gate | Command | Pass criterion |
|---|---|---|
| Type | `{{profile.gates.tsc.cmd}}` | {{profile.gates.tsc.pass_criterion}} |
| Lint | `{{profile.gates.eslint.cmd}}` | {{profile.gates.eslint.pass_criterion}} |
| Migrations | `{{profile.gates.lint_migrations.cmd}}` | {{profile.gates.lint_migrations.pass_criterion}} |
| Local apply | `{{profile.gates.migration_up_local.cmd}}` | {{profile.gates.migration_up_local.pass_criterion}} |
| Types regen | `{{profile.gates.types_regen.cmd}}` | {{profile.gates.types_regen.pass_criterion}} |
| Bundle ceiling | `{{profile.gates.bundle_ceiling.cmd}}` | {{profile.gates.bundle_ceiling.pass_criterion}} |
| E2E | `{{profile.gates.playwright.cmd}}` | {{profile.gates.playwright.pass_criterion}} |
| Code review | `code-reviewer` sub-agent | Findings list ≤200 words, every Critical/High either fixed or explicitly deferred to a new Linear ticket |
| Design review (UI PRs only) | `grumpy-designer` sub-agent (`general-purpose` w/ design-critic prompt) | Same disposition rule. Run **in parallel** with code reviewer. |
| AI review (CodeRabbit CLI) | `{{profile.gates.coderabbit.cmd}}` (local CLI, orchestrator-run — NOT a sub-agent; `timeout` because an unauthed CLI hangs) | {{profile.gates.coderabbit.pass_criterion}} **Local pre-PR gate** (no GitHub push needed). |
| Visual proof (count) | `{{profile.gates.screenshots_count.cmd}}` | {{profile.gates.screenshots_count.pass_criterion}} |
| Visual proof (PNG truth) | `{{profile.gates.screenshots_png_truth.cmd}}` | {{profile.gates.screenshots_png_truth.pass_criterion}} |
| Pre-PR gate suite | `{{profile.gates.pre_pr_gate.cmd}}` | {{profile.gates.pre_pr_gate.pass_criterion}}. Phase 6 runs this INSTEAD OF re-deriving each check by hand — see Phase 6.3.5. |

If any gate fails, the orchestrator dispatches a fix-agent against the failing gate and re-runs all gates. Loop cap: **3 fix passes per gate**. After 3 failures, HALT and report — MUST, no exceptions.

---

## Hard stops (always require human OK)

- `git push origin {{profile.target.default_git_branch}}`
- `gh pr merge`
- `{{profile.hard_stops.cloud_migration_wrapper_cmd}}` (or `{{profile.hard_stops.cloud_migration_linked_cmd}}`) — cloud migration push
- `npm install` / `npm uninstall` of any non-dev dependency
- Modifying `~/.claude/settings.json`, `~/.claude.json`, or any secrets file (read-only inspection only)
- Any `DROP`, `TRUNCATE`, or `DELETE`-without-`WHERE` in a migration (lint will block; orchestrator must NOT bypass)

---

## Priority rubric for ticket selection

Run in order; pick the **first** ticket that matches.

1. **Open PRs in review** — if a PR opened by a prior autopilot run is still `OPEN`, exit clean with a one-line status. Don't queue a second.
2. **Urgent regressions** (Linear priority=1, status=Todo, label∋Bug or title∋"Regression") — e.g., a broken dropdown selector, a mobile layout regression.
3. **In Progress with no recent commits** (Linear status=`In Progress` AND `startedAt` > 7 days ago AND no branch HEAD touched in 7 days) — finish what was started.
4. **Sprint-flow continuation** — next item in `{{profile.artifacts.linear_mapping_doc}}` "Active workstream" table that is `Backlog` and has no unmet `Blocked by`.
5. **High-priority infra debt** — Linear priority=2, label∋(infra|database|security).
6. **Otherwise**: report "no eligible ticket, queue empty" and exit.

When the rubric matches a ticket already half-implemented, the orchestrator must read the existing branch state (`git branch -a`, `gh pr list`) before spawning anything.

---

## AUTOPILOT PROMPT

Paste everything between the `===AUTOPILOT===` markers into a fresh session. Self-contained — assumes only that you're in `{{profile.target.repo_path}}` on `{{profile.target.default_git_branch}}` with a clean tree, and that Phase 0 has already loaded the active profile per the "Profile" section above.

```
===AUTOPILOT===
You are the {{profile.linear.project}} orchestrator (profile: {{profile.profile_name}}). Drive ONE backlog ticket from `{{profile.target.default_git_branch}}` → PR-ready, then EXIT.

## GLOSSARY (binding)

- **HALT-PHASE** = stop the current phase, append a HALT entry to RUNNING-LOG.md, decrement the global fix-pass budget, retry per the per-phase loop cap. Do not exit the session.
- **EXIT** = write the final status message, do not make further tool calls, end the session. **Do NOT run the run-active sentinel's `stop` before the session stops** — the Stop hook runs the end-of-run isolation + model-watchdog sweep and checks the sentinel FIRST, so tearing it down before EXIT silently disarms that audit. The sentinel self-clears when this session's process exits (PID guard) and after its TTL, so no explicit teardown is needed and none must precede the audit.
- **Sub-agent** = `Task(subagent_type=...)` invocation using a template from `~/autopilot/subagent-templates.md` (verbatim, slot-filled). Every spawn MUST pin an explicit `model:` (an unpinned-spawn hook rejects unpinned spawns globally) — see `subagent-templates.md` for each template's model tier.

## CONCURRENCY CAP (binding — account-safety rule)

**Never spawn more than 3 sub-agents in parallel via the Task tool.** A single message containing N `Task` invocations counts as N concurrent. Background tasks (`run_in_background: true`) consume the same budget. If a phase wants more, batch into waves of ≤3 and complete a wave before dispatching the next. (Anthropic enforces concurrent-usage limits; exceeding ordinary individual usage risks rate-limits or a ban.)

## HARD STOPS (never auto-perform — require explicit human approval each time)

- `git push origin {{profile.target.default_git_branch}}` (any push to a protected branch)
- `gh pr merge` (any merge — autopilot opens, humans merge)
- `{{profile.hard_stops.cloud_migration_wrapper_cmd}}` (cloud push — see the active profile's `hard_stops` block for the exact flag semantics)
- `{{profile.hard_stops.cloud_migration_linked_cmd}}` (cloud migration)
- `npm install` / `npm uninstall` of any non-dev dependency
- Edits to `~/.claude/settings.json`, `~/.claude.json`, or any secrets file
- Any `DROP`, `TRUNCATE`, or unbounded `DELETE` in a migration (lint blocks; never bypass with `--no-verify`)
- Any `git push --force` or `git rebase` on a shared branch
- Reading file CONTENTS of `~/.claude/settings.json` or `~/.claude.json` (use `jq -r '.key'` to extract a single value if needed)

If you reach one of these and need it, EXIT with a status that names what's blocked and why.

## VERIFICATION PROTOCOL (binding — non-bypassable, applies to EVERY quality gate)

Sub-agent claims of "passed", "all green", "N/N tests passed", "screenshots saved" are HYPOTHESES, never gates. The orchestrator's own re-run of the gate command in THIS session is the authoritative result. (Restates the global rules: VERIFY BEFORE CLAIMING + sub-agent claims of "verified" are hypotheses, not facts.)

For every command in the human-facing "Quality gates" table at the top of this file:

1. **Re-run mandatory.** After a sub-agent reports a gate result, the orchestrator MUST re-run that exact command itself. No delegation. No `run_in_background: true` to "skip while waiting" for it. No "the sub-agent already ran it" exception. If the orchestrator did not invoke the command in its own tool log for THIS phase, the gate is unverified — HALT-PHASE.

2. **Capture quantifiable result.** Record exit code AND any countable axis the gate emits: Playwright `<X> passed, <Y> failed`, screenshot count via `ls *.png | wc -l`, PNG-truth count via `file *.png | grep -c 'PNG image data'`, eslint warning count, tsc error count. The orchestrator's captured numbers are authoritative.

3. **Verification-divergence detection.** If the sub-agent's claim differs from the orchestrator's actual result on ANY axis (exit code, pass-count, file-count, format-truth-count), this is a verification-divergence. Log:
   ```
   [phase <N> verification-divergence] gate=<command> claimed=<sub-agent number> actual=<orchestrator number>
   ```
   Then: increment `loop-state.fix_passes.<gate>`, dispatch a focused fix-agent against the actual failing axis (not the sub-agent's narrative), re-run the gate. Per-counter cap 3 still applies.

4. **Repeated-divergence escalation.** Three verification-divergences on the SAME gate within one PR run = HALT-PHASE with diagnosis `sub-agent integrity failure on <gate>`. The sub-agent is fabricating results; surface to human. Illustrative incidents:
   - A sub-agent claimed Playwright `14/14 passed`; the orchestrator re-run got `13/14`. (Caught only because the re-run actually happened. Without it, a false-pass merge.)
   - A sub-agent reported screenshots saved; the orchestrator's `file ... | grep -c 'PNG image data'` revealed text-file fakes with `.png` extensions.

This rule supersedes any per-phase instruction that omits the orchestrator re-run, omits the divergence comparison, or treats a sub-agent's claim as authoritative. If a per-phase instruction says "assert all-pass" without saying "re-run + compare to claim + HALT on divergence", read it as if it does.

## OUTPUT FORMAT (every step)

`[phase <N>.<step>] <verb-led action> → <exit-code-or-result>`

No prose. No narration. No recap. End-of-iteration HALT/EXIT messages follow the templates in §"Phase 7" and §"Failure protocol".

## STATE FILES (you maintain these — they survive context truncation)

### `~/autopilot/state/.autopilot.lock`
Flock target. Acquire in Phase 0 with `flock -n ~/autopilot/state/.autopilot.lock -c '...'` semantics; if held, EXIT with "another autopilot iteration in flight".

### `~/autopilot/state/<ticket-id>/loop-state.json` — counters + token budget
Schema:
```json
{
  "fix_passes": {"tsc":0,"eslint":0,"lint-migrations":0,"playwright":0,"code-review":0,"design-review":0,"global":0},
  "tokens": {"used_total":0, "cap":1000000, "warn_at":750000, "by_phase":{}, "by_subagent":[]}
}
```

Caps:
- Per fix-pass counter = **3**, global fix-pass = **5** (any cap hit → HALT-PHASE)
- **Token cap = 1,000,000** across the entire PR run (single source of truth — bounds worst-case PR cost and guards against a runaway-loop cost incident of the kind that has burned millions of tokens in unbounded agent loops). Tighten the cap if running on a smaller-context-window model.
- **HIGH risk-tier per-PR override:** Phase 4.0.6 may raise the cap to 2,000,000 for a single HIGH-tier PR to accommodate the deep-audit cost (a Shape-A audit can consume 300k–1.5M; the override leaves headroom for Phase 5 verification). This is a per-PR override applied at the start of 4.0.6 — it does not change the schema default. Reverts on the next PR run.

Token-tracking protocol (MECHANICAL — automate via `jq`; do NOT eyeball-update):

- After EVERY sub-agent reply, the orchestrator MUST do TWO things in this exact order:
  1. **Emit a tokens-marker line** in its own output: `[phase <N.M> tokens] agent=<subagent_type> delta=<parsed-N> running=<sum-after-update>`. This makes the parse visible to anyone reading the tool log and lets skip-detection (below) work.
  2. **Update `loop-state.json` atomically** via a single `jq` invocation (write-then-rename so a crash mid-write never leaves a half-JSON):
     ```
     STATE=~/autopilot/state/<ticket-id>/loop-state.json
     jq --arg agent "<subagent_type>" --arg phase "<N.M>" --argjson tokens <parsed-N> \
        '.tokens.by_subagent += [{"agent":$agent,"phase":$phase,"tokens":$tokens}]
         | .tokens.used_total = ([.tokens.by_subagent[].tokens] | add)
                              + ([.tokens.by_phase | to_entries[] | .value] | add // 0)' \
        "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
     ```
     The parsed-N comes from `<usage>total_tokens: N` in the sub-agent's tool-result. If the `<usage>` line is missing (rare), substitute a heuristic of 50,000 and emit `[phase <N.M> tokens] agent=<type> delta=50000-HEURISTIC running=<sum>` so the under-count is visible.

- After every orchestrator phase boundary, charge the 8K self-use heuristic:
  ```
  jq --arg phase "<N>" \
     '.tokens.by_phase[$phase] = ((.tokens.by_phase[$phase] // 0) + 8000)
      | .tokens.used_total = ([.tokens.by_subagent[].tokens] | add)
                           + ([.tokens.by_phase | to_entries[] | .value] | add // 0)' \
     "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  ```
  (Cannot read own context size from inside a Claude Code session — 8K heuristic is a known under-estimate; sufficient for cap-arithmetic guard-railing.)

- If `tokens.used_total >= warn_at` (default 750K) → emit `[autopilot WARN] tokens N/CAP` and continue.
- If `tokens.used_total > cap` (default 1M) → HALT-PHASE immediately with diagnosis `token cap exceeded: N/CAP`. Do NOT dispatch another sub-agent past the cap.

- **Skip-detection (binding):** if a phase's close row in `progress.yml` lands without a matching `[phase <N.M> tokens]` marker for each sub-agent reply that fired in that phase, the parse step was skipped → HALT-PHASE with diagnosis `token-parse skipped on phase <N>`. Cross-check: the count of `[phase <N.M> tokens]` lines for phase N should equal the count of Task() invocations in phase N.

### `~/autopilot/state/<ticket-id>/progress.yml` — append-only phase log
Schema (each phase emits TWO append-only rows — a `start` event when the phase begins and a `complete|halt|exit` event when it ends):
```yaml
pr: <N>
ticket: <ticket-id>
branch: <branch-name>
started_at: <iso8601>
phases:
  - phase: 1
    event: start
    at: <iso8601>
  - phase: 1
    event: complete   # or "halt" or "exit"
    at: <iso8601>
    status: ok | halt | exit
    summary: <one-line>
    sub_agents: [<list of subagent_type values>]
    tokens_delta: <int — increment over previous phase>
```
**Append-only.** Never edit prior entries. Every phase appends a `start` row as its FIRST tool call and a `complete|halt|exit` row as its LAST tool call. A row pair (start + close) per phase is mandatory — see §Phase 0.8. This is the auditable trail (PR-only-to-default + structured phase log = the evidence needed to show how runaway autonomous changes to sensitive data are prevented).

**Resume semantics:** Phase 0 reads `progress.yml` if it exists for the current branch.
- A `start` row without a matching `complete|halt|exit` row means the prior run crashed mid-phase. Do NOT auto-resume — surface the partial phase and require human intervention.
- If the last close row has `event: halt`, the orchestrator may resume from the next un-completed phase (do NOT re-run completed phases).
- If the last close row has `event: exit`, do not auto-resume — surface the prior exit reason.

---

## Phase 0 — Bootstrap

0.1. `flock -n ~/autopilot/state/.autopilot.lock -c "echo $$"` — if non-zero exit, EXIT with "another autopilot iteration in flight".
0.1.5. **Arm the run-scoped gate sentinel.** Run `<gates-dir>/autopilot-run-active.sh start "v1-$(date -u +%Y%m%dT%H%M%SZ)"`. This writes `~/autopilot/state/run-active.json`, which arms the run-scoped hooks for the duration of this session: a product-write guard (orchestrator may not hand-write the target's `src/`/`e2e/`/`supabase/migrations/` — spawn an implementer), a git-stash guard (no `git stash` mid-run), the end-of-run isolation + model-watchdog sweep, and a resume-leak guard (no resuming a cheap agent under an expensive driver). Without the sentinel these are dormant. Teardown is at EXIT (see GLOSSARY) and is self-healing via the PID+TTL guard.
0.2. **Cache-anchor reads** (do these in this exact order, in a single parallel batch — they form the prompt-caching anchor for the rest of the session; Claude Code automatically caches stable prefixes, and these reads will be cache-hit on every subsequent /loop iteration if the file contents haven't changed):
  - `~/CLAUDE.md`, `{{profile.target.repo_path}}/CLAUDE.md`
  - `{{profile.memory.target_memory_index}}` (index only — load individual gotcha files lazily in the phase that needs them)
  - `{{profile.artifacts.mission_doc}}`, `{{profile.artifacts.migration_rules_doc}}`, `{{profile.artifacts.pr_template}}`, `{{profile.artifacts.linear_mapping_doc}}`, `{{profile.artifacts.agent_handoff_protocol}}`, `~/autopilot/grumpy-designer.md`, `~/autopilot/subagent-templates.md`
  - `tail -50 {{profile.artifacts.running_log}}`

  **Do NOT re-read any of these files later in the session.** Re-reading invalidates the cache and roughly doubles orchestrator token cost per Anthropic guidance. If you need a fact from one of these files later, recall it from context.

0.3. Parallel shell + MCP probe:
  - `git rev-parse --abbrev-ref HEAD` — must equal `{{profile.target.default_git_branch}}`
  - `git diff --quiet` — must exit 0 (no unstaged changes)
  - `git diff --cached --quiet` — must exit 0 (nothing staged)
  - `git status --short` — the running-log file (`{{profile.artifacts.running_log}}`) may be the only dirty file; tolerate local-config/logs dirs (`.claude/` — never commit `.claude/settings.local.json`), locally-installed agent-skill files (`.agents/` + `skills-lock.json` from `npx skills add coderabbitai/skills` — local agent skills, NOT product code; never `git add` them), and any untracked path under `{{profile.artifacts.dir}}` (prior-run specs/screenshots — the autopilot's own working area; only `git add` the explicit spec/screenshot paths this PR created). **`.autopilot/` must NEVER appear in the target repo** — autopilot state lives in `~/autopilot/state/`. If `.autopilot/` does appear, HALT-EXIT with diagnosis (autopilot mis-configured).
  - `git log --oneline -5`
  - `gh pr list --state open --author "@me" --json number,title,headRefName,url,createdAt | jq --arg re '{{profile.linear.branch_regex}}' '[.[] | select(.headRefName | test($re))]'` — only autopilot's own PRs (matching the active profile's branch convention) count
  - `mcp__claude_ai_Linear__list_issues` for `{{profile.linear.project}}` project: Todo, Backlog, In Progress
0.4. If any gate in 0.3 fails (not on default branch / dirty tree / can't reach Linear) → EXIT with one-line diagnosis. Do not attempt to fix.
0.5. If the filtered `gh pr list` returned a PR:
  - If `createdAt` < 72h ago → EXIT clean with status `[autopilot] Prior PR #<N> still in review (<age>): <url>`
  - If ≥ 72h → EXIT with status `[autopilot] Prior PR #<N> stale (<age>) — human attention requested: <url>`
  Do not queue a second PR.

0.6. **Resume check.** `ls ~/autopilot/state/*/progress.yml 2>/dev/null` — for each, check if its `branch` matches a local branch that exists AND has commits ahead of the default branch AND no open PR. If exactly one such progress file exists with `phases[-1].status == "halt"`:
  - Output `[phase 0.6] resuming PR #<N> from phase <next-uncompleted>`
  - Skip to Phase 1.4 (resume work; do NOT re-run completed phases)
  - The orchestrator continues from the resume point; counters in `loop-state.json` and the token budget are preserved across the resume.

  If multiple resumable progress files exist, EXIT with diagnosis (human picks which to resume). If `status == "exit"`, do not auto-resume — surface the prior exit reason.

0.7. **Initialize state files** for a fresh PR run (skip on resume): once Phase 1 has picked the ticket and the ticket-id is known, `mkdir -p ~/autopilot/state/<ticket-id>/`; write `~/autopilot/state/<ticket-id>/loop-state.json` with zeroed counters + token cap from §STATE FILES; write `~/autopilot/state/<ticket-id>/progress.yml` with header (`pr`, `ticket`, `branch`, `started_at`) and an empty `phases:` list. The lock acquired in Phase 0.1 lives at `~/autopilot/state/.autopilot.lock` (global, not per-PR).

0.8. **Phase boundary rule (binding for ALL subsequent phases — NON-SKIPPABLE):** every phase MUST be bracketed by `progress.yml` appends. These are the FIRST and LAST tool calls of each phase, no exceptions.
  1. **AT THE START of the phase** (FIRST tool call, before any sub-agent dispatch or shell command for that phase): append `{phase: <N>, event: start, at: <iso8601>}` to `~/autopilot/state/<ticket-id>/progress.yml`. **Phase 1 special case:** the start event fires immediately after 0.7 has created `progress.yml` (which can only happen once 1.1 has resolved the ticket-id) — i.e., the order inside Phase 1 is `1.1 (pick ticket) → 0.7 (init state files) → 1.0 (append start event) → 1.2 (output) → 1.3-1.4 close`.
  2. **After every sub-agent reply within the phase**: parse `<usage>total_tokens: N` and append to `loop-state.json` `tokens.by_subagent`. Recompute `tokens.used_total`. If past `warn_at` → emit warning. If past `cap` → HALT-PHASE before dispatching anything else.
  3. **AT THE END of the phase** (success, halt, or exit — LAST tool call): append `{phase: <N>, event: complete|halt|exit, at: <iso8601>, status: ok|halt|exit, summary: <one-line>, sub_agents: [...], tokens_delta: <int>}` to `progress.yml`.

  This rule supersedes any per-phase instruction that omits it. **Skip-detection (binding):** if a phase ends without both a `start` row AND a matching `complete|halt|exit` row in `progress.yml`, treat the run as corrupted and HALT-EXIT. The Phase 0.6 resume check uses the same detection — a `start` row without a close partner means the prior run crashed mid-phase.

## Phase 1 — Pick a ticket

1.1. Apply the priority rubric in the human-facing section "Priority rubric for ticket selection" of this file. Pick exactly one ticket.

1.1.5. **Linear-authoritative pickup (binding — never extrapolate scope).** Before declaring the ticket picked:
  - Call `mcp__claude_ai_Linear__get_issue` with `id: "<ticket-id>"`. Read the full description, acceptance criteria, attached PR list, and `startedAt`/`updatedAt` timestamps.
  - **If Linear MCP is unauthenticated** (call returns auth error) → EXIT with diagnosis `Linear authentication required — cannot scope ticket from mapping-file alone`. Do NOT extrapolate scope from `{{profile.artifacts.linear_mapping_doc}}`'s one-line summary. (Lesson: mapping-file extrapolation once shipped 2/5 of the actual ticket; the full Linear description revealed the gap only post-merge.)
  - **Stranded-state check.** If the ticket status is `In Review` AND `updatedAt` > 30 days ago AND the `attachments` array contains no GitHub PR — suspect stranded state, NOT in-flight review. Investigate before picking. Possible outcomes: (a) fix landed direct-to-default pre-PR-only, bump to Done; (b) fix incomplete + later PR dropped wiring, file a regression ticket; (c) fix never landed, reopen as Todo. EXIT for human triage; do not auto-resume.
  - **Two-half check.** If the Linear description has clearly separable halves (e.g., "Schema + UI" or "Backend RPC + Admin CRUD page") AND total scope is heavy (touches >5 files, requires a migration, builds a new admin route), surface a split-vs-monolithic choice via `AskUserQuestion` before scoping the iteration. When the user picks split, file sub-ticket(s) via `mcp__claude_ai_Linear__save_issue` with `parentId: "<parent-ticket-id>"` BEFORE branching, then scope the autopilot iteration to ONE half only.

1.2. Output: `[phase 1.2] picked <ticket-id> "<title>" via rubric step <N> — <one-clause why>` (include `linear-read=true` to confirm 1.1.5 ran).
1.3. If no ticket matches, append `<ts>  [autopilot]  N/A  queue empty` to RUNNING-LOG.md and EXIT.

## Phase 2 — Branch + spec

2.0. Append `{phase: 2, event: start, at: <iso8601>}` to `progress.yml` (FIRST tool call of this phase, per §0.8).
2.1. Pre-checks:
  - `git ls-remote --heads origin "<branch-name-prefix>*"` — if a remote branch exists, EXIT with diagnosis (prior failed run; needs human cleanup).
  - `git branch --list "<branch-name-prefix>*"` — same for local.
2.2. `git checkout -b <branch-name>` where `<branch-name>` follows `{{profile.linear.branch_convention}}` (kebab short-desc from the Linear `gitBranchName`, trimmed).
2.3. Linear: status → "In Progress" via `mcp__claude_ai_Linear__save_issue`. If MCP fails, retry once after 30s; if still failing → HALT-PHASE.

2.3.5. **Trivial-scope skip check** (adaptive-dispatch optimization — saves tokens vs full explorer+architect dispatch when the ticket is genuinely small):

  **Skip-eligible — ALL FOUR conditions must hold:**
  1. **Ticket signals trivial.** At least ONE of:
     - Linear title contains: `regression`, `fix`, `typo`, `rename`, `hotfix`, `doc`, `docs`, `comment`, `wire`, `bump`
     - Linear description ≤ 200 characters
     - Linear description explicitly names ≤ 3 file paths AND no other unspecified scope
  2. **Not UI-build heavy.** The ticket does NOT cite a design-source file (`{{profile.design.design_source_glob}}`) AND its description does NOT contain `module`, `implement`, `build`, `roster`, `dashboard`, `feature` (these signal a new vertical that needs architect spec discipline).
  3. **Not in a forbidden category.** The ticket does NOT touch: a new or modified dialog component, auth / RLS checks, money-handling code (`{{profile.sensitive_surfaces.money_keywords}}`), a DB migration, or any path in `{{profile.design.css_authoritative_paths}}`. (CSS regressions are visual-only and need the architect's CSS audit.)
  4. **Linear description was READ this session AND its scope matches the mapping-file row to ±1 file.** Phase 1.1.5 must have fetched the ticket via `mcp__claude_ai_Linear__get_issue` (not extrapolated from the mapping-file one-liner). The orchestrator must be able to quote the ticket's `## Acceptance` / `## Deliverables` section verbatim and confirm the inferred file list matches that section to within ±1 path. (Lesson: trivial-skip is fast but it lets the orchestrator ship a strict subset of the ticket when the description was never read. Reviewers cannot save you — they score against the spec, not the ticket.)

  **If ALL hold** → SKIP 2.4 (explorer) AND 2.5 (architect). Orchestrator writes the spec INLINE to `{{profile.artifacts.spec_file_template}}` using this minimal template:

  ```markdown
  # PR <N>: <ticket title>

  **Linear**: <ticket-id>
  **Dispatch mode**: orchestrator-inline-spec (Phase 2.3.5 trivial-scope skip rule)
  **Scope**: <one-sentence scope, ≤30 words>
  **Files likely touched**: <list of paths, ≤3>
  **Success criterion**: <observable outcome — what must be true after the PR>
  **Gates that apply**: tsc / eslint (on touched files) / [playwright if UI / skip if no UI] / lint-migrations / migration up --local (only if migration touched)
  **Tokens saved vs full dispatch**: ~60K (explorer + architect)
  ```

  Continue to Phase 3 with this spec. Document the decision in the PR body so the user can audit which PRs ran adaptive-dispatch.

  **If ANY condition fails OR ANY forbidden category fires** → continue to 2.4 with the full explorer + architect dispatch (default behaviour).

  Log: `[phase 2.3.5] trivial-scope=<true|false> dispatch=<inline|full> reasoning=<one-clause-citing-which-rule-fired>`. The Phase 6 PR body MUST include this line so adaptive-dispatch decisions are auditable post-hoc.

2.4. Spawn ONE `feature-dev:code-explorer` sub-agent using **Template A** in `~/autopilot/subagent-templates.md`. Output goes to `{{profile.artifacts.context_file_template}}`.
2.5. Spawn ONE architect using **Template B** (`backend-architect` for DB-only PRs; `feature-dev:code-architect` for UI-heavy PRs). Output goes to `{{profile.artifacts.spec_file_template}}`.
2.6. **Spec acceptance** — `grep -E` the spec file against the checklist in Template B. If any required line is missing, return the spec to the architect with the missing-line list. Cap 2 retries → HALT-PHASE.

## Phase 3 — Implementation waves

Each wave uses a template from `~/autopilot/subagent-templates.md` verbatim, slot-filled. After each wave the orchestrator (not the sub-agent) re-runs the gate commands and compares exit codes to gate criteria. Sub-agent's pass-claim is a hypothesis, not a gate.

**Binding gotchas (already loaded in Phase 0; sub-agent prompts cite them by name):** convenience-block re-append, CSS-Grid cell order, focus-trap hook signature + useCallback, body-scroll-lock, design-source strings binding, server-recompute money, single-db-client-per-action.

3.0. Append `{phase: 3, event: start, at: <iso8601>}` to `progress.yml` (FIRST tool call of this phase, per §0.8).
3.1. **Wave A — DB (only if migration needed):** spawn ONE `backend-architect` via **Template C**. Orchestrator re-verifies: `{{profile.gates.lint_migrations.cmd}}` exit 0, `{{profile.gates.migration_up_local.cmd}}` exit 0, `{{profile.gates.types_regen.cmd}}` + convenience block re-appended, `{{profile.gates.tsc.cmd}}` exit 0. On any failure → increment the relevant `loop-state.fix_passes` counter, dispatch a focused fix-agent, re-verify. Per-counter cap 3.
3.2. **Wave B — Server actions / queries:** ONE `fullstack-developer` via **Template C** (substitute scope to lib/actions). Same re-verification protocol.
3.3. **Wave C — UI components:** ONE `frontend-developer` via **Template D**. Re-verify: tsc, eslint, plus orchestrator-level CSS audit — `grep -oE 'className="[^"]+"' src/<touched> | grep -oE '\b{{profile.design.css_class_prefix}}[a-z0-9-]+\b' | sort -u | while read c; do grep -qF ".$c" {{profile.design.css_authoritative_paths}} || echo "MISSING: $c"; done` (skip this audit — log `[phase 3.3] css-audit skipped: css_class_prefix is unset for this profile` — if the active profile has no `css_class_prefix`). Zero MISSING required.

After every wave: orchestrator increments the global counter. If global > 5 → HALT-PHASE.

## Phase 4 — Parallel review (UI PRs)

4.0. Append `{phase: 4, event: start, at: <iso8601>}` to `progress.yml` (FIRST tool call of this phase, per §0.8).

4.0.5. **Risk-tier classification** (binding — determines whether 4.1 fires single-agent reviewers or 4.0.6 fires the Workflow tool).

Read the protocol at `{{profile.artifacts.workflow_integration_protocol}}` § "When to invoke — risk-tier gate" for canonical rules (if that field is unset for the active profile, skip 4.0.6 entirely and treat every PR as MEDIUM/LOW — proceed straight to 4.1). Apply mechanically using the current branch's touched files + Linear ticket labels, matched against `{{profile.sensitive_surfaces.risk_tier_high_path_patterns}}` and `{{profile.sensitive_surfaces.risk_tier_high_linear_labels}}`:

- `git diff <default-branch>...HEAD --name-only` for touched files
- Linear ticket labels from Phase 1.1.5 `get_issue` result

HIGH triggers (authoritative copy in the active profile's `sensitive_surfaces` block; quick reference):
- Path patterns: `{{profile.sensitive_surfaces.risk_tier_high_path_patterns}}`, plus server actions/entities touching `{{profile.sensitive_surfaces.money_auth_entities}}`
- Linear labels / other triggers: `{{profile.sensitive_surfaces.risk_tier_high_linear_labels}}`
- Uncertain → call HIGH (false-positive escalation is cheap; false-negative miss is expensive)

Emit auditable line: `[phase 4.0.5] risk_tier=<HIGH|MEDIUM|LOW> reason=<path:<glob> | label:<name> | none>`

- **HIGH** → skip 4.1, proceed to 4.0.6.
- **MEDIUM | LOW** → skip 4.0.6, proceed to 4.1.

4.0.6. **HIGH risk-tier review via the Workflow tool** (only fires if 4.0.5 = HIGH; requires the optional workflow artifacts in the profile — if unset, 4.0.5 already routed us to 4.1).

References: `{{profile.artifacts.workflow_integration_protocol}}` § "Canonical Workflow shapes" + `{{profile.artifacts.workflow_example_script}}` (the parameterized Shape A template).

(a) **Token budget pre-check + HIGH-tier cap override.** A Workflow Shape-A audit on a typical PR costs 300k–1.5M tokens. Before dispatching, if `loop-state.tokens.used_total + 1_500_000 > tokens.cap`, raise `tokens.cap` to `max(2_000_000, used_total + 1_500_000)` via the same `jq` atomic write-then-rename pattern as §STATE FILES. Emit `[phase 4.0.6] token_cap raised: <old>→<new> (HIGH-tier Workflow override)`. This is a per-PR override; the default 1M is unchanged in the schema.

(b) **Adapt the canonical script.** Copy `{{profile.artifacts.workflow_example_script}}` to `~/autopilot/state/<ticket-id>/audit-workflow.js`. Edit ONLY these parameters at the top of the file: `MODULE_NAME` (touched-module slug), `PROJECT_ROOT` (absolute path to the current worktree), `SOURCE_HINTS` (derived from `git diff <default-branch>...HEAD --name-only` filtered to source files), `DIMENSIONS` (keep all defaults for UI PRs; drop `visual-fidelity` if the design source is missing; drop `grid-cell-order` for non-UI PRs; ADD a `migration-safety` dimension for migration PRs with prompt "Audit each new migration against `{{profile.artifacts.migration_rules_doc}}`. Flag any DROP/TRUNCATE/non-additive op, any CREATE INDEX CONCURRENTLY inside a migration file, and any RLS policy change without a CHECK-clause + test.").

(c) **Invoke Workflow.** `Workflow({scriptPath: "~/autopilot/state/<ticket-id>/audit-workflow.js"})`. The tool returns immediately with `task ID` + `Run ID`. Capture both to `loop-state.json` under a new `workflow.runs[]` array (atomic `jq` write). The orchestrator is automatically notified when the workflow completes — DO NOT poll.

(d) **On notification, parse the result.** The Workflow returns `{confirmed[], refuted[], confirmed_count, refuted_count, located, dimensions_audited, total_findings}`. Append `[phase 4.0.6] workflow runId=<id> confirmed=<n> refuted=<n> dimensions=<n>` to progress.yml. Token-charge: sum the `subagent_tokens` reported in the task notification into `loop-state.tokens` via the same `jq` atomic write as §STATE FILES.

(e) **Feed confirmed findings into 4.2 triage** alongside CodeRabbit findings from 4.1.5. Use the same Critical/High/Medium/Low buckets. The Workflow's `confirmed[]` is the AUTHORITATIVE review output for this PR — do NOT also dispatch `code-reviewer` + `grumpy-designer` on HIGH paths (4.0.5 routed us past 4.1).

(f) **PR-body trace requirement.** Phase 6.4 PR body MUST include the line `Workflow audit Run ID: <runId>` so reviewers can trace it.

(g) **Fallback on Workflow failure.** If the Workflow tool errors (script syntax, schema validation timeout, locate-stage finds zero files, etc.), emit `[phase 4.0.6] workflow FAILED: <reason>; falling back to 4.1 single-agent review` and proceed to 4.1 as if 4.0.5 had returned MEDIUM. This MUST NOT block the run.

4.1. **MEDIUM/LOW risk-tier path** (only if 4.0.5 = MEDIUM or LOW; or 4.0.6 fallback fired). Spawn IN A SINGLE MESSAGE (true parallelism):
  - `code-reviewer` against `git diff <default-branch>...HEAD`
  - `general-purpose` with the prompt from `~/autopilot/grumpy-designer.md` (verbatim, slot-filled). **Required for any PR touching `src/components/`, `src/app/`, or `src/styles/`. Skip only for pure DB / lib PRs.**

  **Rewrite-aware brief enhancement (binding when applicable).** If `git diff <default-branch>...HEAD --stat` shows ANY file with mode `delete` or `rename`, OR any single file with >50% of its lines replaced (i.e., the PR rewrites a route/component from scratch), the orchestrator MUST append to both reviewer briefs:

  > Pre-state feature inventory required. For each deleted/renamed/rewritten path in this diff, run `git show <default-branch>:<path>` to read the pre-state and enumerate every distinct feature it exposed (rendered components, route handlers, exported functions, button labels, form fields, links). For each enumerated feature, grep the post-state diff for evidence the feature is preserved OR call out its removal as intentional + spec-cited. Findings of "feature silently dropped in rewrite" are CRITICAL severity by default — they cannot be caught from the diff alone.

  (Lesson: a from-scratch route rewrite once silently dropped a download-button wiring that another PR had added days earlier. Two layers of review missed it because they scored against the new shape, not the pre-state feature inventory. The button was missing from production for weeks.)
4.1.5. **CodeRabbit CLI gate (orchestrator-run — ALL PRs, DB or UI; NOT a sub-agent, does NOT count against the 3-parallel cap or the 1M token budget).**
  - First confirm readiness: `coderabbit doctor` — if it reports `[warn] Authentication: Not signed in` or `[fail]` on any line, EMIT `[phase 4.1.5] coderabbit SKIPPED: <reason>` and continue to 4.2 with sub-agent reviewers as authoritative. A missing/unauthed CLI MUST NOT block the run.
  - If ready: run `timeout 300 coderabbit review --agent --base <default-branch>` (`--agent` = structured machine-parseable findings; the `timeout 300` is mandatory — an unauthenticated or stalled CLI HANGS waiting on interactive auth; on exit 124 treat as SKIPPED-with-WARN). Optionally pass `-c {{profile.artifacts.migration_rules_doc}}` for migration PRs. Capture the structured output.
  - Parse each CodeRabbit finding and classify into the same Critical/High/Medium/Low buckets used in 4.2 (treat security/data-loss/auth/money/migration-safety findings as Critical or High by default). Fold them into the 4.2 triage alongside the sub-agent reviewers' tables.
  - Emit `[phase 4.1.5] coderabbit C=<n> H=<n> M=<n> L=<n>` so the result is auditable. The Phase 6 PR body MUST include this line.

4.2. Triage findings (sub-agent reviewers return Markdown tables; CodeRabbit returns plain-text findings classified in 4.1.5 — triage ALL sources together):
  - Critical + High → fix via focused frontend or backend agent (Template C/D, scope-limited).
  - Medium → fix if ≤10-line diff; else open a follow-up Linear ticket via `mcp__claude_ai_Linear__save_issue` and reference in PR Notes.
  - Low → defer, reference in PR Notes.
4.3. After fixes, decide whether the second-pass parallel review can be skipped (token-economy concession with explicit guard-rails):
  - **Skip-eligible (ALL THREE conditions must hold):**
    1. Fix-agent's total diff is **<30 lines** across all touched files (`git diff <default-branch>...HEAD --shortstat` post-fix).
    2. Fix addresses ONLY Critical / High findings from the first pass — no Medium/Low picked up opportunistically, no scope creep.
    3. NO new files added — only existing files modified.
  - **Forbidden skip cases (override the size rule — re-run reviewers regardless of diff size):** the fix touches `src/styles/` (CSS regressions are visual-only; code review can't catch them); auth / RLS policy checks; server-side money handling; a new or modified dialog component (focus-trap + body-scroll-lock are too easy to break).
  - If skip-eligible AND not in a forbidden category → log `[phase 4.3] second-pass skipped: diff=<N>L, C/H only, no new files, no forbidden touch`. Increment `loop-state.fix_passes.code-review` AND `loop-state.fix_passes.design-review` each by 1. Proceed to 4.4.
  - Otherwise → re-run BOTH reviewers in a single parallel message (per 4.1). Increment both fix counters. Cap 3 each.
4.4. If any new Critical/High survives the third pass → HALT-PHASE.

## Phase 5 — Verification (Playwright)

5.0. Append `{phase: 5, event: start, at: <iso8601>}` to `progress.yml` (FIRST tool call of this phase, per §0.8).
5.1. Spawn ONE `test-engineer` using **Template E**. Seeding happens before tests are written — verify via SELECT.
5.2. **Orchestrator re-verification (NOT delegable, NOT skippable — apply §VERIFICATION PROTOCOL on every check):**
  - `{{profile.gates.playwright.cmd}}` — re-run by orchestrator. Capture exit code AND parse `<N> passed, <M> failed` from stdout. **Compare to sub-agent's claim**: if sub-agent claimed `X/Y passed` and orchestrator's parse differs in either count or exit code → verification-divergence per §VERIFICATION PROTOCOL step 3.
  - `{{profile.gates.screenshots_count.cmd}}` — {{profile.gates.screenshots_count.pass_criterion}}; compare to sub-agent's claimed count; mismatch = divergence.
  - `{{profile.gates.screenshots_png_truth.cmd}}` — {{profile.gates.screenshots_png_truth.pass_criterion}}; if PNG-truth-count < the count above, the sub-agent fabricated screenshots; divergence + HALT-PHASE on first occurrence (this is integrity failure, not a normal divergence — per §VERIFICATION PROTOCOL step 4).
  - All three checks must pass on the orchestrator's own re-run OR HALT-PHASE.
5.3. If real bugs found → back to Phase 3 (Wave C usually) to fix; increment `loop-state.fix_passes.playwright`; cap 3.

**All-gates-green summary (single source of truth = the human-facing "Quality gates" table at the top of this file).** Every gate in that table must show a passing re-run from this session before Phase 6 opens a PR. MUST. The mechanical re-derivation of this happens once, in Phase 6.3.5 below, via `{{profile.gates.pre_pr_gate.cmd}}` — Phase 5 does NOT re-run the full gate table a second time itself.

## Phase 6 — PR

6.0. Append `{phase: 6, event: start, at: <iso8601>}` to `progress.yml` (FIRST tool call of this phase, per §0.8).
6.1. `git status`, then `git add <explicit-paths-only>` (never `git add .`), then `git diff --cached`, then `git log <default-branch>..HEAD --oneline`. Verify no secrets (`.env`, `.env.local`, `*.pem`, `id_rsa*`), no oversized binaries (>2MB without explicit OK).
6.2. `git commit -m "$(cat <<'EOF'
<ticket-id>: <imperative summary>

<one-paragraph why>
EOF
)"`
  - **NO attribution trailer.** Do NOT add `Co-Authored-By: …` or any "Generated with" line — enforced by `~/.claude/settings.json` `includeCoAuthoredBy:false` + a commit-message hook that blocks any commit reintroducing it.
6.3. `git push -u origin <branch-name>`. (NOT the default branch. Verify branch name first.)
6.3.5. **Pre-PR gate suite — MUST, replaces hand-re-running the Quality gates table.** Run `{{profile.gates.pre_pr_gate.cmd}}` from `{{profile.target.repo_path}}` (it `cd`s to the repo root itself via `git rev-parse --show-toplevel`). This script reads the target repo's own `.gates.conf`, runs every check it lists, writes `.gate-evidence.json`, and logs telemetry itself. Do NOT proceed to 6.4 unless this exits 0.
  - **Exit 0** → `[phase 6.3.5] pre-pr-gate PASS` → continue to 6.4.
  - **Nonzero exit** → this is the same gate the pre-PR evidence hook will independently re-derive and enforce on `gh pr create` — do NOT attempt 6.4 anyway hoping the hook is lenient. Dispatch a fix-agent against the named failing check(s), re-run `{{profile.gates.pre_pr_gate.cmd}}`. Per-counter cap 3. Cap exceeded → HALT-PHASE.
  - **No `.gates.conf` at the target repo root** (script exits with "nothing to run") → this is a profile/target setup gap, not a code defect — HALT-PHASE with diagnosis `target repo missing .gates.conf — one-time human setup required`. Do NOT author a `.gates.conf` yourself; that's a one-time human precondition.
6.4. `gh pr create --title "<ticket-id>: <imperative summary>" --body "$(...)"` with body following `{{profile.artifacts.pr_template}}` exactly (skip the template-fidelity check if that field is unset — write a plain body covering scope, gates, and the Verification section instead). Include the Verification section with actual exit codes from Phase 5, and the Phase 6.3.5 pre-PR-gate result.
6.5. Update `{{profile.artifacts.linear_mapping_doc}}` with the new row (skip if that field is unset for the active profile).
6.6. Append final RUNNING-LOG entry: `<iso-ts>  [autopilot]  PR-<N> <ticket-id>  <one-line summary>  <comma-separated-paths>`
6.7. Linear: status → "In Review" + comment with the PR URL via `mcp__claude_ai_Linear__save_comment`.

  **Status-update may be redundant but is harmless** — the GitHub→Linear integration auto-progresses status when a PR title is prefixed with the ticket ID. The explicit `save_issue` call is defensive; both firing is idempotent.

  **Hook gotcha for Done transitions** (post-merge, not this phase but worth knowing): a Done-evidence hook may block `state: Done` transitions unless the issue `description` field contains a merged PR URL, an HTTP-200 deploy URL, or an absolute screenshot/log path. For tickets fixed by PR (this autopilot's normal flow) the GitHub-Linear auto-link satisfies the hook automatically. For older tickets fixed by direct-to-default commits PRE the PR-only workflow, the description must be edited first to include a deploy URL (e.g., `{{profile.deploy_check.done_hook_probe_url}}` returns 200) + commit URL before the state transition succeeds.

## Phase 7 — HALT (success path = EXIT)

7.0. Append `{phase: 7, event: start, at: <iso8601>}` to `progress.yml` (FIRST tool call of this phase, per §0.8).
7.1. Append `{phase: 7, event: complete, at: <iso8601>, status: ok, summary: "PR #<N> opened, awaiting human merge", sub_agents: [], tokens_delta: <int>}` to `progress.yml` BEFORE the success output below (Phase 7 close row must land while the orchestrator still has tool access).

Output exactly:
```
[autopilot SUCCESS]
PR #<N> ready: <url>
Linear: <ticket-id> → In Review
Local migrations applied; cloud push NOT done (hard stop).
Reviewers net findings: C=<n> H=<n> M=<n> L=<n>; deferred to: <ticket-id-list-or-none>
Loop budget consumed: global=<n>/5
Awaiting human: (1) merge approval, (2) cloud-migration push approval after merge.
```

Then EXIT. Release the lock (`rm ~/autopilot/state/.autopilot.lock` — flock auto-releases on shell exit but be explicit). No further tool calls.

## Failure protocol (HALT-PHASE → EXIT after cap exceeded)

If a per-fix-counter cap (3), the global fix-pass cap (5), OR the **token cap (1,000,000 default)** is exceeded, OR a hard stop is needed mid-flow, OR any Phase 0 gate fails:

1. Append HALT entry: `<iso-ts>  [autopilot]  HALT  phase=<N> reason=<one-clause> failing-gate=<command>`
2. Linear status rollback by phase:
  - Phases 0-3 → set Linear back to "Todo"
  - Phases 4-5 → keep "In Progress", add Linear comment "autopilot blocked at phase <N>: <reason>"
  - Phase 6-7 → leave "In Review" if PR was opened; otherwise "In Progress" + comment
3. Output:
```
[autopilot HALT-EXIT]
Phase <N> failed: <one-clause reason>
Failing gate: <command> → <exit-code or finding>
Last 20 lines of failing output:
<paste>
Branch state: <branch> @ <sha>; <files dirty>
Loop budget at exit: <per-counter values>
Token budget at exit: <used_total>/<cap> (warn_at <warn_at>)
Resumable: <yes if last progress.yml entry status=halt; no otherwise>
Suggested next move: <one sentence>
```
4. Release lock. EXIT.

Never bypass a gate to move forward. Never `--no-verify`. Never rebase or force-push.
===AUTOPILOT===
```

---

## Companion artifacts (referenced by the prompt)

These are the active profile's `artifacts:` fields — resolve them from `~/autopilot/profiles/<name>.yml`, not from this list (this list documents what each field IS, for a human reading this file):

- `{{profile.artifacts.mission_doc}}` — mission + non-goals
- `{{profile.artifacts.migration_rules_doc}}` — additive-only DDL rules
- `{{profile.artifacts.pr_template}}` — PR body shape, Visual deltas table, Dialog contract
- `{{profile.artifacts.linear_mapping_doc}}` — Linear ↔ PR ↔ branch table
- `{{profile.artifacts.agent_handoff_protocol}}` — sub-agent prompt rules
- `{{profile.memory.target_memory_index}}` — gotcha index

Any field above whose profile value is a `TODO:` placeholder (or absent) means that companion artifact doesn't exist yet for this profile — the phase(s) that reference it degrade per the profile-specific skip note attached to that phase; they do NOT silently invent the missing doc's contents.

If you ever change a binding rule (e.g., a new memory gotcha lands), the prompt picks it up automatically next run because it re-reads the memory index cold every session.

---

## Tuning knobs

- **Slow ticket flow** (one PR per day): use the `schedule` skill, fire once daily.
- **Sprint mode** (back-to-back PRs): use `/loop` with self-pacing — the orchestrator checks `gh pr list` and exits clean if a PR is still open, so the next loop iteration just re-evaluates and waits.
- **Spec-only mode**: change Phase 6 to "STOP at branch+spec, do not implement" — useful when you want to scrub the spec before agents spend tokens.
- **No-Playwright mode** (DB-only PRs): Phase 5 spawns a `test-engineer` that runs psql assertions instead of Playwright.

---

## Why these constraints

- **HALT before merge / cloud-push**: on a real project, a PR shipped with migrations that sat un-pushed for 24h because the orchestrator forgot. Making this an explicit hard stop forces a human moment.
- **Dual review in parallel**: on a real UI PR, code-review alone caught 0 of the design-critical defects; the grumpy designer caught all of them.
- **Binding strings**: "general shape, defaults for the rest" cost multiple design-criticals on a real PR — the design source's strings are a binding contract.
- **Seed-first verification**: agents silently mislabel screenshots without seeded data.
- **Loop cap 3**: per the global rule "3+ failed fixes → STOP, question architecture with the user". The same rule applied per gate, not globally.
