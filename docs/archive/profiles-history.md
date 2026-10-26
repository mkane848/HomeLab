# Profiles: history

Moved out of [`docs/profiles.md`](../profiles.md) so that page can stay a lookup table. Dated narrative, newest first.

| Date | Change | Why |
|---|---|---|
| 2026-10-22 | `dev-workflow-server-llamacpp` became the default | llama.cpp scored 54 of 60 against Ollama's 47 on the 15 real tasks (unreplicated: engine, plugin and checkout eras differ; see the [adversarial review](../adversarial-review-2026-10-23.md)) |
| 2026-10-13 | `dev-workflow-server` became the default | The same seat as the desktop's, about twice the speed. It was brought back from `parked/` on 2026-10-12, when the server returned on a replacement board |
| 2026-10-03 | Main seat `qwen3:14b` → `qwen3.6:35b-a3b-coding`; small model `qwen2.5-coder:3b` → `qwen2.5-coder-3b-cpu` | `qwen3.6` won the [main-seat trial](../main-seat-trial.md). It fills the GPU and spills to RAM, so the GPU 3b evicted it at every session start; the CPU copy (`num_gpu 0`, derived by `startup.ps1`) does not |
| 2026-10-03 | `dev-workflow-quality` stopped exporting `DEV_DOCKER_STACK=true` | `qwen3.6` plus its companion hold ~19 GB of 32 GB RAM; with the Postgres/Redis stack up (WSL alone 2.1 GB) available memory fell under 1.1 GB and the model paged mid-turn |
| 2026-09-20 | `dev-node3` added | Third node onboarded |
| 2026-09-17 | Main seat `qwen2.5-coder:14b` → `qwen3:8b` → `qwen3:14b`; `/implement` and its coder subagent removed | Only the qwen3 family and `devstral:24b` passed the tool-call probe that day. A coder or reasoner in an agent seat reports edits it never made |
| 2026-09-17 | `qwen3:14b` seated, reverted, re-seated the same day | It issued **6 write calls for one request** (the 8B issued 1) and took 217 s against 96 s, then won the seat back for its loose-prompt intent handling. The repeated-call risk is the known cost; if a session shows repeated `← Write` lines, drop to `qwen3:8b`. See [troubleshooting](../troubleshooting.md) |
| 2026-09-17 | Seven server profiles parked | The harness emitted 38 WARNs, all "server unreachable". Warnings you learn to scroll past are how the original config bug survived for weeks |

## Reasoner placement (when the parked profiles were live)

There was no single "reasoner" profile, by design: `dev-server-all` ran DeepSeek-R1 14B on the server, `dev-local-only` and `dev-desktop-only` ran it on the desktop (native Vulkan, 16k bake), `dev-full` allowed both. DeepSeek-R1 cannot call tools (see the [glossary](../glossary.md)), so it is a no-tools model now.

## Memory arithmetic for the quality pair (measured 2026-10-03)

Ollama maps the whole `qwen3.6` file into RAM (`CPU_Mapped model buffer size = 20293.98 MiB` beside `Vulkan0 model buffer size = 11988.43 MiB`). The `qwen3.6` process held 16.56 GB of private memory and the companion 2.40 GB, leaving ~3.5 GB of 32 GB: no room for WSL and the Docker dev stack. Before that the pair was `qwen3:14b` @32k + `qwen2.5-coder:3b` = 13.29 GB, both on the GPU.
