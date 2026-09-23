# Target setup (the "server is back" end state)

What the fleet should look like once the server POSTs, derived from how the
owner actually wants to work (recorded 2026-09-22). This is the concrete shape
of the north star in [roadmap.md](roadmap.md) → "End goal". It is a plan, not
a description of what runs today; [start-here.md](start-here.md) is today.

## Requirements (from the owner, 2026-09-22)

- **Goal: offload, not replace.** Replacing Claude Code / Codex outright is
  only realistic if local agents can take *longer* and still land the same
  quality. The committed targets are:
  - **(B)** local hardware does the routine implementation work while a cloud
    model plans and does the hard parts, and/or
  - **(C)** a fully local path that works offline or on private code.
- **In the loop for planning only.** Interactive back-and-forth until a
  technical plan is approved. After that, implementation runs unattended and
  may be slow. Slow planning is also acceptable if the quality holds.
- **Task size: as large as the hardware can handle.** Full-stack web work,
  plus the personal projects in this repo's benchmark (KaneEnabler, LFCbot,
  ASoHaV). **TypeScript first.** .NET/C# later, not a priority.
- **No planning around gaming.** If the desktop or node3 is in use, no workers
  run on it. Optimising for that case is future work.
- **LAN only for now.** SSH access from Terminus already exists but is not
  documented in this repo (see "Gaps" below).
- **Current hardware only.** Upgrade ideas go in
  [hardware.md](hardware.md) → "Upgrade candidates"; nothing here depends on
  them.
- **Winners first, rigor later (2026-09-23).** Pick winners per role on thin
  samples; the N=10-per-cell backfill and further task authoring wait until a
  working setup lands and earns deeper measurement. A miss reads as "wrong job
  for this model", tracked in role-fit columns, not just pass@1.
- **TypeScript only until first real use lands.** No .NET/C# benchmark tasks
  before then.
- **Server-centric with overflow.** The dispatcher and the main executor live
  on the server once it POSTs; desktop and node3 take overflow attempts when
  available (see Machine roles for the CPU asymmetry behind that split).
- **Hosted calibration unscheduled.** The OpenCode Go key is available whenever
  the owner wants a frontier oracle arm.

## What the data says local models can do (as of 2026-09-23)

Numbers live in `tests/results/README.md` (corpus inventory) and the
per-attempt table plus pass audit in
[implementation-tasks.md](implementation-tasks.md) → "Gap-fill batch review";
what follows is the reading, not a second copy of the tables.

- **Guided-repair pass@1 now separates the field.** The 8 executor candidates
  have first task data (41 gap-fill runs, all post-fix harness): the desktop
  seats pass where `qwen3:8b` mostly didn't, led by `qwen3.5:9b`, while
  node3's small candidates do not execute (`lfm2.5:8b` 0/8, all zero-write;
  `ministral-3:8b` 0/5). All 17 gap-fill passes audited non-hollow, with
  behavioural `failsOnOld`. Timeout counts come from the per-attempt table —
  timeouts are the largest failure class for the 18–25 GB offloading seats
  under the 900 s cap, so their capability is unmeasured, not low.
- **The old 7% pooled rate is retired.** It mixed harness eras (pre/post
  INFRA split, pre/post output-cap fix) and is superseded by the per-seat,
  per-attempt numbers above.
- **`edit` succeeds 85 of 783 times (11%) in the 2026-09-22 corpus. 79% of
  the misses target code that is not in the file**, and only 0.3% are
  whitespace near-misses. 94% of `read` calls pass a small `limit` (20 lines
  most often), and 30% of edits hit a file the model never read. The models
  edit from imagination, not from what they read. (The gap-fill passes
  themselves show 0–3 failed edits each — the loop is a property of weak
  seats, not of the harness.)
- **Writing a test that fails on the old code is the gate local models miss
  most** (`failsOnOld`), even when their source fix is right.

What follows from that: a local model *must not* be asked to plan, design
tests, or judge its own completion. Give it a small, precisely scoped change
with the acceptance test already written, and grade it mechanically.

## The shape: plan with a strong model, execute locally, gate mechanically

```
 you ──▶ PLAN (interactive)  ──▶  work orders  ──▶ EXECUTE (unattended, slow) ──▶ GATE ──▶ REVIEW ──▶ you merge
         Claude Code / Codex       one file per     N attempts across the fleet,   scope     review-gate
         (B), or the server's      task: scope,     each in its own worktree       suite     (different-
         best local model (C)      acceptance test,                                 fails-    family seat)
                                   prompt                                           OnOld
```

1. **Plan (you, in the loop).** Mode B: Claude Code or Codex, fast and high
   quality. Mode C: the server's main model, slower. Output is not prose. It
   is a set of **work orders**. Each one is shaped like a
   `tests/tasks/manifest.json` entry: target repo and branch, `allowFiles`,
   `testCmd`, the prompt, and an **acceptance test the planner writes and you
   approve**. The test must fail on the current code, which is checked before
   the order is queued. That moves the step local models fail most
   (`failsOnOld`) onto the strong model. A large feature becomes many small
   orders, which is how "as large as the hardware can handle" gets handled:
   by decomposition, not by a bigger context.
2. **Execute (unattended).** A dispatcher, grown out of `test-tasks.ps1` +
   `run-tasks-batch.ps1`, runs each order as **N independent attempts** spread
   over whichever hosts are free. Each attempt gets its own worktree, and the
   first attempt that passes the gate wins. This is the "take longer, same
   quality" lever: local attempts cost nothing but time. After N misses the
   order goes back to the planner (B) or to you, never silently dropped.
3. **Gate (mechanical).** The existing gates, unchanged: scope (only
   `allowFiles` touched), suite green, the planner's acceptance test now
   passing, plus typecheck where defined. A model's claim of success is never
   an input. The 2026-09-22 `asohav-01` run is why: it said "tests now verify
   the correct behavior" having written no test.
4. **Review.** The review-gate seat (different model family, see
   [review-gate/](review-gate/README.md)) reads the winning diff. The result
   is a branch plus PR. You merge.

## Machine roles

| Machine | Role | Seats (provisional) | Why |
|---|---|---|---|
| **Server** (4070 Ti Super 16 GB CUDA, 32 GB, always on) | **Main executor model host + dispatcher.** Serves the best executor model to every worker 24/7 and runs the queue. In mode C it is also the local planner. | Winner of the executor batch, most likely a 30B-A3B MoE coder spilling into RAM (`qwen3-coder:30b-a3b`, `north-mini-code-1.0`, `laguna-xs-2.1`, …) | The only machine built to be a server. CUDA opens llama.cpp-CUDA/vLLM. 32 GB RAM with no WSL cap or desktop apps is the best host for MoE spill. **CPU asymmetry:** its 3700X (8c/16t) is the weakest CPU in the fleet — it serves models and runs the queue, but CPU-bound work (worktrees, `pnpm install`, vitest) defaults to node3/desktop. |
| **node3** (3080 10 GB CUDA, 5950X 16c/32t, 32 GB, always on once sleep is disabled) | **Worker: parallel attempts + CPU-heavy test runs.** Runs worktrees, `pnpm install`, vitest, typecheck. Serves a small executor for extra attempts and embeddings. | `qwen3:8b` today; Q4 `qwen3.5:9b` trial next (only strong seat small enough for 10 GB). `ornith:9b` passed only the easiest task; `lfm2.5:8b` / `ministral-3:8b` are not executors. `nomic-embed-text` | The 16-core CPU is the best in the fleet: test/build execution is a big share of every attempt's wall-clock, so node3 is where worktrees run. 10 GB caps its served models at ~9B. |
| **Desktop** (6800 XT 16 GB Vulkan, 5800X3D, 32 GB) | **Where you plan and review.** Claude Code / OpenCode run here. When not in use, its GPU adds attempts or hosts the review-gate seat. | Review-gate seat. Overflow executor (gap-fill winner, once chosen) | Vulkan limits the software stack, and it is the machine you game on. Nothing in the pipeline may *depend* on it — but while idle it is a free second executor with a strong CPU. |
| **GTX 1070** (8 GB) | Spare | — | See [hardware.md](hardware.md) → "Upgrade candidates". |

**One front door.** OpenCode (or the dispatcher) should see one endpoint, and
routing to whichever host is up happens behind it. Today that is spread over
four profiles and three provider blocks in `opencode.jsonc`, and it is the
last step, not the first. A routing proxy on the server (e.g. LiteLLM) is the
likely shape, but it only pays off once there are two executor hosts worth
routing between.

## Starting build (Stage 1, agreed 2026-09-23, server down)

The end state above waits on the server; this is what runs now, picked
winners-first off the 105-row corpus (`tests/results/README.md`):

| Position | Seat | Evidence |
|---|---|---|
| Planner (fully local) | `qwen3.6:35b-a3b-coding` (desktop) | Probe PASS 2026-09-23; slowest seat (123 s probe), 3/6 executor record with 2 timeout unknowns — first plans stay small and benchmark-shaped |
| Executor attempt 1 (desktop) | `qwen3.5:9b` Q8, as measured | 5/6, strongest record anywhere; Q8 deliberately (the record was earned on Q8, Q4 is a separate experiment) |
| Executor attempt 2 (desktop, sequential) | `laguna-xs-2.1` | 3/3, non-Qwen weights for attempt diversity |
| Parallel attempt + CPU worker (node3) | `qwen3:8b` | Only tool-reliable seat fitting 10 GB; node3's 16 cores run the CPU-heavy half (worktrees, vitest) |
| Review-side | `nemotron-3.5-lightning` | 3/4, non-Qwen; trials for the empty reviewer seat per the round-3 protocol, auditor duty meanwhile |
| Embeddings | `nomic-embed-text` | Already on both hosts |
| Autocomplete | deferred | No seat until the server is back |
| Dispatcher | manual (owner runs the batch per order) | Until milestone 4 sets N from data |

Out as executors: `ministral-3:8b` (0/7), `lfm2.5:8b` (0/8, all
zero-write), `ornith:9b` (1/7, liar mode 2026-09-23). Planner discipline (from
the data): the planner writes the acceptance test, the test must fail on
current code before the order queues, one file per order — the loop in "The
shape" is unchanged, only the planner's name is filled in.

## Milestones (ordered; each is measurable with the existing harness)

1. **Pick executor models.** Probe the candidates in
   [hardware.md](hardware.md) with `tests/test-toolcalls.ps1`. Run the
   passers through the 8-task batch, 2 reps each, harness unchanged, beside
   `qwen3-coder:30b-a3b`. Node3 runs its small candidates in parallel.
   **Status 2026-09-23: first pass done** (gap-fill batch — all 8 candidates
   have task data; per-attempt table + audit in the "Gap-fill batch review").
   Still owed: the `qwen3` control rematch on the current harness, `qwen3.5:9b`
   to N=3, raised-timeout re-runs for the offloaders, and the unfinished
   `qwen3-coder:30b-a3b` ×8. The N=10-per-cell backfill waits until after
   milestone 5 lands.
2. **Harness fixes as A/B tests.** A local-executor agent prompt ("read the
   whole file before editing it; never put `...` in `oldString`; re-read after
   any miss") and a consecutive-miss cap on edit loops. One variable at a
   time, on the step-1 winner.
3. **Acceptance-test-supplied mode.** A `test-tasks.ps1` variant where the
   task ships the failing test and the model may change only source files.
   Measures the plan/execute split directly. **Expected to be the largest
   single jump**, since it removes the gate local models fail most.
4. **Best-of-N.** Dispatcher runs N attempts across hosts and records pass@N
   as well as pass@1. Set N from the data, not in advance.
5. **First real use (TypeScript, mode B).** Plan a real change in one of the
   benchmark repos with Claude Code, emit work orders, let the fleet execute,
   review, merge. Milestone reached when a multi-order feature lands this way
   with you only in the planning and merge steps.
6. **Server back.** Probe it (it has never run `test-toolcalls.ps1`), move the
   main executor seat and the dispatcher onto it, then try mode C planning on
   its best model.
7. **Later:** a single routing front door, .NET/C# tasks in the benchmark, and
   optimising around gaming/occupied machines.

## Gaps to close before building

- **Terminus SSH access is undocumented.** Record which hosts it reaches and
  where the key lives (not the key itself) in
  [network-topology.md](network-topology.md).
- ~~Free disk and LAN link.~~ Settled 2026-09-22: all hosts are wired, and
  disk is not a constraint. Per-option totals are in
  [hardware.md](hardware.md) → "Network and storage".
- **node3 sleep settings.** Its 2026-09-21/22 mid-batch dropouts were Windows
  sleep, not a fault. Disable sleep before giving it scheduled work.
