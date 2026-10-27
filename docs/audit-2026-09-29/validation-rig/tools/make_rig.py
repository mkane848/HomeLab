#!/usr/bin/env python3
"""Build a validation rig around the REAL tests/test-tasks.ps1.

  make_rig.py --out RIGDIR --fragment entries.json --repos REPOSDIR [--ref REFDIR]

* RIGDIR/tests/test-tasks.ps1        copy of /home/user/HomeLab/tests/test-tasks.ps1 (re-copied every call)
* RIGDIR/tests/tasks/manifest.json   {"tasks": [...]} from the fragment, `repo` rewritten to the clones in REPOSDIR
* RIGDIR/bin/opencode + standin.ps1  a stand-in `opencode` that "makes the model's change" by applying
                                     REFDIR/<taskId>.src.patch and/or .test.patch according to $RIG_MODE
* RIGDIR/run.sh <taskId> <mode> [dry]  runs the real harness; see tools/README.md
"""
import argparse, json, os, shutil, stat, sys

HARNESS = '/home/user/HomeLab/tests/test-tasks.ps1'
HERE = os.path.dirname(os.path.abspath(__file__))
REPO_MAP = {
    'C:/Projects/KaneEnabler': 'KaneEnabler',
    'M:/Projects/LFCbot': 'lfc-bot',
    'M:/TTRPG/A Story of Heroes and Villains': 'ASoHaVCompanionApp',
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--fragment', required=True)
    ap.add_argument('--repos', required=True)
    ap.add_argument('--ref', default=None)
    a = ap.parse_args()
    out = os.path.abspath(a.out)
    repos = os.path.abspath(a.repos)
    ref = os.path.abspath(a.ref) if a.ref else os.path.join(out, 'ref')
    for d in ('tests/tasks', 'bin', 'out', 'ref'):
        os.makedirs(os.path.join(out, d), exist_ok=True)
    shutil.copyfile(HARNESS, os.path.join(out, 'tests', 'test-tasks.ps1'))
    entries = json.load(open(a.fragment, encoding='utf-8'))
    if isinstance(entries, dict):
        entries = entries['tasks']
    for e in entries:
        key = e['repo']
        if key not in REPO_MAP:
            sys.exit('unknown repo path in entry %s: %r' % (e.get('id'), key))
        e['repo'] = os.path.join(repos, REPO_MAP[key])
        if not os.path.isdir(e['repo']):
            sys.exit('rig clone missing: %s (git clone --local the upstream mirror there first)' % e['repo'])
    json.dump({'tasks': entries}, open(os.path.join(out, 'tests', 'tasks', 'manifest.json'), 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
    shutil.copyfile(os.path.join(HERE, 'standin.ps1'), os.path.join(out, 'bin', 'standin.ps1'))
    launcher = os.path.join(out, 'bin', 'opencode')
    open(launcher, 'w').write('#!/bin/sh\nexec pwsh -NoProfile -File "%s/bin/standin.ps1" "$@"\n' % out)
    os.chmod(launcher, os.stat(launcher).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    run = os.path.join(out, 'run.sh')
    open(run, 'w').write(open(os.path.join(HERE, 'run.sh.tmpl')).read().replace('@RIG@', out).replace('@REF@', ref))
    os.chmod(run, 0o755)
    print('rig ready: %s  (%d tasks)  ref patches: %s' % (out, len(entries), ref))


main()
