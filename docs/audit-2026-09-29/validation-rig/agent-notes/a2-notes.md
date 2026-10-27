# a2 interim notes (2026-10-03) - superseded by report.a2.md when that exists

## State
- clone: G/repos/ASoHaVCompanionApp ; rig: G/rig ; builder: G/build/build_entries.py (prompts in G/prompts/<id>.prompt.txt / .source.txt)
- dry runs (serial, fresh worktrees): 05 baseline 14/14; 07 baseline 5/5 + acceptance fails on base (1 failed | 4 passed); 08 baseline 18/18 + acceptance fails on base (1 failed | 19 passed)
- ref patches in G/rig/ref: 07 and 08 via mkpatch.sh (fix commit restricted to allowFiles); 05 hand-built (adminLogic.ts = fix commit verbatim, library.ts = parent + 4 validation hunks, test = parent + 2 verbatim describe blocks) -
  rebuilt from the fix commit and byte-identical to mine-asohav-old/{library.scoped-fix.ts.bak,library.test.scoped.ts,adminLogic.fixcommit.ts.bak}
- serial 3-mode runs: ref = all PASS (+acceptance PASS on 07/08); srconly = failsOnOld FAIL (07: suite FAIL too, spec reversal); testsonly = scope FAIL + suite FAIL

## RIG / HARNESS HAZARD FOUND (important)
Running two tasks of the SAME clone concurrently corrupts results: `git stash` is repo-global (refs/stash is shared by all worktrees of a clone).
The harness's failsOnOld step does `git stash push -- <srcRevertFiles>` ... `git stash pop` (pops stash@{0}, whoever pushed it).
My first batch (3 tasks in parallel, one clone) gave acceptance=FAIL on 07/08 `ref` runs and left 2 stray stashes; the serial rerun gave acceptance=PASS.
Invalid parallel results quarantined in G/rig/tests/results.invalid-parallel and G/rig/out.invalid-parallel. All reported numbers come from serial runs.
This also contradicts the AGENTS.md remark that different task ids can safely run from two terminals: tasks that share a repo (kane-01..04, asohav-*, lfc-*) share refs/stash.
