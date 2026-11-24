#!/usr/bin/env python3
"""mutate.py: for each task, drop one source hunk of the reference fix at a time and run the upstream tests.
A hunk whose removal stays green is not pinned by the upstream tests."""
import json, re, subprocess, sys, os
M = os.path.dirname(os.path.abspath(__file__))
WT = {'lfc-08-ready-clears-removal': 'lfc-ready-clears-removal', 'lfc-09-digest-cutoff-watermark': 'lfc-digest-cutoff',
      'lfc-10-sealed-sync-join': 'lfc-sealed-sync-join', 'lfc-11-sealed-same-name': 'lfc-sealed-same-name',
      'lfc-12-guild-lifecycle': 'lfc-guild-rejoin-digest', 'asohav-14-strain-clears-on-goal': 'asohav-strain-clears-on-goal',
      'asohav-15-combat-end-authz': 'asohav-combat-end-authz', 'asohav-16-sheet-get-authz': 'asohav-sheet-get-authz',
      'asohav-17-invite-email-escape': 'asohav-email-escape', 'asohav-18-next-round-guard': 'asohav-next-round-guard',
      'asohav-19-defaults-on-read': 'asohav-defaults-on-read', 'asohav-20-motif-pad': 'asohav-motif-pad',
      'asohav-21-invite-decline-pending': 'asohav-invite-decline-pending'}
E = {e['id']: e for e in json.load(open(os.path.join(M, 'entries.json')))}
env = {k: v for k, v in os.environ.items() if k not in ('DATABASE_URL', 'MANAPOOL_API_KEY')}

def sh(cmd, cwd): return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env)

def split(path):
    s = open(path, newline='').read()
    files = re.split(r'(?m)^(?=diff --git )', s)
    out = []  # (file_header, [hunks])
    for f in files:
        if not f.strip(): continue
        head, *hunks = re.split(r'(?m)^(?=@@ )', f)
        out.append((head, hunks))
    return out

def join(parts, skip):
    s = ''; n = 0
    for head, hunks in parts:
        keep = []
        for h in hunks:
            if n != skip: keep.append(h)
            n += 1
        if keep: s += head + ''.join(keep)
    return s

def is_comment_only(h):
    body = [l[1:].strip() for l in h.splitlines()[1:] if l[:1] in '+-']
    return all(not b or b.startswith(('//', '*', '/*', '*/')) for b in body)

ids = sys.argv[1:] or list(WT)
for tid in ids:
    e = E[tid]; wt = os.path.join(M, 'wt', WT[tid]); td = os.path.join(wt, e['testDir'])
    base = sh(['git', 'rev-parse', 'HEAD'], wt).stdout.strip()
    srcp = os.path.join(M, 'patches', tid + '.src.patch'); tstp = os.path.join(M, 'patches', tid + '.tests.patch')
    parts = split(srcp); total = sum(len(h) for _, h in parts)
    flat = [(head.split()[2][2:], h) for head, hs in parts for h in hs]
    print(f'== {tid}: {total} source hunks')
    for i in range(total):
        sh(['git', 'checkout', '-q', base, '--', '.'], wt)
        mut = os.path.join(M, 'patches', '.mut.patch'); open(mut, 'w', newline='').write(join(parts, i))
        a = sh(['git', 'apply', tstp], wt); b = sh(['git', 'apply', mut], wt) if total > 1 else None
        r = sh(['npx', 'vitest', 'run'] + e['testCmd'][3:], td)
        m = re.search(r'Tests\s+(.*)', re.sub(r'\x1b\[[0-9;]*m', '', r.stdout))
        green = r.returncode == 0
        f, h = flat[i]
        tag = 'comment-only' if is_comment_only(h) else ''
        print(f"  hunk {i+1} {f} {h.splitlines()[0][:60]!r}: {'GREEN (unpinned)' if green else 'red'} {tag} [{m.group(1).strip() if m else r.stdout[-200:]}]")
    sh(['git', 'checkout', '-q', base, '--', '.'], wt); sh(['git', 'clean', '-qfd', '-e', 'node_modules'], wt)
