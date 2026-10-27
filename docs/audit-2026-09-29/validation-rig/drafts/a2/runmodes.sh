#!/bin/bash
# runmodes.sh "<task ids>" "<modes>"  -- strictly serial (git stash is repo-global across worktrees!)
G=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/rig/a2
cd $G/rig
for t in $1; do for m in $2; do
  if [ "$m" = dry ]; then ./run.sh $t ref dry; else ./run.sh $t $m; fi
done; done
