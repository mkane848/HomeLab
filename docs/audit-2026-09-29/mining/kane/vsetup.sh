#!/bin/bash
# usage: vsetup.sh <name> <parent-sha>
# Creates a FRESH detached worktree at <parent-sha> (never reused), installs with the manifest's installFlags.
set -u
S=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/mine-kane
name=$1; parent=$2
cd $S/repo || exit 1
if [ -e "$S/wt/$name" ]; then echo "worktree $name already exists - refusing to reuse"; exit 2; fi
git worktree add --detach "$S/wt/$name" "$parent" 2>&1 | tail -1
cd "$S/wt/$name" || exit 1
echo "HEAD=$(git rev-parse HEAD)"; git status --short | head -3
( time pnpm install --frozen-lockfile --ignore-scripts --store-dir $S/pnpm-store ) > $S/logs/$name.install.log 2>&1
echo "install exit=$? (log: logs/$name.install.log)"; tail -4 $S/logs/$name.install.log | head -3
