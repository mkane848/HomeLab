import json, glob, os
os.chdir('/home/user/HomeLab/tests/results')
print("%-42s %-6s %-22s %s" % ("run (model, timestamp)", "writes", "gates s/su/foo", "owner-acceptance"))
n_gate = n_acc = n_both = 0
rows = []
for p in sorted(glob.glob('tasks-lfc-03*.json')):
    d = json.load(open(p, encoding='utf-8-sig'))
    g = d['gates']
    a = d.get('acceptance') or {}
    st = a.get('status') if isinstance(a, dict) else a
    detail = ''
    if isinstance(a, dict):
        detail = ' '.join('%s=%s' % (k, v) for k, v in a.items() if k in ('passed', 'failed', 'total', 'summary', 'tests'))[:60]
    gp = g['scope'] == 'PASS' and g['suite'] == 'PASS' and g['failsOnOld'] == 'PASS'
    n_gate += gp
    n_acc += (st == 'PASS')
    n_both += (gp and st == 'PASS')
    rows.append((d['timestamp'], "%s %s" % (d['model'].split('/')[-1], d['timestamp'][5:16]), d['writes'], "%s/%s/%s" % (g['scope'], g['suite'], g['failsOnOld']), "%s %s" % (st, detail)))
for r in sorted(rows):
    print("%-42s %-6s %-22s %s" % r[1:])
print("\nlfc-03 runs:", len(rows), " all-gates PASS:", n_gate, " owner-acceptance PASS:", n_acc, " both:", n_both)
