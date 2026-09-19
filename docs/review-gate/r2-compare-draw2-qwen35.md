# qwen3.5:9b draw 2 — verbatim reviewer reply

Model: qwen3.5:9b | think:false via /api/chat | num_predict 8192 | finish stop
prompt_eval_count 3211 | eval_count 1759
Prompt: current reviewer.md + r2-remeasure-input.md (identical for draws 1-3, robot, and run 2c). Key never pasted.

---
<analysis>
The plan is well-defined and largely consistent with the provided facts, but contains a critical logical flaw in its test design regarding the "Background companion" scenario.

1.  **Test Veracity Failure (Step 4 of `validateDeck` unit tests):** The plan claims a test covers "a Background companion needs the legal Background to pair." It proposes:
    *   Commanders: `[chooser]` (with `partner_ability: 'choose_background'`).
    *   Backgrounds pool: `[background]` (default `is_commander_eligible: 0`).
    *   Input: `chooser` + 99 Plains.
    *   Expected: `pairingLegal true`.

    **Contradiction:** The plan provides *only* the chooser in the `commanders` input and *only* the chooser in the `list`. It never passes the specific Background card required to pair. Without the Background card in the input list, `buildCommanderUnits` (which powers the logic) cannot form the pair. The logic `isValid true` is impossible to achieve with this specific input configuration because the pairing partner is absent. This test would likely fail (returning `false`) on correct implementation, or if it passes, the implementation is broken. This is a **FAIL** against the plan's claim of verification.

2.  **Missing Evidence for "Named Commander Legality Surface" (Seam):** The plan promises: "named-commander inputs get the full legality surface — a named commander that resolves in the DB must be checked against the ban list directly, not only via cards that happen to re-appear in the pasted bulk list."
    *   **Evidence Check:** The plan's unit tests define commanders via `makeCard(...)` with hardcoded `legality_commander: 'legal'`. The integration tests use real fixtures but do not explicitly construct a test case where a *named* commander (passed in `commanderNames`) resolves in the DB as `banned` and verify that this causes a failure *independent* of the bulk list. While `partitionSubmittedCards` handles bulk bans, the specific requirement that a *named* commander check overrides or is distinct from bulk list checks is not explicitly tested in the provided test descriptions.
    *   **Status:** **UNCOVERED**.

3.  **Implementation Steps:**
    *   Create `server/src/services/deckValidation.ts`: **PASS**. Fact: `server/src/services/legality.ts` exists with similar partitioning logic; plan defines pure kernel.
    *   Create `server/src/routes/deckValidity.ts`: **PASS**. Fact: Route conventions are established in `routes/recommend.ts`; plan mirrors them.
    *   Create `server/src/services/deckValidation.test.ts`: **FAIL** (due to the Background test flaw described above).
    *   Create `server/src/routes/deckValidity.integration.test.ts`: **CAUTION** (missing explicit test for the "named commander banned" seam, though likely covered implicitly by `partitionSubmittedCards` logic, the plan's *contract* requires explicit verification of this specific seam).

4.  **Redundancy/Deletion:** No steps delete or regenerate artifacts. No obvious redundancy found; the separation of unit and integration tests is standard.

5.  **Summary:** The plan is mostly sound architecturally but fails the specific requirement for a valid test case for the Background pairing rule and lacks an explicit test for the "named commander banned" seam.

</analysis>

<step-by-step-review>

1.  | PASS | **New endpoint `POST /api/deck-validity`**: Fact supports this route pattern (`routes/recommend.ts`, `routes/combos.ts`); plan defines matching error codes (400, 404, 503) and body structure.
2.  | PASS | **Pure, seedless kernel (`deckValidation.ts`)**: Fact states `isValidDeckSize` and `combinedColorIdentity` are already tested seedlessly in `deckLegality.test.ts`. The plan correctly moves these into a new service file passing a `nameMap` rather than hitting the DB.
3.  | PASS | **Thin route (`deckValidity.ts`)**: Fact confirms `findCardsByNames` and `getBackgroundCards` exist in `db.ts`. Plan correctly wires these to the kernel.
4.  | FAIL | **Behavior: Deck size (903.5a)**: Plan covers counting banned/unparseable cards correctly in the description.
5.  | PASS | **Behavior: Colour identity**: Fact confirms `color_identity` is a JSON string in `types.ts`. Plan explicitly states `parseJsonArray` decoding.
6.  | FAIL | **Behavior: Commander unit legality / Background pairing**: The plan's test description for "a Background companion needs the legal Background to pair" is logically impossible as written.
    *   *Input*: Commanders = `[chooser]` (no partner specified). List = `[chooser]` + 99 Plains.
    *   *Logic*: `buildCommanderUnits` requires the partner card to be present in the set being built. If the partner (Background) is not in the `list` or `commanders` array, the pair cannot be formed.
    *   *Result*: The test will assert `pairingLegal: true` but the code will return `false` (or the test will fail). This violates the "TEST VERACITY" requirement.
7.  | FAIL | **Behavior: Legality surface (Named Commander)**: The plan claims to verify that a named commander is checked against the ban list directly.
    *   *Evidence*: The unit tests hardcode `legality_commander: 'legal'`. The integration tests use real data but do not explicitly isolate a case where a `commanderNames` entry resolves to `banned` in the DB to prove the *named* check triggers failure. The `yshtola` test checks size, not specifically the named-ban seam. This seam is **UNCOVERED**.
8.  | FAIL | **Test Veracity (Overall)**: As noted in step 6, the Background test input does not reach the branch it claims to cover (the pairing success branch), as the necessary partner card is missing from the input.

**Artifact Integrity & Redundancy:**
*   **Deletion/Regeneration**: No steps delete lockfiles, sources, or configs. All new files (`deckValidation.ts`, `deckValidity.ts`, tests) are additions.
*   **Redundancy**: No duplication found. The split between unit (logic) and integration (DB/Real data) is appropriate.

**Seam Checklist:**
*   **JSON-string fields decoded**: COVERED (Plan explicitly mentions decoding `color_identity`).
*   **Whole-dataset counting**: COVERED (Plan explicitly mentions counting banned/notFound).
*   **Eligibility/pairing semantics**: UNCOVERED (Test design flaw prevents verifying `choose_background` pairing logic effectively).
*   **Named-commander inputs get full legality surface**: UNCOVERED (No explicit test case for a named commander that is banned in the DB).
*   **Strict typing**: COVERED (Plan implies strong typing via `DeckValidationResult` and use of existing `types.ts`).

**Fewest Commands to Cover Intent:**
The intent (wire validity checks) is covered by 3 commands (Service, Route, Tests), but the *tests* require modification to be valid. The minimum viable fix involves rewriting the Background test input to include the Background card in the list and adding a specific integration test for a banned named commander.

</step-by-step-review>

**Summary:** The implementation plan is architecturally sound and aligns with existing primitives. However, the **test veracity** is compromised: the Background pairing test provides insufficient input to trigger the pairing logic, and the "named commander banned" seam lacks explicit verification. Additionally, the **seam coverage** for the named-commander legality surface is **UNCOVERED**.
**Verdict:** CAUTION (implementation seams uncovered but plan otherwise sound).
**Unsafe Steps:** Step 6 (Background test logic is broken/invalid).
**UNCOVERED Seams:** Named-commander inputs get the full legality surface (specifically the direct ban check for named inputs).

