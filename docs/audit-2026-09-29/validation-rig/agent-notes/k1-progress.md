# k1 progress (agent k1; KaneEnabler tasks kane-07/08/09)
- [x] clone G/repos/KaneEnabler; SHAs + parent links verified (all 3 fix commits have the stated single parent)
- [x] entries builder: G/work/build_entries.py (prompts/sources in G/work/text/) -> G/entries.k1.json
- [x] rig built (G/rig); ref patches via mkpatch.sh in G/rig/ref
- [x] DRY (fresh worktrees, NO setup): kane-07 76/76, acceptance fails on base 1 failed/77; kane-08 234/234, acc 4 failed/238; kane-09 16/16, acc 3 failed/17
- [ ] ref/srconly/testsonly, real prompts, env matrix, determinism, mutation checks, report
- LESSON (rig/harness hazard): never run two tasks of the SAME repo concurrently. git stash is shared by all worktrees of one clone;
  my first concurrent `ref` batch popped each other's stashes (UU conflicts, 'stash pop failed' WARNs, acceptance FAIL). Logs kept in G/work/raced/ as evidence. All later runs are sequential.
- [x] SEQUENTIAL sanity (placeholder prompts): dry+ref for all 3: every gate PASS, acceptance PASS (kane-07 77/77, kane-08 238/238, kane-09 17/17); no setup, no WARN
- NEXT: real prompts (G/work/text/prompt.<id>.txt + source.<id>.txt + acceptance-note.<id>.txt), mutation checks (scratch worktree, NO git stash), then formal battery (dry/ref/srconly/testsonly + env matrix + det1..3) on the FINAL manifest
- [x] mutation checks done (work/mutation.k07|k08|k09.txt; harness work/mutate.py, scratch worktrees work/scratch/k0x at the FIX commits, no git stash):
  k08: a(rewards lookbehind)->Flame-Blessed test red; b(dealt-damage lookahead)->Markov red; c(sacrifice span)->Blood Hypnotist red (+ naive first-comma cut turns 2 PRE-EXISTING tests red);
       d(sacrificesCreatureSpecifically)->Gargadon red. NOT pinned: amplifies lookbehind (238/238), "colon wins over later sacrifice" (Nim Devourer-style, c3 238/238), exact heuristic of (d) (d2/d3 238/238).
       hidden constraint (rewards as function) -> 2 PRE-EXISTING tests red (236/238).
  k07: no-fallback -> 3 PRE-EXISTING red (Gravemother + 2 lord wording); consumes-before-rewards order -> Angel test red (76/77)
  k09: intersection->3 red; colourless dropped->2 red; contains-all->3 red; exclude dropped->1 red (pre-existing)
