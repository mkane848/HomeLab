#!/usr/bin/env python3
"""closure.py REPO_ROOT_AT_PIN ENTRY... : static import closure (relative + @mtg/* workspace) and an ambient-input grep over it."""
import os, re, sys, json
root = sys.argv[1]
entries = sys.argv[2:]
imp = re.compile(r"""(?:import|export)\s+(?:type\s+)?(?:[^'"]*?\sfrom\s+)?['"]([^'"]+)['"]""")
ws = {}
for d in ('packages',):
    for p in os.listdir(os.path.join(root, d)):
        pj = os.path.join(root, d, p, 'package.json')
        if os.path.exists(pj):
            try: ws[json.load(open(pj))['name']] = os.path.join(root, d, p)
            except Exception: pass
def resolve(frm, spec):
    cands = []
    if spec.startswith('.'):
        base = os.path.normpath(os.path.join(os.path.dirname(frm), spec))
        cands = [base, base + '.ts', base + '.tsx', base + '.js', os.path.join(base, 'index.ts'), re.sub(r'\.js$', '.ts', base)]
    elif spec in ws:
        cands = [os.path.join(ws[spec], 'src', 'index.ts')]
    for c in cands:
        if os.path.isfile(c): return c
    return None
seen, ext, stack = set(), set(), [os.path.join(root, e) for e in entries]
while stack:
    f = stack.pop()
    if f in seen: continue
    seen.add(f)
    src = open(f, encoding='utf-8').read()
    for m in imp.finditer(src):
        spec = m.group(1)
        r = resolve(f, spec)
        if r: stack.append(r)
        elif not spec.startswith('.'): ext.add(spec)
print('files in closure: %d' % len(seen))
print('external packages imported:', ', '.join(sorted(ext)))
pat = re.compile(r"process\.env|import\.meta\.env|Date\.now|new Date\(|Math\.random|Intl\.|toLocale|performance\.now|setTimeout|setInterval|readFileSync|readFile\(|fs\.|\bfetch\(|localStorage|sessionStorage|navigator|Array\.prototype\.sort|\.sort\(\)|process\.platform|os\.EOL|\\\\r|path\.sep|import\.meta\.url|__dirname|crypto\.|randomUUID")
for f in sorted(seen):
    rel = os.path.relpath(f, root)
    if rel.endswith('.test.ts') or '/test/' in rel:
        tag = ' (test)'
    else: tag = ''
    hits = []
    for i, line in enumerate(open(f, encoding='utf-8').read().split('\n'), 1):
        if pat.search(line) and not line.strip().startswith(('//', '*', '/*')):
            hits.append('%d: %s' % (i, line.strip()[:110]))
    if hits:
        print('%s%s' % (rel, tag))
        for h in hits[:12]: print('    ' + h)
