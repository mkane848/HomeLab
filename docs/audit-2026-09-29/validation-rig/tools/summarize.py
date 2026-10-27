#!/usr/bin/env python3
"""summarize.py RIGDIR [taskId ...]  -> one line per harness run (latest JSON per task+label) + gate/acceptance detail."""
import glob, json, os, sys
rig = sys.argv[1]
ids = set(sys.argv[2:])
rows = {}
for f in sorted(glob.glob(os.path.join(rig, 'tests', 'results', 'tasks-*.json'))):
    j = json.load(open(f, encoding='utf-8-sig'))
    if ids and j['taskId'] not in ids:
        continue
    rows[(j['taskId'], j['modelLabel'])] = j
for (tid, label), j in sorted(rows.items()):
    g = j['gates']
    acc = j.get('acceptance') or {}
    print('%-42s %-10s writes=%s scope=%s suite=%s failsOnOld=%s typecheck=%s acceptance=%s' % (tid, label, j['writes'], g['scope'], g['suite'], g['failsOnOld'], j['typecheck'], acc.get('status')))
    if acc.get('status') not in (None, 'SKIP'):
        print('    acceptance detail: %s' % (acc.get('detail') or '')[:300])
