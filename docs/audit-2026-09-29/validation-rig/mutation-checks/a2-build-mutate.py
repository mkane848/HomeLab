#!/usr/bin/env python3
"""mutate.py WORKTREE TESTFILE MUTATIONS.json -- apply each textual mutation to the (already fixed) tree, run vitest, report, restore.
MUTATIONS.json: [{"name":..., "file": "apps/server/src/...", "old": "...", "new": "...", "count": 1}]"""
import json, subprocess, sys, os, re
wt, testfile, mfile = sys.argv[1], sys.argv[2], sys.argv[3]
muts = json.load(open(mfile))
def run():
    p = subprocess.run(['npx', 'vitest', 'run', testfile], cwd=os.path.join(wt, 'apps/server'), capture_output=True, text=True, timeout=300)
    out = p.stdout + p.stderr
    m = re.search(r'Tests\s+(.*)', out)
    failed = re.findall(r'^\s*(?:×|FAIL)\s+(.*)$', out, re.M)
    return (m.group(0).strip() if m else 'no summary'), sorted(set(f.strip() for f in failed if '>' in f))
base = run()
print('BASELINE (fixed tree):', base[0])
for mu in muts:
    path = os.path.join(wt, mu['file'])
    orig = open(path, encoding='utf-8').read()
    n = orig.count(mu['old'])
    if n != mu.get('count', 1):
        print('!! %s: pattern occurs %d times (expected %d) -- skipped' % (mu['name'], n, mu.get('count', 1))); continue
    open(path, 'w', encoding='utf-8', newline='\n').write(orig.replace(mu['old'], mu['new']))
    try:
        summ, failed = run()
    finally:
        open(path, 'w', encoding='utf-8', newline='\n').write(orig)
    print('%-34s -> %s' % (mu['name'], summ))
    for f in failed: print('      x', f[:170])
print('RESTORED:', run()[0])
