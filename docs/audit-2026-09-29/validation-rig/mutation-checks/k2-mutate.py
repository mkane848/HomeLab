#!/usr/bin/env python3
"""Mutation sanity on the FIXED sources (scratch worktree at the fix commit): apply one change, run the upstream test file, restore."""
import re, subprocess, sys, os
W = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'scratch', 'mut')
def sh(cmd, cwd):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr)
def run_tests(testdir, testfile):
    code, out = sh(['pnpm', 'exec', 'vitest', 'run', testfile], os.path.join(W, testdir))
    out = re.sub(r'\x1b\[[0-9;]*m', '', out)
    m = re.findall(r'^\s*Tests\s+(.*)$', out, re.M)
    fails = re.findall(r'^\s*(?:FAIL|×)\s+.*?>\s*(.+?)\s*$', out, re.M)
    names = sorted(set(re.findall(r'(?m)^ FAIL\s+\S+\s+>\s+(.+?)(?:\s+\d+ms)?$', out)))
    return code, (m[-1].strip() if m else 'no summary: ' + out[-200:]), names
def mutate(label, relfile, edit, testdir, testfile, expect):
    p = os.path.join(W, relfile)
    orig = open(p, encoding='utf-8').read()
    new = edit(orig)
    assert new != orig, label + ': mutation did not change the file'
    open(p, 'w', encoding='utf-8', newline='').write(new)
    try:
        code, summ, names = run_tests(testdir, testfile)
    finally:
        sh(['git', 'checkout', '--', relfile], W)
    verdict = 'RED' if code != 0 else 'green'
    flag = '' if verdict.lower().startswith(expect) else '   <-- UNEXPECTED (expected %s)' % expect
    print('%-34s %-5s %s %s%s' % (label, verdict, summ, ('| ' + '; '.join(names)) if names else '', flag))
    sys.stdout.flush()
def sub(old, new, count=1):
    def f(s):
        assert old in s, 'anchor not found: ' + old[:60]
        return s.replace(old, new, count)
    return f
def rx(pattern, new, flags=re.S):
    def f(s):
        r, n = re.subn(pattern, new, s, count=1, flags=flags)
        assert n == 1, 'regex not found: ' + pattern[:60]
        return r
    return f

# baseline: the fixed tree is green
for td, tf in [('apps/home', 'src/routes/Profile.test.tsx'), ('packages/profile', 'src/useAuth.test.ts'),
               ('apps/commander-recommender/server', 'src/errorHandler.test.ts'), ('packages/card-model', 'src/scryfallFields.test.js'),
               ('apps/time-counters', 'src/components/UndoToast.test.tsx')]:
    code, summ, names = run_tests(td, tf)
    print('%-34s %-5s %s' % ('FIXED tree: ' + tf.split('/')[-1], 'RED' if code else 'green', summ))

CRP = 'apps/home/src/components/ComboPreferenceRow.tsx'
FIXED10 = "const permalink = snapshot.permalink?.startsWith('https://') ? snapshot.permalink : null;"
print('--- kane-10')
mutate('10 revert fix (old behaviour)', CRP, sub(FIXED10, 'const permalink = snapshot.permalink;'), 'apps/home', 'src/routes/Profile.test.tsx', 'red')
mutate('10 never render a link', CRP, sub(FIXED10, 'const permalink = null as string | null;'), 'apps/home', 'src/routes/Profile.test.tsx', 'red')
mutate('10 denylist javascript: only', CRP, sub(FIXED10, "const permalink = snapshot.permalink?.startsWith('javascript:') ? null : snapshot.permalink;"), 'apps/home', 'src/routes/Profile.test.tsx', 'green')
mutate('10 allow http: too', CRP, sub(FIXED10, "const permalink = snapshot.permalink?.startsWith('http') ? snapshot.permalink : null;"), 'apps/home', 'src/routes/Profile.test.tsx', 'green')

UA = 'packages/profile/src/useAuth.ts'
print('--- kane-11')
CATCH = r"\.catch\(\(\) => \{.*?\n      \}\);"
mutate('11 revert fix (no .catch)', UA, rx(r"\n      \.catch\(\(\) => \{.*?\n      \}\);", ';'), 'packages/profile', 'src/useAuth.test.ts', 'red')
mutate('11 .catch swallows, loading stays', UA, rx(CATCH, ".catch(() => {});"), 'packages/profile', 'src/useAuth.test.ts', 'red')
mutate('11 .catch w/o cancelled guard', UA, sub("        if (cancelled) return;\n        setLoading(false);\n      });", "        setLoading(false);\n      });"), 'packages/profile', 'src/useAuth.test.ts', 'green')

EH = 'apps/commander-recommender/server/src/errorHandler.ts'
print('--- kane-12')
IFBLOCK = r"  if \(err instanceof SyntaxError.*?\n  \}\n"
mutate('12 revert fix (no 400 branch)', EH, rx(IFBLOCK, ''), 'apps/commander-recommender/server', 'src/errorHandler.test.ts', 'red')
mutate('12 status===400 only (no SyntaxError)', EH, sub("err instanceof SyntaxError && (err as SyntaxError & { status?: number }).status === 400", "(err as { status?: number }).status === 400"), 'apps/commander-recommender/server', 'src/errorHandler.test.ts', 'green')
mutate('12 SyntaxError only (no status)', EH, sub("err instanceof SyntaxError && (err as SyntaxError & { status?: number }).status === 400", "err instanceof SyntaxError"), 'apps/commander-recommender/server', 'src/errorHandler.test.ts', 'red')
mutate('12 other message', EH, sub("'Request body is not valid JSON.'", "'Bad JSON.'"), 'apps/commander-recommender/server', 'src/errorHandler.test.ts', 'red')
mutate('12 400 with the generic message', EH, sub("res.status(400).json({ error: 'Request body is not valid JSON.' });", "res.status(400).json({ error: 'Something went wrong on the server. Please try again.' });"), 'apps/commander-recommender/server', 'src/errorHandler.test.ts', 'red')
mutate('12 status 422 instead of 400', EH, sub("res.status(400).json", "res.status(422).json"), 'apps/commander-recommender/server', 'src/errorHandler.test.ts', 'red')

SF = 'packages/card-model/src/scryfallFields.js'
print('--- kane-13')
BODY = "  const faces = card.card_faces;\n  const useFrontOnly = Array.isArray(faces) && faces.length > 0 && card.layout !== 'split';\n  if (useFrontOnly) return faces[0]?.[field];\n  return card[field];\n"
OLD = "  if (card[field] !== undefined) return card[field];\n  return card.card_faces?.[0]?.[field];\n"
mutate('13 revert fix (old body)', SF, sub(BODY, OLD), 'packages/card-model', 'src/scryfallFields.test.js', 'red')
mutate('13 naive always-front-face', SF, sub(" && card.layout !== 'split'", ""), 'packages/card-model', 'src/scryfallFields.test.js', 'red')
mutate('13 front face for mana_cost only', SF, sub(BODY, "  const faces = card.card_faces;\n  const useFrontOnly = Array.isArray(faces) && faces.length > 0 && card.layout !== 'split';\n  if (useFrontOnly && field === 'mana_cost') return faces[0]?.[field];\n" + OLD), 'packages/card-model', 'src/scryfallFields.test.js', 'green')
mutate('13 adventure layout only', SF, sub(BODY, "  const faces = card.card_faces;\n  if (card.layout === 'adventure') return faces?.[0]?.[field];\n" + OLD), 'packages/card-model', 'src/scryfallFields.test.js', 'green')
mutate('13 front face wins even for split', SF, sub(BODY, "  return card.card_faces?.[0]?.[field] ?? card[field];\n"), 'packages/card-model', 'src/scryfallFields.test.js', 'red')

UT = 'apps/time-counters/src/components/UndoToast.tsx'
AP = 'apps/time-counters/src/App.tsx'
print('--- kane-14')
T = ('apps/time-counters', 'src/components/UndoToast.test.tsx')
mutate('14 revert UndoToast deps to cardName', UT, sub("[instanceId, onDismiss]", "[cardName, onDismiss]"), *T, 'red')
mutate('14 revert App.tsx only', AP, sub("          instanceId={lastRemoved.card.instanceId}\n", ""), *T, 'green')
mutate('14 no clearTimeout cleanup', UT, sub("    return () => clearTimeout(timer);\n", ""), *T, 'red')
mutate('14 AUTO_DISMISS_MS 5000', UT, sub("AUTO_DISMISS_MS = 6000", "AUTO_DISMISS_MS = 5000"), *T, 'red')
mutate('14 AUTO_DISMISS_MS 7000', UT, sub("AUTO_DISMISS_MS = 6000", "AUTO_DISMISS_MS = 7000"), *T, 'red')
mutate('14 deps [cardName, instanceId, ...]', UT, sub("[instanceId, onDismiss]", "[cardName, instanceId, onDismiss]"), *T, 'green')
mutate('14 deps [instanceId] only', UT, sub("[instanceId, onDismiss]", "[instanceId]"), *T, 'green')
