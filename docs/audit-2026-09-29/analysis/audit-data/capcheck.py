"""Independent re-derivation of the output-cap classification for exit-0 zero-write rows.

Rule under test (the one the harness will implement):
  cap hit  <=>  last step_finish has reason == 'length'
                AND no text/tool_use event after the last step_start
                AND tokens.output >= limit.output (limit known)
Limits at the time of the runs: 8192 for qwen3:14b and qwen3.6, 4096 for every other seat (AGENTS.md).
"""
import csv, glob, json, os, collections

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


def limit_for(model):
    m = model.split('/', 1)[1]
    return 8192 if m.startswith('qwen3:14b') or m.startswith('qwen3.6') else 4096


def ending(path):
    ev = []
    for l in open(path, encoding='utf-8-sig'):
        l = l.strip()
        if not l:
            continue
        try:
            ev.append(json.loads(l))
        except Exception:
            pass
    last_start = max((i for i, e in enumerate(ev) if e.get('type') == 'step_start'), default=-1)
    last_fin = max((i for i, e in enumerate(ev) if e.get('type') == 'step_finish'), default=-1)
    reason = out = None
    if last_fin >= 0:
        p = ev[last_fin].get('part', {})
        reason = p.get('reason')
        out = (p.get('tokens') or {}).get('output')
    tail = ev[last_start + 1:] if last_start >= 0 else ev
    content = any(e.get('type') in ('text', 'tool_use') for e in tail)
    types = collections.Counter(e.get('type') for e in ev)
    return reason, out, content, types, len(ev)


res = collections.defaultdict(lambda: [0, 0, []])   # seat -> [cap, genuine, notes]
missing = 0
for r in rows:
    if r['opencodeExit'] != '0' or r['writes'] != '0' or r['timestamp'] < '2026-09-22':
        continue
    j = J.get((r['taskId'], r['model'], r['timestamp']))
    tf = (j or {}).get('transcriptFile')
    path = os.path.join(R, tf) if tf else None
    seat = r['model'].split('/', 1)[1]
    if not path or not os.path.exists(path):
        missing += 1
        res[seat][2].append('NO TRANSCRIPT ' + r['timestamp'])
        continue
    reason, out, content, types, n = ending(path)
    lim = limit_for(r['model'])
    cap = (reason == 'length' and not content and out is not None and out >= lim)
    res[seat][0 if cap else 1] += 1
    res[seat][2].append('%s reason=%s out=%s lim=%s content=%s events=%d %s' % (r['timestamp'][5:16], reason, out, lim, content, n, 'CAP' if cap else 'genuine'))

tc = tg = 0
for seat, (c, g, notes) in sorted(res.items()):
    tc += c; tg += g
    print('%-28s cap %d  genuine %d' % (seat, c, g))
    for n in notes:
        print('     ', n)
print('TOTAL cap %d genuine %d (rows without transcript: %d) -> %d rows' % (tc, tg, missing, tc + tg + missing))
