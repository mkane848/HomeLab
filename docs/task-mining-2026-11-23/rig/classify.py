import subprocess, sys, re
repo = sys.argv[1]
def g(*a): return subprocess.run(['git','-C',repo,*a],capture_output=True,text=True).stdout
shas = g('log','origin/main','--since=2026-09-26','--no-merges','--format=%H').split()
TEST = re.compile(r'(\.test\.|\.spec\.|/tests?/|__tests__)')
for s in shas:
    subj = g('log','-1','--format=%ad|%s','--date=short',s).strip()
    files = g('diff-tree','--no-commit-id','-r','--name-status',s).strip().splitlines()
    src=[];tst=[];other=[]
    for line in files:
        st,*p = line.split('\t'); f=p[-1]
        if TEST.search(f): tst.append(st+':'+f)
        elif re.search(r'\.(ts|tsx|js|jsx|mjs)$',f) and 'lock' not in f: src.append(st+':'+f)
        else: other.append(f)
    if src and tst:
        print(f"{s[:9]} {subj}\n    SRC({len(src)}) {' '.join(src[:5])}\n    TST({len(tst)}) {' '.join(tst[:5])}\n    other {len(other)}")
