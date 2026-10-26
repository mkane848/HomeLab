# Workflow: the main seat, `/plan` and profiles

> Moved verbatim from `AGENTS.md` on 2026-10-26 (the AGENTS.md split); no facts were dropped. Dated statements keep the date they were written with.

## Active workflow ("qwen3 is the boss")

The `/plan` → execute flow is the reason the workflow agents/commands exist and it pins models via OpenCode, not vram juggling:

**The main seat runs `qwen3.6:35b-a3b-coding`, on the server by default** (`dev-workflow-server-llamacpp`, the launcher's default since 2026-10-22: llama.cpp scored 54 of 60 against Ollama's 47 on the 15 real tasks, with no context overflows, owner's decision; `dev-workflow-server`, the same seat on the server's Ollama, was the default from 2026-10-13: the same weights at about twice the desktop's speed, `docs/roadmap.md` → "Next up"; `dev-workflow-quality` seats it on the desktop, the fallback when the server is down or in a trial window; the other three live profiles seat `qwen3:8b`). It won the plain-language main-seat trial (`docs/main-seat-trial.md`: 3 CLEAN, 1 QUALIFIED, 0 FAIL; the `qwen3:14b` control FAILed both tasks it ran) and leads the real-repo task benchmark, where `qwen3:14b`, the seat from 2026-09-17, is 2/13 and 0/7 on the frontier cells (`docs/roadmap.md` → "Executor standings"). It does not fit on the GPU: 21.13 GB at 64k, of which Ollama puts 12.51 GB (all it can) in VRAM and the rest in system RAM. So its small model is `qwen2.5-coder-3b-cpu`, the 3b with `num_gpu 0` that `startup.ps1` derives: the GPU 3b evicted `qwen3.6` at every session start (titles), the CPU one did not (the trial doc's "Second experiment", 0 evictions in 3 sessions). Tool-calling is not a `qwen3`-only property: 13 of 22 probed models pass `tests/test-toolcalls.ps1` (desktop on Ollama 0.34.3, node3 on 0.34.2; `tests/results/toolcalls-summary.tsv`; see Gotchas), but a probe PASS is necessary, not sufficient. A coder or reasoner that cannot call tools (the `qwen2.5-coder` and `deepseek-r1` families, `glm4:9b`) in an agent seat will *claim* it edited files it never touched.

- `/plan <scope>` (`opencode/commands/plan.md`, runs on the main agent) uses **the main session model**: reads the repo, writes/updates `docs/implementation-tasks.md` (risks/gaps cited by `file:line`, ordered file-scoped tasks with definitions of done). It was pinned to DeepSeek-R1, which cannot call the write tool and hallucinated success instead ("The task tool has written…").
- Then tell the main session model — **`qwen3.6:35b-a3b-coding`** — to "execute task #N from docs/implementation-tasks.md". Coding never goes through delegation.
- **There is no coder subagent and no `/implement`.** Both were removed 2026-09-17: the subagent was pinned to `qwen2.5-coder-16k` (the 7B), which cannot call tools, so `/implement` silently did nothing. A command that looks like it works and doesn't is worse than no command. AGENTS.md already said coding belongs in-thread — now the config agrees.
- `qwen2.5-coder:14b` stays registered as a **no-tools** model: fine to switch to deliberately for code text, explanation or review, useless as an agent.

**The Plan/Build toggle is not `/plan`.** The bottom-left toggle only gates tool
permissions for the *current* session model; it does not switch model and it
does not write the task doc (Plan mode has no write/edit tools). `/plan <scope>`
is the only way to get the task doc written. The main session model must be
a tool-capable seat: `qwen3.6:35b-a3b-coding` by default (or `qwen3:8b` when
you need the lighter/latency-tuned seat); `qwen3:14b` and `qwen3.5:9b` also
qualify (`qwen3.5:9b` is retired as an executor since 2026-10-13: it crashes on
context overflow in about half its runs) — the `qwen2.5-coder` and `deepseek-r1` families cannot call tools.
Launch OpenCode via
`desktop\scripts\opencode.ps1` (sources the active workflow profile + sets
process env, and pre-loads the profile's desktop main seat in the background so
the first reply skips the cold load; `-NoWarm` skips that) or from a shell that
has sourced the profile; a bare launch falls back to User-level defaults.
From any PowerShell, `opencode <profile>` does the same (`opencode quality`,
`opencode resident run "..."`; short names drop `dev-workflow-`/`dev-`):
`desktop\scripts\opencode-profiles.ps1` defines that `opencode` function, put in
`$PROFILE` by `install-opencode-profiles.ps1`, and anything that is not a live
profile name goes to the real opencode untouched. Since 2026-10-03 the launcher
also unloads the desktop models the profile does not use before warming
(`-KeepLoaded` skips that; a profile with no desktop seat leaves the desktop
alone), and restores the shell's env when opencode exits, so a later bare
`opencode` is really bare. `tests/test-opencode-profiles.ps1` guards the
routing and the restore.

Live profiles are `dev-workflow-server-llamacpp.sh` (the default since 2026-10-22: qwen3.6 on the server's llama-server, `opencode server-llamacpp`; Phase 2 of "Replacing Ollama", 2026-10-16; needs the llama.cpp stack up on the server), `dev-workflow-server.sh` (its twin on the server's Ollama, the default from 2026-10-13 to 2026-10-22, desktop tier off), `dev-workflow-quality.sh` (qwen3.6 on the desktop, the fallback), `dev-workflow-resident.sh`, `dev-desktop-only.sh` and `dev-node3.sh`; they set `OPENCODE_MODEL`/`OPENCODE_SMALL_MODEL`/`DEV_*_MODELS`. Seven server profiles are parked in `profiles/parked/` — see its README for the bring-back procedure (`git mv` + `test-profiles.ps1 -Profile <name>`; probe server models before seating: only `qwen3:8b` and `qwen3.6:35b-a3b-coding` have been, on 0.34.3, 2026-10-12 — `tests/results/toolcalls-summary.tsv`, host `server`).
