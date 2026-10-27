#!/usr/bin/env python3
"""Build G/entries.k1.json from structured data + prompt/source text files in G/work/text/.
Key order follows the brief: id,title,source,repo,branch,benchBaseCommit,packageManager,baselineExpect,allowFiles,srcRevertFiles,
testDir,testCmd,installFlags,testEnv,testEnvNote,setup,acceptance,prompt.  ASCII-only is enforced."""
import json, os, sys, collections
HERE = os.path.dirname(os.path.abspath(__file__))
G = os.path.dirname(HERE)
T = os.path.join(HERE, 'text')

def txt(name, default=None):
    p = os.path.join(T, name)
    if not os.path.exists(p):
        return default
    s = open(p, encoding='utf-8').read().strip()
    return s

SERVER = 'apps/commander-recommender/server'
CLIENT = 'apps/commander-recommender/client'
INSTALL = ['--frozen-lockfile', '--ignore-scripts']

TASKS = [
    dict(id='kane-07-find-qualifier-type',
         title='KaneEnabler: a payoff must qualify by the creature type it actually restricts, not the first type word in its clause',
         branch='bench/find-qualifier-type',
         base='10889539112089dcd122014f934520f9f11cf558',
         fix='731e98508f53528647418403133c63c437307313',
         base_n=76,
         src=[SERVER + '/src/services/signals.ts'],
         test=[SERVER + '/src/services/signals.test.ts'],
         testDir=SERVER, testCmd=['pnpm', 'exec', 'vitest', 'run', 'src/services/signals.test.ts'],
         acceptance=True),
    dict(id='kane-08-aristocrats-false-positives',
         title='KaneEnabler: four false positives in the Aristocrats signal (replacement effects, combat-kill triggers, sacrifice-cost scan, multi-resource costs)',
         branch='bench/aristocrats-false-positives',
         base='45095ab148d27fdbe20765a112d1dd7d743e4fcd',
         fix='e95219824e1c9d30da1f48ba160cf69560b40e14',
         base_n=234,
         src=[SERVER + '/src/services/signals.ts'],
         test=[SERVER + '/src/services/signals.test.ts'],
         testDir=SERVER, testCmd=['pnpm', 'exec', 'vitest', 'run', 'src/services/signals.test.ts'],
         acceptance=True),
    dict(id='kane-09-colour-filter-subset',
         title='KaneEnabler: the colour include-filter must keep commanders whose colour identity fits inside the chosen colours (subset, not intersection)',
         branch='bench/colour-filter-subset',
         base='f0abf087f92323e69a0a706e14c22b427fb80d31',
         fix='e0ef290365bc43031357ecc454e7e5e7554f3e99',
         base_n=16,
         src=[CLIENT + '/src/lib/filters.ts'],
         test=[CLIENT + '/src/lib/filters.test.ts'],
         testDir=CLIENT, testCmd=['pnpm', 'exec', 'vitest', 'run', 'src/lib/filters.test.ts'],
         acceptance=True),
]

only = set(sys.argv[1:])
out = []
for t in TASKS:
    e = collections.OrderedDict()
    e['id'] = t['id']
    e['title'] = t['title']
    e['source'] = txt('source.%s.txt' % t['id'], 'PLACEHOLDER source')
    e['repo'] = 'C:/Projects/KaneEnabler'
    e['branch'] = t['branch']
    e['benchBaseCommit'] = t['base']
    e['baselineExpect'] = collections.OrderedDict([('testsTotal', t['base_n']), ('testsPass', t['base_n'])])
    e['allowFiles'] = t['src'] + t['test']
    e['srcRevertFiles'] = t['src']
    e['testDir'] = t['testDir']
    e['testCmd'] = t['testCmd']
    e['installFlags'] = INSTALL
    # no testEnv / setup unless a text file says so (see report)
    env = txt('testEnv.%s.json' % t['id'])
    if env:
        e['testEnv'] = json.loads(env)
        e['testEnvNote'] = txt('testEnvNote.%s.txt' % t['id'], 'PLACEHOLDER testEnvNote')
    setup = txt('setup.%s.json' % t['id'])
    if setup:
        e['setup'] = json.loads(setup)
    if t['acceptance']:
        e['acceptance'] = collections.OrderedDict([
            ('note', txt('acceptance-note.%s.txt' % t['id'], 'PLACEHOLDER acceptance note')),
            ('ref', 'upstream-fix'),
            ('commit', t['fix']),
            ('files', t['test'])])
    e['prompt'] = txt('prompt.%s.txt' % t['id'], 'PLACEHOLDER prompt for ' + t['id'])
    out.append(e)

bad = []
def walk(x, path=''):
    if isinstance(x, str):
        try:
            x.encode('ascii')
        except UnicodeEncodeError:
            bad.append((path, [c for c in x if ord(c) > 127][:5]))
    elif isinstance(x, dict):
        for k, v in x.items(): walk(v, path + '.' + k)
    elif isinstance(x, list):
        for i, v in enumerate(x): walk(v, '%s[%d]' % (path, i))
walk(out)
if bad:
    print('NON-ASCII found:', bad); sys.exit(1)
dest = os.path.join(G, 'entries.k1.json')
json.dump(out, open(dest, 'w', encoding='ascii'), indent=2)
print('wrote', dest, [ (e['id'], len(e['prompt']), len(e['source'])) for e in out ])
