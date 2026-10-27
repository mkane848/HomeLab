import csv, json, glob, os, re, collections

NEW = '/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/newmain/tests/results'
OUT = '/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/PER-ATTEMPT-2026-09-30.md'
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


def shape(r):
    if gp(r):
        return 'PASS'
    if r['scope'] != 'PASS':
        return 'FAIL scope (edited outside allowFiles)'
    if r['suite'] != 'PASS':
        return 'FAIL suite (build/test file broken)'
    if r['failsOnOld'] != 'PASS':
        return 'FAIL failsOnOld (test green on broken code)'
    return 'FAIL'


SEATS = ['qwen3.6:35b-a3b-coding', 'qwen3.5:9b', 'qwen3:14b']
CELLS = [('lfc-03-status-transition-guard', SEATS), ('kane-02-multiword-creature-type', SEATS), ('asohav-02-changelog-uuid-id', SEATS),
         ('kane-04-singleton-up-to-n', ['qwen3.5:9b']), ('lfc-02-scryfall-headers', ['qwen3.5:9b']), ('asohav-01-library-write-reporting', ['qwen3.5:9b'])]
DESIGN = {'qwen3.6:35b-a3b-coding': 65536, 'qwen3.5:9b': 65536, 'qwen3:14b': 32768}
CUR = {'lfc-03-status-transition-guard': '833A03061C7F', 'kane-02-multiword-creature-type': '2C70ABFF8F8A', 'asohav-02-changelog-uuid-id': '15771B923DC9',
       'kane-04-singleton-up-to-n': 'B63AF9A6F823', 'lfc-02-scryfall-headers': '0CDC9E50C546', 'asohav-01-library-write-reporting': '7ACA562BCD15'}
out = ['# Per-attempt table, N>1 protocol cells (2026-09-30, recomputed from tests/results at origin/main 20c3417)\n',
       'Same-config = current prompt sha, the seat\'s designed numCtx (64k for qwen3.6/qwen3.5, 32k for qwen3:14b), Ollama 0.34.3. Timeouts and infra crashes count as attempts; human-aborted runs do not. `oc` = opencode version stamped in the run JSON.\n',
       '| cell | # | when (UTC-4) | oc | writes | sec | s/su/foo | owner acc. | outcome |', '|---|---|---|---|---|---|---|---|---|']
summ = []
for t, seats in CELLS:
    for s in seats:
        att = []
        for r in rows:
            if r['taskId'] != t or r['model'] != 'ollama-desktop/' + s:
                continue
            j = J.get((t, r['model'], r['timestamp'])) or {}
            ctx = j.get('numCtx') or (32768 if r['timestamp'] >= '2026-09-22' else 16384)
            if j.get('promptSha256') == CUR[t] and ctx == DESIGN[s] and (j.get('ollamaVersion') or '').endswith('0.34.3'):
                a = j.get('acceptance')
                ast = (a.get('status') if isinstance(a, dict) else a) if a is not None else '-'
                att.append((r['timestamp'], j.get('opencodeVersion') or '?', r['writes'], r['elapsedSec'], '%s/%s/%s' % (r['scope'][0], r['suite'][0], r['failsOnOld'][0]), ast, shape(r)))
        for p in glob.glob(NEW + '/tasks-%s-*%s*_*.jsonl' % (t, s.replace(':', '_'))):
            m = re.search(r'_(INFRA|TIMEOUT)_(\d{8})-(\d{6})\.jsonl$', p)
            if m and (m.group(2) + m.group(3)) >= '20260927110000':
                ts = '%s-%s-%sT%s:%s:%s' % (m.group(2)[:4], m.group(2)[4:6], m.group(2)[6:], m.group(3)[:2], m.group(3)[2:4], m.group(3)[4:])
                att.append((ts, '?', '-', '-', '-', '-', 'TIMEOUT (1800 s cap)' if m.group(1) == 'TIMEOUT' else 'INFRA (context/template crash)'))
        att.sort()
        k = sum(1 for a in att if a[6] == 'PASS')
        for i, a in enumerate(att, 1):
            out.append('| %s / %s | %d | %s | %s | %s | %s | %s | %s | %s |' % (t.split('-')[0] + '-' + t.split('-')[1], s.split(':')[0], i, a[0][5:16], a[1], a[2], a[3], a[4], a[5], a[6]))
        summ.append('%s %s: %d/%d' % (t.split('-')[0] + '-' + t.split('-')[1], s.split(':')[0], k, len(att)))
out.append('\n**Cell tallies (same-config attempts):** ' + '; '.join(summ) + '\n')
open(OUT, 'w').write('\n'.join(out) + '\n')
print('wrote', OUT)
print('; '.join(summ))
