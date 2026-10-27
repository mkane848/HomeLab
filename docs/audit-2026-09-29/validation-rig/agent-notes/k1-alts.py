#!/usr/bin/env python3
"""alts.py : emulate 'model source = <alternative fix applied to the PIN source>, tests = the upstream fix commit's test file' in the scratch
worktrees (which sit at the fix commits, so their test files ARE the oracle). Source is restored from memory afterwards (no git commands).
usage: alts.py k07|k08|k09 [name ...]"""
import json, os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
CFG = {
  'k07': dict(pin='pins/k07/apps/commander-recommender/server/src/services/signals.ts', wt='scratch/k07', pkg='apps/commander-recommender/server',
              src='apps/commander-recommender/server/src/services/signals.ts', test='src/services/signals.test.ts'),
  'k08': dict(pin='pins/k08/apps/commander-recommender/server/src/services/signals.ts', wt='scratch/k08', pkg='apps/commander-recommender/server',
              src='apps/commander-recommender/server/src/services/signals.ts', test='src/services/signals.test.ts'),
  'k09': dict(pin='pins/k09/apps/commander-recommender/client/src/lib/filters.ts', wt='scratch/k09', pkg='apps/commander-recommender/client',
              src='apps/commander-recommender/client/src/lib/filters.ts', test='src/lib/filters.test.ts'),
}
def rep(*pairs):
    def f(s):
        for old, new in pairs:
            if s.count(old) != 1:
                raise SystemExit('anchor count %d: %r' % (s.count(old), old[:90]))
            s = s.replace(old, new)
        return s
    return f
FQ_OLD = """    const hit = payoffMatchers.some((m) => (typeof m === 'function' ? false : m.test(clause)));
    if (!hit) continue;
    for (const word of wordsIn(clause)) {
      const type = vocab.typeByWord.get(word);
      if (type) return type;
    }"""
A = {'k07': {}, 'k08': {}, 'k09': {}}
A['k07']['pin_unfixed'] = rep()
A['k07']['last_type_word_in_clause'] = rep((FQ_OLD, """    const hit = payoffMatchers.some((m) => (typeof m === 'function' ? false : m.test(clause)));
    if (!hit) continue;
    let last: string | undefined;
    for (const word of wordsIn(clause)) {
      const type = vocab.typeByWord.get(word);
      if (type) last = type;
    }
    if (last) return last;"""))
A['k07']['span_by_index_then_clause'] = rep((FQ_OLD, """    let hit = false;
    for (const m of payoffMatchers) {
      if (typeof m === 'function') continue;
      const mm = m.exec(clause);
      if (!mm) continue;
      hit = true;
      const span = clause.slice(mm.index, mm.index + mm[0].length);
      for (const word of wordsIn(span)) {
        const type = vocab.typeByWord.get(word);
        if (type) return type;
      }
    }
    if (!hit) continue;
    for (const word of wordsIn(clause)) {
      const type = vocab.typeByWord.get(word);
      if (type) return type;
    }"""))
A['k07']['type_after_return_or_put_verb'] = rep((FQ_OLD, """    const hit = payoffMatchers.some((m) => (typeof m === 'function' ? false : m.test(clause)));
    if (!hit) continue;
    const verb = clause.search(/\\b(?:return|put)\\b/i);
    const tail = verb >= 0 ? clause.slice(verb) : clause;
    for (const word of wordsIn(tail)) {
      const type = vocab.typeByWord.get(word);
      if (type) return type;
    }
    for (const word of wordsIn(clause)) {
      const type = vocab.typeByWord.get(word);
      if (type) return type;
    }"""))
A['k07']['nearest_to_payoff_end'] = rep((FQ_OLD, """    let anchor = -1;
    for (const m of payoffMatchers) {
      if (typeof m === 'function') continue;
      const mm = m.exec(clause);
      if (mm) { anchor = mm.index + mm[0].length; break; }
    }
    if (anchor < 0) continue;
    let best: string | undefined; let bestDist = Infinity; let pos = 0;
    for (const word of wordsIn(clause)) {
      const at = clause.toLowerCase().indexOf(word, pos);
      const type = vocab.typeByWord.get(word);
      if (type) { const d = Math.abs(at - anchor); if (d < bestDist) { bestDist = d; best = type; } }
      if (at >= 0) pos = at + word.length;
    }
    if (best) return best;"""))

# ---------------- kane-08 : alternatives built on the PIN source ----------------
RW_OLD = "        /(?:whenever|if)[^.;]*\\b(?:dies?|dying)\\b/i,\n"
CONS_OLD = "          clauses(f.text).some((clause) => sacrificesACreature(clause, vocab)),"
SK_OLD = "    pattern = new RegExp(`\\\\bsacrifice (?:${SACRIFICE_QUANTIFIER})\\\\b.*\\\\b${forms}\\\\b`, 'i');"
A['k08']['pin_unfixed'] = rep()
A['k08']['alt_regex_lookaheads_only'] = rep(
    (RW_OLD, "        /(?:whenever|if)(?![^.;]*\\bwould (?:die|dies)\\b)(?![^.;]*\\bdealt damage by\\b)[^.;]*\\b(?:dies?|dying)\\b/i,\n"))
A['k08']['alt_comma_stops_kind_scan'] = rep(
    (SK_OLD, "    pattern = new RegExp(`\\\\bsacrifice (?:${SACRIFICE_QUANTIFIER})\\\\b[^,]*\\\\b${forms}\\\\b`, 'i');"))
A['k08']['full_alt_A'] = rep(
    (RW_OLD, "        /(?:whenever|if)(?![^.;]*\\bwould (?:die|dies)\\b)(?![^.;]*\\bdealt damage by\\b)[^.;]*\\b(?:dies?|dying)\\b/i,\n"),
    (SK_OLD, "    pattern = new RegExp(`\\\\bsacrifice (?:${SACRIFICE_QUANTIFIER})\\\\b[^,]*\\\\b${forms}\\\\b`, 'i');"))
A['k08']['full_alt_B_fn_matcher_for_rewards'] = rep(
    (RW_OLD, "        (f: CardFacts) => clauses(f.text).some((c) => /(?:whenever|if)[^.;]*\\b(?:dies?|dying)\\b/i.test(c) && !/\\bwould (?:die|dies)\\b/i.test(c) && !/\\bdealt damage by\\b/i.test(c)),\n"),
    (SK_OLD, "    pattern = new RegExp(`\\\\bsacrifice (?:${SACRIFICE_QUANTIFIER})\\\\b[^,]*\\\\b${forms}\\\\b`, 'i');"))
A['k08']['only_gargadon_via_or_list'] = rep(
    (CONS_OLD, "          clauses(f.text).some((clause) => sacrificesACreature(clause, vocab) && !/\\bartifact\\b[^:]*\\bor\\b/i.test(costSideOf(clause)) && !/\\bartifact,/i.test(costSideOf(clause))),"))
# ---------------- kane-09 ----------------
MC_OLD = "    if (!suggestion.colorIdentity.some((color) => allowed.has(color))) return false;"
A['k09']['pin_unfixed'] = rep()
A['k09']['every_in_allowed_set'] = rep((MC_OLD, "    if (!suggestion.colorIdentity.every((color) => allowed.has(color))) return false;"))
A['k09']['difference_empty'] = rep((MC_OLD, "    if (suggestion.colorIdentity.filter((color) => !allowed.has(color)).length > 0) return false;"))
A['k09']['subset_but_colourless_dropped'] = rep((MC_OLD, "    if (suggestion.colorIdentity.length === 0 || !suggestion.colorIdentity.every((color) => allowed.has(color))) return false;"))

task = sys.argv[1]; cfg = CFG[task]
names = sys.argv[2:] or list(A[task].keys())
path = os.path.join(HERE, cfg['wt'], cfg['src'])
fixed_src = open(path, encoding='utf-8').read()
pin_src = open(os.path.join(HERE, cfg['pin']), encoding='utf-8').read()
try:
    for n in names:
        open(path, 'w', encoding='utf-8', newline='').write(A[task][n](pin_src))
        out = os.path.join(tempfile.gettempdir(), 'alt-%s-%s.json' % (task, n))
        if os.path.exists(out): os.remove(out)
        subprocess.run(['pnpm', 'exec', 'vitest', 'run', cfg['test'], '--reporter=json', '--outputFile=' + out],
                       cwd=os.path.join(HERE, cfg['wt'], cfg['pkg']), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        j = json.load(open(out, encoding='utf-8'))
        failed = [a['fullName'] for f in j['testResults'] for a in f['assertionResults'] if a['status'] == 'failed']
        print('%-40s %3d/%-3d failed=%d' % (n, j['numPassedTests'], j['numTotalTests'], len(failed)))
        for t in failed: print('      x', t[:140])
finally:
    open(path, 'w', encoding='utf-8', newline='').write(fixed_src)
