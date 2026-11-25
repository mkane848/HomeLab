#!/usr/bin/env python3
"""Generate the tables in docs/reference/{guards,machines}.md.

  python3 tests/make-reference.py          rewrite the generated blocks
  python3 tests/make-reference.py --check  exit 1 if a guard lacks its header or a block is stale

Guards: every tests/test-*.ps1 must open with `# protects: ...` and `# run-after: ...`.
Mutations: every guard not in tests/mutation-exempt.txt carries at least one complete
`# mutation:` group (path, -from, -to, -expect) whose file exists and whose -from text occurs
exactly once in it; tests/run-mutations.ps1 runs them. The exempt list only shrinks.
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


# The guards that existed when mutation headers became required (2026-11-25). It may only shrink: a guard leaves it
# once it carries a mutation. A new guard is never added to it.
EXEMPT_FILE = 'tests/mutation-exempt.txt'
EXEMPT_MAX = 57


def leading_comments(text):
    out = []
    for line in text.split('\n'):
        if re.match(r'^\s*#', line):
            out.append(line)
        elif line.strip():
            break
    return out


def parse_mutations(text):
    groups, cur = [], None
    for line in leading_comments(text):
        m = re.match(r'^\s*#\s*mutation:\s*(.+?)\s*$', line)
        if m:
            cur = {'path': m.group(1)}
            groups.append(cur)
            continue
        m = re.match(r'^\s*#\s*mutation-(from|to|expect):\s?(.*)$', line)
        if m:
            if cur is None:
                return groups, f'"# mutation-{m.group(1)}:" before any "# mutation:" line'
            cur[m.group(1)] = m.group(2).strip()
    return groups, None


def mutations_check(problems):
    exempt = [l.strip() for l in read(EXEMPT_FILE).split('\n') if l.strip() and not l.lstrip().startswith('#')]
    if len(exempt) > EXEMPT_MAX:
        problems.append(f'{EXEMPT_FILE}: {len(exempt)} names, more than the {EXEMPT_MAX} it started with; '
                        'a new guard carries a "# mutation:" header instead (tests/run-mutations.ps1)')
    if len(exempt) != len(set(exempt)):
        problems.append(f'{EXEMPT_FILE}: a name is listed twice')
    names = {os.path.basename(p) for p in glob.glob(os.path.join(ROOT, 'tests', 'test-*.ps1'))}
    for n in exempt:
        if n not in names:
            problems.append(f'{EXEMPT_FILE}: {n} is not a guard in tests/ (remove it from the list)')
    for name in sorted(names):
        groups, err = parse_mutations(read(os.path.join('tests', name)))
        if err:
            problems.append(f'tests/{name}: {err}')
        if not groups and name not in exempt:
            problems.append(f'tests/{name}: no "# mutation:" header. A new guard names a one-line break of the code it '
                            'protects and the FAIL line it causes (tests/run-mutations.ps1)')
        for i, g in enumerate(groups, 1):
            where = f'tests/{name}: mutation {i} ({g["path"]})'
            missing = [k for k in ('from', 'to', 'expect') if k not in g or (k != 'to' and not g[k])]
            if missing:
                problems.append(f'{where}: missing ' + ', '.join(f'mutation-{k}' for k in missing))
                continue
            target = os.path.join(ROOT, g['path'])
            if not os.path.isfile(target):
                problems.append(f'{where}: no such file')
                continue
            with open(target, 'rb') as f:
                n = f.read().count(g['from'].encode('utf-8'))
            if n != 1:
                problems.append(f'{where}: mutation-from occurs {n} time(s), not once (stale?)')
            if g['from'] == g['to']:
                problems.append(f'{where}: mutation-to is the same as mutation-from')
            try:
                re.compile(g['expect'])
            except re.error as e:
                problems.append(f'{where}: mutation-expect is not a regex ({e})')


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
    mutations_check(problems)
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
