# tests/results — how to read this directory

Raw output from `tests/test-tasks.ps1` (the task-veracity benchmark). Per run:
a graded `.json`, the raw `.jsonl` opencode transcript, and one appended row in
`tasks-summary.tsv`.

Everything here is committed **verbatim and ungraded** per `CONTRIBUTING.md` —
grading happens separately, against the key, by someone who did not generate the
runs. This file is that separate pass for the full corpus, re-inventoried
2026-09-23 at 107 rows (was 43 rows / 1 pass).

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

Consequence for selection: **no desktop qwen3 row exists from 2026-09-22 on,
and every challenger row is from 2026-09-23.** Any incumbent-vs-challenger
comparison spans all three fixes. The challengers' lead is large enough to
survive that caveat, but a same-harness rematch of the incumbents is still
owed before any seat decision cites the gap.

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
capability — and `-OnlyMissing` will retry them. The 31st is an
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

## Re-deriving this

Nothing here is hand-maintained state; the raw files are the source of truth.
The classification is `opencodeExit != 0` → never reached the model,
`reason:"length"` with `writes=0` under the 4096 cap → truncated,
missing `.jsonl` → no transcript, `writes=0` with exit 0 under the 8192 cap →
genuine liar mode. Group seats by `model`, not `modelLabel`. Note that a
`.jsonl` filename's timestamp can differ from its TSV row's by a second or
two — match with a tolerance, not equality.
