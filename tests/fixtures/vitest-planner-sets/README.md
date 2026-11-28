# vitest output for the check of a planner's set before use

Real output of `vitest run`, used by `tests/test-planner-set-check.ps1` to test `Get-PlannerSetUsability` in
`tests/test-tasks.ps1`. Made on 2026-11-27 (Linux, node 22) with the two versions the task repositories' lockfiles name:
vitest **2.1.9** (A Story of Heroes and Villains, `docs/audit-2026-09-29/mining/asohav-old/verification.md`) and
**5.0.1** (LFCbot, `docs/audit-2026-09-29/mining/lfc/verification.md`).

Each file is `v<version>-<case>.txt`: the command's whole output, captured without a terminal as the harness captures
it (`CI=1`, no colour), then a last line `exit=<code>`. The scratch folder's path was replaced with `/work/apps/x`.

| Case | The set | The command |
|---|---|---|
| `ok` | `src/sum.test.js`, with a test that fails on the base | `vitest run src/sum.test.js` |
| `passes` | `src/sum.test.js`, all passing | the same |
| `missing-import` | `src/sum.test.js`, importing a file that does not exist | the same |
| `syntax` | `src/sum.test.js`, a syntax error | the same |
| `not-run` | `src/sum-three.test.js`, failing, which the filter skips | the same |
| `all-ok` | `src/sum-three.test.js`, failing | `vitest run` |
| `all-missing` | `src/mul.test.js`, importing a file that does not exist | `vitest run` |
| `elsewhere` | `src/sum-two.test.js`, passing, beside a failing `src/old.test.js` | `vitest run` |

What the two versions differ in: 2.1.9 lists every file it ran (`✓ src/sum.test.js (1 test)`), and 5.0.1 lists only the
files with a failure. So a passing set file cannot be told from one that never ran by the output alone, and the check
also matches each file against the command's path filters.

To make them again: `make-fixture.sh` sets up `src/` for one case in a project folder that
has the vitest version installed (`npm i vitest@2.1.9`; for 5.0.1 npm 10 failed with "Cannot read properties of null
(reading 'edgesOut')", and `bun add vitest@5.0.1` worked), runs the command and saves the output:

```bash
for sc in ok passes missing-import syntax not-run all-ok all-missing elsewhere; do
  ./make-fixture.sh <project folder> v5.0.1-$sc.txt $sc
done
```
