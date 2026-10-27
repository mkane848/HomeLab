#!/bin/bash
# blind_collect.sh <taskId> <outdir> <refdir>  -> writes <refdir>/<taskId>.blind.patch = everything the solver changed (tracked + new files), excluding node_modules/build output
set -e
id=$1; out=$2; ref=$3
cd "$out/$id/work"
git add -A -N . 2>/dev/null || true
git diff --binary --no-color base -- . ':(exclude)node_modules' > "$ref/$id.blind.patch"
git status --porcelain | head -20
wc -l "$ref/$id.blind.patch"
