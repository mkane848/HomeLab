#!/usr/bin/env bash
# fullsuite.sh ID WTNAME SUITEDIR: whole-package suite at the parent, then with the reference patches
ID=$1; WT=wt/$2; SD=$3; PD=$PWD/patches
cd $WT; P=$(git rev-parse HEAD); git checkout -q $P -- . 
s(){ (cd $SD && env -u DATABASE_URL -u MANAPOOL_API_KEY npx vitest run 2>&1 | grep -E "^\s+Tests " | sed 's/\x1b\[[0-9;]*m//g' | tr -s ' '); }
b=$(s); git apply $PD/$ID.src.patch $PD/$ID.tests.patch || { echo "$ID APPLY FAILED"; exit 1; }
r=$(s); fails=$(cd $SD && env -u DATABASE_URL -u MANAPOOL_API_KEY npx vitest run 2>&1 | grep -E "^\s+×" | head -3)
echo "$ID | base:$b | ref:$r"; [ -n "$fails" ] && echo "$fails"
git checkout -q $P -- .; git clean -qfd -e node_modules
