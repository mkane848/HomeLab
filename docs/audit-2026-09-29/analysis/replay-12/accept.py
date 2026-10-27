import os, re, sys, glob
sys.path.insert(0, os.path.dirname(__file__))
from run_audit import load_passes, reset, sh, run_tests, TASK, SHORT, A
from replay import replay, R

ACC = '3215aafde5f8eb6278d662af24cb01a6fab10eb0'
tid = 'lfc-03-status-transition-guard'
task = TASK[tid]; wt = os.path.join(A, 'wt', 'lfc-03'); pin = task['benchBaseCommit']
f = task['acceptance']['files'][0]

def clean(s): return re.sub(r'\x1b\[[0-9;]*m', '', s)

def run_acc(label):
    rc, summ, fails, out = run_tests(task, wt)
    out = clean(out)
    m = re.findall(r'Tests\s+(?:(\d+) failed \| )?(\d+) passed', out)
    print('%-34s exit %s | %s | failing: %s' % (label, rc, summ or out[-200:], [x[:90] for x in fails[:4]]))

# base source + owner's tests (must fail: the tests discriminate the bug)
reset(wt, pin)
sh(['git', 'checkout', ACC, '--', f], wt)
run_acc('BASE source + owner tests')
for p in load_passes():
    if SHORT[p['task']] != 'lfc-03':
        continue
    reset(wt, pin)
    replay(os.path.join(R, p['json']['transcriptFile']), tid, wt)
    mine = open(os.path.join(wt, f), 'rb').read()
    sh(['git', 'checkout', ACC, '--', f], wt)
    run_acc('qwen3.6 %s + owner tests' % p['ts'][5:16].replace('T', ' '))
    open(os.path.join(wt, f), 'wb').write(mine)
# how many tests does the owner's block hold, and does it cover expired?
rc, txt = sh(['git', 'show', '%s:%s' % (ACC, f)], wt)
print('owner file mentions expired:', txt.count('expired'), 'times; it( count:', len(re.findall(r'\bit\(', txt)))
