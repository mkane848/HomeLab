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


CRP = 'apps/home/src/components/ComboPreferenceRow.tsx'
FIXED10 = "const permalink = snapshot.permalink?.startsWith('https://') ? snapshot.permalink : null;"
print('--- correct ALTERNATIVE implementations (must stay green on the upstream tests)')
mutate('10 alt: URL() protocol check', CRP, sub(FIXED10, "let permalink: string | null = null;\n  try {\n    if (snapshot.permalink && new URL(snapshot.permalink).protocol === 'https:') permalink = snapshot.permalink;\n  } catch {\n    permalink = null;\n  }"), 'apps/home', 'src/routes/Profile.test.tsx', 'green')
mutate('10 alt: regex /^https:\\/\\//i', CRP, sub(FIXED10, "const permalink = snapshot.permalink && /^https:\\/\\//i.test(snapshot.permalink) ? snapshot.permalink : null;"), 'apps/home', 'src/routes/Profile.test.tsx', 'green')
UA = 'packages/profile/src/useAuth.ts'
mutate('11 alt: two-arg then(ok, fail)', UA, rx(r"\n      \.then\(\(\{ data \}\) => \{.*?\n      \}\);", "\n      .then(\n        ({ data }) => {\n          if (cancelled) return;\n          setUser(data.session?.user ?? null);\n          setLoading(false);\n        },\n        () => {\n          if (!cancelled) setLoading(false);\n        },\n      );"), 'packages/profile', 'src/useAuth.test.ts', 'green')
mutate('11 alt: .finally(setLoading false)', UA, rx(r"\n      \.catch\(\(\) => \{.*?\n      \}\);", "\n      .catch(() => {})\n      .finally(() => {\n        if (!cancelled) setLoading(false);\n      });"), 'packages/profile', 'src/useAuth.test.ts', 'green')
EH = 'apps/commander-recommender/server/src/errorHandler.ts'
mutate('12 alt: "status" in err check', EH, sub("err instanceof SyntaxError && (err as SyntaxError & { status?: number }).status === 400", "err instanceof SyntaxError && 'status' in err && err.status === 400"), 'apps/commander-recommender/server', 'src/errorHandler.test.ts', 'green')
mutate('12 alt: statusCode or status', EH, sub("err instanceof SyntaxError && (err as SyntaxError & { status?: number }).status === 400", "err instanceof SyntaxError && ((err as { status?: number; statusCode?: number }).status ?? (err as { statusCode?: number }).statusCode) === 400"), 'apps/commander-recommender/server', 'src/errorHandler.test.ts', 'green')
SF = 'packages/card-model/src/scryfallFields.js'
BODY = "  const faces = card.card_faces;\n  const useFrontOnly = Array.isArray(faces) && faces.length > 0 && card.layout !== 'split';\n  if (useFrontOnly) return faces[0]?.[field];\n  return card[field];\n"
mutate('13 alt: not-split & has faces', SF, sub(BODY, "  if (card.layout !== 'split' && card.card_faces?.length) return card.card_faces[0]?.[field];\n  return card[field];\n"), 'packages/card-model', 'src/scryfallFields.test.js', 'green')
mutate('13 alt: adventure+modal/transform only', SF, sub(BODY, "  const faces = card.card_faces;\n  if (card.layout === 'adventure' || card.layout === 'modal_dfc' || card.layout === 'transform') return faces?.[0]?.[field];\n  return card[field] ?? faces?.[0]?.[field];\n"), 'packages/card-model', 'src/scryfallFields.test.js', 'green')
