"""Which environment does each recorded asohav-02 gate result match?

asohav-02's model-written test file imports the real repo.ts -> pgPool.ts, which throws at import time without
DATABASE_URL. For every graded asohav-02 row with replayable edits, replay the transcript onto the pinned base and run the
suite gate and the failsOnOld gate twice: with DATABASE_URL unset and with a stub. A recorded gate result that matches only
one variant says which environment the harness process had when the row was made.
"""
import csv, glob, json, os, re, sys

sys.path.insert(0, os.path.dirname(__file__))
import run_audit
from run_audit import sh, reset, run_tests, TASK, A
from replay import replay, events, R

TID = 'asohav-02-changelog-uuid-id'
task = TASK[TID]
wt = os.path.join(A, 'wt', 'asohav-02')
pin = task['benchBaseCommit']
BASHW = re.compile(r'(>>?\s*\S|sed\s+-i|\btee\b|\bmv\s|\bcp\s|\brm\s|git\s+(checkout|stash|restore|reset|apply|clean)|\bpatch\b|Set-Content|Out-File|Remove-Item|New-Item)')


def rows():
    out = []
    J = {}
    for p in glob.glob(R + '/tasks-*.json'):
        try:
            d = json.load(open(p, encoding='utf-8-sig'))
        except Exception:
            continue
        if isinstance(d, dict) and d.get('taskId') == TID:
            J[(d['model'], d['timestamp'])] = d
    for r in csv.DictReader(open(R + '/tasks-summary.tsv', encoding='utf-8-sig'), delimiter='\t'):
        if r['taskId'] != TID or r['opencodeExit'] != '0':
            continue
        j = J.get((r['model'], r['timestamp']))
        if not j or not j.get('transcriptFile'):
            continue
        out.append((r, j))
    out.sort(key=lambda x: x[0]['timestamp'])
    return out


def bash_side_effects(path):
    hits = []
    for e in events(path):
        if e.get('type') == 'tool_use' and e['part'].get('tool') == 'bash':
            c = (e['part']['state'].get('input') or {}).get('command', '')
            if BASHW.search(c) and 'vitest' not in c.split('|')[0][:30]:
                hits.append(c.replace('\n', ' ')[:90])
    return hits


def gates(no_db):
    if no_db:
        os.environ['AUDIT_NO_DB'] = '1'
    else:
        os.environ.pop('AUDIT_NO_DB', None)
    rc, summ, fails, out = run_tests(task, wt)
    load_err = 'DATABASE_URL must be set' in out
    suite = 'PASS' if rc == 0 else 'FAIL'
    saved = {f: open(os.path.join(wt, f), 'rb').read() for f in task['srcRevertFiles']}
    sh(['git', 'checkout', pin, '--'] + task['srcRevertFiles'], wt)
    rc2, summ2, fails2, out2 = run_tests(task, wt)
    for f, b in saved.items():
        open(os.path.join(wt, f), 'wb').write(b)
    foo = 'PASS' if rc2 != 0 else 'FAIL'
    reverted_load_only = (rc2 != 0 and 'DATABASE_URL must be set' in out2 and not fails2)
    return {'suite': suite, 'fOO': foo, 'load_err_in_suite': load_err, 'fOO_is_load_error_only': reverted_load_only}


def main():
    res = []
    for r, j in rows():
        label = '%s %s' % (r['timestamp'][5:16].replace('T', ' '), r['model'].split('/')[-1][:24])
        reset(wt, pin)
        recs = replay(os.path.join(R, j['transcriptFile']), TID, wt)
        for junk in glob.glob(os.path.join(wt, '**', '*.rej'), recursive=True) + glob.glob(os.path.join(wt, '**', '*.orig'), recursive=True):
            if 'node_modules' not in junk:
                os.unlink(junk)
        misses = [x for x in recs if x['how'] in ('MISS', 'UNMAPPED PATH')]
        applied = [x for x in recs if x['how'] not in ('MISS', 'UNMAPPED PATH') and not x['how'].startswith('skipped')]
        rc, st = sh(['git', 'status', '--porcelain'], wt)
        changed = sorted(l[3:].strip() for l in st.splitlines() if l.strip())
        has_src = any(c.endswith('repo.ts') for c in changed)
        has_test = any(c.endswith('.test.ts') for c in changed)
        side = bash_side_effects(os.path.join(R, j['transcriptFile']))
        rec = {'label': label, 'ts': r['timestamp'], 'model': r['model'], 'recorded': {'scope': r['scope'], 'suite': r['suite'], 'fOO': r['failsOnOld']},
               'applied': len(applied), 'misses': len(misses), 'changed': changed, 'bash_side_effects': side}
        if applied and has_test:
            rec['no_db'] = gates(True)
            rec['db'] = gates(False)
        res.append(rec)
        nd, db = rec.get('no_db'), rec.get('db')
        print('%-34s recorded suite %-4s fOO %-4s | replay no-DB: %s | with-DB: %s | applied %d miss %d%s' % (
            label, r['suite'], r['failsOnOld'],
            ('suite %s fOO %s%s' % (nd['suite'], nd['fOO'], ' (load error only)' if nd['fOO_is_load_error_only'] else '')) if nd else 'n/a (no test file / no edits)',
            ('suite %s fOO %s' % (db['suite'], db['fOO'])) if db else 'n/a',
            len(applied), len(misses), ('  bash-side-effects: %d' % len(side)) if side else ''), flush=True)
    json.dump(res, open(os.path.join(A, 'out', 'envcheck.json'), 'w'), indent=1)


if __name__ == '__main__':
    main()
