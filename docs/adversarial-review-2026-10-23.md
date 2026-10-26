# Adversarial review: milestone 3 and the road into milestone 4 (2026-10-23)

An independent review of milestone 3's write-up (PR #153, first version) before milestone 4 is built on it, in the
spirit of [adversarial-review-2026-09-29.md](adversarial-review-2026-09-29.md). Written by a Claude Sonnet subagent with
read-only access to the run JSONs, the harness and the docs; then checked by the main session (below) and folded into
[roadmap.md](roadmap.md#after-the-trial) → "After the trial" items 3, 6 and 10 and [target-setup.md](target-setup.md) milestones 3
and 4. The review text is kept as written; where the docs now differ from the first version, it is because of it.


Method: I recomputed every number from the run JSONs (`gates.scope/suite`, `acceptance.status`, `acceptanceShown.tampered`, `elapsedSec`, `usage.output`, `timestamp`) in `llamacpp-sealed-hidden`, `-shown`, `-shown-fixed`, `real02-host-*`, `sealed-c3-node3`, and the private `desktopgpu-shown*` folders. The headline counts reproduce exactly (hidden 40/45, corrected shown 44/45). The conclusions drawn from them do not all hold.

## Findings, ranked by how much they change a conclusion

### 1. The "corrected" shown arm discards genuine failures. Verdict: weakened (the 98% is a best-case number)
Commit c4e4f4c changed only the suite gate (`$shownInBase`, `test-tasks.ps1:2248`). The tamper check (`Remove-ShownAcceptance`, byte compare) and the acceptance gate were not touched, so the bugged rows' tamper and acceptance results are valid evidence about the model.
- `llamacpp-sealed-shown` (bugged rows) holds 3 tampers: `wp-5a` 2 of 3 (`scope FAIL`, `campaign.test.ts (edited)`), `wp-5b` 1 of 3 (`bond.test.ts (edited)`, and that run also has `acceptance FAIL`, a real shown failure). All 3 sit in the discarded rows.
- Add the one tamper in `-shown-fixed` (`wp-0a`). On the 4 affected tasks, the llama.cpp shown arm has 4 genuine failures in 24 runs (17%). Pooled with the 33 unaffected runs (all passed): 53 of 57 (93%), not 44 of 45.
- Desktop: the bugged `desktopgpu-shown` rows hold 2 tampers (`wp-0a`, `wp-5a`) and 2 `wp-5b` acceptance FAILs. So desktop `wp-5b` shown is 1 pass in 4 attempts (2 acceptance FAIL, 1 PASS, 1 timeout), not part of a "28 of 28".
- The tamper rate is the headline risk for milestone 4 (about 1 run in 6 on the tasks where a given file replaces an existing test), and the write-up reports it as "the single failure".
- Fix: report all valid-for-scope runs, or re-grade the bugged rows for scope and acceptance and mark only their suite gate void. State the pooled number (93%) beside 98%.

### 2. The 89% to 98% gap is not established. Verdict: weakened
- Task-level contrast: 3 tasks favour shown (`wp-5b`, `real-02`, `real-03`), 1 favours hidden (`wp-0a`). Exact sign test two-sided p = 0.62.
- Run-level exact test is invalid (runs cluster by task). A within-task permutation test gives one-sided p = 0.08 with `wp-5b`, p = 0.50 without it (shown minus hidden = +1 run of 42).
- Without `wp-5b`: hidden 40 of 42 (95%), shown 41 of 42 (98%). Hidden failures other than `wp-5b` are 2 runs.
- Ceiling: 12 of 15 tasks were 3 of 3 in both arms. The whole effect is 4 tasks.
- Using the pooled 93% from finding 1, the gap over hidden is about 4 points on 57 vs 45 runs, which is noise.
- Wording: "the given test lifts the executor" becomes "the given test may help; on 15 tasks the contrast is `wp-5b` plus two 1-run flips, p about 0.08 at best".

### 3. `wp-5b` is one task, and the hidden failures carry a mix of causes. Verdict: holds, narrowly
- Shown `wp-5b` acceptance: llama.cpp 5 of 6 over all rows (the 22:34 bugged row failed), desktop 1 of 3 graded plus a timeout. Hidden: 0 of 3 here. It is real, but small and not unanimous.
- Hidden `wp-5b` failures include `finishReason: length` (1474 s, 71,642 output tokens) and two `suite FAIL` rows, so those are not all "failed after real work".

### 4. Circularity: the shown test is the grader plus the spec. Verdict: unsupported as evidence about milestone 5
- `acceptance PASS` in the shown arm is the same file that was shown, so the dispatcher's selector is perfect by construction (roadmap item 6 admits this).
- The worse inflation is leakage of requirements. `real-01/02/03` are documentation tasks. A test over a doc encodes the spec the prompt does not state, so a shown test supplies information, not only a stopping gate. The two hidden failures I read were of this kind: `real-03` wrote one file with two URLs in 3 steps and 28 s, and `real-02` edited a file in 7 steps and 124 s. Both are short, prose-final and not blocked by a tool.
- A fair proxy is a held-out second test set: have a planner (or the owner) write tests from the prompt alone, grade each shown run on both the planner's tests and the original hidden tests, and report their disagreement. The old selector false-positive rate is the quantity milestone 4 needs.
- The 2026-09-29 review's item 6 (the "planner writes a failing test" loop is human-powered) is still open. Milestone 3 skipped it by using the oracle.

### 5. Cost and "why it helps". Verdict: partly story-telling
- "203 s vs 187 s, 27% more output" are medians of pooled runs with 15 different task scales. Paired by task: median time ratio 1.05, median output ratio 1.09, shown slower on 10 of 15 tasks. Totals: +10.6% elapsed. Outliers drive the means (`wp-3b` ×2.2, `real-01` output ×3.9, offset by `wp-3a`/`wp-5a` ×0.8). Compactions are 24 vs 19 total (the doc's 16 vs 13 counts runs). Say "about 5 to 10% more per task, noisy".
- "Stops early 'done'" rests on 2 transcripts. It is plausible, and I confirmed the shape, but n=2 with no counterfactual. "The target gives direction on `wp-5b`" is one task. Both are hypotheses, not mechanisms.
- "Nudges equal (2 vs 2)" holds but is trivial.

### 6. Confounds. Verdict: mostly fine, one real one
- Alternation (H 15:15, S 16:35, H, S, H, S) is sound for 11 tasks. The 4 corrected tasks ran 22:40 to 00:21, after the pairs, with no concurrent hidden arm. Server load or thermal drift is small but uncontrolled, and these are the tasks that carry the effect.
- Stacked changes (llama.cpp, sealed, classifier 3, plugin, assisted) are held constant between arms, so they do not bias the contrast. They do mean no comparison with earlier rounds is clean.
- Fix: re-run hidden for the 4 tasks after the pairs, or label them as unpaired.

### 7. Exclusions. Verdict: weakened
- Desktop timeouts were `wp-7a` and `wp-5b`, the two hardest. "28 of 28 graded" is conditional on finishing. Counting them as fails (and the bugged `wp-5b` rows) it is 28 of 30 at best.
- Sealed Ollama `wp-5b` timeout (35 of 44) is excluded the same way. Without it 35 of 45.
- "76% vs 80% within the spread" is fine as stated, since single rounds spread 9 to 13.

### 8. "Host does not matter" for `real-02`. Verdict: unsupported
- 1/8 (desktop) vs 1/5 (server) cannot distinguish 12% from 40%. Pooled with the earlier 3/9 vs 1/16: desktop 4/17 vs server 2/21, still inconclusive. Say "not distinguished".
- Same task: llama.cpp hidden 2/3, shown 3/3, Ollama `sealed-c3-node3` 0/3. The engine lead is also n=3.

### 9. Task set. Verdict: a caveat, not a refutation
- 15 tasks, 3 documentation tasks and about 12 from 2 or 3 repos. Passes are saturated on 12. Representative of the owner's TypeScript work, not of new features, other languages or ambiguous prompts.

## Heading into milestone 4: change, then go

Verdict: change the design claim, keep the sequential-retry direction, and add one experiment before building.

- "~1.02 attempts per task" is a ceiling-case estimate. Use a first-attempt pass rate of about 93%, and for the four tamper-prone tasks about 83%. That gives about 1.08 attempts per task with an oracle selector, which is still cheap. The estimate is meaningless once the selector is a real planner's test.
- Failures are correlated within a task (the same 3 to 4 tasks fail repeatedly; `wp-5b` hidden 0 of 6 across prior and present rounds, with tamper recurring on `wp-5a`/`wp-0a`). Retrying `wp-5b`-like tasks with the same prompt buys little. If the tamper rate is task-bound, a retry needs a changed condition (the given file read-only, or a "do not edit tests" restatement), not a fresh sample.
- Selector false positives: a planner's test can pass while the change is wrong; the review step is the only guard. The cap should be 2 or 3, because pass^k data shows most failures are persistent.
- Parallel before sequential? Not yet. Only wall-clock favours it, and the doc is right that it burns compute at 93%.

### First experiments (in order)
1. Re-grade bugged shown rows for scope and acceptance; publish pooled shown vs hidden with all rows. Stopping rule: if pooled shown is within 5 points of hidden, retire the "lift" claim.
2. Planner-written tests: one planner pass per task from the prompt alone, a test that must fail on base, then shown runs graded by both the planner's test and the original hidden test. Metrics: selector false-positive and false-negative rates, first-attempt pass. Stop and redesign if false positives exceed 10%.
3. Tamper control: same shown arm with the given files made read-only, or restated, on `wp-0a`/`wp-5a`/`wp-5b`, 5 reps each. Stop if the tamper rate is still above 10%.
4. Hidden re-run of the 4 corrected tasks alongside the shown re-run (paired, same hours) to remove the time confound.
5. Record attempts, rejection reasons, total time and tokens for the retry loop, as item 6 already says. Falsifier for the design: a mean attempts per task above 1.5, or a cap-hit rate above 15%.

## What to stop claiming
- "98% vs 89%" as a measured lift, "every task passed at least once" as evidence the shown test selects, "the single failure", "28 of 28", "host does not matter", "27% more output", "1.02 attempts per task".

## What to keep
- The harness fix, the tamper check (it caught real behaviour), the sealed checkouts, and the sequential-retry shape.

## Checked by the main session (2026-10-23)

Recomputed from the same run JSONs, with the bugged rows' suite gate voided (a pass needs acceptance and scope):

| | runs | passed |
|---|---|---|
| node3 hidden, the 3 rounds | 45 | 40 (89%) |
| node3 shown, the 3 rounds (time-matched) | 45 | 42 (93%) |
| node3 shown, plus the 12 re-runs | 57 | 53 (93%), 4 tampers |
| desktop GPU hidden (classifier-3 round) | 25 | 22 (88%) |
| desktop GPU shown, plus its re-runs | 36 | 32 (89%), 2 tampers |

- Findings 1, 2 (the sign test over the 4 differing tasks, two-sided p = 0.625), 7 and 8 hold as stated.
- One assumption in the re-grade: a bugged run whose only failing gate was the suite counts as a pass. The bug
  explains that failure, but the suite output is not kept in the JSON to confirm it run by run.

## What the research says about it

Sources already catalogued in [references.md](references.md), re-read 2026-10-23:

- **Tampering:** the [Reward Hacking Benchmark](https://arxiv.org/abs/2605.02964) reports that "simple environmental
  hardening reduces exploit rates by 5.7 percentage points (87.7% relative) without degrading task success", that
  models "with near-zero rates on standard tasks show elevated rates on harder variants", and that 72% of
  reward-hacking episodes carry an explicit rationale. [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)
  relied on "strongly-worded instructions" ("It is unacceptable to remove or edit tests"); this harness's prompt
  already says as much, and 4 of 57 shown runs still edited a given test. So: harden (read-only given files) rather
  than re-word, and read the tamper transcripts, since the rationale is usually stated.
- **Small gaps:** [Quantifying infrastructure noise](https://www.anthropic.com/engineering/infrastructure-noise) says
  "leaderboard differences below 3 percentage points deserve skepticism", notes that "naive binomial confidence
  intervals already span 1-2 percentage points" on a far larger benchmark, and recommends running "at multiple times
  and on multiple days". At 45 runs an arm, a 4-point gap is noise, and the 4 re-run tasks need hidden runs in the
  same hours.
- **Saturation and selection:** [Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents):
  regression evals "should have a nearly 100% pass rate", capability evals "should start at a low pass rate", and
  "an eval at 100% tracks regressions but provides no signal for improvement"; "pass@k for tools where one success
  matters, pass^k for agents where consistency is essential"; trials "are not independent because they're affected
  by the same factor"; "Make your graders resistant to bypasses or hacks."
- **Realistic prompts:** [Saving SWE-Bench](https://arxiv.org/html/2510.08996v2) finds real developer queries are
  "10-30 words" and that benchmarks "significantly overestimate agent capabilities for some models" once tasks are
  rewritten that way (Sonnet 4 on Multi-SWE-Bench TypeScript, 15.6% → 7.2%). The planner-test experiment should start
  from the owner's own short prompts.
- **Not covered by any catalogued source:** how often a planner's own tests accept wrong code (the selector's
  false-positive rate). That is measured here first, or found in new reading before experiment 3.

## Addendum (2026-10-24): what the tampering was

The main session read every edit to a given test in the 8 tampering runs (roadmap → "After the trial" item 10). Each of
the 4 tasks' own prompt tells the model to change its given test file (rename a test in `party.test.ts`, add tests to
`bond.test.ts`, and so on), and `-ShowAcceptance` appends "Do not edit, move or delete these test files". The model
followed the task: 6 runs added tests or assertions, 2 removed a stale comment, 1 rewrote assertions while debugging;
none weakened a test to pass broken code. So finding 1's tamper rate is mostly an instruction conflict in the harness,
not reward hacking, and experiment 3 of "First experiments" (the read-only control) is replaced as the first step by a
shown-mode prompt that reconciles those instructions, with read-only files as the fallback.
