#!/bin/bash
# mkpatch.sh REPO_CLONE PARENT FIX OUTDIR TASKID "src files..." "test files..."
#   writes OUTDIR/TASKID.src.patch and OUTDIR/TASKID.test.patch = `git diff PARENT FIX -- files` (binary-safe, LF)
set -e
repo=$1; parent=$2; fix=$3; out=$4; id=$5; srcs=$6; tests=$7
mkdir -p "$out"
git -C "$repo" diff --binary --no-color "$parent" "$fix" -- $srcs  > "$out/$id.src.patch"
git -C "$repo" diff --binary --no-color "$parent" "$fix" -- $tests > "$out/$id.test.patch"
wc -l "$out/$id.src.patch" "$out/$id.test.patch"
