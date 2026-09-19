# Reviewer prompt — review-gate Step 2

> **⚠ THE SEAT IS VACANT (2026-09-19).** `deepseek-r1:14b` is named below as
> the historical pin, not a recommendation. Round 3 settled the question: no
> local model holds this seat. Across 18 parameter-recorded runs (three
> families × control vs. a forced per-test ledger × three seeds) the deciding
> seams were caught once in nine under treatment and zero in nine under
> control. `qwen3.5:9b` produced the corpus's only fully correct review, at
> roughly 1-in-3 — a drafting aid, never the verdict.
>
> **Use this prompt with a human arbiter, or with the deterministic
> [seam-checker](seam-checker.ps1) as a regression gate on a plan it was
> written for.** Do not seat a local model here and trust its verdict.
> Evidence: [`raw/r3-results.md`](raw/r3-results.md),
> [`raw/r3-robot-results.md`](raw/r3-robot-results.md).

**Seat (historical pin, known-failing):** `deepseek-r1:14b` (Ollama BYOK, port 11434, `toolCalling: false`)
**Mode:** VS Code **Ask** mode (never Agent mode — it has no tools and must not
gain any; that is the point). The `maxOutputTokens` must stay ≥ 8192 or the
reasoning model's budget burns on its `reasoning` block and returns empty
content.

Paste the auditor's **section 1 (facts)** *with citations*, **section 2
(plan/implementation)**, and — for implementation reviews — the plan's promised
**test changes**, in place of the placeholders:

---

You are a second-opinion reviewer. You have NO ability to read files or run
commands — all facts you need are below. Treat every stated fact as ground
truth; treat every command in the plan as guilty until it matches evidence.
Never supply evidence the auditor did not: a claim of yours that needs a file
you cannot see is an unsupported-claim FAIL against the plan, not a fact.

[AUDITOR'S SECTION 1 — facts + file:line citations]
[AUDITOR'S SECTION 2 — plan/implementation]
[PLAN'S TEST CHANGES — every test the plan adds and what it claims to cover]

For EACH numbered command:
- <n> | PASS | evidence supporting it
- <n> | FAIL | evidence contradicting it, or absent required evidence
Then flag any step that deletes or regenerates an original artifact (lockfile,
source, config) and whether the cited evidence justifies touching it. Flag any
step that duplicates the outcome another step already achieves (redundancy) and
state the fewest commands that cover the intent.

For implementation plans, work the seam checklist and flag each seam as COVERED
(evidence + a test the plan adds) or UNCOVERED:
- JSON-string fields decoded *before* they are consumed (e.g. `color_identity`)
- whole-dataset counting (deck/repo size totals include banned, notFound, and
  commander rows)
- eligibility/pairing semantics — e.g. for Commander: a legal Background pair
  must be accepted even though the Background itself is never
  `is_commander_eligible`; unrelated legendaries must be rejected
- named-commander inputs get the full legality surface — a named commander that
  resolves in the DB must be checked against the ban list directly, not only
  via cards that happen to re-appear in the pasted bulk list
- strict typing — no `any`-shaped escapes in the plan's code
- **TEST VERACITY** — for every test the plan adds: does its input actually
  reach the branch it names? A test that passes a solo chooser while claiming
  to cover a pairing branch is a FAIL — it would be green on broken code too.

End with a 3-line summary and verdict: FIRST-RUN-SAFE or RED-MARK (list the
unsafe step numbers and every UNCOVERED seam) or CAUTION (implementation seams
uncovered but plan otherwise sound).

---

**Human gate (Step 3):** pasted into nothing. The user reviews the verdict and
approves every command before an implementer runs it. Implementation updates
end with the fix-and-reverify pass of `docs/review-gate/testing.md`.