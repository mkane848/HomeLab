#!/usr/bin/env python3
"""summarize.py: one row per task, one column per arm, the gate verdicts each run printed."""
import os, re
RIG = os.path.dirname(os.path.abspath(__file__))
ARMS = ['dry', 'ref', 'srconly', 'testsonly', 'dummy', 'auckland', 'repeat']
SHORT = {'baseline': 'base', 'acceptance (fails on base)': 'accOld', 'dry-run': 'dry', 'opencode run': 'run', 'writes gate': 'writes',
         'scope': 'scope', 'suite': 'suite', 'fails-on-old': 'fOO', 'typecheck (scoped)': None, 'acceptance (informational)': 'acc'}
ids = sorted({f[:-4] for a in ARMS if os.path.isdir(f'{RIG}/logs/{a}') for f in os.listdir(f'{RIG}/logs/{a}')})
def verdicts(arm, tid):
    p = f'{RIG}/logs/{arm}/{tid}.log'
    if not os.path.exists(p): return '-'
    out = []
    for m in re.finditer(r'\[(PASS|FAIL|WARN|SKIP)\] ([a-z\- ()]+?)\s+->', open(p, errors='replace').read()):
        k = SHORT.get(m.group(2).strip(), m.group(2).strip())
        if k: out.append(f'{k}:{m.group(1)[0]}')
    return ' '.join(out)
for tid in ids:
    print(tid)
    for a in ARMS: print(f'  {a:9} {verdicts(a, tid)}')
