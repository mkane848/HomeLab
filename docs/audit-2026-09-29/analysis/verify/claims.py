import csv, json, glob, os, re, collections
R = '/home/user/HomeLab/tests/results'

# 1. probe counts on Ollama 0.34.3
rows = list(csv.DictReader(open(R + '/toolcalls-summary.tsv'), delimiter='\t'))
by = collections.defaultdict(set)
for r in rows:
    if r['ollamaVersion'] == '0.34.3':
        by[r['model']].add(r['status'])
mixed = {m: s for m, s in by.items() if len(s) > 1}
passing = sorted(m for m, s in by.items() if s == {'PASS'})
failing = sorted(m for m, s in by.items() if s == {'FAIL'})
print("probe rows on 0.34.3: %d; distinct models: %d; PASS: %d; FAIL: %d; models with mixed results across rounds/hosts: %s" % (len(rows), len(by), len(passing), len(failing), mixed or 'none'))
print("  PASS:", ', '.join(passing))
print("  FAIL:", ', '.join(failing))

# 2. zero-write census (exit 0, writes 0, since 2026-09-22) and cap-hit share, from transcripts
tsv = list(csv.DictReader(open(R + '/tasks-summary.tsv'), delimiter='\t'))
print("\ntasks-summary rows: %d ; all-gates PASS: %d" % (len(tsv), sum(1 for r in tsv if r['opencodeExit'] == '0' and r['scope'] == 'PASS' and r['suite'] == 'PASS' and r['failsOnOld'] == 'PASS')))
zw = [r for r in tsv if r['opencodeExit'] == '0' and r['writes'] == '0' and r['timestamp'] >= '2026-09-22']
print("exit-0 zero-write rows since 2026-09-22: %d" % len(zw))

# 3. writes==0 by seat overall for the two 'lfm2.5 8/8' and 'devstral 4/4' claims
c = collections.Counter(); t = collections.Counter()
for r in tsv:
    s = r['model']
    if 'lfm2.5' in s or s.endswith('devstral:24b'):
        t[s] += 1
        if r['opencodeExit'] == '0' and r['writes'] == '0':
            c[s] += 1
print("zero-write / graded rows:", {k: '%d/%d' % (c[k], t[k]) for k in t})

# 4. opencode versions stamped in the JSONs
ver = collections.Counter()
n = 0
for p in glob.glob(R + '/tasks-*.json'):
    try:
        d = json.load(open(p, encoding='utf-8-sig'))
    except Exception:
        continue
    if isinstance(d, dict) and 'taskId' in d:
        n += 1
        ver[d.get('opencodeVersion')] += 1
print("\nresult JSONs: %d ; opencode versions: %s" % (n, dict(ver)))
