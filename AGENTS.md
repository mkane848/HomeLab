# AGENTS.md

Repo for provisioning a hybrid Ubuntu server / Windows PCs LLM setup (llama.cpp, with Ollama being replaced; OpenCode). Not an app codebase — most changes are bash/PowerShell scripts, JSONC config templates, and docs.

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
| A testing window on the server and node3 with no one there (`run-window.ps1`, `llamacpp-window.sh`) | [`docs/unattended-window.md`](docs/unattended-window.md) |
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

## Norms and known mistakes

Each of these was a real, repeated mistake (most from 2026-10-30 to 11-02). Follow them without being asked.

**Done means verified.**
- A fix is done when **CI is green on the PR's current head**, not when it passes locally. Wait for the run
  (`gh run watch <id> --exit-status`) before saying "fixed". PR #188's first "fix" passed locally and failed CI twice.
- Reproduce CI's environment, not yours. The runners set `core.autocrlf=true`: run a guard under
  `GIT_CONFIG_GLOBAL=<file with autocrlf = true>`, and with the guard file itself converted to CRLF.
- **The owner merges whenever a PR is green.** Before pushing more commits to a PR, check
  `gh pr view <n> --json state`. If it is merged, cherry-pick onto a new branch from `main` and open a new PR: #190
  was merged one commit early and the second fix needed #191.

**Numbers.**
- Compare arms by task, paired, with an exact sign test; a test on pooled runs overstates the evidence (`docs/methodology.md` -> "How to
  compare two arms"). 2026-11-07's audit found that in recent write-ups, though every count was right.
- Before a headline goes in a report, recompute it from the raw results, and ask what the known-good answer scores on the same measure.

**A guard that cannot fail protects nothing.**
- Mutation-check every new check: disable the rule (or run the guard against `main`'s version of the script) and
  confirm the guard goes red, then restore and confirm the file is byte-identical (`cmp`). Twice a new guard stayed
  green with its rule removed. In one, the check matched text that appears either way. In the other, a later step's
  exit 1 hid the missing refusal.
- Assert **where** a script stopped (its own message, and no later step's), not just its exit code.
- A throwaway git repo in a guard pins `git config core.autocrlf false`, and here-string fixtures are normalised to LF.
- Test the false-positive side as hard as the true one. The integrity gate blocked a perfect attempt for example
  branch names (`` `fix/digest-retry` ``) and for `` `.github/` `` (a `TrimStart('.')` ate the dot). Good work blocked
  breaks the owner's bar as surely as bad work kept.

**Editing files.**
- Python edits: `open(..., newline='')` to keep line endings; use raw strings (`r'''...'''`) for anything containing
  Windows paths or PowerShell (`"\run-planner"` became a carriage return); assert the old text occurs exactly once
  before replacing it.
- Let tools write their own output files when bytes matter (`git diff --binary --output=<file>`). Native output
  through PowerShell loses CRLF and binary content.
- Commit with explicit paths, never `git commit -a`.

**PowerShell pitfalls** (pwsh 7):
- `"$LASTEXITCODE: x"` is a parse error: use `"${LASTEXITCODE}: x"`.
- A comma after `-replace` joins its operands: write `(($x) -replace 'a', 'b'), $next`.
- Variable names are case-insensitive: `$m4Tasks` overwrote the parameter `$M4Tasks` (PR #174).
- A literal `'""'` passed to a native exe arrives as two quote characters: `ssh-keygen -N '""'` set a passphrase.

**node3 (Windows) over ssh.**
- Its ssh shell is **cmd**. `;` does not separate commands (it reached a script as `-Apply;`), and nested quoting
  breaks. Copy a script with `scp` and run it with `pwsh -NoProfile -File <script>`. A script piped into
  `pwsh -Command -` can fail without a word.
- Use `ssh -o BatchMode=yes` (also as `GIT_SSH_COMMAND`) for anything that could prompt; give the command
  `< /dev/null`.
- A one-shot scheduled task (S4U) has none of the user's session environment. Set every variable the run needs:
  `LLAMACPP_SERVER_BASE_URL` (OpenCode's provider reads its `baseURL` from it). Without it all of `real-01`'s attempts
  were "infrastructure". Launch the **running** pwsh (`(Get-Process -Id $PID).Path`, as `run-window.ps1 -Detach`
  does): a Store update can stage a newer build that a task cannot start yet (`0x80070005`).
- Remove a one-shot task, and any worktree a session made, when its run is over; seven had piled up by 2026-11-02.
- Git there is described in `node3/README.md` → "Git on node3".

**Long runs and cleanup.**
- Start long work in the background and wait for its notification; do not poll with `sleep`. Check the first
  attempt's result early: a run that only reaches "infrastructure" is wasted hours.
- Before deleting anything: dry run, then move it aside, verify (hash-compare against the copy that stays), then
  delete.
- Searches skip `tests/.worktrees/`: it holds the sealed task checkouts, with their `node_modules` (over 300,000 files).

**Access and secrets.**
- Never grant access yourself: deploy keys, tokens and repo settings are the owner's step. Prepare everything and
  hand over the one action.
- Never print or read a secret. The planner's token travels only through the process environment.
- A safeguard someone set on purpose (e.g. node3's old `pushurl` block) is changed only on the owner's explicit
  say-so, and the change is recorded where the safeguard was documented.
