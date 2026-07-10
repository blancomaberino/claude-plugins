#!/usr/bin/env bash
#
# ensure-tools.sh — make sure the grounding tool fleet is available before the
# review runs. For each missing tool it attempts a non-interactive install via
# the system package manager (brew, apt-get, dnf, pacman), then reports:
#
#   exit 0 — full fleet present (already there or installed now)
#   exit 1 — some tools could not be installed; the report lists the exact
#            command(s) the USER must run. The skill stops and asks them.
#
# Env:
#   CODEHARE_AUTO_INSTALL=0 — never attempt installs, just check and report.

set -uo pipefail

AUTO="${CODEHARE_AUTO_INSTALL:-1}"

have() { command -v "$1" >/dev/null 2>&1; }

# command name → package name (only ripgrep differs)
pkg() { case "$1" in rg) echo "ripgrep";; *) echo "$1";; esac; }

# fallback hint for tools a package manager may not carry
alt_hint() {
  case "$1" in
    semgrep)    echo "pipx install semgrep   (or: pip3 install --user semgrep)" ;;
    gitleaks)   echo "single binary from https://github.com/gitleaks/gitleaks/releases" ;;
    actionlint) echo "go install github.com/rhysd/actionlint/cmd/actionlint@latest" ;;
    hadolint)   echo "single binary from https://github.com/hadolint/hadolint/releases" ;;
    *)          echo "" ;;
  esac
}

MGR=""
if have brew; then MGR="brew"
elif have apt-get; then MGR="apt"
elif have dnf; then MGR="dnf"
elif have pacman; then MGR="pacman"
fi

install_one() {  # $1 = package name
  case "$MGR" in
    brew)   brew install "$1" ;;
    apt)    sudo -n apt-get install -y "$1" ;;
    dnf)    sudo -n dnf install -y "$1" ;;
    pacman) sudo -n pacman -S --noconfirm "$1" ;;
    *)      return 1 ;;
  esac
}

PRESENT=()
INSTALLED=()
MISSING=()

for t in gitleaks semgrep actionlint hadolint shellcheck rg; do
  if have "$t"; then PRESENT+=("$t"); continue; fi
  if [ "$AUTO" = "1" ] && [ -n "$MGR" ]; then
    p="$(pkg "$t")"
    echo "→ $t missing — attempting install via $MGR ($p)…"
    if install_one "$p" >/dev/null 2>&1 && have "$t"; then
      echo "  ✅ installed $t"
      INSTALLED+=("$t")
      continue
    fi
    echo "  ✗ could not install $t via $MGR"
  fi
  MISSING+=("$t")
done

echo
echo "## Tool fleet status"
[ "${#PRESENT[@]}" -gt 0 ]   && echo "- already present: ${PRESENT[*]}"
[ "${#INSTALLED[@]}" -gt 0 ] && echo "- installed now:   ${INSTALLED[*]}"

if [ "${#MISSING[@]}" -eq 0 ]; then
  echo "- ✅ full grounding fleet available."
  exit 0
fi

echo "- ❌ still missing:  ${MISSING[*]}"
[ "$AUTO" != "1" ] && echo "  (auto-install disabled by CODEHARE_AUTO_INSTALL=0)"
echo
echo "ACTION REQUIRED — ask the user to install the missing tools:"
PKGS=""
for t in "${MISSING[@]}"; do PKGS="$PKGS $(pkg "$t")"; done
case "$MGR" in
  brew)   echo "    brew install$PKGS" ;;
  apt)    echo "    sudo apt-get install -y$PKGS" ;;
  dnf)    echo "    sudo dnf install -y$PKGS" ;;
  pacman) echo "    sudo pacman -S$PKGS" ;;
  *)      echo "    (no supported package manager found — install manually)" ;;
esac
for t in "${MISSING[@]}"; do
  h="$(alt_hint "$t")"
  [ -n "$h" ] && echo "    $t alternative: $h"
done
exit 1
