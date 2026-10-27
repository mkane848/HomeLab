#!/usr/bin/env bash
# Mutation check: each mutant of test-tasks.ps1 must make tests/test-cap-hit.ps1 fail.
set -u
SRC=/home/user/HomeLab/tests/test-tasks.ps1
D=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/verify/mut
mkdir -p "$D"

run() {  # name, file
  out=$(pwsh -NoProfile -File /home/user/HomeLab/tests/test-cap-hit.ps1 -ScriptPath "$2" 2>&1)
  code=$?
  echo "== $1: exit=$code  $(echo "$out" | grep -c '^FAIL') FAIL line(s)"
  echo "$out" | grep '^FAIL' | sed 's/^/     /'
}

sed 's/-and -not \$Ending.LastStepHadContent//' "$SRC" > "$D/m1.ps1"
sed 's/-ge \[int\]\$Limit/-gt [int]$Limit/' "$SRC" > "$D/m2.ps1"
sed 's/\$end.FinishReason = \$null; \$end.OutputTokens = \$null; \$end.LastStepHadContent = \$false/$null = 0/' "$SRC" > "$D/m3.ps1"
sed 's/^    return (\$Ending.FinishReason -eq "length".*$/    return $false/' "$SRC" > "$D/m4.ps1"
for m in m1 m2 m3 m4; do cmp -s "$SRC" "$D/$m.ps1" && echo "!! $m is identical to the source (sed did not match)"; done

run "M1 ignore text/tool content in the last step" "$D/m1.ps1"
run "M2 strict > instead of >= at the limit" "$D/m2.ps1"
run "M3 never reset at step_start" "$D/m3.ps1"
run "M4 never report a cap hit (the old behavior)" "$D/m4.ps1"
run "REAL harness (control)" "$SRC"
