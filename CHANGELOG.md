# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- **fix: llama.cpp placement finds a seat whose router id was rewritten (found in the Phase 2 live window, 2026-10-16).**
  `Get-EngineGpuPlacement` (`tests/engines/llamacpp.ps1`) looked for `--alias <tag>` in `ps`, but llama-server's router
  (b11561) launches each child with `--alias <router id>` and rewrites colon ids, so `qwen3.6:35b-a3b-coding` (child
  `--alias qwen3.6:CODING`) read `not-loaded` while it sat on the GPU. It now asks `/models` for the seat's id and aliases
  and accepts a child carrying any of them (case-sensitive; `/models` unreachable falls back to the tag), and the
  not-loaded note names every name it looked for. `tests/test-engine-adapter.ps1` gained 11 checks (a rewritten id on and
  off the GPU, `/models` down, no cross-match between seats).

- **tests: the batch drives Ollama and llama.cpp hosts through the engine adapters, and the registry gets an `engine`
  column (Phase 2b of "Replacing Ollama", 2026-10-16).**
  - **The batch no longer knows Ollama's endpoints.** In `run-tasks-batch.ps1`, discovery, liveness, version,
    served models, the preflight and the probe call all go through `tests/engines/<engine>.ps1`, each loaded into
    its own module and called through `Invoke-Engine`. `Get-EngineHosts`, `Test-EngineEndpoint` and
    `Get-EngineKind` replace the `^ollama-` parsing. A `llamacpp-<host>` provider is probed with
    `test-toolcalls.ps1 -Engine llamacpp`.
  - **The registry gets an `engine` column.** `tests/run-tasks-models.tsv` is now `tag engine hosts desc`. Existing
    rows were filled once (`ollama`, `opencode-go`). Two `llamacpp` rows (`qwen3:8b` and `qwen3.6:35b-a3b-coding` on
    the server) come from the trial's probe PASSes.
  - **The probe logs:** the batch reads both `toolcalls-summary.tsv` and `toolcalls-summary-llamacpp.tsv`, and a
    probe result is stale on host + engine + engine version. Neither log's format changed.
  - **New adapter function `Get-EngineSeatTags`:** the probe menu lists a llama.cpp model once, by its alias.
  - **Console text:**
    - the hosted note says "probes local engines only";
    - `[drop]` says "engine version";
    - a down host reads "<Engine> not answering at <root>".
  - **Guards:**
    - new `tests/test-batch-engines.ps1` (99 checks, eight controls);
    - `test-engine-adapter.ps1` gains 4 checks (119);
    - `test-hosted-seats.ps1` and `test-gpu-placement.ps1` change their fixtures only (registry shape,
      `function global:` stubs).

- **tests: the serving engine is behind an adapter, and a new contextExceeded outcome (Phase 2 of "Replacing
  Ollama", 2026-10-16).**
  - **The adapter.** `tests/engines/ollama.ps1` holds the Ollama code extracted from `test-tasks.ps1`, behaviour
    unchanged. `tests/engines/llamacpp.ps1` defines the same interface (liveness, version, served models, served
    context, prompt loss, GPU placement, base URL). `test-tasks.ps1` picks one by the provider prefix of `-Model`.
    `Get-OllamaGpuPlacement` and `Get-OllamaPromptTruncation` moved into the Ollama adapter.
  - **llama.cpp specifics:**
    - the version is the router's `build_info`;
    - the served context is the seat's `--ctx-size` in `GET /models`, else `/props?model=<seat>&autoload=false`,
      so the check never loads a seat;
    - prompt loss is "not applicable: refused explicitly";
    - GPU placement is `nvidia-smi --query-compute-apps` over ssh (owner, 2026-10-16), via the new
      `LLAMACPP_<HOST>_SSH`.
  - **Run JSON:** every run records `engine` (name, version, baseUrl). The Ollama fields keep their meaning.
  - **contextExceeded.** An agent exit of 1 whose only errors are context overflows and that did not recover is
    exit -6 with a `_CTXEXCEEDED_` transcript and no row. It was `_INFRA_` "overflow killed the run". A timeout
    holding overflows stays `_TIMEOUT_` and names them.
  - **Batch:** `run-tasks-batch.ps1`'s spend accounting labels `_CPUONLY_` and `_CTXEXCEEDED_` transcripts.
  - **Guards:**
    - new `tests/test-engine-adapter.ps1` and `tests/test-context-exceeded.ps1`;
    - `test-overflow-recovery.ps1` expects `_CTXEXCEEDED_` for its dead-overflow case;
    - `test-gpu-placement.ps1` and `test-prompt-truncation.ps1` load their functions from the Ollama adapter;
    - every guard that copies the harness also copies `tests/engines/`.
  - **Not yet run live** against llama-server; that needs a short server window. The batch's `engine` column and its
    `ollama-` parsing come next.

- **feat: llama.cpp OpenCode providers, env defaults and a server twin profile (Phase 2 of "Replacing Ollama",
  2026-10-16).**
  - `opencode/global/opencode.jsonc` gains `llamacpp-server`, `llamacpp-desktop` and `llamacpp-node3` (each
    `{env:LLAMACPP_*_BASE_URL}`), with the preset's three seats: `qwen3.6:35b-a3b-coding` 65536 / 8192,
    `qwen3:8b` 32768 / 4096, and `qwen2.5-coder-3b-cpu` 16384 / 2048 with no tools. All are text-only, because the
    vision projector is not loaded. The desktop and node3 blocks are there ahead of Phases 4 and 5; neither host
    runs a llama-server yet.
  - **Fix:** `ollama-server`'s `glm4:9b` is now `tool_call: false`. The same weights failed the probe on node3, and
    node3's block already said so.
  - **New live profile `dev-workflow-server-llamacpp`** (`opencode server-llamacpp`): `dev-workflow-server` with both
    seats on the server's llama-server. Every live profile now exports `LLAMACPP_SERVER_BASE_URL` and
    `LLAMACPP_SERVER_SSH`, and `desktop/scripts/opencode.ps1` passes and restores them.
  - **`tests/test-profiles.ps1`:**
    - the served-context check reads llama-server's `GET /props?model=<seat>&autoload=false`
      (`default_generation_settings.n_ctx`);
    - the tier and base-URL maps know `llamacpp-*`;
    - model listing reads `aliases`;
    - the round-trip probes accept `reasoning_content`.
  - **`tests/test-opencode-profiles.ps1`** covers the twin's short name.
  - **Verified offline:** the template resolves every new model with its `limit` (`OPENCODE_CONFIG` pointed at a
    copy, `opencode debug config`). Not yet run live against llama-server: that needs a short server window.

- **docs: llama.cpp trial Phase 1 results, Gate G1 go (2026-10-13 to 16).** The runbook ran on the server from a
  Claude Code session on the desktop. The numbers are in `docs/llamacpp-trial.md` → "Results"; summary in
  `docs/roadmap.md` step 4.
  - **The premise holds.** Ollama 0.34.3, 0.40.3 and (node3) 0.40.4 all cut an over-long prompt silently, keeping 38%.
    The cut is Ollama's own Go code plus `--context-shift --keep 4` on its bundled llama-server.
  - **llama-server instead refuses loudly**, with HTTP 400 `exceed_context_size_error`, which OpenCode classifies and
    recovers from. 74 overflows were recovered across step 7, with zero silent lost briefs; the Ollama baseline lost
    3 of 15. 4 of 12 lost-brief runs looped to the 45-minute cap: `kane-08`'s two files are ~96k tokens against a 64k
    window. The owner read them as "loud, not silent", and the fix (reading in ranges) is Phase 2's.
  - **Faster at matched settings.** Ollama runs MTP speculative decoding, so the preset copies it. At
    `n-cpu-moe = 16`, prefill is 106–109% and decode 112–118% of Ollama's, with 1,477 MiB of VRAM free against 782.
  - **Tool probe:** PASS for both seats.
  - **Soak:** 144 of 144 cycles, flat VRAM and RAM, 0 restarts, through a real `daemon-reload` (snapd). The GPU was
    kept; the owner's `sudo` drill was not run.
  - **Round of 15:** 11 (12 on hidden tests alone), level with Ollama's classifier-2 rounds, in about two thirds of
    their wall time.
  - **Placement:** llama-server has no HTTP placement signal; `nvidia-smi --query-compute-apps` over ssh is exact.
  - **Changes on the way:**
    - `server/llamacpp/models.ini` gains an `alias` per seat (router mode rewrites colon names), `device = none` for
      the CPU 3b (`n-gpu-layers = 0` still took 332 MiB), Ollama's sampling, `n-cpu-moe = 16` and MTP.
    - `server/scripts/llamacpp_check.py` accepts aliases and maps `draft_num_predict`.
    - `server/scripts/llamacpp-soak.sh` is new.
    - `tests/test-tasks.ps1` grades an `opencode run` that exits 1 only because it recovered from context overflows
      (`Get-OverflowRecovery`; new guard `tests/test-overflow-recovery.ps1`). opencode 1.18.34 exits 1 after any
      overflow; Ollama never sends one, so no Ollama row changes.
  - **Raw rows:** `tests/results/overflow-probe.tsv`, `toolcalls-summary-llamacpp.tsv`, `bench-speed.tsv` and
    `llamacpp-soak.tsv`. Task runs are assisted and stay private.
  - **The window is closed.** llama-server is down, the `ollama/ollama:0.40.3` image is removed, and the server's
    Ollama serves `qwen3.6` on the GPU again; the unused `ollama/ollama:latest` (0.33.3) image went too.
  - **Phase 2 approved (owner, 2026-10-16)**, scoped as the roadmap outlines it. Placement on llama.cpp hosts is
    `nvidia-smi` over ssh. The fix for files bigger than the window is its own item after Phase 2, and the "After the
    trial" list follows Phase 2.

- **results: node3's `qwen3:8b` re-run, speed was not what held it back (2026-10-13/14).** The roadmap's "After the
  trial" item 2, run early from the desktop while node3 was free: the seven public tasks it had old rows for, two reps
  each, unassisted, with the seat all on the GPU (flash attention, `q8_0` KV) and its small model pinned to node3.
  **0 full passes in 12 graded rows** (2 more timed out with no row), against 1 of 6 valid old rows; runs took 39 to
  348 s instead of 317 to 1,227. So its weak record was capability, not speed. The 12 rows and their run files are in
  `tests/results/`, written up in `tests/results/README.md` → "node3's `qwen3:8b` re-run". Afterwards a Windows Update
  restart let node3's Ollama tray updater install 0.40.4 (2026-10-14). All the rows are 0.34.2, so the two timeouts
  were not re-run. node3 now has the desktop's update block (`desktop/scripts/pin-ollama-desktop.ps1`, its firewall
  rule), and `qwen3:8b` passes the tool-call probe on 0.40.4 (`toolcalls-summary.tsv`). Owner, 2026-10-14: stay on the
  newest Ollama unless problems turn up, but upgrade on purpose (updaters blocked, re-probe, a new era).

- **docs: merging and auto-merge, set up safely (2026-10-13, owner's request).** `CONTRIBUTING.md` gains "Merging and
  auto-merge":
  - **who can merge:** only the owner, the sole admin;
  - **why fork PRs can't do harm:** a read-only token, no secrets, `pull_request` only;
  - **the settings that make it hold:** **Allow auto-merge**, a `main` ruleset (PR required, both CI jobs
    required, no force pushes or deletions, no bypass), and fork workflows that need approval with a read-only
    token.

  The settings are the owner's to flip in GitHub's web UI. This session has no tool for repository settings, and
  could not reach GitHub's docs to cite them.

- **docs: the llama.cpp trial's provider snippet needs no `npm` field (2026-10-13).** One of the trial's open items, settled
  from OpenCode's source at v1.18.34 (`packages/opencode/src/provider/provider.ts` L1547-1555): a config-defined provider with
  no `npm` and an id models.dev doesn't know, such as `llamacpp-server`, gets `@ai-sdk/openai-compatible`, as the `ollama-*`
  blocks already do, and that SDK gets `includeUsage` (L1806). `docs/llamacpp-trial.md` step 6 drops the line and its
  UNVERIFIED comment; `docs/references.md` gains the source. The other open item that needs no server, the preset's
  sampling parameters, can't be settled from a cloud session (`registry.ollama.ai` and `ollama.com` unreachable there), so it
  stays runbook step 3.
  The window itself will be run from a Claude Code session on the desktop (owner, 2026-10-13):
  `docs/agent-notes/prompt-llamacpp-window.md` is its paste-ready handoff, with stop points, `sudo` left to the owner,
  the baseline's settings held constant, and no Phase 2 without a new approval. It also carries a side job for while
  node3 is free: two unassisted reps of `qwen3:8b` on node3 over the seven public tasks it has old rows for, to tell
  speed from capability now that its KV cache fits on the GPU (roadmap → "After the trial", item 2), stopped before the
  trial's step 7, with the titles model kept off the server.

- **CI: syntax on Linux, every guard on Windows (2026-10-13, owner-approved).** `.github/workflows/checks.yml` runs on
  every pull request and push to `main`. The `syntax` job (Ubuntu) parses all 53 `.ps1` files with the AGENTS.md
  `ParseFile` wrapper, runs `bash -n` on all 22 `.sh` files, the 16 Python tests of `tests/test_llamacpp_check.py`, and
  parses `tests/tasks/manifest.json`. The `guards` job (`windows-latest`, PowerShell 7, Node 24.18.0, `opencode-ai@1.18.34`)
  runs `tests/run-guards.ps1` (new), which runs each `tests/test-*.ps1` in its own `pwsh` with an empty stdin and a
  timeout (900 s, whole process tree ended), prints a table and each failure's log tail, writes the GitHub step summary,
  and exits 1 on any guard not OK. Left out, with the reason in the script: `test-profiles`, `test-tasks` and
  `test-toolcalls`, which need live hosts. Read-only token, no secrets, no `pull_request_target`. Why: a Linux sweep the
  same day found 11 of the 28 guards runnable there; the rest need Windows (stand-in `opencode.cmd` shims, `%TEMP%`,
  `taskkill`, `Win32_Process`), so script changes written in cloud sessions were first exercised on the desktop, which is
  how the `python3` Store placeholder and the `test-task-pins` failure under 5.1 were found. AGENTS.md (Verification)
  and the PR template name the workflow and the runner.
  **Its first run (pwsh 7.6.6, Git for Windows defaults) passed 26 of 28 guards and found two real bugs, fixed here:**
  - **Unsetting an environment variable silently stopped working on PowerShell 7.5+.** PowerShell binds `$null` to a
    .NET string parameter as `""`; `SetEnvironmentVariable(name, "")` removed the variable on .NET 8 (pwsh 7.4, the
    desktop's 7.4.20) and sets it to empty on .NET 9+ (pwsh 7.5+, node3's 7.6.6). So on node3 a task pinned "unset"
    (`DATABASE_URL` for asohav-02/05/07/08, `MANAPOOL_API_KEY` for lfc-02) would have seen `''`, which Node's `??`
    does not treat as missing, and every variable `Set-TaskTestEnv` or `Set-NoPushEnv` touched would have been left
    as `''` after a run. `Set-TaskTestEnv` and `Restore-TaskTestEnv` (`tests/test-tasks.ps1`) and the launcher's env
    restore (`desktop/scripts/opencode.ps1`) now pass `[NullString]::Value`, a true null. Reproduced on pwsh 7.6.6
    on Linux (the same 4 FAILs as CI), then `test-task-env.ps1` 60 of 60 on 7.4.6 and 7.6.6; a control with the old
    harness fails the same 4. The guard's own setup lines had the same trap and are fixed too, and
    `test-opencode-profiles.ps1` now checks the variable is absent (`Test-Path`), not merely empty.
  - **`test-llamacpp-stack.ps1` failed on any CRLF checkout** (Git for Windows defaults to `core.autocrlf=true`; the
    repo has no `.gitattributes`): its preset mutations search for multi-line text joined with LF. It now normalises
    the preset to LF before mutating. 36 of 36 on a CRLF and an LF copy.
  - **`.gitattributes` (new, owner-approved):** `*.sh`, `*.ini`, `*.yml`, `*.yaml` and `*.py` are checked out with LF on
    every machine, whatever `core.autocrlf` says, because they run on Linux. All 72 such files were already stored LF,
    so nothing is rewritten in the repo; `.ps1`, Markdown and the rest keep each clone's own setting (some `.ps1` are
    stored CRLF on purpose). An existing Windows clone keeps its CRLF copies until they are checked out again:
    `git rm -r --cached -q . && git reset --hard` in a clean tree refreshes them.

- **The daily default is the server, and the plans are reconciled with 2026-10-10..13 (owner review, 2026-10-13).**
  - **Changed behaviour:** `desktop/scripts/opencode.ps1` launches `dev-workflow-server` by default (was
    `dev-workflow-quality`): the same `qwen3.6` weights on the server, at 2.2 to 3.4 times the desktop's prefill and
    about twice its decode. `dev-workflow-quality` is the fallback (`opencode quality`) when the server is down or
    during the llama.cpp window. No profile's content changed; the desktop's hand-set User-level `OPENCODE_MODEL`,
    which a bare `opencode` uses, is not touched.
  - **Order (roadmap → "Next up"):** server-side work first, few moving parts at once. The llama.cpp trial's
    window (step 4) is next; node3 as run host and the rest wait in a new "After the trial" list (node3 run host
    and control run, a `qwen3:8b` re-run on the fixed node3, the first classifier-3 round, worktrees outside the
    checkout, the server profile's small model, best-of-N, and the desktop's role after Gate G1).
  - **Corrected:** "the work packages are solved locally, 11 of 12" was one desktop round; replicated on the
    server it is 39 of 48 (81%), 46 of 60 on all 15 tasks, with 14 of 15 passing at least once in four reps.
  - **Retired:** `qwen3.5:9b` as an executor (overflow crashes in half its work-package runs); node3's Q4
    `qwen3.5:9b` trial dropped. Its probe row in `tests/run-tasks-models.tsv` stays.
  - **Docs brought up to date:** `docs/target-setup.md` (status; no Linux harness port and no dispatcher on the
    server, per the contention measurement; a current-build table; milestones 3, 4 and 6; node3 sleep gap closed),
    `docs/start-here.md` (the server is up and the default), `docs/profiles.md` (five live profiles, seven
    parked), `README.md` (the server quick start used a profile that switches the server tier off),
    `docs/llamacpp-trial.md` (announce the window; daily use moves to the desktop during it) and AGENTS.md.

- **PowerShell 7 is the only supported PowerShell (owner, 2026-10-12).** One version to write, test and support.
  Guards are run on `pwsh` 7 only; Windows PowerShell 5.1 is no longer a target. Nothing is removed: the existing
  scripts still happen to parse on 5.1, and older entries below that say "PowerShell 7 and 5.1" record what was run
  at the time. What changed: `AGENTS.md` no longer asks for the 5.1 cross-check, and new entries say PowerShell 7.
  The one 5.1 launcher left is a WezTerm menu entry (`wezterm/wezterm.lua`), kept as a fallback shell. `pwsh` 7.6.6
  is installed on node3 and 7.x on the desktop; the server has no PowerShell (its scripts are bash).

- **Measured: the same small seat on three hosts (2026-10-13).** `qwen3:8b`, rep 2 at 3k / 16k / 30k tokens, prefill and decode in
  tok/s: server 6,097 / 100, 4,735 / 77, 3,426 / 63; node3 as set up 3,063 / 30, 2,671 / 17, 2,181 / 10; desktop 237 / 65,
  138 / 54 (one rep read 48, six others 135-139), 51 / 46 (rep 1; rep 2 timed out). On the desktop's better readings its prefill is 17 to 34 times
  slower than the server's and its decode 1.4 to 1.5 times. The desktop's
  depth figures are unsettled (one 16k request read 48 where two others read 136 and 138, and one 30k request timed out at
  900 s). The flash-attention A/B on a quiet machine (`bench-speed-desktop-fa.tsv`): at 16k the desktop's settings read 137 tok/s
  prefill and 54 decode, a temporary instance with flash attention and the q8_0 KV cache off 321 and 27, so the desktop
  trades 2.3 times the prefill for twice the decode; at 30k neither setting is good (36 to 50 tok/s prefill). The overnight
  slowdown did not recur (six of seven 16k readings at 135 to 139). Table and caveats: `tests/results/README.md`.

- **Measured: node3's `qwen3:8b` is 4 to 5 times slower at depth than it needs to be (2026-10-12).** With Ollama 0.34.2 on
  node3 as configured (no flash attention, f16 KV cache, 32k context) the seat takes 10.36 GB, 81% on the GPU, and decodes
  17 tok/s at 16k and 11.7 at 30k. The same seat on a temporary second Ollama with `OLLAMA_FLASH_ATTENTION=1` and
  `OLLAMA_KV_CACHE_TYPE=q8_0` (this process only, killed afterwards; node3 checked back to how it was) takes 7.64 GB, all on
  the GPU, and decodes 74 and 58 tok/s; at 3k, 100 tok/s. Those are the desktop's and the server's settings. Changing them
  on node3 (machine variables plus an Ollama restart) is the owner's call: it is a shared PC. Rows in
  `tests/results/bench-speed.tsv` (host `node3`) and `bench-speed-node3-kv.tsv`.
  Also found: the first request after an idle gap reads low (3k decode 19 against 100 on the repeat), so the first size's
  decode in `bench-speed.tsv` is understated on the desktop and node3, and on any host right after a model load
  (the server's first `qwen3:8b` request read 485 tok/s prefill against 6,097 on the repeat); the long-resident
  `qwen3.6` rows on the server are not affected. Noted in `tests/results/README.md`; warm-up not yet lengthened.

- **node3's Ollama now runs with flash attention and a q8_0 KV cache, and node3 has the task repos (2026-10-13, owner-approved).**
  `OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=q8_0` were set as User variables of node3's account (not machine-wide) and the
  Ollama tray app restarted in her session through a one-shot scheduled task, removed afterwards (a first attempt failed to register the
  task because of an account-name lookup and left Ollama stopped for about two minutes; fixed and restored). Measured on the live
  instance: `qwen3:8b` 100% on the GPU (7.64 GB), decode 101 / 74 / 58 tok/s (was 30 / 17 / 10), prefill 28 to 41% faster, tool-call
  probe PASS. `C:\HomeLab\repos\` holds LFCbot, ASoHaV, KaneEnabler, HomeLab and HomeLab-private, imported from git bundles sent over SSH
  (branches, tags and remote-tracking refs only, no stashes; no credentials entered; `origin` pointing at GitHub with pushing disabled;
  every commit the manifests pin present). The bundles and my helper scripts were deleted from node3 afterwards. What the harness
  still needs to run there: a per-host repo-root map and an OpenCode config.

- **Stop classifier 3 (2026-10-13; owner's call).** `Get-StopKind` gains the `question` kind: a prose-only last step that ends in a
  question mark after zero write or edit calls ("Want me to go ahead and implement all the stubs?") is nudged with the stop text;
  after real edits such an ending is left alone. `ask` also reads "you didn't include a task" and "there is no task"
  (`$script:AskedForTaskExtraPattern`, kept apart from the pattern the context audit shares). Over the 647 transcripts held the
  zero-write question rule finds 16 endings, 15 of them failures (7 already nudged as `ask`, 9 not); the phrase set changes 1.
  `test-tasks.ps1` and `run-tasks-batch.ps1` take `-StopClassifier 2|3` (default 3); 2 reproduces the old classifier exactly, and
  the llama.cpp trial pins it (`docs/llamacpp-trial.md`). `stopNudges.classifier` is 3 from now on: a new assisted era, so a round
  under it is not a like-for-like repeat of rounds 2 and 3. `tests/test-stop-nudge.ps1`: 59 to 85 checks; five controls fail
  8, 2, 4, 3 and 1 checks.

- **Round 3, two more reps under classifier 2, and two endings the stop classifier misses (2026-10-13).** 22 of 30 pass
  (11 of 15 per rep), clean on every infrastructure check; with round 2, 46 of 60 and four per-rep scores of 12, 12, 11,
  11, which is the baseline's noise floor. Eight tasks pass 4 of 4; `wp-5b` 0 of 4 (the same hidden test in
  three of them). Two runs ended with no edits and a question that no nudge reached: "you didn't include a task…
  what would you like me to work on next?" and "Want me to go ahead and implement all the stubs?". A phrase fix would
  change exactly one of 647 transcripts; a rule "prose-only last step, ends in a question, no write yet" finds 16
  endings, 15 of them failures, 9 of which the classifier does not nudge. Either is classifier 3, a new assisted era,
  not made mid-round; the owner decides. `docs/roadmap.md` step 3 has the detail, `docs/llamacpp-trial.md` the baseline.

- **Round 2 of the nudged real tasks on the server, under stop classifier 2 (2026-10-12).** Two reps of the 15 (30 runs,
  about 5 h, run host the desktop): 24 of 30 pass the hidden tests, 12 of 15 in each rep, against round 1's 10 of 15 under
  classifier 1. No infrastructure, timeout, truncation or CPU-only row; `gpuPlacement` is `gpu` on all 30. 11 tasks pass in
  both reps, 2 miss in both (`wp-5b`, `real-02`) and 2 split (`wp-7a`, `real-01`). The new `pending` nudge kind fired in
  none of the runs (19 nudges: 13 empty, 4 ask, 2 announce), so it cannot be credited for `wp-5a`, `wp-6f` and `wp-3b`
  passing. 9 runs took a front-drop, mostly on the very first request (`wp-2b`, `wp-4a`, `wp-5b`, `wp-7a`). One run
  (`real-01` rep 1) edited the harness checkout's own `AGENTS.md` instead of the task's, which `outsideWrites` caught: the
  task worktrees sit inside the checkout, a suspect and not a finding. This is the like-for-like baseline the llama.cpp
  trial needed (`docs/llamacpp-trial.md`, `docs/roadmap.md` step 3).

- **Measured: other CPU work on the server costs `qwen3.6` about 60% of its decode speed (2026-10-12).** Decode on the
  server with 0, 4 and 8 busy threads (`yes`, capped by `timeout`) beside the model: 70 / 69 / 62 tok/s, then 27 / 25 / 26,
  then 20 / 23 / 20 at 3k / 30k / 60k tokens; prefill unchanged. Same script as the speed baselines, one rep per
  condition, rows in `tests/results/bench-speed-contention.tsv`. It turns "keep tool work off the server" into a
  number: `docs/target-setup.md` gets the routing rule, the roadmap step 5 the result. The desktop baseline for the same
  seat is in `bench-speed.tsv` (prefill 319 / 268 / 200, decode 31 / 36 / 29 tok/s; the server is 2.2 to 3.4 times
  faster at prefill and about 2 times at decode). node3 now has the harness toolchain (Node 24.18.0, pnpm 10.33.0,
  OpenCode 1.18.34, all matching the desktop); it still needs the task repos and a config.

- **`llamacpp-check.sh` and its guard pick a Python that runs (2026-10-12).** The first run of the trial's guards on Windows
  (desktop, PowerShell 7.4.20): all four pass except `test-llamacpp-stack.ps1`, which failed 22 checks with exit 49 from
  every checker scenario. `python3` there is the Microsoft Store placeholder (on `PATH`, exits 49 instead of running);
  the real interpreter is `python.exe`. `server/scripts/llamacpp-check.sh` now takes the first of `python3` and `python`
  that runs, and the guard does the same for its Python unit tests. After the fix all four trial guards pass.
  Found by running a guard on a second platform, as its handoff asked.

- **docs: status and handoff for the llama.cpp engine trial (2026-10-13).** Records where the program stands so the next
  session, or the owner, can pick it up without this one: Phase 0 is on `main` (PRs #115 and #116) and has run nowhere
  but a Linux sandbox on PowerShell 7.4.6; Phase 1 has not started. `docs/llamacpp-trial.md` gets a "Status and handoff"
  section (what was checked and what was not, the ordered checklist for the owner or a desktop-side agent, the open
  items the runbook already carries), and `docs/roadmap.md` step 4 is brought up to date and gets an outline of
  Phases 2–6 under "Replacing Ollama", which until now existed only in a planning session. `.gitignore` also gains
  `__pycache__/` and `*.pyc`: `tests/test-llamacpp-stack.ps1` imports `server/scripts/llamacpp_check.py`, so every
  machine that ran the guard was left with an untracked cache directory. Nothing else runs differently.
- **The llama.cpp engine trial, Phase 0: protocol, server stack and tools (2026-10-12).** The owner approved Phases 0 and 1
  of replacing Ollama (server first, Ollama untouched). This is the repo half; nothing has run against a real server, because
  the session that wrote it could not reach one. Protocol, runbook and the pre-registered Gate G1 are in
  `docs/llamacpp-trial.md`.
  - **`server/docker/docker-compose.llamacpp.yml` + `server/llamacpp/models.ini`.** A separate compose project (`name:
    llamacpp`, so it never orphans the Ollama stack's volume), image `ghcr.io/ggml-org/llama.cpp:server-cuda-b11561`
    pinned by tag and digest (the registry tags every build; CUDA 12.8.1, which driver 580 runs), the same five explicit
    `/dev/nvidia*` nodes and a `nvidia-smi -L` healthcheck as the Ollama file (the 2026-10-12 silent GPU loss),
    `restart: "no"`, and Ollama's volume mounted read-only so llama-server loads Ollama's own weights blobs. The router-mode
    preset names each seat like its Ollama tag, pins the blob by sha256, sets `c`, one slot, `q8_0` KV and flash attention.
  - **`server/scripts/llamacpp-check.sh`** (python3): checks the preset against `models/server-seats.tsv` (blob sha256,
    explicit context equal to `num_ctx`, one slot, a CPU seat with no GPU layers); with `--ollama-url` compares the sampling
    parameters Ollama applies to the same tag, because `llama-server` uses its own defaults for anything the preset leaves
    out; with `--url` checks a running server's `/props` without loading a model.
  - **`tests/probe-overflow.ps1`.** Sends one oversized request and reports EXPLICIT-ERROR, SILENT-TRUNCATION or
    ACCEPTED-FULL, and whether OpenCode v1.18.34's own overflow patterns (read from its source: 27 patterns, including
    llama.cpp's "exceeds the available context size") would classify the error. It is the premise check for the whole
    migration (does Ollama 0.40.x still cut silently?) and the first half of the overflow measurement.
  - **`-Engine llamacpp` on `tests/test-toolcalls.ps1` and `tests/bench-speed.ps1`.** The probe sends the same prompt and
    schema to `/v1/chat/completions` and logs to its own file, so the Ollama log the batch parses is untouched; the bench
    reads llama-server's `timings` with the prompt cache off and leaves placement blank (no `/api/ps`). Default behaviour
    of both is unchanged.
  - **Guards, each with controls that fail when the thing it guards is broken:** `tests/test-toolcalls-engine.ps1` (44
    checks; the probe had none), `tests/test-probe-overflow.ps1` (51), `tests/test-llamacpp-stack.ps1` (36, plus 16 Python
    tests in `tests/test_llamacpp_check.py`), and `tests/test-bench-speed.ps1` extended from 43 to 81 checks. Run on
    PowerShell 7.4.6 on Linux; not yet on Windows (PowerShell 7 only).
  - **Caught by those guards while writing them:** `@("a" + $x, "b")` fused two URLs into one string (the comma binds
    tighter than `+`) and only worked against the stand-in because its pattern was lenient, so a no-whitespace check on
    every request URL was added; `"…$NumCtx: …"` parses as a scope-qualified variable; and PowerShell hashtables enumerate
    in a per-process random order on .NET Core, so two runs of one script serialise the same request with different key
    order (compared with sorted keys).
  - **Not verified, and said so in the runbook:** whether llama.cpp can read Ollama's `qwen3.6` blob; how OpenCode behaves
    after the overflow error (classification is confirmed, recovery is not); the real status code and body of the
    overflow response; whether `n-gpu-layers = 0` leaves the CPU companion with no VRAM; whether the new
    `llamacpp-server` provider block needs an `npm` field.
  - **Roadmap, AGENTS.md and `docs/references.md`:** step 4 records the approval and what is written; "Replacing Ollama"
    gets a dated update (CUDA container on the server, same bytes, a premise check against Ollama 0.40.3, sampling as a
    confound, a mechanism-first gate); five sources added and two rows refreshed.

- **`tests/bench-speed.ps1`: prefill and decode speed of one seat on one host, at depth (2026-10-12).** "The server is
  faster" rested on wall-clock per task, which mixes the engine with how much work the model chose to do (the server's
  two early-stopped runs were also its fastest). The script asks one host the same question at the same prompt sizes
  and appends rows to `tests/results/bench-speed.tsv`: cold load, then per size (default 3k, 30k, 60k tokens) prefill and
  decode tok/s from Ollama's own durations, the `/api/ps` placement, the engine and version, and the baked `num_ctx`.
  - Each prompt carries a fresh nonce (no prefix-cache hits); a size over 92% of `num_ctx` is skipped and logged rather
    than sent (Ollama would cut it from the front); the chars-per-token estimate is corrected after the first request.
  - A warm-up request (about 600 tokens in, one out) loads the seat and calibrates characters per token, so each measured
    size lands within a few percent of its target; no speeds are logged for it, and a speed from fewer than 64 prompt or
    8 generated tokens is null. The first real run, before either rule, logged 1,000,000 tok/s for a one-token decode and a
    3000-token target that came out at 4,465.
  - Ollama only for now; `llama-server` arrives with the engine trial, and `engine` is already a column so rows compare.
  - New guard `tests/test-bench-speed.ps1` (43 checks, PowerShell 7); controls with a fixed nonce, the cap
    disabled, a wrong divisor or no minimum token count each fail their own checks. Found on the way: `"a`tb" -split
    "`t", -1` does not split on PowerShell 7.4.20 (5.1 does); the guard uses `.Split("`t")`.

- **Every run JSON records `runHost` (2026-10-12).** The agent's tools (read, edit, shell, `pnpm`, `vitest`, `tsc`) run on
  the machine hosting the harness, which is not necessarily the one serving the model: in the first server round the
  model ran on the server's GPU and every tool call on the desktop's CPU. The fleet's CPUs differ (node3's 5950X
  16c/32t, the desktop's 5800X3D 8c/16t, the server's 3700X 8c/16t), so `test-tasks.ps1` now records the machine name,
  CPU model, cores, logical processors and OS. A wall-clock compared across run hosts says whose CPU it was. Rows
  before this have no field (all desktop). `docs/roadmap.md` "Next up" step 5 is rewritten around it: model host and
  run host are separate choices, node3 is the default run host, and the Linux harness is demoted.
  - Next to it, `phaseSeconds`: how long the CPU-bound phases of that run took on that machine (`install` and `setup`,
    once per worktree; `baseline`, the post-change `suite`, `typecheck`, `acceptance`). Every run on every host now
    adds a row to the answer to "which CPU is better at which work": a single test file (start-up latency) against a
    whole suite (many workers), an install, a typecheck. It replaces most of the separate `bench-cpu.ps1` the plan had.
  - Both are checked in `tests/test-gpu-placement.ps1` (73 checks, PowerShell 7); a harness without
    `phaseSeconds` fails 3 checks, without `runHost` 2.

- **The harness checks GPU placement after each run (2026-10-12).** On 2026-10-12 the server's container lost its GPU and
  Ollama kept answering from the CPU; nothing in a run but its speed showed it, and a batch crawled for 31 minutes.
  - `tests/test-tasks.ps1`: after each run that exited 0 against an Ollama provider, `Get-OllamaGpuPlacement` asks the
    host's `/api/ps` where `-Model` sits. Loaded with `size_vram` 0 is infrastructure: exit -5, a `_CPUONLY_`
    transcript, no run JSON, no summary row. Graded runs record `gpuPlacement` (verdict, GB, share). `-NoGpuCheck`
    skips it. Only the seat asked about counts, so the CPU-pinned 3b beside it never trips it.
  - `tests/run-tasks-batch.ps1`: a `_CPUONLY_` transcript stops that host's remaining runs (`Get-CpuOnlyRun`; the
    other hosts of the batch carry on, like the hosted-model guards), with the run, how many were not started on
    that host, and `-OnlyMissing` to carry on after the fix. The batch exits 1.
  - `gpuPlacement.note` says `OLLAMA_*_BASE_URL is unset` for an Ollama provider with no base URL, instead of calling
    it a non-Ollama provider (found by the ultrareview of this branch).
  - New guard `tests/test-gpu-placement.ps1` (73 checks, PowerShell 7); controls (all measured on PowerShell 7): a harness without its exit -5 branch fails 6 checks, a batch with the stop removed 11,
    a batch that stops every host instead of one 1, the old note wording 2. The throwaway watchdog the first round ran under (outside the repo) is no
    longer needed.

- **First nudged round of the 15 real tasks on the server's `qwen3.6` (2026-10-12).** `docs/roadmap.md` "Next up"
  step 3 has the result; nothing in the repo changed but the docs, and the rows and transcripts stay in the private
  repo (assisted rows, `results/nudged-server/`).
  - 15 of 15 graded, all on the GPU (container healthy, 0 restarts, `qwen3.6` 59% GPU after the last run). 10 passed:
    work packages 8 of 12, real tasks 2 of 3. Every failure missed one hidden test.
  - On the 11 work packages both hosts graded, 8 of 11 against the desktop's 11 of 11 (the desktop's `wp-5b` timed
    out, so its "11 of 12" is 11 passes and a timeout). Fisher exact p ≈ 0.21 at one run per task: not separable yet.
  - 92 minutes against the desktop's 201 on the 14 tasks both ran (2.2x).
  - Two of the four work-package misses (`wp-5a`, `wp-6f`) stopped with work undone and ran no test; the stop
    classifier (`Get-StopKind`) didn't read their closing sentences as a stop, and neither was a third run (`wp-3b`,
    which passed).
- **Stop classifier 2: a `pending` kind (2026-10-12).** `Get-StopKind` in `tests/test-tasks.ps1` now also reads the
  last two sentences for work still to do or a wait ("Still need to…", "yet to", "I'll wait", "waiting for/on",
  "still running", "let me know when/once"). "Let me know if…" stays a sign-off. A scan of all 607 transcripts held
  (public and private) changes exactly three endings (`wp-5a`, `wp-6f`, `wp-3b`, all stops with work undone) and none of
  the other 604. The run JSON's `stopNudges` gains `classifier` (2; absent = 1), so earlier nudged rows are a different
  era. `tests/test-stop-nudge.ps1` gains 7 classifier cases and an end-to-end `pending` run (59 checks, PowerShell 7
  and 5.1); the same guard against a harness without the branch fails 8.

- **The server's container lost the GPU silently, and a benchmark batch ran on the CPU (2026-10-12).** A systemd reload
  at 11:12Z (`apt-daily`) dropped `ollama-server`'s device access on this host's systemd-cgroup-v2 Docker
  (`docker exec ollama-server nvidia-smi -L`: `Failed to initialize NVML: Unknown Error`; the host's `nvidia-smi` fine).
  Ollama kept answering from the CPU: `qwen3.6` loaded at 38 GB, `100% CPU`, and the first launch of the nudged
  15-task round crawled for 31 minutes before it was noticed. It was stopped and wrote no result rows. Recreating the
  container restored 22.68 GB / 60% on the GPU, 645 tok/s prefill and 66.8 tok/s decode.
  - `server/docker/docker-compose.yml` lists the five `/dev/nvidia*` nodes explicitly and its healthcheck now fails
    when `nvidia-smi -L` fails inside the container (the old `ollama list` check stayed green).
  - `server/scripts/status.sh` prints the GPU as the container sees it and each loaded model's GPU share.
  - `docs/troubleshooting.md` → "Container lost the GPU", an `AGENTS.md` Gotcha and `docs/roadmap.md` record the cause
    and the fix. **Tested once:** after `sudo systemctl daemon-reload` (13:48:16Z, the trigger that broke the
    container at 11:12Z) the container still saw the GPU, stayed healthy and `qwen3.6` stayed 60% on the GPU, with a
    benchmark batch running. The harness still does not check a remote host's GPU use.

- **`tests/test-hosted-seats.ps1` failed 5 checks in the first ~30 hours after every weekly plan reset (found
  2026-10-12).** It was the test's fixture, not the batch's plan-meter code. The end-to-end scenarios stamp their
  usage rows from the real clock ("30 hours ago: $8.00") but the week meter's reset was pinned to
  `2026-10-11T23:00:00Z`, so 6 hours after that reset the $8.00 row sat in the previous week, the batch counted $0.50
  instead of $8.50, and the "week is full" stop never fired. The month meter had the same flaw after the 25th. The
  scenarios now anchor their meters relative to the real clock (`LiveAnchors`, `LivePlanTsv`); the unit checks keep
  the fixed anchors because they pass their own clock. A new sweep checks every hour of 40 days, across weekly
  resets and the 25th, that a 30-hour-old row stays inside the current week and month, and a control runs the old
  fixed anchors through the same loop and must fail some hours. Same-clock result at reset + 13 h: the original
  file exits 1 with the same 5 failures, the fixed file exits 0 with 146 checks passing (PowerShell 7 and Windows
  PowerShell 5.1). `Get-MeterBounds` and the rest of `run-tasks-batch.ps1` are unchanged.


- **Server day-one bring-up (2026-10-12).** `docs/roadmap.md` "Next up" step 2 is done; step 3 has its first numbers.
  - **Ollama realigned.** `server/docker/docker-compose.yml` pins 0.34.3 (the version the desktop was measured on)
    with flash attention, a `q8_0` KV cache, `NUM_PARALLEL=1` and a 4 h keep-alive. The running container had been
    an unmanaged `ollama/ollama:latest` (0.33.3) from a stale non-git copy; it is now managed from `~/HomeLab` and
    keeps its volume. The owner extended the root volume from 98 GB to 914 GB.
  - **Seats.** New `models/server-seats.tsv` and `server/scripts/bake-models.sh` pull and bake `qwen3.6:35b-a3b-coding`
    (65536), `qwen3:8b` (32768) and `qwen2.5-coder:3b` (16384) under the desktop's tags, plus the CPU-pinned
    `qwen2.5-coder-3b-cpu`, read `num_ctx` back, and check each weights blob against the desktop's `sha256` (all
    four match). Ported from the owner's 2026-10-10 offline WIP, whose first real run this was.
  - **Fixed:** `server/scripts/install-model.sh --ctx` never created its derived model, because its Modelfile went
    through `docker exec` without `-i` and was dropped.
  - **Probe (Ollama 0.34.3, host `server`):** `qwen3:8b` and `qwen3.6:35b-a3b-coding` PASS; the 3b CPU model FAILs as
    expected. Both PASSes are server seats in `tests/run-tasks-models.tsv`. `opencode run` against the server's
    `qwen3.6` made exactly one write call and wrote the right file.
  - **`dev-workflow-server` is live again**, rewritten for `qwen3.6` on the server with the desktop tier off (it
    still seated the pre-qwen3.6 setup). `opencode/global/opencode.jsonc` `ollama-server` lists the new seats.
    `test-profiles.ps1`: 116 PASS, 0 FAIL, 0 WARN, 2 SKIP (node3 unreachable) across the five live profiles. `profiles/parked/README.md`, `AGENTS.md`
    and `server/README.md` updated.
  - **SSH access documented** in `docs/network-topology.md` ("SSH access"), which closes the gap `docs/target-setup.md`
    listed. `sudo` on the server asks for a password; privileged steps stay with the owner.
  - **First `qwen3.6` numbers on the server** (single stream, not compared with the desktop yet): 22.68 GB at 64k,
    13.59 GB on the GPU; prefill 646 tok/s; decode about 63 tok/s.


- **The server is back (2026-10-11).** `docs/server-recovery-cpu-led.md` records attempts 3–11 (two ROMs, four
  USB sticks logged by vendor/product ID, GPU out, CPU out, a 60-minute run): every Flashback write hung, so the
  board itself had failed. A replacement MAG B550 Tomahawk MAX WiFi booted first time with the same CPU, RAM,
  GPU, PSU and drive. Also recorded: the Secure Boot key re-enrollment the NVIDIA driver needs on a new board
  (and after every CMOS clear), the A-XMP freeze, the `apt full-upgrade` to kernel 7.0.0-38, and bench and
  in-case thermals. `AGENTS.md` and `docs/roadmap.md` ("Next up", step 1) no longer call the server down; the
  old handoff prompt is marked resolved. New source in `docs/references.md`: `mortar-flashback`.

- `docs/roadmap.md`: a new "Next up (2026-10-10): server first". The owner made getting the server back the top
  priority and the place things run from; the Qwen Code trial is declined. The list, in order:
  1. POST;
  2. day-one bring-up, including aligning the server's Ollama with the desktop's measured setup (it differs in
     version, flash attention, KV cache, context, parallel slots and keep-alive), the OpenCode provider, the first
     tool-call probe and the profile;
  3. measuring `qwen3.6` on the server with a nudged round of the 15 real tasks;
  4. a llama.cpp CUDA trial there;
  5. the harness ported to Linux so batches run on the server;
  6. real use the owner drives.

  The 2026-09-23 list is kept, marked superseded. `docs/target-setup.md` gets a status note.
- The replication of the nudge's rescues (`wp-2b`, `wp-5a`, `wp-1a`), which missed #107's merge, is carried here.

- `docs/roadmap.md`: "Round 3 and the stop nudge (2026-10-09/10)". With `-NudgeOnStop`, qwen3.6 passed 11 of 12
  work packages, against 7 of 12 in each plain round. That matches hosted Qwen3.7 Plus, at $0.
  - Four of the passes depended on a nudge, including both runs that had lost their brief, which the re-sent
    request rescued.
  - No nudge harmed a run.
  - `qwen3.5:9b` stays at 6 of 12; its limit is overflow crashes, which a nudge can't reach.
  - `tests/results/real-tasks-public.tsv` gains round 3's 24 unassisted rows; the nudged runs are private by
    design.
- `docs/roadmap.md`: "Alternatives to OpenCode: researched 2026-10-10". 13 agent clients measured against what the
  adapter and daily use need, with sources in `docs/references.md`. Shortlist: Qwen Code, then Goose, then
  Hermes. A trial of Qwen Code is proposed, not decided.
- `docs/roadmap.md`: "Replacing Ollama: llama.cpp or Unsloth, researched 2026-10-10".
  - Unsloth Studio serves GGUFs through `llama-server`, so it's a layer, not an engine. It fits fine-tuning and its
    quants.
  - `llama-server` would turn Ollama's silent front-drop into an explicit error, place the MoE experts on the CPU
    (`--n-cpu-moe`), report cache use exactly, and manage models itself. The cost is a new era and about 147
    Ollama references across 25 files.
  - Proposed, not decided: a side-by-side trial with Ollama kept in place.

- Agent adapter boundary: everything OpenCode-specific in the task harness moved into one file,
  `tests/agents/opencode.ps1`. That covers starting and continuing `opencode run`, reading its JSONL transcript,
  `--version`, `debug config`, plugins and orphan cleanup.
  - The transcript is read as neutral events (`Read-AgentEvents`), and every analysis now reads those: context
    events, stop kinds, outside writes, usage, cap hits, writes and session ids.
  - `test-tasks.ps1` and `run-tasks-batch.ps1` take `-Agent` (default `opencode`). Another agent is one sibling
    adapter file.
  - Every run JSON records `agent` (name, version). The `opencode*` fields stay for continuity: `opencodeVersion`
    is null under another agent.
  - The batch calls `opencode` directly only for the OpenCode Go provider.
  - Owner, 2026-10-10: the daily client may move off OpenCode, so leaving it must stay cheap.
  - New guard `tests/test-agent-adapter.ps1`. It checks the interface, the boundary in both scripts, the event
    mapping, and a second, made-up agent run end to end.
  - Behaviour is unchanged: every existing guard passes.
- `test-tasks.ps1 -NudgeOnStop [-MaxStopNudges 2]` (also on `run-tasks-batch.ps1`): an assisted diagnostic for
  runs that stop with work undone. It acts when the last step made no tool call:
  - if the model asked what its task is, it re-sends the original prompt after a short note;
  - if the last step announced a next step or was empty, it sends a "keep going, or confirm you're done" message;
  - after any other closing text, it sends nothing.

  Endings like these failed 6 of 6, 16 of 17 and 76 of 110 of the graded runs so far. New guard
  `tests/test-stop-nudge.ps1`.
- `test-tasks.ps1`: assisted rows now stay apart from the model's own, for both nudge switches:
  - a results folder holding them is marked `ASSISTED`;
  - an assisted run is refused in a folder of unassisted rows, and an unassisted run is refused in a marked one;
  - assisted runs of a private manifest are no longer mirrored to `tests/results/real-tasks-public.tsv`. They
    were before, which would have mixed nudged verdicts into the public table. No nudged run of the private
    tasks had happened yet.

  `tests/results/compaction-nudge/` and `compaction-daily/` get the marker.

- `docs/roadmap.md`: "Follow-up runs (2026-10-09)". "Check your work" didn't change any outcome. qwen3.6's
  rerun passed `wp-6a` and failed the other three again, so stopping with work undone is a pattern, not a
  one-off. `wp-2b` loses its brief every time, while `wp-3b` got its brief back from a compaction. `qwen3.5:9b`
  passed 4 of 12 work packages, all within 15 minutes, and crashed on 4. `tests/results/real-tasks-public.tsv`
  gains the 29 local rows of 2026-10-07/09. `docs/costs.md` updated to match.
- `test-tasks.ps1`: every run JSON's `contextEvents` records `askedForTask`, each time the model's own text asks
  what its task is ("You've shared two files but haven't specified a task"), with a WARN. It isn't graded. The
  token test for a front-drop missed `wp-2b`'s rerun (2026-10-09): Ollama still had the first run's identical
  prompt cached, so the drop looked like a cache hit. Over the 523 committed and private transcripts the new check
  finds 9 lost prompts, 4 of which the token test missed, and no false alarms. `tests/test-context-events.ps1`
  covers it.
- `docs/roadmap.md`: "Local qwen3.6 on the work packages (2026-10-07)". qwen3.6 passed 7 of 12 with a 45-minute
  limit, 3 within 15 minutes, against Qwen3.7 Plus's 11 of 12. Four passes compacted and still finished. Three of
  the five failures stopped with work undone. A local-first split would have halved the Go bill for the same 11.
  `docs/costs.md` updated to match.
- `test-tasks.ps1`: writes outside the worktree are flagged. Every run JSON records `outsideWrites`, the
  write/edit/patch calls whose path resolves outside the task's worktree, and the console warns. It isn't graded.
  The scope gate and the guard rails see only the repo's diff, so a GLM-5.2 run's stray config in `%TEMP%` went
  unnoticed (2026-10-07). Shell commands aren't parsed. New guard `tests/test-outside-writes.ps1`.
- `test-tasks.ps1`: every run JSON records `runTimeoutSec`, the opencode run's time limit. The owner chose 45 minutes
  for the local seats on the work packages (2026-10-07): a slower right answer counts. A run that finished under
  15 minutes ends the same either way, so the hosted comparison holds.

- Results: the first hosted batches on the private real tasks (2026-10-06/07). Five OpenCode Go seats ran 3 LFCbot
  tasks and 12 work-package tasks: 47 of 49 graded runs passed before the plan's weekly limit stopped them.
  - 49 rows in `tests/results/real-tasks-public.tsv` (opaque task ids and verdicts only).
  - `docs/roadmap.md` → "Hosted seats on the real tasks": results next to the local seats, and what the failures
    show. No hosted run compacted. The local LFCbot failures were early stops and incomplete surveys, not
    context loss. `wp-5b`'s hidden tests enforce rules the contract only implies. Writes outside the worktree
    go unchecked (TODO).
  - `docs/costs.md` → "What a pass costs": cost per pass on the tasks four seats shared, from $0.06 (DeepSeek V4
    Pro) to $0.42 (Qwen3.8 Max).
  - The owner's decisions after the batches: `wp-5b` keeps its implied-rule tests; the orchestrator shortlist is
    DeepSeek V4 Pro and Qwen3.7 Plus; the first hybrid is built in OpenCode; the Go budget is deferred. The next
    deciding experiment is the local seats on the work packages.
  - Hermes Agent researched from its docs and parked (`docs/roadmap.md`, sources in `docs/references.md`).

- `run-tasks-batch.ps1`: hosted batches now respect OpenCode Go's plan-wide limits. Go meters every model together
  against one 5-hour, one weekly and one monthly limit; the owner's dashboard showed the week at 100% after the
  2026-10-06/07 batches.
  - `costs/go-plan.tsv`: the three limits, calibrated from the dashboard, in opencode's prices.
  - The batch reads this machine's Go use from opencode's records (`opencode db`, message table only), shows each
    meter before it starts, and stops every hosted seat once a meter is within `-PlanReserveUsd` ($0.50) of its
    limit. With no plan file or no readable usage, no hosted seat runs.
  - `docs/costs.md` → "Usage limits as observed": what the dashboard showed, including why the 402 reads
    "Insufficient account funds" (Extra Usage on, $0 credit).
  - Covered in `tests/test-hosted-seats.ps1`.

- `run-tasks-batch.ps1`: a hosted model refused by the provider (HTTP 402, OpenCode Go's "Insufficient account
  funds") is stopped for the rest of the batch; other models carry on. On 2026-10-06 the batch kept starting runs
  after the first refusal and 28 failed within seconds each. Covered in `tests/test-hosted-seats.ps1`.
  - Observed that night (`docs/costs.md` → "Usage limits as observed"): the refusals looked like one limit shared by
    all five models, not the per-model limits Go's docs describe.

- Costs: what model access costs, recorded next to what it achieves (`docs/costs.md`).
  - `costs/access.tsv`: what the owner pays, Claude Pro $20/month and OpenCode Go $10/month (checked 2026-10-06).
  - `costs/go-rates.tsv`: dated per-token rates and monthly allowances for the five Go seats.
  - Every run JSON records `usage` (tokens over all turns). A hosted run also records `costEstimate`.
  - New guard `tests/test-run-cost.ps1`.
- OpenCode Go seats: Qwen3.7 Plus, Qwen3.8 Max, Kimi K2.7 Code, GLM-5.2 and DeepSeek V4 Pro (owner's choice,
  2026-10-06).
  - All five passed a smoke test, a real file write through `opencode run --auto`
    (`tests/results/hosted-smoke.tsv`).
  - `run-tasks-batch.ps1 -Models hosted` runs them. A batch stops a model once it has spent 20% of its monthly
    allowance (`-SpendCapShare`, owner's rule), and shows the caps before it starts.
  - New guard `tests/test-hosted-seats.ps1`.

- `test-tasks.ps1`: the model's process can no longer push or open pull requests. Task worktrees are
  checkouts of the owner's real repos, signed in to git and gh, and the new stretch task replays the
  owner's "if there's anything worth PRing, do it".
  - For the opencode runs, network push URLs are rewritten to an unreachable host and gh gets an
    invalid token, through the environment only. The run JSON records `pushGuard`.
  - New guard `tests/test-no-push.ps1` (19 checks).
- `test-tasks.ps1`: `grading: "checklist"` for real tasks that a person rates against a written
  checklist: the large features and the stretch task built from the owner's real V0.6 opener.
  - Such a task runs like an acceptance task. Its row reads acceptance `MANUAL`, and the run JSON
    names the checklist.
  - New guard `tests/test-checklist-grading.ps1` (11 checks).
- The compaction-continue plugin loads once per project directory. Listed twice, for example in the
  global config and an overlay, two copies each sent an idle continue.
  - The live check runs opencode with an empty config home, so the installed copy stays out.
  - It now tries up to three ports, and fails rather than skips when an installed opencode can't
    start.

- Results: the daily configuration measured. It is five assisted `qwen3.6`
  runs with the installed plugin plus the compaction nudge, in
  `tests/results/compaction-daily/`.
  - `kane-07` PASS, plus a second run with the correct fix and a weak test;
    `asohav-02` PASS.
  - `kane-08` and `lfc-07` failed on the 8,192 output cap, not on stalls.
  - The roadmap records the parked `limit.output` trade-off (it moves opencode's
    compaction threshold).
  - `real-tasks-public.tsv` gets three daily-config rows (`qwen3.6` 0/3). A
    plugin on/off A/B, 8 of 8 PASS, cleared the plugin of that; it is kept
    private.
  - Also recorded: the `qwen3.5:9b` on node3 research (it fits only as the
    registry Q4, a different seat), now pulled to node3; and the two
    large-feature checklists drafted for the owner's review.

- Install the compaction-continue plugin for daily use: a `plugin` entry in
  `opencode/global/opencode.jsonc`, deployed with `sync-opencode.ps1
  -Template`.
  - Every desktop session has it from now on, harness runs included, with
    the idle continue off there. Benchmark rows from now on are a new era,
    marked by `opencodePlugins` in the run JSON.
  - Take it out by deleting the entry and re-syncing.

- opencode plugin `opencode/plugins/compaction-continue.js`, which keeps a
  session working after an automatic compaction without the owner having to
  type "continue". It is not installed in the live config; that is the
  owner's call.
  - **Rewrite:** the model is sent the nudge text plus the original request in
    place of opencode's "…or stop and ask" message.
  - **Summary:** the compaction prompt is asked to keep the original request.
  - **Idle continue:** a session that goes idle after a compaction, ending on
    prose with no tool call, error or question, gets the nudge text as a new
    message. Once per compaction, at most three per session, and never after
    the owner has written.
  - `test-tasks.ps1` records `opencodePlugins` and `compactionPluginRewrites`
    per run, and turns the idle continue off under `opencode run`.
  - New guard `tests/test-compaction-plugin.ps1`: node unit checks, the
    harness end to end, and a live check in the real `opencode serve` against
    a scripted stand-in model. It is pinned to opencode 1.18.34.
  - Trial of the rewrite and summary alone (5 runs,
    `tests/results/compaction-plugin/`): `kane-09` × `qwen3.5:9b` 2 of 2,
    `kane-07` × `qwen3.6` 0 of 3. Two of those three still stalled, which is
    why the idle continue exists.

- Fix: `-CommandTimeout` is enforced. Grading commands (test suite,
  acceptance tests, scoped typecheck) run through `Run-NativeTimed`, which
  ends the whole process tree at the limit (default 300 s). A hung suite is a
  FAIL ("suite timed out … a hang counts as a failure"), not a batch that
  stands still.
  - Found 2026-10-05, when a model's infinite loop in `signals.ts` kept vitest
    spinning for 2 h 20 min.
  - The child gets an empty stdin, and `cmd` metacharacters are quoted for
    `.cmd` shims.
  - New guard `tests/test-command-timeout.ps1` (19 checks).
  - `test-revert-source.ps1` and `test-task-env.ps1` load the new functions.

- Compaction-nudge diagnostic. `test-tasks.ps1 -NudgeAfterCompaction`
  sends a fixed continue message into the session of a run that stopped on
  prose after a compaction, at most one per compaction and two per run. The
  message keeps the owner's approvals.
  - Nudged runs are assisted: they are refused into `tests/results/` and
    recorded as `nudges`.
  - `Get-ContextEvents` adds `endedWithoutToolCall`.
  - New guard `tests/test-compaction-nudge.ps1` (26 checks).
  - Result (13 runs, in `tests/results/compaction-nudge/`): all 4 genuine
    stalls resumed once nudged. `qwen3.6` on `kane-07` went from 0 of 4 to 2 of
    3 passes. The common stall is a recap several steps after compacting, which
    the first trigger (within two steps) missed. The next limit is
    `limit.output`.
  - Next: an opencode plugin that does this inside the session, unassisted
    (above).

- Context overflow found and recorded. `qwen3.5:9b`'s "No user query found
  in messages" crash is a request over `num_ctx`, not a template bug:
  - opencode 1.18.34 decides to compact before counting the tool output a step
    added;
  - Ollama 0.34.3 then silently drops the oldest messages, task prompt first.

  Other seats lose their task silently in the same spot: `qwen3.6` on `kane-08`
  three times out of three, plus three 32k runs on 09-26. All 7 `qwen3.5`
  crashes are this, and none followed a compaction, correcting earlier
  write-ups.
  - `test-tasks.ps1` records `contextEvents` in every run JSON (compactions,
    ended right after one, front-drops, peak prompt, the compaction threshold),
    WARNs on a front-drop, and names the cause in a template crash's `_INFRA_`
    detail. Grading is unchanged.
  - New guard `tests/test-context-events.ps1`.
  - A trial that compacted earlier (`limit.input` + `compaction.reserved`) was
    not adopted: compacted runs pass 4 of 18, and the change would have
    compacted 15 more runs, 11 of them passes.
  - The roadmap's proposed workaround, a `qwen3.5:9b` without the template's
    `raise`, is withdrawn: it would hide the crash as silent task loss.
  - Docs: `docs/roadmap.md` → "Context overflow", corrections in place,
    `tests/results/README.md`, an AGENTS.md Gotcha and verification bullet, and
    three source citations in `docs/references.md`.

- Results: `qwen3.5:9b`'s second run of the 16 guided tasks (9 of 16 again; 18
  of 32 attempts against `qwen3.6`'s 22 of 31; all four crashes are the
  template error at 50–54k tokens), and runs 2 and 3 of the three real-prompt
  documentation tasks (`qwen3.6` 7/9, `qwen3.5:9b` 3/9). `docs/roadmap.md` →
  "The light seat overnight" and "Real-use tasks".

- Multi-turn tasks. A manifest task's `followUps` (fixed later turns, such as
  the owner's "go ahead" after a plan) are each sent with
  `opencode run --session <id>` into the same session and transcript.
  - The run is graded on the end state, edits count across turns, and the run
    JSON records `turns`.
  - The follow-ups are part of the prompt hash; single-turn hashes are
    unchanged.
  - A turn that cannot find a session id (exit -4) or fails is infrastructure:
    no row, `_INFRA_` transcript.
  - `Invoke-OpencodeRun` takes `-SessionId` and `-Transcript`.
  - New guard `tests/test-follow-ups.ps1` (20 checks, PowerShell 7 and 5.1),
    which also caught `Get-TranscriptSessionId` leaving the transcript open for
    the next turn's append.

- Harness support for real-prompt tasks built from the owner's own sessions
  (`docs/roadmap.md` → "Real-use tasks", owner decisions of 2026-10-04).
  `test-tasks.ps1` and `run-tasks-batch.ps1` take `-TaskManifest` and
  `-ResultsDir`; a manifest outside this repo is private and is refused
  without a `-ResultsDir` outside it too. New task fields:
  - `grading: "acceptance"`: hidden tests are the gate, and a run passes on
    scope + suite + acceptance;
  - `scope: "guardrails"`: no lockfile, `.env*`, CI or out-of-package edit,
    under file and line ceilings (`Test-Guardrails`);
  - `acceptance.dir`: hidden tests from a folder beside the manifest, placed
    only after the model's run;
  - `acceptance.solution`: `-DryRun` checks the hidden tests pass on the real
    fix;
  - `requireTest`: otherwise `failsOnOld` is `SKIP`, "not asked".

  Their rows go to `real-tasks-summary.tsv` in the results folder; a private
  run mirrors only opaque ids and verdicts to `tests/results/real-tasks-public.tsv`.
  Guided tasks are unchanged. New guard `tests/test-acceptance-grading.ps1`
  (49 checks, PowerShell 7 and 5.1). Both summaries carry `acceptanceHash`, a
  fingerprint of the hidden tests, because a check revised after a run makes
  its old rows incomparable.
- First real-prompt pilot (2026-10-04): three LFCbot documentation tasks from
  the owner's own sessions. Latest run per task: `qwen3.6` 2/3, `qwen3.5:9b`
  1/3. Rows are in `tests/results/real-tasks-public.tsv`, ids and verdicts only;
  `real-01`'s first two rows were graded by a superseded check.

- Light-seat overnight batch (2026-10-03/04): `qwen3:8b`, the main seat of
  three of the four live profiles, and `qwen3.5:9b` on every active task each
  had no graded row for. `qwen3:8b` passed 0 of 17 attempts (12 graded, 5
  timeouts; 1 of 47 graded runs on the desktop overall), changing only tests,
  leaving no net change, or repeating writes up to 108 times. `qwen3.5:9b`
  passed 9 of 16, the same tasks `qwen3.6` passes and mostly in 1–2 minutes,
  with 2 crashes from its chat template's `No user query found in messages`
  error at 50–54k tokens of context, a known property of the seat. No prompt
  was truncated. The roadmap's "Task set expansion II" records it and the
  re-seat question it raises (owner decision); `tests/results/README.md`
  notes that timeout transcripts have been kept since 2026-09-26.

- Second `qwen3.6` run of the 16 active new tasks (2026-10-03 evening, same
  versions and config as the first, 1800 s cap): 11 of 15 graded runs pass;
  `kane-08` hit the cap with no edit (no row). Across both runs 10 tasks pass
  twice, `asohav-07` and `asohav-09` once, and `kane-07`, `kane-08`, `kane-14`
  and `lfc-07` never. Recorded in the roadmap's "Task set expansion II".
- `failsOnOld` is now `SKIP` when the suite is already red with the model's
  change, and the source is not reverted: a suite that fails either way
  measures nothing. `asohav-07`'s second run left a test file that does not
  parse and recorded `failsOnOld: PASS` for it; 30 rows in all read
  `suite: FAIL, failsOnOld: PASS` that way (none is a pass; documented in
  `tests/results/README.md`). TSV parsers must tolerate `SKIP` in that column.
  New guard `tests/test-fails-on-old.ps1` (9 checks, PowerShell 7 and 5.1;
  fails 4 of them against the previous harness).

- Retire `asohav-05-library-write-validation` and `asohav-06-bond-cap-setting`
  (owner decision 2026-10-03). Their pins carry the asohav repo's ~280 KB
  `CLAUDE.md`, a file that existed for two days before the owner trimmed it to
  16 KB, so they measure a transient mistake that no 64k seat can see past, not
  daily use. New manifest field `retired` ({date, reason, see}): the task keeps
  its id, pin and rows; `test-tasks.ps1` and `run-tasks-batch.ps1` leave it out
  of a no-argument run, `-Tasks all` and the picker, and refuse it by name
  unless `-IncludeRetired`. The roadmap records the way back (new ids on the
  pin plus the first trimmed `CLAUDE.md`, `47bf270`) and the open question of
  how tasks should treat a repo's instruction file. Guarded by
  `tests/test-retired-tasks.ps1` (27 checks, PowerShell 7 and 5.1).
- First model run of the 18 new tasks: `qwen3.6` (desktop, Ollama 0.34.3,
  opencode 1.18.34, 64k, CPU companion), 18 runs plus a follow-up of four at an
  1800 s cap. 11 of 16 valid graded runs pass every gate; the failures are one
  test that does not catch its bug (`kane-14`), two output-cap hits (`lfc-07`,
  `asohav-09`) and two long-context losses (`kane-07` overflowed into OpenCode
  compaction, `kane-08` lost the task at 46k tokens). Four rows (`asohav-05`/
  `-06`, twice each) measured nothing: the repo's ~280 KB `CLAUDE.md` at those
  pins made the first request ~83k tokens and Ollama truncated it to 32,770,
  dropping the system prompt, tools and task. Recorded in
  `tests/results/README.md` ("Prompt truncated by Ollama") and the roadmap's
  "Task set expansion II". `test-tasks.ps1` now detects that case from the local
  Ollama log (`Get-OllamaPromptTruncation`: exit -3, `_TRUNCATED_` transcript,
  no row) and records `promptTruncation` and an engine-neutral `servingEngine`
  in every graded run JSON, ahead of the planned move off Ollama. New guard
  `tests/test-prompt-truncation.ps1` (24 checks, PowerShell 7 and 5.1).
- `opencode <profile>` from any PowerShell (owner request 2026-10-03):
  `desktop/scripts/opencode-profiles.ps1` defines an `opencode` function that
  sends a live profile name (full, or without `dev-workflow-`/`dev-`, any case)
  to `desktop/scripts/opencode.ps1` and everything else to the real opencode
  untouched; `install-opencode-profiles.ps1` adds one guarded line to the
  PowerShell 7 and 5.1 profiles (`-Uninstall` removes it). The launcher now
  unloads the desktop models the profile does not use and waits for them to go
  before warming (`-KeepLoaded` skips; profiles with no desktop seat leave the
  desktop alone), restores the shell's env when opencode exits, calls the real
  opencode explicitly, and `-ListProfiles` lists every live profile, not only
  `dev-workflow-*`. Guarded by `tests/test-opencode-profiles.ps1` (22 checks,
  PowerShell 7 and 5.1). Live: quality → resident → quality left exactly each
  profile's two models in `/api/ps`; the first try logged one `evicting` line
  because Ollama acknowledges `keep_alive: 0` before the memory is free, and
  after the wait the repeat logged none.
- `dev-workflow-quality` no longer starts the Docker dev stack at login
  (`DEV_DOCKER_STACK=false`; owner decision 2026-10-03). `qwen3.6` holds far
  more system RAM than documented: Ollama maps the whole 20.3 GB model file
  (`CPU_Mapped`), GPU part included, and the process held 16.56 GB private
  beside the companion's 2.40 GB, ~3.5 GB of 32 GB left. With the stack up
  (WSL's VM 2.1 GB) available memory fell to 0.55–1.1 GB, the model paged at
  4k–19k hard page-ins/s, and the re-run of the companion driver was killed
  for low memory 85 s into its first turn. RAM figures corrected in the
  profile header, `AGENTS.md`, `docs/profiles.md`, `docs/start-here.md`,
  `startup.ps1`'s comment and `docs/main-seat-trial.md` (new "Follow-up"
  section). Start the stack by hand with `docker-stack.ps1 up`.
- A dead job host no longer ends a task batch. On 2026-10-02 the PowerShell
  process of the background job running `opencode` died under run 1 of 16
  (`kane-01` × `devstral-small-2:24b`); `Receive-Job` raised
  `PSSessionStateBroken`, the script's `Stop` made it terminating, and the
  other 15 runs never started. Had it not thrown, the empty result would have
  defaulted to exit -1 and been archived as a `_TIMEOUT_`. `Invoke-OpencodeRun`
  (`tests/test-tasks.ps1`) now reports it as an infrastructure FAIL (exit -2,
  `_INFRA_` transcript, no summary row) and kills any orphaned opencode
  (`Stop-OrphanOpencode`, shared with the timeout path). PowerShell 7 never
  ends such a job, so the wait is now 5 s slices with a check that the job's
  PID (its first output) is alive. `tests/run-tasks-batch.ps1` also catches
  any exception out of a run, records it as `crash`, and continues. New guard
  `tests/test-opencode-run.ps1` (12 checks, PowerShell 7 and 5.1) kills the
  job's process for real; against the old code it reproduces the crash.
- Desktop keep-alive is 4h (User env `OLLAMA_KEEP_ALIVE=4h`, owner decision
  2026-10-03; was Ollama's 5m default, under which an idle `qwen3.6` reloaded
  and re-prefilled for 2–3.5 min). Confirmed live as `OLLAMA_KEEP_ALIVE:4h0m0s`
  in `server.log` after a restart. `desktop\scripts\opencode.ps1` now
  pre-loads the profile's desktop main seat in the background at launch
  (`-NoWarm` skips it). It warms the main seat only: warming the CPU companion
  as well let it load first, and `qwen3.6`'s load then evicted it, so it
  loaded twice; cold-start test after the fix: 0 evictions, both models
  expiring 4h out. Recorded in `AGENTS.md` (Gotchas), the quality profile,
  the roadmap's decision list and `tests/results/README.md` ("Era
  confound": durations across the date are not comparable; verdicts are).
- Re-seat `dev-workflow-quality`: the main seat is `qwen3.6:35b-a3b-coding`
  (was `qwen3:14b`, seated 2026-09-17) and the small model is
  `qwen2.5-coder-3b-cpu` (was `qwen2.5-coder:3b`), per the main-seat trial
  and its companion experiment (`docs/main-seat-trial.md`). `startup.ps1`
  derives the companion from the 3b with `num_gpu 0` (`$derivedModels`, after
  the context bakes) and lists it in its context contract;
  `DEV_DESKTOP_MODELS` gains `qwen3.6`; `test-profiles.ps1`'s intent manifest
  moves with the profile. `AGENTS.md`, `docs/profiles.md`,
  `docs/start-here.md`, `docs/troubleshooting.md`,
  `docs/model-architecture.md`, the roadmap's standings label and the model
  comments and display names in `opencode/global/opencode.jsonc` now name
  the new seat; dated history is unchanged. Not measured: the pair beside a
  game, and beside the Docker dev stack (the experiment ran with WSL
  stopped).
- Close the main-seat trial and pre-register its second experiment
  (`docs/main-seat-trial.md`). `qwen3.6:35b-a3b-coding` meets the re-seat
  bar (zero FAILs, three CLEANs; the control can reach two at most), so the
  four open cells were not run. The trial-day Ollama logs show `qwen3.6`
  spills to system RAM and takes every GPU byte, the 3b companion runs once
  per session (titles) and evicts it then, and keep-alive reloads cost more
  (2–3.5 min first replies). Option B (a 32k re-measure) is ruled out; option
  A, the same 3b pinned to the CPU (`qwen2.5-coder-3b-cpu`, registered in
  `opencode/global/opencode.jsonc`, built by hand), runs first against a
  five-criterion pass bar on a clean desktop; option C, documented eviction
  acceptance, is the fallback. No profile changes until it passes.
  `OLLAMA_KEEP_ALIVE` is added to the roadmap's owner decisions.
  **It passed, 5 of 5 (2026-10-03):** across three sessions (15 turns) no
  eviction, `qwen3.6` loaded once and kept 12.51 GB of VRAM throughout, the
  companion stayed at 0 GB VRAM, and titles took 3.4 to 14.8 s. Driven with
  `opencode run` instead of the TUI (owner away), recorded as a deviation.
- Add 18 benchmark tasks mined from the owner's repos, so the suite is 27:
  `kane-07` to `kane-14`, `lfc-04`, `lfc-05`, `lfc-07` and `asohav-03` to
  `asohav-09` (the 15 candidates that fit the harness plus `kane-14`, `lfc-07`
  and `asohav-05`, which needed the multi-file `srcRevertFiles` fix). Each is a
  real merged fix pinned at its fix commit's parent, and 15 carry an
  `acceptance` block whose oracle is the upstream fix commit's own test file.
  New shapes: two-source-file fixes, brand-new test files, spec reversals,
  React component and hook tests, a symptom-only data-conformance prompt. Every
  entry ran through the real `test-tasks.ps1` with a stand-in `opencode` in a
  fresh worktree: the baseline equals `baselineExpect`, the upstream tests fail
  on the untouched base, the reference fix passes every gate, the fix without
  tests fails failsOnOld, the tests without the fix fail scope and suite, and
  the gate results are identical across four environments and three repeats.
  `asohav-05`, `asohav-07` and `asohav-08` pin `DATABASE_URL` (the `asohav-02`
  rule). `docs/roadmap.md` → "Task set expansion II" has the table, the parts
  the upstream tests do not pin, and the 11 candidates not added.
- failsOnOld no longer uses `git stash`. `refs/stash` belongs to the repository,
  not to a worktree, so two tasks of one repo graded at the same time popped
  each other's stashes (found independently by three of the agents validating
  the new tasks: `stash pop failed`, then an acceptance run against reverted
  source). `Invoke-WithSourceReverted` saves the model's source bytes, checks
  the files out of the pinned base (not `HEAD`, so a model that commits still
  reverts to the pin) and writes the bytes back, touching nothing outside the
  worktree. The gate verdicts were already decided before the pop, and the six
  same-repo overlaps in the corpus (2026-09-23, `kane` tasks) finished at least
  85 s apart, so no recorded verdict is known to be affected.
  `tests/test-revert-source.ps1`, 46 checks (one-file, two-file and bare-string
  `srcRevertFiles`, non-text bytes restored byte for byte, a path the base
  lacks, a model that committed, two worktrees of one repo held open together),
  replaces `test-stash-args.ps1`; six mutants of the mechanism (the old stash,
  nested-array arguments, a text restore, `HEAD` instead of the pin, no restore,
  a revert that reaches the tests) each fail it. A second battery of the 18 new
  tasks against the new harness ran six lanes at once, two per repository, and
  reproduced all 72 runs of the first (the sequential one) exactly.
- Harness: a pinned acceptance commit this clone does not have yet is fetched
  from `origin` once before it is called missing (`Resolve-AcceptanceCommit`,
  as `Resolve-TaskBase` already did for a base), and `run-tasks-batch.ps1
  -SetupOnly` fetches for it too. Groundwork for tasks mined from upstream fix
  commits, whose acceptance oracle is the fix commit's own test file: it is on
  `origin/main` but not necessarily in an older clone. `test-task-pins.ps1`
  gains five checks (a base pin and an acceptance pin that are upstream but not
  yet local, an acceptance pin that exists nowhere; the acceptance ones fail
  against the previous harness) and its real-checkout step now resolves pins
  through the harness's own resolvers. `test-task-env.ps1` gains a guard that
  every ASoHaV `apps/server` task pins `DATABASE_URL` (`asohav-01` is exempt:
  it pre-dates the rule and its recorded rows do not depend on it).
- `Get-PublishState` (`run-tasks-batch.ps1`) sets `$ErrorActionPreference =
  "Continue"` for itself. Its git probes write to stderr in normal operation (a
  commit origin lacks is "not our ref"; a local origin warns that it ignores
  `--filter`), and under a caller's `"Stop"` Windows PowerShell 5.1 turns that
  into a terminating error. The batch itself runs under the default, so the
  real `-SetupOnly` was unaffected; `test-task-pins.ps1` (which sets `"Stop"`)
  failed on 5.1 at "a commit that was pushed", and passes on 5.1 and 7 now.
  Found by the first run of the regression tests on Windows PowerShell 5.1.
- Pin each benchmark task's test environment. `tests/tasks/manifest.json` gains
  an optional `testEnv` (variable → value, `null` = unset) that `test-tasks.ps1`
  applies to the test command and to the model's own `opencode run` process,
  restores afterwards, and records in the run JSON (`Set-TaskTestEnv` /
  `Restore-TaskTestEnv`, used by `Invoke-Test` and around the `opencode` call).
  `asohav-02` pins `DATABASE_URL` to unset: a model-written test that imports
  the real `repo.ts` imports `pgPool.ts`, which throws at import without it, and
  the harness process had the variable on 2026-09-29 but not on 09-27, so the
  two `qwen3.6` passes of 09-29 load only where it is set. `lfc-02` pins
  `MANAPOOL_API_KEY` to unset (the flake its prompt already warns about). New
  `tests/test-task-env.ps1`, 50 checks: the manifest entries, the real
  set/restore functions and `Invoke-Test`, and the real `test-tasks.ps1` run end
  to end against a fixture repo with a stand-in `opencode` (three tasks in one
  run: the model's process, the gates and the run JSON see the pins, and the
  next task does not). Sixteen mutants (scratch copies) each fail it.
- Record a second replay of DP12's 12 passes (`docs/implementation-tasks.md` →
  DP12 addendum), this time with the gates re-run and the project's own fix
  commit as an oracle. All 12 gates reproduce and all 12 sources are right
  against tests the models never saw; three of DP12's classifications differ
  (kane-04 × `qwen3.5` rep 1 asserts no warning, both lfc-03 passes never test
  `expired`, both asohav-02 passes need `DATABASE_URL`), so 5 clean and 7
  qualified rather than 10 and 2. `docs/roadmap.md` carries the consequence for
  the `qwen3.6` lead: 12/15 and Fisher p = 0.30 over `qwen3.5` if the asohav-02
  passes are counted as a clean checkout would count them.
- Main-seat trial: control task 3 FAIL (`qwen3:14b` on `9060ae9`, same base
  as the candidate: edit-first, false truncate claim over dead code, an
  unprompted reject→truncate contract change with the specifying test
  rewritten to fit, and a self-contradictory suite report against a real
  356/356). Control stands at 0 CLEANs across tasks 1 and 3, so the
  candidate's bar clearance (3 CLEANs, 0 FAILs) no longer depends on any
  outstanding cell. Remaining: control tasks 2 + 4, `qwen3.5` tasks 2–4,
  then the second experiment's pre-registered pass bar.
- Main-seat trial: all four `qwen3.6` cells graded (task 1 CLEAN, task 2
  CLEAN on the corrected `170b395` base after a VOID run on `4906dc2`,
  task 3 QUALIFIED, task 4 CLEAN with a retracted fixture-trap claim).
  Session rows in `docs/main-seat-trial.md`; control cells still open.
  Parks the alert-first TUI session watchdog (`docs/implementation-tasks.md`
  item 10): the task-4 session stalled 6+ min mid-loop needing a manual
  kick, and batch timeouts already cover non-interactive runs.
- lfc-03's acceptance commit `3215aaf` is published
  (`bench/status-guard-throw` pushed to `mkane848/lfc-bot`; a from-scratch
  fetch resolves), so every benchmark pin is on GitHub. Corrects the
  "local-only" wording in this changelog, `AGENTS.md` and `docs/roadmap.md`.
- Record data point 12 (`docs/implementation-tasks.md`): replay audit of the
  12 unaudited N>1 passes (PRs #62–#64), closing DP11's caveat. 10 genuine
  and spec-complete; 2 qualified with grades standing (lfc-02 × `qwen3.5`
  rep 1 ships a hardcoded `0.0.0` User-Agent version against a real 1.5.0,
  rep 2 deletes a used type import into a typecheck-SKIP task). No hollow
  passes; the standings are strengthened, not revised.
- Pin every benchmark task's base commit, so a moved branch cannot change a
  base under the corpus. `kane-01`, `lfc-01` and `lfc-03` ran from the tip of a
  local branch (a work branch, and `main`); every recorded row had happened to
  use one commit per task, and those are now `benchBaseCommit` in
  `tests/tasks/manifest.json`, with `bench/*` branch labels like the other six.
  - `test-tasks.ps1` `Resolve-TaskBase`: the worktree is made from the pinned
    SHA, not from `refs/heads/<branch>`. A local branch elsewhere is a WARN; a
    pin missing from the repo is an error naming the `git push` that fixes it; a
    task without a pin still uses the branch tip.
  - `run-tasks-batch.ps1 -SetupOnly` warns when a pinned base or lfc-03's
    acceptance commit is not on origin (`Get-PublishState`), with the push
    command. `git ls-remote` and a by-SHA fetch into an empty repo show **all
    nine pinned bases are on GitHub**: eight on `main`, `kane-01`'s `92a8ed0` as
  `review-gate/deck-validity` and PR #82's head. lfc-03's acceptance commit
  `3215aaf` (`bench/status-guard-throw`) was the one local-only pin — pushed
  2026-09-30 (`git -C M:/Projects/LFCbot push origin bench/status-guard-throw`;
  a from-scratch fetch of the SHA resolves), so every pin is now on GitHub.
  - lfc-03's acceptance tests are pinned by `acceptance.commit`
    (`Resolve-AcceptanceCommit`): all 18 recorded acceptance runs used
    `3215aaf`, and a branch that has moved is a WARN, not followed.
  - The first version of this entry said `kane-01`'s base was local-only. That
    was wrong: the check ran in single-branch clones, which show `main` only.
    `Get-PublishState` now asks origin itself from an empty scratch repo,
    because `git fetch origin <sha>` inside a clone that already has the commit
    exits 0 without asking anyone; it also finds a commit only a pull-request
    ref reaches.
  - New `tests/test-task-pins.ps1` (42 checks): manifest pins, all 218 rows and
    all 18 acceptance runs used them, and the three functions on throwaway repos
    (including the two shapes that fooled the first version); it fails on 14
    mutants. `AGENTS.md` and `docs/roadmap.md` (the 2026-09-30 correction, the
    setup section) updated.
- Hold benchmark replicates to one opencode version and spread them across time.
  opencode installs patch releases by itself when a TUI starts (never from
  `opencode run`; read from upstream at `2fa3363`), and the results corpus took
  1.18.31, .32 and .33 in ten days. Split by version, all 8 disagreeing
  replicate pairs are cross-version (8 of 19; 0 of 11 back-to-back, 0 of 2
  same-version other-session), so version cannot be told from session.
  - `docs/adversarial-review-2026-09-29.md` §7: a same-config attempt shares
    prompt sha, `numCtx`, Ollama version **and** opencode version.
  - `run-tasks-batch.ps1`: reps run rep-outer within each model (`-BackToBack`
    for the old order); the batch reads `opencode --version` at the start and
    stops if it changes; the preflight reports whether autoupdate is pinned.
    New `tests/test-batch-plan.ps1` (27 checks; fails on seven mutants).
  - `opencode/global/opencode.jsonc`: `autoupdate` `true` → `"notify"`. **The one
    behavior change:** OpenCode no longer upgrades itself; run `opencode upgrade`
    on purpose, between batches. Revert that line to keep autoupdate on; the
    drift stop still protects a batch.
  - `docs/roadmap.md` → "By opencode version": the seat order is the same on
    both versions (`qwen3.6` 8/9 then 6/6, `qwen3.5` 7/9 then 6/12, `qwen3:14b`
    2/9 then 0/4); on the frontier cells at 1.18.33 `qwen3.6` is 6/6 to
    `qwen3.5`'s 2/6 (p = 0.061). No seat decision moves.
  - New `docs/references.md` rows for the opencode source and docs read.
- `test-tasks.ps1`: the writes gate tells an output-cap hit from liar mode. An
  exit-0 run with no write whose last step is an empty `length` step at
  `limit.output` (no text, no tool call) is reported as "NOT liar mode: the
  seat ran out of room to act", and the run JSON records `outputCapHit`,
  `finishReason`, `lastStepOutput` and `outputLimit` (read from `opencode debug
  config`; an unreadable limit degrades to "cannot confirm a cap"). Both are
  still FAILs, and the `tasks-summary.tsv` schema is unchanged. A `length`
  stop that cannot be confirmed as the cap (limit unreadable, or the stop came
  below it) gets its own "truncated" message instead of the liar-mode one. A
  run that makes edits and then hits the cap keeps its PASS, with a note. New
  `tests/test-cap-hit.ps1` runs the real functions and the real gate block on
  synthetic transcripts and 8 committed ones the 2026-09-29 audit classified;
  it fails on eight mutants (four of the classifier, four of the gate wiring).
  A scratch re-derivation over all 31 exit-0 zero-write rows gives the audit's
  split (8 cap hits, 23 genuine). Also fixes two docs that still called
  `ornith:9b`'s cap hits liar mode (`docs/target-setup.md`,
  `docs/implementation-tasks.md`).
- `test-tasks.ps1`: grade tasks that list two or more `srcRevertFiles`. The
  failsOnOld revert built its `git stash push` arguments with the file list
  nested inside the array; `Run-Native`'s `[string[]]` parameter joined it into
  one argument (`a.ts b.ts`), git rejected the pathspec, and every model would
  have got "git stash push failed - cannot grade" on such a task. All nine
  current tasks list one file, so it never fired. New
  `tests/test-stash-args.ps1` runs the real line against a throwaway repo (one
  file, two files, bare string); it fails on the old code and passes now.
- Correct claims the data no longer supports (docs and comments only, no
  behavior change), from a recheck against `tests/results/`:
  - "Only the qwen3 family can call tools / 5 of 13 pass" (`AGENTS.md`,
    `README.md`, `docs/start-here.md`, `docs/troubleshooting.md`,
    `docs/profiles.md`, `docs/model-architecture.md`, two profile comments, two
    test-script comments): 13 of 22 probed models pass (Ollama 0.34.2/0.34.3), and a
    probe PASS is necessary, not sufficient (`lfm2.5:8b` passes, then makes zero
    writes on 8 of 8 tasks). `AGENTS.md` also says the configured main seat is
    not the best-measured one.
  - Stale `num_ctx` figures in `AGENTS.md` and `README.md` now match
    `startup.ps1` `$contextModels` (65536 for six seats, 32768 for the qwen3
    pair and devstral pair).
  - `tests/results/README.md`: update banner (218 rows, 81 passes), an
    opencode-version era axis, a correction that the control rematch ran, and a
    correction that 8 of the 31 zero-write rows since 2026-09-22 are output-cap
    hits (`nemotron` 4/6, `ornith` 3/4, `qwen3:8b` 1/1), not liar mode.
    `AGENTS.md` Gotchas gains the same warning.
  - `docs/roadmap.md`: the source repos are public (not "private"); the
    `bench/*` branches are local-only (not "verifiable by anyone"); a status
    note on the 2026-09-23 "Next up" list.
  - `docs/adversarial-review-2026-09-29.md`: dated addendum correcting five
    statements against the raw rows (control rematch had run, task difficulty
    figures were the 09-23 inventory, liar-mode list, N=1 confirmed,
    protocol config key).
- Record data point 11 (`docs/implementation-tasks.md`) and the same-config
  executor standings (`docs/roadmap.md`): the adversarial review's N>1
  protocol on the frontier cells (PRs #61–#64, desktop Ollama 0.34.3). Counted
  on one config (prompt sha, designed `numCtx`, timeouts as attempts),
  `qwen3.6` passes 14/15 attempts, `qwen3.5` 13/21, `qwen3:14b` (the default
  main seat) 2/13; `qwen3.6` against `qwen3.5` is Fisher p = 0.051, against
  `qwen3:14b` p = 0.0001.
  - None of the 9 graded FAIL rows is a zero-write. Of the 18 lfc-03 runs with
    an owner acceptance result, 12 pass it and 8 pass every gate.
  - Replicates are not independent evidence: back-to-back pairs agreed 11 of
    11, pairs from different batches disagreed 8 of 21 (p = 0.03), and every
    mixed cell straddles opencode 1.18.32 and 1.18.33.
  - The replay audit of the 12 new passes was not done. No seat or config
    changes.
- Adversarial review of the testing methodology
  (`docs/adversarial-review-2026-09-29.md`): what each harness measures,
  N=1 / era-confound / guided-repair limits, plus the N>1 protocol
  (frontier tasks × top-2 challengers + control, 2 fresh reps each,
  per-attempt reporting, no seat decisions until it reports).
- Record data point 10 (`docs/implementation-tasks.md`), two decision tests
  for open seat questions.
  - north-mini, 32k vs 64k on lfc-01: 0/4 PASS, and no `/workspace` at
    either size. Context size isn't the fix.
  - Write-discipline canary: `qwen3.6` and `qwen3.5` 3/3, `qwen3:14b` 2/3
    (one double write). `qwen3.6` waits about 2 minutes before the first
    reply of every session.
  - Corrects DP9's north-mini count: `/workspace` in 4 of 9 runs at 64k, not
    3 of 5.
  - New `tests/results/reliability-summary.tsv`, plus 3 graded runs, 1
    timeout transcript and 3 `tasks-summary.tsv` rows. The temporary
    `north-mini-code-1.0-32k` tag is removed.

- Record data point 9 (`docs/implementation-tasks.md`): step 6's other 6
  tasks × 8 desktop seats (six at 64k, the qwen3 control pair at 32k).
  **26/48 PASS**; 64k seats 24/36, 32k seats 2/12. Across all 9 tasks:
  `qwen3.6` 8/9, `qwen3.5` 7/9, `qwen3:14b` (the default main seat) 2/9.
  - All 26 passes were audited beyond the gates. No test was removed, and 3
    passes met the gates while covering less than the prompt asked.
  - New ungraded shape: an output-cap truncation that ends in the Qwen
    template 400 without any compaction.
  - 64k passes ran a median 37% faster than matching 32k passes.
  - 86 result files, 5 timeout/infra transcripts and 43
    `tasks-summary.tsv` rows are archived.
  - `docs/roadmap.md` gains "Executor standings after step 6", with the
    re-seating case and its preconditions. Nothing is re-seated yet.

- Retire LM Studio. VS Code's BYOK registry now has one provider, desktop
  Ollama, with every desktop seat (the 10 tool-capable seats + the
  `deepseek-r1:14b` reviewer), budgets mirrored from `opencode.jsonc`
  (`maxInputTokens` + `maxOutputTokens` = served `num_ctx`; the old
  entries declared the whole window as input). `docs/lmstudio-vscode.md` is
  now `docs/vscode.md`, rewritten Ollama-only; links and current docs
  updated; dated 2026-09-18/19 run records still say what they ran on.
  `opencode.jsonc`'s three import comments now say "local GGUF" instead
  of LM Studio.

- 64k context trial: `qwen3.5:9b`, `qwen3-coder:30b-a3b`, `north-mini-code-1.0`,
  `laguna-xs-2.1`, `qwen3.6:35b-a3b-coding` and `nemotron-3.5-lightning` go to
  65536 in `startup.ps1` `$contextModels`, `opencode.jsonc` `limit.context`
  and `models/catalog.tsv`. The devstral pair and the qwen3 dense pair stay at
  32768. Acceptance rule in `docs/roadmap.md` → "Context budget".
- `test-tasks.ps1`: stamp `numCtx` (the served model's baked `num_ctx`, from
  `/api/show`) into every result JSON and the header line, so runs at
  different context sizes can be told apart.
- Record data point 8 (`docs/implementation-tasks.md`): the 64k trial re-ran
  lfc-03, kane-02 and asohav-02 on the six raised seats — **9/18 PASS vs 3/15
  at 32k** for the same seats; timeouts 3 → 1, context deaths 3 → 1. First
  local asohav-02 passes (`laguna-xs-2.1`, `qwen3.5:9b`). All 9 passes
  audited beyond the gates (no assertion removed); lfc-03's two typecheck
  WARNs reproduced (laguna: a real `string`-index error in source;
  qwen3-coder: test-only). Roadmap acceptance criterion met; 64k adopted for
  the six seats. 34 result files + 16 `tasks-summary.tsv` rows archived.

- Record data point 7 (`docs/implementation-tasks.md`): step 6's frontier
  slice — lfc-03, kane-02 and asohav-02 × the desktop seats. First local
  passes: lfc-03 2/8 (`laguna-xs-2.1`, `qwen3.6:35b-a3b-coding`, both 29/29
  owner acceptance), kane-02 1/9 (`laguna-xs-2.1`); asohav-02 stays 0/14.
  Three more lfc-03 seats wrote an acceptance-correct fix but failed a gate on
  their own tests. Four ungraded runs were context overflow (OpenCode
  compaction), not infrastructure. Memory-pressure-contaminated timeouts are
  marked superseded. 36 result files, 13 timeout/infra transcripts, 18
  `tasks-summary.tsv` rows archived.
- `test-tasks.ps1`: create the transcript file before the run starts, so a
  timeout with zero events leaves an empty `_TIMEOUT_` transcript instead of
  nothing; decode opencode's stdout as UTF-8 inside the job (non-ASCII text
  in transcripts was OEM-codepage mojibake).
- `docs/roadmap.md` → "Context budget: 32k vs 64k per seat": measured KV,
  CPU offload and generation speed at both sizes for the 10 desktop seats.
  Hybrid/SWA/MoE seats cost under 1 GB; the dense `devstral` pair loses ~30%
  generation speed; `qwen3:8b`/`qwen3:14b` are capped at 40,960 by their
  training context. Trial proposed, not adopted.

- Record data point 6 (`docs/implementation-tasks.md`): oracle sweep —
  `opencode-go/qwen3.8-max` PASSes all 8 remaining manifest tasks on the same
  prompt shas as the local corpus (9/9 with DP5). Every task is passable as
  written; kane-02, asohav-02 and lfc-03 still have no local PASS. Test diffs
  audited beyond the gates (kane-01's removed lines strengthen the PR #82-trap
  test). 16 result files + 8 `tasks-summary.tsv` rows archived.
- `docs/roadmap.md` → fine-tuning: replace the stale "zero successful
  trajectories" gate with the current state (9 oracle trajectories, 22 local
  PASSes) and the next gate — a held-out split, since training on the 9
  benchmark tasks and grading on them would measure recall, not capability.

- Record blind-trial data point 5 (`docs/implementation-tasks.md`): Accelerator
  A — `opencode-go/qwen3.8-max` on `lfc-03-status-transition-guard`, same
  prompt sha as DP4's write arm (`4A1266C4478E`) — **PASSes all four gates**
  (3 writes, 320 s, suite 30/30, fails-on-old catches all 5 forbidden
  transitions, typecheck clean) and 29/29 on the owner's acceptance tests.
  Step 5's DoD is met. Result files + one `tasks-summary.tsv` row archived.
- Owner acceptance tests for `lfc-03` (`LFCbot` `bench/status-guard-throw` @
  `3215aaf`, on GitHub since 2026-09-30) assert the prompt's error contract — id, current
  and requested status in the message — instead of a `/cannot .* from/`
  phrasing that failed a spec-compliant guard with other wording.
- `test-tasks.ps1`: informational owner-acceptance check. A task's
  `acceptance { ref, files }` block is swapped in over the model's tests after
  the four gates and the model's files are restored byte for byte; the result
  (status, ref, exact commit) lands in the per-run JSON only — never a gate,
  TSV schema unchanged. Under `-DryRun` those tests must fail on the untouched
  base. `lfc-03` carries the block.
- `test-tasks.ps1` harness honesty (step 8a/8c): transcripts stream to disk as
  events arrive, so a timeout keeps a `_TIMEOUT_` transcript; orphaned
  `opencode` children are tree-killed on timeout; the closing line reports the
  real appended-row count instead of always claiming "Summary appended"; the
  `ollamaVersion` field is the serving host's `/api/version` (`n/a` for hosted
  providers) instead of the local binary.
- `tests/tasks/manifest.json`: drop a trailing comma after `lfc-03`'s prompt
  that strict JSON parsers rejected (PowerShell 7 tolerated it).

- Record blind-trial data point 4 (`docs/implementation-tasks.md` → "New open
  follow-ups"): the first `lfc-03` executor attempt through the harness.
  Accelerator B delivered as `-EditFormat write|edit` on `test-tasks.ps1`.
  Both A/B arms on `ollama-desktop/qwen3:14b` FAILed: arm A (write) made the
  guard change (scope/suite green, one whole-file `write`) but never authored
  acceptance tests — **fails-on-old FAIL**, the exact trap DP4 documents; arm
  B (edit) timed out at 1800 s and its transcript was again unarchived (the
  "Summary appended but appends nothing" gap). Corpus: two result files +
  one `tasks-summary.tsv` entry archived. Step-5 DoD met on execution but NOT
  on grade — Accelerator A (the `opencode-go/qwen3.8-max` oracle run of the
  exact order) is queued with owner approval 2026-09-25.
- Add `-EditFormat write|edit` to `tests/test-tasks.ps1`: appends a whole-file-
  write vs substring-search-replace directive to the task prompt (part of the
  hashed prompt, so each arm records a distinct sha). Implements the
  edit-format A/B accelerator (`docs/methodology-research.md`); the first A/B
  executor attempt on `lfc-03-status-transition-guard` is docketed.
- Record blind-trial data point 3 (`docs/implementation-tasks.md` → "New open
  follow-ups"): Plan mode killed the live-checkout violation but stalled the
  seat — contract step 4 needs a write (the only one in the whole prompt), Plan
  mode denies it, and `qwen3.6` resolved the contradiction by compacting 5×
  into the forbidden summary template and asking new questions instead of
  emitting `## Work orders`. Resolved by drafting the order outside the seat:
  the DP3 interview answers become the `lfc-03` contract, docketed below.
- Docket the first real step-5 work order as a new task
  `lfc-03-status-transition-guard` (`tests/tasks/manifest.json`): a
  status-transition matrix for LFCbot `setStatus` that supersedes the
  silent-no-op contract of `lfc-01` (only `active` may originate a terminal
  transition, `fulfilled → deleted` stays legal, everything else throws per
  `createListing`'s convention). Acceptance block authored + verified
  failing-first outside the seat on LFCbot bench branch
  `bench/status-guard-throw` (`fcf9d1a`): 24/29 on unguarded `main` (baseline
  21 kept green), 29/29 with a candidate guard, full suite 343/343, scoped
  tsc clean. `lfc-01` keeps its older contract and history.
- Add `docs/references.md` (catalog of every external source cited in the docs
  + the citation convention) and `docs/methodology-research.md` (2026-09-24
  sanity-check writeup: methodology verdict, two accelerators — spend the
  hosted-calibration key and run the edit-format A/B — and community resources
  mapped to the measured gaps: SWE-Edit, aider edit-format analysis, the QCoda
  engine-model bake-off, terminal-agent context management). `AGENTS.md` now
  requires inline citations for externally-grounded claims and a
  `docs/references.md` row in the same change; `docs/README.md` indexes both
  new pages.
- Rewrite `docs/implementation-tasks.md` step 5 as "blind trial v2"
  (2026-09-24): data points 1+2 consumed, the `ses_f2ef…` recovery thread is
  void, and the launch is Plan-mode-first (Step 0 — the DP2 mechanical fix).
  Owner locked three decisions: target = DP2's own finding (the `setStatus`
  guard at `listings.ts:297-301`), calibration key spent on the produced order
  once it exists (accelerator A), and the edit-format A/B packaged as the
  first executor attempt (accelerator B).

- Expand `docs/implementation-tasks.md` → "Next steps" into the ordered
  2026-09-24 plan (steps 5–9, each with a definition of done): blind trial
  first (recover `ses_f2ef…` with the mission line, small target,
  failing-first acceptance), then control rematch + 1800 s offloader reruns
  on disjoint task sets, `qwen3.5:9b` to N=3 + node3 Q4 probe-then-batch,
  harness honesty fixes before the next results PR (streamed `_TIMEOUT_`,
  kill-vs-cap tags, per-host version stamp), greenfield slice chain last.
  Items 1–4 kept as completed record.

- Bind the `qwen3.6` planner prompt (`docs/agent-notes/planner-prompt-qwen3.6.md`)
  to a mandatory mission line after its first live run stalled (blind-trial
  data point 1, recorded in `docs/implementation-tasks.md`): launched with no
  `Target repo:`/`Target:` line, the session treated the workflow repo itself
  as the target — 23 messages, 4 compactions, zero work orders, LFCbot never
  read. The build must now open with a two-part mission line; the explore step
  is bound to that repo only; re-reading a file already in context is banned
  (the 32k filled in <30 min largely on 3-4x re-reads of three docs); status
  replies are short lines, not full-session summaries (the model started
  echoing the compaction summary format after the first compaction). The live
  session is recoverable without a restart — reply to it with the mission line.
- Decide the scaffold-from-scratch benchmark shape (roadmap.md): plan **B,
  decomposed slices** for the React 9 + TS webapp-from-plain-English case.
  Feature slices fit the existing four gates untouched (benchBaseCommit =
  previous slice's head; failsOnOld reverts the slice's source); the slice-0
  skeleton is a planning-time artifact because the scope gate requires a
  revertable source file, and a greenfield reverting-scaffold task-kind is
  explicitly deferred. The translator seat is the planner — decomposing the
  English prompt into ordered, benchmark-shaped slices is its existing
  contract. First instance queued behind the blind-trial lanes
  (implementation-tasks.md → "New open follow-ups").
- Rerun the 3 open timeout unknowns at a 1800 s cap (2026-09-23 evening,
  `-OnlyMissing` re-targeted the row-less cells): `qwen3.6 x asohav-01` PASS
  (13 writes, 1620.3 s, suite 48 green - the seat's first pass on the cell),
  `qwen3.6 x asohav-02` FAIL liar mode (exit 0, 0 writes); the "times out at
  1800 = seat finding" branch resolves negative - the seat finishes, it just
  fails the cell. `node3 qwen3:8b x lfc-02` was killed by a human from
  another session at ~25 min (exit -1: a kill, not a cap), so the
  closeout's "hangs again = host finding" branch is NOT met and the cell
  stays open; the harness-tagged `_TIMEOUT_` transcript was renamed by hand
  to `_ABORTED_` for truthfulness (new open follow-up: the harness cannot
  distinguish a kill from a cap). Corpus 102 -> 107, passes 21 -> 22;
  `tests/results/README.md` re-inventoried to 107 (absorbing PR #45's 3
  graded rows that the 102-row pass had missed). Details in
  `docs/implementation-tasks.md` -> "Rerun lanes".
- Draft the `qwen3.6` planner prompt in
  `docs/agent-notes/planner-prompt-qwen3.6.md`: read-only explore first,
  one numbered-list interview, work orders shaped to fit the benchmark
  (bench branch, 2-3-file scope, testCmd), planner-written acceptance tests
  that must fail on current code before the order queues. DRAFT - not yet
  run in a live session.

- Agree the Stage 1 starting build (2026-09-23, server down): planner
  `qwen3.6:35b-a3b-coding` (fully local loop, first plans small and
  benchmark-shaped), executor attempt 1 `qwen3.5:9b` Q8 as measured (5/6),
  attempt 2 `laguna-xs-2.1` (3/3), parallel attempt `qwen3:8b` on node3,
  review-side `nemotron-3.5-lightning` (reviewer-seat trial per the round-3
  protocol — the seat is empty, auditor duty meanwhile), dispatcher manual.
  `ministral-3:8b` (0/7), `lfm2.5:8b` (0/8) and `ornith:9b` (1/7, liar mode
  2026-09-23) are out as executors. Recorded in `docs/target-setup.md` →
  "Starting build".
- `opencode/global/opencode.jsonc`: raise the `qwen3.6:35b-a3b-coding` seat to
  `limit.output` 8192 (it plans now — multi-order work orders plus acceptance
  tests do not fit the 4096 executor budget that truncated `qwen3:14b`).

- Record the aborted 2026-09-23 2-lane executor launch in
  `docs/implementation-tasks.md` (open follow-ups): Lane 1 control and Lane 2
  node3 gap fill both picked `kane-02` within 18 seconds — `-OnlyMissing`
  correctly ignored the legacy exit-1 rows while control legitimately re-ran
  the task, and no guard covers worktree contention. Zero corpus impact (102
  rows, clean tree). Adjustments before relaunch: static task partition per
  lane, driver-stop-plus-process-check stop procedure (a stopped driver
  orphans its `opencode run` child), and the two voided `kane-02` cells stay
  open.
- `tests/run-tasks-batch.ps1`: add `-RunTimeout`/`-CommandTimeout`, forwarded
  to every `test-tasks.ps1` invocation (0 = its 900/300 defaults). The
  18–25 GB offloading seats need 1800 or they die at the default cap with no
  transcript — the gap-fill review's largest failure class. Requested there,
  applied here.
- Re-inventory `tests/results/README.md` for the 102-row corpus (was 43 rows /
  1 pass): 21 genuine passes listed, an era-confound box (no desktop qwen3 row
  exists post-09-22, so incumbent-vs-challenger comparisons span three harness
  fixes), guided-repair labeling for what the tasks measure, a task × model
  coverage grid, the `lfm2.5:8b` 8/8 zero-write finding, and reconstructed
  timeout counts with the lost-transcript caveat. Defers per-attempt rates to
  `docs/implementation-tasks.md` → "Gap-fill batch review" instead of
  duplicating them.
- Reframe `docs/roadmap.md` and `docs/target-setup.md` around the owner's
  2026-09-23 decisions: executor selection winners-first (N=10 backfill and
  16-task expansion wait until after first real use; misses read as role-fit,
  not model quality), TypeScript-only until first real use, server-centric
  fleet with desktop/node3 overflow, hosted calibration unscheduled with the
  OpenCode Go key available. Roadmap Next-up item 2 replaced, node3 and
  review-gate items closed out with pointers, `target-setup.md` data section
  re-based off the gap-fill review (retiring the pooled 7%), machine roles
  record the CPU asymmetry (server serves, node3/desktop run worktrees).
- Grade the 2026-09-23 gap-fill batch (`docs/implementation-tasks.md` →
  "Gap-fill batch review"). Rates are now per attempt, because timeouts
  leave no row and graded-only ratios overstate: `qwen3.5:9b` 5/8,
  `laguna-xs-2.1` 3/8 (5 timeouts), `nemotron-3.5-lightning` 3/8,
  `qwen3.6:35b-a3b-coding` 3/8, `north-mini-code-1.0` 1/8,
  `devstral-small-2:24b` 1/8 (7 timeouts). An audit of the transcripts of all
  17 passes finds none hollow: real edits to both source and test, and every
  `failsOnOld` is a behavioural failure, not an import crash. Records the
  lost-timeout-transcript bug, the `kane-02` compaction failures behind both
  `_INFRA_` runs, and the missing Ollama-version control. Nothing else changes.

- Task-veracity benchmark: gap-fill batch 2026-09-23, 41 graded runs (22
  desktop + 19 node3) across the new executor candidates, evidence committed
  verbatim (per-run `.json` + `.jsonl`; 2 extra `_INFRA_` transcripts with no
  row, by design). Desktop candidates land guided-repair passes where
  `qwen3:8b` mostly didn't — `laguna-xs-2.1` 3/3, `qwen3.5:9b` 5/6,
  `nemotron-3.5-lightning` 3/4, `qwen3.6:35b-a3b-coding` 3/6,
  `north-mini-code-1.0` 1/2, `devstral-small-2:24b` 1/1. Node3 small
  candidates mostly miss — `lfm2.5:8b` 0/8, `ministral-3:8b` 0/5, `ornith:9b`
  1/6 — consistent with `docs/hardware.md`'s "likely too weak to write fixes"
  note on `lfm2.5:8b`. Includes the 18-row 0.34.3/0.34.2 toolcall probe log
  behind the 8 new `run-tasks-models.tsv` seats.
- `tests/run-tasks-batch.ps1`: add `Probe` and `Both` modes on top of the
  data-driven pickers. Probe runs `test-toolcalls.ps1` on every host that
  answers. `Both` then batches every seat whose probe PASSes on its host's
  current Ollama version. `-OnlyMissing` runs only task × model pairs with no
  graded row. `-Mode/-Tasks/-Models/-Reps/-Yes` make the whole thing
  non-interactive. Seats the live opencode config doesn't know are dropped
  before they can become `_INFRA_` runs. Also fixes the seat picker from #36,
  which offered every seat as one joined option: `return ,@(...)` wrapped in
  `@()` nests the array.
- `tests/test-toolcalls.ps1`: log every result to
  `tests/results/toolcalls-summary.tsv` with host label and Ollama version.
  Results were previously recorded by hand, and a probe only holds for the
  version it ran on. Accepts a `/v1` base URL. Fixes the usage comment's
  nonexistent `-Host` flag.
- Serve and register every desktop tool-capable seat at 32768 context:
  `qwen3.5:9b`, `qwen3-coder:30b-a3b` and `devstral:24b` were 16384. At 16k,
  OpenCode's ~14.4k-token standing preamble plus the 4096 output reserve does
  not fit, so those seats lost their system prompt before seeing a task. Baked
  by `startup.ps1` (`$contextModels`), with `limit.context` to match.
- Register the 2026-09-22 executor candidates in `opencode.jsonc` and
  `models/catalog.tsv`: on the desktop, `devstral-small-2:24b`,
  `north-mini-code-1.0`, `laguna-xs-2.1`, `qwen3.6:35b-a3b-coding` and
  `nemotron-3.5-lightning`; on node3, `ornith:9b`, `ministral-3:8b` and
  `lfm2.5:8b`. They are registered ahead of the probe with `tool_call: true`
  so one `-Mode Both` run can batch whichever pass. The script drops non-PASS
  seats, and a FAIL gets flipped to false afterwards.
- Desktop Ollama 0.34.1 → 0.34.3 (manual install; the `pin-ollama-desktop.ps1`
  firewall rule stays, so the tray app still cannot self-update). Desktop
  models moved from `C:\Users\<you>\.ollama\models` to `M:\ollama\models`
  (User-level `OLLAMA_MODELS`).
- Add `docs/target-setup.md`: the planned fleet end state once the server is
  back, derived from the owner's stated workflow (interactive planning only;
  unattended, slow implementation is fine; TypeScript first; offload to local
  rather than replace Claude Code/Codex). A strong model writes work orders
  with the acceptance test already in them. The fleet runs N attempts across
  hosts, and the existing task-harness gates pick the winner. Includes machine
  roles and ordered milestones.
- Record the 2026-09-22 edit-reliability analysis in
  `docs/implementation-tasks.md`: `edit` succeeds 11% of the time across all
  graded transcripts. 79% of misses target code that isn't in the file (not
  whitespace), 94% of reads are small slices, and 30% of edits hit unread
  files. Close the node3 "flapping" follow-up: the cause was Windows sleep.
- `docs/hardware.md`: desktop RAM (32 GB), free-RAM-for-spill notes, the
  2026-09-22 Ollama library scan of candidate executor models per host, and
  ranked hardware upgrade candidates for AI. Adds wired LAN and per-option
  disk totals (~102 GB for all large candidates, ~17 GB for node3's; the
  desktop's current install measures 85.8 GB).
- Make `tests/run-tasks-batch.ps1`'s task and model pickers data-driven. The hardcoded
  seat list is gone: options now come from `tests/run-tasks-models.tsv` (a row
  per tag the toolcalls probe measured PASS on, with eligible hosts)
  intersected against each live host's `/api/tags`, so a new tool-capable model
  is one TSV row and a down host or an unpulled tag stops being offered on its
  own. The newly imported `qwen3.5:9b` and `qwen3-coder:30b-a3b` seats appear
  via that mechanism (`deepseek-r1-0528:8b` stays custom-option-only — the
  probe measured it FAIL). Bench-branch pins moved into the tasks manifest
  (`branch` + `benchBaseCommit` per task) so `-SetupOnly` and the task picker
  are manifest-driven too.
- Set node3's `qwen3:8b` `limit.context` to `32768` in `opencode/global/opencode.jsonc`,
  this time backed by a measurement: `/api/ps` on a healthy node3 reports
  `context_length 32768` and `7.84 GiB` VRAM (Ollama 0.34.2) with the model
  loaded. The same number was set and reverted earlier on an unmeasured
  justification ("6/6 liar mode" that turned out to be six unreachable-host
  transcripts) — this entry replaces that guess with a reading.
- Fix `tests/test-tasks.ps1` silently stranding INFRA/TIMEOUT transcripts in
  `%TEMP%`. The cross-volume move (`C:\Temp` → `M:\results`) failed when a
  handle briefly held the file (opencode teardown / AV scan); the old
  `Move-Item -ErrorAction SilentlyContinue` swallowed the failure and still
  printed "kept," which is how 15 transcripts on 2026-09-21 and 12 more on
  2026-09-22 were left behind uncollected. A new `Move-Transcript` helper
  retries with backoff, falls back to copy+delete, and prints a truthful WARN
  with the stranded path when a source is genuinely stuck.
- Bring `AGENTS.md`'s task-veracity harness description up to date with the
  2026-09-21 fixes. It still described grading as "scope / suite / failsOnOld /
  typecheck" with no mention that a run is graded **only** if `opencode run`
  exited 0, that any non-zero exit is infrastructure and writes no
  `tasks-summary.tsv` row, that `run-tasks-batch.ps1` now refuses to start
  against a host that is not answering, or that `typecheck` can be `SKIP`.
  `AGENTS.md` is the first file an agent reads, so a stale harness contract
  there is the one most likely to be acted on.
- Withdraw a stale citation in `docs/roadmap.md`'s breadth-vs-depth rationale.
  It offered node3's `qwen3:8b` "liar mode" on `kane-01`/`lfc-01` as a second
  worked example of between-task variance; those runs never reached Ollama, so
  they are not evidence of anything about that seat. The `qwen3:14b` example
  still stands and the N=10 conclusion does not depend on the withdrawn one.
- Record the worktree-keying trade-off as an open follow-up in
  `docs/implementation-tasks.md`: `test-tasks.ps1` keys both the worktree and
  the install marker by task id alone, which is what makes same-task
  concurrency unsafe. Keying by task id **and** model label would delete that
  rule rather than document it, at the cost of one worktree and one
  `node_modules` per (task, seat) pair.

- Fix `tests/test-tasks.ps1` recording `typecheck: PASS` for tasks that never
  ran `tsc`. The flag was a boolean initialised to `$true` *before* the
  `if ($tk.typecheck)` guard, so the 6 of 8 manifest tasks with no `typecheck`
  block recorded a clean compile having compiled nothing - most starkly the
  three `kane-02` rows, which never reached the model at all. It is now
  tri-state: `PASS`/`WARN` only when the task defines the block, `SKIP`
  otherwise (a status the console summary already counted but never emitted).
  Only `kane-01` and `lfc-01` define one, so the other six now read `SKIP` -
  including all five never-run tasks, which would otherwise have added ~30
  vacuous `PASS` values to the next breadth batch. Rows written before this
  change still carry the old vacuous `PASS`; `tests/results/README.md` says
  how to read them.
- Correct the node3 concurrency plan in `docs/roadmap.md` (step 9 under
  "Put it to work on the task-veracity benchmark", and the pointer in item 3).
  It said desktop and node3 should run the same tasks "at the same time";
  `tests/test-tasks.ps1` keys the worktree by task id alone
  (`$wtPath = Join-Path $wtRoot $tk.id`), as it does the install marker, so two
  concurrent runs of one task id share a worktree and corrupt each other -
  the constraint AGENTS.md already states as "different task IDs only, never
  the same one twice". Split the terminals by disjoint task id instead, each
  running both seats; the wall-clock saving is identical.
- Add a desktop handoff to `docs/implementation-tasks.md`: the outstanding
  on-hardware verification for the harness and config changes, the ordered
  node3 bring-back sequence (measure `/api/show` before setting
  `limit.context` again), the dry-run preflight for the five never-run tasks
  with the `@asohav/shared` setup-step warning, and the N=3-then-N=10 breadth
  batch plan.

- Fix `tests/test-tasks.ps1` grading infrastructure failures as model
  behaviour. It bailed out only on its `-1` timeout sentinel, so any other
  non-zero `opencode run` exit fell through to the writes gate and was
  stamped "0 write/edit calls - the model described the change instead of
  making it (the old liar mode)". opencode exits 0 even when a model
  answers in prose, so a non-zero exit is always infrastructure - an
  unreachable provider, a bad model id, a crash - and now produces a
  `FAIL`ed run, an `_INFRA_`-tagged transcript and **no summary row**,
  because a run that never reached the model measured nothing. The console
  now also quotes the transcript's first error event, so an unreachable
  host reads as "Cannot connect to API" instead of "exit 1".
- Add an endpoint preflight to `tests/run-tasks-batch.ps1`: every host the
  batch is about to drive is checked with `/api/tags` before the first run,
  and the batch refuses to start against one that is not answering. Covers
  `$env:OPENCODE_SMALL_MODEL`'s host too, which matters because
  `profiles/dev-node3.sh` points the small model at `ollama-server` - down
  since 2026-09-16.
- Correct the record on node3's `qwen3:8b` "liar mode", and **revert** the
  `limit.context` 16384 -> 32768 bump in `opencode/global/opencode.jsonc`
  that was made on the strength of it. All six node3 task-veracity
  transcripts are 307 bytes holding exactly one event: an `APIError`,
  "Cannot connect to API", against `http://NODE3_IP:11434/v1/chat/completions`.
  No request ever reached Ollama, so those runs are not evidence about
  context budget, tool-calling or this model in any direction - and the
  `kane-02` subset is not the stale `setup` step either, since the same
  signature appears on `kane-01` and `lfc-01`, which never had that step.
  Node3's liar-mode denominator is **0, not 6**; it has no capability data
  yet. The preamble arithmetic remains unresolved (~12,288 tokens of input
  budget at 16384 vs a measured 14,364-token preamble), so measure what
  node3 actually serves before setting this number again - see
  `docs/roadmap.md`'s corrected entry for the order to do it in.
- Raise `ollama-desktop`'s `qwen3:14b` `limit.output` from 4096 to 8192.
  At 4096 the seat exhausted its output budget inside its own reasoning
  block on 8 of 16 task-veracity runs (`step_finish` reason `"length"`,
  usage output exactly 4096, ~25k of the context window still unused), and
  on `kane-01` it hit the cap before any edit call on 7 of 9 runs - leaving
  the seat with almost no gradable data and invalidating every 14b-vs-8b
  comparison drawn from it. 8192 is the reasoner budget that file's own
  rules already prescribe; the prompt window stays at 24,576.
- Add `.claude/hooks/session-start.sh` (`SessionStart` hook, registered in
  `.claude/settings.json`): installs `pwsh` in remote/Claude-Code-web
  sessions, gated on `$CLAUDE_CODE_REMOTE` so it never touches a local
  session that already has real Windows PowerShell. Idempotent (no-ops if
  `pwsh` is already on `PATH`). Prompted by the `kane-02` bug below - AGENTS.md's
  own `ParseFile` syntax-check convention had no PowerShell to actually run
  against in a remote session, only a bracket-balance approximation.
  Installs the official Linux binary tarball (x64/arm64) to
  `/opt/microsoft/powershell/7`, symlinked to `/usr/local/bin/pwsh`. Verified:
  ran the hook directly (`CLAUDE_CODE_REMOTE=true .claude/hooks/session-start.sh`)
  from a clean state, confirmed `pwsh --version` afterward and confirmed
  `tests/run-tasks-batch.ps1` and `tests/test-tasks.ps1` both parse clean.
- Fix `kane-02-multiword-creature-type`'s manifest entry: it shipped with a
  `setup` step (build `@mtg/rules`) copied from `kane-01`'s entry without
  re-checking it against `kane-02`'s own pinned commit - `packages/rules`
  doesn't exist yet at that point in KaneEnabler's history (`git ls-tree`
  confirms only `packages/config` does), and `signals.ts` has no `@mtg/rules`
  import there at all. The original verification pass missed this because it
  built `@mtg/rules` while still on `main` (current HEAD) *before* creating
  the task's bench branch - the stale `packages/rules/dist/` build output
  was untracked and survived the branch switch, so the sandbox test passed
  even though a real `git worktree add` (no such leftover) cannot resolve
  it. Surfaced 2026-09-21 while investigating three node3 runs of this task
  that failed identically - those runs turned out to have died at the
  `opencode run` API call (node3 unreachable), not here, since a failed
  setup step returns before any summary row is appended and all three
  appended one. Reading them is what exposed this. Removed the `setup` block; re-verified in a genuinely
  fresh worktree (28/28, no setup needed) and re-audited every other new
  task's import requirements directly against git history (`git show
  <commit>:<path>` - no working-tree checkout, so immune to the same
  mistake) - `kane-03`/`kane-04`/`lfc-02` correctly have no setup step,
  `asohav-01`/`asohav-02` correctly do.
- Add `tests/run-tasks-batch.ps1`: wraps `test-tasks.ps1` for day-to-day use.
  Ensures every task's local `bench/*` branch exists (idempotent, reads repo
  paths from the manifest, commit hashes match `docs/roadmap.md`'s task-set-
  expansion table), then interactively prompts for which task(s), which
  model(s), and how many repeats of each, and runs one `test-tasks.ps1`
  invocation per (task, model, rep) combination. `-SetupOnly`/`-SkipSetup`
  split the two phases. Sequential by design, not parallel — the worktree-
  keyed-by-task-id constraint means true concurrency still needs two
  separate terminals running non-overlapping task IDs directly.
- Task-veracity benchmark: strategy pivot from depth to breadth, since the
  actual goal is general capability, not just `kane-01`/`lfc-01`. Cap N at
  **10 per model/task cell** (was heading toward 30-50), added GitHub read
  access + shallow clones for `mkane848/kaneenabler`, `asohavcompanionapp`
  and `lfc-bot`, mined each repo's commit history for real merged bug-fix
  commits, and added **6 new tasks** to `tests/tasks/manifest.json` —
  `kane-02-multiword-creature-type`, `kane-03-saga-chapter-triggers`,
  `kane-04-singleton-up-to-n`, `asohav-01-library-write-reporting`,
  `asohav-02-changelog-uuid-id`, `lfc-02-scryfall-headers` — bringing the
  set to 8, with 16 as the target. Every task independently verified
  (baseline green at the parent commit, `failsOnOld` confirmed red) before
  being added; two candidates found and dropped for not isolating cleanly
  to a 2-file scope. Full reasoning, the verification table, the dropped
  candidates, and the `MANAPOOL_API_KEY` caveat on `lfc-02` in
  `docs/roadmap.md` ("Task-veracity benchmark: task set expansion"). Each
  new task's pre-fix state lives on a new local branch (`bench/*`) that
  must be created in the corresponding local checkout before it can run —
  commands in the same roadmap section.
- Harden `tests/test-tasks.ps1`'s prompt-hash line: it called
  `[Security.Cryptography.SHA256]::HashData(...)` and `[Convert]::ToHexString(...)`,
  both .NET 5+ convenience APIs. Hit a `does not contain a method named 'HashData'`
  failure on desktop (2026-09-21) on the first invocation of a shell session; an
  identical retry succeeded, so the root cause looks like a transient type-resolution
  race rather than a real PS 5.1/PS 7 split — but the script already targets both
  runtimes (AGENTS.md), so swapped to `SHA256.Create()` + `ComputeHash()` +
  `BitConverter.ToString()`, which needs nothing newer than .NET Framework and
  produces the identical uppercase 12-char hex prefix.
- Task-veracity benchmark: 4 more graded runs (2026-09-20 evening, Ollama
  0.34.1, opencode 1.18.31; base `92a8ed0` for `kane-01-background-pair`,
  `4906dc2` for `lfc-01-listing-status-guard`).
  `kane-01-background-pair` on `ollama-node3/qwen3:8b` x2 (21:55, 22:05) —
  both exit 1 with 0 writes, scope FAIL / suite PASS / failsOnOld FAIL.
  `lfc-01-listing-status-guard` on `ollama-desktop/qwen3:14b` x2 — 21:58
  fully landed (2 writes, all four gates PASS), 22:12 scope PASS / suite
  FAIL / failsOnOld PASS (6 writes). Rows appended to
  `tests/results/tasks-summary.tsv`; raw `.json`/`.jsonl` transcripts
  committed verbatim, ungraded per CONTRIBUTING.
- Disable the `~/.claude` skill rider: opencode auto-loaded the Claude Code
  plugin's synced skills (`~/.claude/skills/synced/`, 10 SKILL.md, 167 KB) into
  every request behind `$GLOBAL_SKILL_SOURCES`'s back. Measured on the desktop
  (2026-09-20): OK probe `task.n_tokens` 16,851 → 14,364 and prompt prefill
  113 s → 84 s with `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1`. Baked into all
  four live profiles + forwarded by `desktop/scripts/opencode.ps1` + set as a
  User-level env default; `AGENTS.md` Preamble Budget gotcha expanded with the
  measurement and the keep-it-set warning.
- Document the `gh pr create/edit --body` PowerShell trap in `AGENTS.md`
  (Gotchas) and `CONTRIBUTING.md`: inline `--body "..."` eats backticks, so
  write the body to a file, pass `--body-file`, and re-read the rendered body
  with `gh pr view`. Learned the hard way on PR #19/#20, whose bodies had to
  be re-saved after merge.
- Documentation cleanup after the node3 onboarding: every live/parked
  profile count now says 4 / 8 (was 3 / 9 across `README.md`,
  `docs/profiles.md`, `profiles/README.md`); `dev-node3.sh`'s `FUTURE/STUB`
  header, `profiles/parked/README.md`'s "never provisioned" section, and
  `docs/network-topology.md`'s `(future)` labels updated for the live node;
  ROCm remnants corrected to Vulkan (`desktop/README.md` rewritten sections,
  `dev.dockerfile`, `docker-compose.yml`, `sandbox.md`, `troubleshooting.md`,
  `models.ps1`, `config.example.json` — whose stale `OLLAMA_CONTEXT_LENGTH`
  note now describes the per-model bake); `opencode/README.md` counts fixed
  (73 skills with vercel at 44, 4 agents, no `planner.md`) and its provider
  table corrected (no GLM4 on desktop, full desktop seat list);
  `docs/start-here.md` + `CONTRIBUTING.md` expect the measured **100 PASS /
  0 FAIL / 1 WARN / 2 SKIP**, closing the roadmap's pass-count contradiction;
  `dev-workflow-resident.sh`'s VRAM header re-based to the served 32k figures
  (11.97 GB) with its removed-subagent echo fixed; server-block `tool_call`
  comment records the measured node3 `glm4:9b` FAIL. Verified with
  `test-profiles.ps1` (full: 100/0/1/2) and `-Profile dev-node3` (15/0/1/2).
- Refresh `AGENTS.md` for the node3 onboarding and other drift: 4 live
  profiles / 8 parked (was 3 / 9), `origin` remote documented (was "no
  remote configured"), node3 marked onboarded with `qwen3:8b` as the only
  agent seat, desktop context-bake list corrected against `startup.ps1`
  `$contextModels`, catalog↔`opencode.jsonc` gap note rewritten (per-host
  registration + the three LM-Studio imports with no catalog row), and new
  pointers to the `-Reliability` canary, the `test-tasks.ps1` benchmark, and
  the PR/changelog convention. Commits the staged `dev-node3.sh` unpark
  alongside so the live-profile count holds in-tree.
- Third node (RTX 3080 FE) onboarding complete 2026-09-20: `dev-node3.sh`
  unparked, `test-profiles.ps1 -Profile dev-node3` green (15 PASS, 0 FAIL,
  1 WARN, 2 SKIP). The WARN (`install intent (node3) -> missing on host:
  qwen3:14b, gpt-oss:20b`) is a documented false positive — the harness's
  group-expansion for `DEV_NODE3_MODELS` doesn't check the catalog's
  `hosts` column, and neither model was ever intended for this host
  (`gpt-oss:20b` is `hosts=server,desktop` only; `qwen3:14b` isn't
  registered in node3's `opencode.jsonc` block because 14B weights are
  tight on a 10 GB card). Do not install either to silence it. The 2 SKIPs
  are the pre-existing, unrelated Ubuntu server outage. `docs/hardware.md`'s
  `(future)` tag on the third-node row is removed accordingly, and the
  roadmap's north-star progression note updated to record that node3 came
  online ahead of the server (stage 2), inverting the plan's original
  ordering.

- Third node (RTX 3080 FE) onboarding, steps 1-6 done 2026-09-20: Ollama
  installed, LAN bind + firewall confirmed (`0.0.0.0:11434` listening),
  `qwen3:8b`/`glm4:9b`/`nomic-embed-text`/`mxbai-embed-large` pulled,
  `NODE3_IP` reachable from the desktop. Real tool-calling probes run for the
  first time on this host: `qwen3:8b` **PASS** (62.3s, real `write_file`
  call), `glm4:9b` **FAIL** (32.8s, ignored the tool and answered in prose).
  The `glm4:9b` result closes a real gap flagged in the previous entry —
  `opencode/global/opencode.jsonc`'s `ollama-node3` block claimed
  `"tool_call": true` for it with no measurement behind that claim; corrected
  to `false` now that one exists, and it's recorded in AGENTS.md's Gotchas
  alongside the other measured failures. `qwen3:8b` stays the only node3
  agent seat, unchanged from `dev-node3.sh`'s existing default. Also fills in
  `docs/hardware.md`'s previously-unknown node3 RAM figure (32 GB).
- Task-veracity benchmark: 15 more harness runs to bulk up the graded sample
  on the qwen3 seats for both tasks (base `92a8ed0` for
  `kane-01-background-pair`, `4906dc2` for `lfc-01-listing-status-guard`).
  11 new graded rows appended to `tests/results/tasks-summary.tsv`; 4 runs hit
  the harness's 900 s `opencode run` cap and append no row (existing timeout
  design). Results — Task 1, qwen3:14b x4: 0/4 landed (two zero-write
  liar-mode runs, one 1-write run that broke the suite with a re-parse error,
  one 7-write run whose suite failed a legality assertion; the test file went
  unmodified every run, so failsOnOld stayed red). Task 1, qwen3:8b x3:
  0/3 landed (the 30- and 2-write runs edited only `deckValidation.ts` and
  left the test file untouched so the claimed branch is never exercised; the
  35-write run left the suite green but still never touched the test, so
  failsOnOld stayed red). Task 2, qwen3:14b x2: 0/2 landed (both runs the
  same shape — 3 writes, both claimed files in scope, but `listings.test.ts`
  left with a `'} expected'` parse error, suite load/parse FAIL, typecheck
  WARN). Task 2, qwen3:8b x2: 0/2 landed (9- and 30-write runs edited only
  `listings.ts`, leaving the guard test unwritten; suite FAIL, failsOnOld
  FAIL). Cumulative: still 0 successful fixes across both tasks — the
  "test never enters its claimed branch" class now dominates the failures,
  consistent with the existing read of an under-powered sample rather than a
  hard ceiling.
- Plan the third-node (RTX 3080 FE) onboarding now that the hardware exists:
  expand `docs/roadmap.md`'s onboarding checklist into a concrete join →
  probe → put-to-work sequence (CUDA, not Vulkan — no flash-attention
  workaround needed), flag that `glm4:9b`'s `"tool_call": true` entry in
  `opencode/global/opencode.jsonc` doesn't appear in the actual measured
  tool-calling pass/fail list and needs a real probe before it holds an
  agent seat, and note the concrete payoff for the task-veracity benchmark
  (real parallel trial capacity, not just another row in a table). Also
  records Unsloth's installation on that machine as a separate, explicitly
  gated future track (fine-tuning) — gated on there being a genuine
  successful trajectory to train on, which the benchmark doesn't have yet.
  No config or seat changes made; nothing here is live until the node is
  actually onboarded.
- Task-veracity benchmark: external research pass on the combined Task 1 +
  Task 2 result (0/7 graded runs). Confirms the harness's 4-gate design
  (scope/suite/failsOnOld/typecheck) matches SWE-bench's own methodology,
  and that Task 1/2 sidestep a documented SWE-bench contamination critique
  by using private, unpublished bugs. Names the qwen3:14b "liar mode" and
  devstral destructive-rewrite failures as a studied class (reward hacking /
  MIRAGE-Bench's agent-hallucination taxonomy), not one-off flukes.
  **Correction:** published base rates for the *un-tuned* models this fleet
  seats (plain Qwen3-8B ≈ 8% on SWE-bench Verified; Devstral-Small ≈ 17.2%
  pass@1 on SWE-MERA) put 0 successes in 7 trials at roughly 20–55%
  probability by chance alone — so "0/7" should be read as an
  under-powered sample, not confirmed evidence of a hard capability
  ceiling. Adds an unscheduled testing-plan item (hosted/frontier-model
  calibration arm on the existing Task 1/2 prompts) and reorders "Next up"
  to prioritize more repeat trials over a 3rd task shape. See
  `docs/roadmap.md` → "Task-veracity benchmark: external research pass".
- Run Task 2 of the task-veracity benchmark (`lfc-01-listing-status-guard`)
  across all three seats on the real `opencode run` tool loop (base `4906dc2`,
  baseline green 21/21 every run): **0 of 3 landed the fix**, each failing
  structurally and differently. qwen3:14b in liar mode — both `edit` calls
  errored (multi-match `oldString` for `setStatus`'s shared `where(eq(id,id))`;
  guessed literal test anchor), then it ran vitest, saw the untouched green
  suite, and *asserted in prose* that the fix and new tests were done; its first
  run (900 s timeout) was the same loop before the rerun failed fast (167 s).
  qwen3:8b by breaking the build — deleted `const db = getDb();` and wrote
  module-level `await db.select(...)/db.update(...)` into the sync `setStatus`
  (TS2304/TS1308/TS7006), so the file never parses and the suite runs 0 tests.
  devstral:24b by a destructive full-file rewrite hidden behind two harness
  timeouts — at +12 min it replaced the 516-line `listings.test.ts` with 4
  mangled comment lines (`<%/* */%>`), then produced nothing flushed for 7.5 h;
  the `tool_use` events were lost to the force-kill's buffer flush, which is why
  its post-kill transcript shows only a `step_start`. Fix the harness on the way
  (branch `task2`, PR #13): the `setup`-array crash for tasks without a `setup`
  array, and the `Get-FailedTestNames` blind spot that printed an **empty** FAIL
  for broken modules (`Failed Suites N` / `Tests no tests` vs. `Tests N failed` —
  now captured, gated on `Failed Suites N`, with the failing file named).
  Write-up in `docs/roadmap.md` → "Task 2 first graded runs"; evidence
  (per-run `.json` + `.jsonl` transcripts, preserved STALL transcript, destroyed
  test file) in `tests/results/`. No seat/config change made, per the benchmark
  gate (≥3 graded runs across ≥2 tasks satisfied by *something*).
- Add Task 2 to the task-veracity benchmark manifest:
  `lfc-01-listing-status-guard` (lfc-bot), a missing-validation bug —
  `setStatus()` in `src/services/listings.ts` updates a listing's status by
  `id` alone with no guard on its current status, so an already
  fulfilled/deleted/expired listing can be re-fulfilled or re-deleted,
  silently resurrecting it. Deliberately a different bug shape from Task 1's
  eligibility/conditional-logic bug. Found by codebase survey, independently
  verified against the actual source, all three call sites, and existing
  test coverage before being written into the manifest — never taking a
  survey's word for it, same discipline as the rest of this repo's research.
  Fixes the harness to get there: `Ensure-Worktree`'s install step was
  hardcoded to `pnpm install`, which would silently mis-install an
  npm-only repo (no pnpm lockfile); it's now `packageManager`-aware per task
  (defaults to `pnpm`, so kane-01 is unaffected). The task's scoped
  typecheck extends `tsconfig.eslint.json`, not `tsconfig.json` — confirmed
  empirically (`tsc --noEmit --listFiles`) that the latter's inherited
  `exclude: [..., "tests"]` silently drops the test file from an explicit
  `include` even when named directly, which would have made the typecheck
  gate a no-op on exactly the file it needs to check.
- Add the task-veracity benchmark harness (`tests/test-tasks.ps1`) and task
  manifest, seeded with the background-pairing task and its first graded runs
  (qwen3:14b, qwen3:8b x2, devstral:24b — all FAIL on the six mechanical gates).
- Harden the task-veracity benchmark harness before Task 2: raw run
  transcripts are now kept (moved into `tests/results/*.jsonl`, paired by
  filename with the graded JSON) instead of deleted from `%TEMP%` — the same
  round-2 mistake this repo's review-gate work already learned from. Every
  run also records `ollamaVersion`/`opencodeVersion`. Sampling (seed/
  temperature) is explicitly documented as NOT controlled or recorded —
  `opencode run` has no known per-invocation flag for either, unlike
  `docs/review-gate/r3-runner.ps1`'s direct-Ollama-API approach — rather than
  fabricate a reading for a parameter this harness cannot currently pin.
- Cross-check the `devstral:24b` zero-write result from the task-veracity
  benchmark (`kane-01-background-pair`) through VS Code Agent mode, same base
  commit and identical prompt: reproduced - 0 files changed. Confirms the
  failure isn't an OpenCode/raw-Ollama-template artifact.
  (`tests/results/tasks-kane-01-background-pair-devstral-24b-vscode_*.json`)
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