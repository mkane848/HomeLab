#!/usr/bin/env bash
# verify.sh NAME REPO FIX TESTDIR "TESTFILES" "SRCFILES" [RUNFILES]
#   TESTFILES / SRCFILES: repo-relative paths taken from the fix commit.
#   RUNFILES: paths relative to TESTDIR passed to vitest (default: TESTFILES made relative).
# Arms, like the 2026-10-03 validation rig: baseline (parent), testsonly, ref (fix + tests), srconly.
set -u
NAME=$1; REPO=$2; FIX=$3; TESTDIR=$4; TESTFILES=$5; SRCFILES=$6; RUNFILES=${7:-}
ROOT=/tmp/claude-0/-home-user-HomeLab/782e04ff-fa86-5326-8d62-53344bef5c9a/scratchpad/mining
W=$ROOT/wt/$NAME; OUT=$ROOT/out/$NAME; mkdir -p "$OUT"
R=/home/user/mkane848/$REPO
P=$(git -C "$R" rev-parse "$FIX^")
git -C "$R" worktree remove --force "$W" 2>/dev/null; rm -rf "$W"
git -C "$R" worktree add -q --detach "$W" "$P" || exit 1
cd "$W"
git config core.autocrlf false
{ echo "parent $P"; echo "fix $(git -C "$R" rev-parse "$FIX")"; } > "$OUT/pins"
npm ci --ignore-scripts --no-audit --no-fund > "$OUT/install.log" 2>&1 || { echo "$NAME INSTALL FAILED"; tail -5 "$OUT/install.log"; exit 1; }
if [ -d packages/shared ] && [ "$REPO" = asohavcompanionapp ]; then
  (cd packages/shared && npx tsc -p tsconfig.json) > "$OUT/setup.log" 2>&1 || echo "$NAME setup (shared build) failed"
fi
if [ -z "$RUNFILES" ]; then
  for f in $TESTFILES; do RUNFILES="$RUNFILES ${f#$TESTDIR/}"; done
  [ "$TESTDIR" = "." ] && RUNFILES="$TESTFILES"
fi
run() {  # arm
  (cd "$TESTDIR" && env -u DATABASE_URL -u MANAPOOL_API_KEY npx vitest run $RUNFILES --reporter=json --outputFile="$OUT/$1.json" > "$OUT/$1.log" 2>&1)
  python3 - "$OUT/$1.json" "$1" <<'EOF'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception as e: print(f"  {sys.argv[2]:9} NO RESULT ({e.__class__.__name__})"); sys.exit()
t,p,f=d['numTotalTests'],d['numPassedTests'],d['numFailedTests']
bad=[a['fullName'] for s in d['testResults'] for a in s['assertionResults'] if a['status']=='failed']
loadfail=[s['name'].split('/')[-1] for s in d['testResults'] if s.get('status')=='failed' and not s['assertionResults']]
print(f"  {sys.argv[2]:9} {p}/{t} pass, {f} fail" + (f"  load-fail: {loadfail}" if loadfail else ""))
for b in bad[:8]: print("      x", b[:150])
EOF
}
echo "== $NAME  ($REPO, parent ${P:0:9})"
run baseline
existing=""; for f in $TESTFILES; do git cat-file -e "$P:$f" 2>/dev/null && existing="$existing $f"; done
git checkout -q "$FIX" -- $TESTFILES; run testsonly
git checkout -q "$FIX" -- $SRCFILES; run ref
git checkout -q "$P" -- $existing 2>/dev/null
for f in $TESTFILES; do git cat-file -e "$P:$f" 2>/dev/null || rm -f "$f"; done
run srconly
git checkout -q "$P" -- . ; git clean -qfd -e node_modules
