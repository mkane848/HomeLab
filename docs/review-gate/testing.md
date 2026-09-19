# Verifying model-written changes: test veracity and the fix-and-reverify pass

> Companion to the review-gate methodology in
> [docs/lmstudio-vscode.md](../lmstudio-vscode.md). Written after the review of
> KaneEnabler PR #82 (2026-09-19): the deck-validity PR came in with a green
> suite (lint clean, `tsc` clean, 404 passed / 14 skipped / 0 failed) and a
> silent correctness bug a human PR review caught before any merge. This doc
> exists so that "the tests passed" is never again treated as "the feature
> works."

## Principle

**A passing suite is necessary, not sufficient.** This is the same shape as the
fleet's existing probe rule ("passing the probe is necessary, not sufficient" —
`tests/test-toolcalls.ps1` proves tools work, not that a recommendation
survives contact with its own evidence). For model-written code the corollary:

> A model-written test that passes does not prove the behavior it *claims* to
> cover. It proves only that the code path the test actually walked behaved as
> the test expects.

## Test veracity — the rule

Every new test an implementation adds must be audited against the **branch it
names**, not just run green:

- Read the test body and the target function together.
- Does the input the test constructs actually reach the branch the test's name
  or comment claims? If the test says "pairs correctly" but its arguments never
  enter the pairing path, it is a **false-positive test**: green on both the
  broken and the fixed code.
- Fix by adding the *missing-branch case* (e.g. pass the pair, not just the
  solo chooser) and confirm the new test **fails on the old code** and passes
  on the fix.

### Worked example: PR #82's Background pairing test

`deckValidation.ts` computed
`eligible = commanders.every(c => c.is_commander_eligible === 1)`, but a
Background card is `is_commander_eligible = 0` by definition, so a fully legal
pair (e.g. Tevesh Szat, Doom of Fools + Boarding Party) resolved to
`pairingLegal = false`. The fix is
`usableAsCommander = c => c.is_commander_eligible === 1 || c.is_background === 1`
and letting `legalUnits.some(...)` (via `buildCommanderUnits`) keep doing the
real pairing-legality check.

The PR's unit test "a Background companion needs the legal Background to pair"
never caught it because it passed only `[chooser]` — it exercised the harmless
solo-unit branch while claiming (by name and doc) to test the pairing branch.
The information needed to catch the bug (the `is_commander_eligible` comment
directly above `is_background` in the same file) was sitting in the code the
model was editing.

**A test's name and its body must agree; the body decides.**

## The fix-and-reverify pass (merge DoD for model PRs)

Before merging a model-produced change:

1. Re-run the gates (lint, typecheck, unit suite) on the actual checkout.
2. **Audit every new test** against the branch it claims to cover; add the
   missing-branch case and confirm it fails on the old code.
3. Run the **integration suite against real data** (seeded DB / live fixtures) —
   a suite that only runs in CI, or has never run locally, proves nothing
   locally.
4. Human merge review, then merge.

## Three-tier verification

| Tier | What it catches | PR #82 on review |
|---|---|---|
| Unit (branch-coverage audit) | tests that never enter their claimed branch | missed the Background pairing bug |
| Integration (seeded DB, real fixtures) | assertions that are internally incoherent or unproven | skipped locally — the 100-card assertion was CI-only |
| Human PR review | silent logic bugs the suite structure can't see | **caught it** — this doc's reason for existing |

Each tier catches what the tiers above it miss; all three are required before
"verified" is a word you use.

## Relation to the reviewer seat

The reviewer's seam checklist (see `reviewer.md`) now ends with a test-veracity
clause: *does each test the plan adds exercise the branch it names?* A plan
whose tests would be green on broken code is a FAIL on that seam — the run-2
reviewer granted PASS on a plan containing exactly such a test.