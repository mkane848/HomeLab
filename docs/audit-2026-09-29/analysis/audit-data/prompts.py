import json, glob, os, collections
os.chdir('/home/user/HomeLab/tests/results')
by = collections.defaultdict(lambda: collections.defaultdict(list))
acc = collections.Counter()
for p in sorted(glob.glob('tasks-*.json')):
    try:
        d = json.load(open(p, encoding='utf-8-sig'))
    except Exception:
        continue
    if not isinstance(d, dict) or 'taskId' not in d:
        continue
    by[d['taskId']][d.get('promptSha256')].append(d['timestamp'][:10])
    a = d.get('acceptance')
    if a is not None:
        acc[(d['taskId'], a.get('status') if isinstance(a, dict) else str(a))] += 1
print("distinct prompt shas per task (sha -> n runs, date range)")
for t, m in sorted(by.items()):
    print(" ", t)
    for sha, ds in sorted(m.items(), key=lambda kv: min(kv[1])):
        print("     %-14s n=%-3d %s..%s" % (sha, len(ds), min(ds), max(ds)))
print("\nacceptance field census:", dict(acc))
