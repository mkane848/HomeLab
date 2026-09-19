# The review-gate experiment

**Question:** can a model running on this fleet's own hardware act as a
reliable second-opinion reviewer on a coding agent's plan or PR — catching
what it's specifically told to check for, not just rubber-stamping a green
test suite?

**Short answer so far:** partially. A capable model with real tool access can
self-discover most of a codebase's actual defects when it goes and reads the
code (the "auditor" role, below). Getting a *second*, cheaper local model to
reliably catch specific seams as a reviewer — without hand-holding, without
fabricating evidence, without flipping its verdict between otherwise-identical
runs — turned out to be the hard part, and no local model has earned the
reviewer seat. That now rests on 18 parameter-recorded runs across three model
families (round 3, below), which also killed the leading explanation: forcing
the reviewer to transcribe every test's arguments before judging raised its
output length exactly as intended and changed almost nothing. One run
transcribed the decisive argument correctly and passed the broken plan anyway.
The bottleneck is verification reasoning, not prompt shape. See
[docs/lmstudio-vscode.md](../lmstudio-vscode.md) for the full write-up and the
[roadmap](../roadmap.md) for where this is headed next.

## How it's organized

- **[lmstudio-vscode.md](../lmstudio-vscode.md)** — the narrative: how the
  method works (auditor → reviewer → arbiter), the VS Code / LM Studio BYOK
  setup, and the two full case studies (a real dependency audit, then the
  KaneEnabler deck-validity PR).
- **[testing.md](testing.md)** — the test-veracity rule this method exists to
  enforce: a green suite proves a test ran, not that it covers what it claims
  to.
- **[auditor.md](auditor.md)** / **[reviewer.md](reviewer.md)** — the two
  agent roles: auditor reads the real repo and writes a plan with cited
  evidence; reviewer gets the plan (and, in later runs, the evidence) and has
  to find the seams without being told where they are.
- **[seam-checker.ps1](seam-checker.ps1)** — a deterministic, no-model
  "robot" reviewer: it just checks whether the plan's claimed test coverage
  is actually staged in the input, no LLM judgment involved. Useful as a
  floor to compare LLM reviewers against.
- **Round 3** — the controlled A/B that closed the seat question:
  **[r3-protocol.md](r3-protocol.md)** (design and the rules the runner
  enforces), **[r3-ledger-clause.md](r3-ledger-clause.md)** (the treatment),
  **[r3-runner.ps1](r3-runner.ps1)** (the harness), and
  **[raw/r3-results.md](raw/r3-results.md)** (the grade, the negative result,
  and two instrument defects it exposed). Raw runs in `raw/r3/`.
- **[raw/](raw/)** — the actual per-run transcripts, comparisons, and
  remeasure inputs/outputs that back the claims above. Supporting evidence,
  not required reading — start with `lmstudio-vscode.md` and dip into a raw
  run file only if you want to check a specific claim against the source.
