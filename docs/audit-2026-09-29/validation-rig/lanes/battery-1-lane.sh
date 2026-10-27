#!/bin/bash
# lane.sh <taskId...> : the full battery for each task, strictly sequential (git stash is repo-global, so one lane per repo clone)
cd "$(dirname "$0")/rig"
for id in "$@"; do
  ./run.sh $id ref dry
  ./run.sh $id ref
  ./run.sh $id srconly
  ./run.sh $id testsonly
  RIG_UNSET="MANAPOOL_API_KEY DATABASE_URL" RIG_TAG=unset ./run.sh $id ref
  RIG_ENV="DATABASE_URL=postgres://u:p@127.0.0.1:9/x MANAPOOL_API_KEY=dummy-key" RIG_TAG=dummy ./run.sh $id ref
  RIG_ENV="TZ=Pacific/Auckland" RIG_TAG=tz ./run.sh $id ref
  for i in 1 2 3; do RIG_TAG=det$i ./run.sh $id ref; done
  echo "TASK DONE $id $(date -u +%H:%M:%S)"
done
echo "LANE DONE $(date -u +%H:%M:%S)"
