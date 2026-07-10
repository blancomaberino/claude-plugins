#!/usr/bin/env bash
#
# pr-gate.sh — PreToolUse(Bash) hook. Blocks `gh pr create|edit|ready|merge|reopen`
# unless /codehare has run clean on the CURRENT commit, and hard-blocks on any
# secret the deterministic scan finds regardless of receipt.
#
# Enforcement model:
#   - The /codehare skill writes a receipt (HEAD SHA) via approve.sh, but ONLY
#     after its 🔴 blocking findings are fixed and committed.
#   - Any new commit moves HEAD, so the receipt goes stale → re-review required.
#
# Hook protocol: reads the tool-call JSON on stdin. Exit 0 = allow; exit 2 =
# block (stderr is shown to the agent). Fail-OPEN for anything that isn't a
# gated `gh pr` command or isn't a git repo; fail-CLOSED once we're gating one.

set -uo pipefail
PY=/usr/bin/python3
[ -x "$PY" ] || PY=python3

RAW="$(cat)"

# --- is this a Bash tool call? pull out the command + effective directory ---
# The gate must inspect the repo the command actually runs in, NOT the hook
# process's inherited cwd. That directory is the payload's `cwd`, further
# adjusted by a leading `cd <dir> &&`/`;` inside the command itself.
# Output: line 1 = effective dir, line 2 = command (newlines flattened).
OUT="$(printf '%s' "$RAW" | "$PY" -c 'import json,sys,re,os
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
if d.get("tool_name")!="Bash": sys.exit(0)
cmd=d.get("tool_input",{}).get("command","") or ""
if not cmd.strip(): sys.exit(0)
cwd=d.get("cwd") or os.getcwd()
m=re.match(r"""\s*cd\s+(?:"([^"]+)"|\x27([^\x27]+)\x27|([^\s;&|]+))\s*(?:&&|;)""", cmd)
if m:
    t=os.path.expanduser(next(g for g in m.groups() if g))
    if not os.path.isabs(t): t=os.path.join(cwd,t)
    if os.path.isdir(t): cwd=t
print(cwd)
print(" ".join(cmd.splitlines()))')"

[ -n "$OUT" ] || exit 0
DIR="$(printf '%s\n' "$OUT" | head -1)"
CMD="$(printf '%s\n' "$OUT" | tail -n +2)"
[ -n "$CMD" ] || exit 0

# --- does the command create/update a PR? -----------------------------------
echo "$CMD" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+(create|edit|ready|merge|reopen)' || exit 0

# From here we are gating a PR command → fail closed.
block() { printf '%s\n' "$1" >&2; exit 2; }

cd "$DIR" 2>/dev/null || exit 0                                  # dir gone → not ours
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0   # not a repo → not ours
cd "$ROOT" || exit 0

DIRTY="$(git status --porcelain --untracked-files=no 2>/dev/null)"
HEAD="$(git rev-parse HEAD 2>/dev/null || echo none)"
RECEIPT="$(git rev-parse --git-path codehare/approved 2>/dev/null)"
APPROVED="$( [ -f "$RECEIPT" ] && tr -d '[:space:]' < "$RECEIPT" || echo '' )"

# --- deterministic secret backstop (blocks regardless of receipt) -----------
if command -v gitleaks >/dev/null 2>&1; then
  base=""
  for b in origin/main main origin/master master; do git rev-parse --verify -q "$b" >/dev/null && { base="$b"; break; }; done
  if [ -n "$base" ]; then
    mb="$(git merge-base "$base" HEAD 2>/dev/null)"
    if [ -n "$mb" ] && ! gitleaks detect --source . --no-banner --redact --log-opts="$mb..HEAD" >/tmp/cr-gitleaks.$$ 2>/dev/null; then
      msg="$(sed 's/^/    /' /tmp/cr-gitleaks.$$ 2>/dev/null | head -40)"; rm -f /tmp/cr-gitleaks.$$
      block "🔴 BLOCKED: gitleaks found a potential secret in this branch's diff.
Do not open/update the PR until it is removed and history is clean.

$msg

Run: gitleaks detect --source . --log-opts=\"$mb..HEAD\"  to see full detail."
    fi
    rm -f /tmp/cr-gitleaks.$$
  fi
fi

# --- receipt / clean-tree enforcement ---------------------------------------
if [ -n "$DIRTY" ]; then
  block "⛔ CodeHare gate: uncommitted changes present, so the review can't cover what the PR will contain.
Commit everything, then run /codehare (fix any 🔴 blockers), then retry the PR command."
fi

if [ "$APPROVED" = "$HEAD" ] && [ "$HEAD" != "none" ]; then
  exit 0   # ✅ reviewed & approved on this exact commit
fi

if [ -z "$APPROVED" ]; then
  block "⛔ CodeHare gate: this branch has not passed /codehare review.
Before creating or updating the PR you MUST:
  1. Run  /codehare   and fix every 🔴 Blocking finding (address 🟡 too, or justify).
  2. Commit the fixes.
  3. The skill records approval for the committed HEAD ($HEAD).
Then retry this command. (Enforced by the codehare plugin's pr-gate hook.)"
else
  block "⛔ CodeHare gate: the approval is stale — it was recorded for a different commit.
  approved: $APPROVED
  current : $HEAD
New commits landed since the last review. Re-run /codehare, fix any findings, and let it re-approve HEAD, then retry."
fi
