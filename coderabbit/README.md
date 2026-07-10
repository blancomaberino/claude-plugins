# coderabbit — self-hosted CodeRabbit-equivalent PR review

A Claude Code plugin that reproduces CodeRabbit's review pipeline locally, for
free — and **enforces** it: a `PreToolUse` hook blocks `gh pr
create|edit|ready|merge|reopen` until the review has run clean on the exact
commit being published.

## What it does

1. **Grounding pass** (`scripts/ground.sh`) — runs the real open-source tool
   fleet, scoped to the diff: gitleaks (secrets), semgrep (SAST), actionlint,
   hadolint, shellcheck, plus debug-leftover heuristics.
2. **Project quality gates** — runs the repo's own lint/static-analysis/tests
   (from its CLAUDE.md, or auto-detected), with a guard
   (`scripts/check-gates-env.sh`) against containerized gates testing the wrong
   checkout.
3. **Grounded LLM review** — fans out subagents over *every* changed file
   against a 10-dimension checklist (`references/review-checklist.md`),
   including cross-file invariants and sibling-pattern consistency. Output
   matches CodeRabbit: `path:line` findings, committable suggestions, 🔴/🟡/🟢/💭
   severities, walkthrough + changes table.
4. **Cross-cutting checks** — tests-for-changed-paths, description⇄diff
   consistency, breaking-change detection. Orchestrates `/security-review` and
   `/simplify` instead of duplicating them.
5. **Enforced approval gate** — after all 🔴 findings are fixed and committed,
   `scripts/approve.sh` writes a receipt for HEAD (in `.git/coderabbit/`, never
   committed). The bundled hook (`hooks/hooks.json` → `scripts/pr-gate.sh`)
   only allows `gh pr …` when the receipt matches HEAD. Any new commit
   invalidates it. gitleaks runs as a deterministic backstop that blocks on
   secrets regardless of receipt.

## Install

```
/plugin marketplace add <path-or-repo-of-this-marketplace>
/plugin install coderabbit@marce-plugins
```

## Recommended companion tools

The skill works without them (it reports skipped coverage), but the full fleet is:

```bash
brew install semgrep gitleaks hadolint actionlint shellcheck ripgrep
```

## Usage

- `/coderabbit` — review the current branch/worktree against `origin/main`
  (falls back to `main`, `origin/master`, `master`).
- `/coderabbit <base-ref>` — review against a different base.
- Mention a PR number to review a specific PR.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `CODERABBIT_GATE_CONTAINER` | `laravel.test` | docker container name filter for the gates-environment check |
| `CODERABBIT_GATE_MOUNT` | `/var/www/html` | code mount point inside that container |

## Notes

- The hook fails **open** for anything that isn't a gated `gh pr` command or
  isn't a git repo, so it won't interfere with other work.
- The approval receipt lives in `.git/coderabbit/approved` — per-clone, never
  pushed, invalidated by any new commit.
- The skill reviews; it never pushes, merges, or advances the default branch.
