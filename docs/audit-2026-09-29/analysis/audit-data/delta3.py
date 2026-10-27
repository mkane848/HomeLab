import csv, json, glob, os, re, math, collections, itertools

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


def fisher2(a, b, c, d):
    n1, n2, k = a + b, c + d, a + c; N = n1 + n2
    pm = lambda x: math.comb(k, x) * math.comb(N - k, n1 - x) / math.comb(N, n1)
    o = pm(a); return sum(pm(x) for x in range(max(0, k - n2), min(k, n1) + 1) if pm(x) <= o + 1e-12)


# same-config groups (0.34.3, stamped or inferred ctx, current prompt sha = the sha shared by the majority)
G = collections.defaultdict(list)
for r in rows:
    if r['opencodeExit'] != '0' or r['timestamp'] < '2026-09-22':
        continue
    j = J.get((r['taskId'], r['model'], r['timestamp'])) or {}
    if not (j.get('ollamaVersion') or '').endswith('0.34.3'):
        continue
    ctx = j.get('numCtx') or 32768
    G[(r['model'], r['taskId'], ctx, j.get('promptSha256'))].append((r['timestamp'], gp(r), j.get('opencodeVersion'), r['timestamp'][:10]))

within_c = within_d = cross_c = cross_d = 0
w_pairs, x_pairs = [], []
for k, v in G.items():
    v.sort()
    for a, b in itertools.combinations(v, 2):
        same_oc = a[2] == b[2]
        same_batch = same_oc and a[3] == b[3] and (abs((int(b[0][11:13]) * 60 + int(b[0][14:16])) - (int(a[0][11:13]) * 60 + int(a[0][14:16]))) < 240)
        conc = a[1] == b[1]
        if same_batch:
            w_pairs.append(conc)
        else:
            x_pairs.append(conc)
print("pairs of same-config rows (Ollama 0.34.3, same prompt sha, same numCtx):")
print("  same opencode version AND same day, <4h apart (back-to-back batch): %d pairs, discordant %d" % (len(w_pairs), w_pairs.count(False)))
print("  different opencode version or day (across batches):              %d pairs, discordant %d" % (len(x_pairs), x_pairs.count(False)))
print("  Fisher two-sided on discordance rate: p = %.3f" % fisher2(w_pairs.count(False), w_pairs.count(True), x_pairs.count(False), x_pairs.count(True)))

# seat totals over ALL tasks, same-config (64k for the six, 32k for dense), timeouts/infra since 09-27 counted as misses
DESIGN = {'qwen3.6:35b-a3b-coding': 65536, 'qwen3.5:9b': 65536}
tot = {}
for s, ctx in DESIGN.items():
    k = n = 0
    per = {}
    for (m, t, c, sha), v in G.items():
        if m == 'ollama-desktop/' + s and c == ctx:
            kk = sum(x[1] for x in v); k += kk; n += len(v); per[t.split('-')[0] + t.split('-')[1]] = (kk, len(v))
    # ungraded attempts at 64k (>= 09-27T11) : TIMEOUT / INFRA
    ung = 0
    for p in glob.glob(NEW + '/tasks-*.jsonl'):
        b = os.path.basename(p)
        m = re.search(r'_(INFRA|TIMEOUT)_(\d{8})-(\d{6})\.jsonl$', b)
        if m and s.replace(':', '_') in b and (m.group(2) + m.group(3)) >= '20260927110000':
            ung += 1
    tot[s] = (k, n + ung, per, ung)
for s, (k, n, per, ung) in tot.items():
    print("\n%s all-task same-config attempts: %d/%d (incl. %d ungraded timeout/infra at 64k)" % (s, k, n, ung))
    print("   per task (graded only):", per)
a, b = tot['qwen3.6:35b-a3b-coding'], tot['qwen3.5:9b']
print("\nFisher two-sided qwen3.6 %d/%d vs qwen3.5 %d/%d : p = %.3f" % (a[0], a[1], b[0], b[1], fisher2(a[0], a[1] - a[0], b[0], b[1] - b[0])))
