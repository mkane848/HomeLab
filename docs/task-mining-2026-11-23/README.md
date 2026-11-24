# Task mining, 2026-11-23: 13 tasks from lfc-bot and ASoHaV

On 2026-11-23 the owner asked a Claude Code cloud session to look for new benchmark tasks in lfc-bot and the ASoHaV
companion app, which had changed a lot since the last mining (2026-09-29, [audit-2026-09-29/](../audit-2026-09-29/)).
It answers the audit item "More tasks, not more runs" ([audit-2026-11-09.md](../audit-2026-11-09.md) → "Open: work
for an agent"). The owner picked 13 of the 20 verified candidates, and they are in `tests/tasks/manifest.json`:
**40 tasks, 27 before and 13 new, none with a graded row yet.**

Each task is a real, already-merged upstream fix. Its pin is the fix commit's parent, scoped down where the commit was
a bundle. Its acceptance oracle is the fix commit's own test files, except for `asohav-21`, whose tests are hand-scoped.

## The 13 tasks

| Task | What it is | Baseline → fix's tests alone → with the fix | Source files |
|---|---|---|---|
| `lfc-08-ready-clears-removal` | data loss: a guild that re-added the bot while it was offline stays marked and is purged 30 days later; one call at boot | 14 → 2 red → 14 | `ready.ts` (44 lines) |
| `lfc-09-digest-cutoff-watermark` | data loss: a listing posted while a digest is being sent never appears in any digest; a cutoff and a forward-only watermark | 35 → 5 red → 38 | `digest.ts`, `digest-state.ts` |
| `lfc-10-sealed-sync-join` | concurrency: a second catalog sync must join the one in flight (the same promise), and a later one start fresh | 34 → 1 red → 35 | `sealed.ts` (434 lines) |
| `lfc-11-sealed-same-name` | same-named products told apart (`Name (SET)`, `uuid:<uuid>` values); **spec reversal**, three existing tests encode the old rule | 46 → 8 red → 52 | `sealed.ts`, `constants.ts`, `have-sealed.ts`, `want-sealed.ts` |
| `lfc-12-guild-lifecycle` | three gaps between a server's digest job and whether the bot is in it (rejoin, restart, removal while offline) | 35 → 4 red → 36 | `guildCreate.ts`, `ready.ts`, `digest-state.ts`, `listing-expiry.ts` |
| `asohav-14-strain-clears-on-goal` | a ruleset change: Strain clears at the end of Combat only when the Goal was achieved; **reverses `asohav-08`**, whose old test must be rewritten | 20 → 1 red → 22 | `routes/combat.ts` |
| `asohav-15-combat-end-authz` | security: ending Combat read and re-saved the sheet of a character from another campaign | 30 → 1 red → 31 | `routes/combat.ts` |
| `asohav-16-sheet-get-authz` | security: any GM could read any character's sheet by id | 9 → 1 red → 11 | `routes/sheet.ts` |
| `asohav-17-invite-email-escape` | security: the GM-typed campaign name went unescaped into an HTML email | 8 → 1 red → 9 | `email.ts` |
| `asohav-18-next-round-guard` | a Postgres unique violation on a racing Start becomes a 409; a save may only keep Round or add 1 | 22 → 4 red → 30 | `routes/combat.ts` |
| `asohav-19-defaults-on-read` | three independent missing defaults in the normalizers of a 1,150-line file | 160 → 3 red → 163 | `packages/shared/src/logic.ts` |
| `asohav-20-motif-pad` | data loss: a save carrying two Motifs wiped both; one hunk in a 1,400-line file | 187 → 1 red → 189 | `packages/shared/src/logic.ts` |
| `asohav-21-invite-decline-pending` | race: a decline after a redemption wrote Declined over Accepted; **hand-scoped**, no acceptance block | 14 → 2 red → 15 | `routes/invites.ts` |

**Report them as their own cohort, and split lfc from ASoHaV.** Four of the five lfc tasks (`lfc-08`, `09`, `10`,
`12`) come from a state-machine audit that lfc-bot committed on 2026-11-20 (`8bdcd4d`). It recorded every bug it found
as an `it.fails` test, an expected failure that keeps CI green, and the fixes came in later commits. So at these pins
the suite already holds a named repro of the bug. That makes the task easier than a bare symptom, and it adds a step a
model can miss: a correct fix turns the `it.fails` into an unexpected pass, which vitest reports as a failure. The
model has to flip it to `it` and update the abstraction the conformance test replays. A source-only fix is red for
exactly that reason, which is also why `failsOnOld` bites. The prompts explain the convention and do not say which
test to flip.

Shapes the suite did not have before: the `it.fails` flip, a reversal paired with an existing task
(`asohav-14` / `asohav-08`), four source files in one task (`lfc-11`, `lfc-12`), and needle-in-a-big-file fixes
(`asohav-19`, `asohav-20`).

## How they were found

1. **Classification** (`rig/classify.py`, `results/classified.txt`): every non-merge commit on `main` since
   2026-09-26 that touches both source and tests. That was 147 commits (56 in lfc-bot, 89 in ASoHaV, 2 in KaneEnabler)
   and 48 hits, most of them features or release bundles. KaneEnabler had nothing to mine: a docs move, and a
   state-machine audit (`c2420b1`, 2026-11-23) that lists open defects with no fixes yet.
2. **Four arms in a fresh worktree at the fix's parent** (`rig/verify.sh`; `results/batch-lfc.out`,
   `results/batch-asohav.out`), installed with `npm ci --ignore-scripts` as the harness does: the baseline, the fix's
   tests alone, the fix with its tests, and the fix alone. 20 candidates passed.
3. **Stability** (`rig/repeat.sh`, `results/batch-repeat.out`): the fixed run three times and once under
   `TZ=Pacific/Auckland`. All 20 gave identical counts. The instruction file at every pin is 12 to 19 KB (`AGENTS.md`
   for lfc-bot, `CLAUDE.md` for ASoHaV), far from the 280 KB that retired `asohav-05` and `asohav-06`.
4. **The whole package suite with the fix** (`rig/fullsuite.sh`, `results/batch-full.out`): a check the 2026-10 rig
   did not have. It caught the owner's first pick for `lfc-12`, the rejoin fix alone: that fix turns the server model's
   conformance test red (1 of 857), because upstream fixed all three gaps in one commit and updated the model once. The
   owner chose the whole commit instead. All 13 keep their package suite green.
5. **The real harness** (`rig/`, `results/rig-matrix.txt`): today's `tests/test-tasks.ps1` (llama.cpp-era, sealed
   checkouts) on Linux, with a stand-in `opencode` that applies the reference patches. Arms: `-DryRun`, `ref`,
   `srconly`, `testsonly`, `ref` with dummy `DATABASE_URL` and `MANAPOOL_API_KEY`, `ref` under
   `TZ=Pacific/Auckland`, and a repeat of `ref`. Every verdict was as expected. `ref` and its three variants passed
   every gate with acceptance PASS. `srconly` was suite FAIL for the `it.fails` and reversal tasks and `failsOnOld` FAIL
   for the rest. `testsonly` was scope FAIL and suite FAIL.
6. **Mutation checks** (`rig/mutate.py`, `rig/variants.py`; `results/mutate.out`, `results/variants.out`). Each source
   hunk of the reference fix was dropped in turn, and some wrong variants were tried. A change that stays green under
   the upstream tests is listed below.

## What the gates cannot check

Only a model's own tests, graded by `failsOnOld`, can catch these partial fixes. The upstream tests stay green with
them.

- `asohav-17`: **exporting `escapeHtml` and never using it** in the email body (the upstream test calls the function
  only). Also the subject's line-break rule.
- `lfc-09`: `runDigest` still selecting up to `now()` instead of the cutoff. That is a duplicate next time, not a loss.
- `lfc-11`: the set-code tiebreak in the ordering.
- `asohav-20`: truncating a list of more than three Motifs.
- `asohav-21`: the 409's message (only the status is asserted).

Everything else that was tried went red: every hunk of `lfc-08`, `lfc-09`, `lfc-12`, `asohav-15`, `asohav-18` and
`asohav-19`, plus wrong variants of each task (a watermark that moves back, a guard never cleared, a joined call
returning a new promise, no shortening, an empty cache marking everything, a non-integer or skipped Round, an
existence-only character check, an unescaped apostrophe, copying three Motifs).

## Not added

| Candidate | Fix | Why |
|---|---|---|
| `closed-listings` (lfc) | `9c5381e` | 7 source files, 54 → 10 red → 59: verified, held for the parked "larger Stage 2 project" |
| `auth-outage-503` (ASoHaV) | `0f4a281` | a new test file, so the baseline must be the full server suite (as `asohav-09`); held |
| `campaign-phase-race` (ASoHaV) | `17209ae` | six existing tests are tied to the exact repo calls; the prompt would have to dictate them; held |
| `admin-changelog` (ASoHaV) | `0f4a281` | two fixes bundled, and it also needs `types.ts`, which vitest does not check; held |
| `library-id-immutable` (ASoHaV) | `f6dc24c` | one field-order fix, likely to saturate like `kane-12` |
| `bond-spend-v07` (ASoHaV) | `cdd6eeb` | a verbatim-text check: the prompt would have to give the text |
| invite redemption and character-creation cleanup, the Strain-offer route, request-body checks (ASoHaV) | `0f4a281`, `1170b7a`, `926c2f0` | each fix creates a new source file (`bestEffort.ts`, `offers.ts`, `body.ts`), which the revert cannot grade |
| `digest-pause-overlap` (lfc) | `e201108` | needs a drizzle migration with a generated 1,024-line snapshot |
| the 0.83.0 campaign changes (ASoHaV) | `f6dc24c` | four fixes in one file; would need hand-scoped tests |
| the rejoin fix alone (lfc) | `af2a8e6` | breaks the server model's conformance test (above); replaced by the whole commit as `lfc-12` |

`asohav-21` is hand-scoped for the same new-file reason. The same commit also moved the redemption rollback to
`releaseInviteClaim`, a repo function that does not exist at the parent. The route tests mock the repo module, so
they would pass anyway. Those hunks (one source, two test) are dropped, and the task covers the decline only
(`reference-patches/asohav-21-*.upstream.patch` are the unscoped originals).

**Next mining:** KaneEnabler, once its state-machine audit's fixes land. They should give tasks of the same shape as
lfc-bot's.

## Running them (the owner, on Windows)

`.\tests\run-tasks-batch.ps1 -SetupOnly` creates the `bench/*` labels and fetches what the clones lack. Then, per new
task, `.\tests\test-tasks.ps1 -Task <id> -DryRun` checks the install, the baseline and the acceptance tests failing on
the untouched base, on a CRLF checkout, which this Linux session could not do. By hand:

```powershell
# M:\Projects\LFCbot
git fetch origin
git branch bench/ready-clears-removal 8bdcd4d009a23cd9041f3e675b0b28bebb30512e
git branch bench/digest-cutoff-watermark 8bdcd4d009a23cd9041f3e675b0b28bebb30512e
git branch bench/sealed-sync-join 660f3265acdb07dd53c6f05e9ddd9d0215b30b4a
git branch bench/sealed-same-name 2e0e833f548156c60aea5299cde35f5446f642e2
git branch bench/guild-lifecycle cb2338c3f8248a8f4880e4cc3e119fc1f23a1733

# M:\TTRPG\A Story of Heroes and Villains
git fetch origin
git branch bench/strain-clears-on-goal c761a356b27fff4489032e1153b84f270d02996a
git branch bench/combat-end-authz 0bf6052ba9cc74e4d6684f2e6b960d9d992c3297
git branch bench/sheet-get-authz 0bf6052ba9cc74e4d6684f2e6b960d9d992c3297
git branch bench/invite-email-escape 0bf6052ba9cc74e4d6684f2e6b960d9d992c3297
git branch bench/next-round-guard 4b63a80a9cc563f363eac28926b042568a2d8ca2
git branch bench/defaults-on-read 42493a1531e8e3b01bb1706c35725b5b821ced24
git branch bench/motif-pad 208ec7ff7d011db1079dea55e440d9c1d9b5d4b6
git branch bench/invite-decline-pending f0f6779b8ae729738761710d4fe22724f39e4b4d
```

A bare `-OnlyMissing` batch would queue 13 more tasks for every seat. Pick them with `-Tasks`, and keep the cohort's
rows apart from the 27 until each seat has comparable runs on both.

## What is here

| Path | What |
|---|---|
| `rig/` | The scripts as run, keeping the session's scratch paths (like [audit-2026-09-29/validation-rig/](../audit-2026-09-29/validation-rig/)): `classify.py`, `verify.sh` and the `batch-*.sh` drivers, `repeat.sh`, `fullsuite.sh`, `mutate.py`, `variants.py`, `build_entries.py` (which wrote the 13 entries), and the harness rig: `standin.ps1` (the stand-in `opencode`), `lane.sh` and `summarize.py` |
| `results/` | The raw output of each step above, and `rig-matrix.txt` (every gate verdict, 13 tasks × 7 arms) |
| `reference-patches/` | The source and test patch of each task, cut from the upstream fix commits. `asohav-21`'s are hand-scoped, and its upstream originals sit beside them. `lfc-12-guild-rejoin-digest.*` is the first pick that was replaced |

The rig ran on an earlier draft of the prompts. The gates never read the prompt (only the run JSON's prompt hash
changes), and the entries' other fields are the same.
