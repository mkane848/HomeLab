import os, re, sys, glob, csv, json
sys.path.insert(0, os.path.dirname(__file__))
import envcheck
from envcheck import *
want = ['09-27T14:47', '09-27T15:51', '09-27T10:07']
for r, j in rows():
    if r['timestamp'][5:16] not in want: continue
    reset(wt, pin)
    replay(os.path.join(R, j['transcriptFile']), TID, wt)
    for junk in glob.glob(os.path.join(wt, '**', '*.rej'), recursive=True) + glob.glob(os.path.join(wt, '**', '*.orig'), recursive=True):
        if 'node_modules' not in junk: os.unlink(junk)
    os.environ.pop('AUDIT_NO_DB', None)
    rc, summ, fails, out = run_tests(task, wt)
    out = re.sub(r'\x1b\[[0-9;]*m', '', out)
    print('=====', r['timestamp'][5:16], r['model'].split('/')[-1], '| with DATABASE_URL: exit', rc, summ)
    i = out.find('Failed Suites')
    j2 = out.find('Failed Tests')
    k = i if i >= 0 else j2
    print(out[k:k + 900] if k >= 0 else out[-600:])
