# Contributing

This repo is a written-up homelab, not a product — but if you want to improve
it, the same standard that keeps the fleet honest applies to the docs and
scripts here. Short version: prove every claim, commit deliberately, and don't
let a model tell you a change works without seeing it run.

## Report, don't guess

- Bugs and typos: open an issue with the exact command/output. "It doesn't
  work" with no reproduction is not actionable.
- Hardware-specific numbers (VRAM, throughput, tool-call results) should name
  the Ollama version and the model they were measured on. Results measured on
  one version do not transfer to another — the tool-calling probe is
  re-run on every update for exactly this reason.

## Changelog

The changelog follows [Keep a Changelog 1.0.0](https://keepachangelog.com/en/1.0.0/)
and the repo adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

- Every notable change gets an entry under `[Unreleased]` in `CHANGELOG.md`,
  grouped Added / Changed / Deprecated / Removed / Fixed / Security.
- Don't dump the commit log into the changelog. One curated, human-readable
  line per change; open a PR right after a release to promote `[Unreleased]`
  into a dated version heading.

## Pull requests

PRs are how changes land. A template lives in
`.github/PULL_REQUEST_TEMPLATE.md` and pre-fills automatically.

- **Title convention:** `type: description`, e.g. `docs: fix startup ordering`,
  `tests: add probe for qwen3.5:9b`, `fix: correct VRAM table in hardware.md`.
- Keep PRs small and single-purpose. A docs change and a script change in one
  PR should be because they are actually one change.
- Model-written changes carry extra proof obligations (below).

## Verifying changes

Run the relevant checks before you open a PR, and paste the output into the
PR's "Verification" section rather than asserting success:

- Profiles: `.\tests\test-profiles.ps1` (expect 100 PASS / 0 FAIL / 1 WARN /
   2 SKIP as of 2026-09-20 — the WARN is a documented node3 false positive,
   the SKIP taps are the dead server;
   server-reachable WARNs are green-lit for `dev-workflow-server` only).
- Tool-calling: `.\tests\test-toolcalls.ps1` before trusting any model in a
  seat that reads/edits/runs. `PASS` is one row — the whole probe exits 1 if
  anything fails, and that is expected.
- PowerShell syntax: see AGENTS.md
  `[System.Management.Automation.Language.Parser]::ParseFile(...)`.
- Bash syntax: `bash -n` (Git bash on Windows).

## The review-gate rule on "it passed the tests"

A green suite proves a test **ran**, not that it covers what its name claims.
This is the repo's own finding (`docs/review-gate/testing.md`) — a test that
passes a solo chooser while claiming to cover a pairing branch is green on
broken code too. For model-written PRs specifically:

1. Re-run the gates (lint, typecheck, unit suite) on the actual checkout.
2. Audit every new test against the branch it claims to cover; add the
   missing-branch case and confirm it fails on the old code.
3. Run the integration suite against real data (seeded DB / live fixtures) —
   a suite that only runs in CI proves nothing locally.
4. Human merge review, then merge.

A PR that lands "because the suite was green" without this pass is how the
Background-pairing bug rode into KaneEnabler. Don't repeat it here.

## Git hygiene

- Keep `git status` clean before handing a script to an agent to edit, and
  `git diff` + syntax-check after.
- Don't force-push `main`. Revert-and-re-PR over rewriting history.
- Raw experiment outputs (review-gate runs, probe results) are committed
  verbatim, ungraded — grading happens separately, against the key, by someone
  who did not generate the runs.

## Scope

- `skills/` and `claude/imports/` are vendored third-party packages with their
  own licenses — see `claude/README.md` for provenance. Don't rewrite them to
  fix the homelab scripts; patch the scripts or vendor a newer copy.
- `.env`, `desktop/docker/.env` and `*.env` are git-ignored and never
  committed. Secrets live in `~/.config/opencode/.secrets/`, outside the repo.

## License

By contributing you agree that your changes are licensed under the repo's MIT
license (see `LICENSE`). Vendored third-party packages keep their own licenses.