# Brief: add real-bug-fix tasks to the HomeLab LLM-executor benchmark (item 5, 2026-10-03)

Read ALL of this first. Your group assignment (which tasks, SHAs, files, notes) is in your prompt.

## What the benchmark is (30 seconds)
`tests/test-tasks.ps1` in /home/user/HomeLab runs a FIXED PROMPT through `opencode run` (a local LLM drives the editor/shell tools) inside a throwaway
git worktree pinned to a commit, then grades it MECHANICALLY on four gates:
- scope: the diff touches only `allowFiles` (and at least one `srcRevertFiles` file);
- suite: `testCmd` is green on the model's change;
- failsOnOld: revert ONLY `srcRevertFiles` (the model's tests stay) -> the suite must now FAIL. A test that is green on the broken code is a false positive;
- typecheck (informational; our new tasks define none -> SKIP);
plus, when the task has an `acceptance` block, the owner's/upstream test file(s) are swapped in over the model's and run against the model's source (informational, never a gate).
The models are SMALL LOCAL ones (qwen3 8-35B). The suite is saturating at the top, so each new task must be fair, deterministic and gradable, and ideally differently shaped.
Each task = a REAL, already-merged upstream bug fix: the pin (`benchBaseCommit`) is the fix commit's PARENT; the fix commit is on origin/main of the upstream repo.

## Ground rules
- /home/user/HomeLab is READ-ONLY for you (read the manifest, harness, docs; never edit, commit, push). No GitHub/gh/network use except `npm`/`pnpm` installs the harness does itself.
- Work only under your group dir `G` = `<scratchpad>/rig/<group>/` (scratchpad = /tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad). Do NOT spawn subagents.
- Today is 2026-10-03. Persist early and often (write entries/report files as you go; a cut-off must not lose work).
- Never claim a result you did not run. Paste real runner summary lines into your report.
- Be economical with output: pipe long logs through tail/grep.
- Upstream clones you may read (pristine, never modify): `<scratchpad>/rig/repos/{KaneEnabler,lfc-bot,ASoHaVCompanionApp}`. Make your OWN clones for worktrees (see tools/README.md).
- Earlier mining notes with per-candidate evidence (read the section for your tasks): `<scratchpad>/mine-kane/verification.md`, `mine-lfc/verification.md`,
  `mine-asohav-old/verification.md`, `mine-asohav-new/verification.md`; whole candidate table: `<scratchpad>/CANDIDATES-2026-09-29.md`.
  Hand-scoped artifacts (asohav-05/06) are in `mine-asohav-old/` (library.test.scoped.ts, library.scoped-fix.ts.bak, adminLogic.fixcommit.ts.bak, logic.*.ts). Treat those notes as leads; RE-VERIFY everything yourself in fresh worktrees.

## The validation rig (already built and smoke-tested on kane-07; read `<scratchpad>/rig/tools/README.md`)
It runs the REAL harness against local clones with a stand-in `opencode` that applies reference patches. Modes: `dry` (worktree+install+baseline+acceptance-must-fail-on-base),
`ref` (source fix + tests -> all gates PASS, acceptance PASS), `srconly` (fix without tests -> failsOnOld FAIL), `testsonly` (tests without fix -> scope FAIL + suite FAIL).
Env variants via RIG_ENV / RIG_UNSET / RIG_TAG. If the rig itself misbehaves, say exactly how in your report instead of working around it silently.

## Deliverables (all under G)
1. `entries.<group>.json` - a JSON ARRAY of complete manifest entries (format below), validated with `python3 -m json.tool`.
2. `rig/ref/<taskId>.src.patch` and `.test.patch` - reference patches used by the rig (mkpatch.sh for clean cuts; hand-made for hand-scoped ones).
3. `report.<group>.md` - per task: evidence table (baseline N/N; fix tests alone on old src: x failed/y; ref: N/N), the four rig runs' gate lines, environment-sensitivity matrix results,
   determinism runs, decisions (acceptance yes/no and why; testEnv yes/no and why; what the prompt pins and why), fairness analysis, hazards/Windows notes, any residual doubt.
4. When done: `rm -rf G/rig/tests/.worktrees` (frees GBs; logs and JSON stay) and `git -C <clone> worktree prune`.
Final message to the parent (<= 350 words): one table row per task (id | baseline | fix-tests-on-old | ref | srconly | testsonly | acceptance | notes), paths, open problems. Details live in the files.

## Manifest entry format (follow the existing 9 entries in /home/user/HomeLab/tests/tasks/manifest.json; read kane-04, asohav-02, lfc-02 closely)
Key order: `id, title, source, repo, branch, benchBaseCommit, packageManager (npm repos only), baselineExpect, allowFiles, srcRevertFiles, testDir, testCmd, installFlags,
testEnv, testEnvNote (only if pinned), setup (only if needed), acceptance (only if used), prompt`.
- `id` as given in your assignment; `title` "<Repo>: <what must be fixed>" (one line). `repo`: KaneEnabler = "C:/Projects/KaneEnabler"; lfc-bot = "M:/Projects/LFCbot"; ASoHaV = "M:/TTRPG/A Story of Heroes and Villains" (the rig rewrites it; keep these owner paths in your entries file).
- `branch` = `bench/<slug>` as given (a label only); `benchBaseCommit` = the full 40-hex parent (git rev-parse it; never an abbreviation).
- `packageManager`: "npm" for lfc-bot and ASoHaV; omit for KaneEnabler (pnpm default). `installFlags`: Kane `["--frozen-lockfile","--ignore-scripts"]`; lfc/ASoHaV `["--ignore-scripts"]`.
- `testDir` relative to the repo root (lfc-bot ".") ; `testCmd` an array, e.g. `["pnpm","exec","vitest","run","src/x.test.ts"]` (Kane) or `["npx","vitest","run","tests/x.test.ts"]` (npm repos).
  Use the SINGLE test file when it exists at the pin; use the FULL suite (`vitest run`, like asohav-02) when the task's test file is NEW (does not exist at the pin) - then baselineExpect is the full-suite count.
- `baselineExpect` {testsTotal, testsPass} = what the harness's baseline run prints on the untouched pin (equal numbers - baseline must be green).
- `allowFiles` = every file the model may change (src + test, incl. a NEW test file); `srcRevertFiles` = the SOURCE files only (the failsOnOld gate reverts exactly these; list ALL source files the reference fix touches).
- `source`: provenance, <= ~900 chars: "Mined from <Repo> commit <full SHA> (<date>, real merged fix) ... what was scoped down (bundled commits!) ... Verified 2026-10-03 in a fresh worktree at the parent (<full SHA>): N/N baseline, then the fix commit's test file alone against the unfixed source (x/y fail) to confirm failsOnOld, then N/N with the fix's source; replayed through test-tasks.ps1 with a stand-in opencode (reference = every gate PASS; source-only = failsOnOld FAIL; tests-only = suite FAIL). <bug class, what is new vs the existing tasks>."
- `setup`: only if a fresh worktree needs it (e.g. ASoHaV server tasks must build `packages/shared` first: `{"note": "...", "cwd": "packages/shared", "cmd": ["npx","tsc","-p","tsconfig.json"]}` exactly like asohav-01/02). Confirm necessity in a FRESH worktree with `dry`.
- `testEnv`/`testEnvNote`: pin an environment variable (null = unset) ONLY when your env matrix shows a gate result that depends on it. Standing decision: ASoHaV `apps/server` tasks pin `{"DATABASE_URL": null}` (asohav-02's finding: a model-written test importing the real repo.ts loads pgPool.ts, which throws at import without it; CI has no DATABASE_URL), wording adapted from asohav-02's `testEnvNote`; lfc-bot pins `{"MANAPOOL_API_KEY": null}` only if a task's tests are sensitive to it.
- `acceptance`: see policy below.
- `prompt`: see below. ASCII ONLY in every string of the entry (straight quotes, plain hyphens; no em dashes, curly quotes, arrows): the manifest is read by Windows PowerShell 5.1 without an encoding flag and non-ASCII would be mangled.
- Do not add `typecheck`, `baseNote`, `promptPlain`, or any field not listed.

## Acceptance policy (informational oracle = the UPSTREAM fix commit's own test file)
Use it when the fix commit's version of the task's test file, taken VERBATIM, (a) fails on the untouched pin, (b) passes with just your reference source fix, and (c) does not depend on anything the task does not ask for.
`{ "note": "...", "ref": "upstream-fix", "commit": "<full fix sha>", "files": ["<test file(s) in allowFiles>"] }` - `ref` is just a label (the commit is on origin/main; the harness pins by `commit`).
note = "The upstream fix commit's own test file(s), swapped in over the model's and run against the model's source - informational, never a gate. <what the prompt pins so a spec-compliant fix is not failed on naming, or: nothing beyond existing exports>."
OMIT acceptance when the oracle would be hand-scoped (not a commit) or would fail a correct but differently-named solution you cannot fix by pinning names in the prompt; say why in the report and in `source`.
Because acceptance runs the UPSTREAM tests against the MODEL's source, every identifier, prop name, constant, exported function, call shape or message string those tests depend on and that the model could not guess MUST be pinned in the prompt. Read the upstream test with exactly this question in mind.

## Prompt policy (this is the part that decides whether the task is fair - read carefully)
Style = the existing "guided repair" prompts (read kane-04, asohav-02, lfc-02): 1,500-2,800 chars, one paragraph (no markdown, no bullet characters; inline "(1) ... (2) ..." is fine), voice of a maintainer briefing a contractor.
Include, in this order: the repo + one-line product context; the file and function(s); the observable defect with a CONCRETE example (real card text / real input from the upstream test or commit message is ideal); the likely cause at the level a maintainer would state it
(the existing prompts name the cause - do the same, without handing over the fix); the required behaviours as a numbered inline list INCLUDING the behaviours that must keep working (the "controls" the upstream tests include);
any interface the acceptance tests need (see above); then: "Add or update tests in <file> proving: ...". "Your added/updated test(s) must FAIL if only your <source> fix is reverted while the test changes stay."; "Change ONLY these N files: <paths>. Do not commit. Do not touch any other file."; "When done, run `<testCmd as the model would type it from testDir>` and make sure it passes."
Do NOT: paste or closely paraphrase the fix's code (no regex, no helper name the model should invent); mention the benchmark, harness, gates, hidden tests, upstream SHAs; reveal a trap that the model's own `run the tests` step will surface (e.g. a constraint the pre-existing suite enforces) unless the task is unfair without it; quote more than needed from CHANGELOG/commit text.
Do: say which existing test helpers the test file already has when that saves the model a discovery step; tell it where a NEW test file goes (full path) and that it does not exist yet; state spec-reversal explicitly when existing tests must change.
If the defect is a data/spec-conformance bug (source of truth = a document), name the document but not the one wrong value.
Length discipline: if you are past ~2,800 chars you are probably dictating the fix; cut.

## Validation protocol (per task; use fresh worktrees ONLY - the rig makes them)
1. Mechanics: `./run.sh <id> ref dry` -> baseline green with N == baselineExpect; acceptance (if any) FAILS on the untouched base (the harness reports that as PASS). Confirm `setup` is needed/not needed by trying without it in a fresh worktree if unsure.
2. Reference patches: build src/test patches from the fix commit restricted to your allowFiles (mkpatch.sh), or by hand for hand-scoped ones. The reference must be a GENUINE fix + GENUINE tests (the upstream's), not a hack.
3. Four modes: dry, ref, srconly, testsonly. Expected: ref = writes>0, scope PASS, suite PASS, failsOnOld PASS, acceptance PASS; srconly = failsOnOld FAIL; testsonly = scope FAIL, suite FAIL. Explain any deviation (a spec-reversal task like kane-09 legitimately fails srconly's SUITE).
4. Mutation sanity (cheap, in a scratch worktree, not via the harness): where the fix has several independent parts, confirm that reverting each part alone turns >= 1 of the fix commit's tests red (or record which part the upstream tests do NOT pin - the report must say so; it is a known weakness, not a blocker).
5. Environment-sensitivity matrix, `ref` mode, same task, four variants: ambient (the sandbox has MANAPOOL_API_KEY set; check `env | cut -d= -f1`), `RIG_UNSET="MANAPOOL_API_KEY DATABASE_URL"`, `RIG_ENV="DATABASE_URL=postgres://u:p@127.0.0.1:9/x MANAPOOL_API_KEY=dummy-key"`, `RIG_ENV="TZ=Pacific/Auckland"` (each with its own RIG_TAG). All gate results must be identical; if not, find out why (grep process.env / config at the pin) and pin with testEnv or report the hazard. Also `grep -rn "process.env" ` the files reachable from the test file at the pin and list what you found.
6. Determinism: `ref` mode 3 times in a row (RIG_TAG=det1..3) - identical results; report any flake with the failing test name.
7. Windows/PowerShell hazards review (you cannot run Windows; REVIEW): path separators in test code, CRLF vs LF in files read at test time (regexes over Markdown), spaces in paths, timers/real time, locale, case-insensitive FS, native modules under `--ignore-scripts`. List findings; do not guess.
8. Prompt fairness self-check: re-read your prompt cold. Could a competent engineer who has never seen the upstream fix, given only the prompt and the repo, (a) find the right place, (b) know the exact required behaviours, (c) write tests that the gates accept? Would a CORRECT alternative implementation pass the acceptance tests? Note what you pinned to make it so.
9. Leave each task's final prompt in the entries file; keep the draft history out of it.

If a candidate turns out invalid (cannot be made green/red as claimed, flaky, unrunnable without scripts, etc.) say so with evidence and STOP on that task - do not paper over it.
