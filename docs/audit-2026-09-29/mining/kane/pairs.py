import json, re, os
S='/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/mine-kane/'
commits=json.load(open(S+'commits-cat.json'))
def base(p):
    b=os.path.basename(p)
    b=re.sub(r'\.(test|spec|integration\.test|real-data\.test)\.(m?[jt]sx?)$','',b)
    b=re.sub(r'\.(m?[jt]sx?)$','',b)
    return b
rows=[]
for c in commits:
    by=c['by']
    tests=by.get('test',[])
    srcs=by.get('src',[])
    if not tests: continue
    for tp,ta,td in tests:
        tb=base(tp)
        m=[s for s in srcs if base(s[0])==tb]
        # also match by directory sibling
        rows.append((c['sha'],c['date'],c['subject'][:70],tp.split('/')[-1],f"+{ta}/-{td}",[f"{s[0].split('/')[-1]}(+{s[1]}/-{s[2]})" for s in m]))
# only print commits whose subject smells like a fix OR multiple pairs
for r in rows:
    print('|'.join(map(str,r)))
