#!/usr/bin/env bash
#
# ground.sh — CodeRabbit-style "grounding" pass.
#
# Runs the real open-source lint/SAST fleet against the PR diff and prints a
# single Markdown report. The LLM review pass reads this report so its findings
# are grounded in actual tool output instead of guesses.
#
# Usage:  ground.sh [BASE_REF]
#   BASE_REF defaults to origin/main, main, origin/master, master.
#   Diff is BASE...HEAD (merge-base).
#
# Never aborts on findings — a tool reporting problems is the whole point.
# Missing tools are reported as "skipped (not installed)" with an install hint.

set -uo pipefail

BASE_REF="${1:-}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo"; exit 1; }
cd "$REPO_ROOT" || exit 1

# --- resolve base ref -------------------------------------------------------
if [ -z "$BASE_REF" ]; then
  for b in origin/main main origin/master master; do
    if git rev-parse --verify -q "$b" >/dev/null; then BASE_REF="$b"; break; fi
  done
  [ -n "$BASE_REF" ] || BASE_REF="$(git rev-parse HEAD~1 2>/dev/null || git rev-parse HEAD)"
fi
MERGE_BASE="$(git merge-base "$BASE_REF" HEAD 2>/dev/null || echo "$BASE_REF")"

# --- changed files (Added/Copied/Modified/Renamed — no deletions) ----------
# bash 3.2 compatible: no mapfile / associative arrays. Committed range + the
# uncommitted working tree, de-duped via sort -u, kept only if the file exists.
FILES=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -e "$f" ] || continue
  FILES+=("$f")
done < <(
  { git diff --name-only --diff-filter=ACMR "$MERGE_BASE"...HEAD
    git diff --name-only --diff-filter=ACMR HEAD
  } | sort -u
)

have() { command -v "$1" >/dev/null 2>&1; }
# print FILES matching any of the pipe-separated case-globs, one per line.
# A `|` inside a variable is NOT a case alternation separator, so split it
# ourselves. `set -f` stops the globs expanding to real filenames while we split.
match() {
  local f pat patterns
  patterns=$(printf '%s' "$1" | tr '|' ' ')
  set -f
  for f in "${FILES[@]:-}"; do
    [ -n "$f" ] || continue
    for pat in $patterns; do
      # shellcheck disable=SC2254  # unquoted on purpose: $pat IS a glob pattern
      case "$f" in $pat) printf '%s\n' "$f"; break;; esac
    done
  done
  set +f
}

section() { printf '\n## %s\n\n' "$1"; }
# shellcheck disable=SC2016  # backticks are Markdown code spans, not expansions
skip() { printf '_skipped — %s not installed. Install: `%s`_\n' "$1" "$2"; }

echo "# Grounding report"
echo
echo "- Base: \`$BASE_REF\`  (merge-base \`${MERGE_BASE:0:12}\`)"
echo "- Changed files: **${#FILES[@]}**"
if [ "${#FILES[@]}" -eq 0 ]; then echo; echo "_No changed files against base — nothing to ground._"; exit 0; fi
echo
echo '<details><summary>Changed file list</summary>'; echo
printf '%s\n' "${FILES[@]}" | sed 's/^/- /'
echo; echo '</details>'

# ============================================================ SECRETS
section "Secret scan (gitleaks)"
if have gitleaks; then
  # scan only the diff range; gitleaks exits 1 when leaks found
  gitleaks detect --source . --no-banner --redact \
    --log-opts="$MERGE_BASE..HEAD" 2>/dev/null \
    && echo "✅ No secrets detected in the diff." \
    || echo "⚠️  gitleaks reported potential secrets above — verify each."
else
  skip gitleaks "brew install gitleaks"
fi

# ============================================================ SAST
section "Static analysis (semgrep)"
if have semgrep; then
  SG_TARGETS=(); while IFS= read -r l; do [ -n "$l" ] && SG_TARGETS+=("$l"); done < <(match '*.php|*.js|*.jsx|*.ts|*.tsx|*.py|*.go|*.rb')
  if [ "${#SG_TARGETS[@]}" -gt 0 ]; then
    # p/ci = curated low-FP; p/security-audit widens recall (weak hashes, injection,
    # SSRF, etc.) at some FP cost — fine for a human-in-loop review. --error keeps
    # the exit code meaningful so the ✅/⚠️ line is accurate.
    semgrep --config=p/ci --config=p/security-audit --config=p/secrets \
      --metrics=off --quiet --error "${SG_TARGETS[@]}" 2>/dev/null \
      && echo "✅ semgrep: no findings on changed code." \
      || echo "⚠️  semgrep findings above (p/security-audit is higher-recall — triage FPs)."
  else
    echo "_No semgrep-relevant source files changed._"
  fi
else
  skip semgrep "brew install semgrep"
fi

# ============================================================ AST-GREP (structural)
section "Structural lint (ast-grep)"
# ast-grep needs a ruleset (sgconfig.yml) to flag anything; run it only when the
# project ships one. Without rules it has no built-in security pack (unlike
# semgrep), so we don't fabricate findings — we note availability instead.
if have ast-grep || have sg; then
  AG="$(command -v ast-grep || command -v sg)"
  if [ -f sgconfig.yml ] || [ -f sgconfig.yaml ] || [ -d .ast-grep ]; then
    "$AG" scan 2>&1 | tail -40 || true
  else
    echo "_ast-grep installed but no project ruleset (sgconfig.yml) — skipped. semgrep p/security-audit covers the common structural rules._"
  fi
else
  skip ast-grep "brew install ast-grep"
fi

# ============================================================ CI WORKFLOWS
section "GitHub Actions lint (actionlint)"
WF=(); while IFS= read -r l; do [ -n "$l" ] && WF+=("$l"); done < <(match '.github/workflows/*.yml|.github/workflows/*.yaml')
if [ "${#WF[@]}" -eq 0 ]; then echo "_No workflow files changed._"
elif have actionlint; then actionlint "${WF[@]}" && echo "✅ actionlint clean." || echo "⚠️  actionlint findings above."
else skip actionlint "brew install actionlint"; fi

# ============================================================ DOCKERFILES
section "Dockerfile lint (hadolint)"
DF=(); while IFS= read -r l; do [ -n "$l" ] && DF+=("$l"); done < <(match '*Dockerfile*|*.dockerfile')
if [ "${#DF[@]}" -eq 0 ]; then echo "_No Dockerfiles changed._"
elif have hadolint; then for d in "${DF[@]}"; do echo "### $d"; hadolint "$d" || true; done
else skip hadolint "brew install hadolint"; fi

# ============================================================ SHELL
section "Shell lint (shellcheck)"
SH=(); while IFS= read -r l; do [ -n "$l" ] && SH+=("$l"); done < <(match '*.sh|*.bash')
if [ "${#SH[@]}" -eq 0 ]; then echo "_No shell scripts changed._"
elif have shellcheck; then shellcheck "${SH[@]}" && echo "✅ shellcheck clean." || echo "⚠️  shellcheck findings above."
else skip shellcheck "brew install shellcheck"; fi

# ============================================================ HEURISTIC GREP
section "Heuristic pattern scan (changed files)"
# rg is often a shell alias (absent in scripts); grep -nE is always present.
patterns='dd\(|dump\(|var_dump|console\.(log|debug)|debugger;|TODO|FIXME|HACK|XXX|@ts-ignore|eslint-disable|phpcs:ignore|Log::debug|\.only\(|fdescribe|fit\(|binding\.pry|die\('
if [ "${#FILES[@]}" -gt 0 ]; then
  if have rg; then hits="$(rg -n --no-heading -e "$patterns" "${FILES[@]}" 2>/dev/null)"
  else hits="$(grep -nE "$patterns" "${FILES[@]}" 2>/dev/null)"; fi
  if [ -n "$hits" ]; then
    echo "Left-in debug/markers to confirm are intentional:"; echo '```'; echo "$hits"; echo '```'
  else echo "✅ No debug leftovers / suppression markers in changed files."; fi
fi

section "Notes"
echo "- Project gates (lint, static analysis, tests, coverage) run separately via the SKILL workflow — this report is the cross-cutting SAST/secrets/config layer."
echo "- Every ⚠️ above is a *lead*, not a verdict: confirm against the diff before reporting."
