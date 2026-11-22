# Workflow: the main seat, `/plan` and profiles

> Moved verbatim from `AGENTS.md` on 2026-10-26 (the AGENTS.md split); no facts were dropped. Dated statements keep the date they were written with.

## Active workflow ("qwen3 is the boss")

The `/plan` → execute flow is the reason the workflow agents/commands exist and it pins models via OpenCode, not vram juggling:

**The main seat runs `qwen3.6:35b-a3b-coding`, on the server by default** (`dev-workflow-server-llamacpp`, the launcher's default since 2026-10-22: llama.cpp scored 54 of 60 against Ollama's 47 on the 15 real tasks, with no context overflows, owner's decision; Ollama was removed from the fleet on 2026-11-21, so llama-server is the only engine and the desktop runs no models; the other live profile, `dev-node3`, seats `qwen3:8b` on node3's llama-server; before 2026-11-21 `dev-workflow-server` seated it on the server's Ollama and `dev-workflow-quality` on the desktop). It won the plain-language main-seat trial (`docs/main-seat-trial.md`: 3 CLEAN, 1 QUALIFIED, 0 FAIL; the `qwen3:14b` control FAILed both tasks it ran) and leads the real-repo task benchmark, where `qwen3:14b`, the seat from 2026-09-17, is 2/13 and 0/7 on the frontier cells (`docs/roadmap.md` → "Executor standings"). It does not fit on a 16 GB GPU: on the server's llama-server the experts of the first `n-cpu-moe` layers stay in system RAM (`server/llamacpp/models.ini`). So its small model is `qwen2.5-coder-3b-cpu`, the 3b on the CPU (`num_gpu 0` in `models/server-seats.tsv`): on the desktop's Ollama the GPU 3b evicted `qwen3.6` at every session start (titles), the CPU one did not (the trial doc's "Second experiment", 0 evictions in 3 sessions). Tool-calling is not a `qwen3`-only property: 13 of 22 probed models passed `tests/test-toolcalls.ps1` in the Ollama era (desktop on Ollama 0.34.3, node3 on 0.34.2; `tests/results/toolcalls-summary.tsv`; see Gotchas; re-probe on llama-server before seating), but a probe PASS is necessary, not sufficient. A coder or reasoner that cannot call tools (the `qwen2.5-coder` and `deepseek-r1` families, `glm4:9b`) in an agent seat will *claim* it edited files it never touched.

- `/plan <scope>` (`opencode/commands/plan.md`, runs on the main agent) uses **the main session model**: reads the repo, writes/updates `docs/implementation-tasks.md` (risks/gaps cited by `file:line`, ordered file-scoped tasks with definitions of done). It was pinned to DeepSeek-R1, which cannot call the write tool and hallucinated success instead ("The task tool has written…").
- Then tell the main session model — **`qwen3.6:35b-a3b-coding`** — to "execute task #N from docs/implementation-tasks.md". Coding never goes through delegation.
- **There is no coder subagent and no `/implement`.** Both were removed 2026-09-17: the subagent was pinned to `qwen2.5-coder-16k` (the 7B), which cannot call tools, so `/implement` silently did nothing. A command that looks like it works and doesn't is worse than no command. AGENTS.md already said coding belongs in-thread — now the config agrees.
- No-tools models (the `qwen2.5-coder` family) are useless as agents; `qwen2.5-coder:14b` was registered as one until 2026-11-21, when it went with Ollama.

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
process env) or from a shell that has sourced the profile; a bare launch falls
back to User-level defaults. From any PowerShell, `opencode <profile>` does the
same (`opencode server-llamacpp`, `opencode node3 run "..."`; short names drop
`dev-workflow-`/`dev-`): `desktop\scripts\opencode-profiles.ps1` defines that
`opencode` function, put in `$PROFILE` by `install-opencode-profiles.ps1`, and
anything that is not a live profile name goes to the real opencode untouched.
The launcher restores the shell's env when opencode exits, so a later bare
`opencode` is really bare. (Until 2026-11-21 it also warmed and unloaded desktop
Ollama models; the desktop runs none now.) `tests/test-opencode-profiles.ps1` guards the
routing and the restore.

Live profiles are `dev-workflow-server-llamacpp.sh` (the default since 2026-10-22: qwen3.6 on the server's llama-server, `opencode server-llamacpp`; Phase 2 of "Replacing Ollama", 2026-10-16; needs the llama.cpp stack up on the server) and `dev-node3.sh` (qwen3:8b on node3's llama-server); they set `OPENCODE_MODEL`/`OPENCODE_SMALL_MODEL` and the `LLAMACPP_*` endpoints. The Ollama-era profiles (`dev-workflow-server`, `dev-workflow-quality`, `dev-workflow-resident`, `dev-desktop-only` and six parked ones) were deleted on 2026-11-21 with Ollama. `dev-go-only` (hosted models only) is parked in `profiles/parked/` — see its README for the bring-back procedure (`git mv` + `test-profiles.ps1 -Profile <name>`; probe a model before seating: `.\tests\test-toolcalls.ps1 -Engine llamacpp -EngineHost http://SERVER_IP:8090 -Model <tag>`).
