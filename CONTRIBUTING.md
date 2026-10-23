# Contributing

This repo is a written-up homelab, not a product — but if you want to improve
it, the same standard that keeps the fleet honest applies to the docs and
scripts here. Short version: prove every claim, commit deliberately, and don't
let a model tell you a change works without seeing it run.

## Report, don't guess

- Bugs and typos: open an issue with the exact command/output. "It doesn't
  work" with no reproduction is not actionable.
- Hardware-specific numbers (VRAM, throughput, tool-call results) should name
  the engine (Ollama or llama.cpp), its version and the model they were measured
  on. Results measured on one version do not transfer to another — the
  tool-calling probe is re-run on every update for exactly this reason.

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
- Creating the PR via `gh` from PowerShell? Write the body to a file and pass
  `--body-file` — inline `--body "..."` mangles backticks (PowerShell eats
  them as escape characters), then re-read the rendered body with
  `gh pr view <n> --json body --jq .body` before asking for review.
- Model-written changes carry extra proof obligations (below).

## Merging and auto-merge (set up 2026-10-13)

`main` only moves through a pull request whose CI (`.github/workflows/checks.yml`) is green. The owner, the only
account with write access (admin; checked 2026-10-13), merges or sets **auto-merge**, which merges the PR by itself
once the required checks pass. An agent sets auto-merge only when the owner asks for it on that PR.

**Why outsiders can't use this to change the project.** On a public repository anyone can open a pull request from
a fork, but merging, and turning auto-merge on, takes write access, which only the owner has. A fork's PR runs the
workflow with a read-only token and no secrets: the workflow uses `pull_request`, never `pull_request_target`, and
declares `permissions: contents: read`. The settings below make that hold by configuration, not by habit.

**Repository settings (owner, in GitHub's web UI).** These names are from GitHub's UI as of 2026; they were not
re-checked against GitHub's docs when this was written, because the session couldn't reach them. Use the closest
match if a label has moved.

1. **Settings → General → Pull Requests:**
   - turn on **Allow auto-merge**;
   - optionally turn on **Automatically delete head branches**.
2. **Settings → Rules → Rulesets → New branch ruleset**, named `main`:
   - Enforcement **Active**; target the **default branch**; bypass list **empty**. To get around it in an emergency, set the ruleset to Disabled for the moment and switch it back.
   - **Restrict deletions** and **Block force pushes**. This matches "Don't force-push `main`" below.
   - **Require a pull request before merging**, with **0** required approvals. A single maintainer can't approve their own PRs, and a PR an agent opens is opened under the owner's account. CI and the owner's choice to merge are the gate.
   - **Require status checks to pass**, adding both checks by their exact names: `syntax (ps1, sh, python, manifest)` and `guards (Windows, pwsh 7)`. Without a required check, auto-merge has nothing to wait for. If a job in `checks.yml` is renamed, update the ruleset in the same PR.
3. **Settings → Actions → General:**
   - **Fork pull request workflows from outside collaborators:** require approval for all outside collaborators, so a stranger's PR runs nothing until the owner looks at it.
   - **Workflow permissions:** read repository contents only, and leave **Allow GitHub Actions to create and approve pull requests** off.

**Check it worked:**
- Open a PR. Its merge box should list both checks as required, and should offer **Enable auto-merge** while they run.
- A direct `git push origin main` should be rejected.

## Verifying changes

Run the relevant checks before you open a PR, and paste the output into the
PR's "Verification" section rather than asserting success:

- Profiles: `.\tests\test-profiles.ps1`. Expect 0 FAIL. A WARN about node3
  install intent is a documented false positive. A SKIP means a host did not
  answer. Server-reachable WARNs are expected only for `dev-workflow-server`.
  The last recorded full run is in [docs/start-here.md](docs/start-here.md).
- Tool-calling: `.\tests\test-toolcalls.ps1` before trusting any model in a
  seat that reads/edits/runs. `PASS` is one row — the whole probe exits 1 if
  anything fails, and that is expected.
- Guards: `.\tests\run-guards.ps1` runs every regression guard. CI runs the
  same set on Windows for each pull request.
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