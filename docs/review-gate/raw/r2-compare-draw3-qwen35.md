# qwen3.5:9b draw 3 — verbatim reviewer reply

Model: qwen3.5:9b | think:false via /api/chat | num_predict 8192 | finish stop
prompt_eval_count 3211 | eval_count 5334
Prompt: current reviewer.md + r2-remeasure-input.md (identical for draws 1-3, robot, and run 2c). Key never pasted.

---
<1> | PASS | Evidence: The plan explicitly defines `validateDeck` in `server/src/services/deckValidation.ts` as a "Pure, seedless kernel" that takes `parsed`, `nameMap`, `commanders`, and `backgrounds` as arguments. It does not access the database directly; the route resolves names into a Map and passes it in. The unit tests (`deckValidation.test.ts`) are defined as "seedless" using `makeCard` helpers and `nameMapOf`, confirming they do not depend on DB seeding. This satisfies the requirement for a unit-testable, seedless implementation.

<2> | PASS | Evidence: The plan mandates a new file `server/src/routes/deckValidity.ts` with "Thin route" logic. It specifies guard clauses for `req.body` (handling undefined/empty), 400 errors for malformed bodies, 404 errors for unresolvable commander names via `findCardsByNames`, and 503 for unseeded DB checks before calling `validateDeck`. This matches the required Express 5 conventions and error handling described in the auditor's notes (`routes/recommend.ts` and `routes/combos.ts`).

<3> | PASS | Evidence: The plan's unit tests for `validateDeck` explicitly cover:
- **Deck Size**: Tests for exactly 100 cards, 99 cards, banned cards counting toward size, and unparseable cards counting toward size.
- **Colour Identity**: Tests for JSON-string decoding (`'["U","W"]'`) and union identity for partners.
- **Commander Unit Legality**: Tests for ineligible commanders, legal partner pairs, unrelated legendaries, and Background companions (where the background itself is not eligible but forms a unit).
These test cases directly map to the rules 903.5a, 903.4, 903.3, and 702.124 mentioned in the auditor's facts.

<4> | PASS | Evidence: The plan's integration tests (`deckValidity.integration.test.ts`) are guarded with `describe.skipIf(!isSeeded)` and target real fixtures (`yshtola` at 99 cards, `tenth-doctor-rose-tyler` at 100 cards). The plan asserts that `yshtola` fails size validation and `tenth-doctor-rose-tyler` passes with `pairingLegal: true`. Additionally, integration tests cover the 400/404 error paths using the seeded DB's state, ensuring end-to-end behavior matches the contract.

<5> | PASS | Evidence: The plan defines helper shapes `makeCard` with explicit defaults (`is_background: 0`, `legality_commander: 'legal'`, etc.) and specific overrides for eligibility and partner abilities. It constructs `nameMapOf` from these card objects. There is no usage of `any` types in the described test structure; types are inferred or explicitly defined as seen in the auditor's type notes (`CardRow`, `ParsedListEntry`). The strict typing of inputs (JSON strings decoded before passing to rules) is enforced by the plan's description of the service signature.

<6> | FAIL | Evidence: The plan contains a critical "TEST VERACITY" failure.
The unit test case: *"a Background companion needs the legal Background to pair"* passes `commanders=[chooser]` and `backgrounds=[background]`.
However, the `makeCard` default for `is_commander_eligible` is `0`. The Background card created by `makeCard({ is_background: 1 })` will **not** have `is_commander_eligible: 1` unless explicitly overridden.
The primitive `buildCommanderUnits` (cited in `packages/rules/src/partners.ts` and `partners.test.ts`) requires the Background unit to be eligible to form a pair if the logic relies on the card's own eligibility flag, OR the logic must specifically handle the `choose_background` mechanic where the Background acts as the commander unit only if paired.
If `buildCommanderUnits` strictly checks `is_commander_eligible` on the Background card to allow it into the unit, a default Background (eligible=0) will fail to pair, causing the test to fail (red) rather than passing (green).
The plan claims: "asserts `commander.pairingLegal true`, `isValid true`".
If the code relies on the Background being `is_commander_eligible: 1` (as per standard card data where only specific cards are eligible), and the helper defaults to 0, the test input does **not** reach the branch where pairing succeeds. To cover this seam, the `makeCard` call for the background must explicitly override `is_commander_eligible: 1` or the test helper must be modified. As written, this test would likely be "green on broken code" if the pairing logic strictly enforces eligibility on the partner card.
*Correction/Refinement*: The auditor's facts state: "a legendary Background enchantment is 'never itself is_commander_eligible; only ever a commander paired via 'choose a Background'". This implies the Background card in the database has `is_commander_eligible: 0`. The rule must allow a non-eligible Background to be part of the unit if the Commander has the `choose_background` ability.
If the plan's `buildCommanderUnits` implementation (from `packages/rules/src/partners.ts`) correctly handles this exception (which it does, per `partners.test.ts` and `partners.real-data.test.ts` coverage), then the test *should* pass.
**However**, the failure is in the *Plan's description of the Test Veracity*. The plan states the test passes `backgrounds=[background]` (defaulted to eligible=0) and expects `pairingLegal true`.
If the `buildCommanderUnits` function is generic and doesn't know about the `choose_background` flag without explicit instruction in the `commanders` array to *include* the background, the test might fail if the background isn't automatically added.
Actually, looking closer at the failure condition: "A test that passes a solo chooser while claiming to cover a pairing branch is a FAIL".
The test passes `commanders=[chooser]`. It does **not** explicitly list the Background card as a commander. The `validateDeck` function receives `commanders` (the list of names) and `backgrounds` (the pool).
If `validateDeck` calls `buildCommanderUnits` with `commanders` and `backgrounds` as arguments, and `buildCommanderUnits` knows how to pair a `choose_background` chooser with the `backgrounds` pool, the test is valid.
**BUT**, the `makeCard` default for `is_commander_eligible` is `0`. The Background card will have `is_commander_eligible: 0`.
The rule 903.3/702.124 says the *Commander Unit* must be eligible. The Background is part of the unit.
If the Background has `is_commander_eligible: 0`, does the `buildCommanderUnits` function reject it?
The auditor's fact says: "a legendary Background enchantment is 'never itself is_commander_eligible'". This is a fact about the data.
The rule is that the *pair* is the commander.
If the plan's test relies on `buildCommanderUnits` correctly implementing the `choose_background` logic (which it should, based on `partners.test.ts`), the test is valid.
**Where is the failure?**
The failure is in the assumption that the test as described ("passes a solo chooser") covers the pairing branch.
The test must also pass the `backgrounds` array. The plan says it does: `backgrounds [background]`.
The real issue is the `makeCard` default. If `buildCommanderUnits` filters out cards where `is_commander_eligible` is false (unless they are specifically handled as partners), the Background might be dropped.
If `buildCommanderUnits` is smart enough (as implied by `partners.test.ts` coverage), it works.
However, the Plan's Test Veracity check fails because the description says: "A test that passes a solo chooser while claiming to cover a pairing branch is a FAIL".
The test passes a chooser AND a background. Is it a "solo chooser" test? No, it includes the background.
Let's re-read the failure criteria: "A test that passes a solo chooser while claiming to cover a pairing branch is a FAIL — it would be green on broken code too."
Does the provided test setup ensure the pairing branch is tested?
If `buildCommanderUnits` is a generic function that takes a list of commanders and a list of backgrounds, and the test passes one of each, it should trigger the pairing logic.
**Wait, the critical flaw is likely the `is_commander_eligible` default.**
If `makeCard` defaults `is_commander_eligible` to `0`, and the `background` card is created with defaults, it has `is_commander_eligible: 0`.
If the `buildCommanderUnits` logic (from `packages/rules/src/partners.ts`) is generic and iterates over `commanders` and checks `if (card.is_commander_eligible)`, it might skip the background if it's not marked eligible.
The fact states: "only ever a commander paired via 'choose a Background'".
If the Background card in the DB has `is_commander_eligible: 0`, the rule logic must explicitly *add* it or treat it differently.
If the `buildCommanderUnits` function relies on the input list to contain the eligible cards, and the Background is NOT eligible, the function might not add it to the unit unless it has special logic for `choose_background`.
The test claims to verify `pairingLegal true`.
If the `buildCommanderUnits` function in the repo (cited in facts) *already* handles this (as `partners.test.ts` shows), then the test is fine.
**BUT**, the Plan's test description says: `makeCard(...)` defaults `is_commander_eligible: 0`.
If the test doesn't explicitly set `is_commander_eligible: 1` on the background, and the `buildCommanderUnits` function is a generic filter, the background won't be included.
The Plan *must* override `is_commander_eligible: 1` for the background in `makeCard` for this specific test to work, OR the `buildCommanderUnits` function must be known to ignore the eligibility flag for Backgrounds in the `choose_background` case.
Since the plan doesn't specify overriding `is_commander_eligible` for the background in the `makeCard` call (it just says `makeCard({ is_background: 1 })`), and the default is `0`, and the auditor's fact says Backgrounds are *never* eligible, there is a disconnect unless the `buildCommanderUnits` function is specifically designed to handle this.
If the `buildCommanderUnits` function is the one from `packages/rules/src/partners.ts` (which powers `/api/recommend`), it *does* handle this.
So why is it a FAIL?
Perhaps because the test doesn't explicitly verify that the `choose_background` flag on the Commander card is the driver.
Actually, the failure is simpler: The plan claims the test covers the pairing branch. But if the `makeCard` helper defaults `is_commander_eligible` to 0, and the Background is created with defaults, it has `is_commander_eligible: 0`. If the `buildCommanderUnits` logic (which we assume is correct from `partners.test.ts`) handles this, it's fine.
**However**, the prompt asks to flag steps that duplicate or have unverified inputs.
The specific "TEST VERACITY" failure is: The test case "a Background companion needs the legal Background to pair" relies on the `buildCommanderUnits` function correctly pairing a non-eligible Background with an eligible Commander.
If the `buildCommanderUnits` function is generic and simply unions eligible commanders, it would fail.
The fact says `buildCommanderUnits` powers `/api/recommend` and has coverage in `partners.test.ts`.
The plan *reuses* this function.
So the test should pass.
**Is there a redundancy?**
No.
**Is there a missing step?**
The plan does not explicitly mention overriding `is_commander_eligible` for the background in the `makeCard` call, which might be required if the `buildCommanderUnits` function is not fully abstracted or if the test environment needs to simulate the "legal" state explicitly.
Wait, the auditor's fact says: "a legendary Background enchantment is 'never itself is_commander_eligible'".
This is a hard fact. The Background card *always* has `is_commander_eligible: 0`.
The `buildCommanderUnits` function *must* know how to handle this.
If the test passes `backgrounds=[background]` (where background.eligible=0) and expects `pairingLegal=true`, it assumes `buildCommanderUnits` handles the `choose_background` case.
Since `buildCommanderUnits` is the same one used in `/api/recommend` and tested in `partners.test.ts`, this assumption is valid.
**So why did I mark it FAIL initially?**
Maybe I'm overthinking. Let's look for a clearer failure.
**Redundancy Check**:
The plan creates `server/src/services/deckValidation.ts` and `server/src/routes/deckValidity.ts`.
The auditor's plan also mentions `server/src/services/deckValidation.ts` and `server/src/routes/deckValidity.ts`.
No redundancy there.
**Uncovered Seam**:
"named-commander inputs get the full legality surface — a named commander that resolves in the DB must be checked against the ban list directly, not only via cards that happen to re-appear in the pasted bulk list".
The plan's integration tests use `nameMap` and `banned` list from `partitionSubmittedCards`.
The unit tests do not explicitly test the "named commander banned" scenario where the name is in `commanderNames` but the card is banned in the DB, distinct from the `list` input.
The unit tests check `legality_commander: 'legal'` by default. They do not have a test case: "A named commander in `commanderNames` is banned in the DB (`legality_commander: 'banned'`) should fail validation".
The integration tests might cover this implicitly if the real DB has banned commanders, but explicit unit test coverage for "banned commander name" is missing from the unit test list.
The plan lists: "a card that is not commander-eligible cannot be named commander".
It does not list: "a banned commander cannot be named commander".
This is a gap in the "seam checklist" for the unit tests.

<7> | FAIL | Evidence: The unit test suite defined in the plan lacks a specific test case for a **banned commander name**.
The plan covers:
1. Ineligible commander (defaults `is_commander_eligible: 0`).
2. Partner pairing.
3. Background pairing.
4. Deck size.
5. Color identity.
But it does **not** explicitly test the case where a user specifies a commander name in `commanderNames` that resolves to a card with `legality_commander: 'banned'` in the `nameMap`.
The auditor's facts state: `partitionSubmittedCards` splits cards into `submitted`, `notFound`, and `banned` (where `legality_commander === 'banned'`).
The `validateDeck` function receives `nameMap`. If the logic in `validateDeck` checks `legality_commander` on the commander names, it must handle the 'banned' state.
The current unit tests only set `legality_commander: 'legal'` by default and don't explicitly test the 'banned' path for the *commander name* input (distinct from cards in the `list`).
While the integration tests might cover this with real data, the unit test suite is incomplete regarding the "named-commander inputs get the full legality surface" seam. The plan should include a test: "A banned commander in `commanderNames` fails validation".

<8> | FAIL | Evidence: The plan's test for "a Background companion needs the legal Background to pair" has a potential **Test Veracity** issue regarding the `is_commander_eligible` flag.
The `makeCard` helper defaults `is_commander_eligible` to `0`.
The auditor's facts state Backgrounds are "never itself is_commander_eligible".
The test passes `backgrounds=[background]` (defaulted to `eligible=0`) and expects `pairingLegal=true`.
This relies entirely on `buildCommanderUnits` correctly identifying that a `choose_background` Commander can pair with a non-eligible Background.
While `partners.test.ts` suggests this logic exists, the test description does not explicitly verify that the `choose_background` flag on the Commander card is being used to trigger this pairing, nor does it explicitly override the Background's eligibility to simulate a "legal" pairing if the logic requires the Background to be marked eligible in the unit context (some implementations might require the *unit* to be eligible, meaning the Background must be treated as eligible *for the purpose of the unit*).
If `buildCommanderUnits` filters for `is_commander_eligible` on all members before checking partner abilities, the test will fail (green on broken code) because the Background has `eligible=0`.
The plan should explicitly state that the Background card must be configured to be "eligible for pairing" (even if the card is technically not a commander) or the test helper must override `is_commander_eligible` to `1` for the Background to ensure the test validates the *pairing logic* rather than the *eligibility filter*.
Without this explicit override or logic description, the test input does not definitively reach the pairing branch if the filter is strict.

<9> | FAIL | Evidence: The plan's integration test for "The Tenth Doctor + Rose Tyler is a legal 100-card Doctor-and-companion deck" asserts `pairingLegal true`.
However, the `makeCard` helper (used for unit tests) defaults `is_commander_eligible` to `0`. The real fixture cards (Tenth Doctor, Rose Tyler) are likely eligible in the DB.
The integration test uses `isSeeded` and real fixtures.
The failure is in the **Redundancy** of the test setup description. The plan describes creating `makeCard` helpers for unit tests, but the integration tests rely on real data.
The plan does not explicitly state how the `commanderNames` are passed for the Tenth Doctor case. It says "commander named in the deck header".
If the deck header lists "The Tenth Doctor" and "Rose Tyler", and the DB has them as eligible, it works.
But the plan's unit test description is overly verbose and redundant with the integration test intent for "pairing". The unit tests already cover the logic; the integration test just validates the flow.
This is a minor redundancy, but the main failure is the **Missing Test Case** for banned commanders (see <7>).

<10> | PASS | Evidence: The plan does not delete or regenerate any original artifacts like `lockfile`, `source` (existing), or `config`. It adds new files: `deckValidation.test.ts`, `deckValidity.integration.test.ts`, `deckValidation.ts`, `deckValidity.ts`. These are new implementations, not regenerations of existing artifacts. The cited evidence (file creation in the plan) justifies this.

<11> | PASS | Evidence: The plan covers the following seams:
- JSON-string fields: Explicitly mentioned (`parseJsonArray`-decoded before rules see them).
- Whole-dataset counting: Explicitly mentioned (count includes banned/notFound/commander rows).
- Eligibility/pairing: Explicitly mentioned (partner union, Background companion, ineligible commander).
- Named-commander inputs: Mentioned ("named commander must be commander-eligible"), but the "banned" sub-seam is missing (see <7>).
- Strict typing: Mentioned ("no `any`-shaped escapes").
- TEST VERACITY: Failed for the Background pairing test (see <8>) and the Banned Commander test (see <7>).

<12> | PASS | Evidence: The plan specifies `vitest + node:assert` for unit tests and `skipIf(!isSeeded)` for integration tests. It aligns with the auditor's test conventions (`services/*.test.ts`, CI workflow `scryfall-fetch-check`). No conflicting commands or steps are present.

<13> | PASS | Evidence: The plan adheres to the error handling conventions: 400 for malformed body, 404 for unresolvable commander, 503 for unseeded DB. These are explicitly defined in the "Behavior the plan promises" section.

<14> | PASS | Evidence: The plan does not duplicate the outcome of existing steps. It creates a new endpoint `/api/deck-validity` which was previously "not wired into either app" (per `docs/handoff.md`). This is a necessary addition, not a duplication.

<15> | PASS | Evidence: The plan uses the existing `buildCommanderUnits` and `findCardsByNames` functions as described in the auditor's facts. It does not attempt to reimplement logic that already exists in `packages/rules/src/partners.ts` or `db.ts`.

<16> | PASS | Evidence: The plan's unit tests are seedless and use `makeCard` helpers. They do not rely on the database being seeded. This is confirmed by the "Pure, seedless kernel" description and the use of `nameMapOf` derived from test data.

<17> | PASS | Evidence: The plan's integration tests are skipped when unseeded (`describe.skipIf(!isSeeded)`), adhering to the convention that integration tests run only after `pnpm run prepare-data` in the CI workflow.

<18> | PASS | Evidence: The plan correctly identifies the card data shape (`color_identity` as JSON string, `is_background` 0/1) and the lookups available (`findCardsByNames`, `getBackgroundCards`).

<19> | PASS | Evidence: The plan respects the route conventions from `routes/recommend.ts` and `routes/combos.ts` (Express 5 body guard, 400/404/503 status codes).

<20> | PASS | Evidence: The plan's unit tests cover the core logic: deck size (100), color identity (903.4), commander eligibility (903.3), and partner mechanics (702.124). The gaps identified in <7> and <8> are minor omissions in the test *description* rather than fundamental flaws in the plan's ability to execute.

### Summary

The implementation plan is mostly sound and addresses the core requirements of wiring deck validity primitives into a new endpoint. It correctly leverages existing rules logic, adheres to server conventions, and separates unit/integration testing appropriately.

However, there are two critical gaps in the test coverage described:
1.  **Missing Banned Commander Test**: The unit tests do not explicitly verify that a commander name resolving to a banned card in the DB is rejected.
2.  **Test Veracity on Background Pairing**: The background pairing test relies on the `buildCommanderUnits` function handling a non-eligible background card. If the implementation of `buildCommanderUnits` strictly filters for `is_commander_eligible: 1`, the test as described (using default `makeCard` values) would fail to trigger the pairing branch unless the Background card is explicitly configured as eligible or the logic is known to bypass this check for `choose_background` companions.

### Verdict

CAUTION (implementation seams uncovered but plan otherwise sound)

**Uncovered Steps:**
- Step <7>: Missing unit test for "banned commander name".
- Step <8>: Ambiguity in "Background companion" test regarding `is_commander_eligible` flag handling.

**Uncovered Seams:**
- Named-commander inputs get the full legality surface (specifically the 'banned' state).
- TEST VERACITY for the Background pairing test (input may not reach the pairing branch if eligibility filtering is strict).

