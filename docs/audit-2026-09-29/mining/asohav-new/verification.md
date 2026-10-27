# verification.md - ASoHaV NEW window (commits dated >= 2026-09-13)

Method for every candidate: a FRESH `git worktree add <dir> <PARENT sha>` from my own clone
(`mine-asohav-new/repo`, itself a `git clone --local` of the read-only mirror), then
`npm ci --ignore-scripts` at the repo root (the manifest's `installFlags` for asohav are
`["--ignore-scripts"]`), then the `setup` step (build `@asohav/shared`), then the scoped test command.
Worktrees live in `mine-asohav-new/wt/<letter>-<sha>`. Nothing is reused across candidates.
Sandbox: Linux x86_64, node v22.22.2, npm 10.9.7. `npm ci --ignore-scripts` took ~9 s per worktree; no
native module needed scripts to run (see the "install/scripts" note at the bottom).

Setup step confirmed from the PARENT's tree (not from a built checkout):
`git ls-tree d73d6c9 packages/shared/` -> package.json, src, tsconfig.json (NO dist; `dist/` is in
`.gitignore`, `git ls-tree -r d73d6c9 | grep -c /dist/` = 0). `packages/shared/package.json` @parent has
`"main": "./dist/index.js"` + `"exports": {".": {"types": "./dist/index.d.ts", "default": "./dist/index.js"}}`
and `"build": "tsc -p tsconfig.json"`. So a server test that imports `@asohav/shared` needs
`cd packages/shared && npx tsc -p tsconfig.json` first (same `setup` as asohav-01/02). Shared's OWN tests
do not need the build (they import `./x.js` which vitest resolves to the .ts source).

---

## Candidate A  -  2db8a09  "slice 0 / WP 0A: stop the party route clamping Rapport to the cap"

- fix commit: 2db8a09b37fc967ad1199bfa436a3d1ebde1c0d1 (2026-09-22 18:55 +0000, Claude / [model id omitted], PR #140 branch claude/v06r-s0-rapport-clamp)
- PARENT:     d73d6c978f478e3aca5fb836683fcfe639debd43 (merge of PR #138 = main at that time)
- files in commit: apps/server/src/routes/party.ts (+5/-7), apps/server/src/routes/party.test.ts (+7/-5),
  apps/web/src/features/sheet/KeepWatchModal.tsx (+1/-1)  -> SCOPED DOWN to party.ts + party.test.ts
  (dropped the one-line web KeepWatchModal client-side cap; it is UI, untested, out of scope).
- worktree: wt/A-2db8a09 @ d73d6c9 (fresh, `git rev-parse HEAD` = d73d6c978f47...)
- test cmd (cwd apps/server): `npx vitest run src/routes/party.test.ts`

1. BASELINE at parent (nothing applied):
```
 ✓ src/routes/party.test.ts (5 tests) 74ms
 Test Files  1 passed (1)
      Tests  5 passed (5)
```
   => 5/5 green.

2. RED: `git checkout 2db8a09 -- apps/server/src/routes/party.test.ts` only (source still unfixed):
```
 ❯ src/routes/party.test.ts (5 tests | 1 failed) 83ms
   × PUT /campaigns/:campaignId/party — Rapport bounds > keeps Rapport above the track length (overflow banks until Make Camp) 17ms
     → expected 5 to be 13 // Object.is equality
 Test Files  1 failed (1)
      Tests  1 failed | 4 passed (5)
```
   => 1/5 red, and it is the right reason: the route still clamps Rapport 13 down to RapportTrackLength (5).
   No import error / missing helper: the other 4 tests in the file still pass.

3. GREEN: additionally `git checkout 2db8a09 -- apps/server/src/routes/party.ts` (web file NOT applied):
```
 ✓ src/routes/party.test.ts (5 tests) 63ms
 Test Files  1 passed (1)
      Tests  5 passed (5)
```
   `npx tsc -p tsconfig.json --noEmit` in apps/server: exit code 0 (the removed `getLibrary` import is the only
   import change, and the test file still mocks `getLibrary`, which is harmless).

RESULT: VERIFIED. baseline 5/5 -> red 1/5 -> green 5/5.
Bug class: an over-eager server-side clamp discarding banked state (missing-state / clamp bug). Toolchain: server vitest (supertest, mocked repo).
No `setup` needed for the *test* to run? -> the server test imports `@asohav/shared` (via the party route), so YES the shared build is needed.

### Setup-necessity check for the server tests (A0, fresh worktree wt/A0-nobuild @ d73d6c9, `npm ci --ignore-scripts`, NO shared build)
```
 FAIL  src/routes/party.test.ts [ src/routes/party.test.ts ]
Error: Failed to resolve entry for package "@asohav/shared". The package may have incorrect main/module/exports specified in its package.json.
 Test Files  1 failed (1)
      Tests  no tests
```
=> every apps/server test needs `cd packages/shared && npx tsc -p tsconfig.json` first (5 s). Same `setup` block as asohav-01/02 in
the manifest; confirmed from the parent's tree above (no dist tracked).

---

## Candidate B  -  d769699  "slice 6 / WP 6F: ending Combat"  (server half only)

- fix commit: d7696990b5e2551c9897e6ec255c70be213ca8b2 (2026-09-23 06:58 +0000, Claude / [model id omitted]; PR #147 branch claude/v06r-s6-combat-loop)
- PARENT:     9afb9112b0e2596edac0e7fe4055149512ab3b62  ("slice 6 / WP 6C: resolving incoming Strain in the revised order", same branch, one commit before)
- files in commit: apps/server/src/routes/combat.ts (+20/-3), apps/server/src/routes/combat.test.ts (+66/-0),
  apps/web/src/features/combat/DefiantGoals.tsx (+28/-6), apps/web/src/features/combat/EndCombatFlow.tsx (+34/-19)
  -> SCOPED DOWN to combat.ts + combat.test.ts. The two web files are the UI half (Defiant Goal "Supersedes the Combat Goal" button, claim-Potential flow):
  a separate feature, untested, dropped.
- Documented as a live defect in `Planning Docs/WorkPlan-V0.6-Revision.md` B1: "End Combat never clears Strain -- routes/combat.ts /end only sets Status".
- worktree: wt/B-d769699 @ 9afb911 (fresh; `npm ci --ignore-scripts` 7 s; then `cd packages/shared && npx tsc -p tsconfig.json`)
- test cmd (cwd apps/server): `npx vitest run src/routes/combat.test.ts`

1. BASELINE at parent (nothing applied):
```
 ✓ src/routes/combat.test.ts (18 tests) 143ms
 Test Files  1 passed (1)
      Tests  18 passed (18)
```
2. RED: `git checkout d769699 -- apps/server/src/routes/combat.test.ts` only:
```
 ❯ src/routes/combat.test.ts (20 tests | 1 failed) 148ms
   × POST /campaigns/:campaignId/combat/:encounterId/end > clears every Hero's marked Strain when Combat ends 15ms
     → expected "spy" to be called 2 times, but got 0 times
 Test Files  1 failed (1)
      Tests  1 failed | 19 passed (20)
```
   (the `stderr ... CampaignArchivedError ... status: 409` block in the output is an existing test's expected 409 log, not a failure.)
   => 1/20 red for the right reason: the unfixed route never reads the participants' sheets (`getSheet` called 0 times).
   The 2nd new test (non-GM must not touch sheets) passes on the old code by design (it is a guard against over-eager fixes).
3. GREEN: additionally `git checkout d769699 -- apps/server/src/routes/combat.ts` (web NOT applied):
```
 ✓ src/routes/combat.test.ts (20 tests) 139ms
 Test Files  1 passed (1)
      Tests  20 passed (20)
```
   `npx tsc -p tsconfig.json --noEmit` (apps/server): exit code 0.

RESULT: VERIFIED. baseline 18/18 -> red 1/20 -> green 20/20.
Bug class: missing cascading side effect on a state transition (ending an Encounter must clear Strain on every Hero's *separate* sheet record; repo API getSheet/saveSheet already exist at the parent).
Prompt-design note: the fix's own test pins the call shape `saveSheet(sheet, campaignId)` + "only sheets with a marked Strain are saved" + a 'Combat ended' History entry.
The prompt should state those behaviours explicitly (they are not derivable from the diagnosis alone), else a valid alternative implementation (e.g. saving every sheet) fails an owner acceptance test.

---

## Candidate C  -  aec6644  "Give Strike a Nerve its Virtue: m-strike VirtueId null -> v-guile (0.64.3)"

- fix commit: aec6644bfd4f92d787253680b7682ed9b0e4c52a (2026-09-25 17:06 +0000, Claude / [model id omitted]; PR #175 branch claude/ecstatic-rubin-6n1311)
- PARENT:     8686bf41c9ac130bd521f05e056460ca777f43bf (merge of PR #172 = main at 0.64.2)
- files in commit (non-doc): packages/shared/src/seedLibrary.ts (+2/-2: one m-strike line + the SEED_VERSION constant '0.63.0' -> '0.64.3'),
  packages/shared/src/seedLibrary.test.ts (NEW, +58), plus the 4 package.json version bumps + lockfile + CHANGELOG/CLAUDE/HANDOFF.
  -> SCOPED to: ONE token in seedLibrary.ts (`VirtueId: null` -> `'v-guile'` on m-strike) + the new test file. SEED_VERSION bump dropped (release concern; nothing in the vitest suites reads it).
- worktree: wt/C-aec6644 @ 8686bf4 (fresh; `npm ci --ignore-scripts` 7 s). NO shared build needed: shared's own tests import ./x.js which vitest resolves to the .ts.
- test cmd (cwd packages/shared): `npx vitest run` (full shared suite, because the fix adds a brand-new test file: same shape as asohav-02) or `npx vitest run src/seedLibrary.test.ts` once the file exists.

1. BASELINE at parent, full shared suite (nothing applied):
```
 Test Files  10 passed (10)
      Tests  368 passed (368)
```
2. RED: `git checkout aec6644 -- packages/shared/src/seedLibrary.test.ts` (source unfixed):
```
 ❯ src/seedLibrary.test.ts (3 tests | 1 failed) 11ms
   × seeded Basic Moves follow their ruleset headings > gives a Move whose heading names exactly one Virtue that VirtueId 8ms
     → ## Strike a Nerve (Guile): expected null to be 'v-guile' // Object.is equality
 Test Files  1 failed | 10 passed (11)
      Tests  1 failed | 370 passed (371)
```
   => 1/371 red overall (1 of the 3 new tests), for the right reason (the seed's m-strike.VirtueId is null while the ruleset heading says Guile).
3. GREEN: one-token `sed` on seedLibrary.ts (`git diff --stat`: 1 file, 1 insertion, 1 deletion; SEED_VERSION untouched):
```
 ✓ src/seedLibrary.test.ts (3 tests) 11ms
 Test Files  11 passed (11)
      Tests  371 passed (371)
```
   `npx tsc -p tsconfig.json --noEmit` (packages/shared): exit 0.
   Collateral check at the fixed state (built shared first): full server suite 16 files / 247/247 pass; full web suite 8 files / 59/59 pass.

RESULT: VERIFIED. baseline 368/368 -> red 1/371 -> green 371/371.
Bug class: data/spec conformance (seed data disagrees with the canonical ruleset heading) + invariant-test authoring from a document. New shape vs the suite: the source of truth is a Markdown file, not code.
Risk notes:
- the test reads `Planning Docs/Ruleset-V0.6.md` via `new URL('../../../Planning Docs/Ruleset-V0.6.md', import.meta.url)` (space in the path; fine with readFileSync(URL) on Windows).
- The Basic Moves headings contain markdown-escaped hyphens/trailing spaces (`## Offer Solace \- (Heart) `); a model that hand-copies a table instead of parsing headings still passes failsOnOld (its table would say Guile for Strike a Nerve).
- If the prompt names `m-strike` the task collapses to a one-token edit; a harder, fairer prompt names only the symptom + the ruleset path (see candidates.json).

---

## Candidate E (NOMINATION, shape (a)+type-oracle)  -  3a7589d  "Send improvementIds and loadTier from web character creation (0.64.3)"
## and REJECTED sibling 139b942 (same bug, parallel PR)

- fix commit: 3a7589d7b3b7f94684967a819e736e382d0e9cc9 (2026-09-25 17:06 +0000, PR #174 branch claude/relaxed-meitner-vr5kfk)
- PARENT:     8686bf41c9ac130bd521f05e056460ca777f43bf (merge of PR #172 = main at 0.64.2). Same parent as 139b942 and aec6644.
- files in commit (non-doc): apps/web/src/lib/api.ts (+5/-12), apps/web/src/pages/CreateCharacterPage.tsx (+5/-8),
  apps/web/src/lib/api.test.ts (+35/-1), apps/server/src/routes/characters.test.ts (+23/-0; a 400-pin that passes both before and after)
- bug: since 0.55.0 every web-created character was rejected with 400: CreateCharacterPage.onSubmit copied six of the schema's eight fields by hand into
  `api.character.create(campaignId, body)`, whose hand-written `body` type had no slot for `improvementIds`/`loadTier`, so tsc could not notice.
- worktrees (both fresh): wt/E-3a7589d and wt/E2-139b942, each @ 8686bf4; `npm ci --ignore-scripts` 7-8 s; shared built (web tsc needs shared's dist .d.ts).

E-3a7589d results:
1. BASELINE @ parent: `cd apps/web && npx vitest run src/lib/api.test.ts` -> `Tests  8 passed (8)`.
   `cd apps/web && npx tsc --noEmit` -> exit 0 (17.7 s wall).
2. TESTS ONLY (`git checkout 3a7589d -- apps/web/src/lib/api.test.ts apps/server/src/routes/characters.test.ts`), source unfixed:
   - vitest web api.test.ts: `Tests  10 passed (10)`  <- NOT red. (`expectTypeOf` is a no-op at runtime; the POST body test passes because JSON.stringify(body) forwards whatever it is given.)
   - vitest server characters.test.ts: `Tests  17 passed (17)`  <- NOT red (the 400 pin documents server behaviour that was always true).
   - `apps/web: npx tsc --noEmit` -> exit 2:
     `src/lib/api.test.ts(108,78): error TS2344: Type '{ name: string; ...; improvementIds: string[]; loadTier: ...}' does not satisfy the constraint '{ ... improvementIds: "Expected: ..., Actual: never"; ...`
     => the ONLY red signal is the type checker.
3. + `git checkout 3a7589d -- apps/web/src/lib/api.ts` (type fix only), CreateCharacterPage.tsx still the old six-field copy:
   `apps/web: npx tsc --noEmit` -> exit 2:
   `src/pages/CreateCharacterPage.tsx(178,68): error TS2345: Argument of type '{ name: ...; motifs: ...[]; }' is not assignable to parameter of type '{ ...; improvementIds: string[]; loadTier: ...}'.  ... is missing the following properties from type ...: improvementIds, loadTier`
   (this is the fix commit's own claim: "reverting either the old body type or the old onSubmit fails `npm run typecheck -w @asohav/web`" -- reproduced.)
4. + `git checkout 3a7589d -- apps/web/src/pages/CreateCharacterPage.tsx`: `apps/web: npx tsc --noEmit` -> exit 0;
   full web vitest `Test Files  8 passed (8) / Tests  61 passed (61)`; server characters.test.ts `Tests  17 passed (17)`.

RESULT (E): VERIFIED for the tsc oracle, and *explicitly NOT verifiable as a vitest failsOnOld*: baseline vitest 8/8 & tsc exit 0 -> tests-only: vitest 10/10 (no red), tsc exit 2 (red) ->
+api.ts: tsc exit 2 (red, different file) -> +CreateCharacterPage.tsx: tsc exit 0, vitest 61/61.
=> cannot be entered in the manifest as-is: `failsOnOld` (suite must FAIL) never trips. Needs a harness change (see nominations).

E2-139b942 (the *other* PR's version of the same fix), fresh worktree, `git checkout 139b942 -- apps/web/src/lib/api.test.ts`, source unfixed:
```
 ✓ src/lib/api.test.ts (9 tests) 37ms      Tests  9 passed (9)
web tsc exit: 0
```
=> its test is green under BOTH vitest and tsc on the unfixed source: it guards nothing. REJECTED (3a7589d is the meaningful version).

---

## Candidate F (NOMINATION, shape (c) feature slice, RED-BY-DESIGN baseline)  -  4e5bbcf  "slice 7 / WP 7A: enemies in the fight -- the rule bodies"

- WP commit: 4e5bbcf291c000cd241baa25399bac13f8ff7a66 (2026-09-23 11:44 +0000; PR #149 branch claude/v06r-s7-enemies).
- PARENT: 088e5e7797d92f4ea08a6a4d68247c6d4ef9ec1c = "slice 7 / contract: enemies in the fight". That commit ships the TYPES + STUBS (functions that throw `not implemented`) + the
  truth-table tests (enemies.test.ts +264 lines) "which fail until WP 7A lands". So the task is: make the given tests pass by writing the rule bodies.
- files in the WP commit: packages/shared/src/enemies.ts (+202/-12; 12 stubs that `throw new Error('not implemented: WP-7A')` at the parent: newEnemyParticipant, guardedStrain, negateWithStatus, inflictEnemyStrain [sparse marking, Subdued, Minion-per-hit, every Legendary phase transition with a one-phase-per-activation guard],
  enemyStrainRank, markEnemyCondition/clearEnemyCondition [Crumble/Unshakable], effectiveEnemyVirtues, enemyVirtueRollHints, groupMinionAttack) + packages/shared/src/combat.ts (+4/-4: beginTurn clears the phase guard). NO test file is touched by the WP commit.
- worktree: wt/F-4e5bbcf @ 088e5e7 (fresh; npm ci --ignore-scripts 7 s; shared tests need no build)
- test cmd (cwd packages/shared): `npx vitest run` (or `npx vitest run src/enemies.test.ts src/combat.test.ts`)

1. AT PARENT (red by design, nothing applied):
```
 ❯ src/combat.test.ts (62 tests | 1 failed)
 ❯ src/enemies.test.ts (42 tests | 30 failed)
 Test Files  2 failed | 6 passed (8)
      Tests  31 failed | 322 passed (353)
```
   (representative failures: `newEnemyParticipant > copies the stat block and starts clean`, `inflictEnemyStrain > Opening → Bloodied clears every Strain box and Condition, keeps Statuses, and discards the rest`,
   `markEnemyCondition / clearEnemyCondition > Crumbles on the final available Condition`, `groupMinionAttack > adds the Minions’ Strain and caps it at 5`; the stack traces point into the stubs at enemies.ts:125/139/145.)
2. `git checkout 4e5bbcf -- packages/shared/src/enemies.ts packages/shared/src/combat.ts` (tests untouched):
```
 ✓ src/combat.test.ts (62 tests)   ✓ src/enemies.test.ts (42 tests)   ... 
 Test Files  8 passed (8)
      Tests  353 passed (353)
shared tsc exit: 0
```
RESULT: VERIFIED as red-by-design. baseline 322/353 (31 red BY DESIGN) -> green 353/353 with the WP commit's 2 source files.
Why the current harness cannot grade it: (i) `baselineExpect` assumes the pre-fix suite is fully green; here the baseline is RED on purpose; (ii) `failsOnOld` is meaningless (the tests exist before the model starts -- there is nothing for the model to author), so the gate must become
"the GIVEN failing tests turn green and no test file changed" (allowFiles = the 2 source files, tests protected/hash-checked).

---

## Candidate G (alt for (c), smaller)  -  e793ff9  "slice 1 / WP 1A: Hero Roll cap, Conditions as Banes, fixed Resist table"   [engine.ts only]
- PARENT dae86a90ffb221d17210e1eed6def4c49249f2a1 = "slice 1 / contract: ..." whose message says "11 tests fail on the stubs by design". Worktree wt/G-e793ff9 (fresh).
```
PARENT:  ❯ src/engine.test.ts (57 tests | 11 failed)   Test Files  1 failed | 6 passed (7)   Tests  11 failed | 261 passed (272)
+ `git checkout e793ff9 -- packages/shared/src/engine.ts`:  Test Files  7 passed (7)   Tests  272 passed (272)   shared tsc exit: 0
```
RESULT: VERIFIED red-by-design: 261/272 -> green 272/272 (one source file, no test file touched). Content: computeRollBreakdown +-cap with a Cap source, conditionBaneCandidates, resistReduction 2/1/0.

## Candidate H (alt for (c), smallest)  -  46e88f5  "slice 9 / WP 9A: rollOdds enumerates every outcome of the roll's dice"  [odds.ts only]
- PARENT 44ead5d619bb1a26854c0d861aa75a89f14a8fd6 = "slice 9 / contract: reminders, the dice odds, and Debug mode" (stub rollOdds + exact-count tests). Worktree wt/H-46e88f5 (fresh).
```
PARENT:  ❯ src/odds.test.ts (7 tests | 7 failed)   Test Files  1 failed | 8 passed (9)   Tests  7 failed | 349 passed (356)
+ `git checkout 46e88f5 -- packages/shared/src/odds.ts`:  Test Files  9 passed (9)   Tests  356 passed (356)   shared tsc exit: 0
```
RESULT: VERIFIED red-by-design: 349/356 -> green 356/356. Pure enumeration math (2d6, Advantage, Disadvantage, Double Disadvantage, Severe Status 1d6, modifiers -3..+3) with exact-count assertions: the only nominee with zero domain vocabulary.
NOTE: CLAUDE.md invariant "never add randomness to the rules engine" is a real trap here: a Monte-Carlo implementation would violate it and be flaky.

## Candidate I (rejected as alt)  -  42356ce  "slice 6 / WP 6A: the Combat loop's rule bodies"
- PARENT 5951c5c. Worktree wt/I-42356ce (fresh). At parent: `combat.test.ts (68 tests | 15 failed)`; after `git checkout 42356ce -- packages/shared/src/combat.ts`: STILL `1 failed | 316 passed (317)`
  (`combat.test.ts:75`) because the WP commit ALSO edits one line of combat.test.ts (+1/-1). Not a clean "tests given" case -> REJECTED as an alternate (would need that 1-line test edit pre-applied on the bench branch).

---

## Candidate J (NOMINATION, shape (e) security/authz, multi-file)  -  7c5a4de  "slice 2 / WP 2A: the misfortune route; the party PUT and adventures reset"

- fix/feature commit: 7c5a4de00ac5c4383043eb194fc509d2ca677084 (2026-09-23 02:07 +0000; PR #146 branch claude/v06r-s2-misfortune)
- PARENT: e90990775d5a01c6f61d511272960e1767e585da ("slice 2 / WP 2C": web-only commit; the contract (types, applyMisfortune stub implemented by WP 2B) is already in shared).
- files: apps/server/src/routes/party.ts (+48/-1), apps/server/src/routes/adventures.ts (+15/-2), party.test.ts (+169/-0), adventures.test.ts (+40/-0) = 2 src + 2 test files (the harness scope gate allows exactly 2 files).
- Security shape: Misfortune is a GM-only resource stored on a member-writable document. Requirements the tests pin: PUT /party keeps the STORED Misfortune whatever the client sends (mass-assignment / privilege boundary);
  POST /party/misfortune: any member may Gain (note required), only the GM may Spend/Reset/BeginSession (403), 409 at 0 on Spend, 409 on an Archived campaign, 403 for a non-member, 404s; adventures PUT resets Misfortune to 1 only on Active->Concluded.
- worktree: wt/J-7c5a4de @ e909907 (fresh; npm ci --ignore-scripts 7 s; shared built; test cmd cwd apps/server)
1. BASELINE: `npx vitest run src/routes/party.test.ts src/routes/adventures.test.ts` -> `Test Files 2 passed (2) / Tests 19 passed (19)`.
2. RED (`git checkout 7c5a4de -- apps/server/src/routes/party.test.ts apps/server/src/routes/adventures.test.ts`, source unfixed):
```
 ❯ src/routes/party.test.ts (20 tests | 13 failed)
   × PUT /campaigns/:campaignId/party — Rapport bounds > preserves the stored Misfortune value when client sends a different one
   × POST /campaigns/:campaignId/party/misfortune > lets a player Gain Misfortune with a note   ... (12 more in the POST describe)
 ❯ src/routes/adventures.test.ts (17 tests | 1 failed)
   × PUT /campaigns/:campaignId/adventures/:adventureId > resets Misfortune when transitioning an Adventure from Active to Concluded
 Test Files  2 failed (2)
      Tests  14 failed | 23 passed (37)
```
3. GREEN (+ `git checkout 7c5a4de -- apps/server/src/routes/party.ts apps/server/src/routes/adventures.ts`):
```
 ✓ src/routes/adventures.test.ts (17 tests)   ✓ src/routes/party.test.ts (20 tests)
 Test Files  2 passed (2)     Tests  37 passed (37)      server tsc exit: 0      full server suite: 16 files, 228/228
```
RESULT: VERIFIED. baseline 19/19 -> red 14/37 -> green 37/37 (2 src + 2 test files).
Why the harness cannot grade it: `allowFiles`/`srcRevertFiles`/scope gate assume 2 files (here 4); it is a feature (new route) whose value is the authz matrix, and the failsOnOld revert must revert TWO source files.
A smaller authz-only cut is conceivable (the one-line `incoming.Misfortune = existing?.Misfortune ?? 1` in the PUT handler + the single 'preserves the stored Misfortune value' test) -- but that is a hand-cut, not a commit, and I did NOT run it in isolation: UNVERIFIED as a separate task.

---

## Candidate K (alt for (a), WEAK)  -  c6fa889  "slice 5 / WP 5A: every pair of Heroes gets a Bond"   (3 src + 2 test files)

- fix commit: c6fa889c099abb00bc7d14dd6b7f4f607e96ef83 (2026-09-23 20:52 +0000; PR #151 branch claude/v06r-s5-connections). "Fixes HANDOFF open issue 23: only the seed ever inserted a Bond, so a real campaign's Heroes had none."
- PARENT: 70fbf71bc9e002436531e1346c79fd35dc4bf755 ("slice 5 / contract": adds `repo.ensureBondsForCampaign` as a stub that throws `not implemented: WP-5A`, and `missingBondPairs()` in shared with tests).
- files: apps/server/src/repo.ts (+33/-3: parallel reads, missing pairs, per-pair id `bd-<a>-<b>`, swallow Postgres unique-violation 23505 as a race, re-list), routes/campaign.ts (+4/-2: repair-on-read for ACTIVE campaigns only), routes/characters.ts (+2/-1: call after creating a character) + campaign.test.ts (+25/-1) + characters.test.ts (+3/-0).
- worktree wt/K-c6fa889 @ 70fbf71 (fresh; npm ci --ignore-scripts 8 s; shared built). test cmd (cwd apps/server): `npx vitest run src/routes/campaign.test.ts src/routes/characters.test.ts`
1. BASELINE: `Test Files 2 passed (2) / Tests 46 passed (46)`.
2. RED (fix's 2 test files only): 
```
 ❯ src/routes/characters.test.ts (16 tests | 1 failed)
   × POST /campaigns/:campaignId/characters > creates a character, sheet, and links the membership
     → expected "spy" to be called with arguments: [ 'cm-2' ]
 ✓ src/routes/campaign.test.ts (31 tests)
 Test Files  1 failed | 1 passed (2)     Tests  1 failed | 46 passed (47)
```
   => only 1/47 red. The campaign.ts (bootstrap repair-on-read) tests are GREEN on the unfixed source (the old code always calls listBondsForCampaign, and the new 'archived => listBondsForCampaign, not ensureBondsForCampaign' test is satisfied by the old code).
3. GREEN (+ the 3 source files): `Tests  47 passed (47)`; server tsc exit 0; full server suite 16 files / 237/237.
4. FINDING: with repo.ts left as the throwing stub and ONLY the two route files applied: still `Tests  47 passed (47)`. The 36-line ensureBondsForCampaign body (the actual fix) has NO test in the commit.
RESULT: baseline 46/46 -> red 1/47 -> green 47/47, but WEAK: the graded property is only the wiring in characters.ts; the core logic and campaign.ts wiring are unpinned.
REJECTED as a bug-fix candidate; listed as an (a) alternate only if the owner adds an authored repo-level unit test (repo.ts is mocked everywhere, so there is no existing pattern except repo.changelog.test.ts's supabase-client mock).

