#!/usr/bin/env python3
"""mutate.py WORKTREE TESTCMD_DIR 'npx vitest run ...' MUTATIONS.json
MUTATIONS.json = [{"name":..., "file": rel path, "edits": [[old,new,count?], ...]}]
Applies each mutation to the (already reference-patched) worktree, runs the test command, prints summary + failed tests, restores the file."""
import json, os, re, subprocess, sys, shutil
wt, tdir, cmd, mfile = sys.argv[1:5]
muts = json.load(open(mfile))
def run():
    p = subprocess.run(cmd, shell=True, cwd=os.path.join(wt, tdir), capture_output=True, text=True)
    out = p.stdout + p.stderr
    out = re.sub(r'\x1b\[[0-9;]*m', '', out)
    summ = [l.strip() for l in out.splitlines() if re.match(r'\s*Tests\s', l)]
    fails = sorted(set(l.strip() for l in out.splitlines() if l.strip().startswith(('×', '✗', 'FAIL')) and ' > ' in l))
    return p.returncode, (summ[-1] if summ else 'no summary'), fails
rc, s, f = run()
print('%-46s rc=%d  %s' % ('BASE (reference applied)', rc, s))
for m in muts:
    path = os.path.join(wt, m['file'])
    orig = open(path, encoding='utf-8', newline='').read()
    new = orig
    for e in m['edits']:
        old, rep = e[0], e[1]
        n = new.count(old)
        want = e[2] if len(e) > 2 else 1
        if n != want:
            print('!! mutation %s: expected %d occurrence(s) of %r, found %d' % (m['name'], want, old[:70], n)); new = None; break
        new = new.replace(old, rep)
    if new is None:
        continue
    open(path, 'w', encoding='utf-8', newline='').write(new)
    try:
        rc, s, f = run()
    finally:
        open(path, 'w', encoding='utf-8', newline='').write(orig)
    print('%-46s rc=%d  %s' % (m['name'], rc, s))
    for x in f:
        print('      ' + x[:230])
rc, s, f = run()
print('%-46s rc=%d  %s' % ('RESTORED', rc, s))
