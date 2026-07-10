---
name: coderabbit
description: >
  Self-hosted CodeRabbit-equivalent PR review. Reproduces CodeRabbit's pipeline —
  diff-scoped context gathering, a real lint/SAST/secret-scan grounding pass
  (semgrep, gitleaks, actionlint, hadolint, shellcheck), a grounded line-by-line
  LLM review with committable suggestions, a PR walkthrough summary, and
  cross-cutting checks (tests-for-changed-paths, description-vs-diff). Orchestrates
  the existing /security-review and /simplify skills instead of duplicating
  them. Use when the user says "coderabbit", "review my PR/branch/diff like
  coderabbit", "AI code review", or before opening a pull request.
---

# CodeRabbit-equivalent PR review

Reproduce CodeRabbit locally, for free. This is an **orchestrator**: it runs the
real tool fleet for grounding, then layers an LLM review on top, and reuses
existing review skills rather than re-implementing them.

The value of CodeRabbit is that the LLM review is **grounded in real tool output**.
So the grounding pass is not optional — run it first, feed it to the review.

> **This is an enforced gate, not a suggestion.** A `PreToolUse` hook
> (`scripts/pr-gate.sh`, registered by this plugin) blocks `gh pr
> create|edit|ready|merge` until this skill has run clean on the current commit.
> The gate reads an approval receipt that **Phase 7 writes only after every 🔴
> Blocking finding is fixed and committed**. Any new commit invalidates the
> receipt → you must re-review. So: run this skill, fix what it finds, let it
> approve, then open/update the PR. Don't try to route around the hook — fix the
> findings.

**Bundled scripts.** The `scripts/` and `references/` directories sit next to
this SKILL.md inside the installed plugin. Resolve them from this file's
location and set once:

```bash
SKILL_DIR="<directory containing this SKILL.md>"   # e.g. ${CLAUDE_PLUGIN_ROOT}/skills/coderabbit
```

---

## Inputs

- **Base ref** (optional): what to diff against. Default `origin/main`, then
  `main`, then `origin/master`/`master`.
- Works on a branch, an un-pushed commit, or the uncommitted working tree.
- If the user names a PR number, `gh pr checkout <n>` first, then proceed.

## Phase 0 — Scope the diff

```bash
BASE="${ARG_BASE:-origin/main}"
git fetch origin --quiet 2>/dev/null || true
git --no-pager diff --stat "$(git merge-base "$BASE" HEAD)"...HEAD
```

Read the diff and the PR/commit description. Note the stated **intent** — you'll
check the code against it in Phase 4. Pull in the *full* changed files (not just
hunks) and any obviously-related files for context, exactly as CodeRabbit does.

## Phase 1 — Grounding pass (the real tools)

Run the bundled script. It is diff-scoped, never aborts on findings, and skips
missing tools with an install hint:

```bash
bash "$SKILL_DIR/scripts/ground.sh" "$BASE"
```

This runs, scoped to changed files:
- **gitleaks** — secrets in the diff
- **semgrep** (`p/ci`, `p/security-audit`, `p/secrets`) — SAST for php/js/ts/py/go/rb
- **actionlint** — changed GitHub workflows
- **hadolint** — changed Dockerfiles
- **shellcheck** — changed shell scripts
- **ripgrep** heuristics — left-in `dd()`/`console.log`/`.only`/`@ts-ignore`/TODO/FIXME

Treat every ⚠️ as a **lead to verify against the diff**, not an automatic finding.
If a tool is reported missing and the change touches its domain, tell the user the
one-line `brew install …` to unlock it — don't silently skip the coverage.

## Phase 2 — Project quality gates

Run the repo's mandated quality gates — the language-level
linters/type-checkers/tests CodeRabbit also shells out to. Find them in this
order:

1. **The repo's CLAUDE.md / CONTRIBUTING.md** — if it names gate commands, those
   are authoritative. Only run the sides the diff touches.
2. **Auto-detect** otherwise: `composer.json` scripts (`lint`, `stan`, `test`),
   `package.json` scripts (`lint`, `typecheck`/`tsc --noEmit`, `test`),
   `Makefile` targets, `pyproject.toml` (ruff/mypy/pytest), etc.

**If gates run inside a container (Laravel Sail, docker compose), first verify
they will test THIS diff, not another checkout.** Containers commonly mount one
working copy while you review from a worktree on a different branch — then the
container's tests greenlight code you're not reviewing:

```bash
bash "$SKILL_DIR/scripts/check-gates-env.sh"
```

(Container name and mount path configurable via `CODERABBIT_GATE_CONTAINER` /
`CODERABBIT_GATE_MOUNT`; defaults `laravel.test` / `/var/www/html`.) If it
reports a ⚠️ MISMATCH, either align the checkout or run the gates another way —
and in the report, mark Phase-2 gates as **not run against this diff** rather
than claiming a green that isn't real.

Capture failures — they become 🔴 findings. If the repo requires coverage, a
coverage regression on a changed path is a finding.

## Phase 3 — Grounded LLM review (fan out over EVERY changed file)

**Review every changed file. No subset, no "high-risk first," no deprioritizing.**
The most common failure of this skill is skipping files that "look boring"
(admin pages, service providers, factories, config, jobs) — that is exactly
where real bugs hid in past runs (a user admin that creates password-less
accounts; a factory with a mismatched extension; a provider that TypeErrors on a
missing config key). CodeRabbit reviews all of them; so do you.

**Mechanism — fan out, don't serialize.** A single-pass read of a big diff misses
things by fatigue. Instead:

1. Group the changed files (e.g. by directory/subsystem: Controllers, Jobs,
   Models, Admin/UI, Providers, Migrations, Services, Factories/Tests, Config).
2. **Spawn a review subagent per group in parallel** (Agent tool, or a Workflow
   fan-out if available), each given: the group's diffs + full files, the Phase
   1/2 grounding output for those files, and `references/review-checklist.md`.
   Each returns structured findings (`path:line`, severity, category, suggestion).
3. Collect, de-dup, and rank. Every changed file must be covered by exactly one
   agent — verify coverage before synthesizing (list files with no reviewer and
   assign them). If you truly cannot fan out (tooling unavailable), review the
   files yourself **one group at a time** and tick each off a checklist — but
   never drop a file.

Walk each file against all of `references/review-checklist.md` (10 dimensions,
incl. cross-file invariants, sibling-pattern consistency, config safety, and
test-data correctness). Cross-reference the Phase 1/2 tool output — cite it when
it corroborates a finding.

**Trace across files, not just within the hunk** (this is where the biggest
misses happen):
- **Sibling patterns:** if the diff fixes/guards something in one place, grep for
  the same construct elsewhere and check it too (e.g. one `firstOrCreate` guarded
  for a race, another not; one enum arm updated, a parallel one not).
- **Invariant pairs across files:** a value set in file A must satisfy a check in
  file B — status/stage maps vs a job's `expectedStatus`, a route name vs its
  controller, a config key written vs read, an event vs its listener.
- **Call-site fanout:** for a changed signature/return/enum, open its callers.

Rules for output, matching CodeRabbit:
- One finding = one location. Anchor as `path:line`.
- Prefer a **committable suggestion** (a fenced diff/code block the user can paste)
  over prose.
- Label severity: 🔴 Blocking / 🟡 Should-fix / 🟢 Nit / 💭 Question. Don't
  under-rate a real vulnerability as a "question" — a working exploit path
  (SSRF/IDOR/injection) is 🟡/🔴, not 💭.
- No noise: skip findings you can't tie to a line, and skip tool false positives
  (e.g. a PHPStan "undefined method" that only fires because the grounding run
  lacks the project's stubs/extensions — verify against the real Phase-2 gate
  before reporting). Don't restate what the code does.
- If uncertain about *intent* (not correctness), ask (💭) instead of asserting.

## Phase 4 — Cross-cutting checks (the layers gates miss)

1. **Tests-for-changed-paths.** For each new/changed function or branch, name the
   test that covers it, or flag it 🔴 as uncovered. Reject meaningless tests
   (no `assertTrue(true)`, no status-only asserts, no snapshot-only, no tests
   that pass whether or not the feature works) — and enforce any stricter
   testing rules the repo's CLAUDE.md adds.
2. **Description ⇄ diff consistency.** Does the code do what the PR/commit claims —
   nothing undisclosed added, nothing promised missing? Flag scope creep.
3. **Breaking changes.** API/schema/contract changes surfaced and versioned?

## Phase 5 — Reuse existing skills (don't duplicate)

- Invoke **`/security-review`** for the deep security pass on the final diff.
- Invoke **`/simplify`** for the reuse/altitude/dead-code cleanup pass.
  (Simplify changes code — re-run Phase 2 gates afterward.)

If either skill is unavailable in this environment, perform that pass yourself
against the corresponding checklist sections instead of skipping it. Fold the
results into the single report below; de-dup overlapping findings.

## Phase 6 — Output: the walkthrough + review

Produce one Markdown report, in this order (this is the CodeRabbit layout):

```
## 📝 Walkthrough
<2–4 sentence summary of what the PR does and why>

## 📂 Changes
| File | Summary |
|------|---------|
| path | one line |

## 🔎 Findings
### 🔴 Blocking
- `path:line` — <issue>. <why it's wrong>.
  ```suggestion
  <committable fix>
  ```
### 🟡 Should-fix
### 🟢 Nits
### 💭 Questions

## ✅ Verification
- Gates: lint <✓/✗> · types/static analysis <✓/✗> · tests <✓/✗> · coverage <±>
- Grounding: secrets <✓> · semgrep <n> · shellcheck <n> · actionlint <n>
- Tests-for-changed-paths: <covered / gaps listed>
- Description ⇄ diff: <consistent / discrepancies>

## Verdict
<Ready to open PR / Fix blockers first> — <one line>
```

Keep it tight. If there are zero findings in a severity bucket, omit the bucket.

## Phase 7 — Fix, then approve (the enforcement step)

This is what lets the PR proceed. Do NOT skip it and do NOT fake it.

1. **Fix every 🔴 Blocking finding.** Address 🟡 Should-fix too, or state in the
   report why it's deferred. Re-run Phase 1–2 after edits (fixes can regress gates
   or introduce new grounding hits). Loop until 🔴 is empty.
2. **Commit the fixes** (on the feature branch — never on the default branch).
3. **Record approval for the committed HEAD:**
   ```bash
   bash "$SKILL_DIR/scripts/approve.sh"
   ```
   It refuses on a dirty tree (the receipt must describe exactly what the PR will
   contain) and is invalidated by any later commit.

Only after this will `pr-gate.sh` allow `gh pr create|edit|ready|merge`.

**Never bypass the gate.** If the hook blocks a PR command, the fix is to resolve
the findings and approve — not to disable the hook, edit the receipt by hand, or
reword the command to dodge the matcher. A secret flagged by the backstop must be
removed from history, not just from the working tree.

If review found **zero** blockers and needed no code changes, you may approve the
current HEAD directly (step 3) — the receipt still records that review happened on
this commit.

---

## Notes & failure modes

- **Not in a git repo / no base branch:** say so and stop; offer `git init` or a base ref.
- **Container for gates not running:** skip those gates with a note; still do 1,3,4,5.
- **Huge diff:** scale out, don't cut. Spawn more parallel review agents (one per
  directory/subsystem) so coverage stays complete — do NOT fall back to a
  "high-risk subset." Skipping the boring files is how real bugs ship. If a hard
  limit forces triage, say so explicitly and list every file that got only a
  shallow pass — but the default is: every file, fully reviewed.
- This skill **reviews**; it does not push, commit (except review fixes in
  Phase 7), or merge. Never advances the default branch.
