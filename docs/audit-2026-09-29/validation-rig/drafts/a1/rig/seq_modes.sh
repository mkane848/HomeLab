#!/bin/bash
# sequential four-mode pass (never parallel within one clone: git stash is repo-global)
cd "$(dirname "$0")"
for id in "$@"; do
  for m in ref srconly testsonly; do ./run.sh $id $m; done
done
