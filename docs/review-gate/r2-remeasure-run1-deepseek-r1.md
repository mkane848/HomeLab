# Review-gate re-measure run 1 (2026-09-19) — deepseek-r1:14b

Fixed-input re-measure of the reviewer seat. Same material as run 1's PR #82
(`docs/review-gate/r2-remeasure-input.md`), improved prompt as amended in
`docs/review-gate/reviewer.md` (evidence + citations, seam checklist, explicit
test-veracity clause). Prompt never included `r2-remeasure-key.md`.

**Run record:** `deepseek-r1:14b` via Ollama port 11434; prompt 3071 tokens
(prompt-only file: `r2-remeasure-input.md`); `max_tokens` 8192, `stream` false.
`finish_reason: stop` (NOT length — the review is complete, not truncated).
Completion 1145 tokens. Raw reply + full reasoning saved under
`C:\Users\<username>\AppData\Local\Temp\opencode\r2-rem\` (`response.json`,
`content.txt`, `reasoning.txt`).

## Verdict: FAILED re-measure — R1 does not keep the reviewer seat

| Seam | Ground truth | Reviewer's call | Grade |
|---|---|---|---|
| 1 JSON-string `color_identity` decoded before use | covered | COVERED (test asserts decode) | ✓ |
| 2 deck size counts whole pasted deck incl. banned/notFound | covered | COVERED | ✓ |
| 3 strict typing | covered | COVERED | ✓ |
| 4 eligibility/pairing via `is_commander_eligible` + units | covered (solo/Partner) | COVERED — but rubber-stamped; never checked the legal-Background-pair case the checklist names | ~ |
| 5 **Background-pairing eligibility bug** | **uncovered** | "I don't see any ... missed branches" | ✗ |
| 6 **direct `legality_commander` ban-list check** | **uncovered** | never mentioned | ✗ |
| Verdict line | RED-MARK | **FIRST-RUN-SAFE** | ✗ |

## Evidence it had, and still missed

All three inputs it needed were in the pasted material, uncontaminated:

1. **types.ts schema comment** (Section 1): a legendary Background is "never
   itself is_commander_eligible; only ever a commander paired via 'choose a
   Background'".
2. **The checklist seam** (reviewer.md, verbatim): "a legal Background pair
   must be accepted even though the Background itself is never
   `is_commander_eligible`".
3. **The test inventory** (Section 3): the Background test passes
   `commanders: [chooser]` only — the pairing/eligibility path is never
   exercised, so `is_commander_eligible === 1` on the `commanders` array is
   trivially satisfied and the test is green on broken code.

It instead asserted (reasoning.txt): *"Each test is designed to hit specific
branches, and I don't see any redundancy or missed branches."* — a statement
that is false against its own input, made without checking a single argument
list. The exact run-1 failure mode (approve regardless of evidence) survives a
directed checklist; the checklist hint was waved through without confrontation.

(The classic seams 1–4 are still caught — so the floor is real. What's missing
is the willingness to actually *verify*: reasoning confirms it never examined
the test inputs for the commander-legality commands it stamped COVERED. One
minor inaccuracy: it credited "malformed bodies and 404s" to the unit test,
when those live in the integration suite.)

## Contamination check: clean

No key material pasted. Reviewer's claims restate only Section 1–3 facts (plus
the one misattribution above); nothing quotes the key. No `r2-remeasure-key`
text appears in the reply. Run is valid.

## Decision + next move

- **R1 is off the reviewer seat.** Even a directed seam checklist produces a
  false-positive FIRST-RUN-SAFE on code carrying two real bugs. Salvage is a
  different failure than hope; we already have one full A/B cycle of evidence.
- **Re-measure candidates on the same fixed input** (same prompt, same
  material; the reviewer seat needs NO tools, so the qwen3 tool-call probe
  does not gate this seat — Ask mode only, `toolCalling: false` as designed):
  - `qwen3:14b` — same family as the main seat, would be swapping the
    verification hole for the seat's known "repeated write calls" trait
    (irrelevant here: no tools).
  - `qwen3.5:9b` — installed 2026-09-18, newer generation; strongest
    reasoning-per-gram candidate; also likely cheap enough to back-book.
  - `devstral:24b` — passes tool probes; edge VRAM fit solo-seat; long
    inference per output token.
  - `qwen2.5-coder:14b` — registered deliberately as no-tools; good text work,
    but empty-`tool_calls` is not a disqualifier for a no-tools seat.
- Each candidate run grades on the same 6-seam key; a response that flags
  seams 5–6 AND calls the verdict RED-MARK takes the seat. Publish the winning
  run as the new record ("1/4 → 4/6" with 5–6 explicitly), then archive the
  losing R1 runs.