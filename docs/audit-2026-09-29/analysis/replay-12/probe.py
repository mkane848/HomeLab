import os, re, sys, glob
sys.path.insert(0, os.path.dirname(__file__))
from run_audit import load_passes, reset, sh, TASK, SHORT, A
from replay import replay, R

def clean(s): return re.sub(r'\x1b\[[0-9;]*m', '', s)
passes = {(SHORT[p['task']], p['ts'][5:16].replace('T', ' ')): p for p in load_passes()}

def setup(short, stamp):
    p = passes[(short, stamp)]; task = TASK[p['task']]; wt = os.path.join(A, 'wt', short)
    reset(wt, task['benchBaseCommit']); replay(os.path.join(R, p['json']['transcriptFile']), p['task'], wt)
    for junk in glob.glob(os.path.join(wt, '**', '*.rej'), recursive=True) + glob.glob(os.path.join(wt, '**', '*.orig'), recursive=True):
        if 'node_modules' not in junk: os.unlink(junk)
    return task, wt

KANE_PROBE = r"""
import { describe, it } from 'vitest';
import { singletonLimit } from './singleton';
const mk = (txt: string) => ({ name: 'Probe', type_line: 'Creature', oracle_text: txt } as any);
describe('probe', () => { it('prints', () => {
  const out: string[] = [];
  const w = console.warn; let warned = 0; console.warn = () => { warned++; };
  for (const t of ['up to 7', 'up to 13', 'up to seven', 'up to thirteen', 'up to xyz', 'up to 0', 'up to 007']) {
    warned = 0; const r = singletonLimit(mk('A deck can have ' + t + ' cards named Probe.'));
    out.push(`${t.padEnd(16)} -> limit ${String(r).padEnd(4)} warned ${warned}`);
  }
  console.warn = w; console.log('PROBE\n' + out.join('\n'));
}); });
"""
LFC_PROBE = r"""
import { afterEach, describe, it, vi } from 'vitest';
import { autocompleteCards } from '../../src/services/scryfall.js';
import { setupTestDb } from '../helpers/db.js';
setupTestDb();
afterEach(() => { vi.unstubAllGlobals(); });
describe('probe', () => { it('prints the headers actually sent', async () => {
  const f = vi.fn().mockResolvedValue(new Response(JSON.stringify({ data: ['x'] }), { status: 200, headers: { 'content-type': 'application/json' } }));
  vi.stubGlobal('fetch', f);
  await autocompleteCards('lotus');
  console.log('PROBE headers sent: ' + JSON.stringify((f.mock.calls[0] as any)[1].headers));
}); });
"""

def vitest(task, wt, rel, body):
    path = os.path.join(wt, task['testDir'], rel)
    open(path, 'w').write(body)
    try:
        rc, out = sh(['npx', 'vitest', 'run', rel], os.path.join(wt, task['testDir']), env={'MANAPOOL_API_KEY': ''})
    finally:
        os.unlink(path)
    return rc, clean(out)

print('############ kane-04: what do the two models\' singletonLimit actually do on each input? ############')
for stamp in ('09-29 16:37', '09-29 16:39'):
    task, wt = setup('kane-04', stamp)
    rc, out = vitest(task, wt, 'src/services/_probe.test.ts', KANE_PROBE)
    i = out.find('PROBE')
    print('--- kane-04 pass', stamp, 'vitest exit', rc); print(out[i:i + 600] if i >= 0 else out[-800:])

print('\n############ lfc-02: headers actually sent ############')
for stamp in ('09-29 16:52', '09-29 16:54'):
    task, wt = setup('lfc-02', stamp)
    rc, out = vitest(task, wt, 'tests/services/_probe.test.ts', LFC_PROBE)
    i = out.find('PROBE')
    print('--- lfc-02 pass', stamp, 'vitest exit', rc); print(out[i:i + 400] if i >= 0 else out[-800:])
    pkg = sh(['git', 'show', 'HEAD:package.json'], wt)[1]
    m = re.search(r'"version":\s*"([^"]+)"', pkg); print('   package.json version at the pin:', m.group(1) if m else '?')

print('\n############ lfc-02: tsc --noEmit (typecheck is SKIP for this task by design) ############')
task = TASK['lfc-02-scryfall-headers']; wt = os.path.join(A, 'wt', 'lfc-02')
reset(wt, task['benchBaseCommit'])
rc, out = sh(['npx', 'tsc', '--noEmit', '-p', 'tsconfig.json'], wt)
print('base: exit', rc, '| error lines:', len(re.findall(r'error TS\d+', out)))
for stamp in ('09-29 16:52', '09-29 16:54'):
    task, wt = setup('lfc-02', stamp)
    rc, out = sh(['npx', 'tsc', '--noEmit', '-p', 'tsconfig.json'], wt)
    errs = re.findall(r'^(.*error TS\d+: .*)$', out, re.M)
    print('pass', stamp, ': exit', rc, '| error lines:', len(errs))
    for e in errs[:8]: print('   ', e[:200])
