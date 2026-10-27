import csv, json, glob, os, re, collections, datetime, sys

NEW = '/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/newmain/tests/results'
OLD = '/home/user/HomeLab/tests/results'


def load(d):
    return list(csv.DictReader(open(d + '/tasks-summary.tsv'), delimiter='\t'))


old_rows, new_rows = load(OLD), load(NEW)
old_keys = {(r['timestamp'], r['taskId'], r['model']) for r in old_rows}
delta = [r for r in new_rows if (r['timestamp'], r['taskId'], r['model']) not in old_keys]
print("rows: old=%d new=%d delta=%d" % (len(old_rows), len(new_rows), len(delta)))

# index json by (taskId, model, ts)
J = {}
for p in glob.glob(NEW + '/tasks-*.json'):
    try:
        d = json.load(open(p, encoding='utf-8-sig'))
    except Exception:
        continue
    if isinstance(d, dict) and 'taskId' in d:
        J[(d['taskId'], d['model'], d['timestamp'])] = d


def jfor(r):
    return J.get((r['taskId'], r['model'], r['timestamp']))


def gp(r):
    return r['scope'] == 'PASS' and r['suite'] == 'PASS' and r['failsOnOld'] == 'PASS' and r['opencodeExit'] == '0'


print("\n== delta rows (new since my checkout)")
print("%-16s %-9s %-24s %-3s %-13s %-9s %-7s %-6s %-8s %s" % ("timestamp", "task", "seat", "wr", "s/su/foo", "accept", "sec", "numCtx", "opencode", "verdict"))
for r in sorted(delta, key=lambda r: r['timestamp']):
    j = jfor(r) or {}
    a = j.get('acceptance')
    ast = (a.get('status') if isinstance(a, dict) else a) if a is not None else '-'
    print("%-16s %-9s %-24s %-3s %-13s %-9s %-7s %-6s %-8s %s" % (
        r['timestamp'][5:16], r['taskId'][:9], r['model'].split('/')[-1][:24], r['writes'],
        "%s/%s/%s" % (r['scope'][0], r['suite'][0], r['failsOnOld'][0]), ast, r['elapsedSec'],
        j.get('numCtx', '-'), j.get('opencodeVersion', '-'), 'PASS' if gp(r) else 'FAIL'))

print("\n== distinct config stamps across ALL json (opencodeVersion / ollamaVersion), counts")
c = collections.Counter()
for j in J.values():
    c[(j.get('opencodeVersion'), j.get('ollamaVersion'))] += 1
for k, v in sorted(c.items(), key=lambda kv: str(kv[0])):
    print("  ", k, v)

# non-row transcripts new since old
old_files = set(os.path.basename(p) for p in glob.glob(OLD + '/tasks-*'))
newf = sorted(os.path.basename(p) for p in glob.glob(NEW + '/tasks-*.jsonl') if os.path.basename(p) not in old_files and re.search(r'_(INFRA|TIMEOUT|ABORTED)_', p))
print("\n== new ungraded transcripts:", newf)

# protocol cells
SEATS = ['qwen3.6:35b-a3b-coding', 'qwen3.5:9b', 'qwen3:14b']
TASKS = ['lfc-03-status-transition-guard', 'kane-02-multiword-creature-type', 'asohav-02-changelog-uuid-id']
CUR = {'lfc-03-status-transition-guard': '833A03061C7F', 'kane-02-multiword-creature-type': '2C70ABFF8F8A', 'asohav-02-changelog-uuid-id': '15771B923DC9'}
CTX = {'qwen3.6:35b-a3b-coding': 65536, 'qwen3.5:9b': 65536, 'qwen3:14b': 32768}
print("\n== protocol cells: same-config graded rows (current prompt sha, seat's designed numCtx) + ungraded transcripts")
allrows = new_rows
for t in TASKS:
    for s in SEATS:
        rows = [r for r in allrows if r['taskId'] == t and r['model'] == 'ollama-desktop/' + s]
        same, other = [], []
        for r in rows:
            j = jfor(r) or {}
            ok = j.get('promptSha256') == CUR[t] and j.get('numCtx') == CTX[s]
            (same if ok else other).append(r)
        tr = [os.path.basename(p) for p in glob.glob(NEW + '/tasks-%s-*%s*_*.jsonl' % (t, s.replace(':', '_'))) if re.search(r'_(INFRA|TIMEOUT|ABORTED)_', p)]
        ungr_same = [x for x in tr if x[-20:-6] >= '20260927-000000']
        line = "".join('P' if gp(r) else 'f' for r in sorted(same, key=lambda r: r['timestamp']))
        print("  %-30s %-24s same-config rows: %-8s (%d)  other-config rows: %d  ungraded transcripts since 09-27: %s" % (t[:30], s, line, len(same), len(other), [re.search(r'_(INFRA|TIMEOUT|ABORTED)_', x).group(1) for x in ungr_same]))
