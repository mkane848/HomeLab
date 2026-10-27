#!/bin/bash
# usage: showfix.sh <sha>   -- show message + non-doc diff
cd /tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/mine-kane/repo
git show -s --format='### %H%nparent: %P%ndate: %ad%nsubject: %s%n%n%b' --date=short "$1"
git show --stat --format= -M "$1" | cat
