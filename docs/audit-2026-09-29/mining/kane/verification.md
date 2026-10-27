# Verification log (KaneEnabler mining, 2026-09-29)

Environment: Linux x86_64, node v22.22.2, pnpm 10.33.0. Every candidate verified in a FRESH `git worktree add --detach` off
`mine-kane/repo` (a `git clone --local` of the read-only mirror), install = `pnpm install --frozen-lockfile --ignore-scripts
--store-dir mine-kane/pnpm-store` (the store is a content-addressed cache, not a checkout; node_modules is created fresh per worktree).
Install takes ~6 s with a warm store. `--ignore-scripts` did NOT break anything for the vitest suites used here (better-sqlite3's
native build is skipped, and none of the scoped suites import it).

## BASE: review-gate/deck-validity tip 92a8ed0 (kane-01's base; branch tip == 92a8ed0df10262cc878d4d214d0a312d542375ec, verified by
`git fetch --depth=300 https://github.com/mkane848/kaneenabler review-gate/deck-validity` on 2026-09-29; branch is exactly ONE commit
(92a8ed0 "feat: add POST /api/deck-validity ...") on top of main's 54cd6ca (= "Merge pull request #81"))

### dv-base worktree (fresh, detached at 92a8ed0)
```
$ cd apps/commander-recommender/server && pnpm exec vitest run src/services/deckValidation.test.ts
 Test Files  1 passed (1)
      Tests  10 passed (10)
```
=> baseline 10/10 (matches kane-01 baselineExpect 10/10). No `setup` step needed to RUN vitest: packages/rules/package.json exports
`"import": "./src/index.ts"` (only the scoped typecheck needs the @mtg/rules build - see kane-01's setup block).

---
## K05 — deck-validity: singleton copy limit (CR 903.5b) — OWNER-DIAGNOSED DEFECT, no upstream fix commit exists
Source of the defect: docs/vscode.md "Arbiter verification" item (2) "the singleton paper-rule isn't checked" and
docs/implementation-tasks.md task 6 ("Pre-existing, still open: singleton paper-rule"). The branch has one commit (92a8ed0) so it is
unfixed by construction. There is no merged fix, so the ACCEPTANCE TESTS and the REFERENCE FIX below were authored by me and verified
here (artifacts/kane-05.*). Fresh worktree wt/dv-k05 @ 92a8ed0df10262cc878d4d214d0a312d542375ec, pnpm install --frozen-lockfile --ignore-scripts.
```
[baseline, untouched tree]        Test Files 1 passed (1) | Tests 10 passed (10)
[acceptance tests only, src unfixed]  Tests  5 failed | 13 passed (18)        <- failsOnOld = 5/18
    x two copies of a nonbasic card break the rule and invalidate the deck        (true !== false on result.isValid)
    x the same card spread over several lines counts as several copies, however it is cased   (true !== false)
    x a nonbasic land with a basic land type is not exempt                          (true !== false)
    x an "up to N" card is allowed exactly N copies and reports its own limit beyond that   (true !== false)
    x a banned card listed twice is reported as banned, not as a singleton violation  (TypeError: result.singleton undefined - shape-only)
[acceptance tests + reference fix]  Test Files 1 passed (1) | Tests 18 passed (18)
[scoped typecheck, kane-01's setup step (build @mtg/rules) + _bench-typecheck.json over the 2 files]  tsc exit=0
```
(4 of the 5 reds are behavioural: `isValid` is true on the unfixed source for a deck with 2x Sol Ring; 1 is shape-only (new result field).
Three of the 8 new tests are green-on-old CONTROLS (one copy each valid; basics/snow/Wastes exempt; Relentless Rats "any number" exempt).)

TRAP FOUND (important for prompt fairness): the 10 existing tests model filler "Plains"/"Island"/"Artifact Land" as generic creature cards with quantities
up to 99. With a CORRECT singleton fix, 4 of those 10 ORIGINAL tests go red:
```
[reference fix + ORIGINAL 10-test file]  Tests 4 failed | 6 passed (10)
   x exactly 100 cards with a legal commander is valid
   x a colorless deck is vacuously within any identity
   x a legal Partner pair is one commander unit with the union identity (702.124e)
   x a Background companion needs the legal Background to pair
```
so an executor must update the fixtures (type_line 'Basic Land — Plains', etc.) instead of weakening the fix. That is a feature of the task, and the
prompt must say so (it does). Setup needed only for the OPTIONAL scoped typecheck (same `setup` as kane-01); vitest resolves @mtg/rules to src.

---
## K06 — deck-validity: named commanders checked against legality_commander + banned/notFound dedupe — OWNER-DIAGNOSED DEFECTS, no upstream fix commit
Source: docs/vscode.md "Arbiter verification" items (1) "named `commanders` are never checked directly against `legality_commander` — ban enforcement is incidental,
only firing when the pasted `list` duplicates the commander line" and (4) "`banned` / `notFound` are per-line name lists, not deduped"; docs/implementation-tasks.md task 3 (+DoD:
"a banned commander omitted from `list` is reported in the verdict; the deck-size total stays correct; the existing suite stays green") and task 6.
Fresh worktree wt/dv-k06 @ 92a8ed0df10262cc878d4d214d0a312d542375ec. Acceptance tests + reference fix authored by me (artifacts/kane-06.*). The fix lives in the PURE
service (deckValidation.ts) rather than routes/deckValidity.ts (the route needs a seeded SQLite DB and its integration suite is skipped locally), which is where the
diagnosis's DoD is unit-testable.
```
[baseline, untouched tree]            Test Files 1 passed (1) | Tests 10 passed (10)
[acceptance tests only, src unfixed]  Tests  5 failed | 13 passed (18)     <- failsOnOld = 5/18
    x a banned commander missing from the pasted list is still reported as banned          (isValid true !== false)
    x a commander that is not_legal or restricted is treated the same way                   (AssertionError: not_legal)
    x a banned card on two lines is reported once, and both copies still fill slots         (banned deepEqual: ['Banned Card','Banned Card'])
    x banned lines that differ only by case are one card; distinct cards keep first-seen order
    x an unresolvable name on several lines is reported once in notFound, all copies counted
[acceptance tests + reference fix]    Test Files 1 passed (1) | Tests 18 passed (18)
[scoped typecheck as for K05]         tsc exit=0
```
All 5 reds are behavioural (no missing-field/import errors). 3 of the 8 new tests are green-on-old CONTROLS that guard against a naive fix that double-reports a commander who is also on the list
(same spelling, different case) or flags a legal commander.

---
## M1 — e952198 (2026-08-26) "Fix produces-only supporters and death-trigger/sacrifice-cost false positives in Aristocrats" — SCOPED to signals.ts + signals.test.ts
Fix commit: e95219824e1c9d30da1f48ba160cf69560b40e14, parent 45095ab148d27fdbe20765a112d1dd7d743e4fcd (merge of PR #74). Scoped down: dropped synergy.ts + synergy.test.ts
(the 5th sub-fix, `supporterMatches` produces-only exclusion), CHANGELOG, docs. Remaining = four independent regex/helper false-positive fixes, all in signals.ts (tests: 4 real-card fixtures).
Fresh worktree wt/m-e952198 (blob ids of signals.ts/signals.test.ts at the parent match the fix diff's `index` base lines: 040f3fb / 06cfeab).
```
$ cd apps/commander-recommender/server
[baseline]  pnpm exec vitest run src/services/signals.test.ts        -> Test Files 1 passed (1) | Tests 234 passed (234)
[fix commit's signals.test.ts only, signals.ts unfixed]              -> Tests 4 failed | 234 passed (238)      <- failsOnOld = 4/238
    x a "would die ... instead" replacement effect is not a death-trigger reward                          AssertionError: Expected values to be strictly equal
    x a combat-kill trigger on an opponent's creature is not "your board dying" value                     AssertionError: Expected values to be strictly equal
    x a triggered ability's condition does not bleed into its unrelated effect across a comma             AssertionError: Expected values to be strictly equal
    x creature listed alongside other fungible resources in a sacrifice cost is not a creature-specific outlet   AssertionError: The expression evaluated to a falsy value
[+ fix commit's signals.ts]                                          -> Test Files 1 passed (1) | Tests 238 passed (238)
[whole server suite, only signals.ts+signals.test.ts taken from fix] -> Test Files 13 passed | 2 skipped (15) | Tests 392 passed | 10 skipped (402)   (skips = integration suites needing a seeded DB)
```
No `setup` step (vitest resolves @mtg/rules to src via the `import` export condition; confirmed by the run above with no build). The parent's tree has @mtg/rules present
(`packages/rules` exists at 45095ab) and signals.ts imports `parseCreatureTypes`/`hasChangeling` from it.
Hidden constraint worth knowing (from the source comments): the death-trigger `rewards` matcher MUST stay a plain RegExp - findQualifier skips function matchers, so converting it
to a function would silently make every Aristocrats death-trigger unqualifiable. VERIFIED by experiment (temporary edit in wt/m-e952198, then restored to 238/238): rewriting
that one regex as a `(f) => clauses(f.text).some(...)` function matcher turns 2 EXISTING tests red (Tests 2 failed | 236 passed (238)):
  x goWide borrows Cat from kindred, and aristocrats qualifies to Cat on its own text
  x a kindred consumer is read from the cost, not wherever the type is mentioned
so the trap is caught by the pre-existing suite (an executor that only runs its own new tests would miss it).

---
## M2 — 731e985 (2026-08-22) "Fix findQualifier to tie the candidate type to the payoff matcher's match" — signals.ts + signals.test.ts (clean 2-file commit, no scoping needed)
Fix commit 731e98508f53528647418403133c63c437307313, parent 10889539112089dcd122014f934520f9f11cf558 (merge PR #35). Fresh worktree wt/m-731e985; parent blobs match the diff's `index` base lines (signals.ts 7965985, signals.test.ts aeb6b7d).
```
$ cd apps/commander-recommender/server
[baseline]                         vitest run src/services/signals.test.ts -> Test Files 1 passed (1) | Tests 76 passed (76)
[fix's signals.test.ts only]       -> Tests 1 failed | 76 passed (77)     <- failsOnOld = 1/77
    x qualifies by the type the payoff actually restricts, not the first type word in the clause    AssertionError: expected a Human-qualified reanimator signal
[+ fix's signals.ts]               -> Test Files 1 passed (1) | Tests 77 passed (77)
[whole server suite at that state] -> Test Files 12 passed | 2 skipped (14) | Tests 201 passed | 9 skipped (210)
```
No setup step needed.

---
## 271636f (2026-08-21) "Fix bugs found in a tech-stack audit ..." — a NINE-bug, 24-file bundle; five of its bugs are independent 2-file (src + sibling test) fixes. Each verified in its OWN fresh worktree at the parent.
Fix commit 271636f41a6e31f24d88f2a8cd8101935b02e76e, parent 605a2e080cfddee855337f1b3d0b9cf7e48ddd6e (merge of PR #25). Scoped down per candidate to one src file + its test (docs/CHANGELOG/package.json version bumps dropped).
The other 4 bugs of the bundle (import-scryfall.ts DFC type_line; /api/cards oracle_id cap (integration test only, skipped w/o DB); ExportControls setTimeout cleanup (no test); signals.ts self-reference
stripping for Adventure names (kept in the shortlist, not verified)) are not used.

### P1 UndoToast (apps/time-counters) — fresh wt/m-undo — timer keyed on cardName instead of removal identity; needs a NEW `instanceId` prop plumbed through App.tsx (2 src files) + a NEW test file
```
$ cd apps/time-counters      (jsdom + @testing-library/react + vi.useFakeTimers)
[baseline, FULL suite - the test file does not exist at the parent]  vitest run -> Test Files 8 passed (8) | Tests 108 passed (108)
[+ fix's UndoToast.test.tsx, src unfixed]                              -> Test Files 1 failed | 8 passed (9) | Tests 1 failed | 110 passed (111)   <- failsOnOld = 1/111
    x restarts the dismiss timer when a second same-named card is removed within the window   AssertionError: expected "vi.fn()" to not be called at all, but actually been called 1 times
[+ fix's UndoToast.tsx + App.tsx]                                      -> Test Files 9 passed (9) | Tests 111 passed (111)
```
(the other 2 UndoToast tests - auto-dismiss at 6 s, shows the card name - pass on the unfixed component, i.e. they are controls; the new required prop `instanceId` is ignored by the old component.)

### P2 ComboPreferenceRow (apps/home) — fresh wt/m-combo — SECURITY: a stored `snapshot.permalink` of any scheme (incl. javascript:) rendered as an <a href>
```
$ cd apps/home
[baseline]                   vitest run src/routes/Profile.test.tsx -> Test Files 1 passed (1) | Tests 10 passed (10)
[+ fix's Profile.test.tsx]   -> Tests 1 failed | 10 passed (11)     <- failsOnOld = 1/11
    x never renders a combo permalink with a non-https scheme, since snapshot is unvalidated jsonb    AssertionError: expected <a class="profile-combo-link" …(3)></a> to be null
[+ fix's ComboPreferenceRow.tsx] -> Test Files 1 passed (1) | Tests 11 passed (11)
```
(the same test file also gains an assertion that a normal https permalink still renders with the right href - a control that passes on old code.)

### P3 frontFaceField (packages/card-model, plain JS) — fresh wt/m-fields — adventure cards read Scryfall's JOINED top-level mana_cost/power/toughness; split cards must keep it
```
$ cd packages/card-model
[baseline]                   vitest run src/scryfallFields.test.js -> Test Files 1 passed (1) | Tests 20 passed (20)
[+ fix's test file]          -> Tests 1 failed | 21 passed (22)     <- failsOnOld = 1/22
    x reads only the front face for an adventure card, not the joined top-level value    AssertionError: expected '{2}{R} // {1}{R}' to be '{2}{R}'
[+ fix's scryfallFields.js]  -> Test Files 1 passed (1) | Tests 22 passed (22)
```
(the new "reads a split card's combined top-level mana cost" test passes on old code: a CONTROL that punishes the naive "always take the front face" fix.)

### P4 useAuth (packages/profile) — fresh wt/m-useauth — getSession() rejection leaves `loading` true forever (missing .catch), React hook via renderHook
```
$ cd packages/profile
[baseline]                   vitest run src/useAuth.test.ts -> Test Files 1 passed (1) | Tests 11 passed (11)
[+ fix's test file]          -> Tests 1 failed | 11 passed (12)     <- failsOnOld = 1/12
    x stops loading (rather than hanging forever) when the initial session check rejects (1018ms = waitFor timeout)   AssertionError: expected true to be false
[+ fix's useAuth.ts]         -> Test Files 1 passed (1) | Tests 12 passed (12)
```
### P5 errorHandler (apps/commander-recommender/server) — fresh wt/m-errhandler — malformed JSON body mapped to 500 instead of 400
```
$ cd apps/commander-recommender/server
[baseline]                   vitest run src/errorHandler.test.ts -> Test Files 1 passed (1) | Tests 3 passed (3)
[+ fix's test file]          -> Tests 1 failed | 4 passed (5)     <- failsOnOld = 1/5
    x reports a malformed-JSON body as 400, not 500 — express.json() marks it a client error    AssertionError: expected "vi.fn()" to be called with arguments: [ 400 ]
[+ fix's errorHandler.ts]    -> Test Files 1 passed (1) | Tests 5 passed (5)
```
(the second new test - a plain SyntaxError with no status must still be 500 - passes on old code: a control.)
No `setup` step needed for any of P1-P5 (vitest resolves the workspace packages to src; --ignore-scripts install was sufficient in every worktree).

---
## N1 (beyond bug fixes, shape (a): a 4-source-file bug fix) — 4029a94 (2026-08-16) "fix(time-counters): Fading permanents sacrificed one upkeep early"
Fix commit 4029a94a8bd5a22df1f3dcf819719c0e448270b4, parent f7d9bc129a22daa93ae5ae094e6e3205e1ed717c. Fresh worktree wt/m-fading. Src files touched by the fix (4): apps/time-counters/src/hooks/useGameState.ts,
src/utils/counters.ts (new exported predicate hasHitTarget), src/types.ts (new TrackedCard.fadeExhausted), src/components/CardTile.tsx (dedupes its own copy of the check). Tests: useGameState.test.ts (+68), counters.test.ts (+44).
```
$ cd apps/time-counters
[baseline]   vitest run src/hooks/useGameState.test.ts src/utils/counters.test.ts -> Test Files 2 passed (2) | Tests 38 passed (38)
[fix's useGameState.test.ts ONLY (hook-level behaviour), all src unfixed]  -> Tests 2 failed | 21 passed (23)      <- behavioural failsOnOld = 2/23
    x a Fading N card survives N+1 upkeeps — only flagged ready on the upkeep the removal fails   AssertionError: expected [ { …(8) } ] to deeply equal [ ObjectContaining{…} ]
    x removeCard logs a Fading card as resolved only once exhausted, not merely at 0             AssertionError: expected 'Resolved' to be 'Removed'
[+ fix's counters.test.ts, src unfixed]  -> Test Files 2 failed (2) | Tests 7 failed | 41 passed (48)   (5 extra reds = `TypeError: hasHitTarget is not a function` - a NEW EXPORT the tests import)
[+ fix's 4 src files]  -> Test Files 2 passed (2) | Tests 48 passed (48)
[whole time-counters suite at that state]  -> Test Files 4 passed (4) | Tests 58 passed (58)
[only useGameState.ts taken from the fix, other 3 src files left at the parent]  -> the whole hook suite goes red (useGameState.ts imports the not-yet-existing hasHitTarget) - i.e. the REAL fix is inherently multi-file
```
Caveat: 3 of the 5 new hook tests (stops re-triggering once exhausted; Vanishing unchanged; manual edit clears the flag) are controls that pass on the unfixed code, and the UI symptom
(CardTile's "Ready to sacrifice" badge one turn early) has NO test in the fix commit - only the hook-level behaviour is graded. counters.test.ts pins a new API (`hasHitTarget(card)`), so a prompt must
either spell that API out or grade only the hook-level tests.

---
## M3 — e0ef290 (2026-08-24) "Restore subset colour-filter semantics" — SCOPED to client/src/lib/filters.ts + filters.test.ts
Fix commit e0ef290365bc43031357ecc454e7e5e7554f3e99, parent f0abf087f92323e69a0a706e14c22b427fb80d31 (merge of PR #64). Scoped down: dropped RecommendationResults.tsx / ResultFilters.tsx / ResultFilters.test.tsx / filters.css (the
"muted colour pip" UI feature), CHANGELOG, docs. Fresh worktree wt/m-colorfilter (client package already depends on @mtg/rules, no package.json change needed).
```
$ cd apps/commander-recommender/client
[baseline]                       vitest run src/lib/filters.test.ts -> Test Files 1 passed (1) | Tests 16 passed (16)
[fix's filters.test.ts only]     -> Tests 3 failed | 14 passed (17)     <- failsOnOld = 3/17 (two EXISTING assertions flip + one new)
    x color include keeps only identities that fit inside the included colors
    x color include keeps a colourless commander — the empty identity is a subset of anything
    x Abzan does not survive an R+G include                                   (all: AssertionError: Expected values to be strictly deep-equal)
[+ fix's filters.ts]             -> Test Files 1 passed (1) | Tests 17 passed (17)
```
Shape note: a SPEC REVERSAL - the pre-existing tests encode the old "touches this colour" semantics and must be rewritten (two of the three reds are old assertions whose expected values flip), unlike kane-02/03/04 which only add tests.

## M4 — cf2d0e5 (2026-09-02) W6 "Memoize buildCollectionProfile with a bounded LRU keyed on full row content" — synergy.ts + synergy.test.ts (a PERFORMANCE-shaped change)
Fix commit cf2d0e5eef7fbed9354585347aa55e9384577892, parent db6cf3364ee7b3750bb87efdb2fabc1ef2cc270d. Scoped: dropped the other ~44 files of the KimiAudit bundle. Fresh worktree wt/m-memo.
```
$ cd apps/commander-recommender/server
[baseline]                      vitest run src/services/synergy.test.ts -> Test Files 1 passed (1) | Tests 48 passed (48)
[fix's synergy.test.ts only]    -> Tests 1 failed | 48 passed (49)     <- failsOnOld = 1/49
    x memoizes: the same list returns the same profile instance, and any change in a row differs   AssertionError: Values have same structure but are not reference-equal
[+ fix's synergy.ts]            -> Test Files 1 passed (1) | Tests 49 passed (49)
```
The test cannot see the LRU bound (100 entries) or the recency refresh; only identity-on-hit and no-collision-on-changed-row are graded.

## M5 — cf2d0e5 F5/W3 "Batched card-preference writers" — packages/profile useCardPreferences.ts + test (a FEATURE SLICE: two new exported hooks)
Fresh worktree wt/m-batchprefs @ db6cf3364ee7b3750bb87efdb2fabc1ef2cc270d.
```
$ cd packages/profile
[baseline]                      vitest run src/useCardPreferences.test.tsx -> Test Files 1 passed (1) | Tests 10 passed (10)
[fix's test file only]          -> Tests 6 failed | 10 passed (17)     <- 6/17, ALL `TypeError: useSetCardPreferences|useRemoveCardPreferences is not a function` (new exports = the feature)
[+ fix's useCardPreferences.ts] -> Test Files 1 passed (1) | Tests 17 passed (17)
```

---
## N4 (beyond bug fixes, shape (d): behaviour-preserving refactor with an existing safety net) — consolidate 5 identical private `parseJsonArray` copies into one export in types.ts
Upstream did exactly this inside db6c1cb (2026-08-17, "... dedupe parseJsonArray"; its other hunks are unrelated fixes, so the refactor is NOT a clean upstream commit and the reference below is MY OWN re-application of just that hunk set).
Parent = db6c1cb^ = 2945ca84abdf0ca010d23e80ab49ba369f0026e2 (2026-08-16 "feat(commander-recommender): TanStack Router"). Fresh worktree wt/r-parsejson, install as always.
```
$ cd apps/commander-recommender/server
[baseline]  vitest run (whole server suite) -> Test Files 13 passed (13) | Tests 186 passed (186)     tsc --noEmit -> exit 0     structural probe `git grep -n 'function parseJsonArray' -- src | wc -l` -> 5
   (identical copies in routes/combos.ts, routes/recommend.ts, services/partners.ts, services/signals.ts, services/synergy.ts)
[my reference refactor: export from src/types.ts, 5 files import it, 5 local copies deleted; 6 files, +16/-54]
            vitest run -> Test Files 13 passed (13) | Tests 186 passed (186)     tsc --noEmit -> exit 0     structural probe -> 1 (src/types.ts:51)
[mutation A: make the shared parseJsonArray always return []]   -> Tests 18 failed | 168 passed (186), 3 files   (the services' logic is really exercised)
[mutation B: delete recommend.ts's import of parseJsonArray (a broken refactor)]
            vitest run -> Test Files 13 passed (13) | Tests 186 passed (186)   <-- THE UNIT SUITE DOES NOT NOTICE (routes are only covered by the DB-seeded integration suites, skipped here)
            tsc --noEmit -> src/routes/recommend.ts(91,62): error TS2304: Cannot find name 'parseJsonArray'   exit 2   <-- only the typecheck catches it
```
=> This shape CANNOT be graded by the current harness: (i) there is no test change and the source revert leaves the suite green, so the `failsOnOld` gate would FAIL a correct refactor, (ii) `typecheck` is informational
(PASS/WARN) though it is the only thing that catches a dropped import in a route file, and (iii) "the copies are gone" is a structural property no gate expresses. Minimal harness change: a task-level `kind: "refactor"`
that (a) skips failsOnOld, (b) promotes scoped/whole-package `tsc --noEmit` to a hard gate, (c) adds a `structural: [{ "grep": "function parseJsonArray", "path": "apps/commander-recommender/server/src", "expectCount": 1 }]` check.
