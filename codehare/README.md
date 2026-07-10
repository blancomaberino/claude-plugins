# codehare 🐇

**A free, self-hosted CodeRabbit-equivalent for Claude Code.** Reviews your
branch/PR the way CodeRabbit does — grounded in real tool output, one finding
per line, committable suggestions — and **enforces** the review: a `PreToolUse`
hook blocks `gh pr create|edit|ready|merge|reopen` until the review has run
clean on the exact commit being published.

(Named *codehare* — same family as the rabbit, but faster and free — to avoid
colliding with anything CodeRabbit ships themselves.)

## What it does

1. **Grounding pass** (`scripts/ground.sh`) — runs the real open-source tool
   fleet, scoped to the diff: gitleaks (secrets), semgrep (SAST), actionlint
   (GitHub workflows), hadolint (Dockerfiles), shellcheck, plus debug-leftover
   heuristics (`dd()`, `console.log`, `.only`, `@ts-ignore`, …).
2. **Project quality gates** — runs the target repo's own
   lint/static-analysis/tests (taken from its CLAUDE.md, or auto-detected from
   `composer.json` / `package.json` / `Makefile`), with a guard
   (`scripts/check-gates-env.sh`) against containerized gates testing the wrong
   checkout.
3. **Grounded LLM review** — fans out subagents over *every* changed file
   against a 10-dimension checklist (`references/review-checklist.md`),
   including cross-file invariants and sibling-pattern consistency. Output
   matches CodeRabbit: `path:line` findings, committable suggestions,
   🔴/🟡/🟢/💭 severities, walkthrough + changes table.
4. **Cross-cutting checks** — tests-for-changed-paths, description⇄diff
   consistency, breaking-change detection. Orchestrates the `/security-review`
   and `/simplify` skills instead of duplicating them.
5. **Enforced approval gate** — after all 🔴 findings are fixed and committed,
   `scripts/approve.sh` writes a receipt for HEAD (in `.git/codehare/`, never
   committed or pushed). The bundled hook (`hooks/hooks.json` →
   `scripts/pr-gate.sh`) only allows `gh pr …` when the receipt matches HEAD —
   any new commit invalidates it. gitleaks also runs as a deterministic
   backstop that blocks on secrets regardless of receipt.

## Installation

### 1. Register the marketplace (once per machine)

Inside any Claude Code session:

```
/plugin marketplace add blancomaberino/claude-plugins
```

(or `/plugin marketplace add /path/to/claude-plugins` for a local clone.)

### 2. Install the plugin

```
/plugin install codehare@marce-plugins
```

Approve the installation when prompted. This registers both the `/codehare`
skill and the PR-gate hook — no manual `settings.json` editing needed.

### 3. Grounding tool fleet — installed automatically

On each run the skill first checks the scanner fleet (gitleaks, semgrep,
actionlint, hadolint, shellcheck, ripgrep) and auto-installs anything missing
via your package manager (brew / apt / dnf / pacman, non-interactive — it never
prompts for a sudo password). If something can't be installed automatically,
the review pauses and asks you to run the exact command it prints, e.g.:

```bash
brew install semgrep gitleaks hadolint actionlint shellcheck ripgrep
```

Set `CODEHARE_AUTO_INSTALL=0` to disable install attempts (check-and-report
only). You can also pre-install the fleet with the command above to skip the
bootstrap entirely.

### 4. Verify

- `/codehare` should appear in your skills list.
- In a git repo with unreviewed commits, asking Claude to run
  `gh pr create` should be blocked by the gate with instructions to run
  `/codehare` first.

To update later: `/plugin marketplace update marce-plugins`. To remove:
`/plugin uninstall codehare@marce-plugins` (this also removes the hook).

## Usage

- `/codehare` — review the current branch/worktree against `origin/main`
  (falls back to `main`, `origin/master`, `master`).
- `/codehare <base-ref>` — review against a different base.
- Mention a PR number to have it check out and review that PR.
- Saying "review this like coderabbit" also triggers the skill.

The flow it enforces: run the review → fix every 🔴 Blocking finding (and 🟡,
or justify deferral) → commit the fixes → the skill records approval for that
HEAD → `gh pr create|edit|…` is allowed.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `CODEHARE_AUTO_INSTALL` | `1` | set to `0` to stop the skill from installing missing scanners (it will just report them) |
| `CODEHARE_GATE_CONTAINER` | `laravel.test` | docker container name filter for the gates-environment check |
| `CODEHARE_GATE_MOUNT` | `/var/www/html` | code mount point inside that container |

Both only matter if the target repo runs its quality gates inside a
docker-compose container (e.g. Laravel Sail); otherwise the check is a no-op.

## Notes

- The hook fails **open** for anything that isn't a gated `gh pr` command or
  isn't a git repo, so it never interferes with other work.
- The gate always resolves the repo **the command actually runs in** — from the
  hook payload's working directory, including a leading `cd /path && gh pr …` —
  never from the hook process's own location. Reviews, receipts, and blocks are
  therefore always scoped to the repo (and worktree) being operated on.
- The approval receipt lives at `.git/codehare/approved` — per-clone, never
  pushed, invalidated by any new commit.
- The skill reviews; it never pushes, merges, or advances the default branch.
