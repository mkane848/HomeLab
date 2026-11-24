#!/usr/bin/env bash
# lane.sh ID... : every arm for each task, sequentially. Logs in logs/<arm>/<id>.log, rows in results/<arm>/.
M=/tmp/claude-0/-home-user-HomeLab/782e04ff-fa86-5326-8d62-53344bef5c9a/scratchpad/mining; RIG=$M/rig; cd $RIG
export PATH=$RIG/bin:$PATH RIG_PATCHES=$M/patches
arm() {  # arm-name mode extra-env...
  local name=$1 mode=$2; shift 2; mkdir -p logs/$name results/$name
  local dry=""; [ "$mode" = dry ] && dry="-DryRun"
  env RIG_MODE=$mode "$@" timeout 1200 pwsh -NoProfile -File tests/test-tasks.ps1 -Task $id -Model fixture/m -NoGpuCheck $dry \
    -ResultsDir $RIG/results/$name > logs/$name/$id.log 2>&1
  echo "$id $name exit=$?"
}
for id in "$@"; do
  arm dry dry
  arm ref ref
  arm srconly srconly
  arm testsonly testsonly
  arm dummy ref DATABASE_URL=postgres://u:p@127.0.0.1:9/x MANAPOOL_API_KEY=dummy-key
  arm auckland ref TZ=Pacific/Auckland
  arm repeat ref
done
