# Methodology research — sanity check & community guidance

Recorded 2026-09-24 from the sanity-check review of where the fleet stands and
whether it is moving toward *first real use* fast enough. Not a plan change —
the ordered plan in [implementation-tasks.md](implementation-tasks.md) →
"Next steps" stays as agreed. This page is the reasoning written down, plus the
community resources that map to the gaps this repo has already *measured*, so
the links survive the session.

Every external claim is cited; the full catalog lives in
[references.md](references.md), and the citation convention is enforced in
`AGENTS.md`. **Leaderboard and "best model" figures move weekly — re-verify
anything environment-shaped (Ollama version, model releases, harness versions)
before acting on it.**

## Verdict

The methodology is sound and the direction is right; the bottleneck is no
longer knowledge, it is execution of step 5 (the blind trial).

- **The core loop matches the field standard.** Guided-repair tasks → mechanical
  gates (scope / suite / failsOnOld / typecheck) → per-attempt grading →
  winners-first → blind trial. SWE-bench grades the same way: apply the patch,
  run the real suite, binary resolved/not-resolved. The self-corrections that
  cost real work to learn (INFRA-vs-liar split, the `qwen3:14b` output-cap
  truncation, per-attempt timeout reconstruction, the "6/6 liar mode" debunk)
  are the things published evals usually get away with hand-waving.
- **Winners-first was the right call.** The 8-candidate gap-fill batch answered
  the selection question on thin samples; more candidate cells now would be
  measurement churn, not signal. The compute budget belongs to the blind trial
  and the control rematch (to *close* the era confound, not extend it).
- **The catalog is essentially community-optimal for this hardware.** The
  16 GB sweet spot in 2026 is the 30B-A3B MoE class already seated
  (`qwen3.6:35b-a3b-coding` ≈ 73.4% SWE-bench Verified on current leaderboards —
  near dense-27B without needing its 24–32 GB). Dense 27B models (75–77%) do
  **not** fit either 16 GB card or node3's 10 GB; `qwen3.5:9b` on 10 GB is the
  right node3 pick. Do not spend compute proving that a model you cannot deploy
  is better.

## The two accelerators for "sooner rather than later"

1. **Spend the hosted/frontier calibration key now, not "unscheduled."** It is
   the cheapest uncommitted de-risking capital in the repo (~cents per run) and
   does three things at once:
   - catches task-design bugs in the exact tooling the blind trial builds on;
   - gives the corpus the one oracle-level upper bound it lacks;
   - produces the first genuine successful trajectory — which is the precise
     gate the node3 Unsloth fine-tuning track is waiting on (imitation learning
     needs an example of *correct* behavior; the benchmark has produced zero
     so far).
2. **Run the edit-format A/B alongside the blind trial, not after first use.**
   This repo's own loudest single finding is sitting on the shelf: whole-file
   `write` is 8/8 in the 2026-09-22 corpus, substring `edit` is 11% (85/783),
   with 79% of misses targeting code that isn't in the file. Edit-format choice
   is the one variable named in every community dataset from the last six months
   (SWE-Edit, aider, the QCoda bake-off below), and the phantom-edit loop is the
   largest *controllable* failure class in this corpus. It is a prompt change;
   it costs an afternoon; it may move the winning seat's pass rate more than any
   model swap the fleet could make.

## What community data says about the measured gaps

### Edit reliability — the 11% `edit` and phantom-edit loop

[*SWE-Edit*](https://arxiv.org/html/2604.26102) (Microsoft, 2026-05) is the
closest thing to a canonical treatment: it measures that the edit interface
"conflates inspection, planning and execution in one context window," that
find-replace is brittle (exact string match; a single whitespace mismatch
fails), and that the fix is to separate *what the agent sees*, *what it
decides*, and *how edits are executed* — a Viewer + Editor split with clean
context windows (+2.1 pp resolve, −17.9% inference cost on SWE-bench Verified).
Its strongest result for this fleet: edit-format *selection* is a learnable
skill — a GRPO-trained Qwen3-8B editor matches GPT-5-nano, and an adaptive
find-replace-vs-whole-file policy beats any single fixed format. PR-Edit
(the companion eval) is cheap to borrow as a gate.

Caveat from this repo's own data: only 0.3% of `edit` misses were whitespace
near-misses, so *fuzzy matching alone* fixes almost nothing here. The 79%
hallucinated-oldString class is the phantom-edit loop, and points at
read-before-edit (below) and whole-file mode, not at a better matcher.

### Whole-file vs search-replace — both directions are real

The direction of the win depends on the seat and the load:

- Aider's [edit formats](https://aider.chat/docs/more/edit-formats.html) and
  [unified-diffs analysis](https://aider.chat/docs/unified-diffs.html): high-level
  hunks + *flexible application* cut editing errors ~9x; the "blame the model"
  failure (eliding large sections, "… original code here …") is mostly an
  edit-format artifact. Apply-side flexibility (normalize indentation, re-diff
  minus/plus lines, break hunks) is directly transferable to a smarter
  `oldString` applier in `test-tasks.ps1`.
- The [QCoda engine×model bake-off](https://qcoda.com/blog/engine-model-bakeoff)
  (2026-06) found `aider:whole` 0/10 where `aider:diff` went 10/10 *on the same
  qwen3-coder:30b* — under real context load (specs + project ledger in the
  window) a 30B model cannot re-emit a 195-line file, drops the task, and exits
  cleanly. That is the caution for whole-file mode: it wins for *small, freshly
  read* files and loses under context load for larger files.
- SWE-Edit reconciles the two: find-replace for localized changes, whole-file
  for restructuring, decided per task — the policy can even be taught to a 8B.

A third, independent data point: [metaharness's ADR-127](https://github.com/ruvnet/metaharness/blob/4db1c8f8/docs/adrs/ADR-127-darwin-searchreplace-patch-primitive.md)
measures the same whole-file-vs-search-replace split and lands the same
conclusion — whole-file is reliable on small files and regresses `PASS_TO_PASS`
on large ones (a full rewrite changes more than intended); exact-block
search/replace fixes the large-file case with no collateral damage.

Transfer to this fleet: tasks are capped at ~2 files / ~300 lines and the
prompt hands over the file,function,bug — whole-file mode is the plausible
static default for this harness, but the QCoda and ADR-127 results say it is a
real A/B, not a slam dunk. It belongs on the milestone that already plans it
(milestone 2 "harness fixes as A/B tests"), and ideally alongside the blind
trial.

### Harness round-trip weight — the offloader timeouts

Same bake-off names the mechanism behind this corpus's largest failure class:
opencode's read-edit-verify-lint cycle on a local 30B on commodity hardware
"runs out of runway before it finishes" (timed out at 1200 s). Low-round-trip
engines (aider:diff, pi) win on local hardware — 21 s on qwen2.5-coder:32b vs a
timeout. This is the external argument for milestone 3 (acceptance-test-supplied
mode, source-only edits → fewer round trips) and for treating
[`aider:diff` / `pi`](https://qcoda.com/blog/engine-model-bakeoff) as the
eventual executor-harness upgrade if the current loop stays slow after the
format fix. The 900→1800 s cap raise already done is the other half of the
same lever.

### Context management — the kane-02 compaction failures and planner stall

[*Building AI Coding Agents for the Terminal*](https://arxiv.org/html/2603.05344v1)
(2026-03) catalogs exactly the two failure shapes seen here: instructions
decaying over long sessions (the "brief user message injected at the decision
point" — system reminders — is the mechanism that fixes it), and tool results
crowding the context window (compaction / scratch-file offload with agent-aware
recovery hints). The planner mission-line + re-read bans already encode the same
class of fix; reminders are the piece not yet borrowed.

### Planner / executor split

The decomposition adopted here (strong model plans and writes the acceptance
test; the executor only implements source; mechanical gates grade) is the same
shape the field converged on: read-only-Planner-schema patterns and SWE-Edit's
Viewer/Editor split. The measured reason it matters is milestone 3's own claim —
it removes `failsOnOld`, the gate this fleet's seats miss most.

### Model fits

On current hardware the answer is "keep the lineup": `qwen3.6:35b-a3b` for
planning (A3B MoE is the community's local-agent sweet spot at 16 GB),
`qwen3.5:9b` as the default executor, node3 getting a Q4 `qwen3.5:9b` trial.
Cross-checks: [ModelFit local-vs-cloud SWE-bench](https://modelfit.io/benchmark/)
(35B-A3B ≈ 73%, dense 27B ≈ 75–77% on 32 GB+, both behind frontier APIs) and the
[SWE-bench Verified leaderboard](https://www.swebench.com/) itself. Anything
"bigger" (dense 27B, 122B-A10B) physically needs the server's 16 GB + system-RAM
offload or hardware that does not exist yet; gate it on the server POSTing and
a measured probe, not on a leaderboard.

## Recommendations (ranked)

1. Run step 5 (blind trial) — it is the milestone.
2. Spend the hosted calibration key now (de-risk the harness + unlock the
   fine-tuning gate).
3. A/B the edit format on the winner (whole-file vs search-replace, read-before-
   edit) *alongside* step 5, not after milestone 5 lands.
4. Do the 10-minute step-8 sub-fix now (honest "Summary appended" message /
   kill vs cap tags); defer the `_TIMEOUT_`-transcript and version-stamp work
   until they block analysis — they do not block first use.
5. Do not add model candidates. Spend remaining compute on the control rematch
   and the raised-cap reruns already queued.

## References

Every source for the claims above is catalogued with URL, author/lab, and date
in [references.md](references.md).