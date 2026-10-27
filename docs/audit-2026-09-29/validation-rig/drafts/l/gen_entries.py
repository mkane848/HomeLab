#!/usr/bin/env python3
"""Assemble entries.l.json from metadata (here) + prompts/<id>.txt + source/<id>.txt. Re-run after editing any of them.
   Output is the deliverable: a JSON ARRAY of manifest entries, ASCII only, validated with json.tool by the caller."""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def txt(kind, tid):
    p = os.path.join(HERE, kind, tid + '.txt')
    if not os.path.exists(p):
        return 'PLACEHOLDER %s %s' % (kind, tid)
    return open(p, encoding='utf-8').read().strip().replace('\n', ' ')


COMMON = dict(
    repo='M:/Projects/LFCbot',
    packageManager='npm',
    testDir='.',
    installFlags=['--ignore-scripts'],
)

TASKS = [
    dict(
        id='lfc-04-admin-manage-server-permission',
        title="lfc-bot: /admin's default visibility must be the Manage Server permission, not the Administrator bit",
        branch='bench/admin-manage-server-permission',
        benchBaseCommit='e644702a6ce9753b69ca3291e1bdc388e2d1a7d3',
        baselineExpect=dict(testsTotal=4, testsPass=4),
        allowFiles=['src/commands/admin/admin.ts', 'tests/commands/admin/admin.test.ts'],
        srcRevertFiles=['src/commands/admin/admin.ts'],
        testCmd=['npx', 'vitest', 'run', 'tests/commands/admin/admin.test.ts'],
        acceptance=dict(
            note="",
            ref='upstream-fix',
            commit='0e9d123847f2302106cdc5da32ea32f5b3992988',
            files=['tests/commands/admin/admin.test.ts'],
        ),
    ),
    dict(
        id='lfc-05-digest-allowed-mentions',
        title="lfc-bot: the digest must not let a user-controlled display name mass-ping the channel (suppress mention parsing)",
        branch='bench/digest-allowed-mentions',
        benchBaseCommit='6f5a5038aef79c2ccdcd460d9ebfa9c6b2e16cef',
        baselineExpect=dict(testsTotal=6, testsPass=6),
        allowFiles=['src/services/digest.ts', 'tests/services/digest.test.ts'],
        srcRevertFiles=['src/services/digest.ts'],
        testCmd=['npx', 'vitest', 'run', 'tests/services/digest.test.ts'],
        acceptance=dict(
            note="",
            ref='upstream-fix',
            commit='d998d2da5722bd0a8c060fa263f96b17f5b75786',
            files=['tests/services/digest.test.ts'],
        ),
    ),
    dict(
        id='lfc-07-digest-split',
        title="lfc-bot: an over-long digest must be split across several Discord messages without losing a line or advancing the watermark on a partial failure",
        branch='bench/digest-split',
        benchBaseCommit='d6a5338d809407d181b7d74eef064bbd0d81ffa2',
        baselineExpect=dict(testsTotal=7, testsPass=7),
        allowFiles=['src/services/digest.ts', 'src/utils/constants.ts', 'tests/services/digest.test.ts'],
        srcRevertFiles=['src/services/digest.ts', 'src/utils/constants.ts'],
        testCmd=['npx', 'vitest', 'run', 'tests/services/digest.test.ts'],
        acceptance=dict(
            note="",
            ref='upstream-fix',
            commit='e644702a6ce9753b69ca3291e1bdc388e2d1a7d3',
            files=['tests/services/digest.test.ts'],
        ),
    ),
]

# optional per-task extras read from extras/<id>.json (testEnv, testEnvNote, setup) - written only if the evidence demands them
ORDER = ['id', 'title', 'source', 'repo', 'branch', 'benchBaseCommit', 'packageManager', 'baselineExpect', 'allowFiles',
         'srcRevertFiles', 'testDir', 'testCmd', 'installFlags', 'testEnv', 'testEnvNote', 'setup', 'acceptance', 'prompt']

out = []
for t in TASKS:
    e = dict(COMMON)
    e.update(t)
    e['source'] = txt('source', t['id'])
    e['prompt'] = txt('prompts', t['id'])
    acc_note = os.path.join(HERE, 'acceptance-notes', t['id'] + '.txt')
    if os.path.exists(acc_note):
        e['acceptance']['note'] = open(acc_note, encoding='utf-8').read().strip().replace('\n', ' ')
    else:
        e['acceptance']['note'] = 'PLACEHOLDER acceptance note'
    ex = os.path.join(HERE, 'extras', t['id'] + '.json')
    if os.path.exists(ex):
        e.update(json.load(open(ex, encoding='utf-8')))
    unknown = set(e) - set(ORDER)
    if unknown:
        sys.exit('unknown keys in %s: %s' % (t['id'], unknown))
    o = {k: e[k] for k in ORDER if k in e}
    out.append(o)

blob = json.dumps(out, indent=2, ensure_ascii=False)
bad = sorted(set(ch for ch in blob if ord(ch) > 127))
if bad:
    sys.exit('NON-ASCII characters in entries: %r' % bad)
open(os.path.join(HERE, 'entries.l.json'), 'w', encoding='ascii').write(blob + '\n')
print('wrote entries.l.json (%d entries)' % len(out))
for o in out:
    print('  %-42s prompt=%d chars source=%d chars' % (o['id'], len(o['prompt']), len(o['source'])))
