import json, re, csv
S='/tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/mine-kane/'
commits=json.load(open(S+'commits.json'))
def cat(p):
    # handle rename syntax {a => b}
    pl=p.lower()
    if re.search(r'(\.test\.|\.spec\.|/__tests__/|/tests?/)',pl): return 'test'
    if pl.endswith('.snap'): return 'snap'
    if pl.endswith('.md') or '/docs/' in pl or pl.startswith('docs/'): return 'doc'
    if pl.endswith('pnpm-lock.yaml') or pl.endswith('package-lock.json'): return 'lock'
    if pl.endswith('.css') or pl.endswith('.scss'): return 'css'
    if pl.endswith(('package.json','tsconfig.json','.yaml','.yml','.json','.toml','.config.ts','.config.js','.config.mjs','.config.cjs','.gitignore','.prettierignore','.prettierrc')) or '/.github/' in pl or pl.startswith('.github/'): return 'config'
    if pl.endswith(('.ts','.tsx','.js','.jsx','.mjs','.cjs','.sh')): return 'src'
    if pl.endswith(('.svg','.png','.jpg','.jpeg','.ico','.woff','.woff2','.webp')): return 'asset'
    if pl.endswith(('.html',)): return 'html'
    return 'other'
rows=[]
for c in commits:
    by={}
    for a,d,p in c['files']:
        k=cat(p)
        ad=0 if a=='-' else int(a); dd=0 if d=='-' else int(d)
        by.setdefault(k,[]).append((p,ad,dd))
    c['by']=by
    def n(k): return len(by.get(k,[]))
    def pl(k): return (sum(x[1] for x in by.get(k,[])), sum(x[2] for x in by.get(k,[])))
    c['nsrc']=n('src'); c['ntest']=n('test'); c['nfiles']=len(c['files'])
    c['src_pm']=pl('src'); c['test_pm']=pl('test')
json.dump(commits,open(S+'commits-cat.json','w'))
# print compact table
for c in commits:
    print(f"{c['sha']}|{c['date']}|src={c['nsrc']}(+{c['src_pm'][0]}/-{c['src_pm'][1]})|test={c['ntest']}(+{c['test_pm'][0]}/-{c['test_pm'][1]})|all={c['nfiles']}|{c['subject'][:95]}")
