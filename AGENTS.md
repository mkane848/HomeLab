# AGENTS.md

Repo for provisioning a hybrid Ubuntu server / Windows PCs LLM setup. llama.cpp's `llama-server` runs on the server and
node3, the only local engine since Ollama was removed on 2026-11-21. The desktop runs no models. The client is OpenCode.
It is not an app codebase: most changes are bash and PowerShell scripts, JSONC config templates, and docs.

**North star:** turn every machine in the house into interchangeable compute for one Claude Code / Codex-like
experience. You prompt in plain language and the fleet supplies the models: the profile selects one, OpenCode pins it,
tests enforce it. Progress gates by hardware, not by preference. What is next: `docs/plan.md`.

This file follows [Factory's AGENTS.md guide](https://docs.factory.com/harness/agents-md). History, incidents and
postmortems are in `CHANGELOG.md` and `docs/roadmap.md`, not here.

## Commands

Run from the repo root. PowerShell 7 (`pwsh`) is the only supported PowerShell (since 2026-10-12).

| What | Command |
|---|---|
| Syntax-check a `.ps1` | `pwsh -NoProfile -Command '$errs = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile("<path>",[ref]$null,[ref]$errs); if ($errs.Count) { $errs \| ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 } else { "OK" }'` |
| Syntax-check a `.sh` | `bash -n <path>` |
| Lint shell as CI does | `shellcheck -S error <path>` (CI lints `server/scripts`, `server/household`, `profiles`, `tests` and `.claude/hooks`) |
| One guard | `pwsh -NoProfile -File tests/test-<name>.ps1` |
| Every guard | `pwsh -NoProfile -File tests/run-guards.ps1` |
| Regenerate the reference tables | `python3 tests/make-reference.py` (CI runs it with `--check`) |
| Wait for CI on a PR | `gh run watch <id> --exit-status` |

Notes:
- The ParseFile form prints each error's line and message and exits 1; the bare `ParseFile(...)` call dumps a whole
  `ScriptBlockAst`. Printing `$errs` itself is not enough: on pwsh 7.4.6 a ParseError formats as an empty line
  (checked 2026-11-24), which reads like no output.
  `[ref]$null` as a discard out-parameter is legal in pwsh 7.
- On Linux, give `ParseFile` a forward-slash path. A backslash path resolves to a wrong literal filename and reports a
  misleading `FileReadError` that is not a syntax error.
- Which guard to run after touching what: the "run after" column of
  [`docs/reference/guards.md`](docs/reference/guards.md).
- Most guards are Windows-first (stand-in `.cmd` shims). On Linux some stop early. Windows CI is the run that counts.

## Verification

Do these in order before calling a change done:
1. `git diff` the change, and syntax-check every edited script (Commands).
2. Run the guards for what you touched. A new `tests/test-*.ps1` needs its `# protects:` and `# run-after:` header
   lines, or CI fails.
3. `python3 tests/make-reference.py --check`.
4. Reproduce CI's environment for a guard: the runners set `core.autocrlf=true`. Run the guard under
   `GIT_CONFIG_GLOBAL=<file with autocrlf = true>`, with the guard file itself converted to CRLF.
5. **Done means CI is green on the PR's current head**, not a local pass. PR #188's first "fix" passed locally and
   failed CI twice.

Syntax-checking is necessary, not sufficient: it catches malformed PowerShell, not wrong data. Verify task data against
a genuinely fresh `git worktree add`, never a reused branch checkout (the `kane-02` postmortem in `CHANGELOG.md`).

## Where things are

The long reference lives in `docs/reference/` (moved there from this file on 2026-10-26). Read the row you need.

| Need | Read |
|---|---|
| Machines, roles, per-host history (`server`, `desktop`, `node3`) | [`docs/reference/machines.md`](docs/reference/machines.md) (table generated from `machines.tsv`) |
| The main seat, `/plan` → execute, Plan/Build toggle, live profiles | [`docs/reference/workflow.md`](docs/reference/workflow.md) |
| Model catalog, installing models, profiles, OpenCode config, sync pipeline, desktop Docker | [`docs/reference/config.md`](docs/reference/config.md) |
| Which guard to run after touching X; CI; every `tests/` tool in detail | [`docs/reference/guards.md`](docs/reference/guards.md) (table generated from each guard's `# protects:` / `# run-after:` header) |
| Symptom → cause → fix (tool-calling, context, VRAM, Vulkan, env vars, GPU loss) | [`docs/reference/gotchas.md`](docs/reference/gotchas.md) |
| A testing window on the server and node3 with no one there (`run-window.ps1`, `llamacpp-window.sh`) | [`docs/unattended-window.md`](docs/unattended-window.md) |
| Working on node3 over ssh, and git there | [`node3/README.md`](node3/README.md) → "Working on node3 over ssh", "Git on node3" |
| What is next, who it waits on | [`docs/plan.md`](docs/plan.md) |
| History, incidents, postmortems | `CHANGELOG.md`, `docs/roadmap.md` (the dated log) |

**Generated files:** the tables in `docs/reference/machines.md` and `docs/reference/guards.md` come from `machines.tsv`
and the guard headers. Edit those sources, then run `python3 tests/make-reference.py`. Never hand-edit a generated
block.

## Safety

- **Commit before letting an agent edit anything.** `git status` should be clean when you start. Before 2026-09-17 the
  repo had no git, and a damaged `desktop/scripts/sync-skills.ps1` could only be recovered by reading it by hand.
- **Never print or read a secret.** `.env`, `desktop/docker/.env` and anything `*.env` are git-ignored; only
  `.env.example` templates are tracked. Secrets live in `~/.config/opencode/.secrets/`, outside the repo. The planner's
  token travels only through the process environment.
- **Never grant access yourself.** Deploy keys, tokens and repo settings are the owner's step: prepare everything and
  hand over the one action.
- **A safeguard set on purpose** (e.g. node3's old `pushurl` block) changes only on the owner's explicit say-so. Record
  the change where the safeguard is documented.
- **Before deleting anything:** dry run, then move it aside, verify (hash-compare against the copy that stays), then
  delete.
- **Git:** the remote is `origin` (`github.com/mkane848/HomeLab`). Don't force-push `main`; revert and re-PR instead.
  Commit with explicit paths, never `git commit -a`.
- Remote and web sessions get `pwsh` from `.claude/hooks/session-start.sh` (gated on `$CLAUDE_CODE_REMOTE`). It
  installs the official Linux tarball to `/opt/microsoft/powershell/7`, linked from `/usr/local/bin/pwsh`, only if its
  sha256 is the pin for the architecture. A new PowerShell version needs new pins from that release's `hashes.sha256`.
  It does nothing if `pwsh` is already on `PATH`.

## PRs and docs

- PRs: title `type: description` (`docs: …`, `tests: …`, `fix: …`). Fill the Verification section with the commands
  run, not assertions, and add a `[Unreleased]` `CHANGELOG.md` entry. Template: `.github/PULL_REQUEST_TEMPLATE.md`;
  rules: `CONTRIBUTING.md`.
- **The owner merges whenever a PR is green.** Before pushing more commits to a PR, check `gh pr view <n> --json state`.
  If it is merged, cherry-pick onto a new branch from `main` and open a new PR. #190 was merged one commit early, and the
  second fix needed #191.
- **Model-written PRs: a green suite is necessary, not sufficient.** Audit every new test against the branch it claims
  to cover (a passing test can be green on broken code), and run integration on a seeded DB before merge. Method, with
  the PR #82 Background-bug worked example: `docs/review-gate/testing.md`.
- **Cite external sources in docs.** A claim grounded in a paper, leaderboard, benchmark, blog or tool docs gets an
  inline link with descriptive text on first mention: never a bare URL, never a guessed one. Fetch any URL before you
  cite it, and use the fetched link if the two differ. Add each new source to `docs/references.md` (short name, title,
  author/lab, date, URL) in the same change. Re-verify stale-able claims (leaderboard ranks, "best model", version facts)
  when editing a doc that carries them; if you cannot, keep the claim but date-stamp it.

## Known mistakes

Each was a real, repeated mistake, most from 2026-10-30 to 11-02. Follow these without being asked.

**Numbers.**
- Compare arms by task, paired, with an exact sign test. A test on pooled runs overstates the evidence
  (`docs/methodology.md` → "How to compare two arms").
- Before a headline goes in a report, recompute it from the raw results, and ask what the known-good answer scores on
  the same measure.

**A guard that cannot fail protects nothing.**
- Mutation-check every new check: disable the rule (or run the guard against `main`'s version of the script) and confirm
  the guard goes red, then restore and confirm the file is byte-identical (`cmp`). Twice a new guard stayed green with
  its rule removed: once the check matched text that appears either way, once a later step's exit 1 hid the missing
  refusal.
- Assert **where** a script stopped (its own message, and no later step's), not just its exit code.
- A throwaway git repo in a guard pins `git config core.autocrlf false`, and here-string fixtures are normalised to LF.
- Test the false-positive side as hard as the true one. The integrity gate once blocked a perfect attempt over example
  branch names (`` `fix/digest-retry` ``) and over `` `.github/` `` (a `TrimStart('.')` ate the dot). Blocking good work
  breaks the owner's bar as surely as keeping bad work.

**Editing files.**
- Python edits: `open(..., newline='')` keeps line endings. Use raw strings (`r'''...'''`) for anything with Windows
  paths or PowerShell (`"\run-planner"` became a carriage return). Assert the old text occurs exactly once before
  replacing it.
- Let tools write their own output files when bytes matter (`git diff --binary --output=<file>`). Native output through
  PowerShell loses CRLF and binary content.

**PowerShell pitfalls** (pwsh 7):
- `"$LASTEXITCODE: x"` is a parse error: use `"${LASTEXITCODE}: x"`.
- A comma after `-replace` joins its operands: write `(($x) -replace 'a', 'b'), $next`.
- Variable names are case-insensitive: `$m4Tasks` overwrote the parameter `$M4Tasks` (PR #174).
- A literal `'""'` passed to a native exe arrives as two quote characters: `ssh-keygen -N '""'` set a passphrase.

**node3 (Windows) over ssh.** Its ssh shell is **cmd**: copy a script with `scp` and run it with
`pwsh -NoProfile -File <script>`. Use `ssh -o BatchMode=yes` for anything that could prompt. A one-shot scheduled task
has none of the user's environment, so set every variable the run needs. The details and the incidents behind them are
in [`node3/README.md`](node3/README.md) → "Working on node3 over ssh".

**Long runs and cleanup.**
- Start long work in the background and wait for its notification; do not poll with `sleep`. Check the first attempt's
  result early: a run that only reaches "infrastructure" is wasted hours.
- Searches skip `tests/.worktrees/`: it holds the sealed task checkouts and their `node_modules` (over 300,000 files).
