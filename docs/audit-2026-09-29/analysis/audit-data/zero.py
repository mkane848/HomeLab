import csv, json, glob, os, re, datetime, collections
os.chdir('/home/user/HomeLab/tests/results')
rows = list(csv.DictReader(open('tasks-summary.tsv'), delimiter='\t'))
# index transcripts by (taskId-prefix, timestamp) -> capped-empty?
capped = set()
for p in glob.glob('tasks-*.jsonl'):
    evs = []
    for line in open(p, encoding='utf-8', errors='replace'):
        line = line.strip()
        if line:
            try:
                evs.append(json.loads(line))
            except Exception:
                pass
    sfs = [i for i, e in enumerate(evs) if e.get('type') == 'step_finish']
    sts = [i for i, e in enumerate(evs) if e.get('type') == 'step_start']
    if not sfs:
        continue
    last = evs[sfs[-1]]['part']
    if last.get('reason') == 'length' and not evs[(sts[-1] + 1 if sts else 0):sfs[-1]] and last.get('tokens', {}).get('output') == 4096:
        m = re.search(r'_(\d{8})-(\d{6})\.jsonl$', p)
        if m:
            capped.add((p.split('-ollama')[0].replace('tasks-', '')[:20], datetime.datetime.strptime(m.group(1) + m.group(2), '%Y%m%d%H%M%S')))


def is_capped(r):
    t = datetime.datetime.fromisoformat(r['timestamp'])
    for (_, ct) in capped:
        if abs((ct - t).total_seconds()) <= 5:
            return True
    return False


z = collections.defaultdict(lambda: [0, 0])
for r in rows:
    if r['opencodeExit'] != '0' or r['writes'] != '0' or r['timestamp'] < '2026-09-22':
        continue
    seat = re.sub(r'^(ollama-(desktop|node3)|opencode-go)/', '', r['model'])
    if 'node3' in r['model']:
        seat = 'node3:' + seat
    z[seat][0] += 1
    z[seat][1] += is_capped(r)
print("post-2026-09-22 exit-0 zero-write rows by seat: [total, ended by empty 4096-token cap hit]")
tt = tc = 0
for s, (a, b) in sorted(z.items()):
    print("  %-30s %2d  %2d" % (s, a, b))
    tt += a
    tc += b
print("  %-30s %2d  %2d" % ("ALL", tt, tc))
