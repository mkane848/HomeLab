# Analysis scripts and outputs

The scripts the audit session ran to recompute figures, replay model runs and check its own follow-ups. They ran in the cloud container and keep its paths (`/home/user/HomeLab`, the session's scratch directory). They read `tests/results/` as it stood when they ran, so running one today gives today's numbers, not the review's. They are a record of the method, not maintained tools; see the [folder README](../README.md#provenance-and-caveats).

## audit-data/

The recompute behind [the review](../review-2026-09-29.md). All read-only over `tests/results/`.

| Script | What it does |
|---|---|
| `audit.py` | Corpus counts; the step-6 standings grid with Wilson intervals; the DP8 and DP9 Fisher tests; per-task pass rate in the window; run-to-run noise; zero-write rows per seat; elapsed seconds of passes (§0, §1) |
| `cap.py` | Transcripts whose final step is empty and ended `finish=length` at exactly the output cap (§2) |
| `zero.py` | Census of exit-0 zero-write rows since 2026-09-22, and which are cap hits (§2) |
| `capcheck.py` | An independent re-derivation of the cap-hit rule that PR [#66] then implemented |
| `prompts.py` | Distinct prompt hashes per task, with the run counts and date ranges, and a census of the `acceptance` field |
| `acc.py` | `lfc-03`: the owner's acceptance tests against the gates (§3) |
| `standings.py`, `standings2.py` | The same-config standings after the N>1 data (DP11). `standings2.py` adds the opencode version to the config key |
| `delta.py` to `delta4.py` | The §9 update after PRs #61 to #64: what changed, same-config tallies, replicate pairs. `delta4.py` writes the per-attempt table |
| `pairs2.py` | Replicate-pair concordance, split by whether the two attempts share an opencode version |
| `pass12.py` | Lists the 12 new DP11 passes and what each transcript did; the input to `replay-12/` |

## replay-12/

The replay audit of the 12 new passes (item 4 of the follow-ups; the owner's DP12 audit landed first, so this was a second replay). `run_audit.py` is the driver. For each pass, on a scratch worktree at the task's pinned base:

1. replay the transcript's completed edit and write calls (`replay.py`, which applies the diff opencode itself recorded, and falls back to the exact old-to-new string);
2. diff against the base and check the scope;
3. run the task's test command (the suite gate, reproduced);
4. revert the source files, keep the model's tests, rerun (the `failsOnOld` gate, reproduced);
5. compare base test names, assertion counts and removed base lines (a weakening check).

The other scripts: `crosscheck.py` runs the model's tests against the real upstream fix and the upstream tests against the model's source; `envcheck.py` asks which environment each recorded `asohav-02` gate result matches (the `DATABASE_URL` finding behind the `testEnv` pin in PR [#75]); `accept.py` does the `lfc-03` acceptance run; `probe.py`, `probe2.py`, `why_fail.py` and `detail_c.py` are one-off investigations. `setup.sh` prepares the worktrees. The outputs are `out-all.txt` (first replay), `out-all2.txt` (second), `out-cross.txt`, `out-env.txt`, `out-env-run1.txt`, and `out/` (the replayed diffs, suite logs and result JSON). `logs/` holds the install logs.

## verify/

Scripts and outputs from checking each follow-up before it was proposed.

| File | What it is |
|---|---|
| `mutants-cap.sh`, `mutants-gate.sh` | Mutants of `test-tasks.ps1`, each of which must make `test-cap-hit.ps1` fail (PR [#66]) |
| `mutants-batch.sh` | Mutants of `run-tasks-batch.ps1`, each of which must make `test-batch-plan.ps1` fail (PR [#67]) |
| `mutants-pins.sh` | Mutants, each of which must make `test-task-pins.ps1` fail (PRs [#68], [#69]) |
| `e2e-setup.sh`, `fetch-by-sha.sh` | The real `run-tasks-batch.ps1 -SetupOnly` against fixture repos, and how `git fetch origin <sha>` behaves against a local bare origin |
| `nested.ps1`, `stash-check.ps1` | The nested-argument defect behind the two-`srcRevertFiles` bug (review §7.1), and the real `git stash push` line run against a throwaway repo |
| `build_candidates.py`, `spot.sh`, `claims.py`, `jsonc_check.py`, `syntax.sh` | `build_candidates.py` writes the candidate table and checks that every SHA exists; `spot.sh` is the independent re-run of four candidates; `claims.py` recounts the figures behind the §5 doc claims (probe results, the zero-write census, opencode versions); `jsonc_check.py` parses and diffs a JSONC file; `syntax.sh` syntax-checks every script a PR touched |
| `pins.tsv`, `lsremote-*.txt`, `last-test-*.txt` | The task pins, the `git ls-remote` listings of the three repos at the time (evidence that the pinned commits were published or not), and the last output of the guards |

## harness-mutants/

Proof that a guard fails when the code it protects is wrong. Each mutant is stored as a diff against the version of the harness it was cut from, with carriage returns stripped (the mutants were written with LF line endings; `test-tasks.ps1` is CRLF), so the diffs show the mutation and nothing else.

| Folder | Mutants of | Against | Guard |
|---|---|---|---|
| `testenv/` | `test-tasks.ps1` (M1 to M11) | `c099957` | `tests/test-task-env.ps1` (PR [#75]). `mutants.py` generates them and also M12 to M16, which are edited manifests; `patch_tasks.py` is the script that wrote the `testEnv` change into the harness; `proto_e2e.ps1` is the end-to-end prototype of the guard |
| `revert/` | `test-tasks.ps1` (M1 to M6) | `7b5a554` | `tests/test-revert-source.ps1` (PR [#76]): the old `git stash` revert, nested-array arguments, text restore, `HEAD` instead of the pin, no restore, a revert that reaches the tests |

[#66]: https://github.com/mkane848/HomeLab/pull/66
[#67]: https://github.com/mkane848/HomeLab/pull/67
[#68]: https://github.com/mkane848/HomeLab/pull/68
[#69]: https://github.com/mkane848/HomeLab/pull/69
[#75]: https://github.com/mkane848/HomeLab/pull/75
[#76]: https://github.com/mkane848/HomeLab/pull/76
