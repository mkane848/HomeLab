# Owner setup: merging and auto-merge

Repository settings only the owner can change. Contributors: see [CONTRIBUTING.md](../CONTRIBUTING.md).

`main` only moves through a pull request whose CI (`.github/workflows/checks.yml`) is green. The owner (the only account with write access, checked 2026-10-13) merges, or sets **auto-merge**. An agent sets auto-merge only when the owner asks for it on that PR.

A fork's PR runs with a read-only token and no secrets: the workflow uses `pull_request`, never `pull_request_target`, and declares `permissions: contents: read`.

| Where (GitHub web UI; names as of 2026, not re-checked against GitHub's docs) | Setting |
|---|---|
| Settings → General → Pull Requests | **Allow auto-merge** on; optionally **Automatically delete head branches** |
| Settings → Rules → Rulesets → New branch ruleset `main` | Enforcement **Active**, default branch, bypass list **empty** (in an emergency set it Disabled, then back) |
| same ruleset | **Restrict deletions**, **Block force pushes** |
| same ruleset | **Require a pull request**, **0** approvals (a lone maintainer cannot approve their own PRs; CI and the owner's merge are the gate) |
| same ruleset | **Require status checks**: `syntax (ps1, sh, python, manifest)` and `guards (Windows, pwsh 7)`. Rename a job in `checks.yml` and the ruleset in the same PR |
| Settings → Actions → General | Fork PR workflows: require approval for all outside collaborators. Workflow permissions: read contents only; leave "create and approve pull requests" off |

**Check it worked:** a new PR lists both checks as required and offers **Enable auto-merge** while they run; a direct `git push origin main` is rejected.
