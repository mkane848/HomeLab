"""DP11 replay audit: replay each of the 12 new passes onto its base and check it beyond the gates.

Steps per pass (all on a scratch worktree at the task's pinned base, never in the repo):
  1. replay the transcript's completed edit/write calls           (replay.py)
  2. diff vs base, scope vs allowFiles
  3. run the task's testCmd on the replayed tree                  (suite gate, reproduced)
  4. revert srcRevertFiles to base, keep the model's tests, rerun  (failsOnOld gate, reproduced)
  5. base test names / assertion counts / removed base lines       (weakening check)
"""
import csv, glob, json, os, re, subprocess, sys, shutil, time

sys.path.insert(0, os.path.dirname(__file__))
from replay import replay, events, R, A

MANIFEST = json.load(open('/home/user/HomeLab/tests/tasks/manifest.json', encoding='utf-8'))
TASK = {t['id']: t for t in MANIFEST['tasks']}
SHORT = {'lfc-03-status-transition-guard': 'lfc-03', 'lfc-02-scryfall-headers': 'lfc-02', 'kane-02-multiword-creature-type': 'kane-02',
         'kane-04-singleton-up-to-n': 'kane-04', 'asohav-02-changelog-uuid-id': 'asohav-02'}
SEATS = {'ollama-desktop/qwen3.6:35b-a3b-coding': 'qwen3.6', 'ollama-desktop/qwen3.5:9b': 'qwen3.5'}


def load_passes():
    rows = list(csv.DictReader(open(R + '/tasks-summary.tsv', encoding='utf-8-sig'), delimiter='\t'))
    J = {}
    for p in glob.glob(R + '/tasks-*.json'):
        try:
            d = json.load(open(p, encoding='utf-8-sig'))
        except Exception:
            continue
        if isinstance(d, dict) and 'taskId' in d:
            J[(d['taskId'], d['model'], d['timestamp'])] = d
    out = []
    for r in rows:
        if r['model'] not in SEATS or r['taskId'] not in SHORT:
            continue
        if not (r['opencodeExit'] == '0' and r['scope'] == 'PASS' and r['suite'] == 'PASS' and r['failsOnOld'] == 'PASS'):
            continue
        j = J.get((r['taskId'], r['model'], r['timestamp'])) or {}
        if j.get('opencodeVersion') != '1.18.33':
            continue
        out.append({'task': r['taskId'], 'seat': SEATS[r['model']], 'ts': r['timestamp'], 'json': j})
    out.sort(key=lambda x: (x['task'], x['seat'], x['ts']))
    return out


def sh(args, cwd, timeout=600, env=None):
    e = dict(os.environ)
    e.update(env or {})
    e['CI'] = '1'
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=e)
    return r.returncode, (r.stdout + r.stderr)


def reset(wt, pin):
    sh(['git', 'reset', '-q', '--hard', pin], wt)
    sh(['git', 'clean', '-fdq'], wt)


def task_env(task):
    """The environment every gate run gets. MANAPOOL_API_KEY is blanked for all tasks. asohav-02's model tests import the
    real repo.ts, which imports pgPool.ts, which throws at import time unless DATABASE_URL is set: the owner's harness
    process had it set on 2026-09-29 (the models' own vitest runs show the import error on 09-27 and never on 09-29), so
    the audit stubs it (new Pool() does not connect until the first query). AUDIT_NO_DB=1 leaves it unset (the control)."""
    e = {'MANAPOOL_API_KEY': ''}
    if task['id'].startswith('asohav') and not os.environ.get('AUDIT_NO_DB'):
        e['DATABASE_URL'] = 'postgres://stub:stub@127.0.0.1:9/stub'
    return e


def run_tests(task, wt):
    cwd = os.path.join(wt, task['testDir'])
    rc, out = sh(task['testCmd'], cwd, timeout=900, env=task_env(task))
    m = re.findall(r'Tests\s+(?:(\d+) failed \| )?(\d+) passed(?: \((\d+)\))?', out)
    summ = ' | '.join(' '.join(x for x in t if x) for t in m[-1:]) if m else ''
    fails = re.findall(r'FAIL\s+.*?>\s*(.+)', out)
    return rc, summ, fails[:6], out


TEST_NAME = re.compile(r"""\b(?:it|test)(?:\.each\([^)]*\))?\(\s*(?P<q>[`'"])(?P<n>.*?)(?P=q)""", re.S)


def test_names(text):
    return [m.group('n') for m in TEST_NAME.finditer(text)]


def audit(p, keep_log=True):
    tid = p['task']; task = TASK[tid]; short = SHORT[tid]
    wt = os.path.join(A, 'wt', short)
    pin = task['benchBaseCommit']
    j = p['json']
    label = '%s|%s|%s' % (short, p['seat'], p['ts'][5:16].replace('T', ' '))
    os.makedirs(os.path.join(A, 'out'), exist_ok=True)
    stem = '%s_%s_%s' % (short, p['seat'], p['ts'].replace(':', '').replace('-', '')[4:13])
    res = {'label': label, 'stem': stem, 'task': tid, 'seat': p['seat'], 'ts': p['ts'], 'writes': j.get('writes'),
           'recorded': j.get('gates'), 'transcript': j.get('transcriptFile')}
    reset(wt, pin)
    recs = replay(os.path.join(R, j['transcriptFile']), tid, wt)
    res['calls'] = [(r['tool'], r['file'], r['how']) for r in recs]
    res['misses'] = [r for r in recs if r['how'] in ('MISS', 'UNMAPPED PATH')]
    # `patch` leaves .rej/.orig behind when a recorded diff did not apply and the exact replacement was used
    for junk in glob.glob(os.path.join(wt, '**', '*.rej'), recursive=True) + glob.glob(os.path.join(wt, '**', '*.orig'), recursive=True):
        if 'node_modules' not in junk:
            os.unlink(junk)
    # scope
    rc, out = sh(['git', 'status', '--porcelain'], wt)
    changed = [l[3:].strip() for l in out.splitlines() if l.strip()]
    res['changed'] = changed
    res['out_of_scope'] = [c for c in changed if c not in task['allowFiles']]
    rc, dtxt = sh(['git', 'diff', '--no-color'], wt)
    untracked = [c for c in changed if not os.path.exists(os.path.join(wt, c)) is False and c not in dtxt]
    open(os.path.join(A, 'out', stem + '.diff'), 'w').write(dtxt)
    rc, stat = sh(['git', 'diff', '--stat', '--no-color'], wt)
    res['stat'] = stat.strip().splitlines()[-1] if stat.strip() else '(no diff)'
    # suite gate
    rc, summ, fails, out = run_tests(task, wt)
    res['suite'] = {'exit': rc, 'summary': summ, 'fails': fails}
    if keep_log:
        open(os.path.join(A, 'out', stem + '.suite.log'), 'w').write(out)
    # failsOnOld gate: revert source files, keep the model's tests
    saved = {f: open(os.path.join(wt, f), 'rb').read() for f in task['srcRevertFiles']}
    sh(['git', 'checkout', pin, '--'] + task['srcRevertFiles'], wt)
    rc2, summ2, fails2, out2 = run_tests(task, wt)
    res['failsOnOld'] = {'exit': rc2, 'summary': summ2, 'fails': fails2}
    for f, b in saved.items():
        open(os.path.join(wt, f), 'wb').write(b)
    # weakening check on test files
    weak = {}
    for f in task['allowFiles']:
        if not f.endswith('.test.ts'):
            continue
        rc, base_txt = sh(['git', 'show', '%s:%s' % (pin, f)], wt)
        base_txt = base_txt if rc == 0 else ''
        new_txt = open(os.path.join(wt, f), encoding='utf-8', errors='replace').read() if os.path.exists(os.path.join(wt, f)) else ''
        bn, nn = test_names(base_txt), test_names(new_txt)
        lost = [n for n in bn if n not in nn]
        rc, d0 = sh(['git', 'diff', '-U0', '--no-color', '--', f], wt)
        removed = [l[1:] for l in d0.splitlines() if l.startswith('-') and not l.startswith('---')]
        weak[f] = {'base_tests': len(bn), 'now_tests': len(nn), 'lost_names': lost, 'base_expects': base_txt.count('expect('),
                   'now_expects': new_txt.count('expect('), 'removed_base_lines': removed[:12]}
    res['weakening'] = weak
    return res


if __name__ == '__main__':
    passes = load_passes()
    want = sys.argv[1:]
    results = []
    for i, p in enumerate(passes):
        lab = '%s/%s/%s' % (SHORT[p['task']], p['seat'], p['ts'][5:16])
        if want and not any(w in lab for w in want):
            continue
        t0 = time.time()
        r = audit(p)
        results.append(r)
        print('\n#%d %s  (%.0fs)' % (i + 1, r['label'], time.time() - t0))
        print('  calls:', ', '.join('%s %s [%s]' % (c[0], c[1].split('/')[-1], c[2]) for c in r['calls']))
        print('  misses:', r['misses'] or 'none', '| out of scope:', r['out_of_scope'] or 'none', '|', r['stat'])
        print('  suite: exit %s %s   (recorded gate: %s)' % (r['suite']['exit'], r['suite']['summary'], (r['recorded'] or {}).get('suite')))
        print('  failsOnOld: exit %s %s %s   (recorded: %s)' % (r['failsOnOld']['exit'], r['failsOnOld']['summary'], r['failsOnOld']['fails'][:2], (r['recorded'] or {}).get('failsOnOld')))
        for f, w in r['weakening'].items():
            print('  %s: tests %d -> %d, expects %d -> %d, lost names %s, removed base lines %d' % (f.split('/')[-1], w['base_tests'], w['now_tests'], w['base_expects'], w['now_expects'], w['lost_names'] or 'none', len(w['removed_base_lines'])))
    json.dump(results, open(os.path.join(A, 'out', 'results-%s.json' % ('all' if not want else '_'.join(w.replace('/', '-') for w in want))), 'w'), indent=1)
