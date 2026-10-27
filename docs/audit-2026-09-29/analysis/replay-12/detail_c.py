import os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
from run_audit import load_passes, reset, run_tests, TASK, SHORT, A
from replay import replay, R
from crosscheck import fix_commit, show, REPO

want = [('kane-04', '09-29 16:39'), ('lfc-02', '09-29 16:54')]
for p in load_passes():
    s = SHORT[p['task']]
    stamp = p['ts'][5:16].replace('T', ' ')
    if (s, stamp) not in want:
        continue
    task = TASK[p['task']]; wt = os.path.join(A, 'wt', s); pin = task['benchBaseCommit']; fc = fix_commit(s, pin)
    reset(wt, pin); replay(os.path.join(R, p['json']['transcriptFile']), p['task'], wt)
    for f in task['srcRevertFiles']:
        open(os.path.join(wt, f), 'wb').write(show(s, fc, f))
    rc, summ, fails, out = run_tests(task, wt)
    out = re.sub(r'\x1b\[[0-9;]*m', '', out)
    print('=====', s, stamp, 'exit', rc, summ)
    i = out.find('Failed Tests')
    print(out[i:i + 1500])
    print('----- upstream source around the relevant lines')
    src = show(s, fc, task['srcRevertFiles'][0]).decode('utf-8')
    if s == 'kane-04':
        j = src.find('UP_TO_N')
        print(src[:200]); k = src.find('NUMBER_WORDS'); print(src[k - 100:k + 900]); print('...'); m = src.find('export function singletonLimit'); print(src[m:m + 1500])
    else:
        j = src.find('Accept')
        print(src[max(0, j - 900):j + 500])
