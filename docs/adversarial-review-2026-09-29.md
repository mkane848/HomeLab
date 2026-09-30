# Adversarial review of testing methodology (2026-09-29)

Scope: `tests/test-toolcalls.ps1`, `tests/test-profiles.ps1`,
`tests/test-tasks.ps1` + `tests/run-tasks-batch.ps1`, the review-gate R3
protocol (`docs/review-gate/reviewer.md`, `docs/review-gate/raw/r3-results.md`),
the 64k context trial (`docs/roadmap.md` → "Context budget"), and the
planner/executor process (`docs/target-setup.md`,
`docs/implementation-tasks.md`).

Verdict: the corpus is unusually honest (INFRA-vs-liar split, era confound,
truncated rows, hollow-pass audits are all written down), but almost every
seat decision since 2026-09-23 rests on **N=1 per cell, across harness/Ollama
eras, on guided-repair prompts that do not measure the north star**
(plain-language planning + execution). Nothing below blocks the N>1 protocol
in §7 — that protocol is the fix for findings 3b–3d.

## 1. `test-toolcalls.ps1` — necessary, not sufficient, over-claimed as gate

- **N=1, one tool, one phrasing.** Single `write_file` call, single prompt
  (`tests/test-toolcalls.ps1:61`). No repeats, no seed/temperature control,
  no `read`/`edit`/`bash` coverage. Binary PASS/FAIL from one sample.
- **Proven insufficient by this repo's own data.** `lfm2.5:8b` probe-PASSes
  in seconds then goes 0/8 zero-write in the real loop; `ornith:9b`,
  `qwen3.5:9b`, `qwen3.6`, `nemotron-3.5-lightning`, `north-mini-code-1.0`
  each show the same shape at least once
  (`tests/results/README.md:162-171`). "Probe PASS does not predict
  task-loop writing" is documented and the probe is still the seating gate.
- **Crude filter, untested residency path.** `SKIP_PATTERN` matches
  substrings, not model kinds (`test-toolcalls.ps1:49`). `keep_alive 0`
  vs loaded-resident eviction behavior is never probed.
- **"Only qwen3 calls tools" rests on 13 models × 1 Ollama version**
  (`tests/results/toolcalls-0.34.1.txt`) on one backend, plus one
  `qwen3:8b`/`glm4:9b` node3 spot-check. `glm4:9b` FAIL is N=1.
  Template-vs-weights root cause is plausible, not isolated.

## 2. `test-profiles.ps1` — checks the config against itself

- Intent manifest + registration check verifies the profile resolves, not
  that the seat is right. `opencode debug config` proving `limit` survived
  only proves no schema typo.
- `-RoundTrip` capability probe (toy python function / arithmetic / Q&A)
  has no construct validity vs 2-file guided repair, let alone planning.
- `-Reliability` canary is one prompt (`docs/_scratch.md`, `writes == 1`).
  DP10 ran it 3/3 outside the harness because neither candidate is seated
  (`docs/implementation-tasks.md:1160-1184`). N=3 on one prompt cannot
  separate 66% from 100% — `qwen3:14b` went 2/3 in the same session.

## 3. `test-tasks.ps1` — best harness here, still load-bearing holes

(a) **Measures guided repair, not the north star.** Every prompt names
file, function, bug shape (`tests/tasks/manifest.json`).
`tests/results/README.md:88-93` admits this transfers to the work-order
executor role, not autonomous debugging or loose prompts — yet
`docs/roadmap.md:221-278` uses 2/9 vs 8/9 here to argue for re-seating the
interactive main seat. DP4 already showed the gap: `qwen3:14b` fixed
source correctly and FAILed for never writing tests
(`docs/implementation-tasks.md:728-766`).

(b) **N=1, winners-first on noise.** Step-6 standings (`qwen3.6` 8/9,
`qwen3.5` 7/9, `laguna`/`qwen3-coder` 6/9) are N=1 per cell. A 1-pass gap
at N=9 is luck. No CIs, no significance, no pre-registered decision
threshold. 2026-09-29 TSV count: most task×model cells sit at 1–2 graded
rows; only `kane-01`/`lfc-01` × `qwen3:8b`/`qwen3:14b` have depth (8–12,
mostly pre-fix eras).

(c) **Era confound, control owed.** Corpus spans the INFRA split, the
`limit.output` 4096→8192 fix, typecheck boolean→tri-state, and Ollama
0.34.1→0.34.3. `tests/results/README.md:69-86` states no desktop-qwen3
row exists post-move while every challenger row is post-move. The control
rematch has been owed since 2026-09-23 and was still open when 64k was
adopted and north-mini dropped.

(d) **Timeouts are the largest failure class and the least measured.**
Timeout → no row by design; transcript streaming landed (`bbf06db`,
empty-transcript + UTF-8 follow-ups in DP7), but per-attempt counts are
still reconstructed from row gaps + server log — post-hoc and fragile.
Graded-only pass@1 conditions on finishing, flattering slow offloaders.

(e) **`failsOnOld` is manual, not mechanical.** Any red after `stash push`
of source passes — including import crashes. The audit is human
(`docs/implementation-tasks.md:387-398`). DP9: 3 of 26 passes met the
gate while covering less than the prompt asked
(`docs/implementation-tasks.md:1020-1034`). The PR #82 trap is narrowed,
not closed.

(f) **Contamination + difficulty skew unaddressed.** Tasks mined from real
merged fixes; no training-data membership check, no holdout. Oracle
`qwen3.8-max` 9/9 could be recall. Difficulty dominates seat variance:
`kane-04` ~9/15, `kane-02`/`asohav-02` ~0 — the benchmark is 2 easy + 2
near-impossible + middle, unstratified.

(g) **Documented footguns still structural.** Task-id-keyed worktree +
install marker (`test-tasks.ps1:212-300`, `:623`) caused the 2026-09-23
lane collision + orphaned runs; fix (key by task+model) deferred.
`pnpm exec tsc` hardcoded for npm tasks (`lfc-01` WARNs) still open.
Pre-trial `typecheck: PASS` rows mean "never ran" on 6 of 8 tasks
(`tests/results/README.md:17-22`) — old comparisons are invalid and every
parser must tolerate `SKIP`/`n/a`/`NOT_RUN`.

## 4. Review-gate R3 — strong internal, zero external, closed too early

18 runs, 3 families, one defect pair (seam 5+6). 1/9 vs 0/9 treatment vs
control is a floor effect — underpowered for anything but a huge effect.
"No local model holds the reviewer seat" generalizes from one plan to all
review; the limit is stated (`docs/roadmap.md:290-294`) and the seat then
closed as "settled." The deterministic checker is FIRST-RUN-SAFE vs
RED-MARK on one plan: a regression test, not a reviewer.

## 5. Context/VRAM — single-sample decisions

- 64k adoption on 15 vs 18 attempts, N=1 per cell, same 3 tasks in order,
  no randomization. Cost table is one short `generate` per cell with <15%
  dismissed as noise by fiat. "Overflow didn't turn into timeouts" on N=18
  is not a finding — and the standings table confounds seat × context
  (32k seats are exactly the dense qwen3 pair), noted as caveat, ranked
  anyway.
- VRAM: catalog disk GB vs runtime GB confusion recurs (`glm4` ~6GB,
  reviewer ~9 vs ~10.5GB). Node3 usable VRAM still unmeasured. Desktop
  figures date from 0.34.0, not re-measured post-0.34.1/0.34.3.
  Co-residency 12.34 vs 13.29GB contradiction open — fit verdicts cite
  disputed numbers.

## 6. Process — planner loop is structurally contradictory

DP1 (wrong repo) → DP2 (edits live checkout, skips interview, ships
untestable tests) → DP3 (Plan mode fixes live-edit but makes the
failing-first worktree verification physically impossible: needs a write,
Plan denies it). Resolution — owner authors acceptance tests by hand —
means the "planner writes test, test must fail first" loop is
human-powered, while the starting build still seats `qwen3.6` as planner.
"Winners-first, miss = wrong job" is unfalsifiable: any miss is role-fit,
never evidence against the lineup.

## 7. Fix first: N>1 protocol (no seat decisions until it reports)

**Rule.** No re-seat, drop, or context change cites a gap smaller than
what N≥3 per cell on the same prompt sha, same `numCtx`, same Ollama
version can support. Timeouts and `_INFRA_`/`_CONTEXT_`/`_ABORTED_`
transcripts count as attempts — report per-attempt, never graded-only.

**Minimal viable batch (overnight, desktop only).** Frontier tasks where
the standings hinge × top-2 challengers + control, 2 fresh reps each on
top of the 1 DP8/DP9 row per cell:

- Tasks: `lfc-03-status-transition-guard`, `kane-02-multiword-creature-type`,
  `asohav-02-changelog-uuid-id`
- Seats: `ollama-desktop/qwen3.6:35b-a3b-coding`,
  `ollama-desktop/qwen3.5:9b`, `ollama-desktop/qwen3:14b` (control)
- 3 tasks × 3 seats × 2 reps = 18 runs, `-RunTimeout 1800`, plain prompts
  (no `-EditFormat`), **without** `-OnlyMissing` (that flag skips cells
  that already have a row — the opposite of N>1).

Preconditions (from DP7/DP9 lessons): close memory-heavy apps, check free
RAM, record `ollama --version` + `/api/version` + `opencode --version`
from the batch header, confirm `numCtx` stamps 65536 / 32768 as designed.

Suggested invocation (interactive picker still asks; prefer explicit
params + `-Yes` for a clean log):

```powershell
.\tests\run-tasks-batch.ps1 -SkipSetup -Mode Tasks `
  -Tasks lfc-03-status-transition-guard,kane-02-multiword-creature-type,asohav-02-changelog-uuid-id `
  -Models ollama-desktop/qwen3.6:35b-a3b-coding,ollama-desktop/qwen3.5:9b,ollama-desktop/qwen3:14b `
  -Reps 2 -RunTimeout 1800 -Yes
```

**DoD.** Every listed cell reaches ≥3 same-config graded-or-ungraded
attempts (rows + `_TIMEOUT_`/`_INFRA_`/`_CONTEXT_` transcripts); report
is a per-attempt table (PASS / FAIL-by-gate / timeout / infra), not a
graded-only ratio; `tasks-summary.tsv` rows + transcripts committed
verbatim per `CONTRIBUTING.md`; standings in `docs/roadmap.md` not edited
until the table lands. `devstral-small-2:24b` ×5 and the node3 Q4
`qwen3.5:9b` trial stay queued behind this batch.

## Addendum (2026-09-30): what the N>1 data and a recheck change

The §7 protocol ran (PRs #62–#64; per-attempt tables in
`docs/implementation-tasks.md` → "Data point 11"). Checked against the raw rows,
five statements in this review need correcting; the rest stands.

- **§3(c), "control rematch owed"**: it had already run. DP7 and DP9 cover every
  `qwen3:14b` and `qwen3:8b` × task cell on Ollama 0.34.3 (DP9: "the control
  lane's DoD is met"). What is still confounded is 32k vs 64k, and now opencode
  1.18.32 vs 1.18.33.
- **§3(f), "`kane-04` ~9/15, `kane-02`/`asohav-02` ~0; 2 easy + 2
  near-impossible"**: those figures are the 2026-09-23 inventory in
  `tests/results/README.md`. In the step-6 window (8 desktop seats) `kane-01` is
  7/8, `kane-04` 6/8, `lfc-01` 5/8, `kane-02` 4/8 and `asohav-02` 2/8, and at
  N=3 `qwen3.6` passes `kane-02` 3/3 and `asohav-02` 2/3. Difficulty moved with
  the seat set and the config; the suite now saturates at the top, not at the
  bottom.
- **§1, the liar-mode list** (`ornith:9b`, `nemotron-3.5-lightning`, …, citing
  `tests/results/README.md:162-171`): most of `ornith`'s and `nemotron`'s
  zero-write rows are output-cap hits, not liar mode (correction in that README).
- **§3(b), N=1 on noise**: confirmed, and stronger than stated. `qwen3.5:9b`'s
  step-6 7/9 was regression to the mean: at N≥3 on the same config it is 13/21
  over all tasks against `qwen3.6`'s 14/15 (Fisher p = 0.051).
- **§7, the protocol itself**: the "same config" key omits the opencode version,
  and replicates in every cell straddle 1.18.32 and 1.18.33. Replicates run
  back-to-back agreed in 11 of 11 pairs; the same cells across batches disagreed
  in 8 of 21 (p = 0.03), so back-to-back reps are not independent evidence.
  Interleave reps across sessions and pin opencode. The control × `kane-02` cell
  also has one attempt, not the required three.
