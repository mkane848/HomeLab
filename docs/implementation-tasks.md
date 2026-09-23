# Audit result — /plan run of 2026-09-17 (qwen3:14b)

Scope: `add a --DryRun switch to desktop/scripts/sync-skills.ps1`.

## Resolution — all tasks shipped in commit `3e243f9` (2026-09-18)

> **Correction (2026-09-19).** This section originally cited commit
> `eec004d`, which does not exist in this repository (`git cat-file -e` fails;
> it appears in no branch). The work actually landed in **`3e243f9`**, confirmed
> by `git log -S'would create remote dirs' -- desktop/scripts/sync-skills.ps1`.
> The same phantom hash is in commit `41a457d`'s own message, so it was
> mis-recorded at the source rather than corrupted later. The code fixes
> themselves are real and present.

- [x] Task 1 (smoke-test `-DryRun`) — PASSED 2026-09-17; the one uncovered
      defect (unguarded remote `mkdir`) became Task 2 and is now fixed.
- [x] Task 2 (guard the remote `mkdir -p` behind `-DryRun`) — **done in
      `3e243f9`**; `sync-skills.ps1:205` now sits inside an `if ($DryRun)` /
      `else` split. DoD check: a dry run prints `(dry run) would create remote
      dirs` and issues no ssh.
- [x] Task 3 (fix `$pair[1]` interpolation) — **done in `3e243f9`**; both
      interpolations are now `$($pair[1])` (sync-skills.ps1:168, 171).

Kept as the `/plan` canary record: this file proves the command writes a real
doc to disk, that its gap claims were wrong and caught by a human audit, and
that the corrected list then shipped in one commit.

## Verdict: feature already exists; plan's gap claims are inverted

`sync-skills.ps1` already has a working `-DryRun` switch (param line 45),
guarded at **every** destructive boundary. Each of the three "risk/gap" claims
in the raw /plan output was checked against the file and found wrong:

| Raw claim | Cited lines | Reality |
|---|---|---|
| "Existing DryRun handling may miss edge cases — only logs skills without checking pruning/copying" | 101 | Line 101 IS `if ($DryRun)` — staging copy is skipped in dry run. |
| "Prune logic lacks DryRun validation — no explicit guard" | 145-159 | Line 151 IS `if ($DryRun) { log } else { Remove-Item }` — prune is guarded. |
| "DryRun does not prevent legacy directory removal on server" | 177-188 (local) / 219-226 (server) | Line 181 (local) and line 220 (server) both guard with `if (-not $DryRun)`. |

All line numbers were accurate; semantics were inverted. **This run reproduces
the exact failure already documented at `docs/troubleshooting.md:165-205`**
(the "Prune logic bypasses DryRun" claim), this time under qwen3:14b — the 14b
seat does not fix plan-verification reliability. Treat /plan output as a draft,
never a task list.

## Task list

1. **Smoke-test the existing `-DryRun` end to end.** No code changes needed.
   Definition of done:
   - `.\desktop\scripts\sync-skills.ps1 -DryRun -Local` prints `  + skills/...`
     lines but writes **nothing** to `~/.config/opencode/` (verify by comparing
     file timestamps / running `-Prune` too stays log-only). **PASSED 2026-09-17.**
   - `.\desktop\scripts\sync-skills.ps1 -DryRun -Server` prints `(dry run)`
     lines and skips the scp transfers (line 214) and legacy `rm -rf`
     (line 220-221). **Verified 2026-09-17: FAILS its own DOD** — line 205
     `ssh $remote "mkdir -p ..."` runs unguarded and attempted a live
     connection during the dry run. Scp/rm are guarded; the `mkdir` is not.
     Task 2 below is the fix.
   - The only unavoidable writes are to the temp `$STAGE` directory — created
     at line 76-83 before any dry-run branch. Confirm that is the *only* local
     write. (Confirmed; the `$STAGE` teardown at line 77 is idempotent.)
2. **Guard the remote `mkdir -p` (line 205) behind `-DryRun`** so a dry run
   performs no network writes at all. Move line 205 inside the same
   `if ($DryRun)`/`else` split already used for scp (lines 211-215):
     - dry run  → `Write-Host "  (dry run) would create remote dirs"`, skip ssh
     - real run → keep `ssh $remote "mkdir -p ..."` and the line 206 failure abort
   Definition of done: `-DryRun -Server` on a reachable host prints the dry-run
   line and issues no ssh command (`test-toolcalls.py`/`ssh -v` session or
   `LASTEXITCODE` untouched).
3. **Cosmetic: fix `$pair[1]` string interpolation** — PSH does not index
   `"$pair[1]"` in a string; it prints the whole array + literal `[1]`
   ("commands commands[1]/bootstrap.md"). Use `"$($pair[1])/..."` (lines 168,
   171). No behaviour change.
---

# Review-gate on LFCbot - approved and executed (2026-09-18)

Scope: dependency hygiene of `M:\Projects\LFCbot` (v1.6.0), running the
review-gate methodology documented in `docs/lmstudio-vscode.md` end to end:
auditor -> reviewer -> human approval -> implementer.

## What happened

- **Auditor** `qwen/qwen3-coder-30b` (LM Studio, port 1234, tested native
  Ollama import `qwen3-coder:30b-a3b` exists) - facts capture graded A: all 14
  invalid installs, the one `UNMET DEPENDENCY` (typescript-eslint) and the
  extraneous `@types/node-cron` each identified from the ground-truth evidence;
  semver-fine upgrades (discord.js 14.27.0, typescript 5.9.3, prettier 3.9.6)
  correctly *not* flagged. Section 2 shipped a 3-step `npm install` plan -
  concise, no lockfile deletion.
- **Reviewer** `deepseek-r1:14b` (Ollama, Ask mode, no tools) - graded 3/3
  PASS, flagged no destructive/redundant steps. Verdict: FIRST-RUN-SAFE.
- **Human gate**: held and then released - the user approved the plan, and the
  **implementer** (`qwen3:14b` seat, tool-capable) ran the approved steps
  verbatim: `npm install` (added 38, removed 88, changed 48), re-checked
  `typescript-eslint` present, verified `npm ls --depth=0` exit 0 (all 20 deps
  at locked versions, no invalid/extraneous).
- **Verification after execution**: `npm run type-check` exit 0, `npm run lint`
  exit 0, `npm test` 335/335 passed (better-sqlite3 native binding works - the
  blocking failure that stopped the toolchain before the gate is resolved).

## Lessons

- The auditor-produced plan no longer deletes the lockfile, but it still does
  not converge on `npm ci` - the reviewer catches it, which is the point of the
  gate. The right handoff is: approved plan verbatim to a **tool-capable**
  implementer (e.g. `qwen3:14b`), not the auditor seat. On the executed run the
  implementer produced a clean tree and a green toolchain, confirming the model
  choice and handoff shape.
- The workflow lives in **VS Code + LM Studio** (BYOK), not OpenCode. Prompt
  templates for both seats live at `docs/review-gate/auditor.md` and
  `docs/review-gate/reviewer.md`; the flow is: Auditor (Agent mode,
  `qwen/qwen3-coder-30b`) -> Reviewer (Ask mode, `deepseek-r1:14b`) -> human
  approves -> tool-capable implementer (`qwen3:14b`) runs the approved steps.
  Full protocol in `docs/lmstudio-vscode.md`.

## Open follow-up

- Add the three imported desktop seats (`qwen3-coder:30b-a3b`, `qwen3.5:9b`,
  `deepseek-r1-0528:8b` - registered in opencode/global/opencode.jsonc but not
  yet rows in `models/catalog.tsv`) so install/test/profiles know them.

---

# KaneEnabler deck-validity follow-up — PR #82 fix-and-reverify (task list)

Scope: the follow-up work to KaneEnabler PR #82 (`review-gate/deck-validity`),
driven by the 2026-09-19 PR review. The PR is **open, not merged** — fixes land
on the same branch before any merge. Verdict on the submitted validator: **good
scaffolding, needs a fix-and-reverify pass before merge** — the PR review
found a silent Background-pairing bug despite a green suite (lint, `tsc`, 404
passed / 14 skipped / 0 failed). Full context:
`docs/lmstudio-vscode.md` → "The PR review that caught the silent bug" and
`docs/review-gate/testing.md`.

Tasks are ordered; **each fix must ship a test that fails on the old code**.

1. **Fix the Background-pairing eligibility bug** (`server/src/services/deckValidation.ts`).
   `eligible` is `commanders.every(c => c.is_commander_eligible === 1)`, but a
   Background card is definitionally `is_commander_eligible = 0`, so a legal
   pair (e.g. *Tevesh Szat, Doom of Fools* + *Boarding Party*) is rejected.
   Replace with
   `const usableAsCommander = (c) => c.is_commander_eligible === 1 || c.is_background === 1;`
   and let `legalUnits.some(...)` (via `buildCommanderUnits`) keep doing the
   pairing-legality check.
   Definition of done: a Background pair returns `isValid true`; Sol Ring as
   commander and two unrelated legendaries are still rejected.
2. **Make the Background unit test exercise the pairing branch.** The PR's
   "a Background companion needs the legal Background to pair" test passes only
   `[chooser]` — it never enters the pairing branch it claims to test. Pass the
   pair (chooser + Background) so the branching path `legalUnits.some(...)` is
   actually walked.
   Definition of done: the new test **fails on the old code** and passes on the
   fixed code.
3. **Check named `commanders` rows directly against `legality_commander`**
   (`server/src/routes/deckValidity.ts`). Today ban enforcement is incidental —
   it only fires when the pasted `list` happens to duplicate the commander line.
   Add an explicit check on the resolved `commanders` rows.
   Definition of done: a banned commander omitted from `list` is reported in the
   verdict; the deck-size total stays correct; the existing suite stays green.
4. **Run the integration suite on a seeded DB** — prove the 100-card-valid
   assertion AND a real Background pair live, not CI-only.
   Definition of done: the deck-validity integration tests run with 0 skips
   locally and both assertions hold.
5. **Re-run lint + tsc + full suite on the checkout** — the fix-and-reverify
   pass is complete (see `docs/review-gate/testing.md`).
6. (Pre-existing, still open): singleton paper-rule; `banned`/`notFound`
   dedupe.

# Task-veracity: next testing round — desktop handoff (2026-09-21)

Written for whoever picks this up **on the desktop**, with fleet access. This
container had neither the task repos (Windows paths) nor the LAN, so everything
below is either verified-here-and-noted or explicitly left for you.

## Where things stand

The 2026-09-19 → 09-21 corpus is 43 rows, of which **18 measured nothing about a
model** and **exactly one run is a genuine pass** (`lfc-01` on
`ollama-desktop/qwen3:14b`, 2026-09-20T21:58). Full inventory and the reasoning:
`tests/results/README.md`.

Two instrument defects produced most of that and are now fixed (PR #30 and the
`typecheck` change alongside this entry):

- `test-tasks.ps1` graded any non-zero `opencode run` exit as "liar mode".
  Six node3 runs whose transcripts hold nothing but `Cannot connect to API`
  became a "6/6 liar mode" capability finding that reached `docs/roadmap.md`,
  `CHANGELOG.md` and a config change. **node3's liar-mode denominator is 0.**
- `ollama-desktop/qwen3:14b` truncated at its 4096 `limit.output` on 8 of 16
  runs — on `kane-01`, before any edit call on 7 of 9. **Any 14b-vs-8b
  comparison from the old corpus is invalid.** Cap is now 8192.

**Read this before touching node3:** its six failures were HTTP refusals on
`:11434`. Nothing in this repo reaches node3 over SSH — `docs/network-topology.md`
gives it one firewall rule, inbound TCP 11434. The only SSH item in the repo is
the *server's* pending key auth, and the server has been down since 2026-09-16.
Fixing SSH on node3, if that is what was done, does not by itself restore the
benchmark path.

## 1. Verify the merged changes on real hardware

None of these could run here.

- [ ] `opencode debug config` — confirm `ollama-desktop/qwen3:14b` and
      `ollama-node3/qwen3:8b` both still resolve **with** a `limit` block. A key
      the schema rejects is dropped silently and brings the truncation bug
      straight back (`opencode.jsonc`'s own RULES block, rule 3).
- [ ] One run against a deliberately wrong base URL → expect a `FAIL` naming the
      exit code, an `_INFRA_`-tagged transcript, and **no new row** in
      `tasks-summary.tsv`. Then a normal run → expect a row as before.
- [ ] One `kane-01` run on `ollama-desktop/qwen3:14b` → expect no
      `step_finish` with `reason: "length"`, and a non-zero write count.
- [ ] A run of any task **without** a `typecheck` block (e.g. `kane-03`) →
      expect `typecheck: SKIP`, not `PASS`.
- [ ] `.\tests\test-profiles.ps1` → 100 PASS / 0 FAIL / 1 WARN / 2 SKIP. The
      WARN is the known node3 catalog-group false positive; **do not** silence it
      by pulling `qwen3:14b` or `gpt-oss:20b` onto node3
      (`docs/roadmap.md`, "do not pull either onto node3").

## 2. Bring node3 back, in this order

Full reasoning in `docs/roadmap.md` → "Node3's `qwen3:8b` 'liar mode' was never
liar mode". Do not skip to step 4.

- [ ] `curl http://NODE3_IP:11434/api/tags` — does it answer at all?
- [ ] `curl http://NODE3_IP:11434/api/show -d '{"name":"qwen3:8b"}'` — read the
      `num_ctx` Ollama **actually serves**. node3 has no context-baking step the
      way desktop's `startup.ps1` (`$contextModels`) does. Set
      `OLLAMA_CONTEXT_LENGTH` on node3's own service, restart it, re-read, then
      set `limit.context` in `opencode.jsonc` to what it reports. It is at the
      16384 onboarding default right now, which the preamble arithmetic suggests
      is too small (~12,288 tokens of input budget vs a measured 14,364-token
      preamble) — but measure, do not guess again.
- [ ] `curl http://NODE3_IP:11434/api/ps` with the model loaded — closes the
      long-open "node3 usable VRAM never measured" to-do in `docs/roadmap.md`.
- [ ] `tests/test-toolcalls.ps1 -Model qwen3:8b -OllamaHost http://NODE3_IP:11434`
      — confirm the seat still passes as it did on 2026-09-20.

## 3. Preflight the five never-run tasks

`kane-03`, `kane-04`, `asohav-01`, `asohav-02`, `lfc-02` have **never been run**.
`kane-02`'s only three rows are node3 connection failures, so it has no data
either — only `kane-01` and `lfc-01` do.

- [ ] `.\tests\run-tasks-batch.ps1 -SetupOnly` — creates the six `bench/*`
      branches.
- [ ] `test-tasks.ps1 -DryRun` for each of the five (validates worktree +
      install + baseline, skips the model run).
- [ ] **Give `asohav-01` and `asohav-02` extra scrutiny.** Both carry a `setup`
      step building `@asohav/shared` via `npx tsc` — the same shape as the step
      that invalidated `kane-02`: a workspace package built into an untracked
      `dist/` that survives a branch switch and makes a stale tree look green.
      Confirm the baseline passes in a genuinely fresh worktree.
- [ ] `asohav-02` runs the full 194-test suite (unfiltered `npx vitest run`) —
      slower, more flake surface. `lfc-02` has the `MANAPOOL_API_KEY` flake
      guard; unset the key first.

## 4. Run the breadth batch

Rationale: `docs/roadmap.md`'s own 2026-09-21 pivot — breadth over depth, 8
tasks now, 16 the target. Two of eight tasks currently have any gradable data,
so between-task variance is essentially unmeasured.

- [x] Seats: `ollama-desktop/qwen3:8b` and `ollama-node3/qwen3:8b`. node3's
      `qwen3:8b` is bit-identical weights served over CUDA against desktop's
      Vulkan, so any systematic split between the two seats flags a backend
      artifact for free — the stated reason node3 was onboarded. **(Ran
      2026-09-21; harvested per-seat: the node3 leg was lost to an outage —
      see the results block below.)**
- [x] **Never run the same task id in two terminals at once.** The worktree is
      keyed by task id alone (`test-tasks.ps1:448`,
      `$wtPath = Join-Path $wtRoot $tk.id`), and so is the install marker
      (`:205`) — two concurrent runs of one task share a worktree and corrupt
      each other. AGENTS.md states the rule: *"different task IDs only, never
      the same one twice"*. `run-tasks-batch.ps1` is sequential by design.
      To keep both machines busy, **partition by task, not by seat**:
      terminal A took `kane-03` + `kane-04`, terminal B took `asohav-01` +
      `asohav-02` + `lfc-02`, each running its own tasks against *both* seats.
      No task id then appeared in two terminals. (Both terminals may hit the
      same Ollama host at once; that is a throughput question, not a
      correctness one.)
- [x] **Hold `qwen3:14b` out of this batch.** It needs its own `kane-01` re-run
      post-cap-fix to establish whether its record was truncation or capability
      — a separate question from task breadth.
- [x] **N=3 first, not N=10.** 5 tasks × 2 seats × 3 = 30 runs satisfies the
      repo's own action gate (">=3 graded runs across >=2 tasks",
      `test-tasks.ps1` header) and surfaces a broken task definition after 6 runs
      rather than 20. Fill to the N=10 statistical target only for cells that
      come through clean. `run-tasks-batch.ps1` defaults reps to 1.

The batch runner refuses to start against a host that is not answering, so a
dead endpoint can no longer burn a batch silently. **It is a point-in-time
snapshot, not a watch — node3 answered `/api/tags` at 20:43 and was unreachable
by the first node3 attempt ~22:47.**

### 4a. Results (2026-09-21 batch: 30 runs attempted)

Ran via two detached `pwsh` drivers (`tests/run-tasks-batch.ps1` is interactive;
the drivers looped `test-tasks.ps1 -Task <t> -Model <m> -RunTimeout 1500
-CommandTimeout 300`, one per partition, `-DryRun`-preflighted in Section 3).
Transcripts + the batch rows are in `tests/results/`; 9 new `tasks-summary.tsv`
rows, 6 TIMEOUTs (no row), 15 `_INFRA_` (no row — harness correctly refused to
grade a host that was not answering; this is the fixed behaviour, not a repeat
of the "6/6 liar mode" misreading).

**node3 (15 runs) — infrastructure outage, zero gradable data.** Host healthy
at batch start (20:43, 4 tags), dead by first node3 run ~22:47: every node3 run
failed `Cannot connect to API [http://192.168.1.235:11434/v1/chat/completions]`
and was recorded `_INFRA_`. Confirmed down after (TCP 11434 refused, `ssh`
hangs). **The whole node3 breadth leg is unmeasured — re-run seats
`ollama-node3/qwen3:8b` across the same 5 tasks × N=3 once the box is back.**
(Follow-up entry below.)

**desktop (15 runs) — 1 clean PASS of 9 graded.** Two failure shapes, neither
is liar mode:

1. **Phantom-edit loop (dominant; kane-03 ×1, kane-04 ×1, lfc-02 ×2).** The
   model reads the real file, then issues `edit` calls whose `oldString` does
   not match the file — e.g. kane-03 tried to pattern-match `const newCount =
   count + delta;`, which does *not* exist (actual: `const to = clampCount(
   c.count + delta, ...)`). Every call returns `Could not find oldString...`
   and it retries in a loop: 17, 36, 48, 88 `edit` calls, re-running vitest
   8–13×, exiting 0 with **zero** real changes. `writes` in the TSV counts
   tool *calls*, so the writes-gate passes and the scope gate correctly FAILs.
   2× kane-03 and 1× each of the rest also TIMED OUT at 1500s.
2. **Suite-breaking source edit (asohav-02 ×3).** rep1 landed the real fix
   (removed `const id = newId('log')` from the insert in `repo.ts`) but its
   added test failed to compile → suite FAIL "load/parse error"; rep3 edited
   only the test (scope FAIL, "test-only change passes a buggy source").
   This is a narrower miss than the phantom loop — the fix itself was correct
   and applied — but the pairing kill (test breaks the build) still fails the
   gate. Worth one targeted follow-up before trusting these results.

**Clean PASS: `asohav-01-library-write-reporting` rep2** (18 writes, 8 true
edits + 10 failed, all gates closed). The only cell that satisfied the N→
follow-up bar naturally. **All other desktop cells are under N=3** (1–2 graded
runs + timeouts), so the "fill clean cells to N=10" decision is deferred but
the batch already surfaces the phantom-edit mode after 6 runs, per the plan's
own rationale.

## Gap-fill batch review (2026-09-23)

Batch: `run-tasks-batch.ps1 -Mode Both -Models new -Tasks all -Reps 1
-OnlyMissing`, 2026-09-22 23:00 → 2026-09-23 08:34. The desktop lane ran from
`M:\Projects\dev-docs` and a node3 lane ran from a second checkout at the same
time. Both were stopped before finishing. The evidence was committed verbatim
in PR #38. This section is the separate grading pass.

**Recorded data is complete.** 41 graded rows, each with its `.json` and
`.jsonl`, plus 2 `_INFRA_` transcripts.

### Pass rate per attempt, not per graded run

A timeout leaves **no row and no transcript** (see the bug below), so the
graded-only ratios in the CHANGELOG ("`laguna-xs-2.1` 3/3") overstate the
models. Attempts are reconstructed from the 15-minute gaps between rows and
from the Ollama server log, which shows requests in every 10-minute window
all night.

| Seat | Attempts | Full PASS | Timeout | `_INFRA_` | 0-write | Other FAIL | Median s (graded) |
|---|---|---|---|---|---|---|---|
| `ollama-desktop/qwen3.5:9b` | 8 | **5** | 1 | 1 | 1 | 0 | 269 |
| `ollama-desktop/laguna-xs-2.1` | 8 | 3 | 5 | 0 | 0 | 0 | 497 |
| `ollama-desktop/nemotron-3.5-lightning` | 8 | 3 | 4 | 0 | 1 | 0 | 510 |
| `ollama-desktop/qwen3.6:35b-a3b-coding` | 8 | 3 | 2 | 0 | 1 | 2 | 358 |
| `ollama-desktop/north-mini-code-1.0` | 8 | 1 | 5 | 1 | 1 | 0 | 730 |
| `ollama-desktop/devstral-small-2:24b` | 8 | 1 | 7 | 0 | 0 | 0 | 732 |
| `ollama-node3/ornith:9b` | 6 | 1 | 0 | 0 | 3 | 2 | 77 |
| `ollama-node3/ministral-3:8b` | 8 | 0 | 3 | 0 | 0 | 5 | 230 |
| `ollama-node3/lfm2.5:8b` | 8 | 0 | 0 | 0 | 8 | 0 | 20 |

Pass by task, across all seats:

| Task | Passes | Note |
|---|---|---|
| `kane-04` | 7 | Easy: `ornith:9b` passed it in 65 s |
| `lfc-01` | 4 | |
| `lfc-02` | 3 | |
| `kane-01` | 2 | |
| `kane-03` | 1 | |
| `kane-02` | 0 | 907-line `signals.ts`. Both `_INFRA_` runs are this task |
| `asohav-01`, `asohav-02` | 0 | 3 of the 7 zero-write runs outside `lfm2.5` are ASoHaV tasks. No seat has passed either one |

### Transcript audit of all 17 full passes

- **None is hollow.** Every pass has successful edits to both the source file
  and the test file, within `allowFiles`.
- **Every `failsOnOld` PASS is a behavioural failure, not an import crash.**
  The test imports added by the models were checked against each task's base
  commit: `chapterRoman` exists at `kane-03`'s base (`counters.ts:151`), and
  `singletonLimit`/`applySingletonLimits` exist at `kane-04`'s base
  (`singleton.ts:42/77`). Nothing else imports a symbol the fix introduced.
- **The phantom-edit loop is essentially gone in these runs.** Most passes have
  **0 failed edits** (the worst has 3). The 2026-09-22 corpus had 85 of 783
  edits succeed.

### Failure modes

- **Timeouts are the largest failure class for the offloading models** (the 18–25 GB
  MoE/dense candidates). `test-tasks.ps1` defaults `-RunTimeout` to 900 s. Those
  models' true capability is unmeasured, not low.
- **Both `_INFRA_` runs are context overflow on `kane-02`, not host failures.**
  The model filled 32k, then OpenCode's compaction failed.
  `north-mini-code-1.0` made a tool call during the summary ("Tool call not
  allowed while generating summary"). `qwen3.5:9b`'s chat template raised "No
  user query found in messages" (HTTP 500). Each had worked for minutes
  first. They are recorded as infrastructure and have no row, so
  `-OnlyMissing` will retry them.
- **`lfm2.5:8b` passes the tool-call probe and is liar mode in the real
  loop.** It made 0 writes on 8 of 8 tasks in 9–44 s. The probe is necessary,
  not sufficient.

### What the batch does NOT show yet

- **Model versus environment.** Ollama moved 0.34.1 → 0.34.3 between the old
  corpus and this batch. The `qwen3:14b`/`qwen3:8b` gap-fill runs, which would
  be the control, were queued last and never ran. Run them before crediting
  the jump to the new models.
- **Unfinished work:** `qwen3-coder:30b-a3b` ×8, `devstral:24b` ×7,
  `qwen3:14b` ×6, `ollama-desktop/qwen3:8b` ×1, `ornith:9b` ×2,
  `ollama-node3/qwen3:8b` ×4. `-OnlyMissing` picks these up.

### Next

- [ ] **Timeout transcripts are lost.** `Invoke-OpencodeRun` writes the job's
      output with `$events | Out-File` only after `opencode run` returns, so
      `Stop-Job` on timeout leaves nothing to rescue. The "partial transcript
      kept" branch can never fire for a timeout. Stream to the file instead
      (`opencode run ... | Out-File` inside the job, or `Tee-Object`).
- [ ] **Raise the timeout for the offloading seats** (for example
      `-RunTimeout 1800`, passed through from `run-tasks-batch.ps1`). Then
      re-run `-OnlyMissing` for `laguna-xs-2.1`, `nemotron-3.5-lightning`,
      `qwen3.6:35b-a3b-coding`, `north-mini-code-1.0` and
      `devstral-small-2:24b`.
- [ ] **Run the control:** `qwen3:14b` and `qwen3:8b` on all 8 tasks on
      0.34.3.
- [ ] **`qwen3.5:9b` is the lead candidate:** 5/8, fits in VRAM, and has the
      fastest median. Give it N=3 on every task. It is also the only strong
      seat small enough for node3's 10 GB at Q4 (the installed desktop copy is
      a 10.4 GB Q8 import), so pulling a Q4 `qwen3.5:9b` on node3 is the
      obvious next node3 candidate.
- [ ] **node3's small candidates are not executors.** Drop `lfm2.5:8b` and
      `ministral-3:8b` from task batches. `ornith:9b` only passes the easiest
      task.

## Open follow-ups, not yet done

- [ ] **Re-run the node3 breadth leg — attempted 2026-09-22, still incomplete.**
      Two partial attempts so far, neither reached N=3 on all 5 tasks:
      - 2026-09-22 07:02–08:01: node3 answered at the start, then flapped mid-leg
        (12 of 15 runs hit `Cannot connect to API`, correctly recorded `_INFRA_`,
        no row). 3 runs reached the model: `kane-04` rep1 **FULL PASS**
        (2 writes, real fix, suite green, fails-on-old red — the first fully
        clean node3 result); `asohav-02` rep2 phantom-write FAIL; `asohav-02`
        rep3 suite-break FAIL (14 writes, same shape as desktop's rep1/rep3).
      - 2026-09-22 09:14: one ad hoc `kane-03` rep on node3 — FAIL (scope/
        failsOnOld), 11 writes, the phantom-edit loop (repeated
        `Could not find oldString`) reproducing on node3 the same way it did on
        desktop. **Confirms the phantom-edit mode is seat-general, not a
        Vulkan/desktop artifact.**
      - 2026-09-22 13:31: `asohav-01` rep1 on node3 — suite-breaking edit (real
        changes to `library.ts` + `library.test.ts`, scope PASS, suite FAIL,
        failsOnOld PASS), the same shape as `asohav-02`'s rep1/rep3 above.
      - 2026-09-22 14:40: `asohav-01` rep2 on node3. FAIL (failsOnOld). The
        suite PASS is hollow. 12 of 14 `edit` calls missed with `Could not
        find oldString`. The first four used the literal placeholder
        `await appendChangeLog(...);` as `oldString`. Every edit to
        `library.test.ts` missed, so the suite stayed at 35 tests on all six
        vitest runs and there was no new test for failsOnOld to kill. The two
        edits that did land applied the *same* `create` wrap twice. The
        second matched the call inside the first's new `try`, so it nested
        a second try/catch. The run then closed with "the tests …
        now verify the correct behavior". That is a false completion claim
        on top of a phantom-edit loop, not zero-write liar mode.
      Running tally: `kane-04` 1/3, `asohav-02` 2/3, `kane-03` 1/3,
      `asohav-01` 2/3, **`lfc-02` 0/3 — still no node3 data.** Still needed:
      `lfc-02` plus 1–2 more reps each on the four that have started.
      Partition identically to §4 (by task, never the same task id in two
      terminals). If node3 is down at start, `run-tasks-batch.ps1`'s preflight
      refuses to start — that is the intended guard, not a reason to bypass it.
- [x] **node3 has now flapped mid-batch twice** (2026-09-21 ~20:43→22:47 outage
      during §4, 2026-09-22 flap during the re-run leg above) — both times
      *after* an initial healthy `/api/tags` check, which the batch-start
      preflight cannot catch. **Resolved 2026-09-22: both were Windows sleep
      on node3** (power settings never changed after onboarding), per the
      owner. No per-request health check needed. Disable sleep on node3
      before scheduling work on it.
- [ ] **Edit-reliability analysis across the whole corpus (2026-09-22).** Every
      graded transcript was mined for tool-call outcomes. Failed `oldString`s
      were classified against each file at the task's `baseCommit`
      (`git show <baseCommit>:<path>`):
      - `edit`: **85 succeeded, 698 failed (11%)**. `write` (whole file): 8/8.
      - Of the failures: **79% hallucinated** (code not in the file at all),
        8.7% present in the base file (drift after an earlier edit, or a
        non-unique match), 8.5% placeholder `...` in `oldString`, 2.7%
        partially real, **0.3% whitespace/indent-only**. Every target file is
        LF, so CRLF is ruled out. A fuzzy-match edit tool would fix almost
        none of this.
      - `read`: **167 of 177 calls pass a `limit`**. The most common is 20
        lines; target files are 96–907 lines. **238 of 783 edits (30%) hit a
        file the model had not read** in that run.
      - Per seat: `qwen3:14b` makes zero edits in 7 of 19 graded runs (it
        reads, then answers in prose). `qwen3:8b` never makes zero edits but
        loops on misses (up to 95 in one run). Two different failure modes,
        so a single harness fix will not cover both.
      - pass@1 across all 54 graded rows: 4 (7%).
      Conclusion and plan: [target-setup.md](target-setup.md) → "Milestones"
      (agent-trained executor candidates first, then a read-before-edit agent
      prompt and a miss-loop cap as A/B tests).
- [ ] **The phantom-edit loop is a new failure mode distinct from liar mode**
      (`tests/results/tasks-kane-03-saga-chapter-triggers-ollama-desktop_qwen3_8b_20260921-210616.jsonl`).
      The model reads files then edits with a fabricated `oldString`, rolls on
      dozens of `Could not find oldString` errors, exits 0 having written
      nothing. The writes-gate counts calls and passes; only the scope gate
      catches it. Worth (a) a `test-tasks.ps1`-level note or test — e.g. a
      scope gate already covers it, but a "writes > 5 with scope==no-changes"
      heuristic in the summary would make the mode legible at a glance — and
      (b) a probe of whether `qwen3:8b`'s edit reliability degrades with the
      preamble size / prompt length (the §1 OK-probe runs edited fine).
- [ ] `test-tasks.ps1` hardcodes `pnpm exec tsc` even for `packageManager: npm`
      tasks. `lfc-01` is npm and WARNs on 10 of 17 rows — **confirm whether those
      are real type errors or pnpm failing in an npm-installed tree** before
      trusting that column for npm tasks. Deliberately not changed blind: it
      needs a desktop run to tell the two apart.
- [ ] `profiles/dev-node3.sh` points `OPENCODE_SMALL_MODEL` at
      `ollama-server/qwen2.5-coder:7b` — the machine that has not POSTed since
      2026-09-16. The new preflight catches it; nothing fixes it yet.
- [ ] PR #29's Verification checkboxes are unchecked while its prose asserts they
      are satisfied.
- [ ] **The worktree being keyed by task id alone is the root cause of the
      concurrency footgun**, not just a rule to work around. `test-tasks.ps1`
      builds it as `$wtPath = Join-Path $wtRoot $tk.id` (`:448`) and the install
      marker as `$wtRoot/.<taskId>.installed` (`:205`), so the same task can
      never run on two seats at once. Keying both by task id **and** model label
      would make same-task concurrency safe and delete the rule instead of
      documenting it — at the cost of one worktree and one `node_modules` per
      (task, seat) pair rather than per task, which is the real trade-off to
      weigh. Not attempted here: it changes install-marker semantics and disk
      cost, and wants a desktop run to validate.
- [ ] **Aborted 2-lane executor launch, 2026-09-23 ~13:00: `kane-02` worktree
      collision (analysis; zero corpus impact).** Lane 1 (control rematch,
      desktop `qwen3:14b` ×8, no `-OnlyMissing`) and Lane 2 (node3 gap fill,
      `-OnlyMissing`) launched a minute apart and both picked
      `kane-02-multiword-creature-type` within 18 seconds of each other (PIDs
      43240 desktop/14b at 12:59:47, 52384 node3/8b at 13:00:05 — read off the
      `opencode run --dir/--model` command lines in a process audit). The
      node3 run was killed as the later starter; then both drivers were
      stopped; the desktop run survived its driver's death as an orphan and
      was killed directly. Verified after: TSV still 102 rows, tree clean,
      zero batch processes — the collided cells left no trace, which is the
      correct epitaph for voided cells (the orphan's partial transcript sits
      unarchived in `%TEMP%` with no harness left to collect it).
      - **Root cause, not bad luck.** `-OnlyMissing` correctly ignored node3's
        three legacy exit-1 `kane-02` rows (not data), so the task looked
        unrun exactly when control legitimately re-ran it. The launch plan's
        "lanes rarely reach the same task together" assumption failed on the
        first task. The structural cause is the task-id-keyed worktree above;
        the batch preflight guards host liveness, not worktree contention, so
        no guard fired — nothing was misconfigured, the rule was just
        unenforced.
      - **Stopping a driver orphans its run.** `Invoke-OpencodeRun` spawns
        `opencode run` under `Start-Job`; Ctrl+C on the batch driver leaves
        the child working with nobody watching. The stop procedure is driver
        stop **plus** a process check for `opencode *run*`, not the driver
        stop alone. (Had Lane 2's driver lived to process the kill, its
        INFRA-path `git reset --hard` would have wiped Lane 1's in-progress
        edits in the shared worktree — a second, unrealised collision from
        the same root cause.)
      - **Before relaunch:** partition lanes by task id statically up front
        (disjoint task sets per lane in the launch plan, verified against
        each lane's `-Tasks` list before starting — no "rarely collide"
        reasoning); keep the (task, model-label) keying fix above as the
        structural answer. Voided cells stay open and are covered by the
        replan: `kane-02`/desktop-14b gets one clean single-cell re-run at
        the end of Lane 1 (even a PASS from the collided run would be
        suspect), `kane-02`/node3-8b is re-picked by Lane 2's `-OnlyMissing`
        on its own.
