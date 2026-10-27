import csv, json, glob, os, re, datetime, collections
os.chdir('/home/user/HomeLab/tests/results')
rows = list(csv.DictReader(open('tasks-summary.tsv'), delimiter='\t'))
for r in rows:
    r['t'] = datetime.datetime.fromisoformat(r['timestamp'])


def match_row(fname):
    m = re.search(r'_(\d{8})-(\d{6})\.jsonl$', fname)
    if not m:
        return None
    t = datetime.datetime.strptime(m.group(1) + m.group(2), '%Y%m%d%H%M%S')
    task = re.match(r'tasks-(.+?)-(ollama|qwen3|devstral)', fname)
    best = None
    for r in rows:
        if task and not r['taskId'].startswith(task.group(1)):
            continue
        d = abs((r['t'] - t).total_seconds())
        if d <= 5 and (best is None or d < best[0]):
            best = (d, r)
    return best[1] if best else None


out = []
for p in sorted(glob.glob('tasks-*.jsonl')):
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
    if last.get('reason') != 'length':
        continue
    between = evs[(sts[-1] + 1 if sts else 0):sfs[-1]]
    if between:
        continue
    tok = last.get('tokens', {})
    r = match_row(os.path.basename(p))
    flag = ('INFRA' if '_INFRA_' in p else 'TIMEOUT' if '_TIMEOUT_' in p else 'row')
    if r:
        res = 'PASS' if (r['scope'] == 'PASS' and r['suite'] == 'PASS' and r['failsOnOld'] == 'PASS') else 'FAIL'
        info = 'writes=%s %s' % (r['writes'], res)
    else:
        info = 'no-row'
    out.append((os.path.basename(p)[:12] + '..' + os.path.basename(p)[-52:], tok.get('output'), tok.get('input'), flag, info))
print("transcripts whose FINAL step is empty and ended by finish=length:", len(out))
for o in out:
    print("  ", o)
