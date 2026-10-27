#!/usr/bin/env bash
# Mutation check: each mutant must make tests/test-task-pins.ps1 fail.
set -u
T=/home/user/HomeLab/tests
D=/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/verify/mutp
rm -rf "$D"; mkdir -p "$D"

run() {  # name, then extra args for the test
  local name="$1"; shift
  out=$(pwsh -NoProfile -File $T/test-task-pins.ps1 "$@" 2>&1)
  code=$?
  echo "== $name: exit=$code  $(echo "$out" | grep -c '^FAIL') FAIL line(s)"
  echo "$out" | grep '^FAIL' | sed 's/^/     /' | head -4
}

# --- harness mutants (test-tasks.ps1 is CRLF: patterns avoid line-end anchors)
sed 's/\$pin = \$Task.benchBaseCommit/$pin = $null/' $T/test-tasks.ps1 > $D/m1.ps1
sed 's/return \[pscustomobject\]@{ Head = \$full; Ref = \$full; Source = "pin"/return [pscustomobject]@{ Head = $tip; Ref = $tip; Source = "pin"/' $T/test-tasks.ps1 > $D/m2.ps1
sed 's/\$warning = "local branch \$(\$Task.branch)/$warning = $null; $unused = "local branch $($Task.branch)/' $T/test-tasks.ps1 > $D/m3.ps1
sed 's/    if (-not \$full) {/    if ($false) {/' $T/test-tasks.ps1 > $D/m4.ps1
sed 's/if (-not \$acc.commit) {/if ($true) {/' $T/test-tasks.ps1 > $D/m12.ps1
# --- publish-check mutants
sed 's/^        return "unpublished"/        return "published"/' $T/run-tasks-batch.ps1 > $D/m5.ps1
sed 's/if (\$LASTEXITCODE -ne 0) { return "unknown" }/if ($LASTEXITCODE -ne 0) { return "unpublished" }/' $T/run-tasks-batch.ps1 > $D/m6.ps1
# the trap: ask from INSIDE the clone that already has the commit
sed 's/& git -C \$tmp fetch -q --depth=1 --filter=blob:none o \$Commit \*> \$null/\& git -C $Repo fetch -q origin $Commit *> $null/' $T/run-tasks-batch.ps1 > $D/m10.ps1
# no second question: only the remote-tracking branches
sed 's/^        if (\$LASTEXITCODE -eq 0) { return "published" }/        if ($false) { return "published" }/' $T/run-tasks-batch.ps1 > $D/m11.ps1
for m in m1 m2 m3 m4 m12; do cmp -s $T/test-tasks.ps1 $D/$m.ps1 && echo "!! $m identical (sed did not match)"; done
for m in m5 m6 m10 m11; do cmp -s $T/run-tasks-batch.ps1 $D/$m.ps1 && echo "!! $m identical (sed did not match)"; done

# --- data mutants
python3 - <<EOF
import json, glob, os, shutil
m = json.load(open('$T/tasks/manifest.json', encoding='utf-8'))
m['tasks'][0]['benchBaseCommit'] = 'f' * 40
json.dump(m, open('$D/manifest-rebased.json', 'w'), indent=2)
m = json.load(open('$T/tasks/manifest.json', encoding='utf-8'))
m['tasks'][1]['benchBaseCommit'] = m['tasks'][1]['benchBaseCommit'][:12]
json.dump(m, open('$D/manifest-short.json', 'w'), indent=2)
m = json.load(open('$T/tasks/manifest.json', encoding='utf-8'))
for t in m['tasks']:
    if t.get('acceptance'): t['acceptance']['commit'] = t['acceptance']['commit'][:10]
json.dump(m, open('$D/manifest-accshort.json', 'w'), indent=2)
lines = open('$T/results/tasks-summary.tsv', encoding='utf-8-sig').read().split('\n')
head = lines[0].split('\t'); ci = head.index('baseCommit')
parts = lines[5].split('\t'); parts[ci] = '0' * 40; lines[5] = '\t'.join(parts)
open('$D/summary-otherbase.tsv', 'w', encoding='utf-8').write('\n'.join(lines))
# a results dir whose lfc-03 acceptance runs include one from another commit
os.makedirs('$D/results', exist_ok=True)
n = 0
for p in sorted(glob.glob('$T/results/tasks-lfc-03-*.json')):
    d = json.load(open(p, encoding='utf-8-sig'))
    if d.get('acceptance', {}).get('commit'):
        if n == 3: d['acceptance']['commit'] = 'a' * 40
        n += 1
    json.dump(d, open(os.path.join('$D/results', os.path.basename(p)), 'w'))
EOF

run "M1  base pin ignored (branch tip used)"          -ScriptPath $D/m1.ps1
run "M2  pin resolved but the tip is run"             -ScriptPath $D/m2.ps1
run "M3  no warning when the branch moved"            -ScriptPath $D/m3.ps1
run "M4  missing pin not an error"                    -ScriptPath $D/m4.ps1
run "M12 acceptance pin ignored"                      -ScriptPath $D/m12.ps1
run "M5  no-remote-has-it reads as published"         -BatchPath $D/m5.ps1
run "M6  unreachable origin reads as unpublished"     -BatchPath $D/m6.ps1
run "M10 asks from inside the clone (the trap)"       -BatchPath $D/m10.ps1
run "M11 no second question (PR ref / single-branch)" -BatchPath $D/m11.ps1
run "M7  a task re-based to another commit"           -ManifestPath $D/manifest-rebased.json
run "M8  an abbreviated base pin"                     -ManifestPath $D/manifest-short.json
run "M13 an abbreviated acceptance pin"               -ManifestPath $D/manifest-accshort.json
run "M9  a corpus row from another base"              -SummaryPath $D/summary-otherbase.tsv
run "M14 an acceptance run from another commit"       -ResultsDir $D/results
run "REAL (control)"
