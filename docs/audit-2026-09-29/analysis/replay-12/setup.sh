#!/usr/bin/env bash
# Base worktrees at each task's pin, with dependencies installed, for the DP11 replay audit.
set -u
SP=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad
A=$SP/audit12
UP=$SP/upstream
STORE=$SP/mine-kane/pnpm-store
mkdir -p "$A/wt" "$A/logs"

mk() {  # name repo pin
  local name=$1 repo=$2 pin=$3
  if [ -d "$A/wt/$name" ]; then echo "[$name] exists"; return; fi
  git -C "$UP/$repo" worktree add -q --detach "$A/wt/$name" "$pin" && echo "[$name] worktree at ${pin:0:10}"
}

t0=$(date +%s)
mk lfc-03 lfc-bot 4906dc2881d362bda2006d3407e0ba63e005b91b
mk lfc-02 lfc-bot 170b395baf8ad4205f6fb6d409b29c25635e7363
mk kane-02 KaneEnabler 0e9b703047d37e31abbccbda2c9de175ae3e33cb
mk kane-04 KaneEnabler 420372615ef8b95566dc8ab24039c1532830fdbf
mk asohav-02 ASoHaVCompanionApp d83381ad650b3474a50310e0dd3441a03cd89706

for n in lfc-03 lfc-02; do
  echo "[$n] npm ci --ignore-scripts"; (cd "$A/wt/$n" && npm ci --ignore-scripts --no-audit --no-fund > "$A/logs/$n.install.log" 2>&1; echo "   rc=$? ($(( $(date +%s) - t0 ))s)")
done
for n in kane-02 kane-04; do
  echo "[$n] pnpm install --frozen-lockfile --ignore-scripts"; (cd "$A/wt/$n" && pnpm install --frozen-lockfile --ignore-scripts --store-dir "$STORE" > "$A/logs/$n.install.log" 2>&1; echo "   rc=$? ($(( $(date +%s) - t0 ))s)")
done
n=asohav-02
echo "[$n] npm ci --ignore-scripts"; (cd "$A/wt/$n" && npm ci --ignore-scripts --no-audit --no-fund > "$A/logs/$n.install.log" 2>&1; echo "   rc=$? ($(( $(date +%s) - t0 ))s)")
echo "[$n] setup: tsc -p packages/shared"; (cd "$A/wt/$n/packages/shared" && npx tsc -p tsconfig.json > "$A/logs/$n.setup.log" 2>&1; echo "   rc=$? ($(( $(date +%s) - t0 ))s)")
echo done
