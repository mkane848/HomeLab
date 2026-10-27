#!/usr/bin/env bash
# Mutation check: each mutant of run-tasks-batch.ps1 must make tests/test-batch-plan.ps1 fail.
set -u
SRC=/home/user/HomeLab/tests/run-tasks-batch.ps1
D=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/verify/mutb
mkdir -p "$D"

run() {
  out=$(pwsh -NoProfile -File /home/user/HomeLab/tests/test-batch-plan.ps1 -ScriptPath "$2" 2>&1)
  code=$?
  echo "== $1: exit=$code  $(echo "$out" | grep -c '^FAIL') FAIL line(s)"
  echo "$out" | grep '^FAIL' | sed 's/^/     /' | head -6
}

# M1: the default order flipped to back-to-back
sed 's/^        if (\$BackToBack) {$/        if (-not $BackToBack) {/' "$SRC" > "$D/m1.ps1"
# M2: -OnlyMissing ignored
sed 's/if (\$OnlyMissing -and \$Graded\["\$taskId|\$model"\])/if ($false)/' "$SRC" > "$D/m2.ps1"
# M3: drift check inverted
sed 's/if (-not \$now -or \$now -eq \$Expected) { return \$null }/if (-not $now -or $now -ne $Expected) { return $null }/' "$SRC" > "$D/m3.ps1"
# M4: autoupdate:true counted as pinned
sed 's/if (\$a -is \[bool\] -and -not \$a) { return \$true }/if ($a -is [bool]) { return $true }/' "$SRC" > "$D/m4.ps1"
# M5: the env flag accepts "yes" (opencode does not)
sed 's/@("true", "1") -contains/@("true", "1", "yes") -contains/' "$SRC" > "$D/m5.ps1"
# M6: any output read as a version
sed "s/if (\$out -match '^\\\\d+\\\\.\\\\d+\\\\.\\\\d+') { return \$out }/if (\$out) { return \$out }/" "$SRC" > "$D/m6.ps1"
# M7: reps loop runs one time too few in the rep-outer branch
sed 's/^            for (\$r = 1; \$r -le \$Reps; \$r++) {$/            for ($r = 1; $r -lt $Reps; $r++) {/' "$SRC" > "$D/m7.ps1"
for m in m1 m2 m3 m4 m5 m6 m7; do cmp -s "$SRC" "$D/$m.ps1" && echo "!! $m is identical to the source (sed did not match)"; done

run "M1 default order flipped to back-to-back" "$D/m1.ps1"
run "M2 -OnlyMissing ignored" "$D/m2.ps1"
run "M3 drift comparison inverted" "$D/m3.ps1"
run "M4 autoupdate:true counted as pinned" "$D/m4.ps1"
run "M5 env flag accepts 'yes'" "$D/m5.ps1"
run "M6 any output read as a version" "$D/m6.ps1"
run "M7 rep-outer loop off by one" "$D/m7.ps1"
run "REAL script (control)" "$SRC"
