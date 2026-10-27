# Candidate tasks mined 2026-09-29 (all baselines/red/green re-run in fresh worktrees by the mining agents; rows marked "I re-ran" were reproduced independently by me)

fit: A = fits the harness today (1 src + 1 test, green baseline); A* = same but tests authored by the mining agent, not upstream; A! = env-sensitive; B = needs the srcRevertFiles fix; C = needs an implement-to-given-tests task kind (red baseline, protect test files); D = >2 files (scope gate); E = needs typecheck as a gate; X = not gradable today.

| id | fit | fix (date) | parent | files | baseline -> red -> green | what it is |
|---|---|---|---|---|---|---|
| kane-05-singleton-copy-limit | A* | no upstream fix | 92a8ed0df | server/src/services/deckValidation.ts + .test.ts | 10/10 -> 5 red/18 -> 18/18 | CR 903.5b singleton rule. OWNER-DIAGNOSED open defect on unmerged review-gate/deck-validity; no upstream fix, tests + reference fix AUTHORED by the mining agent (kane-05.* artifacts). Trap: a correct fix turns 4 of the 10 original tests red (filler basics modelled as generic cards), so the executor must update fixtures, not weaken the fix |
| kane-06-commander-legality-dedupe | A* | no upstream fix | 92a8ed0df | same two files | 10/10 -> 5 red/18 -> 18/18 | Named commanders never checked against legality_commander; banned/notFound not deduped. Same provenance as kane-05 (authored tests) |
| kane-07-find-qualifier-type | A | 731e98508 2026-08-22 | 108895391 | server/src/services/signals.ts + .test.ts | 76/76 -> 1 red/77 -> 77/77 | regex/qualifier: candidate type must tie to the payoff matcher (clean 2-file commit) |
| kane-08-aristocrats-false-positives | A | e95219824 2026-08-26 | 45095ab14 | server/src/services/signals.ts + .test.ts (scoped; synergy.ts dropped) | 234/234 -> 4 red/238 -> 238/238 | four independent regex/helper false-positive fixes in one big file; hidden constraint (matcher must stay a RegExp) is caught by the pre-existing suite. Large signals.ts is what made kane-02 the hardest task |
| kane-09-colour-filter-subset | A | e0ef29036 2026-08-24 | f0abf087f | client/src/lib/filters.ts + .test.ts (scoped) | 16/16 -> 3 red/17 -> 17/17 | SPEC REVERSAL: two existing assertions flip, so the model must rewrite existing tests (no current task does) |
| kane-10-combo-permalink-scheme | A | 271636f41 2026-08-21 | 605a2e080 | apps/home/src/components/ComboPreferenceRow.tsx + apps/home/src/routes/Profile.test.tsx | 10/10 -> 1 red/11 -> 11/11 (I re-ran) | SECURITY + REACT component test (RTL/jsdom exist here): javascript: permalink rendered as href. Scoped from a 9-bug audit commit |
| kane-11-useauth-session-reject | A | 271636f41 2026-08-21 | 605a2e080 | packages/profile/src/useAuth.ts + .test.ts | 11/11 -> 1 red/12 -> 12/12 | async error path in a React hook (renderHook): getSession() rejection leaves loading true |
| kane-12-error-handler-400 | A | 271636f41 2026-08-21 | 605a2e080 | server/src/errorHandler.ts + .test.ts | 3/3 -> 1 red/5 -> 5/5 | malformed JSON body mapped to 500 not 400 (easy; likely saturates) |
| kane-13-front-face-field | A | 271636f41 2026-08-21 | 605a2e080 | packages/card-model/src/scryfallFields.js + .test.js | 20/20 -> 1 red/22 -> 22/22 | plain JS (not TS); adventure vs split card faces; a naive "always front face" fix is punished by a control test |
| kane-14-undo-toast-timer | B | 271636f41 2026-08-21 | 605a2e080 | time-counters UndoToast.tsx + App.tsx + NEW UndoToast.test.tsx | full suite 108/108 -> 1 red/111 -> 111/111 | React + fake timers; timer keyed on card name not removal identity; new prop plumbed through App (2 src files) |
| lfc-04-admin-manage-server-permission | A | 0e9d12384 2026-09-25 | e644702a6 | src/commands/admin/admin.ts + tests/commands/admin/admin.test.ts | 4/4 -> 1 red/5 -> 5/5 (I re-ran) | DISCORD AUTHZ: /admin default visibility must include Manage Server, not only Administrators. New since last pull (09-25) |
| lfc-05-digest-allowed-mentions | A | d998d2da5 2026-08-30 | 6f5a5038a | src/services/digest.ts + tests/services/digest.test.ts (scoped from a bundle) | 6/6 -> 1 red/7 -> 7/7 | SECURITY: display name "everyone" can mass-ping; suppress mention parsing |
| lfc-06-autocomplete-deadline | A! | 64939c4c5 2026-09-25 | 2383f2491 | src/services/scryfall.ts + tests/services/scryfall.test.ts (scoped) | 12/12 -> 2 red/14 -> 14/14 | async/timing: single autocomplete attempt with no retry; skip requests whose deadline passed while queued. ENV-SENSITIVE: MANAPOOL_API_KEY must be unset (same flake as lfc-02). New (09-25) |
| lfc-07-digest-split | B | e644702a6 2026-09-25 | d6a5338d8 | src/services/digest.ts + src/utils/constants.ts + tests/services/digest.test.ts | 7/7 -> 6 red/13 -> 13/13 | split an over-long digest across messages without dropping lines or advancing the watermark on partial failure. New (09-25). Needs the multi-src harness fix |
| asohav-03-glossary-depth-flatten | A | 300354238 2026-08-14 | 5c8919368 | packages/shared/src/glossary.ts + .test.ts (scoped) | 20/20 -> 2 red/21 -> 21/21 (I re-ran) | the candidate the roadmap DROPPED as unscopable is scopable: the test change is pure-function only. Mutation checks show both halves of the fix are required |
| asohav-04-neutral-status-polarity | A | 2729b5861 2026-08-13 | f15a58cb9 | packages/shared/src/engine.ts + .test.ts (scoped from a bundle) | 22/22 -> 2 red/24 -> 24/24 | Neutral Status treated as Negative at two independent sites (each mutation-verified) |
| asohav-05-library-write-validation | B | 3e0b07459 2026-09-12 | 79b369d7b | apps/server/src/routes/library.ts + adminLogic.ts + library.test.ts (tests hand-scoped: parent tests + two verbatim describe blocks) | 14/14 -> 8 red/24 -> 24/24 | five input-trust hunks (required, defaults, Id spread order, settings type checks), each mutation-verified. Needs @asohav/shared build (setup) |
| asohav-06-bond-cap-setting | A | 3615d3d8b 2026-09-11 | 84719041b | packages/shared/src/logic.ts + .test.ts (scoped) | 93/93 -> 3 red/97 -> 97/97; with 2 extra acceptance tests 5 red/99 | hardcoded cap of 5 at six sites; the upstream tests pin only four (mutation survivors), so a model can pass gates with a partial fix. Ideal for a testMustCover/acceptance block |
| asohav-07-rapport-clamp | A | 2db8a09b3 2026-09-22 | d73d6c978 | apps/server/src/routes/party.ts + .test.ts (web file dropped) | 5/5 -> 1 red/5 -> 5/5 | over-eager server clamp discards banked state. Needs shared build. New (09-22) |
| asohav-08-end-combat-clears-strain | A | d7696990b 2026-09-23 | 9afb9112b | apps/server/src/routes/combat.ts + .test.ts (web halves dropped) | 18/18 -> 1 red/20 -> 20/20 | missing cascading side effect on a state transition across separate records; documented live defect. Prompt must pin the saveSheet call shape. Needs shared build. New (09-23) |
| asohav-09-seed-virtue-conformance | A | aec6644bf 2026-09-25 | 8686bf41c | packages/shared/src/seedLibrary.ts (1 token) + NEW seedLibrary.test.ts | 368/368 -> 1 red/371 -> 371/371 | data/spec conformance: source of truth is a Markdown ruleset, not code. Naming m-strike collapses it to a one-token edit, so prompt with the symptom only. New (09-25) |
| asohav-10-contract-to-wp-odds | C | 46e88f5e0 2026-09-23 | 44ead5d61 | packages/shared/src/odds.ts (tests GIVEN) | 7 red by design -> 7/7 (whole shared suite 349/356 -> 356/356) (I re-ran) | IMPLEMENT-TO-GIVEN-TESTS: contract commit ships stub + exact-count tests, WP commit implements. Pure enumeration math; CLAUDE.md forbids randomness (Monte-Carlo trap) |
| asohav-11-contract-to-wp-engine | C | e793ff9bf 2026-09-22 | dae86a90f | packages/shared/src/engine.ts (tests GIVEN) | 261/272 -> 272/272 (11 red by design) | implement-to-given-tests, small |
| asohav-12-contract-to-wp-enemies | C | 4e5bbcf29 2026-09-23 | 088e5e779 | packages/shared/src/enemies.ts + combat.ts (tests GIVEN) | 322/353 -> 353/353 (31 red by design) | implement-to-given-tests, large (12 stubs, ~200 lines): the hardest candidate; also 2 src files |
| asohav-13-misfortune-authz | D | 7c5a4de00 2026-09-23 | e90990775 | party.ts + adventures.ts + 2 test files (4 files) | 19/19 -> 14 red/37 -> 37/37 | GM-only resource on a member-writable document; authz matrix (403/409/404). Multi-file and partly a feature |
| (nom) lfc multi-file autocomplete | D | 64939c4c5 2026-09-25 | 2383f2491 | 3 src + 6 test files | 38/38 -> 10 red/46 -> 46/46 | multi-file bug fix (scope gate assumes 2 files) |
| (nom) kane fading permanents | D | 4029a94a8 2026-08-16 | f7d9bc129 | 4 src files (+2 test) | hook-level tests: 2 red/23; full 38/38 -> 48/48 | inherently multi-file: fix adds an exported predicate other files import |
| (nom) asohav web character create | E | 3a7589d7b 2026-09-25 | 8686bf41c | apps/web api.ts + CreateCharacterPage.tsx | vitest never goes red; only tsc does (exit 2 -> 0) | type-oracle bug: since 0.55.0 every web-created character got a 400. Needs typecheck as a hard gate |
| (nom) kane parseJsonArray refactor | X | no upstream fix | 2945ca84a | 6 files | suite green before AND after; only tsc catches a dropped import | behaviour-preserving refactor; needs kind=refactor (skip failsOnOld, tsc hard gate, structural grep check) |

## Pin the parents ahead of time (run in each local checkout; the roadmap uses the same `git branch bench/... <sha>` convention)

The `bench/*` names below are proposals. Pinning is cheap and makes the task base immutable even if history is later rewritten. Push them too (`git push origin bench/<name>`), or the tasks are again reproducible only from your disk.

```powershell
# C:\Projects\KaneEnabler   (mkane848/kaneenabler)
git fetch origin
git branch bench/singleton-copy-limit 92a8ed0df10262cc878d4d214d0a312d542375ec
git branch bench/commander-legality-dedupe 92a8ed0df10262cc878d4d214d0a312d542375ec
git branch bench/find-qualifier-type 10889539112089dcd122014f934520f9f11cf558
git branch bench/aristocrats-false-positives 45095ab148d27fdbe20765a112d1dd7d743e4fcd
git branch bench/colour-filter-subset f0abf087f92323e69a0a706e14c22b427fb80d31
git branch bench/combo-permalink-scheme 605a2e080cfddee855337f1b3d0b9cf7e48ddd6e
git branch bench/useauth-session-reject 605a2e080cfddee855337f1b3d0b9cf7e48ddd6e
git branch bench/error-handler-400 605a2e080cfddee855337f1b3d0b9cf7e48ddd6e
git branch bench/front-face-field 605a2e080cfddee855337f1b3d0b9cf7e48ddd6e
git branch bench/undo-toast-timer 605a2e080cfddee855337f1b3d0b9cf7e48ddd6e
```
```powershell
# M:\Projects\LFCbot   (mkane848/lfc-bot)
git fetch origin
git branch bench/admin-manage-server-permission e644702a6ce9753b69ca3291e1bdc388e2d1a7d3
git branch bench/digest-allowed-mentions 6f5a5038aef79c2ccdcd460d9ebfa9c6b2e16cef
git branch bench/autocomplete-deadline 2383f249101da5a4a39b07af18efa8f85bb311c7
git branch bench/digest-split d6a5338d809407d181b7d74eef064bbd0d81ffa2
```
```powershell
# M:\TTRPG\A Story of Heroes and Villains   (mkane848/asohavcompanionapp)
git fetch origin
git branch bench/glossary-depth-flatten 5c891936847a844bb23dd74b02aa1fa6f1525f84
git branch bench/neutral-status-polarity f15a58cb9ef29c3b511caa0d88949a7b10686874
git branch bench/library-write-validation 79b369d7ba01ed02affa6534a33ef698d17b5518
git branch bench/bond-cap-setting 84719041b3312cab3e49901dea20d7129bb24761
git branch bench/rapport-clamp d73d6c978f478e3aca5fb836683fcfe639debd43
git branch bench/end-combat-clears-strain 9afb9112b0e2596edac0e7fe4055149512ab3b62
git branch bench/seed-virtue-conformance 8686bf41c9ac130bd521f05e056460ca777f43bf
git branch bench/contract-to-wp-odds 44ead5d619bb1a26854c0d861aa75a89f14a8fd6
git branch bench/contract-to-wp-engine dae86a90ffb221d17210e1eed6def4c49249f2a1
git branch bench/contract-to-wp-enemies 088e5e7797d92f4ea08a6a4d68247c6d4ef9ec1c
git branch bench/misfortune-authz e90990775d5a01c6f61d511272960e1767e585da
```
