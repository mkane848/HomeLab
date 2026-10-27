#!/usr/bin/env python3
"""ab.py : compare battery 1 (old stash-based harness, sequential) with battery 2 (new harness, six concurrent lanes)."""
import glob, json, os, collections, re, subprocess
def load(root):
    runs = collections.defaultdict(dict)
    for f in sorted(glob.glob(root + '/rig/tests/results/tasks-*.json')):
        j = json.load(open(f, encoding='utf-8-sig'))
        runs[j['taskId']][j['modelLabel']] = j
    return runs
def key(j):
    a = j.get('acceptance') or {}
    g = j['gates']
    return (j['writes'], g['scope'], g['suite'], g['failsOnOld'], a.get('status'), re.sub(r'\s+\d+ms', '', a.get('detail') or ''))
A = load('final'); B = load('final2')
ids = [e['id'] for e in json.load(open('final/entries.all.json'))]
bad = 0; n = 0
for t in ids:
    for lab in ('ref', 'srconly', 'testsonly', 'ref.det1'):
        a = A[t].get(lab if lab != 'ref.det1' else 'ref.det1'); b = B[t].get(lab)
        n += 1
        if not a or not b:
            print('MISSING', t, lab, bool(a), bool(b)); bad += 1; continue
        if key(a) != key(b):
            print('DIFF', t, lab, '\n   old:', key(a), '\n   new:', key(b)); bad += 1
print('compared', n, 'runs; differences:', bad)
# warnings in battery-2 logs
warn = 0
for f in glob.glob('final2/rig/out/*.log'):
    txt = open(f, errors='replace').read()
    for line in txt.splitlines():
        if '[WARN]' in line or 'stash' in line.lower():
            warn += 1; print('WARN LINE', os.path.basename(f), line.strip()[:200])
print('WARN/stash lines in battery-2 logs:', warn)
for r in ('KaneEnabler', 'lfc-bot', 'ASoHaVCompanionApp'):
    p = subprocess.run(['git', '-C', f'final2/repos/{r}', 'stash', 'list'], capture_output=True, text=True)
    print('stash list', r, '->', repr(p.stdout.strip()))
