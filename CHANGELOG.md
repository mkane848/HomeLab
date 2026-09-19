# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Add the task-veracity benchmark harness (`tests/test-tasks.ps1`) and task
  manifest, seeded with the background-pairing task and its first graded runs
  (qwen3:14b, qwen3:8b x2, devstral:24b — all FAIL on the six mechanical gates).
- Add `CONTRIBUTING.md` and a GitHub pull-request template codifying the repo's
  review-gate verification standard and changelog convention.
- Plan the fleet decision on the review-gate results: third 16 GB node vs.
  partial-offload R1 on node3 vs. `glm4:9b` (see `docs/roadmap.md`).

## [0.1.0] - 2026-09-19

Initial versioned snapshot of the repository. Everything merged as of this
date; no release tags have been cut yet.

### Added

- Hybrid Ubuntu-server / Windows-desktop local-LLM fleet documentation, as a
  public home-lab write-up: hardware notes, per-model VRAM/tool-calling
  benchmarks, and a live BIOS-recovery log.
- Model catalog (`models/catalog.tsv` as single source of truth +
  `models/catalog.sh` bash library), per-host Ollama provider config split one
  per host in `opencode/global/opencode.jsonc`, and server/desktop install and
  sync scripts.
- Per-machine tier profiles and model intent (`profiles/dev-*.sh`), an
  interactive picker, and a startup pipeline that bakes a per-model `num_ctx`
  into managed tags.
- The review-gate research thread: auditor and reviewer role prompts,
  deterministic seam-checker robot, round-1 and round-2 case studies
  (including the PR #82 merge-review findings), the round-2 re-measure and its
  corrections, and the round-3 two-arm experiment (ledger clause vs. control;
  18 raw runs committed with a full manifest).
- Robot negative-control protocol and fixtures proving `seam-checker.ps1`
  discriminates: baseline reproduces RED-MARK, the covered fixture goes
  FIRST-RUN-SAFE, the reflowed fixture stays RED-MARK.
- Tool-calling probe `tests/test-toolcalls.ps1` and the re-measured results on
  Ollama 0.34.1 (5 of 13 models pass).
- A `-Reliability` write-discipline gate in the profile test harness.

### Changed

- Repo placed under git (2026-09-17) and switched to feature-branch pulls.
- README rewritten for public sharing; repo moved under an MIT license with
  docs reorganized.
- VS Code surfaced as a first-class interface alongside OpenCode, with an
  LM Studio / BYOK workflow documented.
- `/plan` prompt shortened; the orphaned planner agent removed.
- Desktop Ollama version pinned via a new pin script, then both desktop and
  server re-pinned to Ollama 0.34.1 after the auto-update (see Fixed).
- `dev-wife.sh` renamed to `dev-node3.sh`; stale wording generalized.
- Server profiles parked; the profile picker made dynamic.

### Fixed

- `/plan` issued a prompt too long for the 16k seat; shortened so it works.
- Round-2 comparison corrected: draw 2 was CAUTION with both deciding seams
  flagged (previously mis-recorded).
- Two tool-call count references missed by the first 0.34.1 re-baseline.
- `OLLAMA_CONTEXT_LENGTH` behaviour on Windows corrected in docs; the
  per-model bake approach remains.

[unreleased]: https://github.com/mkane848/HomeLab/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mkane848/HomeLab/releases/tag/v0.1.0