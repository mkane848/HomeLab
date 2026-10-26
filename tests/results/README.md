# tests/results — how to read this directory

Raw output from `tests/test-tasks.ps1` (the task-veracity benchmark). Per run: a graded `.json`, the raw `.jsonl` opencode transcript, and one appended row in `tasks-summary.tsv`. Files are committed **verbatim and ungraded** ([CONTRIBUTING](../../CONTRIBUTING.md)); grading is a separate pass.

Dated measurement logs, per-category row inventories and the era notes live in [NOTES.md](NOTES.md). Current per-seat standings: [`docs/roadmap.md`](../../docs/roadmap.md) → "Executor standings". Terms: [glossary](../../docs/glossary.md).

## Quick map

| Path | Holds | Read it for |
|---|---|---|
| `tasks-summary.tsv` | One row per graded public-task run (+ a `.json` and `.jsonl` per run) | Per-seat pass rates ("What counts as a pass") |
| `tasks-*_INFRA_/_TIMEOUT_*.jsonl` | Transcripts of runs that never reached the model or timed out; no row | "Not every row is a run" |
| `real-tasks-public.tsv` | Opaque public mirror of the private real-prompt set | Real-task verdicts |
| `toolcalls-summary.tsv` (+ `-llamacpp.tsv`) | Tool-call probe results by host and engine version | [docs/tool-calling.md](../../docs/tool-calling.md) |
| `bench-speed*.tsv`, `llamacpp-soak.tsv`, `overflow-probe.tsv` | Speed, soak and overflow measurements | Hardware and engine numbers |
| `compaction-nudge/`, `compaction-plugin/`, `compaction-daily/` | Assisted or plugin runs, kept apart (`ASSISTED` marker) | Never mix with unassisted rows |
| `NOTES.md` | Dated measurement logs, row inventories, era notes | Why a row or number looks the way it does |


Pass rule in one line: a public-task run passes on **scope + suite + failsOnOld**; a real task on **scope + suite + hidden acceptance tests**. Rows from different eras are not comparable ("Era confound"). Terms: [glossary](../../docs/glossary.md).

## Real-prompt tasks: `real-tasks-public.tsv`

Rows from the private real-prompt set (`docs/roadmap.md` → "Real-use tasks")
are graded differently from everything below: **a run passes on `scope` +
`suite` + `acceptance`**, where acceptance is hidden tests the model never saw,
scope is the guard rails (no lockfile, env, CI or out-of-package edit, under the
ceilings), and the model's own test is not required unless the prompt asked
for one. They never enter `tasks-summary.tsv` and do not compare with its rows.
This file is the public mirror: opaque task id, model, opencode and engine
versions, the three verdicts, `acceptanceHash` (a fingerprint of the hidden
tests that graded the row) and elapsed time. The prompts, transcripts, base
commits and full rows (`real-tasks-summary.tsv`) are in the private repo.

**Compare rows only within one task and one `acceptanceHash`.** A hidden test
can be revised after a run shows it judges wording too narrowly, and the old
rows stay as history under their old fingerprint. So far: `real-01`'s
`6d07589d819c` (2026-10-04 12:42 and 12:51) is superseded. That check was tuned
to the owner's own fix and failed two correct answers. Its `7976ebded682`
replacement is calibrated against other correct phrasings and near-misses.

## What counts as a pass

A run passes only when **`scope` + `suite` + `failsOnOld` are all PASS**.
`typecheck` is informational (never FAIL) and does not affect it.

`typecheck` is `PASS`/`WARN` only for tasks that define a `typecheck` block —
`kane-01` and `lfc-01`. The other manifest tasks then recorded `SKIP` (`lfc-03` has defined one since). **Rows
written before that change show `PASS` for those tasks having compiled
nothing**, because the flag was initialised to true before the guard that runs
`tsc`. Treat a pre-change `typecheck: PASS` on any task other than
`kane-01`/`lfc-01` as "not run".

`failsOnOld` is the one that matters most: revert the source fix, keep the
model's test, and the suite must now go red. A test that stays green on broken
code is the PR #82 trap (`docs/review-gate/testing.md`) and fails here.

**`failsOnOld` is `SKIP` when the suite is already red with the model's change**
(from 2026-10-03, after `asohav-07`'s second `qwen3.6` run). A suite that fails
with the fix fails with it reverted too, whatever the test checks: that run left
a test file that does not parse, and the revert "failed" it. **30 rows written
before the change read `suite: FAIL, failsOnOld: PASS`** — that `PASS` measured
nothing; read it as "not measured". None of them is a pass (the suite gate
already fails them), so no tally of passes changes. Any parser over the TSV must
now tolerate `SKIP` in `failsOnOld` as well as `typecheck`
(`tests/test-fails-on-old.ps1` guards it).

**In 107 recorded rows there are 22 genuine passes**, 17 of them from the
2026-09-23 gap-fill batch (new executor candidates on the post-fix harness) and
1 from the 2026-09-23 evening rerun lane (`asohav-01`, `qwen3.6`):

| timestamp | task | seat |
|---|---|---|
| `2026-09-20T21:58:16` | `lfc-01-listing-status-guard` | `ollama-desktop/qwen3:14b` |
| `2026-09-21T19:15:18` | `kane-01-background-pair` | `ollama-desktop/qwen3:14b` |
| `2026-09-21T21:27:59` | `asohav-01-library-write-reporting` | `ollama-desktop/qwen3:8b` |
| `2026-09-22T07:02:48` | `kane-04-singleton-up-to-n` | `ollama-node3/qwen3:8b` |
| `2026-09-23T00:14:30` | `kane-04-singleton-up-to-n` | `ollama-desktop/devstral-small-2:24b` |
| `2026-09-23T01:23:38` | `lfc-01-listing-status-guard` | `ollama-desktop/laguna-xs-2.1` |
| `2026-09-23T02:01:55` | `kane-04-singleton-up-to-n` | `ollama-desktop/laguna-xs-2.1` |
| `2026-09-23T02:45:46` | `lfc-02-scryfall-headers` | `ollama-desktop/laguna-xs-2.1` |
| `2026-09-23T02:54:45` | `kane-01-background-pair` | `ollama-desktop/nemotron-3.5-lightning` |
| `2026-09-23T03:02:21` | `lfc-01-listing-status-guard` | `ollama-desktop/nemotron-3.5-lightning` |
| `2026-09-23T03:42:23` | `kane-04-singleton-up-to-n` | `ollama-desktop/nemotron-3.5-lightning` |
| `2026-09-23T05:27:38` | `kane-04-singleton-up-to-n` | `ollama-desktop/north-mini-code-1.0` |
| `2026-09-23T06:15:51` | `kane-01-background-pair` | `ollama-desktop/qwen3.5:9b` |
| `2026-09-23T06:26:28` | `lfc-01-listing-status-guard` | `ollama-desktop/qwen3.5:9b` |
| `2026-09-23T06:37:54` | `kane-03-saga-chapter-triggers` | `ollama-desktop/qwen3.5:9b` |
| `2026-09-23T06:39:34` | `kane-04-singleton-up-to-n` | `ollama-desktop/qwen3.5:9b` |
| `2026-09-23T07:00:17` | `lfc-02-scryfall-headers` | `ollama-desktop/qwen3.5:9b` |
| `2026-09-23T07:13:52` | `lfc-01-listing-status-guard` | `ollama-desktop/qwen3.6:35b-a3b-coding` |
| `2026-09-23T07:32:22` | `kane-04-singleton-up-to-n` | `ollama-desktop/qwen3.6:35b-a3b-coding` |
| `2026-09-23T08:09:24` | `lfc-02-scryfall-headers` | `ollama-desktop/qwen3.6:35b-a3b-coding` |
| `2026-09-23T08:32:30` | `kane-04-singleton-up-to-n` | `ollama-node3/ornith:9b` |
| `2026-09-23T18:39:02` | `asohav-01-library-write-reporting` | `ollama-desktop/qwen3.6:35b-a3b-coding` |

Per-seat pass@1 over exit-0 rows — **graded-only ratios, which overstate:
a timeout leaves no row, so the denominator is missing the runs that never
finished. The per-attempt table (timeouts reconstructed from row gaps and the
Ollama server log) lives in `docs/implementation-tasks.md` → "Gap-fill batch
review", alongside a transcript audit finding all 17 gap-fill passes
non-hollow** (see "Era confound" before comparing across rows of this table): `laguna-xs-2.1` 3/3, `qwen3.5:9b` 5/6,
`nemotron-3.5-lightning` 3/4, `qwen3.6:35b-a3b-coding` 4/8,
`north-mini-code-1.0` 1/2, `devstral-small-2:24b` 1/1, `ornith:9b` 1/7,
`ollama-desktop/qwen3:14b` 2/19 (2/12 honest — see truncated rows),
`ollama-desktop/qwen3:8b` 1/28, `ollama-node3/qwen3:8b` 1/6,
`ministral-3:8b` 0/7, `lfm2.5:8b` 0/8, `devstral:24b` 0/1.

## Era confound — read this before comparing seats

The harness changed mid-corpus, so rows from different weeks were graded by different harnesses. **Group by model *and* era, never by model alone.** Full list of changes and dates: [NOTES.md → Era confound](NOTES.md#era-confound--read-this-before-comparing-seats).

| Era marker | Where it shows | Rows before it |
|---|---|---|
| Non-zero exits write no row (~2026-09-21) | `opencodeExit` | six legacy node3 rows are infrastructure |
| `qwen3:14b` `limit.output` 4096 → 8192 (~2026-09-21) | `outputLimit` | 14b rows truncate inside reasoning |
| `typecheck` tri-state | `typecheck` column | `PASS` may mean `tsc` never ran |
| Cap-hit classification (2026-09-30) | `outputCapHit` | liar mode vs cap hit not told apart |
| Compaction + read-budget plugins (2026-10-05, 10-17) | `opencodePlugins`, `readBudget` | client not comparable |
| Sealed checkout (2026-10-22), shell in PowerShell 7 (2026-10-26) | `checkout`, `agentShell` | node3 vs desktop confounded |

## Not every row is a run

Rows that measured nothing about a model are kept as evidence but are not attempts: do not count them as failures, and exclude truncated exit-0 rows from capability denominators. Detail per category: [NOTES.md → Not every row is a run](NOTES.md#not-every-row-is-a-run).

| Category | Signal | Row? |
|---|---|---|
| Never reached the model | `opencodeExit != 0` | legacy rows only; none since 2026-09-21 |
| Truncated before acting | exit 0, `writes=0`, `reason:"length"` at the output cap | yes (exclude from denominators) |
| Genuine liar mode | exit 0, `writes=0`, a `stop` finish | yes (a real failure) |
| Prompt truncated by Ollama | `server.log` "truncating input prompt" | no row since 2026-10-03 (`_TRUNCATED_`) |
| No transcript kept | missing `.jsonl` | yes |
| Hand-recorded | `n/a` / `NOT_RUN` | 1 row |

Section names kept for citations: "Prompt truncated by Ollama" and "node3's `qwen3:8b` re-run" are in NOTES.md.

## Re-deriving this

Nothing here is hand-maintained state; the raw files are the source of truth.
The classification is `opencodeExit != 0` → never reached the model,
`reason:"length"` with `writes=0` under the 4096 cap → truncated,
missing `.jsonl` → no transcript, `writes=0` with exit 0 under the 8192 cap →
genuine liar mode. (Corrected 2026-09-30: apply that per seat, not per era. A
seat still at 4096 gets the "truncated" reading whenever its last `step_finish`
is an empty `length` step at the cap; only a `stop` finish is liar mode. A run
JSON written after the 2026-09-30 harness change carries `outputCapHit`,
`finishReason`, `lastStepOutput` and `outputLimit`, so newer rows need no
re-derivation.) Context events are re-derivable the same way: the real
`Get-ContextEvents` from `test-tasks.ps1` runs on any `.jsonl` (see
`tests/test-context-events.ps1` for how to load it); run JSONs from
2026-10-04 on carry the result as `contextEvents`.
Group seats by `model`, not `modelLabel`. Note that a
`.jsonl` filename's timestamp can differ from its TSV row's by a second or
two — match with a tolerance, not equality.
