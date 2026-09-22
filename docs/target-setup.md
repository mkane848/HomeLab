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

## What the data says local models can do (as of 2026-09-22)

From 54 graded `test-tasks.ps1` runs. The per-run table is
`tests/results/tasks-summary.tsv`, and the transcript analysis that produced
these numbers is under "Edit-reliability analysis across the whole corpus" in
[implementation-tasks.md](implementation-tasks.md).

- **pass@1 is 4/54 (7%)** for `qwen3:8b` + `qwen3:14b`. Tasks are
  single-bug fixes over 2 files of 100–900 lines.
- **`edit` succeeds 85 of 783 times (11%). 79% of the misses target code that
  is not in the file**, and only 0.3% are whitespace near-misses. 94% of
  `read` calls pass a small `limit` (20 lines most often), and 30% of edits hit
  a file the model never read. The models edit from imagination, not from what
  they read.
- **Writing a test that fails on the old code is the gate local models miss
  most** (`failsOnOld`), even when their source fix is right.
- **The agent-trained candidates are untested.** `qwen3-coder:30b-a3b`, a
  fair `devstral` run, and the 2026 releases in
  [hardware.md](hardware.md) have no task data yet.

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
| **Server** (4070 Ti Super 16 GB CUDA, 32 GB, always on) | **Main executor model host + dispatcher.** Serves the best executor model to every worker 24/7 and runs the queue. In mode C it is also the local planner. | Winner of the executor batch, most likely a 30B-A3B MoE coder spilling into RAM (`qwen3-coder:30b-a3b`, `north-mini-code-1.0`, `laguna-xs-2.1`, …) | The only machine built to be a server. CUDA opens llama.cpp-CUDA/vLLM. 32 GB RAM with no WSL cap or desktop apps is the best host for MoE spill. |
| **node3** (3080 10 GB CUDA, 5950X 16c/32t, 32 GB, always on once sleep is disabled) | **Worker: parallel attempts + CPU-heavy test runs.** Runs worktrees, `pnpm install`, vitest, typecheck. Serves a small executor for extra attempts and embeddings. | `qwen3:8b` today. `ornith:9b` / `ministral-3:8b` if they probe well. `nomic-embed-text` | The 16-core CPU is its best AI-adjacent asset: test/build execution is a big share of every attempt's wall-clock. 10 GB caps it at ~9B models. |
| **Desktop** (6800 XT 16 GB Vulkan, 32 GB) | **Where you plan and review.** Claude Code / OpenCode run here. When not in use, its GPU adds attempts or hosts the review-gate seat. | Review-gate seat. Overflow executor | Vulkan limits the software stack, and it is the machine you game on. Nothing in the pipeline may *depend* on it. |
| **GTX 1070** (8 GB) | Spare | — | See [hardware.md](hardware.md) → "Upgrade candidates". |

**One front door.** OpenCode (or the dispatcher) should see one endpoint, and
routing to whichever host is up happens behind it. Today that is spread over
four profiles and three provider blocks in `opencode.jsonc`, and it is the
last step, not the first. A routing proxy on the server (e.g. LiteLLM) is the
likely shape, but it only pays off once there are two executor hosts worth
routing between.

## Milestones (ordered; each is measurable with the existing harness)

1. **Pick executor models.** Probe the candidates in
   [hardware.md](hardware.md) with `tests/test-toolcalls.ps1`. Run the
   passers through the 8-task batch, 2 reps each, harness unchanged, beside
   `qwen3-coder:30b-a3b`. Node3 runs its small candidates in parallel.
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
- **Free disk per machine** and **the LAN link between hosts** (wired gigabit
  or Wi-Fi) are not in [hardware.md](hardware.md). Candidate models are
  15–25 GB each, and every agent turn re-sends the prompt to the model host.
- **node3 sleep settings.** Its 2026-09-21/22 mid-batch dropouts were Windows
  sleep, not a fault. Disable sleep before giving it scheduled work.
