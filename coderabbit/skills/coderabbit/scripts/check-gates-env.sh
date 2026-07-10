#!/usr/bin/env bash
#
# check-gates-env.sh — guard against the "gates ran against the wrong checkout"
# trap. A docker-compose container (e.g. Laravel Sail) often mounts ONE working
# copy, but a review runs from a worktree on a different branch. `docker compose
# exec … test` then tests the container's code, not the diff — green gates that
# mean nothing. Run this before trusting containerized gate output.
#
# Config (env vars):
#   CODERABBIT_GATE_CONTAINER — container name filter (default: laravel.test)
#   CODERABBIT_GATE_MOUNT     — code mount point inside it (default: /var/www/html)
#
# Exit 0 always (advisory); prints ✅ when aligned, ⚠️ + guidance when not.

set -uo pipefail

CONTAINER="${CODERABBIT_GATE_CONTAINER:-laravel.test}"
MOUNT="${CODERABBIT_GATE_MOUNT:-/var/www/html}"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
HEAD="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"

command -v docker >/dev/null 2>&1 || { echo "ℹ️  docker not found — run gates however this project runs them."; exit 0; }

CID="$(docker ps --filter "name=$CONTAINER" --format '{{.Names}}' 2>/dev/null | head -1)"
[ -n "$CID" ] || { echo "ℹ️  No running '$CONTAINER' container — if this project's gates run in docker, start it first (Phase 2)."; exit 0; }

SRC="$(docker inspect "$CID" --format "{{range .Mounts}}{{if eq .Destination \"$MOUNT\"}}{{.Source}}{{end}}{{end}}" 2>/dev/null)"
[ -n "$SRC" ] || { echo "ℹ️  Could not read container mount — verify manually which checkout the container runs."; exit 0; }

MROOT="$(git -C "$SRC" rev-parse --show-toplevel 2>/dev/null)"
MHEAD="$(git -C "$SRC" rev-parse HEAD 2>/dev/null)"
MBRANCH="$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null)"

if [ "$MHEAD" = "$HEAD" ]; then
  echo "✅ Container '$CID' mounts the same commit under review ($HEAD) — gates are valid for this diff."
  exit 0
fi

echo "⚠️  GATE MISMATCH — container '$CID' mounts a DIFFERENT checkout than the branch under review."
echo "    reviewing : $HEAD  ($BRANCH)"
echo "    container : ${MHEAD:-unknown}  (${MBRANCH:-unknown})  at ${MROOT:-$SRC}"
echo "    → containerized lint/test will test the container's code, NOT this diff. Do not report those as this branch's gates."
echo "    Fix one of:"
echo "      • git -C \"${MROOT:-$SRC}\" checkout $BRANCH   (coordinate — another session may be using it), or"
echo "      • point the container at this worktree ($ROOT) and restart it."
