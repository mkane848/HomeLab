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
review-gate methodology documented in `docs/vscode.md` end to end:
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
- The workflow lives in **VS Code** (BYOK), not OpenCode. (This run served
  the auditor from LM Studio; since 2026-09-27 every seat is on desktop
  Ollama and LM Studio is retired.) Prompt
  templates for both seats live at `docs/review-gate/auditor.md` and
  `docs/review-gate/reviewer.md`; the flow is: Auditor (Agent mode,
  `qwen3-coder:30b-a3b`) -> Reviewer (Ask mode, `deepseek-r1:14b`) -> human
  approves -> tool-capable implementer (`qwen3:14b`) runs the approved steps.
  Full protocol in `docs/vscode.md`.

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
`docs/vscode.md` → "The PR review that caught the silent bug" and
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

# Session closeout — starting build agreed, reruns pending (2026-09-23)

## What landed

- Afternoon probe, 23 seats on desktop 0.34.3 + node3 0.34.2: full
  reproduction (9 desktop PASSes re-PASS, 8 FAILs re-FAIL with identical
  shapes); `qwen3.6:35b-a3b-coding` PASS (123.3 s); `lfm2.5:8b` /
  `ministral-3:8b` probe-PASS in 3–7 s despite 0/8 and 0/5 task records
  (probe is necessary, not sufficient); `glm4:9b` FAIL reproduced.
  23 rows in `tests/results/toolcalls-summary.tsv`.
- Two task lanes, 6 attempts, disjoint task sets (no collision): 3 graded —
  `ministral × kane-03` FAIL/suite (broke test-file loading),
  `ministral × kane-04` FAIL/failsOnOld (test never modified, the kane-04
  disease), `ornith × lfc-02` FAIL, 0 writes (an output-cap hit, not liar mode:
  corrected 2026-09-30) — and 3
  timeout unknowns at the 900 s cap (`qwen3:8b-node3 × lfc-02`,
  `qwen3.6 × asohav-01/asohav-02`, no rows). Corpus 102 → 105.
  Ministral 0/7, ornith 1/7; `lfm2.5`/`ministral`/`ornith` out as executors.
- Starting build agreed (server down): planner `qwen3.6` (fully local, first
  plans small and benchmark-shaped), attempt 1 `qwen3.5:9b` Q8 as measured,
  attempt 2 `laguna-xs-2.1`, parallel attempt `qwen3:8b` on node3,
  review-side `nemotron-3.5-lightning` (reviewer-seat trial per round-3
  protocol — the seat is empty), dispatcher manual. Recorded in
  `docs/target-setup.md` → "Starting build"; `qwen3.6` raised to
  `limit.output` 8192.
- PR #45 (`tests/afternoon-probe-and-runs`: probe rows + 3 graded rows +
  evidence) and PR #46 (`config/starting-build-seats`: cap + lineup doc).
  Merge results first, then config.

## Rerun lanes (evening, 1800 s cap) — 1 unknown resolved, 1 aborted, 1 open

- **T1 desktop, `qwen3.6 × asohav-01` — PASS.** First pass on this cell
  (13 writes, 1620.3 s, suite 48 green, all three gates). This was the
  `qwen3.6` seat's second-longest run; it cleared the cap but at 27 min is
  hovering against it, worth remembering for `asohav-02`-sized workloads.
- **T1 desktop, `qwen3.6 × asohav-02` — FAIL, liar mode** (exit 0, 0 writes,
  458.3 s). The `asohav-02` cell stays at 0 passes across 10 graded runs —
  now also including the seat that just passed `asohav-01`. `qwen3.6` does
  **not** hit the seat-finding branch of "times out again at 1800": it
  finished both lanes, one clean pass and one plain fail.
- **T2 node3, `qwen3:8b × lfc-02` — ABORTED, not a timeout.** The run was
  killed by a human from another session at ~25 min into the 30-min cap
  (exit `-1`: a kill, not a cap), so the closeout's "if node3 `qwen3:8b`
  hangs again it is a host finding" branch **is not met** — a process stopped
  by the operator proves nothing about the host. **Not a host finding.**
  Transcript preserved as `tasks-…-ABORTED_20260923-183729.jsonl` (renamed
  from the misleading `_TIMEOUT_` tag the harness applied to the non-zero
  exit). It shows the model mid-edit on `src/services/scryfall.ts` when
  killed — slow but working, not wedged. No row; the cell stays open.
- Corpus 105 → 107 (still 8 tasks); passes 21 → 22. Seats unchanged:
  `qwen3.6` 4/8, node3 seats untouched by these lanes.

## New open follow-ups

- [ ] **Blind-trial data point 1: the qwen3.6 planner stalled without a
      mission line** (2026-09-23, session `ses_f2efe83bdffexOK6vf23Yf0F4J`).
      The draft prompt says "Explore the target repo" but never names it.
      Launched from `M:\Projects\dev-docs`, qwen3.6 read that as *this*
      workflow repo and spent ~28 min / 23 messages / 4 compactions looping:
      re-reading `target-setup.md` + `manifest.json` + `implementation-tasks.md`
      3-4x each (each compaction discards the earlier tool results, forcing the
      reload — which is also what filled 32768 in under a half hour), rebuilding
      the same "Objective / Work State / Next Move" summary each turn, and
      asking "Which would you like to prioritize?" — never the numbered
      scope interview the contract requires. **It never produced a work
      order and never touched `M:\Projects\LFCbot`.**
      - The final stop-and-ask was contract-correct (the draft says
        "stop and ask instead of guessing"); the miss is that it read and
        planned the wrong repo because the referent was unbound. The launch
        directory is scaffolding; with no mission line there was no target to
        interview about.
      - Fix (in `docs/agent-notes/planner-prompt-qwen3.6.md`): the build must
        open with a `Target repo:` / `Target:` mission line, the explore step
        is bound to that repo only, re-reads are banned, and status replies are
        short lines instead of full-session summaries. The live session is
        recoverable without a restart — reply to it with the mission line and
        it proceeds to the LFCbot interview.
      - Second finding: after the first compactions qwen3.6 began echoing the
        opencode session-summary format as its normal reply style instead of
        the terminal `## Work orders` contract. The compacted session
        summaries in its own context became its template — worth watching in
        the next run whether the "short status lines" rule holds it off.

- [ ] **Blind-trial data point 2: mission line holds scope, role separation
      does not** (2026-09-24, session `ses_f2bba6de5ffeLs2OcFGUB5rTmt`,
      12:35–16:52, transcript `session-ses_f2bb.md` untracked in repo root).
      Fresh session launched with the mission line + verbatim prompt from
      `docs/agent-notes/planner-prompt-qwen3.6.md`: it explored the RIGHT
      repo (LFCbot, zero dev-docs planning) — data point 1's failure mode is
      gone. Planning judgment was sound (defect at `listings.ts:297-301`,
      guard in the service layer, right test file). Everything else missed
      the contract: it **edited the live LFCbot checkout** (`setStatus`
      guard + a test block — reverted, baseline re-verified 21/21 green),
      skipped the interview, never emitted the terminal `## Work orders`
      section, and never verified failing-first (its test block carries a
      compile error — `fulfillListing({ id: 99999 })` against a
      `(id: number)` signature — and two happy-path tests that pass with or
      without the guard). The no-re-read rule failed openly (full
      `listings.ts` 4×, full test file 3×, some across ordinary turns with
      no compaction between). First turn cost ~4 h on the offloading seat.
      - Fix is mechanical, not a third prompt rule: planner sessions launch
        with the bottom-left toggle on **Plan** (edit/write denied at the
        permission level), so the seat cannot implement whatever it decides.
        The read-only prose stays as backup. Step 0 added to
        `docs/agent-notes/planner-prompt-qwen3.6.md`; status there graduates
        from DRAFT.

- [ ] **Blind-trial data point 3: Plan mode fixes the live-checkout violation
      but stalls the seat entirely** (2026-09-24, session
      `ses_f299504bcffefA9CLk3kZq8dPl`, transcript `session-ses_f299.md`
      untracked in repo root, 17 user turns, 5 compactions, ~4h). Launched
      with the DP2 fix (Plan-mode toggle) + verbatim prompt + mission line
      for the same defect. The live-editing problem is GONE — nothing was
      written to either repo. But the seat never emitted `## Work orders`:
      5 compactions, each re-emitting the forbidden "Objective / Work State /
      Next Move" summary template as its reply, re-reading the same five
      files (full `listings.ts` 4×, full test file 4×), and answering the
      interview against instructions instead of asking the owner — it read
      the A/B/C "refine to three" prompt as directives and turned them into
      self-chosen assertions (only `active` may transition; fulfilled →
      deleted cleanup legal; throws per `createListing`). Its final stall
      question ("should setStatus verify ownership?") is answered by the
      code: `setStatus(id: number, …)` takes no user param — ownership lives
      in the command layer. Root cause is structural, not prompted: contract
      step 4 requires verifying a failing-first test in a throwaway worktree,
      which requires a write, which Plan mode denies — the seat physically
      cannot complete its own mandate and resolves the contradiction by
      asking new questions / compacting instead of terminating. That bind is
      exactly what the external order-drafting path (below) bypasses.
      - Test-cluster result (same transcript) worth keeping: the seat poked
        at a wrong `expired → 'deleted'` transition possibility, and the
        correct reading of the schema (no reactivation path exists;
        `setStatus` callers are `commands/user/fulfill.ts:23`,
        `commands/user/delete.ts:23`, `commands/user/mylistings.ts`,
        `commands/admin/remove.ts:25`) is what settled answers A/B/C.
      - Resolution decision (2026-09-24, owner): the interview answers from
        this session become the NEW contract, superseding the silent-no-op
        contract that `lfc-01-listing-status-guard` (manifest) encodes —
        they are not compatible (lfc-01 blocks `fulfilled → deleted` and
        never throws). So the work order is docketed as a new manifest task
        `lfc-03-status-transition-guard` (older `lfc-01` entry stays intact
        with its own history). Acceptance tests are authored + verified
        outside the seat on bench branch `bench/status-guard-throw`: 5/5
        forbidden-transition tests FAIL on unguarded `main` (24/29, baseline
        21 passing kept), 29/29 PASS with a candidate guard, full suite
        343/343, scoped tsc clean.

- [ ] **Blind-trial data point 4: the first executor attempt ran and both A/B
      arms graded FAIL on `lfc-03-status-transition-guard` — the gates caught
      what they exist for** (2026-09-25, seat `ollama-desktop/qwen3:14b`, Ollama
      0.34.3, opencode 1.18.32, on `4906dc2`). Accelerator B was packaged as a
      new `-EditFormat write|edit` flag on `test-tasks.ps1` (prompt directive
      appended to the hashed prompt, so each arm records a distinct sha) and both
      arms were run through the untouched four gates:
      - **Arm A (`-EditFormat write`)** — opencode exit 0, ONE `write` tool call
        replacing the whole `listings.ts` with a correct matrix implementation
        (`validTransitions = { active: ['fulfilled','deleted'], fulfilled:
        ['deleted'] }` + throw on anything else). **Scope PASS, suite PASS
        (21/21), fails-on-old FAIL** ("the test file was never modified - the
        pre-existing tests are green on the buggy source"). The transcript shows
        the exact failure shape: after the write it hit `step_finish
        reason:length`, compacted, ran the suite via bash, saw the pre-existing
        21 tests green, then emitted prose ("The tests for the status transition
        logic in `set…") and stopped — it implemented the fix but never wrote
        acceptance tests, so nothing proved the new forbidden transitions throw.
        Its guard also carries the TS7053 unchecked-index WARN (the `as keyof`
        fix is in the bench-branch candidate, `bench/status-guard-throw`). Result
        files: `tests/results/tasks-lfc-03-status-transition-guard-qwen3-14b-
        write_20260925-084915.{json,jsonl}` + one TSV row.
      - **Arm B (`-EditFormat edit`)** — timed out at 1800 s. Correctly
        produced **no summary row** and the worktree was reset clean, but its
        transcript was again **not archived** (the known "Summary appended but
        appends nothing" gap below — the raw `opencode run` JSONL was never
        flushed before the kill, so a timeout remains a pure unknown). Prompt sha
        recorded: `1E977C9B5E0D`.
      - Verdict: 0 graded runs passed — same shape as the historical 0/7 for
        kane-01/lfc-01, so the harness is behaving, not malfunctioning. Three
        concrete learnings: (1) **scope+suite green is not enough — fails-on-old
        is the load-bearing gate**, and it FAILed on a model that fixed the code
        but never proved it; (2) a mid-context `reason:length` cap can evict the
        step where the model would have written its tests; (3) the timeout
        black-hole fired again and still costs an unknown. Accelerator A (the
        `qwen3.8-max` oracle run of the same order) is queued with owner
        approval (2026-09-25) — target lower than the local seat's ceiling,
        calibration key spend confirms what a ✓ PASS on the exact order looks
        like before any local re-seat.

- [x] **Blind-trial data point 5: Accelerator A — the `qwen3.8-max` oracle
      PASSes `lfc-03` through the untouched four gates** (2026-09-25, seat
      `opencode-go/qwen3.8-max`, opencode 1.18.32, on `4906dc2`, `-EditFormat
      write`, prompt sha `4A1266C4478E` — identical to DP4's write arm, so the
      model is the only variable). 320 s, 3 write calls, **scope PASS (both
      files), suite PASS (30/30), fails-on-old PASS (all 5 forbidden-transition
      tests fail with the source reverted), scoped typecheck PASS** (no TS7053:
      the transition table is typed `Record<ListingStatus, readonly
      ListingStatus[]>`). Result files: `tests/results/tasks-lfc-03-status-
      transition-guard-qwen3-8-max-oracle_20260925-142706.{json,jsonl}` + one
      TSV row.
      - The fix: a per-status allow-list (`active → fulfilled/deleted`,
        `fulfilled → deleted`, nothing out of `deleted`/`expired`), a
        current-row read in `setStatus`, and ``throw new Error(`Listing ${id}
        cannot transition from '${current}' to '${status}'.`)``; an unknown id
        still returns `undefined`, as before.
      - **Owner acceptance tests, checked separately: 29/29 on the oracle's
        source.** That exposed a test-design flaw: the 5 throw-assertions
        matched `/cannot .* from .*<status>/`, stricter than the prompt (which
        requires the message to name id + current + requested status and gives
        "cannot transition from" only as an example). The oracle passed because
        it echoed the example; an alt-wording guard meeting the spec failed all
        5. Loosened on `bench/status-guard-throw` @ `3215aaf` to assert exactly
        the contract; re-verified 5 fail / 24 pass on unguarded `4906dc2`,
        29/29 with the oracle guard and with the alt-wording guard, full suite
        343/343, scoped tsc clean.
      - Harness follow-through (same session): `test-tasks.ps1` now runs a
        task's `acceptance` block (owner tests from a local ref, swapped in over
        the model's and restored byte for byte) as an **informational** check
        recorded in the per-run JSON — never a gate, TSV unchanged — and under
        `-DryRun` asserts those tests fail on base. `lfc-03` carries the block.
      - Verdict: the order is passable as written and the four gates grade a
        genuine fix correctly. The difference from DP4 is exactly the gate that
        failed there — the oracle wrote tests that prove its own fix. This is
        the first genuine successful trajectory on a real order (the Unsloth
        fine-tune gate in Accelerator A).

- [x] **Data point 6: oracle sweep — `qwen3.8-max` PASSes all 8 remaining
      manifest tasks; 9/9 with DP5** (2026-09-26, `opencode-go/qwen3.8-max`,
      opencode 1.18.32, plain prompts — no `-EditFormat`, so every prompt sha
      matches the local runs it is compared with). One invocation, 50 PASS /
      0 FAIL / 14 SKIP (typecheck/acceptance blocks absent), 8 rows. Oracle vs
      the local corpus (graded runs on the current prompt sha; kane-02's 4
      runs on the pre-`2e6841e` prompt excluded):

      | task | local PASS / graded | oracle writes, s |
      |---|---|---|
      | kane-01-background-pair | 3 / 31 | 4, 358 |
      | lfc-01-listing-status-guard | 5 / 24 | 3, 157 |
      | kane-02-multiword-creature-type | **0 / 3** | 2, 610 |
      | kane-03-saga-chapter-triggers | 1 / 8 | 7, 633 |
      | kane-04-singleton-up-to-n | 8 / 12 | 3, 191 |
      | asohav-01-library-write-reporting | 2 / 7 | 12, 543 |
      | asohav-02-changelog-uuid-id | **0 / 10** | 6, 495 |
      | lfc-02-scryfall-headers | 3 / 8 | 5, 499 |
      | lfc-03-status-transition-guard (DP5) | **0 / 1** | 3, 320 |

      - **Every task is passable as written.** No task-design defect found;
        the local failure record (22 PASS / 104 graded) is a model finding,
        not a harness or task finding. kane-02, asohav-02 and lfc-03 have no
        local PASS yet — they are the frontier.
      - **Audit beyond the gates** (green is necessary, not sufficient): the
        test-file diffs were checked for removed assertions before any reset.
        Only kane-01 removed test lines, and it is a strengthening — the old
        test was the PR #82 trap itself (the Background was never in the named
        unit, so it was green on broken code); the oracle put the Background
        into both the decklist and the commanders argument and added names /
        eligible / colour-identity assertions. The other removals are import
        lines. asohav-01 (12 writes) and kane-03 (7) tripped the
        repeated-call note but graded clean.
      - Result files: `tests/results/tasks-*-qwen3-8-max-oracle_20260926-*.{json,jsonl}`
        (16 files) + 8 TSV rows.

- [x] **Data point 7: step 6, frontier tasks — the three oracle-only tasks ×
      the desktop seats** (2026-09-26/27, desktop Ollama 0.34.3, opencode
      1.18.32, plain prompts, `-RunTimeout 1800`, 3 groups + 1 rerun group).
      Local record on the current prompt shas, before → after:

      | task | local PASS / graded | new passes |
      |---|---|---|
      | lfc-03-status-transition-guard (`833A03061C7F`) | 0 / 0 → **2 / 8** | `laguna-xs-2.1` (8 writes, 1630 s), `qwen3.6:35b-a3b-coding` (7, 525 s) — both 29/29 owner acceptance, typecheck PASS |
      | kane-02-multiword-creature-type (`2C70ABFF8F8A`) | 0 / 3 → **1 / 9** | `laguna-xs-2.1` (2 writes, 850 s) |
      | asohav-02-changelog-uuid-id (`15771B923DC9`) | 0 / 10 → **0 / 14** | none |

      - **Right fix, wrong tests (lfc-03).** `devstral-small-2:24b`,
        `qwen3.5:9b` and `north-mini-code-1.0` score **29/29 on the owner
        acceptance tests** but fail a gate on their own tests (suite FAIL ×2,
        fails-on-old FAIL ×1 — north-mini wrote 1 file, no catching test).
        The informational acceptance check is what separates them from
        `qwen3-coder:30b-a3b` (27/29 — still allows fulfilled→fulfilled and
        deleted→deleted) and `qwen3:14b` (test file does not load). Grading is
        unchanged; they are FAIL rows.
      - **Audit beyond the gates:** every edit in the three passing
        transcripts was diffed against the base test file. laguna (lfc-03)
        only removed lines it had itself added earlier in the run; laguna
        (kane-02) added a Time Lord test and removed only two source comments;
        qwen3.6 (lfc-03) made the shared `seedServer()` helper idempotent
        (`onConflictDoNothing`) — no assertion removed anywhere. Note on
        laguna's kane-02 fix: first-match over the catalog, not longest-match —
        correct for the real catalog (no single-word type is a prefix of a
        multi-word one), fragile if one is ever added.
      - **Context overflow, not infrastructure (4 ungraded runs).** OpenCode
        compacts the session when it nears `limit.context − limit.output`
        (32768 − 4096); the model answers the summary request with a tool call
        and the run dies with exit ≠ 0 — `Tool call not allowed while
        generating summary` (north-mini kane-02, laguna asohav-02) or a
        template crash on the compacted history (`qwen3.5:9b`: `Cannot have 2
        or more assistant messages…` on lfc-03, `No user query found in
        messages` on kane-02). laguna's asohav-02 transcript shows the budget:
        14.8k-token first request (preamble + prompt), one `repo.ts` read
        (38 KB) → 27.6k, 29.1k after four tool calls. The harness files these
        as `_INFRA_` with no row, which hides a capability limit (the seat
        cannot hold the repo) as an infra fault. Proposed: a `_CONTEXT_`
        class, still no row, counted separately. Raising `limit.context` is
        the other lever — see the roadmap note on 64k.
      - **Memory-pressure contamination (group 1, ~16:00–17:54 on 09-26).**
        Firefox held system RAM while partially offloaded seats paged: prompt
        chunks went 3 s → 61–87 s, Ollama cancelled no-output requests at 5 min
        (HTTP 500), and SWA seats (`north-mini`) re-prefilled from zero each
        retry. The `devstral-small-2`, `north-mini`, `nemotron` and
        `qwen3-coder` lfc-03 timeouts from that window are superseded by the
        rerun group; laguna's lfc-03 PASS stands (the result, not its 1630 s).
        Rule: close memory-heavy apps before a batch; check free RAM first.
      - **Timeouts that stand:** `nemotron-3.5-lightning` lfc-03 again in the
        rerun (21 shell commands, 4 edits, never finished — memory was fine);
        `qwen3:8b` lfc-03 (43 edit calls, all `Could not find oldString`);
        `devstral-small-2` on kane-02 and asohav-02 and `qwen3-coder` on
        kane-02 and asohav-02 (still exploring at the cap).
      - **Liar mode, unchanged:** `devstral:24b` (0 writes on all three),
        `nemotron` (0 on kane-02 and asohav-02), `qwen3:8b` and `qwen3.6`
        (0 on kane-02).
      - **Harness fixes found by this run** (branch
        `fix/harness-empty-transcript`): the transcript file is created before
        the job starts, so a zero-event timeout leaves an empty `_TIMEOUT_`
        file instead of nothing (north-mini's first lfc-03 run vanished); and
        the job sets `[Console]::OutputEncoding` to UTF-8, since opencode's
        stdout was decoded with the OEM codepage and every non-ASCII character
        in a transcript was mojibake (`—` → `ΓÇö`). Transcripts from before
        this fix carry the mojibake; the worktrees were not affected.
      - Result files: `tests/results/tasks-{lfc-03,kane-02,asohav-02}-*-ollama-desktop_*_2026092{6,7}-*`
        from 15:00 on 09-26 — 18 graded runs (`.json` + `.jsonl`) + 18 TSV
        rows, 13 `_TIMEOUT_`/`_INFRA_` transcripts.

- [x] **Data point 8: 64k context trial — DP7's frontier tasks × the six
      raised seats** (2026-09-27 11:00–15:51, branch `feat/context-64k-trial`,
      desktop Ollama 0.34.3, opencode 1.18.32, same prompt shas as DP7,
      `-RunTimeout 1800`, `-Reps 1`, 3 groups). Every graded JSON stamps
      `numCtx: 65536` (served, from `/api/show`). Seats: `qwen3.5:9b`,
      `qwen3-coder:30b-a3b`, `north-mini-code-1.0`, `laguna-xs-2.1`,
      `qwen3.6:35b-a3b-coding`, `nemotron-3.5-lightning`.

      | task | 32k (DP7, same seats) | 64k | passes (writes, seconds, peak context) |
      |---|---|---|---|
      | lfc-03 | 2 PASS / 6 attempts | **4 / 6** | nemotron (4, 372 s, 31.2k), qwen3.6 (3, 223 s, 27.3k), laguna (3, 325 s, 26.8k), qwen3-coder (8, 1625 s, 49.5k) — all 29/29 owner acceptance |
      | kane-02 | 1 / 6 | **3 / 6** | qwen3-coder (5, 1553 s, 46.2k), qwen3.5 (12, 544 s, 51.4k), qwen3.6 (2, 369 s, 36.9k) |
      | asohav-02 | 0 / 3 | **2 / 6** | laguna (5, 1418 s, 62.2k), qwen3.5 (13, 637 s, 61.5k) — first local passes on this task |
      | **total** | **3 / 15 (20%)** | **9 / 18 (50%)** | |

      DP7's same-seat attempts include its graded rows and its ungraded
      transcripts; superseded memory-pressure runs are excluded, and
      asohav-02 had only 3 of these seats in DP7.
      - **Acceptance criterion (roadmap) met.** Ungraded runs fell from 6 of
        15 to 2 of 18. Timeouts fell 3 → 1: laguna on kane-02 compacted
        cleanly (61.4k → 14.4k) and was still working at the cap. Context
        deaths fell 3 → 1: `qwen3.5:9b` on lfc-03, a template crash (`Cannot
        have 2 or more assistant messages`) at 59.4k. **7 of the 9 passes
        peaked above ~28.7k**, the point where a 32k seat compacts. Two of
        them compacted near 62k and still passed (laguna and qwen3.5 on
        asohav-02, `compaction_continue` in the transcript). So qwen3.5
        survives some compactions and crashes on others.
      - **Audit beyond the gates.** Every edit in all 9 passing transcripts
        was replayed onto the base files and diffed:
        - lfc-03: the four passes are purely additive to
          `tests/services/listings.test.ts` (0 base lines changed, +8 to +16
          `expect`s).
        - kane-02: qwen3-coder changed 1 base line (added Time Lord to the
          `CREATURE_TYPES` set in the test). qwen3.6 moved one closing `});`
          to append its tests. qwen3.5 changed nothing. No assertion was
          removed.
        - asohav-02: both passes make exactly the upstream fix (delete
          `const id = newId('log')` and `id,`), and each adds a new
          `repo.changelog.test.ts` asserting the insert payload has no `id`.
      - **Typecheck WARNs (lfc-03), reproduced** by replaying each run into
        the task worktree and running the harness's scoped `tsc`. The base
        and the qwen3.6/nemotron runs compile clean.
        - laguna has a **real source error**: `listings.ts:313` indexes the
          transition table (`Record<status, …>`) with a plain `string`
          (TS7053, TS7006). It runs correctly but loses the type safety the
          guard exists for.
        - qwen3-coder's errors are test-only: 4× TS18048 `'fulfilled' is
          possibly 'undefined'`.
        - Informational; no grade changes.
      - **Failures:**
        - north-mini, 0/3:
          - 0 writes on lfc-03 and kane-02.
          - On asohav-02, all 3 edits errored on a mangled path
            (`/workspace/M:Projects/dev-docs/…`), so it never changed a
            file.
        - nemotron: 0 writes on kane-02, as at 32k. On asohav-02 it edited
          `apps/server/.env` and `vitest.config.ts` to get its test to load
          (scope FAIL).
        - qwen3-coder and qwen3.6 on asohav-02: correct source fix, but a
          test file that doesn't load (suite FAIL).
          - qwen3-coder then reported every requirement met.
          - qwen3.6 stopped mid-iteration, blaming "rate limits", which a
            local model doesn't have.
      - **No 5-minute no-output cancels.** The Ollama log for 11:00–16:00 has
        517 × 200 and 7 × 500:
        - six sub-second 500s at 11:51, the qwen3.5 template crash retrying;
        - one at 13:35, the request cancelled when laguna's run hit the cap.
      - **Verdict:** keep 64k for these six seats, and merge this branch to
        adopt it. It's N=1 per cell, but the direction held on all three
        tasks. The qwen3 dense pair (40,960 trained cap) and the devstral
        pair (expensive, see roadmap) stay at 32k.
      - Result files: `tests/results/tasks-{lfc-03,kane-02,asohav-02}-*-ollama-desktop_*_20260927-1{1,2,3,4,5}*`
        — 16 graded runs (`.json` + `.jsonl`) + 16 TSV rows, 1 `_INFRA_` and
        1 `_TIMEOUT_` transcript.

- [x] **Data point 9: step 6, the other 6 tasks × 8 desktop seats**
      (2026-09-27 16:50 to 09-28 22:22, desktop Ollama 0.34.3, opencode
      1.18.32, plain prompts, `-RunTimeout 1800`, `-Reps 1`, 9 batches of
      about an hour each). The six MoE/hybrid seats ran at 64k and the qwen3
      dense pair at 32k; every JSON stamps `numCtx`. The devstral pair was not
      run (see "Not run" below).

      | seat | ctx | kane-04 | lfc-01 | kane-01 | kane-03 | lfc-02 | asohav-01 | pass |
      |---|---|---|---|---|---|---|---|---|
      | `qwen3.6:35b-a3b-coding` | 64k | PASS | PASS | PASS | PASS | PASS | PASS | **6/6** |
      | `qwen3.5:9b` | 64k | PASS | PASS | PASS | PASS | scope, suite | PASS | 5/6 |
      | `laguna-xs-2.1` | 64k | PASS | PASS | PASS | TIMEOUT | PASS | TIMEOUT | 4/6 |
      | `qwen3-coder:30b-a3b` | 64k | PASS | PASS | PASS | PASS | INFRA | suite | 4/6 |
      | `nemotron-3.5-lightning` | 64k | PASS | PASS | PASS | 0 writes | 0 writes | PASS | 4/6 |
      | `north-mini-code-1.0` | 64k | fOO | 0 writes | PASS | suite, fOO | suite, fOO | 0 writes | 1/6 |
      | `qwen3:14b` | 32k | PASS | TIMEOUT | PASS | scope, suite | fOO | fOO | 2/6 |
      | `qwen3:8b` | 32k | suite, fOO | TIMEOUT | fOO | scope, fOO | scope, fOO | fOO | 0/6 |
      | **per task** | | 6/8 | 5/8 | 7/8 | 3/8 | 2/8 | 3/8 | **26/48** |

      (fOO = fails-on-old.) By context size: **64k 24/36 attempts PASS, 32k
      2/12**. The 32k row is the qwen3 dense pair only, so this is a seat
      comparison as much as a context one; the context comparison is DP8.
      Across all 9 tasks, including DP8's frontier runs:

      | seat | 9-task record |
      |---|---|
      | `qwen3.6` | 8/9 |
      | `qwen3.5` | 7/9 |
      | `laguna`, `qwen3-coder` | 6/9 each |
      | `nemotron` | 5/9 |
      | `qwen3:14b` (the default main seat) | 2/9 |
      | `north-mini` | 1/9 |
      | `qwen3:8b` | 0/9 |

      - **Audit beyond the gates.** All 26 passes were replayed onto the base
        files and diffed. No existing test was removed or weakened, and every
        base test name survives in every pass. Details worth keeping:
        - **Gate-green, spec-short (3 passes).** The gates grade whether the
          test fails on the old source, not whether it covers what the prompt
          asked for.
          - kane-01, nemotron and qwen3:14b: both changed only the
            `commanders` argument (`[chooser]` → `[chooser, background]`).
            The prompt asks for the Background "in the submitted deck AND in
            the commanders argument", and their decks still have none.
            laguna, north-mini, qwen3.6, qwen3.5 and qwen3-coder did both.
          - asohav-01, nemotron: all seven routes are fixed, but its tests
            cover only create and update, where the prompt asks for all
            seven. qwen3.6 (an `it.each` over all seven, plus no-warning
            cases) and qwen3.5 (one test per route) meet it.
        - **Fixture noise.** On kane-01, qwen3.5 marked the chooser as a
          Background (`is_background: 1`), which no real chooser is.
          Re-running its fix with the original fixture: 10/10, and the
          realistic test still fails on the old source. So the pass stands.
          One qwen3.5 kane-03 test "moves down" from 0 to 0; its
          down-then-up test covers that requirement properly.
        - **Contract change.** On lfc-01, qwen3-coder returns `undefined` for
          an existing non-active listing, which previously meant "not found".
          No caller reads the return value today. nemotron and laguna did the
          same fix as a single conditional `UPDATE ... WHERE status =
          'active'`, which keeps the return contract.
        - **Typecheck WARN (kane-01, qwen3.5):** an unused helper
          (`ineligibleBackgroundCommander`, TS6133). Lint, not a bug.
        - **Audit method caveat.** OpenCode's edit tool falls back to looser
          matching when `oldString` is not found verbatim, and the replay does
          not. Where the replay missed an edit (qwen3.5 and qwen3.6 on
          asohav-01), the final files in the worktree or the model's own
          per-route tests passing were used to confirm the result.
      - **Failure modes, by seat:**
        - **north-mini invents a `/workspace/<task>` repo root** (lfc-01 and
          asohav-01, plus lfc-03 and asohav-02 in DP8) and keeps returning to
          it after `pwd` shows the real path. It also printed tool calls as
          text in its own `<|END_ACTION|>` format (kane-04). It used
          `/workspace` in 4 of 9 runs at 64k and in 0 of 5 transcripts at 32k
          (3 graded, 2 `_INFRA_`), mostly on different tasks. (Corrected
          2026-09-29: this said 3 of 5 at 64k, which missed asohav-01.) The
          32k-vs-64k check is DP10.
        - **nemotron writes nothing on some tasks** (kane-02, kane-03,
          lfc-02). It explains the fix and exits 0.
        - **qwen3:8b writes edits from the prompt, not the file.** On lfc-01,
          all 48 edits missed: it looked for `Date.now()` where the file has
          `now()`, as the prompt describes it. It also claimed "All tests
          passed" on kane-04 when the suite failed.
        - **qwen3:14b runs out of 32k.** On lfc-01, OpenCode compacted the
          session twice (18:30, 18:41), and after each compaction its edits
          stopped matching the file. That is the DP7 overflow pattern, on the
          control seat. It also edited `src/utils/counters.ts` on kane-03,
          outside scope.
        - **qwen3.5 and scope.** On lfc-02 it edited three files outside
          scope, including removing `runMigrations()` from the shared test
          helper `tests/helpers/db.ts`.
        - **laguna timeouts are long tasks, not wedges.** On asohav-01 it
          made 17 successful edits and compacted once at 61.4k, and was still
          working at the cap. Its three timeouts (kane-02, kane-03, asohav-01)
          are all on long tasks.
      - **New INFRA shape: the output cap, not the context window.**
        qwen3-coder on lfc-02 peaked at 23.6k tokens with no compaction.
        - Two consecutive steps each ran exactly 4m12s and ended with finish
          reason `unknown`, 0 counted output tokens, and only a preamble
          sentence of text. That is consistent with a large tool call cut off
          at `limit.output` 4096.
        - OpenCode then sent two trailing assistant messages. The Qwen
          template rejected them: `400 Cannot have 2 or more assistant
          messages at the end of the list`, the same error qwen3.5 hit after
          compaction on lfc-03.
        - So step 8(d)'s `_CONTEXT_` tag should cover output-cap truncation
          too. Raising qwen3-coder's `limit.output` to 8192 (qwen3.6 already
          has it) is the likely fix, held until after step 6 so the batch ran
          on one config.
      - **Wall-clock at 64k.** 14 of DP9's 64k passes have a 32k pass on the
        same task, seat and prompt sha. Those 32k passes are from 09-23; the
        seats had been baked at 32768 since `e37f102` on 09-22.
        - 12 of the 14 finished faster at 64k, with a median change of
          **−37%** (for example, qwen3.6 on asohav-01: 1620 s → 773 s).
        - The two exceptions are both qwen3.5: kane-04 went from 97 s to
          444 s, and kane-01 from 326 s to 479 s.
        - These are different days and N=1 per pair. Fewer compactions and
          re-prefills would explain the gain, but it isn't isolated.
      - **Run environment.** No memory-pressure contamination. Across the
        whole window, the Ollama log has exactly five non-200 responses, each
        tied to a known event:
        - three 500s where the harness cancelled a run at the cap (09-27
          19:17; 09-28 13:00 and 20:49);
        - one 499 when the killed background batch dropped its request
          (15:52);
        - one 400, the output-cap template error (16:47).

        There were no 5-minute no-output cancels. The two batches launched
        from the Claude Code session started with about 23 GB of RAM free.
        - A lfc-02 batch launched as a background shell from a Claude Code
          session was killed by Claude Code's memory-pressure reaper when
          nemotron loaded, before its first run was graded. Nothing was
          recorded from it.
        - Re-launched in its own window, outside the session, lfc-02 and
          asohav-01 ran to completion. Batches belong in a separate terminal
          (or a session started with
          `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1`).
      - **Not run:**
        - `devstral:24b`: 0 writes on all 4 tasks it has tried (kane-01 in
          2026-09-19, and the three frontier tasks in DP7). Proposed: drop it
          as an executor seat.
        - `devstral-small-2:24b`: one row on these 6 tasks (kane-04 PASS,
          09-23). Covering the other 5 is roughly 2.5–3 hours at 32k, a
          candidate for one overnight batch or a recorded drop. Owner
          decision.
      - Result files: `tests/results/tasks-{kane-04,lfc-01,kane-01,kane-03,lfc-02,asohav-01}-*-ollama-desktop_*_2026092{7,8}-*`
        from 16:50 on 09-27. 43 graded runs (`.json` + `.jsonl`), 43 TSV
        rows, and 5 ungraded transcripts: `_TIMEOUT_` ×4 (qwen3:14b and
        qwen3:8b on lfc-01, laguna on kane-03 and asohav-01) and `_INFRA_` ×1
        (qwen3-coder on lfc-02).

- [x] **Data point 10: two decision tests for open seat questions (2026-09-29)**
      Run from a one-off launcher in its own window, on opencode 1.18.32 and
      Ollama 0.34.3.
      - **north-mini, 32k vs 64k on lfc-01.** The question was whether 64k
        causes its invented `/workspace` root (DP9 failure modes). Same task,
        runs alternated 32k, 64k, 32k, 64k. The 32k copy was a temporary
        derived tag, `north-mini-code-1.0-32k` (`FROM north-mini-code-1.0`,
        `num_ctx 32768`, same weights). It was registered for the run only,
        through `OPENCODE_CONFIG_CONTENT`, and removed afterward.

        | ctx | run 1 | run 2 |
        |---|---|---|
        | 32k | FAIL: suite (3 writes) | `_TIMEOUT_` at 900 s |
        | 64k | FAIL: failsOnOld (1 write) | FAIL: suite (5 writes) |

        - None of the 4 used `/workspace`, including both 64k runs. The one
          earlier 64k run on lfc-01 (09-27) used it 13 times.
        - Across every north-mini transcript it is now 4 of 11 at 64k and 0
          of 7 at 32k. That is lopsided, but mostly on different tasks, and
          the same-task check did not reproduce it at either size. Whether
          64k raises the rate is unresolved.
        - It doesn't change the decision. north-mini failed lfc-01 at both
          sizes, and its record is 1 pass in 7 attempts at 32k and 1 in 11 at
          64k. Returning it to 32k is not a fix.
      - **Write-discipline canary on the re-seat candidates.** Same prompt and
        pass rule as `test-profiles.ps1 -Reliability` (`Test-ReliableWrite`):
        one `opencode run` asking for `docs/_scratch.md` containing
        `it works`. PASS is exactly one write/edit call and the right content.
        It ran from a scratch script, not `test-profiles.ps1`, because
        `-Reliability` only tests the main seats of live profiles, and neither
        candidate is seated. 3 reps each:

        | seat | PASS | wall clock per rep |
        |---|---|---|
        | `qwen3.6:35b-a3b-coding` | 3/3 | 122, 122, 121 s |
        | `qwen3.5:9b` | 3/3 | 59, 7, 6 s |
        | `qwen3:14b` (current main seat) | 2/3 | 184, 17, 36 s; rep 3 made 2 write calls |

        - **qwen3.6 pays about 2 minutes at the start of every session.** In
          the Ollama log, the first request of each of its three runs took
          1m55s with the model already loaded; its later requests took 1–7 s.
          That fits a prompt cache that isn't reused between sessions. The
          cause isn't diagnosed. qwen3.5 paid its first-session cost once.
        - The current main seat repeated a write on 1 of 3 reps, the
          regression that once unseated it.
      - Result files: three graded lfc-01 runs
        (`tasks-lfc-01-listing-status-guard-ollama-desktop_north-mini-code-1.0{,-32k}_20260929-*`),
        one `_TIMEOUT_` transcript, 3 TSV rows, and
        `tests/results/reliability-summary.tsv` (9 canary rows).

- [x] **Data point 11: the N>1 protocol on the frontier cells (2026-09-29,
      PRs #61–#64).** The protocol in `docs/adversarial-review-2026-09-29.md`
      §7, run on desktop Ollama 0.34.3, opencode 1.18.33, `-RunTimeout 1800`,
      plain prompts, no `-OnlyMissing`; 64k for `qwen3.6` and `qwen3.5`, 32k for
      `qwen3:14b` (the control). 21 graded rows, one `_TIMEOUT_` (`qwen3:14b` ×
      lfc-03) and one `_ABORTED_` (a human-stopped `qwen3:14b` × lfc-03 run: 2
      reads, 0 edits, worktree clean; not an attempt). Graded by the gates and,
      for lfc-03, the owner acceptance block. **The replay audit of the passes
      that DP8 and DP9 did was not done for these 12.** Writes and seconds per
      attempt are in the PR bodies (#62–#64).

      Same-config attempts per cell: same prompt sha, the seat's designed
      `numCtx`, Ollama 0.34.3. Timeouts and infra crashes count; aborts do not.
      P pass, f fail, T timeout, I infra crash; oldest first.

      | task | `qwen3.6` (64k) | `qwen3.5` (64k) | `qwen3:14b` (32k) |
      |---|---|---|---|
      | kane-01 | P 1/1 | P 1/1 | P 1/1 |
      | kane-02 (frontier) | PPP 3/3 | PPP 3/3 | f 0/1 |
      | kane-03 | P 1/1 | P 1/1 | f 0/1 |
      | kane-04 | P 1/1 | PPP 3/3 | P 1/1 |
      | lfc-01 | P 1/1 | P 1/1 | T 0/1 |
      | lfc-02 | P 1/1 | fPP 2/3 | f 0/1 |
      | lfc-03 (frontier) | PPP 3/3 | Iff 0/3 | ffT 0/3 |
      | asohav-01 | P 1/1 | Pff 1/3 | f 0/1 |
      | asohav-02 (frontier) | fPP 2/3 | Pff 1/3 | fff 0/3 |
      | **all 9 tasks** | **14/15** | **13/21** | **2/13** |
      | Wilson 95% | 0.70–0.99 | 0.41–0.79 | 0.04–0.42 |
      | frontier cells only | 8/9 | 4/9 | 0/7 |

      Fisher exact, two-sided. All tasks: `qwen3.6` vs `qwen3.5` p = 0.051,
      `qwen3.6` vs `qwen3:14b` p = 0.0001, `qwen3.5` vs `qwen3:14b` p = 0.013.
      Frontier cells only: 0.13, 0.0014, 0.088. The cells with one attempt are
      the DP9 rows; the other five seats are unchanged from DP9 (N=1).

      - **None of the 9 graded FAIL rows is a zero-write; all made edits.**
        Tests green on broken code (failsOnOld only): `qwen3.5` on
        asohav-01 (rep 1), lfc-03 (rep 2) and asohav-02 (rep 2), and
        `qwen3:14b` on lfc-03 (rep 1). Suite broken: `qwen3.5` on asohav-01
        (rep 2), lfc-03 (rep 1) and asohav-02 (rep 1). Out of scope, twice:
        `qwen3:14b` on asohav-02 (4 and 7 writes, never inside `allowFiles`).
        There are no zero-write rows among the 21.
      - **lfc-03 owner acceptance, 5 graded rows.** `qwen3.6` 2/2 PASS;
        `qwen3.5` rep 2 PASS (right source, hollow test: the gates failed it) and
        rep 1 FAIL; `qwen3:14b` FAIL. Across all 18 lfc-03 runs with an
        acceptance result, 12 pass the owner tests and 8 pass every gate; none
        of the 8 has wrong source.
      - **Replicates are not independent evidence.** Over the same-config rows
        in the whole corpus, pairs run back-to-back (same opencode version, same
        day, under 4 h apart) agreed in 11 of 11; pairs from different batches
        disagreed in 8 of 21 (Fisher p = 0.03). Every mixed cell has its first
        row on opencode 1.18.32 and its later rows on 1.18.33
        (`qwen3.5`: asohav-01, asohav-02, lfc-02; `qwen3.6`: asohav-02), so
        version drift, session effects and regression to the mean cannot be
        separated here. `qwen3.5`'s DP9 "7/9" was optimistic: asohav-01 and
        asohav-02 passed once and then failed twice, lfc-02 failed once and then
        passed twice. Update 2026-09-30: split by opencode version, all 8
        disagreements are cross-version pairs (8 of 19); 0 of 11 back-to-back
        pairs and 0 of 2 same-version, different-session pairs disagree
        (roadmap.md → "By opencode version").
      - **Where the protocol's definition of done falls short.** The control ×
        kane-02 cell has one attempt, not three (`qwen3:14b` was not re-run
        there). The replicates in every cell straddle opencode 1.18.32 and
        1.18.33, which the "same config" key (prompt sha, `numCtx`, Ollama
        version) does not include. The PR bodies' tallies also pool rows from
        other configs (kane-04 4/4 and lfc-02 3/4 count a 2026-09-23 32k-era
        row; `qwen3.6`'s kane-02 3/5 and asohav-02 2/4 count 32k rows and, for
        kane-02, an older prompt).
      - **Cap.** `qwen3.6` kane-02 rep 1 ended on a `finish=length` step at
        exactly its 8192 `limit.output`, after its edits, so the gates still
        passed (1269 s against 476 s for rep 2). The top seat also reaches its
        cap.
      - Result files: PRs #62–#64, 44 files (21 `.json`, 21 `.jsonl`, plus the
        `_TIMEOUT_` and `_ABORTED_` transcripts) + 21 `tasks-summary.tsv` rows.

- [x] **Data point 12: replay audit of the 12 unaudited N>1 passes
      (2026-09-30).** Closes DP11's caveat. Method: transcript replay — each
      run's `write`/`edit` tool calls applied in order onto the pinned base
      files (`git show <benchBaseCommit>:<path>`), diffed vs base; removed
      lines checked for assertions, added tests checked against the prompt's
      required cases. Scratch script (not committed). Same audit-method caveat
      as DP9, met twice: OpenCode's loose-match fallback applies edits a
      verbatim replay misses (kane-04 rep 1's warn-capture helper), so the
      transcript's `newString`s are the source of truth where the two differ;
      and the script itself hit the DP7 mojibake trap (`git show` decoded with
      the OEM codepage — fixed with UTF-8 output encoding).
      - **10 genuine and spec-complete.** kane-04 × `qwen3.5` ×2 (digit 7/13
        plus unparseable→1 with the warning asserted — rep 1 via a warn
        tracker including no-warn-on-valid, rep 2 via a `console.warn` spy;
        removed lines are comments only). kane-02 × `qwen3.5` ×2 and ×
        `qwen3.6` ×2 (bigram-match-with-skip fix; all three required cases;
        removed lines are the buggy source line and a test-set extension).
        asohav-02 × `qwen3.6` ×2 (exactly the upstream fix — drop `id` from
        the insert; new file covers no-`id`, the exact 8-column snake_case
        set — rep 2 asserts key-set equality — and rejection propagation).
        lfc-03 × `qwen3.6` ×2 (transition matrix, throw naming id + current
        + requested status, full legal/forbidden coverage including a
        message-content test; owner acceptance PASS and scoped typecheck PASS
        on both).
      - **2 qualified — grades stand, footnoted.** lfc-02 × `qwen3.5` rep 1
        (`...165209`): the User-Agent version is hardcoded `0.0.0` —
        `new URL('../package.json', import.meta.url)` resolves to
        `src/package.json`, which does not exist, so the catch fallback fires
        in every environment; the real version is 1.5.0. The prompt's
        anti-drift requirement is unmet and its own test (a version-pattern
        regex `0.0.0` satisfies) cannot see it. lfc-02 × `qwen3.5` rep 2
        (`...165420`): the fix itself is correct (`../../package.json` → the
        real 1.5.0) but the run deleted the used
        `import type { CardFinish, CardVariant, ResolvedCard }` line, shipping
        a TS error no gate sees (typecheck is SKIP for lfc-02 by design;
        vitest strips types without checking).
      - **Net effect on the standings: nothing hollow, nothing overturned.**
        No pass among the 12 removed or weakened an assertion (contrast DP9's
        3/26 spec-short). `qwen3.5`'s lfc-02 cell (3/4) contains one spec-short
        pass; `qwen3.6`'s 6/6 are all clean. The lead is strengthened, not
        revised.
      - Cosmetic, both kane-04 reps: `Nazgûl` reached the test file as U+FFFD
        (read→edit round-trip through the loose matcher; arbitrary fixture
        strings, suite unaffected).

- [ ] **Greenfield trial: slice-0 webapp skeleton + first slice chain.** The
      scaffold-from-scratch shape is DECIDED (roadmap.md → "scaffold-from-
      scratch": plan shape B, decomposed slices; the translator seat is the
      planner). The step that makes it runnable for the next round of tests:
      author the slice-0 skeleton (React 9 + TS + Vitest, blank app, trivial
      passing test — a planning-time artifact, not an executor task), then
      have the qwen3.6 planner decompose the owner's plain-English webapp
      prompt into a slice chain of full manifest entries (`benchBaseCommit` =
      previous slice's head, `allowFiles` = source + test, accepts failing
      on previous slice before queueing). Executors run the chain through the
      untouched four gates in order. Do NOT spend compute on this until the
      blind-trial lanes clear — same gate as step 5. Decision detail: slice-0
      can't pass the `scope` gate (nothing to revert), so grading starts at
      slice 1; a greenfield task-kind (revert-scaffold) is explicitly deferred.

- [x] **`test-tasks.ps1` stamps the local desktop Ollama version onto
      remote-host runs.** Node3 is live on 0.34.2 (verified) but every
      node3 evidence `.json` from this session reads `"ollamaVersion":
      "ollama version is 0.34.3"`. Fix: query the target host's
      `/api/version` instead of localhost. Contained: the TSV has no
      version column, so corpus analysis is safe — only per-run files
      misstate it. Fix before the next results PR so new files stamp
      correctly. **Fixed 2026-09-25 (`7820266`):** the model id's provider
      picks the host's `*_BASE_URL`; non-Ollama providers stamp `n/a (…)`.
      Verified on desktop (0.34.3) and opencode-go (DP5 JSON reads `n/a`);
      a node3 run has not yet been stamped with the new code.
- [x] **Timeout runs print "Summary appended" but append nothing.** The 3
      timeouts above printed `Summary appended to tasks-summary.tsv`,
      added no row, and wrote no `_TIMEOUT_` transcript (repo-wide search:
      none exist from 2026-09-23). Extends the streaming item under
      "Next" above: at minimum make the message honest; the real fix is
      the `_TIMEOUT_` transcript the docs already promise. Until then a
      timeout is a pure unknown — slow-but-working and wedged look
      identical afterward. **Fixed 2026-09-25 (`bbf06db`):** events are
      appended to the transcript as they arrive, so the existing `_TIMEOUT_`
      rescue has content; the closing line reports the real row count; on
      timeout any `opencode` process whose command line names the worktree is
      tree-killed. Verified: a forced 180-s timeout on `qwen3:14b` kept a
      61 KB `_TIMEOUT_` transcript, wrote no row, left no process. The kill
      branch matched the real command line but was not needed that time (the
      child had already exited).
- [ ] **A human-killed lane gets tagged `_TIMEOUT_` by the harness.** The
      nightly `lfc-02 × node3` lane was stopped from another session (exit
      `-1`, a kill) and the batch labelled its transcript `_TIMEOUT_`.
      Renamed by hand to `_ABORTED_` for truthfulness — the harness should
      tag on `Stopped`/`Stop` vs cap, or at least not claim a timeout it
      did not measure. Related to the item above: both are "the tail of a
      run is evidence, and the label must be honest."

## Next steps (ordered, as of 2026-09-24)

Completed 2026-09-23 (kept as record):

1. ✅ #45 merged, #46 merged; pull main; branches deleted.
2. ✅ Fresh session: closed all `opencode` instances (harness PID included
   — it held the pre-sync config), new terminal, sourced `dev-desktop-only`,
   verified both base URLs + MANAPOOL unset. 8192 cap carried by the staged
   config.
3. ✅ Reran the timeout unknowns with headroom (PR #43's passthrough;
   `-OnlyMissing` re-targets exactly these — timeouts left no rows — and
   the sets are disjoint):
   - T1 desktop: `.\tests\run-tasks-batch.ps1 -Mode Tasks -Reps 1
     -OnlyMissing -RunTimeout 1800` → model `qwen3.6`, tasks
     `asohav-01, asohav-02`. **Result: PASS (`asohav-01`) + FAIL liar
     (`asohav-02`).** The "times out again at 1800 = seat finding" branch
     is resolved negative — the seat finishes, it just fails on
     `asohav-02`.
   - T2 node3: same command → model node3 `qwen3:8b`, task `lfc-02`.
     **Result: human-aborted at ~25 min, not a fatal timeout.** The "hangs
     again = host finding" branch is **not** met — operator kill, not a
     hang; cell stays open, next attempt resumes on node3.
4. ✅ Drafted the `qwen3.6` planner prompt (read-only explore + interview +
   work orders with planner-written acceptance tests; draft at
   `docs/agent-notes/planner-prompt-qwen3.6.md`). Keep first plans small
   and benchmark-shaped; planner test must fail on current code before the
   order queues. Bound to a mandatory mission line after blind-trial data
   point 1 (PR #50).

Open, in order — each gates the next:

5. **Blind trial v2 — first real work orders (protocol rewritten 2026-09-24
   after DP2).** Data points 1 and 2 are consumed; the old "recover session
   `ses_f2ef…` by replying with the mission line" is void. DP3
   (`ses_f299…`, 2026-09-24) is consumed too: Plan mode killed the live-checkout
   violation but stalled the seat (contract step 4 needs a write → 5-compaction
   question loop, no `## Work orders`). The protocol holds; the order is now
   drafted **outside the seat** — see the DP3 record above. Live state:
   - **Plan mode first (Step 0 in `docs/agent-notes/planner-prompt-qwen3.6.md`,
     owner action):** flip the bottom-left toggle to Plan before the first
     message so the seat physically cannot edit. If the session can edit files,
     stop — nothing in the contract is enforced. **DP3 caveat: Plan mode also
     denies the planner's own step-4 worktree verification** — a planner session
     can plan the order but not prove it failing-first. Both jobs now happen
     outside the seat: the planner proposes, the order is docketed by hand
     against the bench branch, the executor implements.
   - **Mission line:** `Target repo: M:/Projects/LFCbot` + `Target: <small
     defect/feature>`. **Target decision (owner, 2026-09-24): reuse DP2's own
     finding** — the `setStatus` guard at `listings.ts:297-301` (updates by id
     with no current-status guard; re-activating an already
     fulfilled/deleted/expired listing). DP2 already scoped it soundly (guard
     in the service layer, right test file); it is benchmark-shaped.
   - Protocol unchanged: branch per order (`order/<n>-<slug>` off `main`),
     2–3 files / ~300-line cap, planner-written acceptance test that FAILS on
     current code before the order queues, abort on 3 consecutive gate
     failures. Keep the target small — `qwen3.6` is the slowest seat (123 s
     probe, 1620 s `asohav-01` PASS against the 1800 cap, and DP2's first turn
     cost ~4 h).
   - **Accelerator A (calibration key):** spend the OpenCode Go key on the
     produced order once it exists — oracle on the *exact* order (task-design
     de-risk + first genuine successful trajectory = the Unsloth fine-tune
     gate). Cost cents; decision made 2026-09-24, action waits for the order.
     **Consumed 2026-09-25 — PASS on all four gates + 29/29 owner acceptance
     (see DP5 record above).**
- **Accelerator B (edit-format A/B):** package whole-file-write vs
      search-replace as the **first executor attempt** on that order, so the
      supplied-test run also measures the format question (write is 8/8 vs
      `edit` 11% in the corpus; `docs/methodology-research.md` → "Edit
      reliability"). One variable; keep it out of step 7's N=3 backfill.
      **Consumed 2026-09-25 — both arms FAILed (see DP4 record above).**
- Definition of done: ≥1 work order (repo + branch + allowFiles + testCmd +
      acceptance + prompt), acceptance verified failing-first, ≥1 executor
      attempt graded through the untouched four gates. **Status 2026-09-25: the
      work order is docketed** — `tests/tasks/manifest.json`
      `lfc-03-status-transition-guard` (full matrix contract from the DP3
      interview: `active`→fulfilled/deleted and fulfilled→deleted legal;
      everything else throws), acceptance block = 8 tests authored + verified
      failing-first by hand on bench branch `bench/status-guard-throw`
      (24/29 on unguarded `main`, 29/29 with a candidate guard, 343/343 full
      suite, scoped tsc clean). **Status 2026-09-25: first executor attempt
      RUN — `qwen3:14b` scored 0 for 2 on Accelerator B's A/B (write arm: scope/
      suite green, fails-on-old FAIL because it never wrote acceptance tests;
      edit arm: 1800-s timeout, ungraded). DoD is NOT met.** Accelerator A
      (the `qwen3.8-max` oracle run of the exact order) is queued with owner
      approval 2026-09-25; a ✓ there defines what a PASS looks like through
      the same four gates before any local re-seat. **Status 2026-09-25:
      Accelerator A RUN — the oracle PASSed all four gates and the owner
      acceptance tests (DP5). DoD met.** A local-seat PASS on the same order
      is still open.
    - **The launch itself is interactive** (Plan mode + numbered interview) —
      owner action; this doc's job is done when the order is a real
      `manifest.json`-shaped entry the harness can run.
6. **Close the measurement confound — control rematch + raised-cap reruns.**
   Lane A (control, desktop): `qwen3:14b` + `qwen3:8b` across all 8 tasks on
   Ollama 0.34.3 — owed before any seat decision cites the challenger gap.
   Lane B (desktop, `-RunTimeout 1800 -OnlyMissing`): the row-less timeout
   cells (`laguna-xs-2.1`, `nemotron-3.5-lightning`, `qwen3.6`,
   `north-mini-code-1.0`, `devstral-small-2:24b`) plus unfinished
   `qwen3-coder:30b-a3b` ×8. Partition lanes by task id statically up front
   (disjoint sets, verified against each lane's `-Tasks` list — the 09-23
   `kane-02` collision is the reason); stop procedure is driver-stop plus a
   `Get-Process opencode` check (Ctrl+C orphans the `opencode run` child);
   never the same task id in two terminals (worktree `:448` + install
   marker `:205` are task-id-keyed). Definition of done: control cells have
   same-harness rows; every offloader timeout cell has a graded row or a
   `_TIMEOUT_` transcript; per-attempt table updated.
   **Status 2026-09-27: frontier slice done (DP7)** — lfc-03, kane-02 and
   asohav-02 × the 10 desktop seats (7 on asohav-02), every cell a graded row
   or a `_TIMEOUT_`/`_INFRA_` transcript. Open: the other 6 tasks (control
   lane `qwen3:14b` + `qwen3:8b`, and the offloader cells), and a decision on
   the 4 context-overflow runs — they re-run meaningfully only after the
   64k-context question (roadmap) is settled. **2026-09-27: settled by DP8.**
   The six MoE/hybrid seats run at 64k, and the three frontier tasks were
   re-run on them: 9/18 PASS, versus 3/15 at 32k. The remaining 6 tasks
   should be run at 64k for these seats. Results from before the trial are
   32k rows, and `numCtx` in the JSON tells them apart.
   **2026-09-29: 8-seat plan done (DP9).** All 6 remaining tasks × the six
   64k seats and the qwen3 control pair: every cell has a graded row or a
   `_TIMEOUT_`/`_INFRA_` transcript. The control lane's DoD is met. Still
   open against the original Lane B list: `devstral-small-2:24b` on 5 tasks
   (run overnight, or drop with a recorded reason). `devstral:24b` is
   proposed for a drop.
7. **`qwen3.5:9b` to N=3 + node3 Q4 copy.** Desktop: N=3 on every task, Q8 as
   measured (the 5/6 record was earned on Q8 — Q4 is a separate experiment).
   Node3: pull Q4 (only strong seat small enough for 10 GB), probe first
   (`test-toolcalls.ps1 -Model qwen3.5:9b -OllamaHost http://NODE3_IP:11434`),
   then batch. Confirm node3 sleep disabled and `MANAPOOL_API_KEY` unset
   for `lfc-02`. Definition of done: N=3 graded rows per `qwen3.5` cell;
   node3 Q4 has probe + task rows or a recorded FAIL with shape.
   `ministral` (0/7), `lfm2.5` (0/8), `ornith` (1/7) stay out as executors.
8. **Harness honesty fixes, before the next results PR**
   (`tests/test-tasks.ps1` + `run-tasks-batch.ps1`): (a) stream timeout
   output inside the job (`Tee-Object`) so a timeout keeps a `_TIMEOUT_`
   transcript — at minimum stop printing "Summary appended" when nothing
   was appended; (b) tag kills vs caps (exit `-1` is `_ABORTED_`, not
   `_TIMEOUT_`); (c) stamp the target host's `/api/version`, not
   localhost's (node3 runs 0.34.2, its 09-23 files all say 0.34.3).
   Definition of done: a deliberate timeout leaves a transcript and no row;
   a killed lane tags `_ABORTED_`; a node3 run stamps 0.34.2;
   `test-profiles.ps1` still 100 PASS / 0 FAIL / 1 WARN / 2 SKIP.
   **Status 2026-09-25: (a) done (`bbf06db` — streamed transcript, honest
   summary line, orphan kill; the deliberate-timeout check passed on
   desktop) and (c) done (`7820266`), both in `test-tasks.ps1` only. Open:
   (b) kill-vs-cap tagging, the node3 0.34.2 stamp confirmation (needs node3
   up), and the `test-profiles.ps1` regression run.** 2026-09-27: two
   follow-ups to (a) landed — empty transcript created up front (a
   zero-event timeout still leaves a file) and UTF-8 decoding of opencode's
   stdout (DP7). New (d): tag compaction deaths (`generating summary`, and
   template crashes on a compacted history) `_CONTEXT_` instead of `_INFRA_`.
   DP9 widens (d): an output-cap truncation ends in the same template 400
   (`Cannot have 2 or more assistant messages`) with no compaction, so the
   tag should key on the error, not on a compaction having happened. New
   (e), found in DP9: the gates cannot see a test that fails on the old
   source but covers less than the prompt asks, which happened on 3 of 26
   passes. Candidate: an optional per-task `testMustCover` list (e.g.
   kane-01: the Background in the submitted deck; asohav-01: all seven
   routes), checked informationally like `acceptance`.
9. **Greenfield trial — slice-0 skeleton + first slice chain** (gated behind
   steps 5–6, no compute until blind-trial lanes clear). Slice-0 skeleton
   is a planning-time artifact (owner or hand-verified planner output,
   committed on `main` of a new benchmark repo: React 9 + TS + Vitest,
   blank app, one trivial passing test — grading starts at slice 1).
   Planner decomposes the owner's webapp prompt into ordered slices, each a
   full `manifest.json` entry (`benchBaseCommit` = previous slice's head,
   `allowFiles` = source + test, acceptance failing on the previous slice
   before queueing). Executors run the chain in order through the untouched
   gates; a slice that can't pass goes back to the planner. Definition of
   done: all slices pass in order with you only in planning + merge
   (milestone 5, greenfield). The `lfm2.5` version-rematch (drop
   `-OnlyMissing` deliberately) stays deferred until the lanes clear.
