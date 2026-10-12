# llama.cpp engine trial on the server: protocol and runbook

**Pre-registered 2026-10-12.** The owner approved Phases 0 and 1 of the Ollama replacement the same day
([roadmap](roadmap.md) → "Next up" step 4, "Replacing Ollama"). This file is written before any measurement so the
bar can't move afterwards. It is the trial only: **no seat moves, no profile changes, Ollama is not touched**, and the
engine adapter (Phase 2) does not start unless Gate G1 passes. Results are appended under "Results" by their own PR.

The repo files for the trial are `server/docker/docker-compose.llamacpp.yml`, `server/llamacpp/models.ini`,
`server/scripts/llamacpp-check.sh`, `tests/probe-overflow.ps1`, and the `-Engine llamacpp` mode of
`tests/test-toolcalls.ps1` and `tests/bench-speed.ps1`. This session could only write and syntax-check them (it can't
reach the server); **the commands below are for the owner, or an agent session on the desktop over SSH.** Anything
that needs `sudo` on the server is the owner's ([network-topology](network-topology.md) → "SSH access").

## The question and what would answer it

Does `llama-server` beat Ollama 0.34.3 as the executor engine on the server, in the ways the benchmark has shown to
matter? Five hypotheses, each with the evidence that settles it:

| | hypothesis | evidence |
|---|---|---|
| H1 | **Mechanism.** A request longer than the served context gets an explicit error, not a silent cut; OpenCode classifies it as a context overflow and recovers (or ends the run cleanly), so no brief is lost silently. | `probe-overflow.ps1` on both engines; OpenCode's overflow patterns; the lost-brief runs |
| H2 | **Speed.** Prefill and decode are at least 90% of Ollama's at 3k, 30k and 60k tokens, with equal or better VRAM headroom. | `bench-speed.ps1`, both engines, same sizes |
| H3 | **Tool calls.** `qwen3.6` and `qwen3:8b` still pass the tool-call probe through `/v1/chat/completions`. | `test-toolcalls.ps1 -Engine llamacpp` |
| H4 | **Rounds.** The lost-brief set loses no brief silently; one nudged round of the 15 tasks is no worse than the Ollama round by more than 2. | the harness, classifier 2 |
| H5 | **Operations.** A lost GPU is detectable, and a 24 h soak is clean. | the drill and the soak (measurement E) |

## Held constant, and the baseline

Anything that differs between the Ollama baseline and the trial is a confound, so these are fixed:

| | value |
|---|---|
| Ollama | 0.34.3, the compose pin. **Do not move it during the trial**: 0.40.2 upgrades stored models in the background and needs a re-pull on downgrade ([Ollama releases](https://github.com/ollama/ollama/releases), read 2026-10-12), which would break the sha-pinned blobs this stack reads. |
| llama.cpp | image `server-cuda-b11561` at digest `sha256:20c6e722…` (CUDA 12.8.1 runtime; driver 580.178.04 runs it). A different build is a different era. |
| OpenCode | 1.18.34 |
| Weights | Ollama's own blobs, read-only; the sha256 in `models/server-seats.tsv` is the contract. |
| Context, slots, KV | `c` = the seat table's `num_ctx` (65536 / 32768 / 16384); `parallel = 1`; K and V cache `q8_0` with flash attention. Same as the Ollama compose file. |
| Sampling | what Ollama applies to the same tag. **Must be copied** (step 3): llama-server uses its own defaults for anything the preset does not set. |
| Run host | the **desktop**, as in the first server round. Every run JSON records `runHost`; a round from another run host is a different era. |
| Nudge | `-NudgeOnStop`, stop classifier 2 (`stopNudges.classifier` 2). |

**Ollama baseline already in hand** ([roadmap](roadmap.md) → "Next up" step 3, 2026-10-12, `qwen3.6` at 64k on the
server):

| | Ollama 0.34.3 |
|---|---|
| prefill at 3k / 30k / 60k | 688 / 692 / 674 tok/s |
| decode at 3k / 30k / 60k | 73.1 / 65.0 / 60.6 tok/s |
| placement | 22.68 GB total, 13.59 GB (60%) in VRAM; ~782 MiB of the 16 GB free |
| nudged round of the 15 | 10 of 15 (work packages 8 of 12, real tasks 2 of 3) under **classifier 1** |
| lost briefs | 3 of 15 (`wp-2b`, `wp-4a`, `wp-5a`) |

**Still to collect before Gate G1 can be read (the owner runs it):** one more Ollama nudged round of the same 15 tasks
on the server under **classifier 2**, from the desktop. The 10 of 15 above used classifier 1, so it is not a
like-for-like baseline. (The desktop's matching speed rows are not needed for the server trial.)

## Runbook

Each step says what to record. Nothing below writes to the Ollama volume or edits Ollama's stack.

### 0. Open the window

Ollama keeps `qwen3.6` loaded for 4 h and the card can't hold both engines' copies, so announce the window and free
the GPU:

```bash
docker exec ollama-server ollama ps
docker exec ollama-server ollama stop qwen3.6:35b-a3b-coding      # and any other resident seat
nvidia-smi --query-gpu=memory.used,memory.total --format=csv      # record the idle baseline
```

### 1. Premise check: does Ollama 0.40.3 still cut silently? (about 30 minutes)

The case for leaving rests on Ollama cutting an oversized prompt from the front without saying so
(`wp-2b`'s lost briefs, `qwen3.5:9b`'s crashes). Test that on the current Ollama in a **scratch** container with its own
volume, a small model and a small context. Run the same probe on 0.34.3 first as the control: it must say
SILENT-TRUNCATION, or the probe is not measuring what it claims.

```bash
for v in 0.34.3 0.40.3; do
  docker volume create ollama-scratch-$v
  docker run -d --name ollama-scratch --gpus all -p 11500:11434 -v ollama-scratch-$v:/root/.ollama \
      -e OLLAMA_CONTEXT_LENGTH=4096 -e OLLAMA_NUM_PARALLEL=1 ollama/ollama:$v
  docker exec ollama-scratch ollama pull qwen3:8b            # 5.2 GB
  pwsh tests/probe-overflow.ps1 -Engine ollama -Endpoint http://SERVER_IP:11500 -Model qwen3:8b -NumCtx 4096 -HostLabel server-scratch-$v
  docker rm -f ollama-scratch && docker volume rm ollama-scratch-$v
done
```

| 0.40.3 says | meaning |
|---|---|
| SILENT-TRUNCATION | the premise stands; continue |
| EXPLICIT-ERROR | **stop and report.** The main reason to migrate is weaker; moving Ollama forward becomes an alternative to weigh (a new era for both hosts). The owner decides. |
| ACCEPTED-FULL | `-NumCtx` is wrong for that container; fix it and repeat |

### 2. Bring llama-server up and load the pinned blob

```bash
docker compose -f server/docker/docker-compose.llamacpp.yml up -d
docker inspect --format '{{json .State.Health}}' llamacpp-server      # healthy? (the image's own check probes 8080; ours overrides)
curl -s localhost:8090/health
curl -s -X POST localhost:8090/models/load -H 'Content-Type: application/json' -d '{"model":"qwen3.6:35b-a3b-coding"}'
bash server/scripts/llamacpp-check.sh --url http://localhost:8090
```

Record: **does Ollama's `qwen3.6` blob load?** (If not, the error, and fall back to the matching quant from Hugging
Face, recorded as a variable.) Also the log's offload line (how many layers on the GPU), and `nvidia-smi` memory.

### 3. Sampling fidelity

```bash
bash server/scripts/llamacpp-check.sh --ollama-url http://localhost:11434
docker exec ollama-server ollama show --parameters qwen3.6:35b-a3b-coding
```

Every FAIL is a parameter Ollama applies that the preset doesn't set. Add the matching keys to
`server/llamacpp/models.ini` (`temp`, `top-k`, `top-p`, `min-p`, `repeat-penalty`, `presence-penalty`), commit the
change, and run again until it prints 0 FAIL. Reload the model afterwards. Without this the engine comparison includes a
sampling difference.

### 4. A. Tool-call probe

```powershell
.\tests\test-toolcalls.ps1 -Engine llamacpp -EngineHost http://SERVER_IP:8090 -HostLabel server -Model qwen3.6:35b-a3b-coding,qwen3:8b
```

Compare with the Ollama rows in `tests/results/toolcalls-summary.tsv` (`qwen3:8b` PASS in 60.3 s, `qwen3.6` PASS in
68 s, both including a cold load). Rows go to `tests/results/toolcalls-summary-llamacpp.tsv`.

### 5. B. Placement and speed

Sweep `n-cpu-moe` for `qwen3.6` over 16, 18, 20, 22, 24 (edit the preset, `POST /models/unload`, load again). For each
value:

```powershell
nvidia-smi --query-gpu=memory.used,memory.total --format=csv        # on the server, with the seat loaded and warm
.\tests\bench-speed.ps1 -Engine llamacpp -EngineHost http://SERVER_IP:8090 -HostLabel server -Model qwen3.6:35b-a3b-coding
```

**Selection rule, fixed now so the sweep can't be tuned to a result:** the setting with the highest decode tok/s at 30k
whose free VRAM stays at or above 700 MiB (Ollama's baseline leaves ~782). Ties go to the higher prefill. Record every
setting, not only the winner, and the host's RAM in use. `bench-speed.ps1` leaves placement columns blank for
llama-server; the `nvidia-smi` reading is the placement.

### 6. C. Overflow

**C1, raw.** Expect the explicit error, and that OpenCode would call it an overflow:

```powershell
.\tests\probe-overflow.ps1 -Engine llamacpp -Endpoint http://SERVER_IP:8090 -Model qwen3.6:35b-a3b-coding -NumCtx 65536 -HostLabel server
```

**C2, through OpenCode.** OpenCode 1.18.34 already classifies llama.cpp's text as an overflow
([`provider-error.ts` at that tag](https://raw.githubusercontent.com/sst/opencode/v1.18.34/packages/llm/src/provider-error.ts),
read 2026-10-12: `/exceeds the available context size/i` is in its list). What is **not** known is what the session does
next. Add a provider to the *live* `~/.config/opencode/opencode.jsonc` by hand (not the template; that is Phase 2) and
set `LLAMACPP_SERVER_BASE_URL=http://SERVER_IP:8090/v1`:

```jsonc
"llamacpp-server": {
  "npm": "@ai-sdk/openai-compatible",   // UNVERIFIED: the ollama-* blocks declare none; confirm with `opencode debug config`
  "options": { "baseURL": "{env:LLAMACPP_SERVER_BASE_URL}" },
  "models": {
    "qwen3.6:35b-a3b-coding": { "name": "Qwen3.6 35B-A3B (llama.cpp)", "tool_call": true, "reasoning": true,
      "modalities": { "input": ["text"], "output": ["text"] }, "limit": { "context": 65536, "output": 8192 } },
    "qwen3:8b": { "name": "Qwen3 8B (llama.cpp)", "tool_call": true, "reasoning": true,
      "modalities": { "input": ["text"], "output": ["text"] }, "limit": { "context": 32768, "output": 4096 } }
  }
}
```

Confirm `opencode debug config` still shows `limit` for both (the silent-drop gotcha in AGENTS.md). Then run **one**
`wp-2b` (it loses its brief at the same step every time on Ollama) with a private results folder and read its
transcript for: the error event, whether OpenCode compacted, whether the compaction request itself fit, whether the run
resumed, and the outcome. Also whether `opencode/plugins/compaction-continue.js` (written for threshold-triggered
compaction) behaves when compaction follows an *error*.

### 7. D. Task rounds

Same flags as the Ollama baseline round, one change: `-Model llamacpp-server/qwen3.6:35b-a3b-coding`. Use
`test-tasks.ps1` directly (the batch only offers Ollama and hosted providers), with the private manifest and a trial
results folder (`-TaskManifest … -ResultsDir …`, `-NudgeOnStop`; the `ASSISTED` marker keeps these rows out of
`tests/results/`).

1. The lost-brief set × 3: `wp-2b`, `wp-4a`, `wp-5a`, `kane-08`.
2. One nudged round of the 15 tasks.

Run a GPU watch beside them, because the harness's GPU-placement check reads Ollama's `/api/ps` and is skipped for
this provider:

```bash
while true; do date -Is; docker exec llamacpp-server nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader 2>&1; sleep 60; done >> gpu-watch.log
```

A run that dies on the overflow error is recorded by the harness as `_INFRA_` with no row (a non-zero `opencode run`
exit). **Count those by hand** from the transcripts as "overflow killed the run"; they are the H1 finding, not noise.
Per run record: outcome, whether a brief was lost (`askedForTask`), compactions, the overflow errors seen, wall time,
`runHost`.

### 8. E. GPU-loss drill and soak

- **E1 (owner, `sudo`).** With a model loaded: `sudo systemctl daemon-reload`, then `docker exec llamacpp-server
  nvidia-smi -L` and `docker ps`. Expect the GPU kept (explicit devices). If it is lost: what does llama-server do,
  does `/health` stay green, does generation continue on the CPU, is anything logged?
- **E2.** Find a signal for "this seat is on the CPU" that the desktop can read over HTTP (llama-server has no
  `/api/ps`). Candidates: the load log's offload line, `nvidia-smi` memory, `/props`. Record which one works; Phase 2's
  placement check depends on it.
- **E3.** 24 h: load and unload `qwen3:8b` and `qwen3.6` alternately every 10 minutes with one request each; log host RAM
  and VRAM; any growth, crash or hang counts.

### 9. Close the window

```bash
docker compose -f server/docker/docker-compose.llamacpp.yml down
docker ps --format 'table {{.Names}}\t{{.Status}}'     # ollama-server healthy
```

## Gate G1

Pass-rate alone cannot decide this: at 15 tasks × 1 run the repo's own test cannot separate 8 of 11 from 11 of 11
(Fisher exact p ≈ 0.21, [roadmap](roadmap.md)). So the gate is mechanism first. **Go requires every row.**

| | criterion | source |
|---|---|---|
| must | `qwen3.6` and `qwen3:8b` PASS the tool probe through `/v1` | step 4 |
| must | an oversized request is an explicit error that OpenCode classifies as an overflow, and the session recovers or ends cleanly; **zero silent lost briefs** across the lost-brief set (Ollama baseline: 3 of 15) | steps 1, 6, 7 |
| must | GPU loss is detectable, and was detected in the drill | step 8 |
| must | the soak is clean | step 8 |
| speed | prefill and decode ≥ 90% of the Ollama rows at 3k, 30k and 60k, at equal or better VRAM headroom (≥ 700 MiB free) | step 5 |
| screen | the nudged round of the 15 is no worse than the classifier-2 Ollama round by more than 2. This catches a collapse; it cannot show a win. | step 7 |

Reading "recovers or ends cleanly": **recovers** (OpenCode compacts and the run carries on) is the strong result.
**Ends cleanly** (a classified, loud failure instead of a silent one) passes the mechanism row but is reported as such:
lost briefs become visible, which is better data, not a better pass rate, and Phase 2 would then have to decide
recovery on the client side.

- **Go:** record the results here, in the roadmap and in CHANGELOG, and propose Phase 2 (the engine adapter) for its own
  approval.
- **No-go:** record the same, stop the container, change nothing else. Ollama was never touched.

## Stop conditions

Stop and report, don't push on, if: the premise check shows 0.40.x erroring explicitly; llama-server can't load the
pinned blob *and* no matching Hugging Face quant reproduces a tool-probe PASS; the GPU is lost in a way nothing here
can detect; or any step would write to the Ollama volume (the stack mounts it read-only and must stay that way).

## Known unknowns, to be answered and written down in "Results"

| unknown | answered by |
|---|---|
| Ollama's `qwen3.6` blob loads in llama.cpp (it may use a layout only Ollama's own engine reads) | step 2 |
| `parallel = 1` in the preset really gives one slot with the full `c` (`/props` `total_slots`, `n_ctx`) | step 2, `llamacpp-check.sh --url` |
| `n-gpu-layers = 0` leaves the CPU companion with no VRAM (a CUDA build may still reserve a context); `device = none` is the fallback | step 2, `nvidia-smi` |
| `<think>` output: llama-server may return it as `reasoning_content` rather than inline; how OpenCode shows it, and the empty-content trap at small `max_tokens` | steps 4, 6 |
| the vision projector (`mmproj`) is a separate file the preset does not load, so the `llamacpp-server` seat is text-only while Ollama's lists image input | noted for Phase 2 |
| the real overflow response's status code and body shape (the upstream test asserts only "not 200" and the phrase) | step 6 C1 |
| router mode counts models (`--models-max`), not VRAM, so co-residency of `qwen3.6` and the CPU 3b is sized by hand | step 2, step 7 |
| the image's `curl` healthcheck works as written | step 2 |

## Sources

Read for this protocol (all dates 2026-10-12 unless stated): the
[`llama-server` README](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/tools/server/README.md) (router mode,
presets, `/models/load` and `/models/unload`, `autoload`, `timings`, `/props`, flags);
[its context-shift test](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/tools/server/tests/unit/test_ctx_shift.py)
(non-200 and "exceeds the available context size"); the
[llama.cpp Docker docs](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/docs/docker.md) and the
[CUDA Dockerfile](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/.devops/cuda.Dockerfile) (entrypoint
`/app/llama-server`, `curl` installed, its own healthcheck on port 8080, CUDA 12.8.1 runtime); the registry's per-build
tags and the `server-cuda-b11561` digest; the
[llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases); OpenCode's
[`provider-error.ts` at v1.18.34](https://raw.githubusercontent.com/sst/opencode/v1.18.34/packages/llm/src/provider-error.ts);
and the [Ollama releases](https://github.com/ollama/ollama/releases). Short names and what each said are in
[references.md](references.md).

## Results

*Not run yet. Appended by the PR that records them.*
