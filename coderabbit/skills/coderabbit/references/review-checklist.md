# Review dimensions (CodeRabbit-equivalent)

The LLM review pass walks each changed hunk against these. Report only issues you
can tie to a specific line in the diff. Prefer a committable suggestion over prose.

## 1. Correctness & logic
- Off-by-one, wrong operator, inverted condition, wrong variable.
- Unhandled `null`/`undefined`/empty-collection; missing `default` in switch/match.
- Async: unawaited promises, races, missing `try/catch` around `await`, unhandled rejections.
- Error handling: swallowed exceptions, `catch` that only logs, errors returned but never checked.
- Off-nominal paths: what happens on failure, timeout, partial write, retry?

## 2. Security (defensive)
- Injection: raw SQL string interpolation, unparameterized queries, shell exec of user input.
- AuthZ/AuthN: missing policy/gate/ownership check on a mutating or reading endpoint.
- Mass assignment / over-posting; missing `$fillable`/`$guarded` (or equivalent) discipline.
- SSRF, path traversal, unsafe deserialization, open redirect.
- Secrets/keys/tokens in code or fixtures; PII in logs.
- Missing rate limiting / throttling on public or expensive endpoints.
- Broken object-level authorization (IDOR): resource fetched by id without scoping to the actor.

## 3. Tests
- Does every **new/changed code path** have a test? Name the untested path.
- Happy path AND failure/edge path both asserted?
- Banned (regardless of what the repo says — and enforce anything stricter its
  CLAUDE.md adds): `assertTrue(true)`-style no-ops, asserts status but not
  body/side-effect, snapshot-only, tests that pass whether or not the feature works.
- E2E present for user-facing flows?
- Uses fakes/fixtures — no live network in CI?

## 4. Performance
- N+1 queries (missing eager-load); queries inside loops.
- Unbounded result sets (no pagination/limit); loading whole tables.
- Repeated work that should be memoized/cached; O(n²) over request-sized data.
- Missing DB index for a new query predicate / foreign key.

## 5. Data & migrations
- Migration reversible (`down()` present and correct)?
- Nullable vs default on new columns; backfill for existing rows.
- DB-engine-specific features (enums, citext, PostGIS, JSON operators) exercised
  against the real engine the app runs on — not a sqlite stand-in.
- Breaking API/schema change without a version bump or contract update.

## 6. Maintainability & consistency
- Matches surrounding naming, structure, and idiom (don't introduce a new style).
- Dead code, commented-out code, unused imports/vars.
- Duplicated logic that should reuse an existing helper.
- Public function / complex block missing a docstring where the file's convention has them.
- Magic numbers/strings that should be named constants or config.

## 7. Cross-file invariants & sibling consistency (HIGH-MISS — check every time)
The single biggest source of missed bugs. A hunk can be locally correct but break
a contract held in another file.
- **Sibling patterns:** grep the codebase for the same construct as the changed
  code. If one site is guarded/validated/fixed, are the others? (e.g. a race
  handled on one `firstOrCreate` but not another; one enum arm updated, a
  parallel one not; one endpoint authorized, a twin not.)
- **Invariant pairs across files:** a value produced in A must satisfy a check in
  B. Trace them: a stage→status map vs a job's `expectedStatus`; a config key
  written vs the type it's read as; an event vs its listener; a migration column
  vs the model `$fillable`/cast; a route name vs the controller method.
- **Call-site fanout:** a changed signature, return shape, enum, or default —
  open the callers and confirm each still holds.
- **Admin / back-office (Filament, Nova, internal tools):** these are security
  surfaces too. Check: user creation that leaves accounts unusable (no password /
  no invite); destructive actions that skip cleanup a sibling action does (token
  revocation on delete vs ban); missing uniqueness/validation on admin forms;
  actions that contradict a stated data guarantee.

## 8. Configuration & wiring safety
- A config key read without a default that will `TypeError`/`null`-deref if the
  key or file is absent (`$config['x']` vs `$config['x'] ?? default`).
- Service-provider / DI bindings that assume optional config is present.
- New env vars undocumented in `.env.example`; defaults that differ prod vs test.

## 9. Test-data & fixtures
- Factory states that set one attribute but leave a contradictory sibling (a
  `keyframe()` state with `image/jpeg` mime but a `.mp4` path/extension).
- Fixtures that don't exercise the branch they claim to; seeders with wrong refs.

## 10. PR hygiene (cross-cutting)
- **Description vs diff**: does the code do what the PR/commit says — nothing sneaky extra, nothing promised-but-missing?
- Scope creep: unrelated changes bundled in.
- Public/breaking changes called out in the description.
- Follows the repo's branch/PR conventions (e.g. one task per branch, task id in
  branch name and PR title — check its CLAUDE.md/CONTRIBUTING.md).

## Severity labels (use these in output)
- 🔴 **Blocking** — bug, security hole, or missing test for a changed path. Must fix before merge.
- 🟡 **Should-fix** — correctness risk, perf issue, or maintainability problem worth addressing.
- 🟢 **Nit** — style/naming/minor. Optional.
- 💭 **Question** — intent unclear; ask rather than assert.
