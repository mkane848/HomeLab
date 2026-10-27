#!/bin/bash
# runall.sh "<task ids>" "<modes>"   (modes: dry ref srconly testsonly) ; sequential
cd "$(dirname "$0")/rig"
for t in $1; do
  for m in $2; do
    s=$(date +%s)
    if [ "$m" = dry ]; then ./run.sh $t ref dry; else ./run.sh $t $m; fi
    echo "   ($(( $(date +%s) - s ))s)"
  done
done
