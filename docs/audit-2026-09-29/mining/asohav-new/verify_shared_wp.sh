#!/usr/bin/env bash
# usage: verify_shared_wp.sh <label> <parent> <fixsha> <src-file>...
# Fresh worktree at <parent>; npm ci --ignore-scripts; run packages/shared suite (red-by-design expected);
# then check out ONLY the listed source files from <fixsha> (tests untouched) and run again.
set -u
ROOT=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/mine-asohav-new
label=$1; parent=$2; fix=$3; shift 3
cd "$ROOT/repo" && git worktree add "../wt/$label" "$parent" >/dev/null 2>&1
cd "$ROOT/wt/$label" || exit 1
echo "worktree $label HEAD=$(git rev-parse HEAD)"
npm ci --ignore-scripts 2>&1 | grep -E "^added"
cd packages/shared
echo "== PARENT $parent: shared suite"
npx vitest run 2>&1 | grep -E "^ (❯|×)|Test Files|      Tests " | grep -v "^ ❯ .*:[0-9]*:[0-9]*$" | head -40
cd ../..
git checkout "$fix" -- "$@"
git status --short
cd packages/shared
echo "== after checking out from $fix: $*"
npx vitest run 2>&1 | grep -E "^ (❯|×)|Test Files|      Tests " | head -20
npx tsc -p tsconfig.json --noEmit; echo "shared tsc exit: $?"
