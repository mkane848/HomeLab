"""Cross-checks against the REAL upstream fix (the first commit after each pin on origin/main).

  (c) the model's tests, run against the upstream fix's source      -> should PASS (a test written for the bug, not for the model's own code)
  (d) the upstream fix's tests, run against the model's source      -> informational: does the model's fix satisfy what the project's own PR asserted?
  (d0) the upstream tests against the BASE source                   -> should FAIL (the upstream tests discriminate the bug; sanity for (d))
"""
import json, os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(__file__))
from run_audit import load_passes, sh, reset, run_tests, TASK, SHORT, A
from replay import replay, R

UP = os.path.join(os.path.dirname(A), 'upstream')
REPO = {'kane-02': 'KaneEnabler', 'kane-04': 'KaneEnabler', 'lfc-02': 'lfc-bot', 'asohav-02': 'ASoHaVCompanionApp'}


def fix_commit(short, pin):
    r = subprocess.run(['git', '-C', os.path.join(UP, REPO[short]), 'log', '--ancestry-path', '--reverse', '--format=%H', pin + '..origin/main'],
                       capture_output=True, text=True)
    return r.stdout.split()[0]


def show(short, commit, path):
    r = subprocess.run(['git', '-C', os.path.join(UP, REPO[short]), 'show', '%s:%s' % (commit, path)], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def main():
    passes = [p for p in load_passes() if SHORT[p['task']] in REPO]
    fixes = {}
    for p in passes:
        s = SHORT[p['task']]
        if s not in fixes:
            fixes[s] = fix_commit(s, TASK[p['task']]['benchBaseCommit'])
    print('upstream fix commits:', {k: v[:10] for k, v in fixes.items()})
    out = []
    for p in passes:
        s = SHORT[p['task']]; task = TASK[p['task']]; wt = os.path.join(A, 'wt', s); pin = task['benchBaseCommit']; fc = fixes[s]
        j = p['json']
        label = '%s|%s|%s' % (s, p['seat'], p['ts'][5:16].replace('T', ' '))
        srcs = {f: show(s, fc, f) for f in task['srcRevertFiles']}
        tests = {f: show(s, fc, f) for f in task['allowFiles'] if f.endswith('.test.ts')}
        rec = {'label': label, 'fix': fc[:10]}
        # (c) model tests on upstream source
        reset(wt, pin); replay(os.path.join(R, j['transcriptFile']), p['task'], wt)
        for f, b in srcs.items():
            open(os.path.join(wt, f), 'wb').write(b)
        rc, summ, fails, _ = run_tests(task, wt)
        rec['c_model_tests_on_upstream_src'] = {'exit': rc, 'summary': summ, 'fails': fails}
        # (d) upstream tests on model source
        reset(wt, pin); replay(os.path.join(R, j['transcriptFile']), p['task'], wt)
        for f, b in tests.items():
            open(os.path.join(wt, f), 'wb').write(b)
        rc, summ, fails, _ = run_tests(task, wt)
        rec['d_upstream_tests_on_model_src'] = {'exit': rc, 'summary': summ, 'fails': fails}
        out.append(rec)
        print('%s  (fix %s)\n   (c) model tests on the UPSTREAM source : exit %s %s %s\n   (d) upstream tests on the MODEL source  : exit %s %s %s' % (
            label, fc[:10], rec['c_model_tests_on_upstream_src']['exit'], rec['c_model_tests_on_upstream_src']['summary'], rec['c_model_tests_on_upstream_src']['fails'][:3],
            rec['d_upstream_tests_on_model_src']['exit'], rec['d_upstream_tests_on_model_src']['summary'], rec['d_upstream_tests_on_model_src']['fails'][:3]), flush=True)
    # (d0) upstream tests on the base source, once per task
    for s, fc in fixes.items():
        task = next(t for t in TASK.values() if SHORT.get(t['id']) == s); wt = os.path.join(A, 'wt', s)
        reset(wt, task['benchBaseCommit'])
        for f in task['allowFiles']:
            if f.endswith('.test.ts'):
                open(os.path.join(wt, f), 'wb').write(show(s, fc, f))
        rc, summ, fails, _ = run_tests(task, wt)
        print('(d0) %s: upstream tests on the BASE source: exit %s %s %s' % (s, rc, summ, fails[:2]), flush=True)
        out.append({'d0': s, 'exit': rc, 'summary': summ, 'fails': fails})
    json.dump(out, open(os.path.join(A, 'out', 'crosscheck.json'), 'w'), indent=1)


if __name__ == '__main__':
    main()
