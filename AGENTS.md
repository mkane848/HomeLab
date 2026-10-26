# AGENTS.md

Repo for provisioning a hybrid Ubuntu server / Windows desktop LLM setup (Ollama + OpenCode). Not an app codebase — most changes are bash/PowerShell scripts, JSONC config templates, and docs.

**End goal (north star): turn every machine in the house into interchangeable compute for one Claude Code / ChatGPT Codex-like development experience** — prompt in plain human language, and the fleet (personal PC today, the Ubuntu server when it's fixed, then node3's 3080 FE) flexibly supplies the models behind that experience. The mechanics documented in this repo exist so you don't have to think about which model runs where: the profile selects it, OpenCode pins it, tests enforce it. See `docs/roadmap.md`. Progress gates by hardware, not by preference.

**This repo is under git as of 2026-09-17.** It was not before, and that cost real work: an agent asked to edit `desktop/scripts/sync-skills.ps1` left three duplicated blocks and three unbalanced braces in it, and the only recovery was reading the damage by hand. There was no `git diff` and no `git checkout --`.

- **Commit before letting an agent edit anything.** `git status` should be clean when you start.
- After an agent edits a script, `git diff` it and syntax-check before running it. PowerShell
  (wrapped so only errors print, not the whole AST — the bare `ParseFile(...)` call dumps a
  `ScriptBlockAst` to the pipeline):
  `$errs = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile(<path>,[ref]$null,[ref]$errs); if ($errs.Count) { $errs } else { "OK" }`.
  PowerShell 7 (`pwsh`) is the only supported version since 2026-10-12 (owner: one version to
  test and support; guards are no longer run on Windows PowerShell 5.1). `[ref]$null` as a
  discard out-param is legal there. Shell: `bash -n`. Use forward slashes for the path on Linux/remote sessions —
  a Windows-style backslash path resolves to a literal (wrong) filename and `ParseFile` reports a
  misleading `FileReadError` that looks like a syntax failure but isn't.
- **Remote/Claude-Code-web sessions get `pwsh` via `.claude/hooks/session-start.sh`** (a
  `SessionStart` hook, gated on `$CLAUDE_CODE_REMOTE`) — added 2026-09-21 after a manifest bug
  (`kane-02`'s `setup` step) shipped because the sandbox had no PowerShell to actually run the
  syntax-check above, only a bracket-balance guess. Installs the official Linux x64/arm64 binary
  tarball to `/opt/microsoft/powershell/7`, symlinked to `/usr/local/bin/pwsh`; idempotent
  (no-ops if `pwsh` is already on `PATH`). Syntax-checking a `.ps1` is still necessary, not
  sufficient — it catches malformed PowerShell, not wrong data (`kane-02`'s bug was a valid
  script pointed at a `setup` step that doesn't apply at that historical commit). The real fix
  for that class of mistake is verifying against a genuinely fresh `git worktree add`, never a
  reused branch checkout — see the `kane-02` postmortem in `CHANGELOG.md`.
- `.env`, `desktop/docker/.env` and anything `*.env` are git-ignored; only `.env.example` templates are tracked. Secrets live in `~/.config/opencode/.secrets/`, outside the repo entirely.
- Remote is `origin` (`github.com/mkane848/HomeLab`). Don't force-push `main`; revert-and-re-PR instead.

## Where things are

The long reference that used to live here moved to `docs/reference/` on 2026-10-26, verbatim and dated. Read the row you need.

| Need | Read |
|---|---|
| Machines, roles, per-host history (`server`, `desktop`, `node3`) | [`docs/reference/machines.md`](docs/reference/machines.md) (table generated from `machines.tsv`) |
| The main seat, `/plan` → execute, Plan/Build toggle, live profiles | [`docs/reference/workflow.md`](docs/reference/workflow.md) |
| Model catalog, installing models, profiles, OpenCode config, sync pipeline, desktop Docker | [`docs/reference/config.md`](docs/reference/config.md) |
| Which guard to run after touching X; CI; every `tests/` tool in detail | [`docs/reference/guards.md`](docs/reference/guards.md) (table generated from each guard's `# protects:` / `# run-after:` header) |
| Symptom → cause → fix (tool-calling, context, VRAM, Vulkan, env vars, GPU loss) | [`docs/reference/gotchas.md`](docs/reference/gotchas.md) |
| History, incidents, postmortems | `CHANGELOG.md`, `docs/roadmap.md` |

**Keep the tables true:** `python3 tests/make-reference.py` rewrites them; CI runs it with `--check`. A new `tests/test-*.ps1` needs the two header comments or CI fails.

## Rules

- Model-written PRs: a **green suite is necessary, not sufficient**. Audit every
  new test against the branch it claims to cover (a passing test can be green on
  broken code) and run integration on a seeded DB before merge. Method + the
  PR #82 Background-bug worked example in `docs/review-gate/testing.md`.
- PRs: title `type: description` (`docs: …`, `tests: …`, `fix: …`), fill the
  Verification section with commands run (not assertions), add a `[Unreleased]`
  `CHANGELOG.md` entry. Template: `.github/PULL_REQUEST_TEMPLATE.md`; rules: `CONTRIBUTING.md`.
- **Cite external sources in docs.** Any claim grounded in a paper, leaderboard,
  benchmark, blog, or tool docs gets an inline link on first mention with
  descriptive link text — never a bare URL, never a guessed URL (`webfetch` any
  URL before you cite it, and swap to the fetched link if the two differ). New
  sources are added to `docs/references.md` (short name, title, author/lab,
  date, URL) in the same change that first cites them. **Re-verify stale-able
  claims when editing a doc that carries them** — leaderboard ranks, "best
  model", and version facts move weekly; if you cannot re-verify, keep the
  claim but date-stamp it. Convention + catalog: `docs/references.md`.
