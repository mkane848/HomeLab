# notes-fairness.md - things that make a lfc-bot task unfair / non-deterministic / unrunnable on the Windows + PowerShell harness

(Step 6 of the brief. Each item says whether it was OBSERVED here or only READ.)

## H1. HARNESS BUG (observed): tests/test-tasks.ps1 can only grade tasks with exactly ONE `srcRevertFiles` entry
`test-tasks.ps1` builds the failsOnOld stash as
`Run-Native "git" @("-C", $wt.Wt, "stash", "push", "--", @($tk.srcRevertFiles))`.
`Run-Native` declares `[string[]]$Arguments`, which stringifies the NESTED array into ONE space-joined element.
Empirical repro (pwsh 7 in this sandbox; tmp/nested-args.ps1):
  srcRevertFiles=1 -> printf args: [stash] [push] [--] [src/a.ts]
  srcRevertFiles=2 -> printf args: [stash] [push] [--] [src/a.ts src/b.ts]      <- one argument containing a space
and git rejects that pathspec (throwaway worktree):
  error: pathspec ':(,prefix:0)src/services/digest.ts src/utils/constants.ts' did not match any file(s) known to git   (exit 1)
  whereas `git stash push -- src/services/digest.ts src/utils/constants.ts` works (exit 0).
Effect: any manifest task with 2+ srcRevertFiles would report `fails-on-old FAIL "git stash push failed - cannot grade"` for EVERY model.
All 9 existing tasks have exactly 1 srcRevertFiles entry, so nothing has hit it yet.
One-line fix: `Run-Native "git" (@("-C", $wt.Wt, "stash", "push", "--") + @($tk.srcRevertFiles))`.
Workaround with no harness edit: list only the primary source file in srcRevertFiles (allowFiles may still list more).
Not tested: Windows PowerShell 5.1 (same $OFS-join semantics are documented, but I only ran pwsh 7).

## H2. HARNESS LIMIT (read + reasoned): a task whose fix CREATES a new source file cannot be graded by failsOnOld
`git stash push -- <path>` only stashes TRACKED changes; an untracked new src file is not stashed (pathspec error if it is the
only path, or silently left in place if other tracked paths are given), so "revert source, keep test" would keep the new source.
Needed for feature slices that add a new module (e.g. 1749a62 schedule-parser.ts): revert = `git stash push -u -- <path>` or delete the file.
(A NEW TEST file is fine: asohav-02 already does it.)  `git status --porcelain` also reports a brand-new DIRECTORY as one `?? dir/`
line, which the scope gate would read as outside allowFiles (only matters if a model creates files in a new dir).

## H3. Typecheck step hard-codes `pnpm exec tsc` (read): lfc-* are npm repos. It works only if pnpm is installed on the box (informational gate, WARN not FAIL).

## H4. ambient env var (observed): this sandbox exports MANAPOOL_API_KEY. All my runs use `env -u MANAPOOL_API_KEY`.
The known lfc-02 flake lives in tests/services/scryfall.test.ts, so ANY task whose test command includes that file (lfc-02, and my
proposed lfc-05 = commit 64939c4 scryfall slice) inherits it: with the key set, the baseline gate itself goes red before the model runs.
(I did not need to reproduce the flake for this; it is documented in the repo's steward skill and in lfc-02's entry.)
Suggested harness fix: make Run-Native scrub MANAPOOL_API_KEY (and DISCORD_*) from the child env for lfc tasks (a manifest `env` block: {"MANAPOOL_API_KEY": null}).
