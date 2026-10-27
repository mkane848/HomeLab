#!/bin/bash
# usage: vrun.sh <wtname> <fix-sha> <testdir-rel> "<test paths, space separated, repo-relative>" "<src paths, space separated, repo-relative>" <test cmd args...>
# baseline -> (apply fix commit's TEST files only) -> (apply fix commit's SRC files) ; prints the runner summary lines each time.
S=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/mine-kane
wt=$1; fix=$2; tdir=$3; tests=$4; srcs=$5; shift 5
cd $S/wt/$wt || exit 1
echo "### $wt  HEAD=$(git rev-parse --short HEAD)  fix=$fix"
run() { ( cd "$tdir" && "$@" 2>&1 ) | grep -E 'Test Files|Tests |×|✗|AssertionError|TypeError|ReferenceError|Error:|No test files|FAIL' | head -${LINES_MAX:-14}; }
echo "[baseline]";                      run "$@"
for t in $tests; do
  if git cat-file -e $fix:$t 2>/dev/null; then git checkout $fix -- $t; else echo "(test path absent in fix: $t)"; fi
done
echo "[fix commit's test files only, src unfixed]"; run "$@"
for s in $srcs; do git checkout $fix -- $s; done
echo "[+ fix commit's src files]";       run "$@"
git status --short | head
