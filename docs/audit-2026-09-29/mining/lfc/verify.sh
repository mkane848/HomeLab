#!/usr/bin/env bash
# verify.sh - protocol runner for one candidate, in a FRESH worktree at the PARENT.
#
#   verify.sh NAME PARENT FIXSHA "TEST_FILES" "SRC_FILES" "SCOPED_VITEST_ARGS" ["INSTALL_FLAGS"]
#
# Steps (each logged to logs/NAME/*.log; summary appended to verification.md):
#   0. git worktree add --detach wt/NAME PARENT      (refuses to reuse an existing dir)
#   1. npm ci <flags>  (default --ignore-scripts)
#   2. baseline: scoped run + full suite            -> baseline N/N
#   3. apply ONLY the fix commit's TEST_FILES       -> red x/y (scoped)
#   4. apply the fix commit's SRC_FILES             -> green (scoped + full)
# MANAPOOL_API_KEY is always unset for test runs (known env-sensitive test).
set -u
ROOT=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/mine-lfc
NAME=$1; PARENT=$2; FIX=$3; TESTS=$4; SRCS=$5; SCOPED=$6; FLAGS=${7:---ignore-scripts}
WT=$ROOT/wt/$NAME
LOG=$ROOT/logs/$NAME
VER=$ROOT/verification.md
mkdir -p "$LOG"

strip() { sed 's/\x1b\[[0-9;]*m//g'; }
summ() { strip < "$1" | grep -E "^\s*(Test Files|Tests)\s" ; }
failnames() { strip < "$1" | grep -E "^\s+(×|✗)|^ FAIL " | sed 's/^ *//' | head -${2:-40}; }

if [ -e "$WT" ]; then echo "REFUSING: $WT already exists (fresh worktree required)"; exit 2; fi
git -C "$ROOT/repo" worktree add --detach "$WT" "$PARENT" > "$LOG/00-worktree.log" 2>&1 || { echo "worktree add failed"; cat "$LOG/00-worktree.log"; exit 3; }
HEADSHA=$(git -C "$WT" rev-parse HEAD)
echo "worktree $NAME @ $HEADSHA (expected parent $PARENT)"
cd "$WT" || exit 4
git status --porcelain --ignored | head -3 > "$LOG/00-clean-check.log"

{
  echo
  echo "## $NAME  (fix $FIX, parent $PARENT)"
  echo
  echo "- worktree: fresh \`git worktree add --detach\` at parent \`$HEADSHA\`; \`${NPMCMD:-npm} ci $FLAGS\`; run $(date -u +%Y-%m-%dT%H:%MZ)"
  echo "- scoped test cmd: \`env -u MANAPOOL_API_KEY npx vitest run $SCOPED\`"
  echo "- test files taken from fix commit: \`$TESTS\`"
  echo "- src files taken from fix commit: \`$SRCS\`"
} >> "$VER"

# 1. install
NPMCMD=${NPMCMD:-npm}
( time $NPMCMD ci $FLAGS ) > "$LOG/01-install.log" 2>&1
echo "npm ci exit: $?" | tee -a "$LOG/01-install.log" | tail -1
ls node_modules/better-sqlite3/prebuilds 2>/dev/null | tr '\n' ' ' > "$LOG/01-prebuilds.log"

run() { # name, args...
  local n=$1; shift
  NO_COLOR=1 env -u MANAPOOL_API_KEY npx vitest run "$@" > "$LOG/$n.log" 2>&1
  echo "$n exit=$?"
}

# 2. baseline
run 02-baseline-scoped $SCOPED
run 02-baseline-full
# 3. red
git checkout "$FIX" -- $TESTS > "$LOG/03-apply-tests.log" 2>&1
git status --short > "$LOG/03-status-after-tests.log"
run 03-red-scoped $SCOPED
run 03-red-full
# 4. green
git checkout "$FIX" -- $SRCS > "$LOG/04-apply-src.log" 2>&1
git status --short > "$LOG/04-status-after-src.log"
run 04-green-scoped $SCOPED
run 04-green-full

{
  echo "- prebuilds shipped by better-sqlite3 tarball: $(cat "$LOG/01-prebuilds.log")"
  echo
  echo '```'
  echo "# baseline (parent, scoped)";       summ "$LOG/02-baseline-scoped.log"
  echo "# baseline (parent, FULL suite)";   summ "$LOG/02-baseline-full.log"
  echo "# RED: fix's test files only on unfixed source (scoped)"; summ "$LOG/03-red-scoped.log"
  failnames "$LOG/03-red-scoped.log" 30
  echo "# RED (FULL suite)";                summ "$LOG/03-red-full.log"
  echo "# GREEN: fix src applied (scoped)"; summ "$LOG/04-green-scoped.log"
  echo "# GREEN (FULL suite)";              summ "$LOG/04-green-full.log"
  echo '```'
} >> "$VER"
echo "--- done; see $VER"
