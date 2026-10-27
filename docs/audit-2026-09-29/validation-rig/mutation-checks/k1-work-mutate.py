#!/usr/bin/env python3
"""mutate.py : apply named mutations to the FIXED source in a scratch worktree, run the fix commit's own test file, report failing tests, restore.
usage: mutate.py k08|k07|k09 [mutation-name ...]   (no names = all)"""
import json, os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
SCR = os.path.join(HERE, 'scratch')

CFG = {
  'k08': dict(wt='k08', pkg='apps/commander-recommender/server', src='apps/commander-recommender/server/src/services/signals.ts',
              test='src/services/signals.test.ts'),
  'k07': dict(wt='k07', pkg='apps/commander-recommender/server', src='apps/commander-recommender/server/src/services/signals.ts',
              test='src/services/signals.test.ts'),
  'k09': dict(wt='k09', pkg='apps/commander-recommender/client', src='apps/commander-recommender/client/src/lib/filters.ts',
              test='src/lib/filters.test.ts'),
}

def rep(old, new, count=1):
    def f(s):
        if s.count(old) != count:
            raise SystemExit('mutation anchor found %d times (want %d): %r' % (s.count(old), count, old[:80]))
        return s.replace(old, new)
    return f

M = {}
# ---------------- kane-08 ------------------------------------------------------------------
M['k08'] = {
 'a1_drop_lookbehind_in_rewards': rep("(?:(?!dealt damage by)[^.;])*(?<!would )\\b(?:dies?|dying)\\b", "(?:(?!dealt damage by)[^.;])*\\b(?:dies?|dying)\\b"),
 'a2_drop_lookbehind_in_amplifies': rep("/(?<!would )\\b(?:dies?|dying)\\b[^.]*triggers? an additional time/i", "/\\b(?:dies?|dying)\\b[^.]*triggers? an additional time/i"),
 'b_drop_dealt_damage_lookahead': rep("(?:(?!dealt damage by)[^.;])*(?<!would )", "[^.;]*(?<!would )"),
 'c_span_whole_clause_again': rep("""  const from = clause.search(/\\bsacrifice\\b/i);
  if (from === -1) return clause;
  const rest = clause.slice(from);
  const comma = rest.indexOf(',');
  return comma === -1 ? rest : rest.slice(0, comma);""", "  return clause;"),
 'c2_cut_at_first_comma': rep("""  const from = clause.search(/\\bsacrifice\\b/i);
  if (from === -1) return clause;
  const rest = clause.slice(from);
  const comma = rest.indexOf(',');
  return comma === -1 ? rest : rest.slice(0, comma);""", """  const comma = clause.indexOf(',');
  return comma === -1 ? clause : clause.slice(0, comma);"""),
 'c3_anchor_on_sacrifice_before_colon': rep("""  const colon = clause.indexOf(':');
  if (colon !== -1) return clause.slice(0, colon);
  const from = clause.search(/\\bsacrifice\\b/i);
  if (from === -1) return clause;""", """  const colon = clause.indexOf(':');
  const from = clause.search(/\\bsacrifice\\b/i);
  if (colon !== -1 && (from === -1 || from < colon)) return clause.slice(0, colon);
  if (from === -1) return clause;"""),
 'd_consumes_uses_broad_helper': rep("clauses(f.text).some((clause) => sacrificesCreatureSpecifically(clause, vocab)),", "clauses(f.text).some((clause) => sacrificesACreature(clause, vocab)),"),
 'd2_specifically_ignores_or': rep("return !(OTHER_SACRIFICEABLE_RESOURCES.test(cost) && /\\bor\\b/i.test(cost));", "return !OTHER_SACRIFICEABLE_RESOURCES.test(cost);"),
 'd3_specifically_ignores_resource_words': rep("return !(OTHER_SACRIFICEABLE_RESOURCES.test(cost) && /\\bor\\b/i.test(cost));", "return !/\\bor\\b/i.test(cost);"),
 'hidden_rewards_as_function': None,  # built below (needs a multi-line edit)
}
# ---------------- kane-07 ------------------------------------------------------------------
M['k07'] = {
 'no_whole_clause_fallback': None,
 'consumes_before_rewards': rep("const payoffMatchers = [...(def.roles.rewards ?? []), ...(def.roles.consumes ?? [])];", "const payoffMatchers = [...(def.roles.consumes ?? []), ...(def.roles.rewards ?? [])];"),
 'back_to_first_word_in_clause': None,
}
# ---------------- kane-09 ------------------------------------------------------------------
M['k09'] = {
 'old_intersection': rep("if (!isWithinColorIdentity(suggestion.colorIdentity, new Set(include))) return false;",
                         "if (!suggestion.colorIdentity.some((color) => new Set(include).has(color))) return false;"),
 'subset_but_colourless_dropped': rep("if (!isWithinColorIdentity(suggestion.colorIdentity, new Set(include))) return false;",
                         "if (suggestion.colorIdentity.length === 0 || !isWithinColorIdentity(suggestion.colorIdentity, new Set(include))) return false;"),
 'include_means_contains_all': rep("if (!isWithinColorIdentity(suggestion.colorIdentity, new Set(include))) return false;",
                         "if (!include.every((color) => suggestion.colorIdentity.includes(color))) return false;"),
 'exclude_dropped': rep("if (suggestion.colorIdentity.some((color) => excluded.has(color))) return false;", ""),
}

def build_special():
    # kane-08: convert the death-trigger rewards regex into a function matcher (the hidden constraint)
    def f(s):
        old = "        /(?:whenever|if)(?:(?!dealt damage by)[^.;])*(?<!would )\\b(?:dies?|dying)\\b/i,\n"
        new = ("        (f: CardFacts) =>\n"
               "          clauses(f.text).some((c) => /(?:whenever|if)(?:(?!dealt damage by)[^.;])*(?<!would )\\b(?:dies?|dying)\\b/i.test(c)),\n")
        if s.count(old) != 1: raise SystemExit('anchor for hidden_rewards_as_function not found')
        return s.replace(old, new)
    M['k08']['hidden_rewards_as_function'] = f
    # kane-07: no fallback
    def g(s):
        old = """    for (const word of wordsIn(clause)) {
      const type = vocab.typeByWord.get(word);
      if (type) return type;
    }
  }
  return undefined;
}

function rolesFor"""
        new = """  }
  return undefined;
}

function rolesFor"""
        if s.count(old) != 1: raise SystemExit('anchor for no_whole_clause_fallback not found')
        return s.replace(old, new)
    M['k07']['no_whole_clause_fallback'] = g
    def h(s):
        # emulate the pre-fix behaviour: first type word anywhere in the clause (regardless of match text)
        old = """      for (const word of wordsIn(match[0])) {
        const type = vocab.typeByWord.get(word);
        if (type) return type;
      }"""
        new = ""
        if s.count(old) != 1: raise SystemExit('anchor for back_to_first_word_in_clause not found')
        return s.replace(old, new)
    M['k07']['back_to_first_word_in_clause'] = h
build_special()

def run(task, name, fn):
    cfg = CFG[task]
    wt = os.path.join(SCR, cfg['wt'])
    path = os.path.join(wt, cfg['src'])
    orig = open(path, encoding='utf-8').read()
    try:
        if fn is not None:
            open(path, 'w', encoding='utf-8', newline='').write(fn(orig))
        out = os.path.join(tempfile.gettempdir(), 'mut-%s-%s.json' % (task, name))
        if os.path.exists(out): os.remove(out)
        subprocess.run(['pnpm', 'exec', 'vitest', 'run', cfg['test'], '--reporter=json', '--outputFile=' + out],
                       cwd=os.path.join(wt, cfg['pkg']), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        j = json.load(open(out, encoding='utf-8'))
        failed = [a['fullName'] if 'fullName' in a else a['title'] for f in j['testResults'] for a in f['assertionResults'] if a['status'] == 'failed']
        return j['numTotalTests'], j['numPassedTests'], failed
    finally:
        open(path, 'w', encoding='utf-8', newline='').write(orig)

task = sys.argv[1]
names = sys.argv[2:] or ['__baseline__'] + list(M[task].keys())
for n in names:
    fn = None if n == '__baseline__' else M[task][n]
    tot, ok, failed = run(task, n, fn)
    print('%-42s %3d/%-3d  failed=%d' % (n, ok, tot, len(failed)))
    for t in failed:
        print('      x', t[:150])
