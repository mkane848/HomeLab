# Roadmap

Ordered backlog for the hybrid LLM fleet. Items are TODOs, not commitments.

## Next up (ordered, as of 2026-09-23)

The rest of this file is the full backlog by theme. This is the short list of
what to actually pick up next, highest value first.

> **Status (2026-09-30).** This is the 2026-09-23 plan, kept as written. Since
> then: the control rematch (item 2a) has run, `qwen3.5:9b` is at N≥3 on six of
> nine tasks (2b), the frontier-cell N>1 protocol has run (DP11), and item 3 is
> done. Items 1 and 4–8 are unchanged. The current standings are under
> "Executor standings" below.

1. **Close the KaneEnabler validator holes** under the fix-and-reverify gate —
   Background-pairing eligibility bug, direct `legality_commander` check on
   named commanders, singleton paper-rule, `banned`/`notFound` dedupe, and the
   seeded-DB proof of the 100-card assertion. Task list in
   [implementation-tasks.md](implementation-tasks.md) §C; method in
   [review-gate/testing.md](review-gate/testing.md). **The only open item with
   real correctness value** — everything else here is hygiene or research. Each
   fix must ship a test that *fails on the old code*. Different repo, so it
   needs a machine with that checkout.
2. **Executor selection, winners-first (supersedes the 2026-09-21 breadth
    plan in the same item).** The 2026-09-23 gap-fill batch put first task
    data on all 8 executor candidates (`docs/implementation-tasks.md` →
    "Gap-fill batch review" for the per-attempt table and the non-hollow
    audit; `tests/results/README.md` for the corpus inventory). The strategy
    the fleet owner chose 2026-09-23: pick winners per role on thin samples,
    then do more testing once a working setup lands — so the N=10-per-cell
    backfill and the 16-task expansion both wait until after first real use.
    A miss is read as "wrong job for this model", and the scoreboard keeps
    role-fit columns (timeout rate, writes-per-pass, failsOnOld-miss rate),
    not just pass@1. Next runs, in order: (a) **control** — `qwen3:14b` /
    `qwen3:8b` rematch on Ollama 0.34.3, owed before the jump is credited to
    the new models rather than the version move; (b) **`qwen3.5:9b` to N=3**
    on every task, plus a Q4 copy on node3 (only strong seat small enough for
    10 GB); (c) raised-`-RunTimeout` re-runs for the offloading seats via
    `-OnlyMissing`; (d) the unfinished `qwen3-coder:30b-a3b` ×8. What the
    tasks measure is **guided repair** (each prompt names file, function, and
    bug shape), which transfers to the work-order executor role — not
    autonomous debugging. The hosted/frontier-model calibration arm stays
    unscheduled; the OpenCode Go key is available whenever the owner wants
    to spend it.
3. **~~Onboard the third node (RTX 3080 FE)~~ — done 2026-09-20.** Join →
   probe → validate all complete (see "Onboarding the third node" below):
   `qwen3:8b` is a real, measured agent seat on this host, `test-profiles.ps1
   -Profile dev-node3` is green. **Done since: the node3 breadth leg ran in
   the 2026-09-23 gap-fill batch** (19 node3 runs with evidence), the sleep
   flap was root-caused to Windows sleep, and the small candidates are
   measured: `ornith:9b` passes only the easiest task (1/6), `lfm2.5:8b`
   (0/8, all zero-write) and `ministral-3:8b` (0/5) are not executors — see
   the "Gap-fill batch review" grading pass. Node3's next job is overflow
   worker duty plus a Q4 `qwen3.5:9b` trial, not more small-candidate
   batches.
   Unsloth is installed there for a later, explicitly gated fine-tuning
   track — still not part of this item.
4. **Settle the desktop Ollama auto-update.** `desktop/scripts/pin-ollama-desktop.ps1`
   exists to prevent exactly the 0.34.0 → 0.34.1 move that happened anyway on
   2026-09-19. Find out whether the firewall rule was ever applied or whether it
   failed — the two need different fixes. Five minutes, and it is the one open
   item that can silently break agent seats.
5. **Probe the server when it POSTs.** It has *never* run
   `tests/test-toolcalls.ps1` — it went down before that test existed — and its
   image pin was bumped to `0.34.1` on 2026-09-19 to match the desktop. Nothing
   on that host should be seated until it is probed. The four post-upgrade
   checks are below under "Post-server-upgrade validation".
6. **Reconcile the VRAM figures that disagree** (see "Known contradictions"
   below). Two of them change real decisions and neither can be settled without
   a measurement.
7. **Rewrite `model-architecture.md`.** It predates the tool-calling finding and
   now carries a staleness banner; it still seats models that cannot call tools
   and never mentions `qwen3:14b`. Either bring it current or fold it into
   `profiles.md` + `hardware.md` and delete it.
8. **Review-gate leftovers, low priority.** The seat question is closed (see
   "Review-gate: settled" below). What remains is optional: a hosted arm (the
   only untried thing that could change the answer — unscheduled, OpenCode Go
   key available),
   Arm C (the de-leaked prompt), and a seam-6 brittleness probe for the
   deterministic checker — the fixture built for that on 2026-09-19 tested the
   wrong thing, so the question is still open. None of these block anything.

### Known contradictions (need a measurement, not an edit)

Written down rather than guessed at. Each is a number that appears twice in
these docs with two different values:

- **`qwen2.5-coder:3b` runtime VRAM** — 1.31 GB (`start-here.md`), 2.26 GB
  (`profiles.md`, `roadmap.md`, `troubleshooting.md`), "1.3–2.3 GB"
  (`hardware.md`). Both larger figures are labelled measured. This gives the
  flagship co-resident pair two different totals (12.34 vs 13.29 GB) and
  *opposite* verdicts on whether it survives while gaming.
- **`deepseek-r1:14b` resident VRAM** — ~9 GB (`vscode.md` §4) vs
  ~10.5 GB @16k (same file, seat-assignment table). The node3 fit argument
  turns on which is right.
- **node3 usable VRAM is unmeasured.** `vscode.md`'s "10 GB usable
  ~9 GB, per `hardware.md`" attribution was removed 2026-09-20 (hardware.md
  states no such figure — its only "usable" number is the desktop's ~14.8 of
  16 GB). To-do: with nothing loaded on node3, record free VRAM from
  `/api/ps` into `docs/hardware.md`, the same way the desktop's 14.8 GB was
  established. Until then, no node3 fit verdict should cite a usable figure.
- **Harness pass count** — ~~docs say 81 PASS (`start-here.md`, `profiles.md`);
  commit `41a457d` reports 85 PASS and 88 with `-Reliability`~~ — resolved
  2026-09-20: re-ran `tests/test-profiles.ps1` across all four live profiles
  (node3 now live) → **100 PASS, 0 FAIL, 1 WARN, 2 SKIP**, and every doc
  claiming 81 PASS now says so (`start-here.md`, `profiles.md`,
  `CONTRIBUTING.md`, `profiles/parked/README.md`). The 1 WARN is the known
  node3 `hosts`-column false positive; the 2 SKIP taps are the dead server.
- **VRAM figures generally** still date from Ollama 0.34.0 and were not
  re-measured after the 0.34.1 move. Not expected to shift, but not verified.
- **Server `glm4:9b` `tool_call: true` is unprobed.** The only measurement is
  the node3 FAIL (2026-09-20, ignored the tool, answered in prose); the server
  copy has been down since before `test-toolcalls.ps1` existed. To-do: when
  the server POSTs, run `.\tests\test-toolcalls.ps1 -Model glm4:9b -OllamaHost
  http://SERVER_IP:11434` and flip the server-block entry to `false` if it
  fails the same way (expected — same weights, same CUDA backend). Recorded
  in `opencode/global/opencode.jsonc`'s server-block comment; see also
  "Post-server-upgrade validation" below.
- **Node3 WARN false positive needs a harness fix.** `test-profiles.ps1`
  expands `DEV_NODE3_MODELS="general embed"` by catalog group membership
  without checking the `hosts` column, so it WARNs on `qwen3:14b` (deliberately
  unregistered on node3 — tight on 10 GB) and `gpt-oss:20b` (never
  node3-eligible). To-do: respect `hosts` when computing per-host install
  intent. Do not pull either model onto node3 to silence the WARN in the
  meantime.

### Context budget: 32k vs 64k per seat (measured and trialled 2026-09-27; adopted for six seats by merging the trial PR)

Why it came up: DP7's four context-overflow deaths (`docs/implementation-tasks.md`).
With a ~14.8k-token first request and `limit.output` 4096 reserved, a 32k seat
has room for roughly one large source file before OpenCode compacts, and the
compaction step is where those runs died. Owner is interested in 64k; this is
the measurement to decide it on, per seat.

Method: desktop, Ollama 0.34.3, Vulkan, flash attention + q8_0 KV; each model
loaded alone on an empty GPU via `/api/generate` with `options.num_ctx` =
32768 then 65536, a ~1.2k-token prompt, 64 output tokens; sizes from
`/api/ps`, allocations from the Ollama server log. **Generation speed is one
short sample per cell** — treat differences under ~15% as noise.

| seat | trained ctx | KV @32k → @64k | on CPU @32k → @64k | gen tok/s @32k → @64k | verdict |
|---|---|---|---|---|---|
| `qwen3:8b` | 40,960 | 2.4 → 3.1 GB (capped at 40k) | 0 → 0 | 86 → 85 | **cannot reach 64k** |
| `qwen3:14b` | 40,960 | 2.7 → 3.4 GB (capped at 40k) | 0 → 0 | 51 → 51 | **cannot reach 64k** |
| `qwen3.5:9b` | 262,144 | 0.5 → 1.1 GB | 0 → 0 | 56 → 59 | free |
| `qwen3.6:35b-a3b-coding` | 262,144 | 0.4 → 0.7 GB | 8.2 → 8.6 GB | 67 → 68 | free |
| `north-mini-code-1.0` | 500,000 | 0.6 → 1.1 GB (SWA) | 4.1 → 4.5 GB | 47 → 48 | free |
| `nemotron-3.5-lightning` | 1,048,576 | 0.1 → 0.3 GB (7 attention layers) | 11.4 → 11.5 GB | 41 → 36 | ~free |
| `laguna-xs-2.1` | 393,216 | 0.7 → 1.4 GB | 5.9 → 6.5 GB | 50 → 41 | small cost |
| `qwen3-coder:30b-a3b` | 262,144 | 1.6 → 3.3 GB | 5.1 → 6.8 GB | 40 → 36 | moderate cost |
| `devstral-small-2:24b` | 131,072 | 2.7 → 5.4 GB (1.4 of it on CPU) | 3.9 → 6.6 GB; 36 → 31 of 41 layers on GPU | 13.5 → 9.6 | **expensive** |
| `devstral:24b` | 131,072 | 2.7 → 5.4 GB | 2.4 → 4.9 GB | 16.4 → 10.4 | **expensive** |

Reading it:

- **Hybrid/SWA/MoE seats barely notice.** Few full-attention layers (qwen3.5/3.6
  every 4th, nemotron 7 of 53, north-mini/laguna sliding-window) means small KV.
  Doubling it costs well under 1 GB, taken from GPU weight space, not added RAM.
- **Dense 24B seats pay twice.** Every layer carries KV, so +2.7 GB, which
  pushes 5 more layers onto the CPU: ~30–37% slower generation and ~2.7 GB
  more system RAM — the resource that ran out under Firefox on 2026-09-26.
- **`qwen3:8b`/`qwen3:14b` top out at 40,960.** Ollama logs `requested
  context size too large for model` and silently loads 40k. 40k is cheap
  (+0.6 GB, fully on GPU); 64k would need RoPE/YaRN scaling in a derived
  model — an untested change to the default seat, not a config bump.
- **Not measured here — time.** A bigger window means later turns carry more
  prompt. The offloaders prefilled at ~150–350 tok/s on this short prompt; a
  50k-token re-prefill at that rate is roughly Ollama's 5-minute no-output
  cancel, and the SWA seats (north-mini, laguna) re-prefill from zero on any
  cache miss (the 2026-09-26 retry loop). An estimate, not a measurement: the
  real test is the rerun below.
- **Two halves of one contract.** A change is `startup.ps1` `$contextModels`
  (the baked `num_ctx`) *and* `opencode.jsonc` `limit.context` for the same
  seat, confirmed with `opencode debug config` (see AGENTS.md → Gotchas).

Proposed trial (not adopted): 64k for `qwen3.5:9b`, `qwen3.6`, `north-mini`,
`nemotron`, `laguna` (and `qwen3-coder` if its speed cost is acceptable);
40k for `qwen3:8b`/`qwen3:14b`; `devstral` pair stays 32k. Acceptance: rerun
DP7's four context-overflow cells plus the three frontier tasks for the raised
seats, and compare timeouts and pass rate against DP7 — a bigger window that
converts overflow into timeouts is not a win.

**Trial configured 2026-09-27 (branch `feat/context-64k-trial`):** 65536 for
`qwen3.5:9b`, `qwen3-coder:30b-a3b`, `north-mini`, `laguna`, `qwen3.6` and
`nemotron` in both `startup.ps1` `$contextModels` and `opencode.jsonc`
`limit.context`; catalog `ctx` updated. `qwen3-coder` is included so the trial
measures its ~11% speed cost instead of guessing at it. **The qwen3 dense pair
stays at 32k for now**, a deviation from the proposal above: none of DP7's
overflow deaths were theirs, 40k buys only ~8k tokens, and `qwen3:14b` is the
daily main seat whose co-residency with the 3b (13.29 → ~13.96 of ~14.8 GB)
and profile docs would all move with it — its own change, if ever. Every run
now stamps `numCtx` (the served `num_ctx`, from `/api/show`) into its result
JSON, because context size is not part of the prompt sha and a 64k row is
otherwise indistinguishable from a 32k one. Revert = restore the 32768s.

**Trial result 2026-09-27 (DP8 in `docs/implementation-tasks.md`): the
acceptance criterion is met.** Same six seats, same three tasks, same prompt
shas, one run per cell, 32k (DP7) → 64k:

| | 32k (DP7) | 64k (DP8) |
|---|---|---|
| attempts | 15 | 18 |
| PASS | 3 (20%) | **9 (50%)** |
| timeouts | 3 | 1 |
| context deaths (`_INFRA_`) | 3 | 1 |

- **Overflow did not turn into timeouts** — timeouts went down too. The
  one 64k timeout (laguna, kane-02) compacted cleanly at 61.4k and was
  still working at the cap.
- **The extra room is what the passes used.** 7 of the 9 passes peaked above
  ~28.7k tokens (where a 32k seat compacts); two of them (laguna and qwen3.5
  on asohav-02) compacted once near 62k and still passed.
- **Not fixed by 64k:** `qwen3.5:9b`'s chat template crashes on some compacted
  histories (lfc-03, at 59.4k) — the bug moves later, it does not go away.
  *Corrected 2026-10-04: no compaction was involved. The crash is a context
  overflow; see "Context overflow" below.*
  `north-mini` is 0/3 at 64k for other reasons (no-write, and a mangled
  `/workspace/M:Projects/…` edit path). `nemotron` still writes nothing on
  kane-02.
- **Cost as measured above:** no seat went from fitting to not fitting;
  laguna and qwen3-coder are ~10–20% slower to generate. No run in the trial
  hit Ollama's 5-minute no-output cancel.

N=1 per cell, so per-seat rankings can still move; the direction held on all
three tasks. Decision: keep 64k for the six seats (merging the trial PR
adopts it). The qwen3 dense pair and the devstral pair stay at 32k.

### Executor standings after step 6 (2026-09-29, not yet acted on)

Step 6's 8-seat plan is done: 9 tasks × 8 desktop seats, one graded run or
ungraded transcript per cell (DP7–DP9 in `docs/implementation-tasks.md`). Per
seat, across all 9 tasks:

| seat | ctx | PASS | how it misses |
|---|---|---|---|
| `qwen3.6:35b-a3b-coding` | 64k | **8/9** | one broken test file (asohav-02) |
| `qwen3.5:9b` | 64k | **7/9** | a template crash after compaction (a context overflow, corrected 2026-10-04: "Context overflow" below); one out-of-scope run |
| `laguna-xs-2.1` | 64k | 6/9 | all three misses are 30-minute timeouts on long tasks |
| `qwen3-coder:30b-a3b` | 64k | 6/9 | broken test files; one output-cap crash |
| `nemotron-3.5-lightning` | 64k | 5/9 | writes nothing on three tasks; edited `.env` and `vitest.config.ts` once |
| `qwen3:14b` | 32k | 2/9 | runs out of 32k (compaction), edits out of scope |
| `north-mini-code-1.0` | 64k | 1/9 | invents a `/workspace` repo root; prints tool calls as text |
| `qwen3:8b` | 32k | 0/9 | edits against text it guessed, not the file |

What this means for the north star:

- **The default main seat is near the bottom.** AGENTS.md seats `qwen3:14b`
  ("qwen3 is the boss"), and on real repo tasks it passes 2 of 9. `qwen3.6`
  and `qwen3.5` pass 8 and 7.
  - `qwen3.5` runs entirely on the GPU at 64k (1.1 GB of KV).
  - `qwen3.6` offloads about 8.6 GB to system RAM, but was the fastest seat
    in wall-clock time.
  - `qwen3.6` also waits about 2 minutes before its first reply in every new
    session (1m55s per first request in DP10, model already loaded).
    `qwen3.5` paid that cost once. For an interactive main seat this weighs
    against its one-task lead.
- **The case for re-seating is strong, but it isn't a config bump.** Before
  `OPENCODE_MODEL` moves:
  1. The candidate passes `test-profiles.ps1 -Reliability`, the
     repeated-writes canary that once unseated `qwen3:14b`. **Met
     2026-09-29 (DP10):** both 3/3 on the same prompt and rule, run outside
     `test-profiles.ps1` because neither is seated yet. `qwen3:14b` went 2/3
     in the same session.
  2. It survives a real-use trial on plain-language prompts. The benchmark
     prompts spell out the bug, the files and the test requirements; the
     north star is a prompt written the way the owner talks.
  3. The profile's co-resident small model is re-measured against the new
     seat's footprint.
- **Caveats:**
  - N=1 per cell.
  - The 32k seats are also the dense qwen3 pair, so seat and context are
    confounded in this table. DP8 is the clean context comparison.
  - The gates overstate test quality slightly: 3 of the 26 step-6 passes met
    the fails-on-old gate while covering less than the prompt required (DP9).

Proposed next, owner decision:

- ~~Run the `-Reliability` canary on `qwen3.6` and `qwen3.5`.~~ Done, DP10.
- Drop north-mini as an executor. DP10 found it fails lfc-01 at 32k too, so
  context isn't the fix. That also retires its VS Code path check.
- Do the VS Code cross-checks: north-mini's path, qwen3:8b's edit format,
  nemotron's zero-write runs, and a plain-language kane-03 prompt on
  `qwen3.6`.
- Raise qwen3-coder's `limit.output` to 8192.
- Settle the devstral pair.
- ~~Decide `OLLAMA_KEEP_ALIVE`.~~ Decided 2026-10-03: **4h**, a User env var
  on the desktop. Under the 5m default, `qwen3.6` reloaded four times on the
  morning of 2026-10-01 after idling past 5 minutes, with no eviction
  involved, and each first reply took 2m11s to 3m28s (reload plus a full
  re-prefill; `docs/main-seat-trial.md` → "Second experiment"). 4h covers a
  working day's breaks and still frees the memory overnight; performance
  while gaming is out of scope (owner). `desktop\scripts\opencode.ps1` also
  pre-loads the main seat at launch. Gate verdicts are unaffected; durations
  across the date are not comparable (`tests/results/README.md`).

### Executor standings after the N>1 protocol (2026-09-30)

DP11 (`docs/implementation-tasks.md`) ran the adversarial review's N>1 protocol
on `qwen3.6`, `qwen3.5` and `qwen3:14b`. Counted on the same config: same
prompt sha, the seat's designed `numCtx`, Ollama 0.34.3; timeouts and infra
crashes count as attempts. Wilson 95% intervals in brackets. The step-6 table
above is unchanged for the other five seats (N=1).

| seat | ctx | all 9 tasks | frontier cells (lfc-03, kane-02, asohav-02) |
|---|---|---|---|
| `qwen3.6:35b-a3b-coding` | 64k | **14/15** (0.70–0.99) | 8/9 |
| `qwen3.5:9b` | 64k | 13/21 (0.41–0.79) | 4/9 |
| `qwen3:14b` (default main seat until 2026-10-03) | 32k | 2/13 (0.04–0.42) | 0/7 |

- **The `qwen3.6` lead now holds up.** Against `qwen3.5`: Fisher p = 0.051 over
  all tasks, 0.13 on the frontier cells alone. Against `qwen3:14b`: p = 0.0001
  and 0.0014. The step-6 table's 8/9 against 7/9 could not separate the top two;
  `qwen3.5`'s 7/9 was optimistic (13/21 at N≥3 on the same config, after two
  cells it had passed once failed twice).
- **Caveat on that lead (2026-10-03, `docs/implementation-tasks.md` → DP12
  addendum).** Two of `qwen3.6`'s 14 passes (`asohav-02`, 2026-09-29) load only
  where `DATABASE_URL` is set; replayed on a clean checkout their test file does
  not load and the suite gate fails. Counted that way `qwen3.6` is 12/15
  (0.55–0.93), its lead over `qwen3.5` is Fisher p = 0.30 over all tasks and
  0.64 on the frontier cells (6/9 against 4/9; 4/6 against 2/6 at 1.18.33,
  p = 0.57), and the gap to `qwen3:14b` stays (p = 0.0018; 0.011 on the
  frontier cells). The order is unchanged, so no seat decision moves, but "the
  lead holds up" against `qwen3.5` is not supported on that reading. Which
  reading the benchmark means is the owner's call; the harness now pins the
  variable to unset (`testEnv`), so new `asohav-02` rows measure the clean one.
- **`qwen3.5` misses by breaking the build or by writing a test that passes on
  broken code, not by writing nothing.** Its 8 same-config misses are seven
  graded rows with edits and one infra crash (a template error after
  compaction at 59.4k).
- **The default main seat is 2/13 on the same config** (0/7 on the frontier
  cells). The step-6 case for re-seating stands and is firmer. Its
  preconditions are unchanged: a plain-language trial, and the co-resident
  small model re-measured. `qwen3.6`'s two-minute first-request wait (DP10)
  still counts against it for an interactive seat.
- **What this does not settle.** Five seats are still N=1. The dense pair's 32k
  against the others' 64k is still confounded with seat (nothing tests 40k for
  the qwen3 pair). Replicates straddle opencode 1.18.32 and 1.18.33 (split
  below), and back-to-back replicates agree far more often than the same cells
  across batches (DP11), so they are not independent evidence. `kane-01`, `kane-03`
  and `lfc-01` are still one attempt per seat, and `qwen3:14b` × kane-02 has
  one.
- **The suite now saturates at the top.** `qwen3.6` passes 14 of 15 attempts,
  8 of 9 on the cells that were the hardest. New or differently shaped tasks are
  what keep separating the top seats.

**By opencode version (added 2026-09-30).** The table above pools two versions:
each cell's DP8/DP9 attempt ran on 1.18.32 and its fresh replicates on 1.18.33
(all on 2026-09-29). Cut by version, same tasks, timeouts counted:

| seat | 1.18.32, one attempt per cell | 1.18.33, fresh reps | 1.18.33, the 3 frontier cells |
|---|---|---|---|
| `qwen3.6:35b-a3b-coding` | 8/9 | 6/6 | 6/6 |
| `qwen3.5:9b` | 7/9 | 6/12 | 2/6 |
| `qwen3:14b` | 2/9 | 0/4 | 0/4 (two cells) |

The order is the same on both versions, so no seat decision moves. On the
frontier cells at 1.18.33 alone, `qwen3.6` 6/6 against `qwen3.5` 2/6 is Fisher
p = 0.061, and 4/4 against `qwen3:14b`'s 0/4 on the two cells it ran is p = 0.029
(its `lfc-03` timeout counted). Under a version-strict key every cell has 2
attempts, not the 3 the protocol asks for. The split cannot separate version from
session: `qwen3.5` passed `asohav-01` and `asohav-02` on 1.18.32 and failed both
twice on 1.18.33, and all 8 disagreeing replicate pairs in the corpus are
cross-version (8 of 19), while the 11 back-to-back pairs and the 2 same-version,
different-session pairs all agree. Two pairs is too few to call it. The next
protocol run should pin the version and put a cell's reps in different sessions:
`run-tasks-batch.ps1` now runs reps rep-outer and stops if the version changes,
and the config template sets `autoupdate` to `"notify"` (opencode installs patch
releases by itself when a TUI starts, never from `opencode run`).

Nothing here re-seats a profile or changes a config.

### Review-gate: settled

Closed 2026-09-19, recorded so it is not reopened by accident.

- **No local model holds the reviewer seat.** 18 parameter-recorded runs,
  three families, control vs. a forced per-test ledger. The ledger raised
  output length exactly as designed (median 1229 → 1770 tokens, 9/9 compliance)
  and changed almost nothing: deciding seams caught 1/9 under treatment, 0/9
  under control. One run transcribed the decisive argument correctly into its
  ledger and passed the broken plan anyway. **The bottleneck is verification
  reasoning — not prompt shape, not output budget, not VRAM.** **Scope:** this
  is confirmed on one defect pair (seam 5 + seam 6), replicated 18 times across
  three model families — internal validity is strong, but no different bug
  shape or plan has ever been tried, so generalization past this one plan is
  untested, the same limit the seam-checker bullet below already states.
  → [review-gate/raw/r3-results.md](review-gate/raw/r3-results.md)
- **The deterministic seam-checker discriminates** — given genuinely covered
  seams it returns FIRST-RUN-SAFE, given the original it returns RED-MARK. It
  is sound as a **regression gate on the one plan it was written for**, and is
  not a general reviewer. → [review-gate/raw/r3-robot-results.md](review-gate/raw/r3-robot-results.md)
- **Two claims made during this work were wrong and are corrected in place**:
  the round-2 comparison mis-scored its own draw 2 and inverted the
  majority-of-3 conclusion; and a "ten-character margin" claim about the
  checker's seam-6 regex was computed under a `re.DOTALL` assumption PowerShell
  does not share. Both corrections are recorded rather than silently applied.
- The gate remains **"auditor crafts, human arbitrates."**

## End goal (north star)

Turn every machine in the house into interchangeable compute for **one Claude
Code / ChatGPT Codex-like development experience**: prompt in plain human
language, and the fleet flexibly supplies the models behind that experience.
The profile selects which models run where, OpenCode pins the main seat, and
`tests/test-profiles.ps1` enforces it — you never think about which GPU answers.

Progress gates by hardware, not by preference:

1. **Personal PC (this desktop, RX 6800 XT)** — doing this *today*.
   `dev-workflow-quality` seats `qwen3:14b` (2026-09-17) as the tool-capable
   main seat, the first seat that is both a real conversational agent and a
   coder. Nothing below needs the server.
2. **Ubuntu server (RTX 4070 Ti Super)** — unblocked once it POSTs; the
   profile stream (`profiles/parked/`) is already in place. Server becomes the
   heavyweight node (server-side `qwen3`, reasoners, embeddings) so the desktop
   can stay a conversational seat.
3. **Third node (RTX 3080 FE)** — **live as of 2026-09-20**, ahead of the
   server (stage 2), which still hasn't POSTed. `qwen3:8b` is a measured,
   tool-capable agent seat on this host; see "Onboarding the third node"
   below. Progress here gated by hardware, not by the plan's original
   ordering — node3 came up first.

Each node joins by taking a profile, not by re-learning the workflow. The end
state is a pool: a loose prompt, and whichever hardware is up and fastest
answers it.

**Concrete shape (2026-09-22): [target-setup.md](target-setup.md).** A strong
model plans interactively with you (Claude Code/Codex, or the server's best
local model offline). The fleet executes the approved work orders unattended,
with several attempts across hosts, and the existing gates decide what
passed. That doc also has the machine roles and the ordered milestones.

## Onboarding the third node (RTX 3080 FE, 10 GB / 5950X)

Started 2026-09-20 — the hardware exists now (previously "future"). The catalog,
OpenCode provider (`ollama-node3`), and `dev-node3.sh` profile were already in
place; this is the concrete sequence to actually bring it up, prove it before
trusting it (same standing rule as every other seat in this repo), and put it
to work on the task-veracity benchmark. Unlike the desktop, this card is
**CUDA, not Vulkan** — no `OLLAMA_VULKAN`/flash-attention workaround needed,
Ollama's native NVIDIA backend applies directly.

**Join:**
1. [x] Install Ollama on its Windows machine (native, from ollama.com — CUDA
   auto-detected). Done 2026-09-20.
2. [x] `OLLAMA_HOST=0.0.0.0:11434`, restart Ollama, open Windows Firewall for
   11434 scoped to the LAN subnet (not public). Done — confirmed via
   `netstat -an | findstr 11434` showing `0.0.0.0:11434` listening.
3. [x] Pull the two chat models + two embed models `dev-node3.sh` expects
   (`DEV_NODE3_MODELS="general embed"`): `qwen3:8b`, `glm4:9b`,
   `nomic-embed-text`, `mxbai-embed-large`. Done — confirmed via
   `/api/tags` on the node.
4. [x] Set `NODE3_IP` in `.env` and confirm from the desktop:
   `curl.exe http://<node3-ip>:11434/api/tags` — done, returned all four
   models.

**Prove it before trusting it — do not skip:**
5. [x] `.\tests\test-toolcalls.ps1 -Model qwen3:8b -OllamaHost http://<node3-ip>:11434`.
   **PASS** (2026-09-20, 62.3s, real `write_file` tool call). Confirms the
   qwen3 family's tool-calling holds on this CUDA host too, not just
   Vulkan/desktop — recorded in AGENTS.md's Gotchas.
6. [x] Same for `glm4:9b` — this was the real open question, since its
   `"tool_call": true` config entry had no measurement behind it (didn't
   appear in either the passing or failing side of the 13-model
   `toolcalls-0.34.1.txt` batch). **FAIL** (2026-09-20, 32.8s): ignored the
   tool entirely and answered in prose ("To write the text 'hello' to a
   file..."), same shape as the `qwen2.5-coder`/`deepseek-r1` failures.
   **Corrected `opencode/global/opencode.jsonc`'s `ollama-node3` block to
   `"tool_call": false` for it** — it stays registered as a no-tools chat
   model, same treatment as `qwen2.5-coder:14b`, and must not hold an agent
   seat. `qwen3:8b` remains the only node3 agent seat, matching
   `dev-node3.sh`'s existing `OPENCODE_MODEL` default — no profile change
   needed.
7. [x] `git mv profiles/parked/dev-node3.sh profiles/` once `NODE3_IP` is set
   (per `profiles/parked/README.md`'s own "bringing one back" step). Done.
8. [x] `.\tests\test-profiles.ps1 -Profile dev-node3` — confirms intent
   manifest, tool-capability, and host liveness together, not just that it
   answers a ping. **Done 2026-09-20: 15 PASS, 0 FAIL, 1 WARN, 2 SKIP.**
   The 2 SKIPs are the already-known Ubuntu server outage, unrelated to
   node3. The 1 WARN (`install intent (node3) -> missing on host: qwen3:14b,
   gpt-oss:20b`) is a **false positive**, not a real gap: the harness expands
   `DEV_NODE3_MODELS="general embed"` by catalog tag-group membership only,
   without checking the `hosts` column. `gpt-oss:20b` is
   `hosts=server,desktop` — never node3-eligible at all — and `qwen3:14b`,
   while `hosts=all`, was deliberately left off node3's `opencode.jsonc`
   provider block (only `qwen3:8b` is registered there) because 14B weights
   alone run ~9-9.5 GB, tight on a 10 GB card per `docs/hardware.md`'s VRAM
    table. Same "catalog↔config diff is not automatically a defect" pattern
    AGENTS.md documents (per-host registration gaps and unprobed-only entries
    are usually deliberate — see its Model catalog section).
   **Do not pull either model onto node3 to silence this WARN.** A harness
   fix (respect `hosts` when computing per-host install intent) is a real,
   minor improvement but out of scope here — untouched, no local `pwsh` to
   syntax-check a `test-profiles.ps1` edit against, so it's flagged rather
   than attempted blind.

**Third node onboarding: complete as of 2026-09-20.** Both agent seats
measured for real (`qwen3:8b` PASS, `glm4:9b` FAIL — corrected in config),
network reachable, profile live, `test-profiles.ps1` green modulo the one
documented false-positive above and the pre-existing server outage.
`docs/hardware.md`'s `(future)` tag removed accordingly.

**Put it to work on the task-veracity benchmark:**
9. Once steps 1-8 pass, `tests/test-tasks.ps1 -Model ollama-node3/qwen3:8b`
   works with no code changes — the provider block already exists. This
   turns node3 into real parallel capacity, not just another row in a table:
   the repeat-trial batch from 2026-09-20 (bringing qwen3:8b/14b to ~5 runs
   per task each) can now split across two hosts running concurrently,
   roughly halving the wall-clock cost of collecting the same number of
   trials.

   **Correction (2026-09-21): split the hosts by TASK, not by seat.** This
   step originally said desktop keeps its batch while node3 runs the same
   tasks "at the same time" — that collides. `test-tasks.ps1` keys the
   worktree by task id alone (`$wtPath = Join-Path $wtRoot $tk.id`), as it
   does the install marker, so two concurrent runs of one task id share a
   worktree and corrupt each other. AGENTS.md already states the rule:
   *"different task IDs only, never the same one twice"*. Give each terminal
   its own disjoint set of task ids and let each run both seats — e.g.
   terminal A takes `kane-03` + `kane-04`, terminal B takes `asohav-01` +
   `asohav-02` + `lfc-02`. The wall-clock saving is the same; the collision
   is not.
10. Free bonus check this setup enables: node3's `qwen3:8b` is bit-identical
    weights to desktop's, served over CUDA instead of Vulkan. Any systematic
    difference in graded outcomes between the two hosts would point at a
    backend/quantization artifact rather than the model itself — cheap to
    notice once both are producing rows in `tests/results/tasks-summary.tsv`,
    no dedicated experiment required.

### Third node: fine-tuning with Unsloth (future, unscheduled)

Unsloth was installed on the node3 machine 2026-09-20, ahead of the node
being fully onboarded above. Recorded here so the intent isn't lost, but
explicitly **not started** — the training data now exists (see below); what
it still waits on is a held-out evaluation split.

- **Hardware fit:** Unsloth's 4-bit QLoRA is memory-efficient enough that
  `qwen3:8b` fine-tunes comfortably inside 10 GB. `qwen3:14b` is a real
  stretch on this card — 4-bit base weights alone run ~8-9 GB, leaving thin
  headroom for gradients/activations — so `qwen3:8b` is the realistic local
  fine-tuning target here, not the 14b main seat.
- **Resource conflict, not a hardware limit:** one 10 GB card can't serve
  Ollama inference and run Unsloth training at full tilt simultaneously.
  Default node3 to inference duty (the onboarding above) and treat
  fine-tuning as a scheduled, exclusive-use activity, not a background job
  competing with benchmark runs.
- **The data gate is now open (2026-09-26).** Fine-tuning "on our
  failures" doesn't make sense — imitation learning needs examples of the
  *correct* behavior. When this was written the benchmark had 0/7 graded
  local PASSes on its two tasks; that went stale as the task set grew (22 /
  104 local PASSes across 9 tasks by 2026-09-26). The hosted-calibration arm
  then landed a genuine PASS on **all 9 tasks** (`opencode-go/qwen3.8-max`,
  blind-trial DP5 + DP6 in `docs/implementation-tasks.md`), each with its raw
  transcript in `tests/results/`. That is distillation data: fine-tune local
  `qwen3:8b` on the stronger model's successful trajectories, then re-run it
  through the unmodified harness.
- **The new gate: held-out evaluation.** The 9 oracle trajectories are the 9
  benchmark tasks. Training on them and re-running the same 9 measures
  recall of the answers, not capability. Before any training run, decide
  the split — hold tasks out of training and grade only on those, or author
  fresh tasks for evaluation — and record it here. Nine examples is also a
  small set; the local PASSes (22) are candidate data too, but they are
  weaker-model trajectories and need the same audit the oracle's got.

## GTX 1070 (retired from server)

Decide its fate:
- **Backup card** for the server if the 4070 Ti Super fails, or
- **Second standalone node** (8 GB — only 7–9B `fit` models), adding another `ollama-*` provider + profile.

## Post-server-upgrade validation (do after hardware lands)

- [ ] `nvidia-smi` → confirms `RTX 4070 Ti SUPER 16 GB`.
- [ ] `./server/scripts/status.sh` → GPU section + catalog "installed vs planned" full.
- [ ] Pull the profile's groups and smoke-test a 14B chat + 16k context.
- [ ] Watch `api/ps` VRAM with 7B + 14B loaded (`OLLAMA_MAX_LOADED_MODELS=2`).

## Desktop environment repair (landed 2026-09-17)

- [x] **OpenCode model schema fixed.** `context_window`/`input` were not real
      keys and were silently dropped, so models resolved with no limits and
      OpenCode sent a 46,505-token prompt at a 16k model. Now
      `limit:{context,output}` + `modalities` + `tool_call`. See
      `docs/troubleshooting.md` → "OpenCode request hangs ~5 minutes".
- [x] **Preamble cut 46,505 → 11,441 tokens.** MCP servers moved out of global
      config into per-project `opencode.jsonc`; global skills cut 64 → 8
      (`sync-skills.ps1 -Scope global -Prune`).
- [x] **Per-model context baking** (`startup.ps1 $contextModels`): 32768 for the
      14B coder and the new `deepseek-r1-32k`, 16384 for the rest.
- [x] **Co-residency fixed**: small model is now `qwen2.5-coder:3b` (2.26 GB),
      so the 14B (11.27 GB) is no longer evicted on every title/summary call.
- [x] **Backend settled: Vulkan, permanently.** gfx1030 is unsupported by the
      Windows HIP SDK; `OLLAMA_VULKAN=0` gives CPU-only. Docs corrected.
- [x] **Root-caused why agents never actually edit anything: only the qwen3
      family (`qwen3:8b`/`qwen3:14b`) + `devstral:24b` can call tools.**
      Measured against `/api/chat` with a tool schema on Ollama 0.34.0 —
      `qwen3:8b` and `qwen3:14b` return populated `tool_calls` (devstral:24b
      passes but partially offloads); `qwen2.5-coder:14b`,
      `qwen2.5-coder:3b` and `deepseek-r1:14b`/`-32k` all return empty
      `tool_calls` and print the call as chat text. Not the bake
      (pristine re-pull behaves the same). See `docs/troubleshooting.md`.
      **Re-measured on 0.34.1 (2026-09-19): every result reproduced, each
      failure in the same mode.** Now 5/13 — `qwen3.5:9b` and
      `qwen3-coder:30b-a3b` were first measured then and both pass;
      `deepseek-r1-0528:8b` fails with the rest of its family. Raw output:
      `tests/results/toolcalls-0.34.1.txt`.
- [x] **Seat assignments corrected (2026-09-17, final).** Every seat that
      reads/edits/runs is a qwen3: `dev-workflow-quality` main seat re-seated
      from `qwen3:8b` to `qwen3:14b` for loose-prompt intent handling (the
      14b was briefly seated then reverted over a 6-write slip — re-probed
      and re-seated same day; watch `← Write` lines for repeated calls);
      `opencode/agents/coder.md` and `opencode/commands/implement.md`
      **deleted** (the subagent was pinned to a model that could not call
      tools, so `/implement` silently did nothing). `qwen2.5-coder:14b` is
      retained as a deliberate no-tools model for code text, explanation and
      review. `devstral:24b` passes the probe but is a solo-seat edge fit —
      registered for evaluation, not seated.
- [x] **End-to-end verified**: `opencode run` → qwen3:8b → `← Write
      docs/_write-test.md` → `Wrote file successfully.` The first attempt was
      blocked by `permission.edit: "ask"`, which is correct interactive
      behaviour — non-interactive `opencode run` cannot prompt, so it denies.
- [x] **qwen3:14b re-seat verified end-to-end (2026-09-17).** `opencode run
      --model ollama-desktop/qwen3:14b --auto "Create a file at …"` made
      **exactly one tool call** (`--format json`: `1 tool`, `1 tool_use`, then
      `step_finish`) and wrote the file correctly. The "6-write slip" that
      unseated it on 2026-09-17 did not reappear. Single-Write discipline
      confirmed, matching the `← Write` watch-rule in `docs/troubleshooting.md`.
      Gotcha while probing: an `opencode run … "full sentence"` message passed
      in through PowerShell→bash inline quoting (`& "…\bash.exe" -c '…'`)
      arrived at the model **truncated to its first word** ("Create"), which
      looked exactly like a tool-calling regression. It was quote-mangling, not
      the model — rerun probes via a bash *script file*, as here.
- [x] **Older `dev-*` profiles still seat a non-tool-capable model.** Audited
      2026-09-17 (pre-park `c3bf530^` and HEAD): **already fixed** — every parked
      main seat is `qwen3:8b` (`dev-node3` on both its branches), `dev-local-only`
      is `ollama-desktop/qwen3:8b`, and `dev-full`/`dev-go-only` leave
      `OPENCODE_MODEL` unset by design (GoDefault). The only `qwen2.5-coder`
      reference anywhere is `OPENCODE_SMALL_MODEL` — the title generator, which
      must not have tools. Nothing to repoint.
- [ ] Prefill on Vulkan is the remaining bottleneck (103 tok/s at `FA=1
      KV=q8_0`). Worth revisiting if AMD adds gfx1030 to the Windows HIP table.

## Hardening / experiments

- [x] **Pin the Ollama image** (2026-09-17; pin bumped to `0.34.1` on
      2026-09-19 to match the desktop): `server/docker/docker-compose.yml`
      pins `ollama/ollama:0.34.1`, the version every tool-calling measurement
      in these docs is now taken against. (VRAM figures still date from 0.34.0
      and have not been re-measured — they are not expected to move, but they
      are not re-verified either.) `:latest` was a live risk,
      not just a reproducibility nicety — which models emit parseable tool calls
      depends on the Ollama version and its templates, so an unattended pull
      could silently turn a working agent into one that reports edits it never
      made. **On any version bump, re-run `tests/test-toolcalls.ps1` against the
      host before trusting a seat.**
      - [ ] **The desktop is a native install, not a container, so it is *not*
            pinned by this — and on 2026-09-19 it auto-updated 0.34.0 → 0.34.1,
            exactly as predicted.** `desktop/scripts/pin-ollama-desktop.ps1`
            exists to prevent this (a Windows Firewall outbound block on the
            tray updater, written 2026-09-17 naming v0.34.1 as the bundle
            already staged), but the update happened anyway — so either the
            guard was never applied or it did not hold. **Unresolved: find out
            which.** No markdown file references that script, which points at
            "never applied". The re-probe half of this item *was* done and the
            news was good (every result reproduced on 0.34.1; docs re-baselined,
            server pin bumped to match), so nothing is broken — but the fleet
            is one silent update away from the same question, and next time the
            answer may not be benign.
- [ ] Try CUDA-only tooling on the server that the Vulkan desktop cannot run: vLLM, TensorRT-LLM, CUDA llama.cpp — good candidates for serving a 14B at higher throughput.
- [ ] Bake a higher-context derived model if the 16 384 default is too small for one specific job (`install-model.sh --ctx N` creates `<tag>-Nk`).
- [ ] Add `qwen3-coder` to `models/catalog.tsv` + OpenCode config when it stabilizes in the Ollama library.
- [ ] Re-check `deepseek-r1-16k` on the desktop: with the server now hosting reasoners, the desktop bake may be optional.
- [x] **LM Studio + VS Code review-gate experiment (2026-09-18).** Native VS Code BYOK (`chatLanguageModels.json`) registers LM Studio + desktop Ollama as peer endpoints; the review-gate split (tool-capable auditor → different-family no-tools reviewer → arbiter) caught a destructive remediation step a single qwen3-coder-30b run shipped. Method + measured gotchas recorded in [docs/vscode.md](vscode.md). LM Studio retired 2026-09-27: VS Code now points at desktop Ollama only, same seats and context as OpenCode. Open follow-up: extend to the server seat (`http://SERVER_IP:11434/v1`) when the host is up.
- [x] **Review-gate run 2 — KaneEnabler deck-validity PR (2026-09-18).** The auditor was given a prompt (not hand-primed facts) and a read-only tool loop clamped to the task repo; it self-discovered ~90% of ground truth over 26 turns (unwired `deckLegality`/`colorIdentity` primitives → test conventions → the `(req.body ?? {})` Express-5 guard → fixture corpus) and produced the plan later opened as KaneEnabler PR #82. Findings that changed the method: **(a) reviewer gradient** — R1 de novo (no seam coaching) graded the self-prompted plan FIRST-RUN-SAFE while missing 3 of the 4 seams the hand-primed review passed on, so the tuning lever is the reviewer prompt/seat, not the auditor tool loop; **(b) arbiter corrections** must be folded into the implementation contract (JSON-string `color_identity` decode, deck size counting banned/notFound slots, commander eligibility via `is_commander_eligible` + `buildCommanderUnits`); **(c) the reviewer seat has no clean third node** — see [docs/vscode.md](vscode.md) → "Fleet seat assignment".
- [ ] **Fleet decision: reviewer node gap — reframed 2026-09-19, no longer a VRAM question.** The original framing (third 16 GB node vs. partial-offload R1 on node3 vs. `glm4:9b`) assumed the blocker was fitting a reviewer on a card. Round 3 (18 runs, three models, control vs. forced per-test ledger) shows the seat fails on verification *reasoning*: models transcribe the deciding argument correctly and still pass the plan. A bigger card does not buy that, and `glm4:9b` is weaker than three models that have already failed — its "~6 GB" was catalog disk size, never a measured runtime figure, and it has never been run as a reviewer. **Do not buy or reassign hardware for a local reviewer seat until one exists.** See `docs/review-gate/raw/r3-results.md`. The live options are a hosted gate seat, or the deterministic checker as a regression gate with the human arbiter retained. Note the reviewer VRAM figure itself is inconsistent in the docs (~9 GB at `docs/vscode.md` §4 vs ~10.5 GB in the seat table) — resolve before any sizing decision is revived.
- [ ] **Review-gate run 2 follow-ups** (see [docs/vscode.md](vscode.md) → "Next steps"): (1) close KaneEnabler validator holes — **Background-pairing eligibility bug** (a legal Background pair is rejected: `eligible` demands `is_commander_eligible === 1` on every named commander, but a Background is definitionally 0; fix `usableAsCommander = c => c.is_commander_eligible === 1 || c.is_background === 1`), **direct `legality_commander` ban-list check on named commanders** (today enforced only incidentally when the pasted `list` duplicates the commander line), singleton paper-rule, `banned`/`notFound` dedupe, and prove the 100-card-valid assertion on a seeded DB — **merge gate: fix-and-reverify pass** (audit every new test against its claimed branch; run 2's Background test passed green while never passing the pair). See [docs/review-gate/testing.md](review-gate/testing.md); (2) ~~re-measure the reviewer seat~~ **— done, closed 2026-09-19.** Run to exhaustion in r2 (three candidates, two never drawn) and then settled by round 3: 18 runs, control vs. forced per-test ledger, prompt hash constant within arm, all parameters recorded. No local model holds the seat, and the failure is verification reasoning rather than prompt shape or output budget — confirmed on one defect pair (seam 5 + seam 6) replicated 18 times, not yet tested across a different bug shape. `qwen3.5:9b` produced the corpus's only fully correct review at ~1-in-3 — drafting aid, never the verdict. The "1/4 → ?" metric is retired: it compared an unchecklisted baseline against checklisted runs and measured three changes at once. See `docs/review-gate/raw/r3-results.md`; (3) run the auditor harness on a second non-hand-picked repo; (4) routinize per-run grading on the **four** axes (evidence discipline, plan safety, review quality, test veracity) so runs become a benchmark. Gate is currently "auditor crafts, human arbitrates" — reviewer must earn its seat before this scales past the human arbiter.

### Task-veracity benchmark: Task 2 first graded runs (lfc-01, 2026-09-19/20)

The task-veracity harness (`tests/test-tasks.ps1`) ran `lfc-01-listing-status-guard`
(re-act on a non-active listing: `setStatus` updates by id with no current-status
guard) once per seat on the real `opencode run` tool loop, graded by the four
mechanical gates. Baseline green 21/21 on every run; base commit `4906dc2`.
**0 of 3 seats landed the fix — each failed in a different way**, and none of the
failures is a near-miss:

| Model | Run | Writes | scope | suite | failsOnOld | Failure shape |
|---|---|---|---|---|---|---|
| qwen3:14b | #1 | — | — | — | — | TIMEOUT @900s (no transcript, buffered output lost) |
| qwen3:14b | #2 | 2 | FAIL | PASS⁺ | FAIL | **liar mode**: both `edit` calls errored (multi-match `oldString` in `setStatus`'s shared `where(eq(id,id))`; guessed literal `it('...',…)` anchor that doesn't exist), then it ran vitest, saw the untouched green suite, and *asserted in prose* "the fix has been implemented… two new tests… they pass" — no changes in the worktree. This is the AGENTS.md "coder claims it edited files it never touched" pathology now caught by the harness with a transcript, not by eye. |
| qwen3:8b | #1 | 20 | PASS | FAIL | FAIL | **build-break**: the one model that actually wrote source — but deleted `const db = getDb();` and wrote module-level `await db.select(...)/db.update(...)` into the sync `setStatus` (TS2304 + TS1308 + TS7006; a read-back API that doesn't exist in this better-sqlite3 codebase). Omitting `async` isn't a tweak — the file never parses, so the suite runs **0 tests** (`Failed Suites 1`). Never touched the test file despite 20 write calls. |
| devstral:24b | #1 | — | — | — | — | TIMEOUT @900s |
| devstral:24b | #2 | — | — | — | — | TIMEOUT @1800s |
| devstral:24b | direct | — | — | — | — | **destructive rewrite, then stall**: the out-of-band `opencode run` (stdout → file) *did* write — the worktree proves it. At 23:20 (12 min in, model fully GPU-resident 13.89/15.01 GB) it replaced the 516-line `tests/services/listings.test.ts` with 4 mangled comment lines (`<%/* … */%`, invalid TS — evidence `tasks-lfc-01-listing-status-guard-devstral-24b-direct_ARTIFACT_testfile_…txt`) and then produced nothing flushed for 7.5 h. The `tool_use` events are missing from the transcript only because the force-kill dropped node's buffered stdout — the "one step_start, zero after" file is post-kill-truncated, **not** proof of a pure stall the way it first looked. Two harness runs (900 s and 1800 s) had already timed out; the direct run shows those timeouts hid a 516→4-line test file destruction, not idleness. |

⁺ `suite` was trivially green — nothing had changed.

Evidence already homed in `tests/results/`: per-run `.json` + `.jsonl` transcripts
(qwen3-8b, qwen3-14b-rerun), the devstral post-kill transcript
(`…devstral-24b-direct_STALL_…jsonl`, truncated — see below), and the destroyed
test file preserved verbatim (`…devstral-24b-direct_ARTIFACT_testfile_…txt`). Task 1
(kane-01) graded runs were all FAIL too (14b and 8b x2 and devstral on 2026-09-19,
in `tests/results/tasks-summary.tsv`) — mostly the close-attempts Task 1 had
reported; Task 2's failures are *structural*: edit tools that bounce and a model
that gives up/asserts, a write that can't compile, and a whole-file rewrite that
destroyed 516 test lines before stalling. This is the same
lesson round 3 proved for the reviewer seat, now measured on the **producer**
side of the loop: the blocker is not fit or throughput, it is whether a seat can
land a two-edit change on an unfamiliar repo. No seat change until the existing
gate (≥3 graded runs across ≥2 tasks) is actually satisfied by *something*.

Harness changes made on the way (branch `task2`, uncommitted): the `setup`-array
crash (a task without `setup` iterated `$null` once — `@($Task.setup)`) and the
`Get-FailedTestNames` blind spot that printed an **empty** FAIL for the broken
module (it only matched `FAIL … > test` / `Tests N failed`; suite-level failures
report `Failed Suites N` / `Tests no tests` instead — now captured, gated on
`Failed Suites N`, with the failing file named). Also confirmed, not fixed: the
timeout path keeps **no transcript** — `Stop-Job` kills the job before the
buffered `$events | Out-File` runs (transcript retention only helps finished-but-
uncollected jobs). For a true-hang diagnostic, run `opencode run` out-of-band with
stdout redirected straight to a file — but read its limits: the file only captures
what node flushes *before* the kill. A `Stop-Process -Force` drops the buffered
remainder, so a large late event (devstral's whole-file write) can be absent from
the transcript and yet provable from the worktree — check both before concluding.
Same lesson as Task 2 overall: the transcript is evidence, not the whole picture.

### Task-veracity benchmark: scaffold-from-scratch (future, unscheduled)

Proposed 2026-09-20, not started — no effort or hardware committed. Tasks 1
(`kane-01-background-pair`) and 2 (`lfc-01-listing-status-guard`) both test
one capability: fix a real, pre-diagnosed bug in an existing, tested repo,
graded by four mechanical gates (scope/suite/failsOnOld/typecheck) that all
assume a passing baseline suite already exists to diff against. A genuinely
different capability — **building something new from a plain-English
prompt, no existing repo, no pre-existing bug** — matches how projects
actually get started day to day and is worth testing eventually, but is not
the same benchmark shape and needs its own design.

TanStack Start's own homepage "Start Prompt" was proposed as the example:

> "Build a TanStack Start application with file-based TanStack Router
> routes, validated search params, route loaders, typed server functions,
> full-document SSR, and streaming. Keep server-only work behind explicit
> boundaries, choose the appropriate SSR mode per route, and target the
> deployment runtime without changing the application model."

Reviewed and agreed: it doesn't fit the existing four-gate harness as
written. It bundles ~6 distinct capabilities into one shot (routing, search
params, loaders, server functions, SSR-mode selection, streaming, deploy
targeting) rather than the narrow single root cause that made Task 1/2
gradable; some of those (per-route SSR-mode choice, deployment-runtime
targeting) are judgment calls without an obvious mechanical pass/fail the
way "does the suite pass" is; and there is no pre-existing baseline to diff
against or revert to, so `failsOnOld` as currently implemented does not
apply. It is also TanStack's own marketing prompt — likely heavily
represented in training data, so a model could produce a plausible,
memorized-pattern scaffold without real reasoning about a specific
codebase, which would measure something different from what Tasks 1-2
measure. TanStack Start's source lives in the `TanStack/router` monorepo
(github.com/TanStack/router) alongside TanStack Router, not a separate repo
— pointer for whoever picks this up.

Three candidate shapes, captured side by side. **Decision 2026-09-23: B
(decomposed slices), for the "React 9 + TypeScript webapp from a plain-English
prompt" case** — the other two stay parked:

- **A — CLI/data-transform scaffold.** Fixed input fixture, exact expected
  output to diff against. Fully mechanical, closest in rigor to Tasks 1-2,
  but the weakest fit to the actual (web-app) workflow this is meant to
  test. Parked.
- **B — Decomposed slices.** Break the Start Prompt into narrow,
  individually-gradable mini-tasks (one route + loader, one server-function
  boundary check, etc.) instead of one monolithic build. Keeps the real
  workflow shape while restoring the narrow-root-cause property that made
  Task 1/2 gradable. **The pick, spec'd concretely below.**
- **C — Full prompt, staged grading.** Keep the whole prompt as the eventual
  target; build mechanical checks incrementally (build succeeds → route
  tree resolves → loader fires → server function absent from client
  bundle); explicitly punt the judgment-heavy parts (SSR-mode choice,
  deploy targeting) rather than force a fake-mechanical answer for them.
  Parked — it is what mode-B planning against a pre-seeded skeleton happens
  to produce autowired in an owner-visible form, so it becomes the objective
  if/when B proves out.

**Why B fits the harness as it exists.** The four gates (scope/suite/
failsOnOld/typecheck) never needed a *pre-existing bug* — they need a source
file to revert (`srcRevertFiles`) and a test that fails when that source is
reverted. A greenfield feature slice is the same shape with "not yet
implemented" in place of "bug": slice N's branch commits off the previous
slice's head (`benchBaseCommit` = slice N-1's commit), the acceptance test
targets only slice N's source file, and `failsOnOld` means "revert slice N's
source → slice N's test fails". The existing `-SetupOnly` branch table already
chains commits this way. **No harness change is required for feature slices.**

**The one genuine gap: slice 0, the skeleton.** A scaffold task (init repo,
package.json, tsconfig, vitest wiring, one trivial passing test) has nothing to
revert — the `scope` gate requires touching a `srcRevertFiles` entry, so no
greenfield task can pass it. **Decision: the skeleton is a planning-time
artifact, not an executor task.** For the first trial the owner (or the planner
seat, hand-verified) authors the slice-0 skeleton, exactly as Tasks 1/2's repos
already exist as skeletons the fleet never scaffolded. Grading starts at slice
1. A future follow-up *could* add a `greenfield` task kind whose failsOnOld
reverts the scaffold files to test "removing the skeleton breaks the suite" —
but that is a new gate and a new judgment (is a ``tsconfig.json`` diff a real
change?), deferred until the translated slices prove they hold mechanically.

**The translator seat is the planner.** Producing ordered, benchmark-shaped
slices from the English prompt — each slice one source file + its test, 2-3
files / ~300-line cap, acceptance test failing on the *previous* slice — is the
same contract the `qwen3.6` planner prompt (docs/agent-notes/
planner-prompt-qwen3.6.md) already enforces for defect orders; only the
"defect" becomes "missing feature". The plain-English → technical-prompt step
the user's ideal setup wants is exactly this seat's output. First instance:
the owner's "React 9 + TS webapp with …features" prompt, decomposed by the
planner into a slice chain.

**Slice-chain mechanics (as specified for the first trial):**
1. Slice-0 skeleton authored + committed by the owner (or planner output hand-verified) on `main` of a new benchmark repo: React 9 + TS + Vitest, blank app, trivial passing test — the same baseline assumption Tasks 1/2 start from.
2. Planner decomposes the English prompt into ordered slices; each slice written as a full `manifest.json` entry with `benchBaseCommit` = the previous slice's committed head, `allowFiles` = source + test only, `testCmd` = `npx vitest run <test>`, acceptance test verified to fail on the previous slice's committed state *before* the order queues (same failing-first discipline as defect orders).
3. Executors run each slice through the untouched gates, in order, one slice per attempt; attempt 2 / parallel node3 seat as in the starting build. A slice that can't pass means its acceptance test did not match the previous state — the slice goes back to the planner, never silently dropped.
4. Pass@N over the whole chain measures the *translation* (did the seat decompose into gradable slices?) separately from per-slice executor passes (did the executor implement it?).

Success for the first trial: all slices pass in order with the runner only
in the planning and merge steps — the same definition as Step 5 (first real
use) but greenfield. Until the server is back, the planner seat does the
decomposition locally (it is slow, but the slice chain is exactly the
"handled by decomposition, not a bigger context" principle applied to
"build a whole app").

Purely additive — does not change the status of Tasks 1/2, the harness, or
the "hold config changes until ~3 graded runs across ≥2 tasks" gate.

### Task-veracity benchmark: external research pass (2026-09-20)

Before deciding whether to keep tuning individual seats or expand the
benchmark, checked whether prior art exists for this exact problem — grading
whether a coding agent actually did the work, not whether it claimed to.
It does, and it changes how the "0/3" result above should be read.

- **The 4-gate mechanical design (scope/suite/failsOnOld/typecheck) already
  matches the field-standard methodology.** SWE-bench — the reference
  benchmark for "can an LLM resolve a real GitHub issue" — grades the same
  way: apply the agent's patch, run the real test suite, binary
  resolved/not-resolved. Nothing to change here.
- **Task 1/2 sidestep a documented SWE-bench weakness.** Recent critique
  argues GitHub-issue-sourced benchmarks risk training-data contamination
  and don't reflect real chat-based dev usage, inflating scores — see
  ["Saving SWE-Bench: A Benchmark Mutation Approach for Realistic Agent
  Evaluation"](https://arxiv.org/html/2510.08996v2). Task 1/2 are private,
  unpublished bugs in this user's own repos — structurally immune to that
  specific critique.
  **Correction (2026-09-30):** the three source repos (`mkane848/KaneEnabler`,
  `lfc-bot`, `ASoHaVCompanionApp`) are public on GitHub, so "private" is wrong.
  The fixes are recent (2026-08 and 2026-09), so contamination of the seats
  measured so far is unlikely but unchecked, and the claim will not survive a
  model trained after they were published. "Unpublished" is a per-model claim
  (the model's training cutoff vs the task's commit date), and no held-out set
  exists.
- **The "liar mode" and destructive-rewrite failures are a named, studied
  failure class, not a fluke of these particular runs.**
  ["Reward Hacking Benchmark"](https://arxiv.org/abs/2605.02964) measures
  exactly this behavior (forging artifacts / skipping steps to fake
  completion) across 13 frontier models and finds non-zero exploit rates
  even at the top end (0%–13.9%, Claude Sonnet 4.5 to DeepSeek-R1-Zero).
  [MIRAGE-Bench](https://arxiv.org/abs/2507.21017) offers a reusable
  taxonomy for this: agent actions unfaithful to (a) task instructions,
  (b) execution history, or (c) environment observations. qwen3:14b's run
  (asserted success after seeing its own edits error and the suite stay
  green) is case (c); devstral's whole-file rewrite is a different,
  more destructive failure the taxonomy doesn't really cover — worth
  naming as its own category if this benchmark grows a "blast radius" axis
  alongside the existing four gates.
- **Calibration numbers exist, and they reframe "0/3" as unsurprising rather
  than a strong finding.** Published SWE-bench-Verified-style rates for the
  *base*, non-SWE-fine-tuned models this fleet actually seats: plain
  Qwen3-8B (non-thinking) ≈ 8%; SFT-specialized 8B/14B variants reach
  21–30%, but the fleet runs the vanilla Ollama-library builds, not those
  variants; Devstral-Small (24B, explicitly marketed for this exact task
  class, by Mistral + All Hands AI) ≈ 17.2% pass@1 on the comparable
  SWE-MERA benchmark. At true rates in the 8–20% range, the probability of
  seeing **0 successes in 7 trials by pure chance is roughly 20–55%**
  ((1-p)^7 at p=0.08..0.20). **Correction to how the "0/3" (and combined
  0/7 across both tasks) result above should be read: this does not yet
  distinguish "these seats can't do this at all" from "these seats succeed
  roughly 1 time in 6–10, and not enough trials have been run to see it."
  Sample size, not task diversity, is the current bottleneck** — a
  different conclusion than treating 0/7 as settled evidence of a hard
  capability ceiling.
- **Scaffold/harness choice is a separate, documented confound from raw
  model capability** —
  ["Don't Blame the Large Language Model: How Scaffolding Evolution Shapes
  Coding Agent Quality"](https://arxiv.org/pdf/2607.03691), consistent with
  this repo's own finding that `qwen2.5-coder`'s template never emits the
  `<tool_call>` tags the harness needs (see Gotchas in AGENTS.md). Devstral
  scoring worst locally despite being the one model vendor-tuned for this
  task class, and known to run here as a partial-offload edge fit, is worth
  checking rather than accepting at face value — this repo already has the
  right technique for it (PR #8's VS Code-Agent-mode cross-check of
  devstral's zero-write result on Task 1), just not yet repeated for Task
  2's destructive-rewrite result.
- A hobbyist sibling project ("harness-bench", in progress) pairs local
  models against multiple agent harnesses across roughly 16 tasks with
  hidden-test grading — informal, not a rigor benchmark, but a useful
  reference point for what scale similar solo efforts converge on once past
  the initial proving-out stage (more like 10–20 tasks, not 2).

**Testing-plan addition — hosted/frontier-model calibration arm (unscheduled).**
Run the exact Task 1 and Task 2 prompts once each through a hosted/frontier
model, needs an endpoint + API key the fleet owner supplies/approves — not
run yet, no cost committed. Purpose: one oracle-level data point to catch
task-design bugs (an ambiguously worded prompt, a gate that's harder to
clear than intended) versus a genuine local-model capability gap. Modeled
directly on the review-gate roadmap's own still-open "hosted arm... the
only untried thing that could change the answer" item above, so it's the
same category of move, not a new one.

**Recommendation, not a directive** — the fleet owner's call: given the
statistical read above, more repeated trials on the existing 2 tasks (e.g.
~5 runs per model per task) is likely higher-value right now than
immediately authoring a 3rd task shape, since it directly narrows the
confidence interval on the current finding rather than adding a new
variable on top of an already-thin sample.

### Task-veracity benchmark: task set expansion (2026-09-21)

The fleet owner clarified the actual goal: **general capability** ("is this
model good at fixing bugs", not "is this model good at fixing `kane-01` and
`lfc-01`"). That changes which axis more trials should grow.

**Why breadth beats depth once the goal is general capability.** Two
sources of uncertainty were tangled together: run-to-run noise (does the
same model on the same task succeed reliably?) and task-to-task variance
(does success on one task predict success on a bug you haven't tried?).
Everything in the external-research-pass section above narrows the first
one only. At 2 tasks, the second is essentially unmeasured no matter how
many repeats run — a 50-run sample on `lfc-01` alone still says nothing
about a race-condition bug or a schema-mismatch bug. This is the same
breadth-vs-depth split SWE-bench resolves by going wide (500–2,294 distinct
issues, one attempt each) instead of deep, and today's own data already
shows the between-task variance is real: `qwen3:14b` scored one full PASS
and one classic 6-write regression on `lfc-01` back to back (see the run
log below) — a pattern not visible from re-running one task harder.

> **Correction (2026-09-21).** This paragraph originally offered a second
> example: that node3's `qwen3:8b` "liar-moded on `kane-01` and `lfc-01`
> alike while desktop's identical model tag never has". **Withdrawn** — those
> runs never reached Ollama at all (see "Node3's `qwen3:8b` 'liar mode' was
> never liar mode" below), so they are not evidence of between-task variance
> or of anything else about that seat. The `qwen3:14b` example above still
> stands on its own, and the breadth-over-depth conclusion does not depend on
> the withdrawn one.

> **2026-09-23: the N=10 backfill and the 16-task expansion wait until
> after first real use (winners-first — see "Next up" item 2). The decision
> below is the target, not the current order.**

**Decision: N=10 per model/task cell, 8 tasks now, 16 the target.** Wilson
95%-CI math (still 0 successes / at a 20% true rate): n=5→±29pts,
n=10→±23pts, n=20→±17pts, n=50→±11pts, n=100→±8pts — classic diminishing
1/√n returns. n=10 is the realistic floor used by community local-model
eval harnesses (bigcode-evaluation-harness-style setups; the academic
Codex/HumanEval pass@k standard is n=200, but assumes near-free parallel
cloud sampling this fleet does not have). Past ~50–100 the marginal
tightening isn't worth the run time here — that budget is better spent on
more tasks. 8 is the near-term stop (up from 2); **16 tracks the "harness-
bench" sibling hobby project's own scale** (§ above) as an informal
reference point for where a solo effort's task-authoring cost starts to
bind.

**The 6 new tasks (`tests/tasks/manifest.json`).** Sourced from real,
already-merged bug-fix commits in the fleet owner's own repos — not invented
bugs — by scanning each repo's commit history for a `fix` commit touching
exactly one source file and its test, then verifying each one directly
(clone, checkout the commit *before* the fix, confirm the baseline suite is
green, then apply *only* the fix commit's test-file changes against the
still-buggy source and confirm the suite goes red — the same `failsOnOld`
contract the harness itself enforces). Picked for genuine diversity against
each other and against `kane-01`/`lfc-01`, not more of the same shape:

| Task | Repo | Bug class | Baseline | failsOnOld check |
|---|---|---|---|---|
| `kane-02-multiword-creature-type` | KaneEnabler | string/word-boundary parsing | 28/28 | 2/31 fail |
| `kane-03-saga-chapter-triggers` | KaneEnabler | stateful event/trigger bug | 23/23 | 3/27 fail |
| `kane-04-singleton-up-to-n` | KaneEnabler | regex/lookup-table fallback | 13/13 | 3/16 fail |
| `asohav-01-library-write-reporting` | ASoHaVCompanionApp | async operation-ordering (report success/failure across 2 non-transactional DB calls) | 35/35 | 7/43 fail |
| `asohav-02-changelog-uuid-id` | ASoHaVCompanionApp | schema/id-generation mismatch | 194/194 (full suite — new test file) | 2/4 fail |
| `lfc-02-scryfall-headers` | lfc-bot | external API contract (missing required headers) | 11/11 | 1/12 fail |

Two candidates were found and **dropped** rather than forced: ASoHaVCompanionApp's
glossary-depth-cap commit bundled a real bug fix in a React component together
with an unrelated "See also chips" feature addition, spanning CSS/component
files well past the 2-file `allowFiles` shape every other task uses — no
clean isolation existed. `asohav-01`/`asohav-02` are themselves each scoped
*down* from a larger real commit (7 and 9 files respectively) to just their
backend logic + test, dropping frontend-surfacing and release-bump files
that were bundled into the same original commit but aren't the bug.

**Known caveat — `lfc-02` and `MANAPOOL_API_KEY`.** `tests/services/scryfall.test.ts`
has a pre-existing, unrelated flake: one test's fetch-call-count assertion
depends on whether `MANAPOOL_API_KEY` is set in the ambient environment
(a real extra network call fires if it is). Reproduced directly during
verification. **`MANAPOOL_API_KEY` must be unset/empty in the shell running
`test-tasks.ps1` for `lfc-02`'s baseline gate to be reliable** — the task's
own prompt tells the model this too, but the baseline check runs before the
model sees anything.

**Setup required before these run — new local branches (not required since
2026-09-30).** `test-tasks.ps1` used to resolve `refs/heads/<branch>` in the
task's local `repo` checkout (not the GitHub remote), so each new task's
pre-fix state needed a real local branch pinned at the exact parent commit
verified above. It now runs the pinned `benchBaseCommit` itself
(`Resolve-TaskBase`), so these branches are labels that
`run-tasks-batch.ps1 -SetupOnly` still creates; the commands below are the
by-hand equivalent. In each local checkout:

```powershell
# C:\Projects\KaneEnabler
git fetch origin
git branch bench/multi-word-creature-types 0e9b703047d37e31abbccbda2c9de175ae3e33cb
git branch bench/saga-chapter-triggers 4029a94a8bd5a22df1f3dcf819719c0e448270b4
git branch bench/singleton-up-to-n 420372615ef8b95566dc8ab24039c1532830fdbf
git branch bench/background-pair 92a8ed0df10262cc878d4d214d0a312d542375ec   # kane-01: tip of review-gate/deck-validity (git fetch origin gets it)

# M:\TTRPG\A Story of Heroes and Villains
git fetch origin
git branch bench/library-write-reporting c6bc1fdf9205daeebb46c469630d3cc61d6aaaa5
git branch bench/changelog-uuid-id d83381ad650b3474a50310e0dd3441a03cd89706

# M:\Projects\LFCbot
git fetch origin
git branch bench/scryfall-required-headers 170b395baf8ad4205f6fb6d409b29c25635e7363
git branch bench/listing-status-guard 4906dc2881d362bda2006d3407e0ba63e005b91b
git branch bench/status-transition-guard 4906dc2881d362bda2006d3407e0ba63e005b91b
```

`ASoHaVCompanionApp` and `KaneEnabler` are npm-installed via `git clone`
(GitHub: `mkane848/asohavcompanionapp`, `mkane848/kaneenabler`,
`mkane848/lfc-bot`) — same repos, same commit hashes, independently
verifiable by anyone with read access.

> **Correction (2026-09-30).** Only the pinned parent commits are public; the
> `bench/*` branches the harness resolved (`refs/heads/<branch>` in the local
> checkout) existed only on the owner's machine (no `bench/*` head exists on
> `kaneenabler`, `lfc-bot` or `asohavcompanionapp`). `kane-01` pinned the mutable
> branch `review-gate/deck-validity` instead of a SHA, `lfc-01`/`lfc-03` the tip
> of the local `main`, and lfc-03's acceptance tests were read from the local
> branch `bench/status-guard-throw`. Every recorded row had in fact used one
> commit per task (kane-01 `92a8ed0`, lfc-01/lfc-03 `4906dc2`), and all 18
> acceptance runs one commit (`3215aaf`; the `fcf9d1a` quoted earlier was the
> branch tip when the tests were authored).
>
> **Fixed the same day.** All nine tasks are pinned by `benchBaseCommit` and
> lfc-03's acceptance tests by `acceptance.commit`; the harness runs the pins (a
> moved branch is a WARN, a pin missing from the repo an error), and
> `tests/test-task-pins.ps1` checks that all 218 rows and all 18 acceptance runs
> used them.
>
> **What GitHub has** (`git ls-remote`, plus a fetch by SHA of each commit into
> an empty repo, 2026-09-30): **all nine pinned bases.** Eight are on `main`;
> `kane-01`'s `92a8ed0` is the tip of `review-gate/deck-validity` and the head of
> PR #82 (`refs/pull/82/head`) on `mkane848/kaneenabler`. lfc-03's acceptance
> commit `3215aaf` was the one exception (local `bench/status-guard-throw`
> only) — **published later the same day** (`git -C M:/Projects/LFCbot push
> origin bench/status-guard-throw`; a from-scratch fetch of the SHA now
> resolves). Every pin in the benchmark is on GitHub.
>
> `run-tasks-batch.ps1 -SetupOnly` prints that command while it is true. (The
> first version of this note said kane-01's base was on no remote. That was
> wrong: the check ran in single-branch clones, which show `main` only.
> `Get-PublishState` now asks the remote itself.)

### Task set expansion II: 18 tasks from the 2026-09-29 mining (2026-10-03)

The suite saturates at the top (see "Executor standings" above), so on
2026-10-03 the owner chose to add the 15 mined candidates that fit the harness
as it was, plus the three that needed the multi-file `srcRevertFiles` fix from
#65 (`kane-14`, `lfc-07`, `asohav-05`). All 18 are in
`tests/tasks/manifest.json`: **27 tasks, nine original and 18 new, none with a
graded row yet.** Each is a real, already-merged upstream fix: the pin is the
fix commit's parent, scoped down where the commit was a bundle, and the fix
commit's own test file is the informational acceptance oracle for 15 of them.
All 33 pinned commits (18 bases, 15 acceptance commits) are reachable from
`main` on GitHub (`mkane848/kaneenabler`, `lfc-bot`, `asohavcompanionapp`;
checked 2026-10-03).

| Task | What it is | Baseline | Upstream tests on the unfixed source | Source files |
|---|---|---|---|---|
| `kane-07-find-qualifier-type` | how far a text search reaches: the first creature-type word in the whole clause vs the text the payoff pattern matched (same file as `kane-02`) | 76/76 | 1 of 77 | `signals.ts` |
| `kane-08-aristocrats-false-positives` | four independent false positives (replacement effect, combat-kill trigger, sacrifice-cost scan, multi-resource cost) in the manifest's largest source file | 234/234 | 4 of 238 | `signals.ts` |
| `kane-09-colour-filter-subset` | **spec reversal**: the colour include filter becomes subset, not intersection; two existing assertions flip | 16/16 | 3 of 17 | `filters.ts` (client) |
| `kane-10-combo-permalink-scheme` | security: a stored permalink of any scheme rendered as a link; a React component test | 10/10 | 1 of 11 | `ComboPreferenceRow.tsx` |
| `kane-11-useauth-session-reject` | unhandled rejection in a React hook (`renderHook`): `loading` never clears | 11/11 | 1 of 12 | `useAuth.ts` |
| `kane-12-error-handler-400` | status mapping in Express error middleware: malformed JSON answered 500, not 400 (the easy one) | 3/3 | 1 of 5 | `errorHandler.ts` |
| `kane-13-front-face-field` | data-shape bug in plain JavaScript with a control: adventure cards read the front face, split cards keep the joined value | 20/20 | 1 of 22 | `scryfallFields.js` |
| `kane-14-undo-toast-timer` | React effect dependencies under fake timers; **two source files and a new test file** (the full suite is the baseline) | 108/108 | 1 of 111 | `UndoToast.tsx`, `App.tsx` |
| `lfc-04-admin-manage-server-permission` | Discord authorization: `/admin` was visible by default to the Administrator bit, not Manage Server | 4/4 | 1 of 5 | `admin.ts` |
| `lfc-05-digest-allowed-mentions` | security: a display name of "everyone" can mass-ping through the digest | 6/6 | 1 of 7 | `digest.ts` |
| `lfc-07-digest-split` | feature-shaped: split an over-long digest across messages with no line lost and the watermark held on a partial failure; **source, constants and test** | 7/7 | 6 of 13 | `digest.ts`, `constants.ts` |
| `asohav-03-glossary-depth-flatten` | two-part fix in a pure function (depth cap and tag flattening); one existing test encodes the old limit | 20/20 | 2 of 21 | `glossary.ts` |
| `asohav-04-neutral-status-polarity` | `!== 'Positive'` where `=== 'Negative'` was meant, at two independent sites | 22/22 | 2 of 24 | `engine.ts` |
| `asohav-05-library-write-validation` | five input-trust fixes in an Express route and its helper file; **hand-scoped tests** | 14/14 | 8 of 24 | `library.ts`, `adminLogic.ts` |
| `asohav-06-bond-cap-setting` | a hardcoded cap at six sites; **hand-scoped tests** | 93/93 | 3 of 97 | `logic.ts` |
| `asohav-07-rapport-clamp` | a ruleset change landing as a bug fix: an over-eager clamp, so the old test must be replaced | 5/5 | 1 of 5 | `party.ts` |
| `asohav-08-end-combat-clears-strain` | a missing cascading side effect across separate records; the repo call shapes are pinned in the prompt | 18/18 | 1 of 20 | `combat.ts` |
| `asohav-09-seed-virtue-conformance` | data/spec conformance against a Markdown document; **new test file** (the full shared suite is the baseline); symptom-only prompt | 368/368 | 1 of 371 | `seedLibrary.ts` |

`kane-10` to `kane-14` share one base (`605a2e0`, a nine-bug audit commit; each
task uses only its own bug's files) and `lfc-04`'s base is `lfc-07`'s fix
commit. Shapes the suite did not have: three tasks with two source files
(`kane-14`, `lfc-07`, `asohav-05`), two with a brand-new test file (`kane-14`,
`asohav-09`), three spec reversals where an existing test must be rewritten
(`kane-09`, `asohav-03`, `asohav-07`), React component and hook tests
(`kane-10`, `kane-11`, `kane-14`), a security cluster (`kane-10`, `lfc-05`,
`lfc-04`), and a prompt that names the symptom and the source of truth but not
the wrong value (`asohav-09`).

**How they were checked.** Each entry ran through the real
`tests/test-tasks.ps1` against a local clone, with a stand-in `opencode` that
applies a known change instead of calling a model (the stand-in and the
reference patches lived in the session scratch, not in the repo), in a fresh
worktree at the pin:

- `-DryRun`: install and `setup` work, the baseline equals `baselineExpect`,
  and the acceptance tests fail on the untouched base.
- `ref`, the upstream fix and tests restricted to `allowFiles`: every gate
  PASS and acceptance PASS.
- `srconly`, the fix without tests: failsOnOld FAIL (the PR #82 trap, caught);
  the suite fails too for the three spec reversals, because an existing test
  encodes the old rule.
- `testsonly`, the tests without the fix: scope, suite and acceptance FAIL.
- `ref` again under four environments (ambient, `MANAPOOL_API_KEY` and
  `DATABASE_URL` unset, both set to dummy values, `TZ=Pacific/Auckland`) and
  three repeats: the gate results were identical in all 18 tasks, so no pin was
  needed beyond the ASoHaV rule below. `lfc-04`, `lfc-05` and `lfc-07` do not
  need `lfc-02`'s `MANAPOOL_API_KEY` pin.

The first battery ran against the previous, stash-based harness, one lane per
repository. A second ran the 18 tasks against the harness as merged here with
six lanes at once, two per repository clone (the case the stash made unsafe),
and reproduced all 72 runs (18 tasks × `ref`, `srconly`, `testsonly` and a
repeat of `ref`) exactly, acceptance details included, with no stash or restore
warning and an empty stash in every clone.

**Acceptance.** 15 of the 18 carry an `acceptance` block whose `commit` is the
upstream fix commit and whose `files` are its test file (informational, never a
gate; `ref` is the label `upstream-fix`). The prompts pin every name those
tests depend on and a model could not guess (`kane-14`'s `instanceId` prop,
`lfc-07`'s `splitDigestMessage` and `DISCORD_MESSAGE_MAX_LENGTH`, `lfc-05`'s
`{ parse: [] }` call shape, `asohav-08`'s `getSheet` and `saveSheet` shapes), so
a correct but differently written fix is not failed on naming. Three tasks have
none: `asohav-05` and `asohav-06` (the oracle would be hand-scoped, not a
commit) and `asohav-09` (the upstream test looks for the `# Basic Moves`
chapter with LF line endings in a 2 MB file and the repo has no
`.gitattributes`, so a CRLF checkout, which git for Windows produces by
default, would fail it for every model without saying why, and a dry run would
still read as "fails on the untouched base"; the prompt tells the model the
file may have either line ending).

**What the gates cannot check.** Mutating the reference fix and running the
upstream tests found the parts they do not pin; for these only the model's own
tests (graded by failsOnOld) can catch a partial fix:

- `kane-14`: the `App.tsx` wiring (reverting it alone stays green; vitest does
  not typecheck and typecheck is not a gate).
- `asohav-06`: two of the six cap sites (the nested `applySpendBond` call in
  `resolveAcceptedBond` and `applySpendBond`'s own lock check), and the lock
  error text. The prompt lists all six behaviours.
- `lfc-05`: the DM send. `lfc-07`: DM delivery as one message, and sending in
  order. Three different correct `splitDigestMessage` designs pass the upstream
  tests; the wrong variants (cut every N characters, repeated headings, kept
  separators, dropped long lines, reversed order, swallowed failures) do not.
- `asohav-05`: a client-sent `0` staying `0` (a `||`-style default survives).
  `asohav-07`: "no upper limit" is pinned only at 13. `kane-10`: the `http:` and
  `data:` schemes. `kane-11`: the unmount guard in the new `.catch`. `kane-12`:
  the `SyntaxError` check. `kane-13`: `power`/`toughness` and the non-adventure
  layouts. `kane-08`: the `amplifies` lookbehind, a colon winning over a later
  "sacrifice", and the exact heuristic for the multi-resource cost.

No gap turned up for `kane-07`, `kane-09`, `lfc-04`, `asohav-03`, `asohav-04`,
`asohav-08` or `asohav-09` in the mutation sets tried (each fix part reverted
alone, plus wrong variants). `kane-08` carries a trap the prompt leaves
unstated on purpose: the death-trigger `rewards` matcher must stay a plain
RegExp (`findQualifier` skips function matchers), and the pre-existing suite
catches a violation (two tests go red).

**Harness changes made on the way.**

- A pinned acceptance commit the clone lacks is fetched from `origin` once
  before it is called missing (`Resolve-AcceptanceCommit`; `run-tasks-batch.ps1
  -SetupOnly` fetches for it too), because the fix commits are on `main` but not
  necessarily in an older clone.
- **failsOnOld no longer uses `git stash`.** Three of the validating agents hit
  it independently: `refs/stash` belongs to the repository, not to a worktree,
  so two tasks of one repo graded at the same time popped each other's stashes
  (the symptom is `stash pop failed` and an acceptance run against reverted
  source). The revert now saves the model's bytes, checks the source files out
  of the pinned base and writes the bytes back, touching nothing outside the
  worktree (`tests/test-revert-source.ps1` replaces `test-stash-args.ps1`; six
  mutants of the mechanism each fail it). The three gate verdicts were already
  decided before the pop, so the hazard reached the acceptance run and the next
  worktree state, not the verdicts; a collision on the stash lock would have
  read as "cannot grade". Corpus check: six pairs of same-repo runs overlapped
  (all `kane` tasks, 2026-09-23, the desktop and node3 terminals); their
  recorded finish times are at least 85 s apart, so their grading windows,
  which last tens of seconds, very probably did not overlap, and no recorded
  verdict is known to be affected. The earlier advice to give each terminal
  disjoint task ids is now sufficient for tasks of one repo too.
- `tests/test-task-env.ps1` checks that every ASoHaV `apps/server` task pins
  `DATABASE_URL` (the `asohav-02` finding applied to the family; `asohav-05`,
  `asohav-07` and `asohav-08` carry it, `asohav-01` pre-dates the rule).

**Not added.** The rest of the 29 candidates, with their pins, for later:

| Candidate | Parent | Why not |
|---|---|---|
| `kane-05` singleton copy limit, `kane-06` commander legality dedupe | `92a8ed0` (`kane-01`'s base) | owner-diagnosed open defects with no upstream fix commit; the tests and a reference fix were authored by the miner, so the oracle is not the project's own (`kane-05` has a trap: a correct fix turns 4 of the 10 original tests red) |
| `lfc-06` autocomplete deadline (fix `64939c4`) | `2383f249101da5a4a39b07af18efa8f85bb311c7` | fits the harness, but the scryfall tests are `MANAPOOL_API_KEY`-sensitive (`lfc-02`'s flake); would need the same `testEnv` pin |
| `asohav-10` odds (fix `46e88f5`), `asohav-11` engine (`e793ff9`), `asohav-12` enemies (`4e5bbcf`) | `44ead5d`, `dae86a9`, `088e5e7` | implement-to-given-tests: the baseline is red by design and the tests exist before the model starts, so `baselineExpect` and failsOnOld do not apply; needs a task kind that protects the test files |
| `asohav-13` misfortune authz (fix `7c5a4de`) | `e909907` | 2 source and 2 test files; gradable now (`allowFiles` takes any number of files), not chosen: partly a feature, 14 red tests |
| lfc multi-file autocomplete (fix `64939c4`), kane fading permanents (`4029a94`) | `2383f24`, `f7d9bc1` | 3 and 4 source files plus tests; gradable now, large prompts |
| asohav web character create (fix `3a7589d`) | `8686bf4` | vitest never goes red, only `tsc` does; needs typecheck as a hard gate |
| kane `parseJsonArray` refactor (no upstream fix) | `2945ca8` | behaviour-preserving: the suite is green before and after and only `tsc` catches a dropped import; needs a refactor kind (no failsOnOld, `tsc` hard gate, a structural check) |

**Running them.** `.\tests\run-tasks-batch.ps1 -SetupOnly` creates the 18 local
`bench/*` labels (the by-hand equivalent is below) and fetches what the clones
lack. On the Windows machine, `.\tests\test-tasks.ps1 -Task <id> -DryRun` per
new task is the first check: it installs, runs the baseline (the table's
`Baseline`) and reports the acceptance tests failing on the untouched base. A
bare `-OnlyMissing` batch now queues 18 tasks for every seat, which is hours;
pick tasks with `-Tasks`. **Report the new tasks as their own cohort.** The
standings in this document and in `tests/results/README.md` are over the
original nine; do not pool the two until each seat has comparable runs on
both.

```powershell
# C:\Projects\KaneEnabler
git fetch origin
git branch bench/find-qualifier-type 10889539112089dcd122014f934520f9f11cf558
git branch bench/aristocrats-false-positives 45095ab148d27fdbe20765a112d1dd7d743e4fcd
git branch bench/colour-filter-subset f0abf087f92323e69a0a706e14c22b427fb80d31
git branch bench/combo-permalink-scheme 605a2e080cfddee855337f1b3d0b9cf7e48ddd6e
git branch bench/useauth-session-reject 605a2e080cfddee855337f1b3d0b9cf7e48ddd6e
git branch bench/error-handler-400 605a2e080cfddee855337f1b3d0b9cf7e48ddd6e
git branch bench/front-face-field 605a2e080cfddee855337f1b3d0b9cf7e48ddd6e
git branch bench/undo-toast-timer 605a2e080cfddee855337f1b3d0b9cf7e48ddd6e

# M:\Projects\LFCbot
git fetch origin
git branch bench/admin-manage-server-permission e644702a6ce9753b69ca3291e1bdc388e2d1a7d3
git branch bench/digest-allowed-mentions 6f5a5038aef79c2ccdcd460d9ebfa9c6b2e16cef
git branch bench/digest-split d6a5338d809407d181b7d74eef064bbd0d81ffa2

# M:\TTRPG\A Story of Heroes and Villains
git fetch origin
git branch bench/glossary-depth-flatten 5c891936847a844bb23dd74b02aa1fa6f1525f84
git branch bench/neutral-status-polarity f15a58cb9ef29c3b511caa0d88949a7b10686874
git branch bench/library-write-validation 79b369d7ba01ed02affa6534a33ef698d17b5518
git branch bench/bond-cap-setting 84719041b3312cab3e49901dea20d7129bb24761
git branch bench/rapport-clamp d73d6c978f478e3aca5fb836683fcfe639debd43
git branch bench/end-combat-clears-strain 9afb9112b0e2596edac0e7fe4055149512ab3b62
git branch bench/seed-virtue-conformance 8686bf41c9ac130bd521f05e056460ca777f43bf
```

**First model run (2026-10-03): `qwen3.6` on all 18, 11 of 16 valid graded runs
pass.** Desktop, Ollama 0.34.3, opencode 1.18.34, num_ctx 65536, limit.output
8192, small model `qwen2.5-coder-3b-cpu`, keep-alive 4h, 900 s run cap; then a
follow-up of four at 1800 s. Rows and transcripts are in `tests/results/`
(`2026-10-03T16:00`–`17:33`).

- **Clean (all gates PASS), 11:** `kane-09` to `kane-13`, `lfc-04`, `lfc-05`,
  `asohav-03`, `asohav-04`, `asohav-07`, `asohav-08`; 1.3 to 12 minutes each.
- **Test does not catch the bug, 1:** `kane-14` (fix and tests written, suite
  green, the new test still passes with the fix reverted).
- **Output cap, 2:** `lfc-07` (one step) and `asohav-09` (after six working
  steps) ended on a step that spent all 8192 output tokens with no edit.
- **Long context, 2 (the 1800 s follow-up):** `kane-07` and `kane-08` timed out
  at 900 s still reading (18–19 reads and searches, no edit). At 1800 s neither
  timed out and both failed: `signals.ts` and its test cost ~31k tokens, so
  `kane-07` overflowed into OpenCode compaction and wrote a plan instead of the
  change, and `kane-08` lost the task at 46,576 tokens of context.
- **Not a measurement, 4 rows:** `asohav-05` and `asohav-06`, twice each. The
  repo's `CLAUDE.md` at those pins is ~280 KB, the first request ~83k tokens,
  and Ollama truncated it to 32,770, dropping the system prompt, tools and task
  (`tests/results/README.md` → "Prompt truncated by Ollama"). Any 64k seat
  fails them the same way; the harness now detects this and records no row.

The failure classes are the seat's known limits (output cap, long context),
plus one weak test.

**Second run (2026-10-03 evening): the same 16 active tasks, 11 of 15 graded
runs pass.** Same opencode, Ollama, context, output limit and companion as the
first; 1800 s cap for all 16 (`2026-10-03T19:21`–`21:32`).

| Across both runs | Tasks |
|---|---|
| Pass both (10) | `kane-09` to `kane-13`, `lfc-04`, `lfc-05`, `asohav-03`, `asohav-04`, `asohav-08` |
| Pass one of two (2) | `asohav-09`: output cap, then a pass (20 min, 11 edits). `asohav-07`: a pass, then a correct source fix (the upstream tests pass on it) beside a test file that does not parse (a note written as code, not a comment) |
| Fail both (4) | `kane-14`: a correct fix both times (upstream tests pass), a test that passes with it reverted both times. `kane-07`: no edit, then a wrong fix (the upstream test still fails). `lfc-07`: output cap, then a fix that fails 3 of the 13 upstream tests. `kane-08`: no edit, then the 1800 s cap with 29 reads, searches and shell calls and still no edit (no row) |

The ten double passes are the seat's reliable ground on this set; the long-context
pair (`kane-07`/`-08`) failed both times in different ways, so that limit is
real, not noise. `asohav-09` passing once it did not hit the 8192 cap is a mild
argument for trying a higher `limit.output` on this seat, not a strong one.
`asohav-07`'s run also exposed a grading flaw: with the suite already red,
`failsOnOld` recorded a `PASS` it never measured. It is `SKIP` from now on
(`tests/results/README.md` → "What counts as a pass").

**The light seat overnight (2026-10-03 22:36 – 10-04 03:27): `qwen3:8b` 0 of
17, `qwen3.5:9b` 9 of 16.** The question was whether `qwen3:8b`, the main seat
of three of the four live profiles (`dev-workflow-resident`, `dev-desktop-only`,
`dev-node3`), can do real work under today's harness, and whether `qwen3.5:9b`
is the replacement. Every active task each seat had no graded row for: the 16
new tasks for both, plus `lfc-03` for `qwen3:8b`. Desktop, the resident
profile's companion (`qwen2.5-coder:7b`), opencode 1.18.34, Ollama 0.34.3,
1200 s cap. Attempts counted the DP11 way (timeouts and crashes are attempts):

| seat | ctx / limit.output | attempts | pass | graded fail | timeout | crash |
|---|---|---|---|---|---|---|
| `qwen3:8b` | 32k / 4096 | 17 | **0** | 12 | 5 | 0 |
| `qwen3.5:9b` | 64k / 4096 | 16 | **9** | 4 | 1 | 2 |
| `qwen3.6` (first graded run of each, for scale) | 64k / 8192 | 16 | 11 | 5 | 0 (2 at the 900 s cap, re-run at 1800 s) | 0 |

- **`qwen3:8b` cannot hold an agent seat on these repos.** None of its 12
  graded runs passed every gate; on the desktop it is 1 of 47 graded runs
  across the whole corpus, and was 0/9 in step 6 above. Three runs changed only tests and never
  the source (`kane-14`, `lfc-05`, `asohav-07`), two made edit calls that left
  the tree unchanged (`kane-08`, 36 calls; `kane-10`, 5), and the rest wrote
  tests that pass with the fix reverted, or broke the suite. It repeats writes
  the way `qwen3:14b` did before it was unseated: 108 calls on `lfc-05`, 68 on
  `lfc-04`, 36 on `kane-12`. No run touched a file outside the task's
  `allowFiles`. 32k was not the problem: Ollama truncated no prompt all night,
  `asohav-03`'s ~19k-token instruction file included.
- **`qwen3.5:9b` passes what `qwen3.6` passes, faster, and misses where it
  misses.** Passes: `kane-09` to `kane-13`, `lfc-04`, `lfc-05`, `asohav-04`,
  `asohav-07`, the passes mostly 1–2 minutes each (`kane-09` 7). Misses:
  `kane-14` (the same weak test `qwen3.6` wrote twice), `kane-07` (suite red),
  `asohav-03` (output cap at 4096), `asohav-09` (no write/edit call; it created
  a stray `temp_ruleset.txt` through the shell), `lfc-07` (1200 s cap). 9/16
  against `qwen3.6`'s 11/16 does not separate the two at N=1.
- **The two crashes are the known `qwen3.5` template bug, so they count
  against the seat.** `kane-08` and `asohav-08` ended on an Ollama 500 from
  the model's chat template, `Jinja Exception: No user query found in
  messages`, at 49.8k and 54.1k tokens of context: the error recorded at 59.4k
  after compaction (DP8 above) and on `kane-02` (2026-09-23). The harness files
  them as `_INFRA_` with no row because opencode exited non-zero, and
  `-OnlyMissing` would retry them, but they are a property of the seat: a long
  session on `qwen3.5:9b` can end on this error.
  *Corrected 2026-10-04: neither the 59.4k one nor these followed a
  compaction. Each is a request over `num_ctx` that Ollama cut from the front,
  and other seats lose their task silently in the same spot ("Context
  overflow" below). They still count against the seat, the same as
  `qwen3.6`'s graded silent loss on `kane-08`.*

What this means: the profiles that seat `qwen3:8b` are seating a model that
passes nothing on real tasks. `qwen3.5:9b` is the evident replacement for the
desktop ones, after (1) reproducing the template crash in a long interactive
session and finding a workaround or accepting it (*done 2026-10-04: it is a
context overflow with no seat-side workaround; "Context overflow" below*),
and (2) the same
preconditions as any re-seat above (`-Reliability` is met, DP10; a
plain-language trial; the companion re-measured). `dev-node3` stays on
`qwen3:8b` until `qwen3.5:9b` is probed on node3. Owner decision.

**`qwen3.5:9b` on node3 (researched 2026-10-05; on hold until the server
runs).**
- **Memory.** The desktop's copy is a Q8_0 GGUF import (2026-09-18). At about
  10.4 GiB at 64k it does not fit node3's 10 GB.
- **The registry build.** `qwen3.5:9b-q4_K_M` (blob `02d45dc1cf45`, 5.63 GB
  plus the vision projector) should fit fully on the GPU at 64k: about
  7.3 GiB with q8_0 KV.
  - The model is cheap on context: only 8 of its 32 layers hold KV, 1,088 MiB
    at 64k (measured on the desktop).
- **It is a different seat from the desktop's**, so the desktop rows don't
  carry over:
  - Q4 instead of Q8;
  - Ollama's built-in `qwen3.5` renderer and parser instead of the GGUF's
    Jinja template;
  - the registry's sampling defaults.
- **Its overflow will probably be silent.** The desktop's "No user query
  found" crash comes from that Jinja template, so on node3 an overflow will
  probably be silent task loss. The harness's log-based truncation check reads
  only the local Ollama.
- **Done so far (owner-approved, 2026-10-05):** pulled to node3 (6.55 GB,
  digest verified).
- **Not done yet:**
  - bake `num_ctx 65536` and check the renderer survives;
  - add an `ollama-node3` entry with `limit`;
  - probe with `test-toolcalls.ps1 -HostLabel node3`;
  - add a `run-tasks-models.tsv` row;
  - give it its own task rows.
- **Read node3's KV and flash-attention settings first.** Its log needs a
  login: SSH has no key set up.

**`qwen3.5:9b`'s second run of the same 16 (2026-10-04 15:46 – 17:34): 9 of 16
again.** Same setup, after the PR #87 merge but on the pre-#87 harness (the
change does not touch single-turn runs). 9 passes, 5 graded fails, 2 crashes,
0 timeouts.

| | tasks |
|---|---|
| passed both runs | `kane-10`, `kane-11`, `kane-12`, `kane-13`, `lfc-04`, `lfc-05`, `asohav-07` |
| failed both runs | `kane-07`, `kane-14` (`qwen3.6` fails both of its runs of these too) |
| crashed both runs | `kane-08` |
| different each run | `kane-09` pass → fail (31 writes, out of scope), `asohav-04` pass → fail, `asohav-03` fail → pass, `asohav-08` crash → pass, `asohav-09` fail → crash, `lfc-07` timeout → fail |

- **18 of 32 attempts across the two runs, against `qwen3.6`'s 22 of 31 graded
  runs of the same tasks with no crash.** The 9b is reliable on the small,
  clearly scoped repairs and erratic beyond them: 6 of 16 tasks changed result,
  and some passes were costly (`lfc-05`: 24 writes and 713 s, against 3 writes
  and 110 s in the first run).
- **Two graded fails had a correct fix.** On `kane-14` and `asohav-04` the
  upstream fix commit's own tests passed (acceptance `PASS`), but the model
  left the suite red. The gates are right to fail them; it is the model's own
  test, not its fix, that is wrong.
- **All four crashes so far are the template error, at 49.9k–54.4k tokens of
  context** (both runs: `kane-08` twice, `asohav-08`, `asohav-09`), plus the
  59.4k one after compaction (DP8). Not yet known whether opencode rewrites the
  history at that size or the template trips on something else. That is the
  next measurement, and a derived model without the template's `raise` is the
  candidate workaround. *Measured the same day ("Context overflow" below):
  each is a request over `num_ctx`, none followed a compaction, and the
  derived model is withdrawn, because it would turn the crash into silent
  task loss.*

**`asohav-05` and `asohav-06` retired (owner decision, 2026-10-03).** The
manifest marks them `retired` (date, reason, evidence): they keep their ids,
pins and rows, `test-tasks.ps1` and `run-tasks-batch.ps1` leave them out of
`all` and the picker and refuse them by name unless `-IncludeRetired`
(`tests/test-retired-tasks.ps1`). The reason is that the oversized file is not
daily use: the ~280 KB `CLAUDE.md` existed 2026-09-10 to 09-12, and the owner
trimmed it to 16 KB, which is what OpenCode loads in that repo today.

- **Way back (not built):** a new id per task (`asohav-05b`, `asohav-06b`) on a
  base that is the original pin plus the first trimmed `CLAUDE.md`
  (`47bf270`, 2026-09-12, 15,643 bytes), chosen because it describes the code
  as it was at the pins; today's file describes features that do not exist
  there. The pin itself cannot move under the old id, and swapping the file in
  the worktree during a run would trip the scope gate. Needs a bench branch
  pushed to the asohav repo, so it is the owner's call.
- **Open question first: how should a task treat the repo's instruction
  file?** OpenCode loads a project's `AGENTS.md`, else its `CLAUDE.md`
  ([OpenCode rules](https://opencode.ai/docs/rules/)), into every request. Of
  the 27 pins, 12 load a `CLAUDE.md` and 15 an `AGENTS.md`, from ~180 tokens
  (KaneEnabler's, which also tells the agent to run
  `pnpm dlx @tanstack/intent@latest`, a network fetch, before substantial
  edits) to ~19k (`asohav-03`) and ~70k (the two retired). Options: as pinned
  (today; realistic only where the file was), normalized (a trimmed or
  current file on a new base), or none (`OPENCODE_DISABLE_CLAUDE_CODE=1`
  covers only `CLAUDE.md`, not `AGENTS.md`, so "none" is not symmetric
  across repos). Any change to how a task loads it is a new era for that
  task's rows. `asohav-03`/`-04` (77 KB and 56 KB, 14–19k tokens at the start
  of every request) fit and passed, but carry part of the same distortion.

### Context overflow: the `qwen3.5:9b` "template crash" and silent task loss (2026-10-04)

**Finding: `qwen3.5:9b`'s `No user query found in messages` is not a template
bug. It is what a context overflow looks like on that one model; every other
seat overflows silently and carries on without its task.**

- **Mechanism, read in the source of the versions we run:**
  - **opencode 1.18.34** compacts when the *last step's* token count reaches
    `limit.context − limit.output`, which is 61,440 for a 64k seat with a 4096
    output limit ([opencode `session/overflow.ts` at v1.18.34][oc-overflow]).
    The tool output that step produced isn't counted, and it all goes into
    the next request. One `read` returns up to ~50 KB, about 15k tokens, so a
    session at ~50k plus one large read sends a request over `num_ctx` with
    no compaction first.
  - **Ollama 0.34.3** then drops messages from the front until the rest fits,
    keeping only system messages, and logs it at debug level
    ([Ollama `server/prompt.go` at v0.34.3][ollama-prompt]).
  - **The task prompt** is the first message after the system prompt, so it
    goes first.
  - **`qwen3.5:9b`'s template** (the GGUF's own) refuses a conversation with
    no user message, and Ollama returns a 500. The other seats' templates
    render the conversation, and the model goes on without its task.
  - **The harness's truncation check** reads Ollama's info-level `truncating
    input prompt`, so it caught neither case.
- **Proof:**
  - A logging proxy between opencode and Ollama captured kane-08's failing
    request on a third run. It contains the user message, so Ollama must have
    removed it before rendering.
  - Replayed to Ollama as captured, the request fails the same way. The same
    request with only its last tool result cut to 2,000 characters succeeds,
    at 61,704 prompt tokens.
- **All 7 `qwen3.5` crashes on record are this overflow, and none followed a
  compaction.** They are `kane-02` twice at 32k (09-23 and 09-26), `lfc-03`
  at 59.4k (09-27), `kane-08` twice, `asohav-08` and `asohav-09` (10-04). The
  earlier write-ups said the `lfc-03` one came "after compaction"; it did not.
- **The silent version is in the corpus.** On `kane-08`, `qwen3.6` lost the task
  in all three of its runs (2026-10-03).
  - In the graded run, its reply after the drop was "I see you've shared the
    `signals.test.ts` file, but I don't see a specific question or task", and
    it stopped: a FAIL.
  - The other two drifted until the time limit.
  - At 32k on 2026-09-26, the same happened to `laguna-xs-2.1` and
    `nemotron-3.5-lightning` on `kane-02`, and to `nemotron` on `lfc-03`.
  - Every case is on a task whose files run to thousands of lines
    (`signals.ts` is 2,742).
- **A second compaction failure: a loop.** `qwen3:8b` on `asohav-03` (32k)
  compacted 14 times. The repo's ~19k-token `CLAUDE.md` keeps the prompt right
  after compaction (29.2k) above the 28,672 threshold, so it compacted again
  at once, until the time limit.

**Trial: compact earlier. Not adopted.**

The overlay was loaded with `OPENCODE_CONFIG`, so neither the live config nor
`tests/results/` changed:
- `limit.input` set to context − output;
- `compaction.reserved: 16000`;
- `preserve_recent_tokens: 8000`.

`qwen3.5:9b` then compacts at 45,440 and `qwen3.6` at 41,344.
`compaction.reserved` only applies to a model that sets `limit.input`.

Five runs, with no overflow and no crash:

| task | seat | result |
|---|---|---|
| `kane-08` | both | FAIL: each compacted at ~50k, then stopped right after, with 0 edits |
| `asohav-03` | `qwen3.6` | PASS, peaked at 39k, no compaction |
| `asohav-03` | `qwen3.5:9b` | FAIL at the 4096 output cap, as its first run did |
| `kane-07` | `qwen3.6` | suite FAIL, as both earlier runs |

- **Why kane-08 stopped.** After an automatic compaction opencode sends a
  hard-coded "Continue if you have next steps, or stop and ask for
  clarification if you are unsure how to proceed." ([opencode
  `session/compaction.ts` at v1.18.34][oc-compaction]). Under `opencode run`,
  a model that answers it in prose ends the run.
- **Why not adopt.** Among graded 64k runs of these two seats, 4 of the 18
  that compacted passed. The new thresholds would have made 15 more runs
  compact, and 11 of those passed. On 64k seats the overflow costs one task
  (`kane-08`), so earlier compaction would cost more than it saves.
  - Caveat: hard, long tasks are the ones that compact, so 4 of 18 overstates
    what compaction itself costs.
- **This also retracts the workaround proposed above**, a derived
  `qwen3.5:9b` without the template's `raise`. It would turn the visible crash
  into the silent task loss.

**Built (`tests/test-context-events.ps1`):**
- Every run JSON records `contextEvents`:
  - compactions, and whether the run ended right after the last one;
  - front-drops: the next step reuses under half the previous prompt from
    the cache, the request is estimated over `num_ctx`, and no compaction is
    involved;
  - the peak prompt;
  - `compactionConfig`: the threshold opencode compacts at, so a change to it
    shows as a new era.
- A front-drop is a WARN.
- A template crash's `_INFRA_` detail names the overflow.
- Grading is unchanged.

**Decided (owner, 2026-10-04): a front-drop run stays graded** on its end
state, as in a real session. Unlike truncation, it is what the seat and
client really do mid-session; `contextEvents` marks it.

**Compaction is the bigger problem. Owner's choice (2026-10-04): first test
whether a plain automatic "continue" rescues a run that stalls after
compaction**, before tuning `preserve_recent_tokens` or `tail_turns`. Those
two settings barely apply in a harness run anyway: opencode keeps whole
*turns*, and a single-prompt run is one turn. The owner's standard settles
the framing. They chat in one window and never switch models or settings,
and approvals in the chat are wanted (for now, more rather than fewer). A
stall after compaction is therefore a defect even though "they could just
type continue".

**Compaction nudge diagnostic (2026-10-04/05): a plain automatic "continue"
rescues the stall.** `test-tasks.ps1 -NudgeAfterCompaction` sends one fixed
message into the same session (`opencode run --session`) when a run ends
after a compaction. It sends at most one per compaction and two per run. The
message keeps the owner's approvals:

> Your context was just compacted; the summary above is what you have. Carry
> on with the original task now: use your tools to make the change and check
> it, instead of describing next steps. Stop and ask only for a decision that
> is mine to make: approving a plan, a requirement that is unclear, or
> anything destructive or hard to undo (deleting files, force-pushing,
> secrets, dependencies, CI).

The cells were those where a current seat's graded run had failed by stopping
after compaction. Default config. Nudged runs are *assisted*, so their 13
runs live in `tests/results/compaction-nudge/` and never in
`tasks-summary.tsv`.

| what happened after compacting | runs | outcome |
|---|---|---|
| kept working | `asohav-01` ×2, `asohav-02`, `lfc-07` ×2 (`qwen3.5:9b`) | 2 PASS, 3 timeouts |
| had already finished; nudged, confirmed done | `kane-09` (`qwen3.5:9b`) | PASS |
| **stalled; nudged; resumed** | `kane-09` (`qwen3.5:9b`) | correct source fix (the upstream fix's tests pass), but its own test left the suite red and a stray `.bak` file failed scope |
| **stalled; nudged; resumed** | `kane-07` ×3 (`qwen3.6`) | **2 PASS** (all gates and the upstream tests); 1 resumed, then ended on a step that used all 8,192 output tokens with no output |
| stalled; not nudged (first, narrow trigger) | `kane-07` ×2 (`qwen3.6`) | FAIL, 0 edits |
| no compaction | `asohav-02` (`qwen3.5:9b`) | suite FAIL |

- **All 4 genuine stalls resumed once nudged, and `kane-07` went from 0 of 4
  to 2 of 3 passes.** So the stall is cheap to fix. It is not the summary
  losing the task. These are assisted runs, and the sample is small.
- **The common stall comes late.** `qwen3.6` re-reads for a few steps after
  compacting, then stops on a recap ("So far I've been working on fixing
  `findQualifier`…"). The first trigger, "stopped within two steps of the
  compaction", missed both such runs. It now fires on any prose-only stop
  after a compaction (`contextEvents.endedWithoutToolCall`). The three
  2026-10-05 runs used the new trigger.
- **The next limit is `limit.output`.** Two `kane-07` runs spent a whole
  step's 8,192 tokens with no output after the nudge. One recovered, one
  ended there. Worth measuring separately; the earlier note that `asohav-09`
  passed once it stopped hitting the 8192 cap points the same way.

**The plugin: `opencode/plugins/compaction-continue.js` (2026-10-05).** The
diagnostic's nudge only comes after a run has ended. The owner's real
experience needs it inside the session, so the plugin does it there. It uses
opencode 1.18.34's hooks, all marked experimental
([`compaction.ts`][oc-compaction]):

1. **Rewrite.** `experimental.chat.messages.transform` replaces, in what the
   model is sent, opencode's "Continue if you have next steps, or stop and
   ask…" with the nudge text above plus the original request, verbatim. The
   stored message is unchanged.
2. **Summary.** `experimental.session.compacting` asks the summary to carry
   the original request verbatim.
3. **Idle continue.** The `event` hook watches for the session going idle.
   It sends the nudge text as a new user message only when all of these hold:
   - the last compaction auto-continued;
   - the owner hasn't written since;
   - the model's last step ended without a tool call or an error;
   - the reply doesn't end on a question.

   It sends once per compaction and at most three times per session. It skips
   subagent sessions. `HOMELAB_COMPACTION_IDLE_CONTINUE=off` turns it off.

**Trial of 1 and 2 alone, unassisted (5 runs, `tests/results/compaction-plugin/`).**
The harness can't exercise 3: `opencode run` exits the moment the session
goes idle. `test-tasks.ps1` therefore turns 3 off for its runs.

| cell | runs | outcome |
|---|---|---|
| `kane-09` × `qwen3.5:9b` | 2 | **2 PASS**, one of them through a compaction (19 edits after it) |
| `kane-07` × `qwen3.6` | 3 | **0 PASS** |

The three `kane-07` runs:
- **Run 1** kept working after compacting, then ended on a step that used all
  8,192 output tokens with no output (`outputCapHit`).
- **Run 2** made one edit, with a `while (re.exec(...))` on a regex without
  the `g` flag. That's an infinite loop, and the suite FAILed on it. It then
  re-read for 3 steps and stopped with an empty reply. Its suite hung for
  2 h 20 min because `-CommandTimeout` was never enforced (fixed in PR #91);
  the gate verdicts are unaffected.
- **Run 3** re-read for 4 steps and stopped on a recap ("Now I have the full
  picture. The bug: …") with no edit.

The rewrite reached the model in every compacted run: 4 model calls each,
counted from the plugin's evidence log. So **rewriting the message cut the
stalls but didn't stop them**: 2 of 3 `kane-07` runs still stalled. A fresh
"continue" after the stop is what worked in the diagnostic (2 of 3 passes).
That is why the plugin has 3.

**Evidence for 3.** The cells' numbers are the diagnostic's, because the
harness's nudge is the same message, sent at the same moment, to the same
session. The plugin's own mechanics are checked live: real `opencode serve`
with the plugin, against a scripted stand-in model that compacts and then
stops on a recap. The model gets the rewritten message, the session gets
exactly one idle continue, the model is sent it as is, and nothing follows
once it has finished. A control, with the idle continue disabled, fails those
checks. All of this is in `tests/test-compaction-plugin.ps1`.

**Installed for daily use (2026-10-05, the owner's call).** It's a `plugin`
entry in the global config template. From then on, every desktop session has
it, harness runs included, with the idle continue switched off for those. So
benchmark rows from then on are a new era: their run JSON's
`opencodePlugins` names the plugin.

**The daily configuration, measured (2026-10-05 evening, `tests/results/compaction-daily/`).**
Setup: the installed plugin plus `-NudgeAfterCompaction`, `qwen3.6`, one run
per context-heavy cell it has failed. The nudge stands in for the plugin's own
idle continue: same text, same moment, same session. These are assisted runs.

| cell | result | before (`qwen3.6`) |
|---|---|---|
| `kane-07` | **PASS**: two compactions, two stalls, resumed after each nudge, 7 edits | no help 0/2, nudge 2/5, plugin alone 0/3 |
| `kane-07` | correct fix (the upstream fix's tests pass), but its own test also passes on the old source: `failsOnOld` FAIL | |
| `asohav-02` | **PASS**, no compaction | 2/4 |
| `kane-08` | FAIL, 0 edits: a front-drop, then after the nudge a step that spent all 8,192 output tokens with no output | 0/1 |
| `lfc-07` | FAIL, 0 edits: an output-cap step five minutes in, no compaction | 0/2 |

- **The plugin with the continue does what it was built for.** On `kane-07`,
  every stalled run that got a fresh continue now resumes. In this batch both
  produced the correct source fix.
- **What's left isn't stalls.** It's the 8,192 `limit.output` (`lfc-07`,
  `kane-08`) and Ollama's front-drop (`kane-08`, the control).
- **The output limit (owner's question, 2026-10-05; parked).**
  - Across all 68 `qwen3.6` transcripts, 11 of 676 steps hit the cap. Every
    one was 3–5 minutes of hidden thinking with no visible output. 4 recovered;
    7 ended their run, and 5 of those runs failed.
  - Raising the limit is not free. opencode compacts at
    `limit.context - limit.output` when no `limit.input` is set
    ([`overflow.ts`][oc-overflow]), so 16,384 would compact at 49,152 instead
    of 57,344. That is the direction of the earlier-compaction trial that was
    rejected.
  - Keeping the threshold with `limit.input` and `compaction.reserved` would
    let a long prompt plus a long reply exceed `num_ctx`.
  - Measure it before changing anything: a separate trial at 16,384 on the
    cells where the cap ended a run, plus a look at the thinking text, to see
    whether the capped steps are loops.

**Is this OpenCode, or the plan? (2026-10-05, recorded, not pursued yet)**

The failures here come from four layers, and only one is OpenCode's:

| layer | whose | would another client fix it? |
|---|---|---|
| a 64k window against repo files of thousands of lines (two reads of `signals.ts`, ~40k tokens) | hardware and model size | no: every client has the same window until more VRAM joins (the server's 4070 Ti Super, node3) |
| over-long requests silently cut from the front | Ollama ([`server/prompt.go`][ollama-prompt]) | partly: Ollama does it to any client, but a client that keeps requests under `num_ctx` never triggers it |
| when and how a session compacts: too late (new tool output uncounted), a summary built from tool results cut to 2,000 characters, the "or stop and ask" follow-up | OpenCode ([`overflow.ts`][oc-overflow], [`compaction.ts`][oc-compaction]) | possibly: this is where clients differ |
| carrying on after a compaction | the model | partly: prompting or a nudge helps, but a 9–35B local model is weaker at it than a hosted one |

So the plan, one chat window with the fleet supplying the models, is not
what fails. Candidate clients noted for a later comparison:

- **Claude Code on local models.** Ollama serves an Anthropic-compatible API,
  so Claude Code can be pointed at it with `ANTHROPIC_BASE_URL`; Ollama's page
  advises 64k context or more for larger repositories ([Ollama: Claude
  Code][ollama-claude-code]). That is the experience the north star
  describes. Its system prompt and tool list are large and unmeasured here,
  which matters on a 64k seat (see the preamble budget in AGENTS.md).
- **OpenClaw** is "a personal AI assistant" that bridges messaging apps to AI
  coding agents through a gateway, and wants at least 64k context with local
  models ([Ollama: OpenClaw][ollama-openclaw]). It is a front end that
  drives coding agents, not a replacement for one, so it does not change any
  layer above.

**How to decide, when it's time: measure, don't switch on impressions.** The
harness grades the end state (tests, scope, acceptance), which doesn't
depend on the client. Only how a run is launched and its transcript read is
OpenCode-specific. Making the client a swappable part, as the serving engine
already is, would let a candidate run the same tasks, starting with the
context-heavy cells where OpenCode failed (`kane-07`/`-08`/`-09`,
`asohav-02`, `lfc-07`). A different client is a new era for its rows.

[ollama-claude-code]: https://docs.ollama.com/integrations/claude-code
[ollama-openclaw]: https://docs.ollama.com/integrations/openclaw
[oc-overflow]: https://github.com/sst/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/session/overflow.ts
[oc-compaction]: https://github.com/sst/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/session/compaction.ts
[ollama-prompt]: https://github.com/ollama/ollama/blob/6383a0fa9cbf97494b847226e189f6e36b401a08/server/prompt.go

### Real-use tasks: the owner's own prompts (planned 2026-10-04)

Every task above is a guided repair: the prompt, written by Claude, names the
file, the function and the bug, asks for a test, and the run is one turn. The
north star is plain-language requests in longer sessions, which is where the
seats fail (compaction, losing the thread at 45–60k, `qwen3.5:9b`'s template
crash). The owner's own Claude Code, OpenCode and Codex sessions are on the
desktop, and they show the gap in aggregate (2026-10-04, 608 prompts in 73
sessions with a typed opener; the harness's scripted canary sessions, Codex's
approval-reviewer messages and injected skill text are left out):

| | owner's opening prompts | guided task prompts |
|---|---|---|
| length (median) | 43 words (OpenCode 28, Codex 43, Claude Code 50) | ~400 words |
| names a file | 19% | 100% |
| names a function | 1% | 100% |
| mentions tests | 16% | 100%, and requires one |
| sessions of one turn | 29% (40% run 4–10 turns, 18% run 11+) | every task |

**Owner decisions (workshop, 2026-10-04):**

- **Private layer.** This repo is public, so the sessions and the tasks built
  from them live in a private repo beside it (`HomeLab-private`): the raw
  collection never committed even there, reviewed tasks, hidden tests and
  transcripts committed there. This repo gets the harness code and, per run,
  an opaque task id and the verdicts (`tests/results/real-tasks-public.tsv`).
- **Work sessions are style-only**: anything from the owner's job (a work Codex
  export, anything under `M:\Projects\work`) may inform aggregate statistics,
  never becomes a task, and its text is never committed anywhere.
- **Single-turn first**: the real opening prompt alone, graded on the outcome.
  Multi-turn (scripted or simulated follow-ups) comes later. *Revised after the
  candidate review, below: plan, then "go ahead".*
- **Verbatim or skip**: a task prompt is exactly what the owner typed, with
  redactions only; one that cannot stand alone is not used.
- **Hidden tests decide**, not the model's own test (a real prompt rarely asks
  for one): the real fix commit's test where it has one, otherwise one written
  for the task and reviewed by the owner. The suite must stay green.
- **Guard-rail scope**: no lockfile, env, CI or out-of-package edit, under file
  and line ceilings; the diff is recorded, not graded.
- **Product repos only** (LFCbot, KaneEnabler, ASoHaV); a pilot of about 12.
- A real-prompt task runs with the repo's instruction file exactly as it was at
  its base commit, because that is what the owner's agent saw; this settles the
  instruction-file question above for this track only.

**Built:** the harness support (`grading: "acceptance"`, `scope: "guardrails"`,
`acceptance.dir`, `acceptance.solution`, `-TaskManifest`/`-ResultsDir`; guarded
by `tests/test-acceptance-grading.ps1`), and in the private repo a collector and
reports: 23 candidate openers in sessions that ended in a commit (LFCbot 17,
ASoHaV 6, KaneEnabler 0).

**Candidate review (2026-10-04): no opening prompt is a "change the code"
request.** The owner's openers are research, planning, reviews and operations
questions (deployment, SSH, a VM's updates, migrations); code is asked for later
in the session, once a plan or handoff exists, which is the `/plan` → execute
loop the north star describes. Of the openers, three are documentation edits
(tidy an `AGENTS.md`, add a working-convention rule to it, add Terms of Service
and Privacy Policy pages), kept with simple file checks; the rest are questions
with no code change to grade, or depend on context outside the repo. So the
owner revised the single-turn decision: **a task is the real opener plus one
fixed "go ahead" turn** (`opencode run --session` continues it), graded on the
end state. Open design question before building it: the features those plans
led to were large (sealed products took about ten commits over five days; the
UI review round two releases of 24–27 files), so a fair task needs a small
plan → implementation pair and hidden tests that check behaviour through an
interface the opener or a committed spec fixes, not the real fix's internals.

**Owner decisions on the plan tasks (2026-10-04):** both kinds.
- **Small work packages** after a committed contract or plan, graded by hidden
  tests against the names the contract fixes. ASoHaV's slice contracts and their
  1–5-file work packages are the model.
- **The real large features** (multi-card input; exact printings with Mana Pool
  links), rated by the owner against a short checklist and reported separately.

The three documentation tasks run first.

**Pilot 1 (2026-10-04): the three documentation tasks, one run each.** Each
hidden check passed `-DryRun` first: it fails on the base and passes on the
owner's real fix, with LFCbot's full suite (83–125 tests) green at every base.

| task | `qwen3.6` | `qwen3.5:9b` |
|---|---|---|
| `real-01` | PASS | PASS |
| `real-02` | FAIL | FAIL |
| `real-03` | PASS | FAIL |

- **`qwen3.6` 2/3, `qwen3.5:9b` 1/3.**
- `real-02` asks to bring an agent-instructions file up to date. `qwen3.6` added
  the two new environment variables but not the five newer modules; `qwen3.5:9b`
  added neither.
- On `real-03`, `qwen3.5:9b` misread the request. It linked the platform's own
  policies instead of writing the bot's: a failure only a real, unspelled-out
  prompt exposes.
- `real-01`'s first-run check failed both models' correct answers because it
  was tuned to the owner's own wording. It was revised, and both passed on the
  re-run. Since then, every hidden check that judges wording must also accept
  other correct phrasings and reject near-misses, checked by a calibration
  script in the private repo, not only fail on the base and pass on the real
  fix. The superseded rows stay under their own fingerprint
  (`tests/results/README.md`).

**Runs 2 and 3 (2026-10-04 15:14 – 15:46), current checks only:**

| task | `qwen3.6` | `qwen3.5:9b` |
|---|---|---|
| `real-01` | 3/3 | 3/3 |
| `real-02` | 1/3 | 0/3 |
| `real-03` | 3/3 | 0/3 |
| **total** | **7/9** | **3/9** |

- The pilot's split held: both seats handle the small, clearly stated rule
  (`real-01`); "is this file up to date" is hard for both (`real-02`), because
  it means comparing a file against the code; and the 9b never wrote the
  pages `real-03` asks for. Its run 2 edited an env template (denied by the
  guard rails) and a deployment doc instead; run 3 changed nothing.
- `real-01`'s two first-run rows under the superseded check are not counted.

**Run 4, the first with the plugin installed (2026-10-05 20:57 – 21:03):
`qwen3.6` 0 of 3.** The runs came straight after the five long
`compaction-daily` runs. They were short (1–3 minutes) and the model fumbled:
- `real-01` added the rule, then deleted its own addition;
- `real-02` hit one failed edit, then declared the file up to date;
- `real-03` wrote one of the two pages.

The plugin had no part in them: no compaction, no rewrite, and its idle
continue is off under the harness. It was nonetheless the only recorded
difference from runs 1–3, so it was tested directly.

**A/B, the plugin on and off (`OPENCODE_PURE=1` skips external plugins for
one process), 21:13 – 21:31.** `real-01` and `real-03`, alternating, twice
each: **8 of 8 PASS, 4 with the plugin and 4 without.**
- So the plugin is cleared, and run 4 was a bad draw: unexplained, possibly
  the long sessions just before it.
- These are diagnostic runs. They are in the private repo
  (`results/plugin-ab/`), not in `real-tasks-public.tsv`, which keeps run 4's
  three rows.

**Two-turn support (built 2026-10-04).** A task's `followUps` are fixed later
turns, sent with `opencode run --session` into the same session and transcript
and graded on the end state (`tests/test-follow-ups.ps1`). In the one local
plan-first session, the owner's real go-ahead was a one-word approval that came
after a scope check, so a short approval is the realistic follow-up.

**ASoHaV's work packages are not on this PC.** None of the 44 local ASoHaV
prompts starts one. All 67 work-package and contract commits (2026-09-22 to
09-24) name one Claude Code on the web session in their `Claude-Session`
trailer. The owner will try to bring that session here (or copy its messages
out) so the verbatim rule can hold. That one session drove nine slices, so its
kickoff messages probably each cover several packages.

**Checklists for the two large features: drafted 2026-10-05, awaiting the
owner's review** (private repo, `reports/large-feature-checklists.md`). There
are 10 observable-behaviour items per feature, 5 of them *must*, each with its
source, the base and done commits, and a verdict rule: PASS if every *must*
holds, PARTIAL if at least half do.
- **Smaller than thought.** Each feature was one commit plus one or two
  follow-ups within a day.
- **Exact printings** has a verbatim opener that stands alone (82 words).
- **Multi-card input** doesn't. Its opener points at a research document the
  owner pasted in a later reply, so the owner decides whether to combine the
  two, make it research-only, or drop it.
- **Rating takes a manual session.** It needs the model's branch running
  against a Discord test server, and a live Mana Pool link needs the owner's
  API key.

**Next:**
- Collect that session and see how its kickoff messages map to packages.
- The owner reviews the checklists.
- Then the plan tasks' pilot.

**TODO:**

- Add the owner's **work Codex sessions** (an export from work) to the style
  statistics: read locally, style-only, never committed.
- The other Codex folders on the desktop (dev-docs, `M:\Projects`, ASoHaV,
  setup folders) stay style-only until the owner marks them personal; LFCbot's
  are personal (2026-10-04).
- Optional: the claude.ai data export, if chat history matters.
- Later: a multi-turn design, informed by how the owner corrects agents.

### Hosted seats on the real tasks: the first batches (2026-10-06/07)

Five [OpenCode Go][opencode-go-docs] seats ran the private real tasks, one run per task, on opencode 1.18.34 with
the compaction plugin installed. The tasks:
- **3 LFCbot tasks** (`real-01`–`03`), each the owner's own prompt, graded by hidden tests.
- **12 work-package tasks** (`wp-*`). Each is an orchestrator's real brief for one slice of the A Story of Heroes
  and Villains V0.6 revision, graded by that slice's contract tests.

Rows are in `tests/results/real-tasks-public.tsv`; what they cost is in `docs/costs.md` → "What a pass costs".

| seat | LFCbot | work packages | not graded |
|---|---|---|---|
| Qwen3.7 Plus | 2/3 | 11/12 | — |
| DeepSeek V4 Pro | 3/3 | 7/7 | 5 refused at the plan limit (1 mid-run) |
| GLM-5.2 | 3/3 | 9/9 | 2 timed out, 1 refused |
| Qwen3.8 Max | 3/3 | 6/6 | 1 refused mid-run, 5 not run |
| Kimi K2.7 Code | 3/3 | — | 12 refused at the plan limit |
| *qwen3.6 (local)* | *9/16 (five batches)* | *7/11 (45-min limit)* | *1 timed out at 45 min* |
| *qwen3.5:9b (local)* | *3/10* | *4/8 (45-min limit)* | *4 crashed (context overflow)* |

- **47 of 49 graded hosted runs passed.** The batches stopped when the Go plan's weekly limit was reached
  (`docs/costs.md` → "Usage limits as observed"). Hosted cells are one run each, so these are signals, not
  standings.
- **The local seats ran the work packages with a 45-minute limit,** qwen3.6 on 2026-10-07 and `qwen3.5:9b` on
  2026-10-09 (below, "Local qwen3.6 on the work packages" and its follow-up). The qwen3.6 cell is the first
  round; a second run of its failures is in the follow-up.

**What the failures show** (transcripts in the private repo):
- **No hosted run compacted.** Go serves these models with up to 1M tokens of context. The biggest request was
  119k tokens, about twice what the local seats hold before they compact. The local failure this roadmap has
  chased (losing the task after a compaction) never arose. The hosted runs avoid it rather than survive it.
- **The local LFCbot failures weren't context failures either.** The runs that recorded it peaked at 11–16k
  tokens. Two other patterns show instead:
  - **Stopping early and claiming success.** On 2026-10-05 qwen3.6 failed all three tasks in 3–5 steps each,
    against 7 of 10 the day before. One run added the requested section, re-read the file, deleted its own
    addition as a "duplicate" and reported success. One stopped after a failed edit without retrying. One wrote
    one of the two pages asked for. The plugin was ruled out earlier (8 of 8 with it switched off), so this is
    run-to-run variance. It's the kind a single run hides.
  - **Incomplete surveys.** `real-02` asks for a document brought up to date with the repo. The hidden tests
    check that the newer modules and environment variables are covered. It failed for qwen3.6 3 times in 4,
    qwen3.5 3 in 3 and Qwen3.7 Plus once. Apart from one early stop, each failure missed some of them.
  - **qwen3.5:9b misread `real-03`.** It wrote deployment notes instead of the two pages asked for, and once
    edited `.env.example`, which the guard rails deny.
- **`wp-5b` is the hardest work package.** Qwen3.7 Plus failed two of its hidden tests, GLM-5.2 timed out
  still working, and DeepSeek was refused before finishing. The two rules Qwen3.7 Plus missed are input checks
  that the slice's contract doc comments imply but don't state. So the task partly measures reading between the
  lines. The owner kept both tests in the grade (2026-10-07).
- **Writes outside the worktree go unchecked.** One GLM run wrote a test config to a temp folder outside the
  worktree while fighting the test setup. The guard rails check only the repo's diff. Harmless here, but it's a
  gap (TODO below).

**Next:**
- ~~Run the local seats on the 12 work packages.~~ qwen3.6 done 2026-10-07, `qwen3.5:9b` 2026-10-09 (below).
- Fill the hosted gaps (Kimi 12, DeepSeek 5, Qwen3.8 Max 6, GLM 3) when the plan's limits allow. The batch now
  checks the plan-wide meters first.

**Done (2026-10-07): writes outside the worktree are now flagged.** `test-tasks.ps1` reads the transcript's
file-tool calls and records each one outside the worktree in the run JSON's `outsideWrites`, with a warning. It
isn't graded. Shell commands aren't parsed, so a redirect in a bash call still goes unseen.

**Decisions taken after these batches (owner, 2026-10-07):**
- **`wp-5b` keeps both implied-rule tests in the grade.**
- **Orchestrator shortlist: DeepSeek V4 Pro and Qwen3.7 Plus.** They are the two cheapest seats, and they passed
  17 of 18 shared tasks. Everything measured so far is implementation. Planning a feature, splitting it into
  briefs and reviewing an implementer's work is untested. The planning turns of `stretch-v06` are where to test
  it, once a Go budget is set.
- **The first hybrid is built in OpenCode** (per-agent model pins, the existing harness). Hermes Agent is
  researched and parked (below).
- **The Go budget is deferred.** No hosted batches until the owner sets one. The batch's plan-wide meters block
  any that would go over in the meantime.

**The question everything else waits on:** do the local seats pass the work packages? If qwen3.6 passes most
of them, the split is proven (hosted orchestrator, local implementers on short file-scoped briefs), and the work
on surviving long local sessions can drop in priority. If it doesn't, the briefs must get smaller, or the local
seats review and assist rather than implement. Fixing the server for a second implementer GPU depends on that
answer too. **First answer (2026-10-07), below: most of them, given time.**

#### Local qwen3.6 on the work packages (2026-10-07)

`qwen3.6:35b-a3b-coding` ran the 12 work packages once each, in small batches through the day. The setup was
the same as the hosted batches: opencode 1.18.34 with the compaction plugin, 64k context. The difference is the
time limit. A local run's time limit was 45 minutes (`-RunTimeout 2700`), against 15 for the hosted runs. The
owner chose 45 because a local model that gets the right answer more slowly is a result worth having. Every run
records its elapsed time, so both limits can be read off the same runs: a run that finished within 15 minutes
ends the same under either. From the second batch on, the run JSONs record the limit itself (`runTimeoutSec`).

| | qwen3.6 (local) | Qwen3.7 Plus (hosted), same 12 |
|---|---|---|
| passed within 15 min | 3 of 12 | 11 of 12 |
| passed within 45 min | 7 of 12 | 11 of 12 |
| time per pass | 7–28 min, median 16 | 1–7 min, median 3 |
| time for the whole set | about 3 h 4 min | 49 min |
| cost | $0 | $1.17 ($0.11 per pass) |

- **Every pass beyond 15 minutes compacted.** Four of the seven passes (`wp-3a`, `wp-3b`, `wp-4a`, `wp-5a`, 16–28
  min) compacted once or twice and finished correctly. Each compaction loses the prompt cache, and each later step
  pays for re-reading the whole context. That costs time, not the task. Before the compaction plugin
  (2026-10-05), losing the task after compacting was the main local failure (above, "Context overflow"). On
  these runs it never happened. Four runs aren't proof, but it's the first evidence that the plugin carries the
  task through. (Found 2026-10-09: `wp-3b` lost its brief to a front-drop *before* its first compaction, asked
  what to do, and got the task back from the compaction summary. More in the follow-up below.)
- **The three passes under 15 minutes never compacted** (`wp-9a`, `wp-0a`, `wp-1a`, 7–12 min). On the seven
  tasks both passed, qwen3.6 took 3–10 times as long as Qwen3.7 Plus (median 5×).
- **Five failures, four different ways:**
  - **`wp-5b` ran out of time while still working.** It compacted three times, kept editing after each, and was on
    its last file at 45 minutes. Every hosted seat that tried it also failed or didn't finish.
  - **`wp-6a` stopped after two correct edits.** Its last message was the made-up line "[Response interrupted by
    admin]". Nothing interrupted it.
  - **`wp-6f` stopped after reading 11 files,** with no edit and no closing message.
  - **`wp-7a` hit the output limit.** After reading five files it produced 8,192 tokens in one step without
    finishing a text or tool call (`outputCapHit`). That's the configured `limit.output`.
  - **`wp-2b` lost its brief.** It read three large files in one step, and the next request went past the 64k
    context: the front-drop (above, "Context overflow").

  Three of the five (`wp-6a`, `wp-6f`, `wp-7a`) stopped with work undone, not with wrong work. In one window the
  owner would answer that with "keep going". The "check your work" variants of the LFCbot tasks (`real-01c`–`03c`)
  test whether one fixed follow-up recovers it.
- **A local-first split would have cost half as much.** Run qwen3.6 first and hand only its five failures to
  Qwen3.7 Plus, and the set ends at 11 of 12, the same as Qwen3.7 Plus alone. Go would bill $0.63 instead of
  $1.17, and the work would take about 3½ hours instead of 49 minutes. This assumes something notices each
  failure. Here the hidden tests did; in real use it would be the orchestrator's review, whose cost isn't
  counted.
- **One run per task.** These are signals, not standings. The LFCbot runs showed qwen3.6 swinging from 7 of 10
  to 0 of 3 between days.

**What this changes:** the split looks workable for time-tolerant work. The hosted orchestrator plans and
reviews, the local seat implements, and the hosted seat takes over what the local one leaves unfinished. The
local work that matters most is now stopping early, not losing the task. Next:
- the "check your work" pair, on the LFCbot tasks first;
- a second qwen3.6 run of the four failures that weren't timeouts, to tell variance from a pattern;
- `qwen3.5:9b` on the same 12;
- a decision on raising qwen3.6's `limit.output` above 8,192 (`wp-7a`). That would start a new era for its rows,
  so it waits until these runs are in.

All four ran on 2026-10-09 except the `limit.output` decision (next section).

#### Follow-up runs (2026-10-09)

**"Check your work" didn't change the outcome.** The three LFCbot tasks ran once with and once without a fixed
second turn asking the model to re-read the request, compare it with its changes and fix what's missing
(`real-01c`–`03c`). qwen3.6 passed `real-01` and `real-03` both ways and failed `real-02` both ways. The
follow-up added 2–9 minutes a task. On `real-02` it changed the failure without fixing it: alone, the model
called the document "already up to date and clean" and changed nothing; asked to check, it made two small fixes
and still missed the newer modules the hidden tests look for. A generic check doesn't make up for an incomplete
survey.

**qwen3.6's four non-timeout failures, run again:**

| task | run 1 (2026-10-07) | run 2 (2026-10-09) |
|---|---|---|
| `wp-6a` | stopped after two edits | **passed** (32 min, one compaction) |
| `wp-6f` | stopped after reading | stopped after "Now I have everything. Let me implement all changes:" and one edit |
| `wp-7a` | output cap | ran the tests, wrote out exactly what to fix, and stopped (37 min) |
| `wp-2b` | lost its brief | lost its brief the same way |

- **`wp-6a` was variance.** Over both rounds qwen3.6 has 8 passes in 16 work-package runs.
- **Stopping with work undone is the pattern.** Four of qwen3.6's eight work-package failures end that way
  (`wp-6a` once, `wp-6f` twice, `wp-7a`'s second run), and in the two latest the model had just said what it
  would do next. A fixed "check your work" turn isn't the answer; something that notices the stop and says "keep
  going" might be. The compaction plugin
  already does that, but only after a compaction and never under `opencode run`.
- **`wp-2b` is deterministic.** Both runs read the same three files in one step (~159k characters), overflowed
  64k, and asked "You've shared two files but haven't specified a task" (`qwen3.5:9b` crashed on the same
  read). The harness flagged the first run's drop and missed the second: Ollama still had the first run's
  identical prompt cached, which looked like a cache hit. Run JSONs now also record `askedForTask`, the model's
  own question (`AGENTS.md` → `test-context-events.ps1`).
- **A compaction can give a lost task back.** `wp-3b` (2026-10-07) lost its brief the same way, but its request
  was then over the compaction threshold (57,344). opencode compacted, building the summary from its own history
  (tool outputs pruned, so the request fit), which still had the brief; the run carried on and passed. `wp-2b`'s request stayed under the
  threshold, so nothing rescued it. Re-sending the original request when the model asks for its task would do
  on purpose what the compaction did by luck.

**`qwen3.5:9b` on the 12 work packages:**

| | qwen3.5:9b | qwen3.6 (first round) |
|---|---|---|
| passed within 15 min | 4 of 12 | 3 of 12 |
| passed within 45 min | 4 of 12 | 7 of 12 |
| time per pass | 2–14 min | 7–28 min |
| crashed (context overflow) | 4 | 0 |

- **Fast when it works.** All four passes (`wp-9a`, `wp-0a`, `wp-1a`, `wp-6a`) finished within 15 minutes;
  `wp-0a` took under 2. It passed `wp-6a` in 4.5 minutes, the task qwen3.6 failed once.
- **A third of the set crashed.** `wp-2b`, `wp-3b`, `wp-4a` and `wp-7a` each ended in "No user query found in
  messages", the template's answer to a front-drop (above, "Context overflow"). Those runs have no row, and they
  count against it.
- **Its graded failures left the code broken.** In all four (`wp-3a`, `wp-5a`, `wp-6f`, `wp-5b`) the suite was
  red: test files that no longer loaded, or hidden tests failing. In three it stopped without a closing message,
  soon after a failed edit or a test or typecheck run; `wp-5b` worked 39 minutes through five compactions and stopped mid-debugging with
  three hidden tests failing.

**Across both local seats,** 8 of the 12 work packages passed at least once (`wp-9a`, `wp-0a`, `wp-1a`, `wp-3a`,
`wp-3b`, `wp-4a`, `wp-5a`, `wp-6a`). `wp-2b`, `wp-5b`, `wp-6f` and `wp-7a` never did.

**Next:**
- ~~**Owner's decision:** a conditional "keep going".~~ Approved and built 2026-10-09 as `test-tasks.ps1
  -NudgeOnStop` (`AGENTS.md` → `test-stop-nudge.ps1`). The trigger was measured on every graded run before
  it was written:

  | how the last step ended | passed | failed | nudged with |
  |---|---|---|---|
  | asked what the task is | 0 | 6 | a note plus the original prompt |
  | announced a next step | 1 | 16 | "keep going, or confirm you're done" |
  | empty (no text, no tool call) | 34 | 76 | the same |
  | any other text | 176 | 101 | nothing |

  Empty endings are mixed because `qwen3.5:9b` often ends a finished run silently, so the run JSON records which
  kind each nudge was and they can be judged apart. The runs go to their own folder in the private repo, which
  is marked `ASSISTED`. A rescue rate worth having comes before any change to the daily setup.
- **The `limit.output` decision for qwen3.6** (`wp-7a`'s first run). One cap hit in 16 runs; the second run of
  `wp-7a` didn't hit it. Not urgent.
- **Hosted gaps** wait for a Go budget.

**Decision (owner, 2026-10-10): leaving OpenCode must stay cheap.** The preferred daily platform is "a chat
window/CLI", not necessarily OpenCode. Since then:
- **OpenCode is the measuring instrument, not the product.** Findings about models, Ollama and failure patterns
  are kept client-neutral.
- **Its specific code lives in one adapter, `tests/agents/opencode.ps1`.** That covers how a run starts and
  continues, how its transcript reads, and its version and config. The grading and every analysis read neutral
  events instead (`AGENTS.md` → `test-agent-adapter.ps1`). Another agent is one sibling file, and its results a
  new era.
- **New daily-use features that would not survive a client switch don't go into the OpenCode setup.** The
  `-NudgeOnStop` result is the first test: if it's worth having day to day, it belongs in whatever drives the
  chosen window, as a client-neutral wrapper that watches the last message. A larger OpenCode plugin is not the
  place.
- **Picking that window is open.** Hermes Agent (below) is one candidate with a headless JSON mode. Picking one
  also gives the adapter its second real client.

#### Hermes Agent: researched 2026-10-07, parked

[Hermes Agent][hermes-agent] (Nous Research, MIT) is an open-source agent with a CLI/TUI, messaging front ends and
a headless mode. This is from its docs as read on 2026-10-07; nothing was installed or run.
- **The architecture fits the north star on paper.** Its `delegate_task` subagents can run on a different model
  and endpoint from the main session: one delegation model shared by every child, not one per child.
  [The delegation docs][hermes-delegation] pitch exactly the hybrid: pinning the delegation model to an
  inexpensive model "while your main session stays on a frontier model keeps the planning quality where it
  matters and cuts spend where the volume is".
- **The providers fit.** Any OpenAI-compatible endpoint works, which covers Ollama and the Go endpoint. It doesn't
  need Nous's own Hermes models.
- **It could be benchmarked.** `--format stream-json` emits a JSONL event transcript for a `-q/--query` run, and
  `-w/--worktree` starts in its own git worktree ([CLI reference][hermes-cli]). That's enough for an adapter in
  the harness.
- **Risks:**
  - [A 64k context minimum][hermes-faq]: qwen3.6 just qualifies, node3's `qwen3:8b` doesn't.
  - 70+ tools whose schemas may ride in every request: the 46k-token preamble problem again, unless `--toolsets`
    is restricted.
  - Compression starts at 50% of the context.
  - The default approval mode spends a model call per risky command.
  - Approvals inside subagents are undocumented.
  - Releases every few days, so a pinned version and a new era.
- **The smallest first experiment, if it's picked up:**
  1. Install the CLI only and point it at local qwen3.6 with an explicit 64k context, minimal toolsets and manual
     approvals.
  2. Measure the fixed prompt size with "Reply with exactly: OK".
  3. If that's small enough, run one benchmark task headlessly.

  It needs no Go spending.

[opencode-go-docs]: https://opencode.ai/docs/go
[hermes-agent]: https://hermes-agent.nousresearch.com/
[hermes-delegation]: https://hermes-agent.nousresearch.com/docs/user-guide/features/delegation
[hermes-cli]: https://hermes-agent.nousresearch.com/docs/reference/cli-commands
[hermes-faq]: https://hermes-agent.nousresearch.com/docs/reference/faq

### Node3's `qwen3:8b` "liar mode" was never liar mode: the runs never reached Ollama (corrected 2026-09-21)

**Superseding the context-budget explanation previously recorded here.** That
explanation was wrong, and so was the config change made on the strength of it.

Node3's `qwen3:8b` was recorded as having liar-moded (0 write calls, describes
the change instead of making it) on **6 of 6 real task-veracity runs across 3
tasks in 2 repos** — `kane-01` ×2, `lfc-01` ×1, `kane-02` ×3 — while desktop's
identical tag was 9/9 real writes. The pattern holding across a third,
unrelated task is what made task-specific bad luck implausible and pointed at
a per-host cause. That much was sound. The cause identified was not.

Re-reading the raw transcripts: **all six are 307 bytes and contain exactly one
event.**

```json
{"type":"error","error":{"name":"APIError","data":{"message":
"Cannot connect to API: Unable to connect. Is the computer able to access the url?",
"metadata":{"url":"http://NODE3_IP:11434/v1/chat/completions"}}}}
```

No request ever reached Ollama on node3. A context-budget bug requires the model
to *respond* — to receive a truncated prompt and answer without the tool
scaffold. These never got a response at all, so they are not evidence about
context, about tool-calling, or about this model in any direction.

Three independent signals in the data already said so and were missed:

- **All six carry `opencodeExit=1`; every desktop row carries `0`.** Real liar
  mode exits 0 — the model answered, it just answered in prose.
- **Elapsed time clusters at 191.9–195.3s across all three tasks.** A uniform
  ~192s is a connect timeout, not three different tasks each reasoning its way
  to the same wrong answer.
- **The probe passed on this host the day before** (`AGENTS.md`, 2026-09-20:
  `qwen3:8b` on node3, 62.3s, real `write_file` call). The endpoint worked, then
  stopped answering. That is availability, not configuration.

**So node3's liar-mode denominator is 0, not 6 — and not the 3 that `CHANGELOG.md`
implied by attributing the `kane-02` subset to that task's stale `setup` step.**
That stale step was real and is fixed, but it is not what these runs hit: the
same single-`APIError` signature appears on `kane-01` and `lfc-01`, which never
had that setup step. **node3 has no capability data at all yet, good or bad.**

**The `limit.context` bump to 32768 is reverted** (back to the 16384 onboarding
default) because the evidence behind it evaporated. The preamble arithmetic it
relied on is still worth knowing and still unresolved: 16384 minus the 4096
output reserve leaves ~12,288 tokens of input budget against a measured
14,364-token preamble, so *if* node3 really serves 16384, this seat is over
budget before the task prompt. That makes measurement urgent; it does not
justify a second guess. Node3 has no context-baking step the way desktop's
`startup.ps1` (`$contextModels`) does — onboarding just did a raw `ollama pull`.

Before node3 rejoins the rotation, in order:

1. `curl http://NODE3_IP:11434/api/tags` — confirm it answers at all.
2. `curl http://NODE3_IP:11434/api/show -d '{"name":"qwen3:8b"}'` — read the
   `num_ctx` Ollama actually serves; set `OLLAMA_CONTEXT_LENGTH` on node3's own
   service (restart required) and set `limit.context` to what it then reports.
3. `curl http://NODE3_IP:11434/api/ps` with the model loaded — closes the
   long-open "node3 usable VRAM never measured" to-do above.
4. `tests/test-toolcalls.ps1 -Model qwen3:8b -OllamaHost http://NODE3_IP:11434`
   — confirm the seat still passes as it did on 2026-09-20.

**The harness bug that produced this is fixed.** `tests/test-tasks.ps1` bailed
out only on its `-1` timeout sentinel, so any *other* non-zero exit fell through
to the writes gate and was stamped "the old liar mode. This run does not count."
It now treats any non-zero exit as infrastructure: a `FAIL`ed run, an
`_INFRA_`-tagged transcript, and **no summary row**, because a run that never
reached the model measured nothing. `tests/run-tasks-batch.ps1` also checks every
host it is about to drive (`/api/tags`) before starting, and refuses to run
against one that is not answering — including the small-model host, which
`profiles/dev-node3.sh` still points at the dead server.

The standing lesson is narrower than "check your config": **an exit code the
harness does not understand became a capability finding about a model.** When a
whole cell fails identically, read one raw transcript before writing down why.

## Desktop dev environments (landed)

- [x] Desktop local service stack (`desktop/docker/docker-compose.yml` — Postgres 16 + Redis 7, loopback-only, `docker-stack.ps1`).
- [x] Read-only `postgres` OpenCode MCP enabled against the local Postgres (`.secrets/postgres-dsn`).
- [x] Shared CPU dev base (`dev/docker/dev.dockerfile` → `dev-base:1` via `docker-base.ps1`).
- [x] Devcontainers for LFCbot and asohav (asohav bakes Playwright chromium + deps).
- [x] `/sandbox` + `/devcontain` OpenCode commands; `docker-sandbox.ps1`.
- [x] `DEV_DOCKER_STACK` profile flag → `startup.ps1` auto-`up`; `.wslconfig` `memory=12GB`.
- [ ] **Revisit the local Postgres before it becomes permanent**: once a real project actually lands on Postgres (e.g. asohav `pg`, a managed DB, or Render/Supabase/Neon), decide whether it should be the desktop stack, the server, or cloud-hosted. The desktop stack is here to unblock local dev, not to become a production target. If a future project needs Postgres in *production*, prefer managed; keep the desktop instance optional and documented.
- [ ] Fold the sandbox/devcontainer workflow into `docs/profiles.md` per-profile docs once it settles.

## Sprinkled TODOs

- Embedding models (`nomic`, `mxbai`) already on desktop — decide whether to move them to the server after upgrade (they're 0.5–4 GB of disk).
- `docs/troubleshooting.md` — recheck the VRAM math and the `api/ps` numbers after the upgrade exercise.