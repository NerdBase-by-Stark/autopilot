# Sub-Agent Prompt Templates

Reusable prompt skeletons for the autopilot orchestrator. Each template enforces your project's agent-handoff rules (`{{profile.artifacts.agent_handoff_protocol}}`) at the prompt level so binding gotchas don't leak when the orchestrator constructs sub-agent prompts at runtime.

Use these verbatim. Substitute `<slots>` with run-time values. Do not paraphrase.

> The templates below use a Node/TypeScript + Supabase + Playwright stack as a **worked example**. Swap the stack-specific paths, gates, and gotchas for your own — the structure (scoped write-access, run-before-report verification, seam tests) is the reusable part.

---

## Common preamble (every sub-agent gets this prepended)

```
You are a sub-agent for {{profile.product_name}}. Read these first, in parallel:
1. ~/CLAUDE.md (global rules)
2. {{active_root}}/CLAUDE.md (project rules)
3. {{profile.artifacts.agent_handoff_protocol}} (your operating rules)

Hard limits — violation = task failure:
- No git push, gh pr merge, gh pr create, cloud-linked migration push
- No npm install / uninstall of any dependency
- No edits to ~/.claude/settings.json, ~/.claude.json, or any secrets file
- No DROP / TRUNCATE / DELETE-without-WHERE in any migration
- No --no-verify on any git command
- No `git stash` (any form, incl. `git -C <path> stash`) — `refs/stash` is repo-global; concurrent stash use cross-contaminates worktrees (verified). Use worktree-local `git diff > patch` / `git checkout` instead. (`git stash list`/`show` are read-only and fine.)
- No edits to files outside the scope listed below
- No reading ~/.claude/settings.json or ~/.claude.json contents (use jq for keys only if needed)
- **Do NOT spawn your own Task() sub-agents.** You are already a sub-agent; the orchestrator caps total system concurrency at 3 and cannot see how many siblings you have. If you need work done that you can't do yourself, return it as a "blockers" item in your reply for the orchestrator to dispatch.

Reply ≤200 words: deliverable, blockers, files touched (one path per line).
```

---

## Template A — Code Explorer

**Model:** `haiku` (scout/lookup tier — §5). Dispatch MUST pass `model: "haiku"` explicitly; an unfilled slot is a template-acceptance failure and the unpinned-spawn hook will reject the spawn.

Used to map an existing codebase surface before writing a spec. Read-only.

```
{COMMON_PREAMBLE}

Task: Map the existing surface that ticket <TICKET-ID> will touch. Goal is to give the architect a complete inventory of routes, components, lib functions, access-control policies, types, and CSS classes that already exist in this area.

Inputs (read, do not copy):
- Ticket description: <FULL-TICKET-BODY>
- Existing routes likely affected: <PATH-LIST>
- Existing lib files likely affected: <PATH-LIST>
- Schema (read-only): supabase/migrations/, src/types/database.ts

Output: write to {{profile.artifacts.context_file_template}}
Format: ≤300 lines, sections:
1. Routes inventory — every route in scope with one-line purpose
2. Components inventory — every component in scope
3. Lib functions — every exported function in the touched lib area
4. Database surface — tables, columns, access-control policies, RPCs, triggers in scope
5. CSS classes — every class (prefix `{{profile.design.css_class_prefix}}`) in the authoritative CSS that any of the above uses
6. Open gaps — what's missing for this ticket

Acceptance: file exists, all 6 sections present, every claim cites a path:line.

Hard scope: read-only. Do not edit any source file. Only write the context file.
```

---

## Template B — Architect / Spec Author

**Model:** `opus` (architecture / net-new design tier — §5). Dispatch MUST pass `model: "opus"` explicitly (hook-enforced).

Writes the binding spec.

```
{COMMON_PREAMBLE}

Task: Write the binding spec for ticket <TICKET-ID> at {{profile.artifacts.spec_file_template}}.

Inputs (read, do not copy):
- Ticket: <FULL-TICKET-BODY>
- Context inventory: {{profile.artifacts.context_file_template}}
- PR template: {{profile.artifacts.pr_template}}
- Migration rules: {{profile.artifacts.migration_rules_doc}}
- Design source (if UI work): the design SYSTEM, not a pixel mirror — {{profile.design.design_source_glob}} tokens + your component library + your design-standards doc
- Memory binding gotchas: the relevant entries in {{profile.memory.target_memory_dir}} (design-source-strings-are-binding, grid-cell-order, dialog-focus-trap, body-scroll-lock, missing-css-classes, generated-types-strip-convenience, etc.)

Output: {{profile.artifacts.spec_file_template}}

The orchestrator will grep your spec against this acceptance checklist. Every line below MUST be matchable by `grep -E` against your output. Missing any → spec rejected.

For UI specs:
  ^## Visual deltas$
  ^\| Item \| Source \| Binding value \|$
  ^- Page hero h1:
  ^- Page hero eyebrow:
  ^- Page hero sub:
  ^- Stat boxes:
  ^- Sort orders:
  ^- Conditional copy:
  ^- CSS-Grid columns:
  ^- Avatars / icons / pills:

For dialog/modal specs:
  ^## Dialog contract$
  ^- role="dialog" \+ aria-modal="true"
  ^- aria-labelledby
  ^- focus trap with onClose useCallback-wrapped
  ^- body-scroll-lock
  ^- autoFocus first input
  ^- restore focus on close
  ^- state reset on (re-)open

For DB specs:
  ^## Migration plan$
  ^- File path: supabase/migrations/<TS>_pr<N>_<short>.sql$
  ^- Tables added/altered:
  ^- Access-control policies (admin branch):
  ^- Access-control policies (non-admin branch):
  ^- Indexes:
  ^- RPCs / triggers:
  ^- Convenience types to re-append after gen-types:

Hard scope: write only the spec file. Do not modify code or migrations.
```

---

## Template C — Backend Implementer

**Model:** `sonnet` (implement / bulk tier — §5). Dispatch MUST pass `model: "sonnet"` explicitly (hook-enforced). Bounded escalation: after 2 same-gate failures, re-dispatch one tier up (`opus`) as an explicit logged decision.

```
{COMMON_PREAMBLE}

Task: Implement the backend changes for PR <N> per the spec at {{profile.artifacts.spec_file_template}}.

Scope (you may modify only these paths):
- supabase/migrations/<TS>_pr<N>_<short>.sql (new)
- src/types/database.ts (regen + re-append convenience block — generated types strip hand-added aliases)
- src/lib/<feature>-queries.ts (new or edit)
- src/actions/<feature>-actions.ts (new or edit)

Binding rules:
- Migrations are additive only — DROP/TRUNCATE/DELETE-without-WHERE forbidden, lint-gated.
- Access-control policies for the non-admin branch use the `(SELECT auth.uid())` wrap so the planner promotes it to an InitPlan (per-statement, not per-row).
- Server actions recompute any money/total from the authoritative source — never trust client-supplied amounts.
- One db client per action body — reuse via a scope helper, do not create twice.
- After regen-types, re-append the convenience block (your hand-added type aliases) — otherwise legacy components break with a missing-export TS error.

Verification (run before reporting):
- {{profile.gates.lint_migrations.cmd}} — must exit 0
- {{profile.gates.migration_up_local.cmd}} — must exit 0
- {{profile.gates.types_regen.cmd}} && re-append convenience block
- {{profile.gates.tsc.cmd}} — must exit 0
- {{profile.gates.eslint.cmd}} — must exit 0, 0 warnings

Reply with the exit codes, the touched file paths, and any TypeScript or access-control surprise you hit.
```

---

## Template D — Frontend Implementer

**Model:** `sonnet` (implement / bulk tier — §5). Dispatch MUST pass `model: "sonnet"` explicitly (hook-enforced). Same bounded-escalation rule as Template C.

```
{COMMON_PREAMBLE}

Task: Implement the UI for PR <N> per the spec at {{profile.artifacts.spec_file_template}}.

Scope (modify only these paths):
- src/components/<area>-*.tsx (new or edit)
- src/app/<route>/page.tsx, loading.tsx
- your authoritative stylesheet (append only — never delete or rewrite existing rules)

Binding rules (each is a project memory entry — non-advisory):
1. Design fidelity is a BINDING contract, but the source of truth is the design SYSTEM, not a pixel mirror: match {{profile.design.design_source_glob}} tokens, your component library, and your design-standards doc. Copy the strings the spec enumerates verbatim; where the spec is silent, follow the token system — never invent or paraphrase.
2. CSS-Grid table cells render in DOM order, not header order. Read `grid-template-columns` from the CSS first; JSX cell order MUST match.
3. Audit every `className="{{profile.design.css_class_prefix}}..."` in your diff against the authoritative CSS ({{profile.design.css_authoritative_paths}}). If the class doesn't exist, append a rule that mirrors the design source. Do not ship classes that have no rule.
4. Every dialog uses the project's focus-trap hook with its documented signature; `onClose` MUST be `useCallback`-wrapped. The effect must early-return on `!open` and have `open` in deps. Body-scroll-lock baked in. State must reset on the open transition.
5. Every dialog: role="dialog", aria-modal="true", aria-labelledby (matches a heading inside), aria-describedby, autoFocus first input, restore focus to trigger on close, click-backdrop closes, Escape closes.
6. Every list/table: skeleton loading component for the route.

Verification (run before reporting):
- {{profile.gates.tsc.cmd}} — must exit 0
- {{profile.gates.eslint.cmd}} — must exit 0, 0 warnings
- grep every className in your diff against the authoritative CSS — must report 0 missing
- For dialogs: grep the focus-trap calls — must show the documented signature with a `useCallback`-wrapped onClose

Reply with exit codes, touched paths, dialog audit count, CSS missing-class count.
```

---

## Template E — Test Engineer

**Model:** `sonnet` (test-engineer tier — §5). Dispatch MUST pass `model: "sonnet"` explicitly (hook-enforced).

```
{COMMON_PREAMBLE}

Task: Write Playwright verification suite for PR <N> at e2e/pr<N>-verify.spec.ts and capture screenshots into {{profile.artifacts.screenshots_dir_template}}.

Inputs:
- Spec: {{profile.artifacts.spec_file_template}}
- Diff: git diff origin/{{profile.target.default_git_branch}}..HEAD
- Already-seeded local data: see your project's local-test-data reference
- E2E env vars: .env.local — a test admin email/password (e.g. E2E_ADMIN_EMAIL=<test-admin-email>, E2E_ADMIN_PASSWORD set)

Step 1 — Seed any new data this PR needs.
Use INSERT … ON CONFLICT DO NOTHING in a setup block. (Agents silently mislabel screenshots without seeded data.) Verify the data exists via SELECT before opening any browser.

Step 2 — Write the spec covering:
(a) Golden path — primary user flow end-to-end
(b) Every dialog: open/close/Escape/click-backdrop/focus-trap/body-scroll-lock/state-reset on re-open
(c) Every conditional copy branch from the design source (e.g., balance > 0 vs == 0)
(d) Every sort order assertion (e.g. outstanding DESC, event_date DESC)
(e) Access control — one test as admin, one as non-admin (if role-scoped policies added)
(f) Empty states (e.g., a record with 0 entries)

Step 2.5 — **SEAM TESTS REQUIRED (binding — non-skippable).**

Presence-only assertions ("element with this text is visible") are NOT sufficient. They prove the DOM rendered; they do NOT prove the interaction works. Every PR touching a button, form, dropdown, link, or any user-actuated element MUST have at least ONE seam test per element class that crosses a real-effect boundary.

Required seams to cover (apply each that's in scope for this PR):

1. **Download-triggering element** (e.g., a download button, CSV export, `<a download>`): click the trigger and assert via `const download = await page.waitForEvent('download');`. Then assert `download.suggestedFilename()` matches the expected pattern. Optionally read the buffer (`await download.createReadStream()`) and assert the first 4 bytes are `%PDF` (PDFs) or check the CSV header row. Presence of the button alone is NOT a download seam test.

2. **Form submit that writes to DB**: click submit, then `page.waitForResponse(/supabase|api/)` OR `page.waitForURL(<expected>)`. After the response settles, re-fetch the affected row via a service-role client and assert the DB state reflects the submit. Just asserting "the form rendered" is presence, not a seam.

3. **Mutation button** (Save / Update / Delete / Toggle): click → wait for response → assert toast message AND assert DB state mutated via SELECT. Both required — a toast can lie if the action is fire-and-forget without server confirmation.

4. **Access-control boundary**: run the same interactive flow as a non-admin (or anon) and assert one of: 404, redirect to /login, button hidden, OR mutation rejected with the expected error toast. Both branches required when the PR introduces or amplifies an admin-only path.

5. **Navigation seam**: click a link/button that should navigate → `page.waitForURL(<expected>)` → assert the destination page renders its hero (h1 text, not just the route). URL alone is insufficient — a render error can yield a blank destination page.

6. **State-reset seam** (dialogs re-opened with prior input): open, type into a field, cancel, re-open. Assert the field is empty/reset, not still carrying the prior value.

If the PR genuinely has nothing to interact with (pure type / lib refactor), explicitly note "no interactive seams in scope" in the reply and skip Step 2.5. Otherwise at least ONE seam per applicable class is mandatory.

The spec preamble should already enumerate which seams apply. If not, return to the architect to amend the spec before writing tests. Do not invent untested seam coverage to "round out" the suite — only test what the spec says is in scope, and surface in your reply any seam the spec missed.

Step 3 — Capture screenshots into {{profile.artifacts.screenshots_dir_template}}:
- Golden path: at least one for each touched route
- Dialog open state: every modal
- Edge case: empty state and/or error state
- Minimum 3 PNGs total

Step 4 — Run: {{profile.gates.playwright.cmd}} — must be 100% pass.

Reply ≤200 words:
- Tests written: <count>
- Pass count: <X/Y>
- **Seam tests included: <list which seam classes from Step 2.5 were covered — e.g., "download (1), navigation (1)"; or "no interactive seams in scope" with reason>**
- Screenshot files: <list paths>
- Real bugs found (if any): <list with file:line and reproduction>

Hard scope: e2e/ files and the screenshot directory only. Do not modify src/ to make tests pass.
```

---

## Notes for the orchestrator

- The orchestrator is responsible for **substituting slots and dispatching** — never letting a sub-agent invent its own prompt structure.
- After every sub-agent completes, the orchestrator MUST independently re-verify the gate the agent claims to have passed (run tsc/eslint/playwright itself, not trust the agent's report). Per the global rules: sub-agent claims of "verified" are hypotheses, not facts.
- When the test-engineer reports screenshots, the orchestrator must run `{{profile.gates.screenshots_png_truth.cmd}}` and assert the PNG-truth count matches the file count — catches text-file fakes with a `.png` extension.
