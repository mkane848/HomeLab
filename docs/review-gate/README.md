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
runs — turned out to be the hard part, and as of the last run here, no local
model has earned the reviewer seat outright. See
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
- **[raw/](raw/)** — the actual per-run transcripts, comparisons, and
  remeasure inputs/outputs that back the claims above. Supporting evidence,
  not required reading — start with `lmstudio-vscode.md` and dip into a raw
  run file only if you want to check a specific claim against the source.
