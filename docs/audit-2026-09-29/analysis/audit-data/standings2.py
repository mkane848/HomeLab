"""DP11 standings re-cut with the opencode version in the same-config key.

Base key (as in standings.py): prompt sha, the seat's designed numCtx, Ollama 0.34.3.
New key adds: opencodeVersion stamped in the run JSON.
Ungraded _TIMEOUT_/_INFRA_ transcripts carry no JSON, so they take the version of the
batch whose time window they fall in (boundaries derived from the graded rows).
"""
import csv, glob, json, math, os, re, collections

R = '/home/user/HomeLab/tests/results'
rows = list(csv.DictReader(open(R + '/tasks-summary.tsv', encoding='utf-8-sig'), delimiter='\t'))
J = {}
for p in glob.glob(R + '/tasks-*.json'):
    try:
        d = json.load(open(p, encoding='utf-8-sig'))
    except Exception:
        continue
    if isinstance(d, dict) and 'taskId' in d:
        J[(d['taskId'], d['model'], d['timestamp'])] = d


def gp(r):
    return r['opencodeExit'] == '0' and r['scope'] == 'PASS' and r['suite'] == 'PASS' and r['failsOnOld'] == 'PASS'


def wilson(k, n, z=1.96):
    p = k / n; d = 1 + z * z / n; c = p + z * z / (2 * n); h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)); return ((c - h) / d, (c + h) / d)


def fisher2(a, b, c, d):
    n1, n2, k = a + b, c + d, a + c; N = n1 + n2
    pm = lambda x: math.comb(k, x) * math.comb(N - k, n1 - x) / math.comb(N, n1)
    o = pm(a); return sum(pm(x) for x in range(max(0, k - n2), min(k, n1) + 1) if pm(x) <= o + 1e-12)


TASKS = [('kane-01-background-pair', 'EFEF5E6EF63E'), ('kane-02-multiword-creature-type', '2C70ABFF8F8A'), ('kane-03-saga-chapter-triggers', 'F9DC389CE88F'),
         ('kane-04-singleton-up-to-n', 'B63AF9A6F823'), ('lfc-01-listing-status-guard', '2040D996958B'), ('lfc-02-scryfall-headers', '0CDC9E50C546'),
         ('lfc-03-status-transition-guard', '833A03061C7F'), ('asohav-01-library-write-reporting', '7ACA562BCD15'), ('asohav-02-changelog-uuid-id', '15771B923DC9')]
FRONTIER = {'lfc-03-status-transition-guard', 'kane-02-multiword-creature-type', 'asohav-02-changelog-uuid-id'}
SEATS = {'qwen3.6:35b-a3b-coding': (65536, '20260927-110000'), 'qwen3.5:9b': (65536, '20260927-110000'), 'qwen3:14b': (32768, '20260926-180000')}


def stamp(ts):  # 2026-09-27T11:56:03 -> 20260927-115603
    return ts.replace('-', '').replace(':', '').replace('T', '-')


# version windows from every graded row that carries a version
vers = sorted((stamp(j['timestamp']), j.get('opencodeVersion')) for j in J.values() if j.get('opencodeVersion'))
print('opencode version windows (first/last graded row per version):')
by = collections.OrderedDict()
for s, v in vers:
    by.setdefault(v, [s, s]); by[v][1] = s
for v, (a, b) in by.items():
    print('   %-8s %s .. %s' % (v, a, b))


def version_at(s):
    """version of the nearest graded row at or before s (ungraded transcripts have no JSON)"""
    prev = None
    for ts, v in vers:
        if ts <= s:
            prev = v
        else:
            break
    return prev


def attempts(t, sha, s):
    ctx, since = SEATS[s]
    seq = []
    for r in rows:
        if r['taskId'] != t or r['model'] != 'ollama-desktop/' + s:
            continue
        j = J.get((t, r['model'], r['timestamp'])) or {}
        c = j.get('numCtx') or (32768 if r['timestamp'] >= '2026-09-22' else 16384)
        if j.get('promptSha256') == sha and c == ctx and (j.get('ollamaVersion') or '').endswith('0.34.3'):
            seq.append((stamp(r['timestamp']), 'P' if gp(r) else 'f', j.get('opencodeVersion')))
    for p in glob.glob(R + '/tasks-%s-*%s*_*.jsonl' % (t, s.replace(':', '_'))):
        m = re.search(r'_(INFRA|TIMEOUT)_(\d{8}-\d{6})\.jsonl$', p)
        if m and m.group(2) >= since:
            seq.append((m.group(2), 'T' if m.group(1) == 'TIMEOUT' else 'I', version_at(m.group(2))))
    seq.sort()
    return seq


tot = collections.defaultdict(lambda: [0, 0])          # (seat, version) -> k, n
cellmax = collections.defaultdict(list)                # seat -> list of max same-version N over cells
strict_cells = {}
print('\nper cell, same-config attempts split by opencode version  (P pass, f fail, T timeout, I infra):')
for s in SEATS:
    print('\n== %s' % s)
    for t, sha in TASKS:
        seq = attempts(t, sha, s)
        groups = collections.OrderedDict()
        for ts, o, v in seq:
            groups.setdefault(v, []).append(o)
            tot[(s, v)][1] += 1
            tot[(s, v)][0] += (o == 'P')
        cellmax[s].append(max((len(g) for g in groups.values()), default=0))
        strict_cells[(s, t)] = groups
        print('  %-34s %s' % (t[:34] + ('*' if t in FRONTIER else ' '), '   '.join('%s: %s (%d/%d)' % (v, ''.join(g), g.count('P'), len(g)) for v, g in groups.items()) or '-'))

print('\nper seat per opencode version (all 9 tasks, same-config attempts):')
for s in SEATS:
    parts = []
    for (ss, v), (k, n) in sorted(tot.items(), key=lambda x: str(x[0])):
        if ss == s:
            lo, hi = wilson(k, n)
            parts.append('%s: %d/%d (%.2f-%.2f)' % (v, k, n, lo, hi))
    print('  %-24s %s' % (s, '   '.join(parts)))

print('\ncells with >=2 attempts under ONE opencode version (the strict N>1 evidence):')
for s in SEATS:
    n2 = sum(1 for m in cellmax[s] if m >= 2)
    print('  %-24s %d of %d cells (loose key: %d of %d)' % (s, n2, len(TASKS), sum(1 for t, sha in TASKS if len(attempts(t, sha, s)) >= 2), len(TASKS)))

# strict comparison: only 1.18.33 attempts (the newest batch, all three seats) on the same tasks
print('\n1.18.33 only, by seat (the one version all three seats were run on together):')
res = {}
for s in SEATS:
    k, n = tot[(s, '1.18.33')]
    res[s] = (k, n)
    lo, hi = wilson(k, n) if n else (0, 0)
    print('  %-24s %d/%d (%.2f-%.2f)' % (s, k, n, lo, hi))
a, b, c = list(SEATS)
(ka, na), (kb, nb), (kc, nc) = res[a], res[b], res[c]
print('  Fisher: qwen3.6 vs qwen3.5 p=%.3f ; qwen3.6 vs qwen3:14b p=%.4f ; qwen3.5 vs qwen3:14b p=%.3f' % (
    fisher2(ka, na - ka, kb, nb - kb), fisher2(ka, na - ka, kc, nc - kc), fisher2(kb, nb - kb, kc, nc - kc)))
