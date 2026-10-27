#!/bin/bash
# blind_setup.sh <taskId> <entries.json> <clone> <outdir>
# Creates <outdir>/<taskId>/work = the pinned base WITHOUT any git history (git archive + fresh init), installs deps and runs the task's setup steps,
# so a blind solver cannot read the upstream fix from history. Prints the environment the gates use.
set -e
id=$1; entries=$2; clone=$3; out=$4
read -r pin pm testdir flags <<<"$(python3 - "$id" "$entries" <<'EOF'
import json,sys
e=[x for x in json.load(open(sys.argv[2])) if x['id']==sys.argv[1]][0]
print(e['benchBaseCommit'], e.get('packageManager','pnpm'), e['testDir'], ' '.join(e['installFlags']))
EOF
)"
w="$out/$id/work"; rm -rf "$out/$id"; mkdir -p "$w"
git -C "$clone" archive "$pin" | tar -x -C "$w"
cd "$w"
git init -q && git add -A && git -c user.email=b@x -c user.name=b commit -qm "base" && git branch -M base
if [ "$pm" = npm ]; then npm ci $flags >/dev/null 2>&1; else pnpm install $flags >/dev/null 2>&1; fi
python3 - "$id" "$entries" <<'EOF' | while IFS= read -r line; do (eval "$line") ; done
import json,sys,shlex
e=[x for x in json.load(open(sys.argv[2])) if x['id']==sys.argv[1]][0]
for s in e.get('setup',[]):
    print('cd %s && %s' % (shlex.quote(s.get('cwd','.')), ' '.join(shlex.quote(c) for c in s['cmd'])))
EOF
echo "ready: $w  (testDir=$testdir)"
