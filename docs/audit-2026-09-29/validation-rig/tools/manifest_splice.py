#!/usr/bin/env python3
"""manifest_splice.py MANIFEST FRAGMENT... [--write]

Validate the entries in the FRAGMENT json arrays and (with --write) splice them, in the manifest's own hand-formatted style, in front of the
closing `]` of MANIFEST. Existing entries are never re-serialised (the file's formatting is hand-made, not json.dumps-reproducible).
"""
import json, re, sys

KEY_ORDER = ['id', 'title', 'source', 'repo', 'branch', 'benchBaseCommit', 'packageManager', 'baselineExpect', 'allowFiles', 'srcRevertFiles',
             'testDir', 'testCmd', 'installFlags', 'testEnv', 'testEnvNote', 'setup', 'typecheck', 'acceptance', 'prompt']
INLINE_ARRAYS = {'testCmd', 'installFlags', 'cmd', 'copy', 'files'}
INLINE_OBJECTS = {'testEnv', 'compilerOptions'}
OWNER_REPOS = {'C:/Projects/KaneEnabler', 'M:/Projects/LFCbot', 'M:/TTRPG/A Story of Heroes and Villains'}


def scalar(v):
    s = json.dumps(v, ensure_ascii=False)
    return s


def inline(v):
    if isinstance(v, dict):
        return '{ ' + ', '.join('%s: %s' % (json.dumps(k), inline(x)) for k, x in v.items()) + ' }' if v else '{}'
    if isinstance(v, list):
        return '[' + ', '.join(inline(x) for x in v) + ']'
    return scalar(v)


def fmt(v, key, ind):
    pad = ' ' * ind
    if isinstance(v, dict):
        if key in INLINE_OBJECTS:
            return inline(v)
        if not v:
            return '{}'
        items = ['%s  %s: %s' % (pad, json.dumps(k), fmt(x, k, ind + 2)) for k, x in v.items()]
        return '{\n' + ',\n'.join(items) + '\n' + pad + '}'
    if isinstance(v, list):
        if not v:
            return '[]'
        if key in INLINE_ARRAYS and all(not isinstance(x, (dict, list)) for x in v):
            return inline(v)
        items = ['%s  %s' % (pad, fmt(x, None, ind + 2)) for x in v]
        return '[\n' + ',\n'.join(items) + '\n' + pad + ']'
    return scalar(v)


def ordered(e):
    extra = [k for k in e if k not in KEY_ORDER]
    if extra:
        raise SystemExit('%s: unexpected keys %s' % (e.get('id'), extra))
    return {k: e[k] for k in KEY_ORDER if k in e}


def validate(e, existing_ids, existing_branches, seen):
    errs = []
    def need(c, m):
        if not c:
            errs.append(m)
    i = e.get('id', '?')
    for k in ('id', 'title', 'source', 'repo', 'branch', 'benchBaseCommit', 'baselineExpect', 'allowFiles', 'srcRevertFiles', 'testDir', 'testCmd', 'installFlags', 'prompt'):
        need(k in e, 'missing %s' % k)
    if errs:
        return errs
    need(re.fullmatch(r'(kane|lfc|asohav)-\d\d-[a-z0-9-]+', i), 'id shape')
    need(i not in existing_ids and i not in seen, 'duplicate id')
    need(e['branch'].startswith('bench/') and e['branch'] not in existing_branches and e['branch'] not in seen, 'branch label shape/duplicate')
    need(e['repo'] in OWNER_REPOS, 'repo must be an owner path')
    need(re.fullmatch(r'[0-9a-f]{40}', e['benchBaseCommit']), 'benchBaseCommit must be 40-hex')
    be = e['baselineExpect']
    need(isinstance(be.get('testsTotal'), int) and be.get('testsTotal') == be.get('testsPass') and be['testsTotal'] > 0, 'baselineExpect must be N/N')
    need(set(e['srcRevertFiles']) <= set(e['allowFiles']) and e['srcRevertFiles'], 'srcRevertFiles must be a non-empty subset of allowFiles')
    need(not any(re.search(r'\.test\.', f) for f in e['srcRevertFiles']), 'srcRevertFiles must not contain test files')
    need(any(re.search(r'\.test\.', f) for f in e['allowFiles']), 'allowFiles needs a test file')
    need(isinstance(e['testCmd'], list) and e['testCmd'], 'testCmd array')
    if e['repo'].endswith('KaneEnabler'):
        need('packageManager' not in e and e['installFlags'] == ['--frozen-lockfile', '--ignore-scripts'], 'kane: pnpm default + frozen lockfile flags')
    else:
        need(e.get('packageManager') == 'npm' and e['installFlags'] == ['--ignore-scripts'], 'npm repos: packageManager npm + --ignore-scripts')
    if 'testEnv' in e:
        need('testEnvNote' in e, 'testEnv needs testEnvNote')
    if 'acceptance' in e:
        a = e['acceptance']
        need(set(a) == {'note', 'ref', 'commit', 'files'}, 'acceptance keys')
        need(re.fullmatch(r'[0-9a-f]{40}', a.get('commit', '')), 'acceptance.commit 40-hex')
        need(set(a.get('files', [])) <= set(e['allowFiles']) and a.get('files'), 'acceptance.files subset of allowFiles')
        need(a.get('ref') == 'upstream-fix', 'acceptance.ref label is upstream-fix')
    p = e['prompt']
    need(all(ord(c) < 128 for c in json.dumps(e, ensure_ascii=False)), 'entry must be ASCII only')
    need('\n' not in p, 'prompt must be one paragraph')
    need(1200 <= len(p) <= 3500, 'prompt length %d outside 1200..3500' % len(p))
    need('Do not commit' in p, 'prompt must say Do not commit')
    need('Do not touch any other file' in p, 'prompt must say Do not touch any other file')
    need('FAIL if only' in p, 'prompt must say the test must FAIL if only the fix is reverted')
    for f in e['allowFiles']:
        need(f in p, 'prompt must name %s' % f)
    need(not re.search(r'\b[0-9a-f]{7,40}\b', p), 'prompt must not contain commit SHAs')
    need(not re.search(r'\b(benchmark|harness|failsOnOld|acceptance|stand-in)\b', p, re.I), 'prompt must not mention the benchmark/harness/failsOnOld/acceptance')
    return ['%s: %s' % (i, m) for m in errs]


def main():
    args = [a for a in sys.argv[1:] if a != '--write']
    write = '--write' in sys.argv
    manifest_path, frags = args[0], args[1:]
    raw = open(manifest_path, encoding='utf-8').read()
    m = json.loads(raw)
    ids = {t['id'] for t in m['tasks']}
    branches = {t['branch'] for t in m['tasks']}
    new, seen, bad = [], set(), []
    for f in frags:
        for e in json.load(open(f, encoding='utf-8')):
            errs = validate(e, ids, branches, seen)
            seen.add(e.get('id')); seen.add(e.get('branch'))
            bad += errs
            new.append(ordered(e))
    if bad:
        print('\n'.join(bad)); sys.exit(1)
    print('%d entries valid' % len(new))
    if not write:
        return
    tail = '\n  ]\n}'
    assert raw.endswith(tail), 'unexpected manifest tail'
    chunks = []
    for e in new:
        body = ',\n'.join('      %s: %s' % (json.dumps(k), fmt(v, k, 6)) for k, v in e.items())
        chunks.append('    {\n' + body + '\n    }')
    out = raw[:-len(tail)] + ',\n' + ',\n'.join(chunks) + tail
    json.loads(out)
    after = json.loads(out)
    assert after['tasks'][:len(m['tasks'])] == m['tasks'], 'existing entries changed'
    assert len(after['tasks']) == len(m['tasks']) + len(new)
    assert out.encode('utf-8').count(b'\r') == 0
    open(manifest_path, 'w', encoding='utf-8', newline='').write(out)
    print('spliced %d entries; manifest now has %d tasks' % (len(new), len(after['tasks'])))


main()
