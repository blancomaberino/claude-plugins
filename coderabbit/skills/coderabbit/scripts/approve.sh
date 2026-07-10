#!/usr/bin/env bash
#
# approve.sh — record a CodeRabbit approval receipt for the current HEAD.
# Called by the /coderabbit skill as its final step, ONLY when there are no
# unresolved 🔴 Blocking findings. The PR-gate hook (pr-gate.sh) reads this
# receipt and allows `gh pr create|edit|…` only when it matches HEAD.
#
# Refuses if the working tree is dirty — the receipt must describe the exact
# committed state the PR will contain.

set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "approve: not a git repo" >&2; exit 1; }
cd "$ROOT" || exit 1

if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  echo "approve: working tree has uncommitted changes." >&2
  echo "Commit your review fixes first, then approve so the receipt covers the committed state." >&2
  exit 1
fi

HEAD="$(git rev-parse HEAD)"
RECEIPT="$(git rev-parse --git-path coderabbit/approved)"
mkdir -p "$(dirname "$RECEIPT")"
printf '%s\n' "$HEAD" > "$RECEIPT"

echo "✅ CodeRabbit approval recorded for HEAD $HEAD"
echo "   Receipt: $RECEIPT"
echo "   Any new commit invalidates this — re-run /coderabbit after further changes."
