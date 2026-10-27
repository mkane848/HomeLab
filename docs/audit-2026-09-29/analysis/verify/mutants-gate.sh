#!/usr/bin/env bash
# Mutation check on the WIRING (main-loop gate block): each mutant must fail tests/test-cap-hit.ps1.
set -u
SRC=/home/user/HomeLab/tests/test-tasks.ps1
D=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/verify/mut
mkdir -p "$D"

run() {
  out=$(pwsh -NoProfile -File /home/user/HomeLab/tests/test-cap-hit.ps1 -ScriptPath "$2" 2>&1)
  code=$?
  echo "== $1: exit=$code  $(echo "$out" | grep -c '^FAIL') FAIL line(s)"
  echo "$out" | grep '^FAIL' | sed 's/^/     /'
}

# M5: typo in the limit variable passed to the classifier (silent: limit becomes $null)
sed 's/Test-OutputCapHit -Ending \$run.Ending -Limit \$outputLimit/Test-OutputCapHit -Ending $run.Ending -Limit $outputLimt/' "$SRC" > "$D/m5.ps1"
# M6: the cap branch never taken
sed 's/^        if (\$capHit) {\r$/        if ($false) {\r/' "$SRC" > "$D/m6.ps1"
# M7: the truncated (unconfirmed) branch removed -> falls through to liar mode
sed 's/^        } elseif (\$run.Ending.FinishReason -eq "length" -and -not \$run.Ending.LastStepHadContent) {\r$/        } elseif ($false) {\r/' "$SRC" > "$D/m7.ps1"
# M8: the cap note on a run that made edits dropped
sed 's/^        if (\$capHit) { \$writeNote +=.*$//' "$SRC" > "$D/m8.ps1"
for m in m5 m6 m7 m8; do cmp -s "$SRC" "$D/$m.ps1" && echo "!! $m is identical to the source (sed did not match)"; done

run "M5 limit variable typo" "$D/m5.ps1"
run "M6 cap branch dead" "$D/m6.ps1"
run "M7 truncated branch dead" "$D/m7.ps1"
run "M8 no cap note after edits" "$D/m8.ps1"
run "REAL harness (control)" "$SRC"
