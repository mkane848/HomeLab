# tests/results — how to read this directory

Raw output from `tests/test-tasks.ps1` (the task-veracity benchmark). Per run:
a graded `.json`, the raw `.jsonl` opencode transcript, and one appended row in
`tasks-summary.tsv`.

Everything here is committed **verbatim and ungraded** per `CONTRIBUTING.md` —
grading happens separately, against the key, by someone who did not generate the
runs. This file is that separate pass for the full corpus, re-inventoried
2026-09-23 at 107 rows (was 43 rows / 1 pass).

> **Update 2026-09-30.** Everything below is the 2026-09-23 inventory (107
> rows, 22 passes), kept as that day's record. Three of its statements no
> longer hold and are corrected inline (search "Correction (2026-09-30)"). The
> corpus is now 218 `tasks-summary.tsv` rows, each with a result JSON, 81 of
> which pass scope + suite + failsOnOld. The current per-seat picture is
> `docs/roadmap.md` → "Executor standings"; per-attempt tables for the N>1
> protocol are in `docs/implementation-tasks.md` → "Data point 11".

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
`kane-01` and `lfc-01`. The other six manifest tasks now record `SKIP`. **Rows
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

The harness changed mid-corpus, so rows from different weeks were graded by
different harnesses:

- **INFRA-vs-liar split (~2026-09-21).** Non-zero `opencode run` exits used to
  fall through to the writes gate; now they write no row. Pre-fix rows with
  `opencodeExit != 0` are the six legacy node3 rows below.
- **`qwen3:14b` `limit.output` 4096 → 8192 (~2026-09-21/22).** Pre-fix 14b rows
  truncate inside the reasoning block (next section). **No post-fix truncation
  has been observed.**
- **`typecheck` boolean → tri-state (~2026-09-21/22).** See above.
- **opencode version (added 2026-09-30).** The result JSONs stamp it:
  1.18.31 on 54 (with Ollama 0.34.1), 1.18.32 on 138 (including the 9
  hosted-oracle runs), 1.18.33 on 21 (all 2026-09-29), none on 5. The N>1
  protocol's "same config" key (prompt sha, `numCtx`, Ollama version) did not
  include it, so replicates within one cell straddle 1.18.32 and 1.18.33; since
  2026-09-30 the key is prompt sha, `numCtx`, Ollama version **and** opencode
  version (`docs/adversarial-review-2026-09-29.md` §7), and rows before that are
  re-cut by the stamped version. opencode installs patch releases by itself when
  a TUI starts (never from `opencode run`), which fits the version taking three
  values in ten days; the config template now sets `autoupdate` to `"notify"`.
- **Test environment (added 2026-10-03).** Until then a gate ran under whatever
  environment the harness process held, and nothing recorded which. `asohav-02`
  showed the cost: a model-written test that imports the real `repo.ts` imports
  `pgPool.ts`, which throws at import unless `DATABASE_URL` is set. The models'
  own vitest runs hit that error on 2026-09-27 and never on 09-29, so the
  variable was set by then; the two `qwen3.6` passes of 09-29 (`...221825`,
  `...223027`) load only where it is set (replayed clean: suite gate FAIL), and
  no other replayable `asohav-02` row's suite verdict depends on it. The manifest
  now pins it (`testEnv`: `DATABASE_URL` unset for `asohav-02`, `MANAPOOL_API_KEY`
  unset for `lfc-02`) for the test command and for the model's own shell, and the
  run JSON records `testEnv`. Rows before 2026-10-03 have no such field. The
  "same config" key stays prompt sha, `numCtx`, Ollama version and opencode
  version, plus the test environment where one is recorded.
- **Desktop keep-alive 5m → 4h (2026-10-03, ~12:50 local).** `OLLAMA_KEEP_ALIVE`
  is a User env var from then on (it was Ollama's 5m default). Gate verdicts do
  not depend on it — a run's requests are back to back — so it is not in the
  "same config" key. Wall-clock fields (`elapsedSec`, timeouts) are: a run that
  started after more than 5 idle minutes used to pay a reload of its seat
  (about a minute for `qwen3.6`) plus a full prefill, and now usually does not.
  Do not compare durations across this date without that caveat.
- **Serving engine (recorded from 2026-10-03).** Every row so far was served by
  Ollama, which the owner plans to replace. Run JSONs now carry an
  engine-neutral `servingEngine` block (`name`, `version`, `endpoint`,
  `provider`) beside the Ollama-shaped `ollamaVersion`, which is kept so older
  files still compare; rows before 2026-10-03 have no block and are all
  `ollama`. A different engine is a new era: it changes the chat template
  path, the tool-call parsing and how an over-long prompt is handled (Ollama
  truncates silently; see "Prompt truncated by Ollama"), so the "same config"
  key gains the engine name and version. The truncation check is
  Ollama-specific; under any other engine a run records `promptTruncation` as
  "not checked", never as a clean, until that engine gets its own detector.

Consequence for selection: **no desktop qwen3 row exists from 2026-09-22 on,
and every challenger row is from 2026-09-23.** Any incumbent-vs-challenger
comparison spans all three fixes. The challengers' lead is large enough to
survive that caveat, but a same-harness rematch of the incumbents is still
owed before any seat decision cites the gap.

> **Correction (2026-09-30).** The rematch has run. Every `qwen3:14b` and
> `qwen3:8b` × task cell has a graded row or a `_TIMEOUT_` transcript from
> 2026-09-26/28 (DP7, DP9), plus `qwen3:14b` on the frontier cells on
> 2026-09-29 (DP11), on Ollama 0.34.3 with the current harness. What is still
> confounded is context (the dense pair is at 32k, the six challengers at 64k)
> and, since 2026-09-29, opencode 1.18.32 vs 1.18.33.

What the tasks measure: every manifest prompt names the file, the function,
and the buggy line shape (`tests/tasks/manifest.json`). This is **guided
repair** — "apply this precise fix plus a test that depends on it" — not
autonomous debugging ("find the bug"). Pass@1 here does not transfer to
unscoped work; it transfers to the work-order executor role in
`docs/target-setup.md`.

## Not every row is a run

**7 of the 102 rows measured nothing about a model** (6 legacy + 1
hand-recorded). They are kept as evidence, but they are not attempts and must
not be counted as failures. Truncated rows (below) are exit-0 attempts that
never acted — exclude them from capability denominators too.

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
anyone re-read the transcripts. **node3's liar-mode denominator from this
batch is 0.** See the corrected roadmap entry,
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
`reason: "length"` and usage `output` of exactly **4096** — the old configured
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
attempt.

`ollama-desktop/qwen3:14b` `limit.output` is now 8192. **Pre-cap rows cannot
be compared against seats that rarely reach the cap.** The honest 14b read is
2 full passes in 12 real attempts (19 rows minus these 7).

### Zero writes after the fix — genuine liar mode, not truncation

Post-2026-09-22 exit-0 `writes=0` rows are real prose-only answers under the
8192 cap, not budget artifacts. The extreme case is `ollama-node3/lfm2.5:8b`:
**8/8 runs, zero writes, exit 0 every time** — it PASSes the `write_file`
canary (`tests/test-toolcalls.ps1`) and then answers every task in prose.
Probe PASS does not predict task-loop writing; `lfm2.5:8b` is the cleanest
demonstration in this corpus. (`ornith:9b` shows the same shape 3×;
`qwen3.5:9b`, `qwen3.6:35b-a3b-coding`, `nemotron-3.5-lightning` and
`north-mini-code-1.0` each show it once.)

> **Correction (2026-09-30).** The heading does not hold for every seat here.
> Classify by the transcript, not by `writes=0`: of the 31 exit-0 zero-write
> rows since 2026-09-22, **8 end in an empty step cut off by the output cap**
> (the last `step_finish` has `reason: "length"`, `output` exactly the seat's
> configured `limit.output` and `reasoning: 0`, with no text or tool event in
> that step; a run JSON written after the 2026-09-30 harness change records
> `outputCapHit`, and older ones are classified from the transcript as here).
> By seat: `nemotron-3.5-lightning` 4 of 6, `ornith:9b` 3 of 4
> (all three of its "same shape" rows), `qwen3:8b` 1 of 1. The other 23 end in
> `stop` and are genuine prose-only answers: `lfm2.5:8b` 8 of 8,
> `north-mini-code-1.0` 5 of 5, `devstral:24b` 3 of 3, `qwen3.6` 3 of 3,
> `qwen3.5:9b` 1 of 1. "Under the 8192 cap" holds only for `qwen3:14b` and
> `qwen3.6`; every other tool-capable seat is at 4096. Those 8 rows are cap
> artifacts of the configuration, not evidence about the seat. The harness's
> writes gate (`test-tasks.ps1`, "the model described the change instead of
> making it") mislabeled them until 2026-09-30; it now reports a cap hit
> separately (`tests/test-cap-hit.ps1`). Rows are unchanged: the graded row and
> its FAIL stand, and only the reading of `writes = 0` differs.

### Prompt truncated by Ollama — 4 rows (2026-10-03)

`opencodeExit=0`, `writes=0`, one step, no tool call, and a prose answer that
pastes code ("Here are the three files updated…"). They read as liar mode and
the writes gate labelled them so. They are not: Ollama logged
`truncating input prompt limit=32770 prompt=83886 keep=4 new=32770` (asohav-05)
and `prompt=83122` (asohav-06) at the start of each run, and the transcript's
first step reports exactly 32,770 input tokens. At those two tasks' pins the
asohav repo's `CLAUDE.md` is 281,225 and 278,549 bytes (16–56 KB at the
neighbouring pins); OpenCode puts it in every request, so the first request
was ~83k tokens against `qwen3.6`'s 65,536. Ollama kept the first 4 tokens and
the tail, which drops the system prompt, the tool schemas and the task. **No
64k seat can be measured on these two tasks as pinned.**

| timestamp | task | seat |
|---|---|---|
| `2026-10-03T16:45:34` | `asohav-05-library-write-validation` | `ollama-desktop/qwen3.6:35b-a3b-coding` |
| `2026-10-03T16:49:56` | `asohav-06-bond-cap-setting` | `ollama-desktop/qwen3.6:35b-a3b-coding` |
| `2026-10-03T17:29:36` | `asohav-05-library-write-validation` | `ollama-desktop/qwen3.6:35b-a3b-coding` |
| `2026-10-03T17:33:53` | `asohav-06-bond-cap-setting` | `ollama-desktop/qwen3.6:35b-a3b-coding` |

Exclude them from every denominator. Both tasks are retired in the manifest
since 2026-10-03 (`retired`, owner decision; `docs/roadmap.md` → "Task set
expansion II" has the way back), so no new rows will join these. Since
2026-10-03 `test-tasks.ps1` reads
the local Ollama log for each run's window (`Get-OllamaPromptTruncation`) and
turns a hit into a FAILed run with a `_TRUNCATED_` transcript and no row; each
graded run JSON records the check in `promptTruncation` (`tests/test-prompt-truncation.ps1`).
Only a local Ollama is checked; a node3 or server run records "not checked".
Before that date the check did not exist, so an older exit-0, zero-write,
one-step row against a large repo is worth a look at the Ollama log before it
is counted as liar mode.

Not this class: the same day's `kane-07` and `kane-08` re-runs (17:20:25,
17:27:16) were never truncated (input peaked at 61,114 and 49,943). `kane-07`
read `signals.ts` and its test (~31k tokens) twice, OpenCode compacted the
session, and after the summary the model wrote a plan instead of the change;
`kane-08` lost the task at 46,576 tokens and asked what it should do. Those
rows stand as genuine failures of the seat at long context. *2026-10-04, the
mechanism for `kane-08`: its request before that step was ~69k tokens against
65,536, so Ollama dropped the oldest messages, the task prompt with them,
logging only at debug level (`docs/roadmap.md` → "Context overflow"). The row
still stands: this is what the seat and client do in a real session. Run JSONs
since then record it in `contextEvents.frontDrops`.*

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

### Ungraded transcripts with no row — 31 `_INFRA_`/`_ABORTED_` files, plus reconstructed timeouts

Non-zero `opencode run` exits since the INFRA fix: transcript kept, no TSV
row, by design. 27 are node3-unreachable (`Cannot connect to API`,
including the 09-21 mid-batch outage and the 09-22 sleep flap), 1 is the
deliberate WRONGURL preflight check, 2 are `kane-02` context overflow
into OpenCode compaction on the desktop (2026-09-23, diagnosed in
`docs/implementation-tasks.md` → "Gap-fill batch review": the model filled
32k, then compaction failed — `north-mini-code-1.0` with `Tool call not
allowed while generating summary: read`, `qwen3.5:9b` with an Ollama 500
Jinja `No user query found in messages` inside `multi_step_tool`). Both
reached the model (real `read` calls first) and both are infrastructure, not
capability — and `-OnlyMissing` will retry them. *Corrected 2026-10-04 for
the `qwen3.5:9b` one, and for all six of its later crashes: no compaction was
involved. A request went over `num_ctx` and Ollama dropped the oldest
messages, the task prompt first, and that model's template refused a
conversation with no user message. Other seats lose their task silently in
the same spot, so it is a capability limit of the seat and client, not
infrastructure, and it still counts against the seat in attempt totals
(`docs/roadmap.md` → "Context overflow").* The 31st is an
`_ABORTED_` transcript (`lfc-02` × `ollama-node3/qwen3:8b`,
2026-09-23 18:37): the lane was **killed by a human from another session**
at ~25 min into its 30-min cap, so it is not a timeout and proves nothing
about node3 — the exit `-1` is a kill, not a cap. It carries no row so the
`asohav`-style cells are unaffected. Distinguish the tags: `_INFRA_` = the
harness or host failed, `_ABORTED_` = a human stopped it.

**Timeout counts are reconstructed; timeout transcripts are lost.** No
`_TIMEOUT_` transcript exists on disk: `Invoke-OpencodeRun` writes the job's
output with `$events | Out-File` only after `opencode run` returns, so
`Stop-Job` on timeout leaves nothing for the "partial transcript kept" branch
to rescue (streaming the output inside the job is the recorded fix). Attempt
counts were reconstructed from row gaps and the Ollama server log instead —
per-seat timeouts in the "Gap-fill batch review" (laguna 5,
devstral-small-2 7, north-mini 5, nemotron 4, qwen3.6 2, qwen3.5 1, ministral
3). Timeouts are the largest failure class for the 18–25 GB offloading seats
under the default 900 s cap: their true capability is unmeasured, not low.
Treat every graded-only ratio above as conditional on finishing inside the
run cap, and use the per-attempt table for selection.

**Timeouts keep their transcripts from 2026-09-26 on** (`_TIMEOUT_*.jsonl`,
the events up to the cap; the earliest on disk is `lfc-03` × `devstral-small-2`,
2026-09-26 16:14), so the paragraph above holds for earlier batches only; for
later ones count timeouts from those files (noted 2026-10-04). The 2026-10-03/04
light-seat batch added 2 more `_INFRA_` files of the `qwen3.5:9b` template
error above (`kane-08` at 49.8k tokens, `asohav-08` at 54.1k). That error
recurs on long contexts, so for `qwen3.5:9b` read it as a property of the
seat, not as infrastructure, even though it carries no row (`docs/roadmap.md`
→ "Task set expansion II", the light-seat overnight).

## Gradable coverage

95 graded rows (exit 0, including the 7 truncated). Against the N=10-per-cell
policy (`docs/roadmap.md`): every cell is under N, most at 1–2 — the policy is
a target for the winners-first rematch, not a description of this corpus.
Cells are `full-pass / graded-n`, grouped by `model` (legacy `modelLabel`
variants — `qwen3-8b`, `qwen3-14b-rerun`, `desktop-qwen3-*` — are merged into
their model; group by `model`, not `modelLabel`):

| task | desktop seats (full/n) | node3 seats (full/n) |
|---|---|---|
| `kane-01-background-pair` | 14b 1/11, 8b 0/10, nemotron 1/1, qwen3.5 1/1, qwen3.6 0/1, devstral 0/1 | lfm2.5 0/1, ministral 0/1, node3-8b 0/2, ornith 0/1 |
| `lfc-01-listing-status-guard` | 14b 1/8, 8b 0/8, laguna 1/1, nemotron 1/1, qwen3.5 1/1, qwen3.6 1/1 | lfm2.5 0/1, ministral 0/1, node3-8b 0/1, ornith 0/1 |
| `kane-02-multiword-creature-type` | qwen3.6 0/1 | lfm2.5 0/1, ministral 0/1, node3-8b 0/3, ornith 0/1 |
| `kane-03-saga-chapter-triggers` | 8b 0/2, qwen3.5 1/1, qwen3.6 0/1 | lfm2.5 0/1, ministral 0/1, node3-8b 0/1, ornith 0/1 |
| `kane-04-singleton-up-to-n` | 8b 0/2, devstral-small-2 1/1, laguna 1/1, nemotron 1/1, north-mini 1/1, qwen3.5 1/1, qwen3.6 1/1 | node3-8b 1/1, lfm2.5 0/1, ministral 0/1, ornith 1/1 |
| `asohav-01-library-write-reporting` | 8b 1/1, nemotron 0/1, qwen3.6 1/1 | node3-8b 0/2, lfm2.5 0/1, ornith 0/1 |
| `asohav-02-changelog-uuid-id` | 8b 0/3, north-mini 0/1, qwen3.5 0/1, qwen3.6 0/1 | node3-8b 0/2, lfm2.5 0/1, ministral 0/1 |
| `lfc-02-scryfall-headers` | 8b 0/2, laguna 1/1, qwen3.5 1/1, qwen3.6 1/1 | lfm2.5 0/1, ministral 0/1, ornith 0/1 |

All eight manifest tasks have graded data now (previously two). `kane-04` is
the easiest cell in the corpus (9/15 full-pass across seats); `kane-02` and
`asohav-02` are the hardest (0 passes on 6 and 10 graded runs respectively).

## Decision-test files (2026-09-29, DP10)

- **`north-mini-code-1.0-32k` rows** are north-mini on its own weights with
  `num_ctx 32768`. The tag was a temporary derived model, registered for that
  run through `OPENCODE_CONFIG_CONTENT` and removed afterward, so it is in
  neither `opencode.jsonc` nor `run-tasks-models.tsv`. Group these rows with
  `north-mini-code-1.0` and split by `numCtx`, not by model id.
- **`reliability-summary.tsv`** holds write-discipline canary results: the
  prompt and pass rule of `test-profiles.ps1 -Reliability`, run from a scratch
  script on seats no live profile seats yet. PASS is `writes = 1` and
  `fileOk = True`. `sec` is wall clock per `opencode run`, including any
  model load.

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
