# k2 progress log (running notes; the report is report.k2.md)

- 01:10 cloned KaneEnabler into G/repos, built rig (make_rig.py) with placeholder prompts, 5 entries.
- dry (fresh worktrees, --frozen-lockfile --ignore-scripts, NO setup step): baselines 10/10, 11/11, 3/3, 20/20, 108/108 -> matches the mined numbers; setup NOT needed for any of the five.
- ref patches cut with mkpatch.sh from 271636f vs 605a2e0, restricted to each task's own files (kane-14: 2 src files + 1 new test file).
- acceptance = upstream fix commit's test file for all five (decision for kane-14: yes, with the prop name instanceId pinned in the prompt).
- Files: G/build_entries.py composes entries.k2.json from G/prompts/<id>.txt + G/source/<id>.txt + G/acceptance/<id>.note.txt.
- 01:25 pass 1 (placeholder prompts): dry/ref/srconly/testsonly for all five tasks behaved as expected (ref all PASS + acceptance PASS; srconly failsOnOld FAIL; testsonly scope+suite FAIL). kane-14 multi-file revert worked.
- 01:30 mutation checks done (notes/mutations.txt): upstream tests pin the core of every fix; unpinned parts: 10 http:/data: schemes; 11 cancelled guard in .catch; 12 instanceof SyntaxError; 13 power/toughness half + non-adventure layouts; 14 App.tsx wiring (no gate checks it).
- prompts + source strings drafted (G/prompts, G/source); entries.k2.json rebuilt.
