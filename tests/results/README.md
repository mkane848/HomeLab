# tests/results — how to read this directory

Raw output from `tests/test-tasks.ps1` (the task-veracity benchmark). Per run:
a graded `.json`, the raw `.jsonl` opencode transcript, and one appended row in
`tasks-summary.tsv`.

Everything here is committed **verbatim and ungraded** per `CONTRIBUTING.md` —
grading happens separately, against the key, by someone who did not generate the
runs. This file is that separate pass for the 2026-09-19 → 2026-09-21 corpus.

## What counts as a pass

A run passes only when **`scope` + `suite` + `failsOnOld` are all PASS**.
`typecheck` is informational (never FAIL) and does not affect it.

`typecheck` is `PASS`/`WARN` only for tasks that define a `typecheck` block —
`kane-01` and `lfc-01`. The other six manifest tasks now record `SKIP`. **Rows
written before that change show `PASS` for those tasks having compiled
nothing**, because the flag was initialised to true before the guard that runs
`tsc`; all three `kane-02` rows are the clearest case, since they never reached
the model at all. Treat a pre-change `typecheck: PASS` on any task other than
`kane-01`/`lfc-01` as "not run".

`failsOnOld` is the one that matters most: revert the source fix, keep the
model's test, and the suite must now go red. A test that stays green on broken
code is the PR #82 trap (`docs/review-gate/testing.md`) and fails here.

**In 43 recorded runs there is exactly one genuine pass:**

| timestamp | task | seat |
|---|---|---|
| `2026-09-20T21:58:16` | `lfc-01-listing-status-guard` | `ollama-desktop/qwen3:14b` |

## Not every row is a run

**18 of the 43 rows measured nothing about a model.** They are kept as evidence,
but they are not attempts and must not be counted as failures.

### Never reached the model — 6 rows

`opencodeExit=1`, `writes=0`. Each transcript is 307 bytes holding exactly one
event: `APIError: Cannot connect to API`, against
`http://NODE3_IP:11434/v1/chat/completions`. Ollama on node3 never received a
request.

| timestamp | task | seat |
|---|---|---|
| `2026-09-20T21:55:34` | `kane-01-background-pair` | `ollama-node3/qwen3:8b` |
| `2026-09-20T22:05:24` | `kane-01-background-pair` | `ollama-node3/qwen3:8b` |
| `2026-09-21T10:56:53` | `lfc-01-listing-status-guard` | `ollama-node3/qwen3:8b` |
| `2026-09-21T13:29:53` | `kane-02-multiword-creature-type` | `ollama-node3/qwen3:8b` |
| `2026-09-21T13:33:11` | `kane-02-multiword-creature-type` | `ollama-node3/qwen3:8b` |
| `2026-09-21T13:36:26` | `kane-02-multiword-creature-type` | `ollama-node3/qwen3:8b` |

These six were originally read as "6/6 liar mode" — a capability finding about
node3 that reached `docs/roadmap.md`, `CHANGELOG.md` and a config change before
anyone re-read the transcripts. **node3's liar-mode denominator is 0.** It has no
capability data yet, in either direction. See the corrected roadmap entry,
"Node3's `qwen3:8b` 'liar mode' was never liar mode".

Watch for these tells, all present in the rows themselves:

- **`opencodeExit=1`.** Real liar mode exits **0** — the model answered, it just
  answered in prose. A non-zero exit is always infrastructure.
- **`elapsedSec` 191.9–195.3 across three different tasks.** A uniform ~192s is
  a connect timeout, not three tasks independently reasoning to the same place.
- **`suite=PASS` with `writes=0`** is vacuous: the suite passed because nothing
  changed. Never read it as a result.

`tests/test-tasks.ps1` no longer produces rows like these — any non-zero exit is
now a FAILed run with an `_INFRA_`-tagged transcript and no summary row, and
`tests/run-tasks-batch.ps1` checks every host with `/api/tags` before starting.

### Truncated before acting — 7 rows

`opencodeExit=0`, `writes=0`, transcript ends `step_finish` with
`reason: "length"` and usage `output` of exactly **4096** — the configured
`limit.output`, hit with ~25k of the 32768 context window still unused. The
reasoning block consumed the whole output budget before any edit call.

| timestamp | task | seat |
|---|---|---|
| `2026-09-20T08:33:13` | `kane-01-background-pair` | `ollama-desktop/qwen3:14b` |
| `2026-09-20T08:43:22` | `kane-01-background-pair` | `ollama-desktop/qwen3:14b` |
| `2026-09-21T12:39:26` | `kane-01-background-pair` | `ollama-desktop/qwen3:14b` |
| `2026-09-21T12:45:26` | `kane-01-background-pair` | `ollama-desktop/qwen3:14b` |
| `2026-09-21T12:50:14` | `kane-01-background-pair` | `ollama-desktop/qwen3:14b` |
| `2026-09-21T12:54:48` | `kane-01-background-pair` | `ollama-desktop/qwen3:14b` |
| `2026-09-21T12:58:47` | `kane-01-background-pair` | `ollama-desktop/qwen3:14b` |

An eighth run, `2026-09-21T13:46:15` (`lfc-01`, same seat), also hit the cap but
made 3 edits first, so it is gradable — the cap cost it the suite, not the
attempt. Of 16 desktop-14b runs, 8 truncated.

`ollama-desktop/qwen3:14b` `limit.output` is now 8192. **Runs from before that
change cannot be compared against the 8b**, which carries the same cap and
rarely reaches it.

### No transcript kept — 4 rows

Pre-dating the change that moved the raw `.jsonl` into this directory instead of
deleting it from `%TEMP%`. The graded row stands; the "why" is unrecoverable.

| timestamp | task | seat |
|---|---|---|
| `2026-09-19T18:02:01` | `kane-01-background-pair` | `qwen3-14b` |
| `2026-09-19T18:29:07` | `kane-01-background-pair` | `qwen3-8b` |
| `2026-09-19T18:37:31` | `kane-01-background-pair` | `qwen3-8b` |
| `2026-09-19T18:39:45` | `kane-01-background-pair` | `devstral-24b` |

### Hand-recorded — 1 row

| timestamp | task | seat |
|---|---|---|
| `2026-09-19T19:00:00` | `kane-01-background-pair` | `devstral-24b-vscode-agent` |

The VS Code Agent-mode cross-check, typed in by hand. Carries `n/a` and
`NOT_RUN` values the harness cannot emit — **any parser over this TSV must
tolerate them.**

## Gradable coverage

25 of 43 rows. Against the N=10-per-cell policy (`docs/roadmap.md`):

| task | seat | gradable |
|---|---|---|
| `kane-01-background-pair` | `ollama-desktop/qwen3:14b` | 2/10 |
| `kane-01-background-pair` | `ollama-desktop/qwen3:8b` | 7/10 |
| `lfc-01-listing-status-guard` | `ollama-desktop/qwen3:14b` | 7/10 |
| `lfc-01-listing-status-guard` | `ollama-desktop/qwen3:8b` | 7/10 |
| `lfc-01-listing-status-guard` | `qwen3-8b` (legacy label) | 1/10 |
| `lfc-01-listing-status-guard` | `qwen3-14b-rerun` (legacy label) | 1/10 |

**Two of the eight manifest tasks have any gradable data.** `kane-03`, `kane-04`,
`asohav-01`, `asohav-02` and `lfc-02` have never been run; `kane-02`'s only three
rows are all node3 connection failures. Between-task variance — the thing the
2026-09-21 breadth pivot exists to measure — is still unmeasured.

## Re-deriving this

Nothing here is hand-maintained state; the raw files are the source of truth.
The classification is `opencodeExit != 0` → never reached the model,
`reason:"length"` with `writes=0` → truncated, missing `.jsonl` → no transcript.
Note that a `.jsonl` filename's timestamp can differ from its TSV row's by a
second or two — match with a tolerance, not equality.
