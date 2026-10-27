# verification.md - append-only log of what was actually run

Environment: Linux x86_64, node v22.22.2, npm 10.9.7, vitest 2.1.9 (from each parent's lockfile). Every candidate gets its OWN fresh
`git worktree add --detach wt/<name> <parent-sha>` from my `git clone --local` of the mirror; never reused. Install = `npm ci --ignore-scripts`
(the harness runs `npm ci <installFlags>` for packageManager=npm). Working copy: mine-asohav-old/repo; worktrees: mine-asohav-old/wt/*.

---------------------------------------------------------------------------------------------------------------------------
## CANDIDATE A: glossary depth cap + tag flattening (asohav-03-glossary-depth-flatten)  -- STATUS: VERIFIED
Re-examination of the candidate roadmap.md ~l.890 says was DROPPED.

- fix commit : 3003542385e2e83a862ff648b69ea0a8f9873da6  "Fix glossary tooltip depth cap, add See also chips (WorkPlan-0.25.0 #9)"  2026-08-14 18:39 +0000 (PR #93)
- parent     : 5c891936847a844bb23dd74b02aa1fa6f1525f84  "Add GlossaryDrawer + triggers on the sheet and Campaign page (WorkPlan-0.25.0 #8)"
- The fix commit touches 7 files: WorkPlan-0.25.0.md, GlossaryDrawer.module.css, GlossaryText.module.css, GlossaryText.tsx, styles/glossarySeeAlso.module.css,
  packages/shared/src/glossary.ts, packages/shared/src/glossary.test.ts.
- SCOPING: the roadmap dropped it because the React component + CSS + "See also chips" feature were bundled in. But the commit's ONLY test-file change is
  packages/shared/src/glossary.test.ts (shared package, pure function, no React), and the bug has a shared-side half (glossary.ts: MAX_DEPTH 1 -> 0 and the
  past-depth early return now flattens explicit [display][id] tags instead of leaking raw brackets). Scope down = glossary.ts + glossary.test.ts; drop
  GlossaryText.tsx/CSS/docs. The fix commit's test file is applied VERBATIM (no test editing).
- setup: NONE. Confirmed from the parent tree (git show 5c89193:packages/shared/...): glossary.test.ts imports only vitest, ./glossary.js, ./types.js;
  glossary.ts imports only a type from ./types.js. No @asohav/shared dist build needed.
- install: `npm ci --ignore-scripts` OK (5.9s). No native-module problem; no scripts needed.
- testDir = packages/shared ; testCmd = npx vitest run src/glossary.test.ts

Runs (fresh worktree wt/glossary, `git status` clean before each phase):
1. BASELINE @ parent, untouched:
   ` ✓ src/glossary.test.ts (20 tests) 14ms` / ` Test Files  1 passed (1)` / `      Tests  20 passed (20)`   => 20/20
2. RED: `git checkout 3003542 -- packages/shared/src/glossary.test.ts` (only the fix commit's test file; source untouched):
   ` ❯ src/glossary.test.ts (21 tests | 2 failed) 22ms`
   `   × linkifyText > does not link past MAX_DEPTH (0 as of 0.25.0 — one nested definition renders plain)  → expected false to be true`
   `   × linkifyText > flattens an explicit tag to its plain display text past MAX_DEPTH instead of leaking brackets  → expected false to be true`
   `      Tests  2 failed | 19 passed (21)`   => 2/21 red; both are behavioural assertion failures on the missing fix (not import/helper errors).
3. GREEN: `git checkout 3003542 -- packages/shared/src/glossary.ts` (fix's glossary.ts only; GlossaryText.tsx/CSS NOT applied):
   ` ✓ src/glossary.test.ts (21 tests) 26ms` / `      Tests  21 passed (21)`   => 21/21
4. MUTATION CHECKS on the green tree (proving each half of the fix is needed by the tests; file restored after each):
   a) MAX_DEPTH=0 but early return left as `return [{ text }]` (no flatten):
      `× ... flattens an explicit tag ... → expected 'you feel [shaken][g-condition] by it.' to be 'you feel shaken by it.'`  `Tests  1 failed | 20 passed (21)`
   b) flatten branch kept but MAX_DEPTH=1 (constant unfixed):
      `× ... does not link past MAX_DEPTH ...` and `× ... flattens an explicit tag ...`   `Tests  2 failed | 19 passed (21)`
   c) restored fixed file: `Tests  21 passed (21)`.
   => the two halves are independently required; a model that only bumps the constant, or only adds flattening, still fails the suite.
- Note on the 2nd red test: at the UNFIXED source the flatten test fails first because depth 1 is not yet "past the cap" (constant), so the bracket-leak
  behaviour itself is only isolated by mutation check (a). That is why the prompt must state BOTH behaviours.
- Determinism: pure function, no timers/network/env/fs. Windows-safe.
- Verdict: VERIFIED. baseline 20/20 -> red 2/21 -> green 21/21. Harness `srcRevertFiles` = [packages/shared/src/glossary.ts].

---------------------------------------------------------------------------------------------------------------------------
## CANDIDATE B: Neutral Status treated as Negative in engine.ts (asohav-04-neutral-status-polarity)  -- STATUS: VERIFIED
- fix commit : 2729b58616447dc6ff6ede2cebdae2641d4e7c47  "fix(shared): correct Virtue-array rules, fix Neutral Status treated as Negative"  2026-08-13 02:52 +0000
- parent     : f15a58cb9ef29c3b511caa0d88949a7b10686874  (merge of PR #74; the real first-parent of the fix commit)
- The fix commit bundles TWO unrelated things across 4 files: (1) Virtue-array spec change (logic.ts + logic.test.ts; STANDARD_VIRTUE_ARRAY -> five owner-confirmed
  arrays: a rules/data change, NOT a bug, needs the five arrays in the prompt) and (2) the Neutral-polarity bug (engine.ts x2 sites, logic.ts x1 site).
  SCOPING: only (2)'s engine.ts sites + engine.test.ts. Dropped: the Virtue-array change, logic.ts negativeStatusRankTotal (a 3rd site, separate test file).
  Applied test file: engine.test.ts verbatim from the fix commit (+2 tests, 16 lines).
- setup: NONE (engine.test.ts imports vitest, ./engine.js, ./seedLibrary.js, ./types.js; engine.ts imports ./logic.js + types) - checked via `git show f15a58c:...`.
- install: `npm ci --ignore-scripts` OK (4.8s, 258 pkgs). testDir=packages/shared; testCmd=npx vitest run src/engine.test.ts

Runs (fresh worktree wt/neutral):
1. BASELINE @ parent: ` ✓ src/engine.test.ts (22 tests) 15ms` / `Tests  22 passed (22)`  => 22/22
2. RED (`git checkout 2729b58 -- packages/shared/src/engine.test.ts`, source untouched):
   ` ❯ src/engine.test.ts (24 tests | 2 failed)`
   `× computeRollBreakdown > never counts a Neutral Status as helpful or hindering  → expected -4 to be 1`
   `× giveStatus > does not flag Subdued for a Neutral Status at the cap either — only Negative triggers it  → expected true to be false`
   `Tests  2 failed | 22 passed (24)`   => 2/24 red, both assertion failures on Neutral being treated as a wound (a Rank-5 Neutral subtracted 5 from the roll total).
3. GREEN (`git checkout 2729b58 -- packages/shared/src/engine.ts`; logic.ts NOT applied): ` ✓ src/engine.test.ts (24 tests)` / `Tests  24 passed (24)` => 24/24
   (engine.ts diff is 2 lines: hindering filter `!== 'Positive'` -> `=== 'Negative'`; giveStatus `subdued = incoming.Polarity !== 'Positive'` -> `=== 'Negative'`)
4. MUTATION: reverting only the computeRollBreakdown site -> `Tests  1 failed | 23 passed (24)` (the -4 vs 1 test);
             reverting only the giveStatus site          -> `Tests  1 failed | 23 passed (24)` (the Subdued test). Restored -> 24/24. Both sites independently required.
- Determinism: pure functions. Windows-safe.
- Verdict: VERIFIED. baseline 22/22 -> red 2/24 -> green 24/24. srcRevertFiles=[packages/shared/src/engine.ts].

---------------------------------------------------------------------------------------------------------------------------
## CANDIDATE D: Content Admin write routes trust the request body (asohav-05-library-write-validation)  -- STATUS: VERIFIED (scoped from a bundle)
- fix commit : 3e0b074596d11cf2acf8af714d0455f80c881ea0  "Ship 0.51.0: Content Admin, phases 1 and 2"  2026-09-12 00:20 +0000 (PR #132), 35 files, +1479/-128
- parent     : 79b369d7ba01ed02affa6534a33ef698d17b5518  (merge of PR #131, the real first-parent of the fix commit)
- SCOPING (this is a release bundle; the hidden fix is the "Fixed - it could lose or destroy your work" set): kept ONLY the server-side input-trust fixes in
  apps/server/src/routes/library.ts (+ helpers in apps/server/src/adminLogic.ts): (1) PUT /library/settings type-checks its patch (a null/NaN for the bool
  GlossaryAutoLink silently disabled auto-linking app-wide), (2) `required` enforced on create/update, (3) declared `default:` applied on create, (4) a
  client-supplied `Id` no longer overrides the generated one on create (`{ Id: newId(..), ...req.body }` spread the wrong way round).
  DROPPED (separate features, different tests): restore-a-deleted-record route (+ repo.getChangeLogEntry), DELETE reference guard (?force=true), rowsOf() refactor,
  all apps/web changes (dirty tracking, confirms, URL routes, 44px targets), docs, version bump.
- TEST SCOPING: parent's library.test.ts + the fix commit's `describe('field validation')` (6 tests) and `describe('settings validation')` (4 tests), VERBATIM.
  Removed from the fix's test file: `getChangeLogEntry` mock line, the 'no-op, not a 404' delete test, `describe('restore from the changelog')`, `describe('delete guards live references')`.
  (diff of scoped test file vs parent's = exactly the two verbatim describe blocks; saved as library.test.scoped.ts next to this file.)
- SOURCE for green: fix commit's adminLogic.ts VERBATIM + the four validation hunks of the fix commit's library.ts applied to the parent's library.ts
  (import line, PUT /settings, POST /:collection incl. Id-last, PUT /:collection/:id). Typed with the commit's `LibRow` type. saved: library.scoped-fix.ts.bak.
- setup NEEDED: build @asohav/shared first (server imports it via package exports -> ./dist/index.js). Confirmed from the parent's tree:
  packages/shared/package.json main/exports = ./dist/index.js; packages/shared/tsconfig.json exists; apps/server/src/routes/library.test.ts imports '@asohav/shared' (type)
  and the routes import `getCollection, newId, seedLibrary` + (fix) `collections, settingsFields` from it. Same setup as asohav-01: cwd packages/shared, `npx tsc -p tsconfig.json` (6.6s).
- install: `npm ci --ignore-scripts` OK (7.1s, 408 pkgs); no native-module problems (supertest/express/vitest only).
- testDir = apps/server ; testCmd = npx vitest run src/routes/library.test.ts

Runs (fresh worktree wt/library):
1. BASELINE @ parent (after install + shared build): ` ✓ src/routes/library.test.ts (14 tests) 140ms` / `Tests  14 passed (14)`  => 14/14
2. RED (scoped test file dropped in; source untouched): ` Tests  8 failed | 16 passed (24)`  => 8/24 red. Failing:
   × field validation > refuses to create a record missing a required field          (expected 400, got 200)
   × field validation > refuses a required field present but blank, not just absent
   × field validation > applies a declared default when the field is omitted
   × field validation > generates the Id itself and ignores a client-supplied one
   × field validation > still refuses an update that blanks a required field
   × settings validation > refuses the NaN-to-null ... GlossaryAutoLink                (expected 400, got 200)
   × settings validation > refuses a non-integer track length
   × settings validation > refuses an unknown setting key rather than storing it unread
   (the other 2 new tests - 'allows an update that omits a required field' and 'accepts a boolean for GlossaryAutoLink' - are regression guards that pass on both sides)
   All 8 are plain assertion failures on the route's behaviour (status/body), not import or missing-helper errors.
3. GREEN: adminLogic.ts (fix, verbatim) + library.ts (validation hunks only): ` ✓ src/routes/library.test.ts (24 tests)` / `Tests  24 passed (24)` => 24/24
   Also: `npx tsc -p tsconfig.json --noEmit` in apps/server with the scoped patch: exit 0.
   Also: swapping in the fix commit's REAL full library.ts + adminLogic.ts + repo.ts (restore route + delete guard included): still 24/24 -> scoped tests are consistent with the real fix.
4. MUTATION (each hunk removed alone from the green tree; restored after):
   M1 drop settings validation -> 3 failed (the 3 settings tests);  M2 Id spread order reverted -> 1 failed (Id test);  M3 drop PUT validation -> 1 failed;
   M4 drop defaults -> 1 failed (default test);  M5 drop POST validation -> 2 failed (missing/blank required). Restored -> 24/24.
- Fairness/determinism: supertest against an in-process express app, repo mocked with vi.mock, no network/db/timers. The server's vitest.config.ts injects stub SUPABASE_URL/KEY
  env (no real Supabase). One noisy `console.error` stack trace ("status: 409") from a pre-existing optimistic-locking test - harmless.
- allowFiles: library.ts, adminLogic.ts, library.test.ts (3 files: the fix's helpers live in adminLogic.ts; the model may inline instead - srcRevertFiles lists both).
- Verdict: VERIFIED. baseline 14/14 -> red 8/24 -> green 24/24.

---------------------------------------------------------------------------------------------------------------------------
## CANDIDATE C: Bond cap hardcoded to 5 while GameSettings.BondTrackLength is admin-editable (asohav-06-bond-cap-setting)  -- STATUS: VERIFIED (scoped from a bundle)
- fix commit : 3615d3d8bbbeb7313e43d9719ae5f7b01dd6588c  "Ship 0.50.0: correctness and safety, out of the project audit"  2026-09-11 19:49 +0000 (PR #131), 39 files, +1241/-189
- parent     : 84719041b3312cab3e49901dea20d7129bb24761  (merge of PR #130, the real first-parent of the fix commit)
- SCOPING: 0.50.0 bundles ~9 unrelated changes (boot-seed guard, optimistic locking, SpendHoldModal, archive freeze x4 routes, three read-time normalizes, phase-gated combat
  route, CharacterSheet.Level removal, errorMiddleware extraction, +14 library tests). Kept ONLY the "Changed: The Bond cap reads GameSettings.BondTrackLength instead of a
  hardcoded 5" change, which is confined to packages/shared/src/logic.ts (isBondLocked, applySpendBond, resolveAcceptedBond + new exported DEFAULT_BOND_CAP) with tests in
  packages/shared/src/logic.test.ts. (The server bond.ts caller change - reading BondTrackLength from the library - is dropped: it needs getLibrary wiring and is a separate hunk.)
- TEST SCOPING: parent's logic.test.ts + the fix commit's `describe('Bond cap honours GameSettings.BondTrackLength')` block VERBATIM except ONE line removed
  (`expect(DEFAULT_BOND_CAP).toBe(5);` - the constant is a new export the prompt need not mandate) + ONE added import name (`resolveAcceptedBond`, which already exists at the parent).
  Dropped: normalizeBond/normalizeEncounter/normalizeAdventure tests + imports (new helpers => import-error red), `Level: 0` fixture line. Saved: logic.test.bondcap.scoped.ts.
- SOURCE for green: the Bond region of the fix commit's logic.ts only (DEFAULT_BOND_CAP + the three functions), spliced into the parent's logic.ts; saved logic.bondcap.scoped-fix.ts.
- setup: NONE (logic.test.ts imports only vitest, ./logic.js, ./engine.js, ./seedLibrary.js, ./seedPlay.js, ./types.js - confirmed with git show of the parent tree).
- install: `npm ci --ignore-scripts` OK (7.6s). testDir=packages/shared ; testCmd=npx vitest run src/logic.test.ts

Runs (fresh worktree wt/bondcap):
1. BASELINE @ parent: ` ✓ src/logic.test.ts (93 tests) 42ms` / `Tests  93 passed (93)`  => 93/93
2. RED (scoped test file, source untouched): `Tests  3 failed | 94 passed (97)`  => 3/97 red:
   × ... does not treat a 5/5 Bond as locked when the authored cap is 7   → expected true to be false
   × ... rolls a spent-below-zero track back to cap - 1, not a hardcoded 4 → expected 4 to be 6
   × ... clamps an accepted MarkBond and a Forge to the authored cap       → expected 5 to be 7
   (the 4th new test, 'defaults to 5', is a regression guard that passes both sides.) Assertion failures on behaviour, not import errors.
3. GREEN (Bond hunk of fix's logic.ts): ` ✓ src/logic.test.ts (97 tests)` / `Tests  97 passed (97)` => 97/97 ; `npx tsc -p tsconfig.json --noEmit` in packages/shared: exit 0.
4. MUTATION (one site at a time on the green tree): M1 isBondLocked ignores cap -> 1 failed; M2 rollback hardcoded 4 -> 1 failed; M3 MarkBond clamp hardcoded 5 -> 1 failed;
   M4 Forge clamp hardcoded 5 -> 1 failed;  **M5 nested applySpendBond inside resolveAcceptedBond drops cap -> 97/97 PASS (SURVIVES);  M6 applySpendBond's own lock check drops cap -> 97/97 PASS (SURVIVES)**.
   => the fix commit's tests do NOT pin two of the six cap sites. I authored two EXTRA tests (not in the fix commit; saved logic.test.bondcap.scoped+extra.ts):
   'applySpendBond only treats a Bond as locked at the authored cap' and 'resolveAcceptedBond passes the cap through to a legacy SpendBond proposal'.
   With them: unfixed parent source -> `Tests  5 failed | 94 passed (99)`; fixed -> 99/99; M5 -> 1 failed (the new SpendBond test); M6 -> 1 failed (the new lock test); restored -> 99/99.
   Recommendation: keep these two as an owner `acceptance` block (informational) so a model that patches 4 of 6 sites is visible.
- Determinism: pure functions. Windows-safe.
- Verdict: VERIFIED. baseline 93/93 -> red 3/97 -> green 97/97 (fix commit's tests); with the 2 extra acceptance tests: red 5/99 -> green 99/99.
