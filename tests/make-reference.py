#!/usr/bin/env python3
"""Generate the tables in docs/reference/{guards,machines}.md.

  python3 tests/make-reference.py          rewrite the generated blocks
  python3 tests/make-reference.py --check  exit 1 if a guard lacks its header or a block is stale

Guards: every tests/test-*.ps1 must open with `# protects: ...` and `# run-after: ...`.
Machines: machines.tsv (name, roles, note).
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(path):
    with open(os.path.join(ROOT, path), encoding='utf-8-sig', newline='') as f:
        return f.read().replace('\r\n', '\n')


def cell(s):
    return s.replace('|', '\\|').strip()


def guards_table(problems):
    rows = []
    for path in sorted(glob.glob(os.path.join(ROOT, 'tests', 'test-*.ps1'))):
        name = os.path.basename(path)
        head = read(os.path.join('tests', name)).split('\n')[:12]
        found = {}
        for line in head:
            m = re.match(r'#\s*(protects|run-after):\s*(.+?)\s*$', line)
            if m:
                found[m.group(1)] = m.group(2)
        for key in ('protects', 'run-after'):
            if key not in found:
                problems.append(f'tests/{name}: missing "# {key}:" header in its first 12 lines')
        rows.append((name, found.get('protects', '?'), found.get('run-after', '?')))
    out = [f'{len(rows)} guards.', '', '| Guard | Protects | Run it after touching |', '|---|---|---|']
    for name, p, r in rows:
        out.append(f'| `tests/{name}` | {cell(p)} | {cell(r)} |')
    return '\n'.join(out)


def machines_table(problems):
    lines = [l for l in read('machines.tsv').split('\n') if l.strip()]
    out = ['| Machine | Roles | Note |', '|---|---|---|']
    for l in lines[1:]:
        parts = l.split('\t')
        if len(parts) < 3:
            problems.append(f'machines.tsv: short row {l!r}')
            continue
        roles = ', '.join(f'`{r}`' for r in parts[1].split())
        out.append(f'| `{parts[0]}` | {roles} | {cell(parts[2])} |')
    return '\n'.join(out)


def splice(text, tag, body):
    pat = re.compile(rf'(<!-- BEGIN GENERATED: {tag} -->\n).*?(\n?<!-- END GENERATED: {tag} -->)', re.S)
    if not pat.search(text):
        return None
    return pat.sub(lambda m: m.group(1) + body + '\n' + m.group(2).lstrip('\n'), text, count=1)


def main():
    check = '--check' in sys.argv
    problems = []
    targets = [
        ('docs/reference/guards.md', 'guards', guards_table(problems)),
        ('docs/reference/machines.md', 'machines', machines_table(problems)),
    ]
    for path, tag, body in targets:
        cur = read(path)
        new = splice(cur, tag, body)
        if new is None:
            problems.append(f'{path}: no GENERATED block named {tag}')
        elif new != cur:
            if check:
                problems.append(f'{path}: generated block "{tag}" is stale (run python3 tests/make-reference.py)')
            else:
                with open(os.path.join(ROOT, path), 'w', encoding='utf-8', newline='\n') as f:
                    f.write(new)
                print(f'updated {path}')
    for p in problems:
        print('FAIL', p)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
