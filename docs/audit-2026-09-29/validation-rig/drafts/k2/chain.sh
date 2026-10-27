#!/bin/bash
# chain.sh <label> <tasks...> : fresh pass (dry ref srconly testsonly), then env matrix, then determinism, per task, sequential
cd "$(dirname "$0")/rig"
label=$1; shift
for t in "$@"; do
  for m in dry ref srconly testsonly; do
    s=$(date +%s)
    if [ "$m" = dry ]; then ./run.sh $t ref dry; else ./run.sh $t $m; fi
    echo "   ($(( $(date +%s) - s ))s)"
  done
done
for t in "$@"; do
  RIG_TAG=ambient ./run.sh $t ref
  RIG_TAG=unset RIG_UNSET="MANAPOOL_API_KEY DATABASE_URL" ./run.sh $t ref
  RIG_TAG=dummy RIG_ENV="DATABASE_URL=postgres://u:p@127.0.0.1:9/x MANAPOOL_API_KEY=dummy-key" ./run.sh $t ref
  RIG_TAG=tz RIG_ENV="TZ=Pacific/Auckland" ./run.sh $t ref
done
for t in "$@"; do
  for i in 1 2 3; do RIG_TAG=det$i ./run.sh $t ref; done
done
echo "CHAIN $label DONE"
