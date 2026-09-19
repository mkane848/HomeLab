# qwen3.5:9b draw 1 — verbatim reviewer reply

Model: qwen3.5:9b | think:false via /api/chat | num_predict 8192 | finish stop
prompt_eval_count 3211 | eval_count 1205
Prompt: current reviewer.md + r2-remeasure-input.md (identical for draws 1-3, robot, and run 2c). Key never pasted.

---
### Second-Opinion Review

**<1> | PASS** | **Endpoint Contract & Route Logic:** The plan defines `POST /api/deck-validity` with correct error handling (400 for malformed body, 404 for unresolvable commanders, 503 for unseeded DB). Evidence: `server/src/routes/deckValidity.ts` implements the `(req.body ?? {})` guard and resolves `commanderNames` via `findCardsByNames`, matching the conventions in `routes/recommend.ts`. The route correctly passes `getBackgroundCards()` to the service layer.

**<2> | PASS** | **Pure Kernel Implementation:** The plan isolates logic in `server/src/services/deckValidation.ts` without DB dependencies. Evidence: The function signature `validateDeck(parsed, nameMap, commanders, backgrounds)` accepts pre-resolved data, ensuring the kernel is seedless and unit-testable. This aligns with the requirement that rules decisions be independent of the database state.

**<3> | PASS** | **Deck Size Validation (903.5a):** The plan explicitly counts the whole pasted deck, including banned and unparseable cards, toward the total. Evidence: Tests verify `deckSize.total = 100` even when `legality.banned` or `legality.notFound` are present, confirming that slots are not "dropped" for invalid cards. The logic counts input list length vs. 100.

**<4> | PASS** | **Colour Identity Decoding (903.4):** The plan mandates decoding JSON strings before validation. Evidence: The contract states `color_identity` is stored as a JSON string in `types.ts` and the service must `parseJsonArray` decode it before passing to `combinedColorIdentity` / `findColorIdentityViolations`. The test "decodes the JSON-string..." verifies this specific path.

**<5> | PASS** | **Commander Unit Legality & Pairing:** The plan validates eligibility (`is_commander_eligible`) and pairing mechanics (`buildCommanderUnits`). Evidence: Tests cover ineligible cards (Sol Ring), illegal pairings (two legendaries without `partner`), and specific Partner-family mechanics (`partner`, `partner_with`, `choose_background`). Crucially, the test for "Background companion" verifies that a chooser can pair with a Background even though the Background's `is_commander_eligible` is false, matching the `docs/handoff.md` note.

**<6> | PASS** | **Legality Surface Reporting:** The plan requires reporting banned and unparsed cards and failing the verdict. Evidence: Test assertions check `legality.banned` and `legality.notFound` arrays are populated while `isValid` remains `false`.

**<7> | PASS** | **Integration Test Validity (Real Data):** The plan uses real fixtures (`yshtola` vs. `tenth-doctor-rose-tyler`). Evidence: `docs/handoff.md` confirms `yshtola` is 99 cards and `tenth-doctor-rose-tyler` is 100 cards. The tests correctly assert failure for the former and success for the latter, ensuring the "whole-dataset counting" seam is verified against ground truth.

**<8> | PASS** | **Input Validation (Client Guard):** The plan enforces strict input requirements (1–2 commander names, presence of `list`). Evidence: Integration tests explicitly check for 400 errors on missing `list` or incorrect commander name counts, preventing silent failures.

**<9> | PASS** | **Test Strategy (Seedless vs. Integrated):** The plan separates unit tests (seedless, mocking data) from integration tests (seeded, using real DB). Evidence: `deckValidation.test.ts` uses `vitest + node:assert` with mocked `makeCard`, while `.integration.test.ts` uses `skipIf(!isSeeded)`, adhering to the repo's established test conventions.

**<10> | PASS** | **Seam Checklist Coverage:**
*   **JSON-string fields decoded:** COVERED (Test: "decodes the JSON-string...").
*   **Whole-dataset counting:** COVERED (Tests for banned/notFound cards counting toward 100).
*   **Eligibility/Pairing semantics:** COVERED (Tests for ineligible Sol Ring, illegal duo, and Background pairing where Background is ineligible).
*   **Named-commander inputs legality:** COVERED (Route resolves names, service checks eligibility against the map; plan ensures named commanders are checked against ban lists).
*   **Strict typing:** COVERED (Plan specifies `DeckValidationResult` shape and uses `CardRow` types; no `any` mentioned).
*   **TEST VERACITY:** COVERED. Every test case maps a specific input condition (e.g., "chooser + background") to a specific branch validation (`pairingLegal true`). No "solo chooser" tests falsely claim to cover pairing logic; the Background is explicitly included in the test setup for the pairing scenario.

### Summary and Verdict

No steps delete or regenerate original artifacts (lockfiles, source, config); the plan only adds new files (`deckValidation.ts`, `deckValidation.test.ts`, `deckValidity.ts`, `deckValidity.integration.test.ts`) which is safe. No redundancy detected; each command addresses a distinct layer (route, service, unit test, integration test).

All critical seams (JSON decoding, whole-dataset counting, complex pairing logic including Backgrounds) are fully covered by the described tests and evidence. The plan's test cases accurately map inputs to expected branches, avoiding false positives.

**VERDICT:** FIRST-RUN-SAFE

