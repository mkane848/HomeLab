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

- [ ] Seats: `ollama-desktop/qwen3:8b` and `ollama-node3/qwen3:8b`, **run
      concurrently** — that is the stated reason node3 was onboarded, and since
      node3's `qwen3:8b` is bit-identical weights over CUDA against desktop's
      Vulkan, any systematic split between them flags a backend artifact for
      free.
- [ ] **Hold `qwen3:14b` out of this batch.** It needs its own `kane-01` re-run
      post-cap-fix to establish whether its record was truncation or capability
      — a separate question from task breadth.
- [ ] **N=3 first, not N=10.** 5 tasks × 2 seats × 3 = 30 runs satisfies the
      repo's own action gate (">=3 graded runs across >=2 tasks",
      `test-tasks.ps1` header) and surfaces a broken task definition after 6 runs
      rather than 20. Fill to the N=10 statistical target only for cells that
      come through clean. `run-tasks-batch.ps1` defaults reps to 1 — set it
      explicitly at the prompt.

The batch runner now refuses to start against a host that is not answering, so a
dead endpoint can no longer burn a batch silently.

## Open follow-ups, not yet done

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
