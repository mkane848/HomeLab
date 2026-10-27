#!/usr/bin/env python3
import json, glob, os, re, collections, sys
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'rig')
entries = {e['id']: e for e in json.load(open(os.path.join(os.path.dirname(R), 'entries.all.json')))}
runs = collections.defaultdict(dict)
for f in sorted(glob.glob(R + '/tests/results/tasks-*.json')):
    j = json.load(open(f, encoding='utf-8-sig'))
    runs[j['taskId']][j['modelLabel']] = j          # latest wins (files sorted by stamp)
def tup(j):
    a = j.get('acceptance') or {}
    g = j['gates']
    return (j['writes'], g['scope'], g['suite'], g['failsOnOld'], a.get('status'))
bad = []
print('%-40s %-14s %-14s %-14s %-9s %-11s %s' % ('task', 'dry base/acc', 'ref', 'srconly', 'testsonly', 'variants', 'notes'))
for tid, e in entries.items():
    r = runs.get(tid, {})
    dry = open(f'{R}/out/{tid}.dry.log', errors='replace').read() if os.path.exists(f'{R}/out/{tid}.dry.log') else ''
    m = re.search(r'\[PASS\] baseline.*?\(Tests\s+(\d+) passed \((\d+)\)\)', dry)
    base = '%s/%s' % (m.group(1), m.group(2)) if m else 'MISSING'
    exp = '%d/%d' % (e['baselineExpect']['testsPass'], e['baselineExpect']['testsTotal'])
    dacc = re.search(r'acceptance \(fails on base\)\s+->\s+owner tests @ \S+ \S+ fail on the untouched source: Tests\s+(\d+) failed', dry)
    accdry = ('F%s' % dacc.group(1)) if dacc else ('-' if 'acceptance' not in e else '??')
    ok_dry = (base == exp) and (('acceptance' not in e) or bool(dacc)) and 'dry-run' in dry and 'exit=0' in dry
    ref = r.get('ref'); so = r.get('srconly'); to = r.get('testsonly')
    notes = []
    if not ok_dry: notes.append('DRY PROBLEM base=%s exp=%s' % (base, exp))
    def fmt(j): return '-' if not j else '%s/%s/%s/%s' % tuple(x[0] if x else '?' for x in (j['gates']['scope'], j['gates']['suite'], j['gates']['failsOnOld'], (j.get('acceptance') or {}).get('status') or 'S'))
    # expectations
    if not ref or tup(ref)[1:4] != ('PASS', 'PASS', 'PASS') or ref['writes'] < 1: notes.append('REF NOT ALL PASS')
    if 'acceptance' in e and (not ref or (ref.get('acceptance') or {}).get('status') != 'PASS'): notes.append('REF ACCEPTANCE != PASS')
    if not so or so['gates']['failsOnOld'] != 'FAIL': notes.append('SRCONLY failsOnOld not FAIL')
    if not to or to['gates']['suite'] != 'FAIL' or to['gates']['scope'] != 'FAIL': notes.append('TESTSONLY not scope+suite FAIL')
    vlabels = ['ref.unset', 'ref.dummy', 'ref.tz', 'ref.det1', 'ref.det2', 'ref.det3']
    same = [v for v in vlabels if v in r and ref and tup(r[v]) == tup(ref)]
    diff = [v for v in vlabels if v in r and ref and tup(r[v]) != tup(ref)]
    miss = [v for v in vlabels if v not in r]
    if diff: notes.append('VARIANTS DIFFER: ' + ','.join(diff))
    if miss: notes.append('MISSING: ' + ','.join(miss))
    if so and so['gates']['suite'] == 'FAIL': notes.append('srconly also fails the suite (spec reversal)')
    print('%-40s %-14s %-14s %-14s %-9s %-11s %s' % (tid[:40], '%s/%s' % (base, accdry), fmt(ref), fmt(so), fmt(to), '%d/6 same' % len(same), '; '.join(notes)))
    if any(n.split(':')[0] in ('REF NOT ALL PASS', 'REF ACCEPTANCE != PASS', 'SRCONLY failsOnOld not FAIL', 'TESTSONLY not scope+suite FAIL', 'VARIANTS DIFFER') or n.startswith('DRY') or n.startswith('MISSING') for n in notes):
        bad.append(tid)
print('\nlegend: scope/suite/failsOnOld/acceptance (P=PASS F=FAIL S=SKIP)')
print('tasks needing attention:', bad or 'none')
