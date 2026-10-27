#!/bin/bash
# final2 lane: the shortened battery against the NEW (stash-free) harness; several lanes of the SAME repo run at once on purpose
cd "$(dirname "$0")/rig"
for id in "$@"; do
  ./run.sh $id ref
  ./run.sh $id srconly
  ./run.sh $id testsonly
  RIG_TAG=det1 ./run.sh $id ref
  echo "TASK DONE $id $(date -u +%H:%M:%S)"
done
echo "LANE DONE $(date -u +%H:%M:%S)"
