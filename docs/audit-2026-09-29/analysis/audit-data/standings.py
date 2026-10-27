import csv, json, glob, os, re, math, collections

R = '/home/user/HomeLab/tests/results'
rows = list(csv.DictReader(open(R + '/tasks-summary.tsv'), delimiter='\t'))
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
# seat -> (designed numCtx, first date a same-config ungraded transcript counts)
SEATS = {'qwen3.6:35b-a3b-coding': (65536, '20260927-110000'), 'qwen3.5:9b': (65536, '20260927-110000'), 'qwen3:14b': (32768, '20260926-180000')}


def attempts(t, sha, s):
    ctx, since = SEATS[s]
    seq = []
    for r in rows:
        if r['taskId'] != t or r['model'] != 'ollama-desktop/' + s:
            continue
        j = J.get((t, r['model'], r['timestamp'])) or {}
        c = j.get('numCtx') or (32768 if r['timestamp'] >= '2026-09-22' else 16384)
        if j.get('promptSha256') == sha and c == ctx and (j.get('ollamaVersion') or '').endswith('0.34.3'):
            seq.append((r['timestamp'].replace('-', '').replace(':', '').replace('T', '-'), 'P' if gp(r) else 'f'))
    for p in glob.glob(R + '/tasks-%s-*%s*_*.jsonl' % (t, s.replace(':', '_'))):
        m = re.search(r'_(INFRA|TIMEOUT)_(\d{8}-\d{6})\.jsonl$', p)
        if m and m.group(2) >= since:
            seq.append((m.group(2), 'T' if m.group(1) == 'TIMEOUT' else 'I'))
    seq.sort()
    return ''.join(x[1] for x in seq)


table = {s: {t: attempts(t, sha, s) for t, sha in TASKS} for s in SEATS}
print('| task | qwen3.6 | qwen3.5 | qwen3:14b |')
print('|---|---|---|---|')
tot = {s: [0, 0] for s in SEATS}
fr = {s: [0, 0] for s in SEATS}
for t, _ in TASKS:
    cells = []
    for s in SEATS:
        a = table[s][t]
        k, n = a.count('P'), len(a)
        tot[s][0] += k; tot[s][1] += n
        if t in FRONTIER:
            fr[s][0] += k; fr[s][1] += n
        cells.append('%s %d/%d' % (a or '-', k, n) if n else '-')
    print('| %s | %s |' % (t.split('-')[0] + '-' + t.split('-')[1] + (' (frontier)' if t in FRONTIER else ''), ' | '.join(cells)))
print('| **all 9 tasks** | ' + ' | '.join('**%d/%d**' % tuple(tot[s]) for s in SEATS) + ' |')
print('| Wilson 95% | ' + ' | '.join('%.2f-%.2f' % wilson(*tot[s]) for s in SEATS) + ' |')
print('| frontier cells only | ' + ' | '.join('%d/%d' % tuple(fr[s]) for s in SEATS) + ' |')
a, b, c = [SEATS_ for SEATS_ in SEATS]
for label, T in (('all tasks', tot), ('frontier only', fr)):
    x, y, z = T[a], T[b], T[c]
    print('\n%s: qwen3.6 vs qwen3.5 p=%.3f ; qwen3.6 vs qwen3:14b p=%.4f ; qwen3.5 vs qwen3:14b p=%.3f' % (
        label, fisher2(x[0], x[1] - x[0], y[0], y[1] - y[0]), fisher2(x[0], x[1] - x[0], z[0], z[1] - z[0]), fisher2(y[0], y[1] - y[0], z[0], z[1] - z[0])))
