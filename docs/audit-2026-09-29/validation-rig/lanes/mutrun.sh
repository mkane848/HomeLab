#!/bin/bash
# mutrun.sh <taskId> <repoClone> <pin> <testDir> '<test cmd>' <mutations.json> [extra setup cmd run in packages/shared]
# Fresh worktree at the pin, reference patches applied, deps installed, then the agents' mutate.py over the mutation list.
set -e
id=$1; clone=$2; pin=$3; tdir=$4; cmd=$5; muts=$6
R=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/rig
wt=$R/final/mut/$id
rm -rf "$wt"; git -C "$clone" worktree prune; git -C "$clone" worktree add -q --detach "$wt" "$pin"
git -C "$wt" apply --whitespace=nowarn $R/final/rig/ref/$id.src.patch $R/final/rig/ref/$id.test.patch
(cd "$wt" && if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile --ignore-scripts >/dev/null 2>&1; else npm ci --ignore-scripts >/dev/null 2>&1; fi)
if [ -n "${7:-}" ]; then (cd "$wt/packages/shared" && eval "$7" >/dev/null 2>&1); fi
env -u DATABASE_URL -u MANAPOOL_API_KEY python3 $R/a1/mutate.py "$wt" "$tdir" "$cmd" "$muts"
