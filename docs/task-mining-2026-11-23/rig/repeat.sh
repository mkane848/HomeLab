#!/usr/bin/env bash
# repeat.sh NAME REPO TESTDIR "TESTFILES" "SRCFILES": ref arm x3 plus TZ=Pacific/Auckland, in the existing worktree
NAME=$1; REPO=$2; TESTDIR=$3; TESTFILES=$4; SRCFILES=$5
ROOT=$PWD; W=$ROOT/wt/$NAME; OUT=$ROOT/out/$NAME
FIX=$(sed -n 's/^fix //p' "$OUT/pins"); P=$(sed -n 's/^parent //p' "$OUT/pins")
cd "$W" && git checkout -q "$FIX" -- $TESTFILES $SRCFILES
RUNFILES=""; for f in $TESTFILES; do RUNFILES="$RUNFILES ${f#$TESTDIR/}"; done; [ "$TESTDIR" = "." ] && RUNFILES="$TESTFILES"
res=""
for i in 1 2 3 tz; do
  tzv=UTC; [ $i = tz ] && tzv=Pacific/Auckland
  (cd "$TESTDIR" && env -u DATABASE_URL -u MANAPOOL_API_KEY TZ=$tzv npx vitest run $RUNFILES --reporter=json --outputFile="$OUT/rep$i.json" > /dev/null 2>&1)
  res="$res $(python3 -c "
import json;d=json.load(open('$OUT/rep$i.json'))
dur=max(s['endTime'] for s in d['testResults'])-min(s['startTime'] for s in d['testResults'])
print(f\"{d['numPassedTests']}/{d['numTotalTests']}@{dur/1000:.1f}s\")" 2>/dev/null || echo ERR)"
done
inst=$(for f in AGENTS.md CLAUDE.md; do s=$(git -C "$W" cat-file -s "$P:$f" 2>/dev/null) && echo -n "$f=${s}B "; done)
echo "$NAME:$res | $inst"
git checkout -q "$P" -- . ; git clean -qfd -e node_modules
