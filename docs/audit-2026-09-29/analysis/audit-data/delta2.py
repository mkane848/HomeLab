import csv, json, glob, os, re, math, collections

NEW = '/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/newmain/tests/results'
rows = list(csv.DictReader(open(NEW + '/tasks-summary.tsv'), delimiter='\t'))
J = {}
for p in glob.glob(NEW + '/tasks-*.json'):
    try:
        d = json.load(open(p, encoding='utf-8-sig'))
    except Exception:
        continue
    if isinstance(d, dict) and 'taskId' in d:
        J[(d['taskId'], d['model'], d['timestamp'])] = d


def gp(r):
    return r['opencodeExit'] == '0' and r['scope'] == 'PASS' and r['suite'] == 'PASS' and r['failsOnOld'] == 'PASS'


def info(r):
    j = J.get((r['taskId'], r['model'], r['timestamp'])) or {}
    ctx = j.get('numCtx')
    if ctx is None:
        ctx = 32768 if r['timestamp'] >= '2026-09-22' else 16384   # unstamped: baked default of that era
    a = j.get('acceptance')
    ast = (a.get('status') if isinstance(a, dict) else a) if a is not None else '-'
    return dict(ctx=ctx, oc=j.get('opencodeVersion'), ol=j.get('ollamaVersion'), sha=j.get('promptSha256'), acc=ast)


def wilson(k, n, z=1.96):
    if n == 0:
        return (0, 0)
    p = k / n; d = 1 + z * z / n; c = p + z * z / (2 * n); h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)); return ((c - h) / d, (c + h) / d)


def fisher2(a, b, c, d):
    n1, n2, k = a + b, c + d, a + c; N = n1 + n2
    pm = lambda x: math.comb(k, x) * math.comb(N - k, n1 - x) / math.comb(N, n1)
    o = pm(a); return sum(pm(x) for x in range(max(0, k - n2), min(k, n1) + 1) if pm(x) <= o + 1e-12)


TASKS = ['lfc-03-status-transition-guard', 'kane-02-multiword-creature-type', 'asohav-02-changelog-uuid-id']
CUR = {'lfc-03-status-transition-guard': '833A03061C7F', 'kane-02-multiword-creature-type': '2C70ABFF8F8A', 'asohav-02-changelog-uuid-id': '15771B923DC9'}
DESIGN = {'qwen3.6:35b-a3b-coding': 65536, 'qwen3.5:9b': 65536, 'qwen3:14b': 32768}

# ungraded transcripts (attempts): TIMEOUT / INFRA count; ABORTED does not
tr = collections.defaultdict(list)
for p in glob.glob(NEW + '/tasks-*.jsonl'):
    m = re.search(r'_(INFRA|TIMEOUT|ABORTED)_(\d{8})-(\d{6})\.jsonl$', p)
    if not m:
        continue
    b = os.path.basename(p)
    t = next((t for t in TASKS if b.startswith('tasks-' + t)), None)
    s = next((s for s in DESIGN if s.replace(':', '_') in b), None)
    if t and s and m.group(2) >= '20260926':
        tr[(t, s)].append((m.group(1), m.group(2) + m.group(3)))

print("== per-attempt table, protocol cells (same prompt sha + seat's designed numCtx, Ollama 0.34.3). P=pass f=fail T=timeout I=infra-crash; ABORTED not counted")
print("   opencode version of each graded row in brackets (1.18.32 vs 1.18.33)")
tot = collections.defaultdict(lambda: [0, 0])
for t in TASKS:
    for s in DESIGN:
        rs = [r for r in rows if r['taskId'] == t and r['model'] == 'ollama-desktop/' + s]
        seq = []
        for r in sorted(rs, key=lambda r: r['timestamp']):
            i = info(r)
            if i['sha'] == CUR[t] and i['ctx'] == DESIGN[s] and (i['ol'] or '').endswith('0.34.3'):
                seq.append((r['timestamp'], 'P' if gp(r) else 'f', i['oc'] or '?', i['acc']))
        for kind, ts in tr[(t, s)]:
            if kind in ('TIMEOUT', 'INFRA') and ts >= '20260927':   # 09-26 32k INFRA rows are the memory-pressure era
                seq.append((ts, 'T' if kind == 'TIMEOUT' else 'I', '?', '-'))
        seq.sort()
        line = ''.join(x[1] for x in seq)
        k = line.count('P'); n = len(line)
        tot[s][0] += k; tot[s][1] += n
        ocs = collections.Counter(x[2] for x in seq if x[1] in 'Pf')
        print("   %-32s %-24s %-6s %d/%d   opencode=%s" % (t[:32], s, line, k, n, dict(ocs)))
print("\n== frontier-cell totals per seat (same-config attempts, timeouts/infra count as misses)")
for s, (k, n) in tot.items():
    lo, hi = wilson(k, n)
    print("   %-24s %d/%d  Wilson95 [%.2f, %.2f]" % (s, k, n, lo, hi))
a, b_, c = tot['qwen3.6:35b-a3b-coding'], tot['qwen3.5:9b'], tot['qwen3:14b']
print("   Fisher two-sided: qwen3.6 vs qwen3.5 p=%.3f ; qwen3.6 vs qwen3:14b p=%.4f ; qwen3.5 vs qwen3:14b p=%.3f" % (
    fisher2(a[0], a[1] - a[0], b_[0], b_[1] - b_[0]), fisher2(a[0], a[1] - a[0], c[0], c[1] - c[0]), fisher2(b_[0], b_[1] - b_[0], c[0], c[1] - c[0])))

print("\n== same-config replicate groups (seat, task, numCtx, prompt sha, ollama) with >=2 graded rows, whole corpus")
g = collections.defaultdict(list)
for r in rows:
    if r['opencodeExit'] != '0':
        continue
    i = info(r)
    if not (i['ol'] or '').endswith('0.34.3') or r['timestamp'] < '2026-09-22':
        continue
    g[(r['model'].split('/')[-1], r['taskId'], i['ctx'], i['sha'])].append((r['timestamp'], gp(r), i['oc']))
multi = {k: sorted(v) for k, v in g.items() if len(v) >= 2}
mixed = {k: v for k, v in multi.items() if any(x[1] for x in v) and not all(x[1] for x in v)}
print("   groups with >=2 rows: %d ; mixed PASS/FAIL: %d" % (len(multi), len(mixed)))
for k, v in sorted(mixed.items()):
    print("     %-24s %-26s ctx=%-5s %s   [opencode %s]" % (k[0], k[1][:26], k[2], ''.join('P' if x[1] else 'f' for x in v), '/'.join(sorted(set(x[2] or '?' for x in v)))))
allsame = [k for k, v in multi.items() if k not in mixed]
print("   uniform groups: %d (%s)" % (len(allsame), ', '.join('%s/%s %s' % (k[0].split(':')[0], k[1].split('-')[0] + k[1].split('-')[1], ''.join('P' if x[1] else 'f' for x in multi[k])) for k in sorted(allsame))))

print("\n== lfc-03: model-authored-test gates vs owner acceptance tests (all runs with an acceptance result)")
n = ga = ac = both = 0
wrong = []
for r in rows:
    if r['taskId'] != 'lfc-03-status-transition-guard':
        continue
    i = info(r)
    if i['acc'] not in ('PASS', 'FAIL'):
        continue
    n += 1
    ga += gp(r); ac += (i['acc'] == 'PASS'); both += (gp(r) and i['acc'] == 'PASS')
    if gp(r) and i['acc'] != 'PASS':
        wrong.append(r)
print("   runs with acceptance result: %d ; all gates PASS: %d ; owner acceptance PASS: %d ; both: %d ; gate-PASS but acceptance FAIL: %d" % (n, ga, ac, both, len(wrong)))

print("\n== failure shapes among the 9 new FAIL rows (delta since 09-29T16:00)")
shape = collections.Counter()
for r in rows:
    if r['timestamp'] < '2026-09-29T16:00' or gp(r):
        continue
    if r['scope'] != 'PASS':
        shape['scope FAIL (edited outside allowFiles)'] += 1
    elif r['suite'] != 'PASS':
        shape['suite FAIL (broke the build / test file does not load)'] += 1
    elif r['failsOnOld'] != 'PASS':
        shape['failsOnOld FAIL (test green on broken code)'] += 1
print("  ", dict(shape))

print("\n== zero-write exit-0 rows in the 21 new rows:", sum(1 for r in rows if r['timestamp'] >= '2026-09-29T16:00' and r['opencodeExit'] == '0' and r['writes'] == '0'))
capped = []
for p in glob.glob(NEW + '/tasks-*.jsonl'):
    if os.path.basename(p) < 'x' and re.search(r'_20260929-(1[6-9]|2)', p):
        txt = open(p, encoding='utf-8', errors='replace').read()
        if '"reason":"length"' in txt:
            capped.append(os.path.basename(p)[:80])
print("   new transcripts containing a finish=length event:", capped)
