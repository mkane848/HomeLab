#!/bin/bash
# run.sh <taskId> <mode> [dry]
#   mode: ref | srconly | testsonly   (what the stand-in "model" does; ignored for dry)
#   dry : -DryRun (worktree + install + baseline [+ acceptance-on-base]); no model step
# Extra environment for the gates AND the "model" process: RIG_ENV="A=1 B=2" ./run.sh ...
#   RIG_UNSET="NAME1 NAME2" unsets variables first; RIG_TAG=foo suffixes the log and the result label (out/<id>.<mode>.foo.log)
# Output: out/<taskId>.<mode>.log ; the harness's result JSON lands in tests/results/
set -u
RIG=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/rig/a1/rig
REF=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/rig/a1/rig/ref
id=$1; mode=${2:-ref}; dry=${3:-}
cd "$RIG"
export PATH="$RIG/bin:$PATH" RIG_MODE="$mode" RIG_REF="$REF" TEMP="$RIG/tmp"
mkdir -p "$TEMP"
for v in ${RIG_UNSET:-}; do unset "$v"; done
for kv in ${RIG_ENV:-}; do export "$kv"; done
tag="$mode${RIG_TAG:+.$RIG_TAG}"
args=(-NoProfile -File tests/test-tasks.ps1 -Task "$id" -Model rig/standin -ModelLabel "$tag" -RunTimeout 900 -CommandTimeout 600)
if [ "$dry" = "dry" ]; then args+=(-DryRun); tag="dry${RIG_TAG:+.$RIG_TAG}"; fi
pwsh "${args[@]}" > "out/$id.$tag.log" 2>&1
code=$?
echo "exit=$code" >> "out/$id.$tag.log"
echo "$id $tag exit=$code"
exit $code
