#!/usr/bin/env python3
"""Compose entries.k2.json from the data below + prompts/<id>.txt + source/<id>.txt (kept separate so each can be edited alone)."""
import json, os, re, sys
G = os.path.dirname(os.path.abspath(__file__))
PIN = '605a2e080cfddee855337f1b3d0b9cf7e48ddd6e'
FIX = '271636f41a6e31f24d88f2a8cd8101935b02e76e'
FLAGS = ['--frozen-lockfile', '--ignore-scripts']

def rd(kind, tid, default):
    p = os.path.join(G, kind, tid + '.txt')
    if os.path.exists(p):
        return open(p, encoding='utf-8').read().strip()
    return default

TASKS = [
    dict(id='kane-10-combo-permalink-scheme', title='KaneEnabler: a stored combo permalink must only become a link when its scheme is https',
         branch='bench/combo-permalink-scheme', base=dict(total=10, pass_=10),
         allow=['apps/home/src/components/ComboPreferenceRow.tsx', 'apps/home/src/routes/Profile.test.tsx'],
         src=['apps/home/src/components/ComboPreferenceRow.tsx'], testDir='apps/home',
         testCmd=['pnpm', 'exec', 'vitest', 'run', 'src/routes/Profile.test.tsx'], acceptance=['apps/home/src/routes/Profile.test.tsx']),
    dict(id='kane-11-useauth-session-reject', title='KaneEnabler: a rejected initial session check must not leave useAuth loading forever',
         branch='bench/useauth-session-reject', base=dict(total=11, pass_=11),
         allow=['packages/profile/src/useAuth.ts', 'packages/profile/src/useAuth.test.ts'],
         src=['packages/profile/src/useAuth.ts'], testDir='packages/profile',
         testCmd=['pnpm', 'exec', 'vitest', 'run', 'src/useAuth.test.ts'], acceptance=['packages/profile/src/useAuth.test.ts']),
    dict(id='kane-12-error-handler-400', title='KaneEnabler: a malformed JSON request body must be answered with 400, not 500',
         branch='bench/error-handler-400', base=dict(total=3, pass_=3),
         allow=['apps/commander-recommender/server/src/errorHandler.ts', 'apps/commander-recommender/server/src/errorHandler.test.ts'],
         src=['apps/commander-recommender/server/src/errorHandler.ts'], testDir='apps/commander-recommender/server',
         testCmd=['pnpm', 'exec', 'vitest', 'run', 'src/errorHandler.test.ts'], acceptance=['apps/commander-recommender/server/src/errorHandler.test.ts']),
    dict(id='kane-13-front-face-field', title='KaneEnabler: frontFaceField must read only the front face of an adventure card, but keep a split card\'s combined value',
         branch='bench/front-face-field', base=dict(total=20, pass_=20),
         allow=['packages/card-model/src/scryfallFields.js', 'packages/card-model/src/scryfallFields.test.js'],
         src=['packages/card-model/src/scryfallFields.js'], testDir='packages/card-model',
         testCmd=['pnpm', 'exec', 'vitest', 'run', 'src/scryfallFields.test.js'], acceptance=['packages/card-model/src/scryfallFields.test.js']),
    dict(id='kane-14-undo-toast-timer', title='KaneEnabler: the undo toast\'s dismiss timer must restart for a second same-named card removed inside the window',
         branch='bench/undo-toast-timer', base=dict(total=108, pass_=108),
         allow=['apps/time-counters/src/components/UndoToast.tsx', 'apps/time-counters/src/App.tsx', 'apps/time-counters/src/components/UndoToast.test.tsx'],
         src=['apps/time-counters/src/components/UndoToast.tsx', 'apps/time-counters/src/App.tsx'], testDir='apps/time-counters',
         testCmd=['pnpm', 'exec', 'vitest', 'run'], acceptance=['apps/time-counters/src/components/UndoToast.test.tsx']),
]

def main():
    only = set(sys.argv[1:])
    out = []
    for t in TASKS:
        e = {}
        e['id'] = t['id']
        e['title'] = t['title']
        e['source'] = rd('source', t['id'], 'PLACEHOLDER source')
        e['repo'] = 'C:/Projects/KaneEnabler'
        e['branch'] = t['branch']
        e['benchBaseCommit'] = PIN
        e['baselineExpect'] = {'testsTotal': t['base']['total'], 'testsPass': t['base']['pass_']}
        e['allowFiles'] = t['allow']
        e['srcRevertFiles'] = t['src']
        e['testDir'] = t['testDir']
        e['testCmd'] = t['testCmd']
        e['installFlags'] = FLAGS
        if t.get('testEnv') is not None:
            e['testEnv'] = t['testEnv']
            e['testEnvNote'] = t['testEnvNote']
        if t.get('setup'):
            e['setup'] = t['setup']
        if t.get('acceptance') and os.path.exists(os.path.join(G, 'acceptance', t['id'] + '.note.txt')):
            e['acceptance'] = dict(note=open(os.path.join(G, 'acceptance', t['id'] + '.note.txt'), encoding='utf-8').read().strip(),
                                   ref='upstream-fix', commit=FIX, files=t['acceptance'])
        e['prompt'] = rd('prompts', t['id'], 'PLACEHOLDER prompt for ' + t['id'])
        out.append(e)
    # checks
    for e in out:
        for k, v in e.items():
            s = json.dumps(v, ensure_ascii=False)
            if re.search(r'[^\x00-\x7f]', s):
                sys.exit('non-ASCII in %s.%s' % (e['id'], k))
        assert len(e['benchBaseCommit']) == 40
        if len(e['source']) > 900:
            print('WARN %s: source is %d chars (> ~900)' % (e['id'], len(e['source'])))
        pl = len(e['prompt'])
        if not e['prompt'].startswith('PLACEHOLDER') and not (1500 <= pl <= 2800):
            print('WARN %s: prompt is %d chars (target 1500-2800)' % (e['id'], pl))
        if '\n' in e['prompt']:
            print('WARN %s: prompt has newlines' % e['id'])
    json.dump(out, open(os.path.join(G, 'entries.k2.json'), 'w', encoding='utf-8'), indent=2, ensure_ascii=True)
    open(os.path.join(G, 'entries.k2.json'), 'a').write('\n')
    print('wrote entries.k2.json (%d entries)' % len(out), ['%s:%d' % (e['id'][:7], len(e['prompt'])) for e in out])

main()
