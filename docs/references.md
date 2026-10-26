# References & citations

Catalog of every external source cited in these docs, plus the convention.

## Convention

- **Any doc claim grounded in an external source** (paper, leaderboard,
  benchmark, blog, tool docs) links that source inline on **first mention**,
  with descriptive link text — never a bare URL and never a guessed URL.
- Every inline-cited source gets a row here: **short name — title, author/lab,
  date, URL**.
- A URL that exists only to check a fact (product page, registry, docs) is
  linked inline; only sources actually *cited as evidence* need catalogue
  entries.
- **Re-verify stale-able claims when editing a doc that carries them.**
  Leaderboard ranks, "best model" statements, and version facts move weekly;
  this repo's value is measured truth, so a 2026-07 leaderboard reading must be
  re-fetched before a 2026-09 doc relies on it. If you cannot re-verify, keep
  the claim but date-stamp it (e.g. "as of 2026-07").
- When you add the first citation from a new source to any doc, add the source
  row here in the same change so the page never lags the docs.

## Papers (arXiv)

| ID | Source | URL |
|---|---|---|
| saving-swebench | "Saving SWE-Bench: A Benchmark Mutation Approach for Realistic Agent Evaluation", arXiv 2025 (re-read 2026-10-23) — real developer queries "10-30 words" against 100+ in SWE-Bench; rewriting tasks that way lowers OpenHands success (Sonnet 4 on Multi-SWE-Bench TypeScript 15.6% → 7.2%) | <https://arxiv.org/html/2510.08996v2> |
| reward-hacking | "Reward Hacking Benchmark", arXiv 2026 (re-read 2026-10-23) — exploit rates 0% to 13.9% by model; higher on harder variants; 72% of episodes with an explicit rationale; "simple environmental hardening reduces exploit rates by 5.7 percentage points (87.7% relative) without degrading task success" | <https://arxiv.org/abs/2605.02964> |
| mirage-bench | "MIRAGE-Bench", arXiv 2025 | <https://arxiv.org/abs/2507.21017> |
| swe-agent | "SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering", Yang et al., Princeton NLP, arXiv 2024 (v3). Its file viewer shows at most 100 lines at a time, and Table 3 (SWE-bench Lite) puts a 100-line window at 18.0 against 14.3 for 30 lines and 12.7 for the full file | <https://arxiv.org/html/2405.15793v3> |
| dont-blame-llm | "Don't Blame the Large Language Model: How Scaffolding Evolution Shapes Coding Agent Quality", arXiv 2026 | <https://arxiv.org/pdf/2607.03691> |
| swe-edit | "SWE-Edit: Rethinking Code Editing for Efficient SWE-Agent", Microsoft, arXiv 2026-05 | <https://arxiv.org/html/2604.26102> |
| terminal-agents | "Building AI Coding Agents for the Terminal", arXiv 2026-03 | <https://arxiv.org/html/2603.05344v1> |

Where used: `saving-swebench`, `reward-hacking`, `mirage-bench`,
`dont-blame-llm` → [roadmap.md](roadmap.md) ("external research pass");
`swe-edit`, `terminal-agents` → [methodology-research.md](methodology-research.md); `saving-swebench`,
`reward-hacking` also → [roadmap.md](roadmap.md) ("After the trial" items 6 and 10) and
[adversarial-review-2026-10-23.md](adversarial-review-2026-10-23.md); `saving-swebench` also →
[planner-tests-experiment.md](planner-tests-experiment.md), with `anthropic-infra-noise`.

## Leaderboards & benchmarks

| ID | Source | URL |
|---|---|---|
| swe-bench-verified | SWE-bench Verified leaderboard + methodology, official | <https://www.swebench.com/> |
| modelfit-swe | ModelFit "Local vs Cloud: SWE-Bench Verified" (raw-confirmed open-weight scores) | <https://modelfit.io/benchmark/> |

Where used: → [methodology-research.md](methodology-research.md) ("Model fits"),
and `swe-bench-verified` is the reference named throughout
[roadmap.md](roadmap.md) for the mechanical-gate methodology.

## Engineering docs & analysis

| ID | Source | URL |
|---|---|---|
| aider-edit-formats | Aider — edit formats (whole, diff, udiff) | <https://aider.chat/docs/more/edit-formats.html> |
| aider-unified-diffs | Aider — "Unified diffs make GPT-4 Turbo 3x less lazy" (edit-format + flexible-apply analysis) | <https://aider.chat/docs/unified-diffs.html> |
| qcoda-bakeoff | QCoda — "We Tested Every Agentic Coding Engine Against Every Local Model" (engine × model, edit-format + round-trip analysis, 2026-06) | <https://qcoda.com/blog/engine-model-bakeoff> |
| mortar-flashback | Tom's Hardware forum — "MSI B550M Mortar - Bios Flash/boot issues" (read 2026-10-10): solid CPU LED after a BIOS settings save, Flashback never finishing across sticks, versions and CPUs | <https://forums.tomshardware.com/threads/msi-b550m-mortar-bios-flash-boot-issues.3664291/> |

Where used: → [methodology-research.md](methodology-research.md) ("Edit
reliability", "Whole-file vs search-replace", "Harness round-trip weight");
`mortar-flashback` → [server-recovery-cpu-led.md](server-recovery-cpu-led.md) (the 2026-10-10 session).

## Software & code

| ID | Source | URL |
|---|---|---|
| swe-edit-repo | SWE-Edit (Viewer/Editor edit decomposition, PR-Edit eval) | <https://github.com/microsoft/SWE-Edit> |
| metaharness-adr127 | agent-harness-generator ADR-127 — search/replace patch primitive vs whole-file on large files (2026-06, run-to-run stable) | <https://github.com/ruvnet/metaharness/blob/4db1c8f8/docs/adrs/ADR-127-darwin-searchreplace-patch-primitive.md> |
| opencode-upgrade | opencode `packages/opencode/src/cli/upgrade.ts` at commit `2fa3363` (2026-09-29) — the autoupdate routine: skipped when `autoupdate` is false or `OPENCODE_DISABLE_AUTOUPDATE` is 1/true; only patch releases install themselves, a minor or major one notifies | <https://github.com/sst/opencode/blob/2fa3363c924c5c3e367b84a87ae478296a0ed59b/packages/opencode/src/cli/upgrade.ts> |
| opencode-tui-worker | opencode `packages/opencode/src/cli/tui/worker.ts` at `2fa3363` — `checkUpgrade`, the only caller of that routine (`opencode run` never calls it) | <https://github.com/sst/opencode/blob/2fa3363c924c5c3e367b84a87ae478296a0ed59b/packages/opencode/src/cli/tui/worker.ts> |
| opencode-config-docs | opencode docs source `config.mdx` at `2fa3363` — "Autoupdate": `autoupdate` is true, false or `"notify"` (the rendered page, opencode.ai, was not reachable when this was written) | <https://github.com/sst/opencode/blob/2fa3363c924c5c3e367b84a87ae478296a0ed59b/packages/web/src/content/docs/config.mdx> |
| opencode-cli-docs | opencode docs source `cli.mdx` at `2fa3363` — environment variables, incl. `OPENCODE_DISABLE_AUTOUPDATE` | <https://github.com/sst/opencode/blob/2fa3363c924c5c3e367b84a87ae478296a0ed59b/packages/web/src/content/docs/cli.mdx> |
| opencode-overflow | opencode `packages/opencode/src/session/overflow.ts` at v1.18.34 (`aec0b9a`, read 2026-10-04) — when a session compacts: the last step's tokens against `limit.context − limit.output`, or `limit.input − compaction.reserved` when `limit.input` is set | <https://github.com/sst/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/session/overflow.ts> |
| opencode-compaction | opencode `packages/opencode/src/session/compaction.ts` at v1.18.34 — the hard-coded follow-up after an automatic compaction ("Continue if you have next steps, or stop and ask for clarification…") | <https://github.com/sst/opencode/blob/aec0b9a6d8898f68f923aaf08b7306d931fd9d76/packages/opencode/src/session/compaction.ts> |
| ollama-prompt | Ollama `server/prompt.go` at v0.34.3 (`6383a0f`, read 2026-10-04) — `chatPrompt` drops messages from the front until a request fits `num_ctx`, keeping system messages, logged at debug level | <https://github.com/ollama/ollama/blob/6383a0fa9cbf97494b847226e189f6e36b401a08/server/prompt.go> |
| ollama-claude-code | Ollama docs, "Claude Code" integration (read 2026-10-05) — Claude Code against Ollama's Anthropic-compatible API via `ANTHROPIC_BASE_URL`; 64k context or more advised for larger repositories | <https://docs.ollama.com/integrations/claude-code> |
| ollama-openclaw | Ollama docs, "OpenClaw" integration (read 2026-10-05) — "a personal AI assistant" bridging messaging apps to AI coding agents through a gateway; at least 64k context advised with local models | <https://docs.ollama.com/integrations/openclaw> |
| opencode-go | OpenCode docs, "Go" (read 2026-10-06) — $10/month (Go) and $40/month (Go Plus); per-model monthly dollar allowances, of which at most 20% per 5 hours and 50% per week; per-token prices; data retention per model (0 days for most, 30 for Grok and GPT Luna, Muse Spark used for training) | <https://opencode.ai/docs/go> |
| claude-pricing | Anthropic, "Pricing" (read 2026-10-06) — Claude Pro $20/month billed monthly, $17/month billed annually; Claude Code included in all paid plans | <https://claude.com/pricing> |
| hermes-agent | Nous Research, Hermes Agent home and docs (read 2026-10-07) — open-source (MIT) agent: CLI/TUI, messaging gateway, headless mode, any OpenAI-compatible endpoint | <https://hermes-agent.nousresearch.com/> |
| hermes-delegation | Hermes Agent docs, "Delegation" (read 2026-10-07) — `delegate_task` subagents on a delegation model/provider/`base_url` separate from the main session (one setting for every child); only a child's summary returns to the parent | <https://hermes-agent.nousresearch.com/docs/user-guide/features/delegation> |
| hermes-cli | Hermes Agent docs, "CLI commands" (read 2026-10-07) — `-z`/`--oneshot`, `--format stream-json` (for `-q/--query` runs), `-w/--worktree`, `--toolsets`, `--ignore-user-config`, exit codes | <https://hermes-agent.nousresearch.com/docs/reference/cli-commands> |
| hermes-faq | Hermes Agent docs, FAQ (read 2026-10-07) — 64,000-token context minimum; set the context length by hand for Ollama, whose `/api/show` reports the model's maximum | <https://hermes-agent.nousresearch.com/docs/reference/faq> |
| hermes-quickstart | Hermes Agent docs, "Quickstart" (read 2026-10-10) — "VLLM, SGLang, Ollama, or any OpenAI-compatible API"; rejects models under 64,000 tokens of context at startup | <https://hermes-agent.nousresearch.com/docs/getting-started/quickstart> |
| hermes-hooks | Hermes Agent docs, "Hooks" (read 2026-10-10) — no general stop-blocking hook; `pre_verify` can continue a run only after code edits | <https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks> |
| qwen-code-repo | QwenLM, Qwen Code repository (read 2026-10-10) — Apache-2.0 CLI agent, a fork of Gemini CLI; PowerShell installer, Node 22+, MCP | <https://github.com/QwenLM/qwen-code> |
| qwen-code-headless | Qwen Code docs, "Headless mode" (read 2026-10-10) — `-p`, `-o json\|stream-json` (`system`, `assistant` with `usage`, `result` with `stats`), `--resume <id>`, exit codes 53/55/130 | <https://qwenlm.github.io/qwen-code-docs/en/users/features/headless/> |
| qwen-code-providers | Qwen Code docs, "Model providers" (read 2026-10-10) — `modelProviders.openai[]` with `baseUrl` (e.g. Ollama's `/v1`), per-model `contextWindowSize` and `max_tokens` | <https://raw.githubusercontent.com/QwenLM/qwen-code/main/docs/users/configuration/model-providers.md> |
| qwen-code-hooks | Qwen Code docs, "Hooks" (read 2026-10-10) — `Stop` with `decision: "block"` + `reason` continues the agent, in `-p` mode too; input incl. `last_assistant_message`, `context_usage`; cap of 8 consecutive blocks; PowerShell hooks | <https://raw.githubusercontent.com/QwenLM/qwen-code/main/docs/users/features/hooks.md> |
| qwen-code-settings | Qwen Code docs, "Settings" (read 2026-10-10) — `context.autoCompactThreshold`, `general.enableAutoUpdate`, approval modes | <https://raw.githubusercontent.com/QwenLM/qwen-code/main/docs/users/configuration/settings.md> |
| goose-cli | Goose docs, "CLI commands" (read 2026-10-10) — `goose run -t/-i`, `--output-format json\|stream-json`, `--max-turns`, named sessions and `--resume` | <https://goose-docs.ai/docs/guides/goose-cli-commands> |
| goose-config | Goose docs, "Config files" (read 2026-10-10) — `GOOSE_INPUT_LIMIT` (Ollama `num_ctx`), `GOOSE_MAX_TOKENS`, `GOOSE_AUTO_COMPACT_THRESHOLD`, `GOOSE_MODE` | <https://goose-docs.ai/docs/guides/config-files> |
| goose-install | Goose docs, "Installation" (read 2026-10-10) — native Windows recommended for the CLI; pin a version at install with `GOOSE_VERSION` | <https://goose-docs.ai/docs/getting-started/installation> |
| goose-hooks | Goose docs, "Hooks" (read 2026-10-10) — `Stop` with `decision: "block"` "forces the turn to keep going", capped by `GOOSE_STOP_HOOK_BLOCK_CAP`; hooks run via `sh -c` | <https://goose-docs.ai/docs/guides/context-engineering/hooks/> |
| codex-cli-ref | OpenAI Codex docs, "CLI reference" (read 2026-10-10) — `codex exec --json`, `exec resume <id>`, `--oss --local-provider ollama`, read-only sandbox by default | <https://learn.chatgpt.com/docs/cli/reference> |
| codex-hooks | OpenAI Codex docs, "Hooks" (read 2026-10-10) — `Stop` with `decision: "block"` + `reason` makes Codex continue; whether hooks fire under `exec` is not stated | <https://learn.chatgpt.com/docs/hooks> |
| codex-config | OpenAI Codex docs, "Config reference" (read 2026-10-10) — `wire_api`: "`responses` is the only supported value"; `model_context_window`, `model_auto_compact_token_limit` | <https://learn.chatgpt.com/docs/config-file/config-reference> |
| ollama-openai-compat | Ollama docs, "OpenAI compatibility" (read 2026-10-10) — `/v1/responses` since v0.13.3, stateless only | <https://docs.ollama.com/api/openai-compatibility> |
| cline-cli-ref | Cline docs, "CLI reference" (read 2026-10-10) — `--json` events (`agent_event`, `run_result`), `--id` to resume, `--compaction agentic\|basic\|off` | <https://docs.cline.bot/cline-cli/cli-reference> |
| cline-releases | Cline releases (read 2026-10-10) — CLI v3.0.70 (2026-10-08) removed options, so scripts passing them now fail | <https://github.com/cline/cline/releases> |
| kilo-cli-ref | Kilo docs, "CLI reference" (read 2026-10-10) — an OpenCode fork: `kilo run --format json --dir -m --auto`, `-s/--session` | <https://kilo.ai/docs/code-with-ai/platforms/cli-reference> |
| crush-repo | Charm, Crush repository (read 2026-10-10) — FSL-1.1-MIT licence; PowerShell and WSL | <https://github.com/charmbracelet/crush> |
| crush-hooks | Crush docs, "Hooks" (read 2026-10-10) — `PreToolUse` only; no Stop event | <https://raw.githubusercontent.com/charmbracelet/crush/main/docs/hooks/README.md> |
| aider-edit-formats | Aider docs, "Edit formats" (read 2026-10-10) — the model writes edits as text (whole, diff, udiff, architect) that Aider applies; not tool calls | <https://aider.chat/docs/more/edit-formats.html> |
| gemini-cli-repo | Google, Gemini CLI repository (read 2026-10-10) — authentication by Google login, Gemini API key or Vertex AI only | <https://github.com/google-gemini/gemini-cli> |
| continue-readme | Continue README (read 2026-10-10) — "no longer actively maintained and is read-only"; final 2.0.0 release | <https://raw.githubusercontent.com/continuedev/continue/main/README.md> |
| openhands-cli-readme | OpenHands CLI README (read 2026-10-10) — "This project is no longer actively maintained" | <https://raw.githubusercontent.com/OpenHands/OpenHands-CLI/main/README.md> |
| claude-code-headless | Claude Code docs, "Headless" (read 2026-10-10) — `-p`, `--output-format stream-json`, `--resume`, exit codes | <https://code.claude.com/docs/en/headless> |
| claude-code-hooks | Claude Code docs, "Hooks" (read 2026-10-10) — a blocking `Stop` hook "sends Claude back to keep working"; PreCompact and PostCompact | <https://code.claude.com/docs/en/hooks> |
| claude-code-llm-gateway | Claude Code docs, "LLM gateway" (read 2026-10-10) — routing Claude Code to non-Claude models through a gateway is not supported | <https://code.claude.com/docs/en/llm-gateway> |
| llama-cpp-server | llama.cpp `tools/server/README.md` on `master` (read 2026-10-10) — `llama-server` endpoints (`/v1/chat/completions`, `/v1/responses`, `/v1/messages`), `--context-shift` (default disabled), `--n-cpu-moe`, `timings`/`usage` fields, router mode (`--models-dir`, `--models-preset`, `/models/load`); re-read 2026-10-12 for the trial: preset INI (`version = 1`, `[*]` shared defaults, one `[section]` per model, keys are the flags without dashes, precedence command line > section > `[*]`), `POST /models/load` and `/models/unload` with `{"model": …}`, `autoload` per request, `GET /props?model=` in router mode, `--models-max` (default 4), `--parallel`, `-fa`, `-ctk`/`-ctv` | <https://raw.githubusercontent.com/ggml-org/llama.cpp/master/tools/server/README.md> |
| llama-cpp-ctx-shift-test | llama.cpp `tools/server/tests/unit/test_ctx_shift.py` on `master` (read 2026-10-10) — with context shift disabled, an oversized prompt gets a non-200 reply containing "exceeds the available context size" | <https://raw.githubusercontent.com/ggml-org/llama.cpp/master/tools/server/tests/unit/test_ctx_shift.py> |
| llama-cpp-releases | llama.cpp releases (read 2026-10-10) — `b11541` (10 October) ships `llama-b11541-bin-win-vulkan-x64.zip`; re-read 2026-10-12: `b11567` (12 October) ships Windows `win-vulkan-x64`, `win-cuda-12.4-x64` and `win-cuda-13.4-x64` (plus `cudart` packs) and `win-rocm-10.0-x64`, and Linux `ubuntu-x64`, `ubuntu-vulkan-x64`, `ubuntu-cuda-12.8-x64` and `ubuntu-cuda-13.4-x64` | <https://github.com/ggml-org/llama.cpp/releases> |
| llama-swap | llama-swap repository (read 2026-10-10) — MIT, one Go binary; swaps upstream servers per model (`cmd`, `ttl`); OpenAI and Anthropic endpoints; Windows binaries | <https://github.com/mostlygeek/llama-swap> |
| unsloth-studio | Unsloth docs, "Introducing Unsloth Studio" (read 2026-10-10) — local app to run and train models: fine-tuning, chat with LLMs and GGUFs, Data Recipes, export | <https://www.unsloth.ai/docs/new> |
| unsloth-api | Unsloth docs, "How to use Unsloth as an API endpoint" (read 2026-10-10) — GGUFs served through `llama-server`; `/v1/chat/completions` and `/v1/messages` on one port; API keys; `unsloth run` passes `-c` and sampling flags | <https://unsloth.ai/docs/basics/api> |
| unsloth-readme | Unsloth README (read 2026-10-10) — Apache-2.0 core, AGPL-3.0 Studio UI; `UNSLOTH_LLAMA_CPP_BACKEND="vulkan"` at install; claims training on AMD GPUs across Windows, WSL and Linux | <https://raw.githubusercontent.com/unslothai/unsloth/main/README.md> |
| llama-cpp-docker | llama.cpp `docs/docker.md` on `master` (read 2026-10-12) — server images on `ghcr.io/ggml-org/llama.cpp`: `:server` (CPU), `:server-cuda` (CUDA 12), `:server-cuda13`, `:server-vulkan`; the CUDA image needs `--gpus all` and the nvidia-container-toolkit | <https://raw.githubusercontent.com/ggml-org/llama.cpp/master/docs/docker.md> |
| llama-cpp-cuda-dockerfile | llama.cpp `.devops/cuda.Dockerfile` on `master` (read 2026-10-12) — server stage on `nvidia/cuda:12.8.1-runtime-ubuntu24.04`; `ENTRYPOINT ["/app/llama-server"]`; `curl` installed; `HEALTHCHECK` on port 8080; `LLAMA_ARG_HOST=0.0.0.0`, `LLAMA_ARG_PORT=8080` | <https://raw.githubusercontent.com/ggml-org/llama.cpp/master/.devops/cuda.Dockerfile> |
| llama-cpp-ghcr | llama.cpp container registry `ghcr.io/ggml-org/llama.cpp` (queried 2026-10-12 through the registry API, anonymous token from `ghcr.io/token?scope=repository:ggml-org/llama.cpp:pull`) — every build is tagged (`server-cuda-b11561`, `server-vulkan-b…`, `server-cuda13-b…`); `server-cuda` and `server-cuda-b11561` were both `sha256:20c6e722…`, a multi-arch index (linux/amd64, linux/arm64) | <https://ghcr.io/v2/ggml-org/llama.cpp/tags/list> |
| opencode-provider-error | opencode `packages/llm/src/provider-error.ts` at v1.18.34 (read 2026-10-12) — `isContextOverflow`: 27 message patterns (incl. `/exceeds the available context size/i`, llama.cpp's), 3 exclusions (`rate limit`, `too many requests`, `throttling error:`/`service unavailable:`), and a bodiless 400/413 fallback; `parseAPICallError` returns `type: "context_overflow"` | <https://raw.githubusercontent.com/sst/opencode/v1.18.34/packages/llm/src/provider-error.ts> |
| opencode-provider-npm | opencode `packages/opencode/src/provider/provider.ts` at v1.18.34 (read 2026-10-13) — a config-defined provider's SDK is `model.provider.npm ?? provider.npm ?? existing ?? cloudflare gateway ?? models.dev[id].npm ?? "@ai-sdk/openai-compatible"` (L1547-L1555), and that SDK gets `includeUsage` (L1806) | <https://raw.githubusercontent.com/sst/opencode/v1.18.34/packages/opencode/src/provider/provider.ts> |
| ollama-releases | Ollama releases (read 2026-10-12) — v0.40.3 (11 October) is latest; v0.40.2: "Models downloaded with earlier versions of Ollama are upgraded in the background the first time you run them" and a downgrade below 0.40 needs a re-pull; no note in 0.34.3–0.40.x on context-overflow or truncation behaviour | <https://github.com/ollama/ollama/releases> |

Where used: `llama-cpp-docker`, `llama-cpp-cuda-dockerfile`, `llama-cpp-ghcr`, `opencode-provider-error`, `opencode-provider-npm`, `ollama-releases` and the refreshed `llama-cpp-server` / `llama-cpp-releases` rows → [llamacpp-trial.md](llamacpp-trial.md) and the stack it describes (`server/docker/docker-compose.llamacpp.yml`, `tests/probe-overflow.ps1`); `swe-edit-repo` → the paper row above; `metaharness-adr127` →
independent confirmation of the whole-file-on-large-files regression documented
in [methodology-research.md](methodology-research.md); `opencode-*` → AGENTS.md / docs/reference/
Gotchas ("opencode upgrades itself…"), the addendum in
[adversarial-review-2026-09-29.md](adversarial-review-2026-09-29.md), and the
`autoupdate` comment in `opencode/global/opencode.jsonc`; `opencode-overflow`,
`opencode-compaction` and `ollama-prompt` → `docs/roadmap.md` → "Context
overflow" and `Get-ContextEvents` in `tests/test-tasks.ps1`; `ollama-claude-code`
and `ollama-openclaw` → the same section's "Is this OpenCode, or the plan?"; `hermes-*` →
`docs/roadmap.md` → "Hermes Agent: researched 2026-10-07, parked"; `qwen-code-*`, `goose-*`, `codex-*`,
`cline-*`, `kilo-*`, `crush-*`, `aider-*`, `gemini-*`, `continue-*`, `openhands-*`, `claude-code-*`,
`ollama-openai-compat`, `hermes-quickstart`, `hermes-hooks` (and `ollama-claude-code`, re-read 2026-10-10) →
`docs/roadmap.md` → "Alternatives to OpenCode: researched 2026-10-10"; `llama-cpp-*`, `llama-swap`, `unsloth-*` →
`docs/roadmap.md` → "Replacing Ollama: llama.cpp or Unsloth, researched 2026-10-10". The 2026-10-10 rows were read by three
research agents in this repo's working session, from the docs as they stood that day. Clients this young change
weekly, so re-read before acting on them
(rendered docs pages, no commit to pin: re-read before acting on them). These are read at one
commit: re-check them when opencode's major or minor version moves (Ollama's
on any upgrade).

## Lab engineering posts and technical reports

| ID | Source | URL |
|---|---|---|
| anthropic-infra-noise | "Quantifying infrastructure noise in agentic coding evals", Anthropic Engineering, 2026-02-05 (read 2026-10-21) — resource configuration alone moved Terminal-Bench 2.0 by 6 points (p < 0.01); within noise up to 3× headroom (p = 0.40); infrastructure errors 5.8% at 1×, 2.1% at 3×, 0.5% uncapped; skepticism for gaps under 3 points | <https://www.anthropic.com/engineering/infrastructure-noise> |
| anthropic-evals | "Demystifying evals for AI agents", Anthropic Engineering, 2026-01-09 (read 2026-10-21) — pass@k vs pass^k; read the transcripts; grade outcomes, not paths; isolate trials, since failures on a shared environment limit are not independent; capability vs regression evals | <https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents> |
| anthropic-long-running | "Effective harnesses for long-running agents", Anthropic Engineering, 2025-11-26 (read 2026-10-21) — agents that one-shot, or "declare the job done" too early; progress file, feature list, end-to-end testing | <https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents> |
| anthropic-context | "Effective context engineering for AI agents", Anthropic Engineering, 2025-09-29 (read 2026-10-21) — context rot; compaction tuned to "maximize recall" first; tool-result clearing; note-taking; just-in-time retrieval with grep/glob | <https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents> |
| anthropic-tools | "Writing effective tools for AI agents – with agents", Anthropic Engineering, 2025-09-11 (read 2026-10-21) — truncation and pagination "with sensible default parameter values"; Claude Code caps tool responses at 25,000 tokens by default; actionable error messages | <https://www.anthropic.com/engineering/writing-tools-for-agents> |
| chroma-context-rot | "Context Rot: How Increasing Input Tokens Impacts LLM Performance", Hong, Troynikov and Huber, Chroma, 2025-07-14 (read 2026-10-21) — 18 models; reliability falls with input length even on simple tasks; distractors hurt | <https://www.trychroma.com/research/context-rot> |

Where used: all six → [methodology-research.md](methodology-research.md) → "What the runs say against the research
(2026-10-21)"; `anthropic-evals` also → docs/reference/guards.md (`tests/summarize-rounds.ps1`); `anthropic-evals`,
`anthropic-infra-noise` and `anthropic-long-running` also → [roadmap.md](roadmap.md) ("After the trial" items 6 and 10)
and [adversarial-review-2026-10-23.md](adversarial-review-2026-10-23.md) (all three re-read 2026-10-23). OpenAI's "Unrolling the Codex agent
loop" and "Harness engineering" (openai.com) answered 403 to the fetch tool on 2026-10-21 and are not catalogued until read.

## Model landscape (2026-10-22)

Vendor and aggregator pages: they move weekly, so re-read before acting on them.

| ID | Source | URL |
|---|---|---|
| fireworks-deepseek | "DeepSeek Models: V3.2, R1, Distills, and Production Caveats", Fireworks AI (read 2026-10-22) — R1 distills 1.5B to 70B (Qwen- and Llama-based); tool calling: R1 no, R1-0528 yes, distills "Varies; parsing issues reported" | <https://fireworks.ai/blog/deepseek-models> |
| digitalapplied-h1-2026 | "Open-Weight Models H1 2026: DeepSeek, Qwen, Llama Recap", Digital Applied (read 2026-10-22) — DeepSeek V4 Preview 2026-04-24; V4-Pro 1.6T / 49B active, V4-Flash 284B / 13B active | <https://www.digitalapplied.com/blog/open-weight-models-h1-2026-retrospective-deepseek-qwen-llama> |
| localaimaster-16gb | "Best Ollama Models for 16GB VRAM (2026)", LocalAIMaster, 2026-07-07, updated August 2026 (read 2026-10-22) — `gpt-oss:20b` first; Devstral 24B for agentic coding at short context | <https://localaimaster.com/vram/best-ollama-models-16gb-vram> |

Where used: all three → [roadmap.md](roadmap.md) → "After the trial" item 9.

## Side-project tools (2026-10-22)

Project pages, read once for [fleet-side-projects.md](fleet-side-projects.md); re-read before installing anything.

| ID | Source | URL |
|---|---|---|
| comfyui | ComfyUI, GitHub README (read 2026-10-22) — NVIDIA (CUDA), AMD on Windows and Linux, Intel XPU, Apple Silicon; video models incl. Wan 2.1/2.2, LTX-Video 2, HunyuanVideo 1.5, CogVideoX, Mochi | <https://github.com/comfyanonymous/ComfyUI> |
| wan22 | Wan2.2, GitHub README (read 2026-10-22) — A14B MoE models need at least 80 GB on one GPU; TI2V-5B at least 24 GB with offload flags | <https://github.com/Wan-Video/Wan2.2> |
| sam2 | SAM 2, Meta, GitHub README (read 2026-10-22) — prompt on one frame, masks propagated through the video | <https://github.com/facebookresearch/sam2> |
| gsplat | gsplat, Nerfstudio, GitHub README (read 2026-10-22) — CUDA-accelerated Gaussian-splat rasterization | <https://github.com/nerfstudio-project/gsplat> |
| faster-whisper | faster-whisper, SYSTRAN, GitHub README (read 2026-10-22) — CTranslate2, up to 4× faster than openai/whisper; CPU int8 or CUDA; no AMD listed | <https://github.com/SYSTRAN/faster-whisper> |
| flamenco | Flamenco, Blender (read 2026-10-22) — open-source render manager, GPL 3.0, used in production by Blender Studio | <https://flamenco.blender.org/> |
| immich-ml | Immich, "Hardware-Accelerated Machine Learning" (read 2026-10-22) — CUDA, ROCm, OpenVINO, ARM NN, RKNN; smart search and facial recognition | <https://docs.immich.app/features/ml-hardware-acceleration> |

## Another page to cite from

If a source is new and not yet here, add a row in the matching table. If a
source has no table yet, add one — the grouping above is the current shape, not
a fixed taxonomy.