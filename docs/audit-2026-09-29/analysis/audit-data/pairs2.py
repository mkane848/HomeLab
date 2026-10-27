"""Replicate-pair concordance, split by whether the two attempts share an opencode version.

Same-config attempts (prompt sha, designed numCtx, Ollama 0.34.3) GRADED only (pairs need two outcomes),
all seats, all tasks, whole corpus - the same population delta3.py used for the 11/11 vs 8/21 figure.
"""
import csv, glob, json, math, itertools, collections, datetime

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


def fisher2(a, b, c, d):
    n1, n2, k = a + b, c + d, a + c; N = n1 + n2
    pm = lambda x: math.comb(k, x) * math.comb(N - k, n1 - x) / math.comb(N, n1)
    o = pm(a); return sum(pm(x) for x in range(max(0, k - n2), min(k, n1) + 1) if pm(x) <= o + 1e-12)


groups = collections.defaultdict(list)
for r in rows:
    if r['opencodeExit'] != '0' or r['timestamp'] < '2026-09-22':
        continue
    j = J.get((r['taskId'], r['model'], r['timestamp'])) or {}
    if not (j.get('ollamaVersion') or '').endswith('0.34.3'):
        continue
    key = (r['taskId'], r['model'], j.get('promptSha256'), j.get('numCtx') or 32768)
    groups[key].append((datetime.datetime.fromisoformat(r['timestamp']), gp(r), j.get('opencodeVersion')))

cats = collections.OrderedDict([('same version, <4h apart (back-to-back)', [0, 0]),
                                ('same version, >=4h apart (other session)', [0, 0]),
                                ('different version', [0, 0])])
for key, atts in groups.items():
    atts.sort()
    for (t1, o1, v1), (t2, o2, v2) in itertools.combinations(atts, 2):
        gap = abs((t2 - t1).total_seconds()) / 3600
        cat = 'different version' if v1 != v2 else ('same version, <4h apart (back-to-back)' if gap < 4 else 'same version, >=4h apart (other session)')
        cats[cat][1] += 1
        cats[cat][0] += (o1 != o2)
print('pairs of graded same-config attempts (all pairs within a cell), by how the two attempts relate:')
for c, (disc, n) in cats.items():
    print('   %-44s %2d pairs, %2d discordant' % (c, n, disc))
b2b, other, ver = list(cats.values())
print('\nFisher, discordance back-to-back vs different-version : p = %.3f' % fisher2(b2b[0], b2b[1] - b2b[0], ver[0], ver[1] - ver[0]))
if other[1]:
    print('Fisher, discordance back-to-back vs same-version other-session: p = %.3f' % fisher2(b2b[0], b2b[1] - b2b[0], other[0], other[1] - other[0]))

# matched comparison on the 1.18.33 batch only
print('\nmatched frontier cells at opencode 1.18.33 (same tasks, one version):')
TOP = {'ollama-desktop/qwen3.6:35b-a3b-coding': 'qwen3.6', 'ollama-desktop/qwen3.5:9b': 'qwen3.5', 'ollama-desktop/qwen3:14b': 'qwen3:14b'}
FR = {'lfc-03-status-transition-guard', 'kane-02-multiword-creature-type', 'asohav-02-changelog-uuid-id'}
tally = collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0]))
for (task, model, sha, ctx), atts in groups.items():
    if model not in TOP or task not in FR:
        continue
    for t, o, v in atts:
        if v == '1.18.33':
            tally[TOP[model]][task][0] += o
            tally[TOP[model]][task][1] += 1
for seat, d in tally.items():
    print('   %-9s ' % seat + '  '.join('%s %d/%d' % (t.split('-')[0] + '-' + t.split('-')[1], k, n) for t, (k, n) in sorted(d.items())))
# graded only here (the qwen3:14b timeout is ungraded); add it back explicitly for the control
a = tally['qwen3.6']; b = tally['qwen3.5']
k6 = sum(v[0] for v in a.values()); n6 = sum(v[1] for v in a.values())
k5 = sum(v[0] for v in b.values()); n5 = sum(v[1] for v in b.values())
print('   qwen3.6 %d/%d vs qwen3.5 %d/%d on the 3 frontier cells at 1.18.33: Fisher p = %.4f' % (k6, n6, k5, n5, fisher2(k6, n6 - k6, k5, n5 - k5)))
# control: its lfc-03 and asohav-02 (two cells), lfc-03 includes one ungraded timeout (counts as a miss)
c14 = tally['qwen3:14b']
kc = sum(v[0] for v in c14.values()); nc = sum(v[1] for v in c14.values()) + 1  # + the lfc-03 _TIMEOUT_
k6c = sum(a[t][0] for t in ('lfc-03-status-transition-guard', 'asohav-02-changelog-uuid-id')); n6c = sum(a[t][1] for t in ('lfc-03-status-transition-guard', 'asohav-02-changelog-uuid-id'))
print('   qwen3.6 %d/%d vs qwen3:14b %d/%d on lfc-03 + asohav-02 at 1.18.33 (timeout counted): Fisher p = %.4f' % (k6c, n6c, kc, nc, fisher2(k6c, n6c - k6c, kc, nc - kc)))
