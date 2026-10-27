import csv, json, glob, os, re, math, collections, statistics
os.chdir('/home/user/HomeLab/tests/results')
rows = list(csv.DictReader(open('tasks-summary.tsv'), delimiter='\t'))


def host(m):
    return 'desktop' if 'ollama-desktop' in m else 'node3' if 'ollama-node3' in m else 'oracle' if 'opencode-go' in m else 'legacy'


for r in rows:
    r['seat'] = re.sub(r'^(ollama-(desktop|node3)|opencode-go)/', '', r['model'])
    r['host'] = host(r['model'])
    r['pass'] = r['opencodeExit'] == '0' and r['scope'] == 'PASS' and r['suite'] == 'PASS' and r['failsOnOld'] == 'PASS'
    r['w'] = int(r['writes']) if r['writes'].isdigit() else -1

print("== 1. corpus:", len(rows), "rows;", sum(r['pass'] for r in rows), "PASS (scope+suite+failsOnOld);",
      sum(r['opencodeExit'] != '0' for r in rows), "rows with exit!=0")
print("   by host:", dict(collections.Counter(r['host'] for r in rows)))


def wilson(k, n, z=1.96):
    if n == 0:
        return (0, 0)
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return ((c - h) / d, (c + h) / d)


def fisher2(a, b, c, d):
    n1, n2, k = a + b, c + d, a + c
    N = n1 + n2

    def pm(x):
        return math.comb(k, x) * math.comb(N - k, n1 - x) / math.comb(N, n1)

    obs = pm(a)
    return sum(pm(x) for x in range(max(0, k - n2), min(k, n1) + 1) if pm(x) <= obs + 1e-12)


TASKS = ['kane-04-singleton-up-to-n', 'lfc-01-listing-status-guard', 'kane-01-background-pair',
         'kane-03-saga-chapter-triggers', 'lfc-02-scryfall-headers', 'asohav-01-library-write-reporting',
         'lfc-03-status-transition-guard', 'kane-02-multiword-creature-type', 'asohav-02-changelog-uuid-id']
SEATS = ['qwen3.6:35b-a3b-coding', 'qwen3.5:9b', 'laguna-xs-2.1', 'qwen3-coder:30b-a3b',
         'nemotron-3.5-lightning', 'qwen3:14b', 'north-mini-code-1.0', 'qwen3:8b']
W = [r for r in rows if r['host'] == 'desktop' and r['timestamp'] >= '2026-09-26T15:00'
     and r['seat'] in SEATS + ['devstral:24b', 'devstral-small-2:24b']]
cell = collections.defaultdict(list)
for r in W:
    cell[(r['seat'], r['taskId'])].append(r)

print("\n== 2. step-6 window grid (latest graded row per cell; P=pass f=graded-fail 0=zero-write .=no row(timeout/infra); +n = extra rows)")
short = [t.split('-')[0] + t.split('-')[1] for t in TASKS]
print("   %-24s" % "seat", " ".join("%-7s" % s for s in short), "  pass/9")
tot = {}
for s in SEATS:
    out = []
    k = 0
    for t in TASKS:
        rs = sorted(cell.get((s, t), []), key=lambda r: r['timestamp'])
        if not rs:
            out.append(".")
            continue
        r = rs[-1]
        ch = 'P' if r['pass'] else ('0' if r['w'] == 0 else 'f')
        k += r['pass']
        out.append(ch + ("+%d" % (len(rs) - 1) if len(rs) > 1 else ""))
    tot[s] = k
    lo, hi = wilson(k, 9)
    print("   %-24s" % s, " ".join("%-7s" % o for o in out), "  %d/9  Wilson95=[%.2f,%.2f]" % (k, lo, hi))
print("   doc says 8,7,6,6,5,2,1,0 ; recomputed:", [tot[s] for s in SEATS])
nonov = []
for i, a in enumerate(SEATS):
    for b in SEATS[i + 1:]:
        la, ha = wilson(tot[a], 9)
        lb, hb = wilson(tot[b], 9)
        if la > hb or lb > ha:
            nonov.append((a.split(':')[0], b.split(':')[0]))
print("   pairs with NON-overlapping Wilson95:", nonov)

print("\n== 3. DP8 64k vs 32k: 3/15 vs 9/18 -> Fisher two-sided p = %.3f ; DP9 64k 24/36 vs 32k 2/12 (seat-confounded) p = %.4f"
      % (fisher2(3, 12, 9, 9), fisher2(24, 12, 2, 10)))

print("\n== 4. per-task pass rate in window (8 seats):")
for t in TASKS:
    k = sum(1 for s in SEATS if cell.get((s, t)) and sorted(cell[(s, t)], key=lambda r: r['timestamp'])[-1]['pass'])
    print("   %-38s %d/8" % (t, k))


def bucket(ts):
    return 'pre0922' if ts < '2026-09-22' else '0922-0925' if ts < '2026-09-26' else 'ge0926'


g = collections.defaultdict(list)
for r in rows:
    if r['opencodeExit'] == '0':
        g[(r['seat'], r['taskId'], bucket(r['timestamp']))].append(r['pass'])
multi = {k: v for k, v in g.items() if len(v) >= 2}
flip = {k: v for k, v in multi.items() if any(v) and not all(v)}
print("\n== 5. run-to-run noise: groups (seat,task,era) with >=2 graded rows:", len(multi), "; mixed PASS/FAIL:", len(flip))
for k, v in sorted(flip.items()):
    print("    ", k, "".join('P' if x else 'f' for x in v))

print("\n== 6. zero-write exit-0 rows per seat (window):", dict(collections.Counter(r['seat'] for r in W if r['w'] == 0)))

print("\n== 7. elapsed seconds of window PASSES (n / median / max):")
for s in SEATS:
    e = [float(r['elapsedSec']) for r in W if r['seat'] == s and r['pass']]
    if e:
        print("   %-24s n=%d median=%.0f max=%.0f" % (s, len(e), statistics.median(e), max(e)))

print("\n== 8. per-run JSON schema")
keys = collections.Counter()
n = 0
sample = None
for p in sorted(glob.glob('tasks-*.json')):
    try:
        d = json.load(open(p, encoding='utf-8-sig'))
    except Exception:
        continue
    if isinstance(d, dict):
        n += 1
        keys.update(d.keys())
        sample = (p, d)
print("  ", n, "json files; keys:", dict(keys.most_common()))
if sample:
    p, d = sample
    print("   sample:", p)
    for k, v in d.items():
        s = json.dumps(v)
        print("     %s: %s" % (k, s if len(s) < 140 else s[:137] + '...'))

print("\n== 9. transcript tails per seat (final step_finish reason; length events with EMPTY final step)")
seat_keys = [('qwen3-8-max', 'oracle'), ('devstral-small-2', 'devstral-small-2'), ('devstral', 'devstral:24b'),
             ('nemotron', 'nemotron'), ('laguna', 'laguna'), ('north-mini', 'north-mini'), ('qwen3.6', 'qwen3.6'),
             ('qwen3.5', 'qwen3.5'), ('qwen3-coder', 'qwen3-coder'), ('qwen3_14b', 'qwen3:14b'),
             ('qwen3-14b', 'qwen3:14b'), ('qwen3_8b', 'qwen3:8b'), ('qwen3-8b', 'qwen3:8b'), ('ornith', 'ornith'),
             ('lfm2.5', 'lfm2.5'), ('ministral', 'ministral')]


def seat_of(f):
    for k, v in seat_keys:
        if k in f:
            return v
    return '?'


tab = collections.defaultdict(collections.Counter)
for p in sorted(glob.glob('tasks-*.jsonl')):
    evs = []
    for line in open(p, encoding='utf-8', errors='replace'):
        line = line.strip()
        if not line:
            continue
        try:
            evs.append(json.loads(line))
        except Exception:
            pass
    c = tab[seat_of(os.path.basename(p))]
    c['n'] += 1
    if not evs:
        c['empty'] += 1
        continue
    sfs = [i for i, e in enumerate(evs) if e.get('type') == 'step_finish']
    sts = [i for i, e in enumerate(evs) if e.get('type') == 'step_start']
    if not sfs:
        c['no_step_finish'] += 1
        continue
    last = evs[sfs[-1]]['part']
    c['last=' + str(last.get('reason'))] += 1
    if last.get('reason') == 'length':
        between = evs[(sts[-1] + 1 if sts else 0):sfs[-1]]
        if not between:
            c['length_EMPTY_final_step'] += 1
        if last.get('tokens', {}).get('output') == 4096:
            c['length_at_4096'] += 1
for s, c in sorted(tab.items()):
    print("   %-18s" % s, dict(c))
