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

## Status and handoff (2026-10-13; Phase 1 done 2026-10-16)

**2026-10-16: Phase 1 is done and Gate G1 is go** ("Results" below). The window is closed: llama-server is down, the
server's Ollama serves `qwen3.6` on the GPU again, and daily use can go back to `dev-workflow-server`. Phase 2 (the
engine adapter) was approved the same day and is done: "Phase 2 live window" below. The large-file fix that followed
was measured 2026-10-17/18: "Read-budget window" below (`kane-08` 3 of 5, the round 41 of 45 over three reps, the window closed
again with Ollama back on the GPU). Its plugin-off control ran 2026-10-19/20: "Plugin-off control" below (four reps, 54
of 60 on against 50 of 60 off, 0 against 146 refused requests; `kane-08` 6 of 10), and one plugin-on round on
Ollama 2026-10-20: "Ollama with the plugin" below (12 of 15, no front-drops). The rest of this section is the
handoff as it stood before the window.

**Where it stands.** Phase 0 (the repo half) is on `main`: PR #115 landed the stranded work of #114
(`bench-speed.ps1`, `test-gpu-placement.ps1`, `runHost`, the harness's GPU-placement check), and PR #116 added this
protocol and the trial's files. **Nothing has been run against a real server, Ollama or llama-server**: the session that
wrote it can't reach the LAN. What was checked is what a sandbox can check:

| check | result |
|---|---|
| `test-bench-speed.ps1` / `test-toolcalls-engine.ps1` / `test-probe-overflow.ps1` / `test-llamacpp-stack.ps1` | 81 / 44 / 51 / 36 checks pass, plus 16 Python tests, on **PowerShell 7.4.6 on Linux only** |
| `bash server/scripts/llamacpp-check.sh` on the real preset and seat table | 7 OK, 0 FAIL |
| syntax of every changed script (`bash -n`, `[Parser]::ParseFile`) | clean |
| the four guards on the desktop (Windows 11, PowerShell 7.4.20; 5.1 was dropped by the owner) | pass, 2026-10-12, after the `python3` Store-placeholder fix |
| any real host | **not run** |

**Phase 1 has not started.** (The baseline round it needs now exists: see "Held constant, and the baseline".) No step of the runbook has run, and Phases 2–6 are neither
started nor approved ([roadmap](roadmap.md) → "Replacing Ollama" lists them).

**Next, in order** (the owner, or an agent session on the desktop over SSH; `sudo` steps are the owner's):

- [x] Run the four guards on the desktop under PowerShell 7 on Windows. Done 2026-10-12 (desktop, PowerShell 7.4.20,
  Windows 11): all four pass. One script bug surfaced and is fixed: `python3` on that PC is the Microsoft Store
  placeholder (on `PATH`, exits 49), so `llamacpp-check.sh` and `test-llamacpp-stack.ps1` now use the first of `python3`
  and `python` that actually runs. Windows PowerShell 5.1 is no longer a target (owner, 2026-10-12).
- [x] The like-for-like baseline: one more Ollama nudged round of the 15 on the server under **classifier 2**, from the
  desktop, into a private `-ResultsDir`. It needs Ollama exactly as it is today, so it comes before the window below.
- [x] **Done 2026-10-13 to 16 (owner, 2026-10-13: server-side work first, nothing else moving on the server meanwhile).** Announce
  one GPU window and work the runbook top to bottom (steps 0–9). Step 1 can end the trial early: if 0.40.3 says
  EXPLICIT-ERROR, stop and report to the owner. **The daily default is the server since 2026-10-13**
  (`dev-workflow-server`), so the announcement matters: during the window daily use goes to `opencode quality` (the
  desktop seat), because step 0 stops the server's Ollama seat and daily requests would skew step 5's speeds and
  step 7's rounds. `dev-workflow-server`'s small model (the CPU 3b on the server) is unchanged until the trial is
  over, because the baseline rounds ran with it.
  **Route chosen 2026-10-13: a Claude Code session on the desktop**, started with
  [`agent-notes/prompt-llamacpp-window.md`](agent-notes/prompt-llamacpp-window.md).
- [x] ~~Owner, with `sudo`: step 8's E1, `sudo systemctl daemon-reload` against the running llama container.~~ A real
  `daemon-reload` (snapd, 2026-10-15 04:37 UTC) came during the soak and the GPU was kept; the owner's drill was not
  run ("Results" → step 8).
- [x] Append the numbers and the Gate G1 verdict under "Results" by a PR of their own, with the roadmap and CHANGELOG
  entries the gate section asks for.

**Open items the runbook already carries, listed so they aren't lost:**

- The preset does **not** yet copy Ollama's sampling parameters; `llamacpp-check.sh --ollama-url` fails until step 3 does.
- `n-cpu-moe = 20` is a starting value; step 5 sweeps it under a rule fixed in advance.
- ~~The `llamacpp-server` OpenCode provider snippet (step 6) has an unverified `npm` field.~~ Settled 2026-10-13 from
  OpenCode's source: no `npm` field is needed (step 6).
- `bench-speed.ps1 -Engine llamacpp` reports a load time that is approximate, and no placement; the `nvidia-smi`
  reading is the placement.
- The compaction plugin is pinned to OpenCode 1.18.34, and `probe-overflow.ps1` embeds that version's overflow patterns;
  re-copy them if OpenCode is upgraded during the trial.
- ~~"Known unknowns" at the end of this file are all still unknown.~~ Answered in "Results" → step 2 (2026-10-13).

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
| Nudge | `-NudgeOnStop -StopClassifier 2` (`stopNudges.classifier` 2). The harness default became classifier 3 on 2026-10-13, so the trial's rounds, like the baseline rounds 2 and 3, must pass `-StopClassifier 2` (`run-tasks-batch.ps1` takes it too). |

**Ollama baseline already in hand** ([roadmap](roadmap.md) → "Next up" step 3, 2026-10-12, `qwen3.6` at 64k on the
server):

| | Ollama 0.34.3 |
|---|---|
| prefill at 3k / 30k / 60k | 688 / 692 / 674 tok/s |
| decode at 3k / 30k / 60k | 73.1 / 65.0 / 60.6 tok/s |
| placement | 22.68 GB total, 13.59 GB (60%) in VRAM; ~782 MiB of the 16 GB free |
| nudged round of the 15, classifier 1 (round 1) | 10 of 15 (work packages 8 of 12, real tasks 2 of 3) |
| nudged round of the 15, **classifier 2** (rounds 2 and 3, the like-for-like baseline, desktop run host, 2026-10-12/13) | four reps: 12, 12, 11, 11 of 15 (mean 11.5; 46 of 60). Eight tasks pass 4 of 4, `wp-5b` 0 of 4; `wp-7a`, `real-01` 2 of 4 |
| lost briefs | round 1: 3 of 15 (`wp-2b`, `wp-4a`, `wp-5a`). Round 2: front-drops in 9 of 30 runs: `wp-2b` (both reps), `wp-4a`, `wp-5b` (both reps, the largest, about 78,700 tokens), `wp-7a` (both reps), `wp-6f`, `wp-5a` rep 2. Add `wp-5b` and `wp-7a` to the set below. |
| CPU contention (server) | decode 70 / 69 / 62 tok/s idle, 27 / 25 / 26 with 4 busy threads, 20 / 23 / 20 with 8; prefill unchanged. Nothing else may run on the server during the trial. |

**The like-for-like baseline is collected** (rounds 2 and 3 above, four reps with identical settings). The reps score
12, 12, 11 and 11 of 15, and individual tasks are not stable (`wp-7a`, `real-01`, `real-02`; `wp-5b` never passes), so
Gate G1's "no worse by more than 2" tolerates about the whole spread: it is a screen for a collapse and nothing finer.
A llama.cpp round scoring 10 or more of 15 would pass it (mean 11.5 minus 2, rounded up). Note for the trial's rounds: round 2 ran from a checkout whose task worktrees sit inside it
(`<checkout>/tests/.worktrees/<id>`), and in two runs the model went up to the checkout's own `AGENTS.md`; run the trial
rounds from a checkout with the same layout, or record the path. The desktop's speed rows (`bench-speed.tsv`) are not
needed for the server trial.

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
  "options": { "baseURL": "{env:LLAMACPP_SERVER_BASE_URL}" },
  "models": {
    "qwen3.6:35b-a3b-coding": { "name": "Qwen3.6 35B-A3B (llama.cpp)", "tool_call": true, "reasoning": true,
      "modalities": { "input": ["text"], "output": ["text"] }, "limit": { "context": 65536, "output": 8192 } },
    "qwen3:8b": { "name": "Qwen3 8B (llama.cpp)", "tool_call": true, "reasoning": true,
      "modalities": { "input": ["text"], "output": ["text"] }, "limit": { "context": 32768, "output": 4096 } }
  }
}
```

**No `npm` field** (settled 2026-10-13): OpenCode v1.18.34 gives a config-defined provider without one
`@ai-sdk/openai-compatible` whenever its id is not a models.dev provider, which `llamacpp-server` is not, exactly as for the
`ollama-*` blocks; that SDK also gets `includeUsage`, so token usage still reaches the run JSONs
([`provider.ts` at that tag][opencode-provider-npm], lines 1547-1555 and 1806). Confirm `opencode debug config` still shows `limit` for both (the silent-drop gotcha in AGENTS.md). Then run **one**
`wp-2b` (it loses its brief at the same step every time on Ollama) with a private results folder and read its
transcript for: the error event, whether OpenCode compacted, whether the compaction request itself fit, whether the run
resumed, and the outcome. Also whether `opencode/plugins/compaction-continue.js` (written for threshold-triggered
compaction) behaves when compaction follows an *error*.

### 7. D. Task rounds

Same flags as the Ollama baseline round, one change: `-Model llamacpp-server/qwen3.6:35b-a3b-coding`. Use
`test-tasks.ps1` directly (the batch only offers Ollama and hosted providers), with the private manifest and a trial
results folder (`-TaskManifest … -ResultsDir …`, `-NudgeOnStop -StopClassifier 2`; the `ASSISTED` marker keeps these rows out of
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

**Phase 1 ran 2026-10-13 to 16** on the server, from a Claude Code session on the desktop (run host: the desktop for every
task run). Raw rows: `tests/results/overflow-probe.tsv`, `toolcalls-summary-llamacpp.tsv`, `bench-speed.tsv`, `llamacpp-soak.tsv`. Task runs
are assisted (nudged) and stay in the private results (`llamacpp-c2`, `llamacpp-lostbrief`, `llamacpp-round`).

**Gate G1: go.** Every row passes (table at the end of this section). The mechanism row passes on the owner's reading,
"loud, not silent" (4 of 12 lost-brief runs looped to the cap and are reported as not recovered). The drill row rests
on a real `daemon-reload` that happened during the soak, not on the owner's `sudo` drill. Phase 2 is not started: it
needs its own approval.

### Declared amendments (made during the window, each before the measurement it affects)

| amendment | why | effect |
|---|---|---|
| `alias` per seat in `models.ini`; the checker accepts aliases and FAILs a `:` section without one | router mode rewrites colon names (`qwen3.6:35b-a3b-coding` → `qwen3.6:CODING`), so the seat ids OpenCode sends did not exist | none on measurements; the response's `model` field still shows the rewritten id |
| `device = none` for the CPU 3b | `n-gpu-layers = 0` still took 332 MiB of VRAM (a CUDA context); `device = none` takes 0 | the runbook's named fallback |
| MTP speculative decoding copied from Ollama (`spec-type = draft-mtp`, `spec-draft-n-max = 2`) | Ollama 0.34.3 runs its bundled llama-server with exactly these flags (its own log, below), so leaving them out compared unlike settings | **the speed row is judged on the MTP arm**; the no-MTP sweep is kept as supplementary data; step 7 ran with MTP |
| harness: an `opencode run` that exits 1 with only context-overflow errors and ends on a finished step is graded (`Get-OverflowRecovery`, `tests/test-overflow-recovery.ps1`) | opencode 1.18.34 exits 1 after any overflow even when it compacted and finished; C2 (14 overflows, an edit, 130/130 tests) was filed as infrastructure | Ollama never sends this error, so no Ollama row is affected; an unrecovered overflow says "overflow killed the run" |
| `server/scripts/llamacpp-soak.sh` | step 8's E3 had no script | — |
| order: the soak (E3) ran before the round's last two tasks (`wp-5b`, `wp-6f`) | Windows Update restarted the desktop at 00:29 on 2026-10-14, mid-`wp-5b`; the owner chose to start the soak first | none expected: the two runs measure the same preset |

### Step 1. Premise: Ollama still cuts silently

| engine | sent | evaluated | verdict |
|---|---|---|---|
| Ollama 0.34.3 (scratch container, `qwen3:8b`, 4096) | ~5,356 | 2,050 (38%) | SILENT-TRUNCATION |
| Ollama 0.40.3 (scratch container, same) | ~5,361 | 2,050 (38%) | SILENT-TRUNCATION |
| Ollama 0.40.4 (node3, `qwen3:8b`, 32768; supplementary, 2026-10-14) | ~42,631 | 16,386 (38%) | SILENT-TRUNCATION |

The needle in the first line was lost every time. **Why**, from Ollama 0.34.3's own log and source: Ollama runs its
bundled llama-server (0.4.1-dev, `391fac164`) with `--context-shift --keep 4` (and `--no-jinja --chat-template chatml`,
the vision projector, `--spec-type draft-mtp --spec-draft-n-max 2`, `-b 512 -ub 512`), and its Go front end cuts the
prompt itself (`llm/llama_server.go:318` at v0.34.3). A per-request `shift: false` on `/api/chat` or `/api/generate`
turns the cut into a 400 (`:299`, `server/sched.go:134`), but there is no environment variable and `/v1`
(`openai/openai.go`) has no such field, and the 400's text matches none of OpenCode 1.18.34's 27 overflow patterns.
A `/v1`→`/api/chat` proxy with `shift: false` plus an error rewrite would close it; not pursued (owner, 2026-10-13: the
plan is to leave Ollama).

### Step 2. Bring-up (known unknowns)

| unknown | answer |
|---|---|
| Ollama's `qwen3.6` blob loads in llama.cpp | **yes**, read-only from the Ollama volume, in ~15 s |
| `parallel = 1` gives one slot with the full `c` | **yes**: `total_slots` 1, `n_ctx` 65536 |
| `n-gpu-layers = 0` leaves the CPU 3b with no VRAM | **no**: 332 MiB (a CUDA context). `device = none`: 0 MiB |
| the image's healthcheck works as written | **yes** |
| router mode counts models, not VRAM | **confirmed**: `qwen3:8b` beside `qwen3.6` fails on a 4.87 GB CUDA allocation, and `POST /models/load` answers `{"success":true}` before the failure (read `GET /models` for `loaded` / `failed`) |
| colon names | rewritten by router mode (above); fixed with `alias` |
| the offload line | not logged at the default level |
| the real overflow response | HTTP 400, `exceed_context_size_error`, with `n_prompt_tokens` and `n_ctx` in the body (step 6 C1) |
| `<think>` output | split out as `reasoning_content` (`reasoning_format: deepseek`), never inline. In OpenCode's run transcripts it looks the same as on Ollama: no reasoning parts, no `<think>` text, 0 reasoning tokens recorded (`wp-0a` on both engines) |
| the vision projector | not loaded: the seat is text-only (noted for Phase 2) |

### Step 3. Sampling

Copied from what Ollama applies to each tag: `qwen3.6` temperature 0.6, top-k 20, top-p 0.95, min-p 0, repeat penalty 1,
presence penalty 0; `qwen3:8b` the same without the presence penalty. `llamacpp-check.sh --ollama-url`: 0 FAIL, 23 OK.

### Step 4. Tool-call probe through `/v1` (H3)

| seat | llama-server | Ollama 0.34.3 (cold load, page cache warm) |
|---|---|---|
| `qwen3.6:35b-a3b-coding` | PASS, 7.1 s (2.3 s with MTP) | 68 s |
| `qwen3:8b` | PASS, 3.0 s | 60.3 s |

### Step 5. Placement and speed (H2)

Swept `n-cpu-moe` 16–24 on both arms; the pre-registered rule picks the lowest value with ≥ 700 MiB free: **16**.

| arm, `n-cpu-moe` 16 | VRAM free | prefill 3k / 30k / 60k (tok/s) | decode 3k / 30k / 60k (tok/s) |
|---|---|---|---|
| Ollama 0.34.3 baseline | ~782 MiB | 688 / 692 / 674 | 73.1 / 65.0 / 60.6 |
| llama.cpp, MTP (**judged**) | 1,477 MiB | 728 / 754 / 721 (106 / 109 / 107%) | 86.4 / 76.6 / 67.9 (118 / 118 / 112%) |
| llama.cpp, no MTP (supplementary) | 2,383 MiB | 746 / 763 / 732 | 65.9 / 59.2 / 54.3 (90 / 91 / 89.6%) |

The full sweep (one rep per size; rows in `tests/results/bench-speed.tsv`):

| `n-cpu-moe` | no MTP: VRAM free | prefill 3k / 30k / 60k | decode 3k / 30k / 60k | MTP: VRAM free | prefill 3k / 30k / 60k | decode 3k / 30k / 60k |
|---|---|---|---|---|---|---|
| 16 | 2,383 MiB | 746 / 763 / 732 | 65.9 / 59.2 / 54.3 | 1,477 MiB | 728 / 754 / 721 | 86.4 / 76.6 / 67.9 |
| 18 | 3,315 MiB | 683 / 699 / 668 | 61.9 / 56.9 / 51.9 | 2,407 MiB | 667 / 685 / 655 | 75.0 / 75.0 / 68.2 |
| 20 | 4,245 MiB | 658 / 633 / 609 | 57.4 / 54.0 / 50.2 | 3,337 MiB | 657 / 628 / 600 | 71.1 / 66.1 / 63.6 |
| 22 | 5,107 MiB | 571 / 590 / 564 | 55.1 / 51.2 / 46.9 | 4,201 MiB | 565 / 586 / 556 | 70.4 / 66.7 / 63.1 |
| 24 | 6,037 MiB | 560 / 538 / 518 | 51.1 / 48.2 / 44.8 | 5,131 MiB | 520 / 534 / 514 | 62.6 / 59.7 / 58.5 |

Each step of two more expert layers on the CPU frees about 0.9 GB of VRAM and costs a few percent of speed (up to 13% in
one step). MTP costs about 0.9 GB and buys 21–35% decode, for 0–7% of prefill. Host RAM in use 2.0–2.3 GB. Speed row: **pass** (on the MTP arm).

### Step 6. Overflow (H1)

- **C1:** an oversized request gets HTTP 400 `exceed_context_size_error` with `n_prompt_tokens` and `n_ctx`, and
  OpenCode 1.18.34's patterns classify it (`probe-overflow.ps1`: EXPLICIT-ERROR).
- **C2:** `wp-2b` through OpenCode: the first request overflowed (69,574 tokens), then 14 overflow → compaction cycles,
  the brief kept in every summary (the compaction requests themselves fit, ~6k), then an edit and visible tests
  130/130, ending on `stop`. opencode exited 1 anyway, which is what the harness amendment above handles. The
  compaction plugin does not match OpenCode's post-overflow message ("…large media attachments"), so it did not rewrite
  it.

### Step 7. Task rounds (H1, H4)

**Lost-brief set**, 3 reps, nudged, classifier 2, 45-minute cap:

| task | result | overflows (each run) | wall (s) |
|---|---|---|---|
| `wp-2b` | 3 / 3 | 9, 2, 6 | 571, 327, 555 |
| `wp-4a` | 2 / 3 | **43 (timeout)**, 12, 14 | 2,700, 901, 1,288 |
| `wp-5a` | 3 / 3 | 3, 4, 8 | 767, 688, 860 |
| `kane-08` | 0 / 3 | **16, 18, 19 (all timeouts)** | 2,700 × 3 |

- **Zero silent lost briefs** (Ollama baseline: 3 of 15). No run asked what its task was (`askedForTask`), and every
  compaction summary kept the brief.
- **58 overflows recovered** in the 8 finished runs. **4 runs did not recover**: each re-read the same large files after
  every compaction, overflowed again, and looped until the cap (`kane-08` rep 3: 75 tool calls, all reads of
  `signals.ts` / `signals.test.ts`, 0 edits).
- **Why:** `kane-08`'s two files are ~131 KB and ~185 KB, roughly 40k + 56k tokens against a 64k window, so the task
  cannot be done by reading whole files on any engine (on Ollama the same task lost its brief three times). `wp-4a`'s six
  files are ~60k tokens, at OpenCode's 57,344-token compaction threshold: it looped once in three. The fix is client-side
  (read ranges or search instead of whole files): Phase 2.
- **Reading of the mechanism row (owner, 2026-10-14): loud, not silent.** The looping runs never lost a brief silently;
  every overflow was an explicit, logged error. They count under "ends cleanly" and are reported as **not recovered: 4 of
  12**.

**Round of 15**, nudged, classifier 2. A Windows Update restart of the desktop (2026-10-14 00:29) cut it off during
`wp-5b`. `wp-5b` and `wp-6f` ran on 2026-10-16 at the same commit and settings, after the soak, and the summary rows of
the first 13 were rebuilt from their run JSONs:

| | |
|---|---|
| passed | **11 of 15** on every gate: `real-01`, `real-03`, `wp-0a`, `wp-1a`, `wp-2b`, `wp-3a`, `wp-4a`, `wp-6a`, `wp-6f`, `wp-7a`, `wp-9a` |
| failed | `real-02` (0 edits: "AGENTS.md is already up to date"); `wp-3b` (hidden tests 210/210, but 612 lines changed against a 400-line ceiling); `wp-5a` (0 edits: after a compaction it named its task and asked "Shall I proceed?"; classifier 3 would have nudged it, the trial holds classifier 2); `wp-5b` (2 visible tests broken, hidden tests 246/247; it failed in every Ollama round too) |
| overflows | 16, all recovered (`wp-2b` 3, `wp-4a` 7, `wp-5a` 5, `wp-5b` 1) |
| wall time | 5,191 s for the 15 tasks; the four Ollama classifier-2 rounds took 6,054 to 10,114 s (mean 8,016) |
| Ollama classifier-2 rounds | every gate: 11, 12, 11, 11 of 15 (mean 11.25); hidden tests alone: 12, 12, 11, 11 (the roadmap's "12 of 15 in each rep" for round 2 counts this way). `nudged-server-2` and `-3`, two rounds each, 2026-10-12/13; `wp-5b` failed in all four, `real-02` in three. The first server round (classifier 1) scored 10 both ways |
| this round, both ways | every gate: **11 of 15**; hidden tests alone: **12 of 15** (`wp-3b` passes its hidden tests and fails only the line ceiling) |

Screen: **pass.** 11 of 15 against Ollama's 11, 12, 11, 11 (every gate), and 12 against 12, 12, 11, 11 (hidden tests
alone): level with Ollama either way, at about two thirds of the wall time. As the gate says, this rules out a collapse
and cannot show a win.

### Step 8. Operations (H5)

- **E1: the GPU was kept through a real `daemon-reload`, which happened by itself during the soak.** At 04:37:48 UTC on
  2026-10-15, snapd ran `systemctl daemon-reload` (`Reload requested from client PID … ('systemctl') (unit
  snapd.service)`, for a `core22` refresh). That is the same kind of event that silently cost Ollama's container the GPU on
  2026-10-12, and it came while `qwen3.6` was loaded (soak cycle 77, loaded 04:34). Every later load landed on the GPU
  at the same VRAM (cycles 78–143), the healthcheck (`nvidia-smi -L` inside the container) stayed `healthy`, and on
  2026-10-16 the in-container `nvidia-smi -L` still listed the RTX 4070 Ti SUPER. **Gap:** nothing asked the model that
  was loaded during the reload for a generation before it was unloaded at 04:44, and the owner's own `sudo` drill was
  not run (the owner was away; the window closed on the natural event). The explicit device nodes plus the GPU-aware
  healthcheck, already the fix on the Ollama compose file, hold for this container too.
- **E2: no HTTP signal.** `/props` (router or per model) and `/slots` carry no placement; `/metrics` is off and carries
  none; `GET /models` shows each child's *configured* args (`--device none`, `--n-cpu-moe 16`), not where it actually
  runs. **What works:** `nvidia-smi --query-compute-apps=pid,used_memory` over ssh, with `ps` mapping each child pid
  (`--port`, `--alias`) to its seat. With `qwen3.6` (GPU) and the CPU 3b both loaded, only `qwen3.6` was listed
  (14,930 MiB); a GPU seat missing from that list is the CPU signature. Each reply's `timings.predicted_per_second` is
  an HTTP hint (85 tok/s for `qwen3.6`, 14.5 for the CPU 3b) but not a signal: CPU contention alone has taken
  `qwen3.6` to ~20 tok/s. Phase 2's placement check needs the ssh call or a small HTTP wrapper for `nvidia-smi`.
- **E3 soak: clean.** 2026-10-14 15:44 to 2026-10-15 15:44 UTC, `qwen3:8b` and `qwen3.6` alternately every 10 min
  (`server/scripts/llamacpp-soak.sh`; its 144 rows are `tests/results/llamacpp-soak.tsv`): **144 of 144 cycles ok**. Every load succeeded and every request returned 200;
  the container stayed `healthy` with 0 restarts.

  | seat | cycles | load (s) | VRAM after load | host RAM in use, mean per 6 h block |
  |---|---|---|---|---|
  | `qwen3:8b` | 72 | 3.1 every time | 7,545 MiB every time | 1,709 / 1,710 / 1,722 / 1,697 MiB |
  | `qwen3.6:35b-a3b-coding` | 72 | 6.1 (once 12.1, the first) | 14,899 MiB every time | 2,172 / 2,180 / 2,195 / 2,167 MiB |

  No growth in either column, and no hang. The day's apt and snap timers ran inside the window, including the reload
  above.

### Phase 2 live window (2026-10-16)

About 50 minutes on the server after PRs #128, #129 and #130 merged, from the desktop (PowerShell 7.4, OpenCode
1.18.34, llama.cpp build b11561, Ollama 0.34.3). The stack files on the server matched `main` byte for byte. Live
OpenCode config: the repo template staged by hand (the local half of `sync-opencode.ps1 -Template`; before it, the live
file was the pre-#128 template exactly).

| check | result |
|---|---|
| `GET /props?model=qwen3%3A8b&autoload=false` on an unloaded seat | HTTP 400 "model is not loaded"; all three seats still `unloaded` afterwards: the check never loads a seat |
| `/v1/models` shape | `{data, object}`; each entry has `id`, `aliases`, `status`, `context_length` and more. Colon ids are rewritten (`qwen3:8B`, `qwen3.6:CODING`); the exact tag is in `aliases` |
| the llama.cpp adapter's functions, live | version `b11561-e937b17a2`; served context 65536 / 32768 / 16384 from `--ctx-size` in `/models`; seat tags listed once each |
| `test-profiles.ps1 -Profile dev-workflow-server-llamacpp -RoundTrip` | 21 PASS, 0 FAIL, 0 WARN (with `LLAMACPP_SERVER_*` set in the shell; it is not a User-level default on the desktop, so a plain shell WARNs and skips the host checks) |
| `kane-12-error-handler-400` on `llamacpp-server/qwen3.6` | every gate PASS, 54 s; run JSON `engine` llamacpp b11561, `ollamaVersion` null, `numCtx` 65536 |
| the same task on `ollama-server/qwen3.6` | every gate PASS, 67 s; `engine` ollama 0.34.3, `gpuPlacement` `gpu`, 13.59 of 22.68 GB in VRAM |
| `run-tasks-batch.ps1 -Mode Probe` on both llama.cpp seats | all four hosts found across both engines; `qwen3:8b` and `qwen3.6` PASS (two rows in `toolcalls-summary-llamacpp.tsv`) |

**One defect, fixed in the same PR as this record.** The ssh placement check reported `qwen3.6` as `not-loaded` while
it held 14.9 GB of VRAM. The router launches each child with `--alias <router id>` (`qwen3.6:CODING`), not the seat's
tag, and the check matched the tag only; the 3b, whose id has no colon, was found. It now resolves the tag through
`/models` and matches the tag, the id or any alias. Checked live before the window closed: the fixed check read `gpu` for
`qwen3.6` (pid 195733), and the same task re-run through the fixed harness graded every gate PASS with `gpuPlacement`
`gpu`. That run also showed the note in GiB (14.56) beside the field in GB (15.64), so the note now uses decimal GB like
the Ollama adapter.

All three task runs went to a scratch results folder, not `tests/results/`: one run per engine checks the plumbing and is not
a benchmark row.

### Read-budget window (2026-10-17/18)

The large-file fix, measured: `opencode/plugins/read-budget.js` (PR #132; [roadmap](roadmap.md) → "Large-file fix
(2026-10-17)"), on the server's llama-server in a window of its own. Setup:

- **Environment:** the desktop as run host (PowerShell 7.4, OpenCode 1.18.34, harness at `2539127`), llama.cpp build
  b11561, `qwen3.6` at 64k with 14.9 GB on the GPU throughout.
- **Settings:** step 7's settings exactly: nudged, classifier 2, a 45-minute cap, the CPU 3b on the server's Ollama as
  the small model.
- **Config:** the live OpenCode config was the merged template, staged by hand: both plugins, and
  `tool_output.max_bytes` 16384.
- **Results:** private and assisted, in `read-budget-lostbrief` and `read-budget-round`.

**The two tasks that looped**, 3 reps each, alternating:

| task | result | overflows (each run) | compactions | reads capped | wall (s) |
|---|---|---|---|---|---|
| `kane-08` | **2 / 3** (step 7: 0 / 3) | 0, 0, 0 (step 7: 16, 18, 19) | 4, 2, 1 | 2 each | 1,960, 1,198, 547 |
| `wp-4a` | **3 / 3** (step 7: 2 / 3) | 0, 0, 0 (step 7: 43, 12, 14) | 1, 0, 1 | 4 each | 322, 189, 352 |

- **The loop is gone.** Each `kane-08` run read `signals.ts` and `signals.test.ts` from line 1 once, the cap returned
  339 and 349 lines with the grep hint, and the model went on with grep and ranged reads. The peak prompt was 58,432
  tokens, under the 64k window.
- **`kane-08` rep 2 failed on the code, not the context.**
  - One of its own new tests was red: Flame-Blessed Bolt's "would die … instead" case.
  - It used both nudges, and its last step hit the 8,192-token output cap.
  - The informational acceptance run (the owner's tests at the upstream fix `e952198`) failed the same case, 237 of 238.
- **Acceptance on the other two `kane-08` runs:**
  - Rep 1 passed every gate but acceptance, at 236 of 238 (the sacrifice-cost case).
  - Rep 3 passed every gate and acceptance, 238 of 238.
- **Only the cap acted.** The per-file budget (`byReason.budget`) never fired in any run.
- **The cap counts more than the slice.** The first `read` under a folder that holds an instruction file gets that file
  appended by OpenCode (`apps/commander-recommender/CLAUDE.md`, 11.9 KB). The capped read of `signals.ts` therefore
  returned 29,204 chars: a 17,093-char slice plus the instructions. Those chars also count toward the file's budget. It
  did no harm here, and it is OpenCode's behaviour, not the plugin's.

**Round of 15**, same settings:

| | |
|---|---|
| passed | **14 of 15** on every gate, and on hidden tests alone |
| failed | `wp-5b` (hidden tests 246/247, "spends 1 Bond when the requested Delta is negative"; it failed every earlier round too) |
| overflows | **0** (step 7's round: 16, all recovered) |
| reads capped | 26, in 9 of the 15 tasks, at most 5 in one run; the budget never fired |
| wall time | 5,690 s (step 7's round: 5,191 s) |
| against | step 7's llama.cpp round: 11 every gate / 12 hidden tests alone. Ollama classifier-2 rounds: 11, 12, 11, 11 every gate |

- **Compared with step 7's round:**
  - `real-02`, `wp-3b` and `wp-5a` passed this time.
  - `real-02` and `wp-5a` had made no edits there.
  - `wp-3b` had exceeded the 400-line ceiling there.
- **The cap was not the whole cause of the gain.** The cap never touched six tasks: `real-01`, `real-02`, `real-03`,
  `wp-0a`, `wp-9a` and `wp-6f`.
  - Five of them passed, as in step 7, so the plugin cost nothing there.
  - `real-02` is one of the six, and it passed this time without the plugin acting. That gain is the task's own
    instability: it failed three of the four Ollama rounds.
  - `wp-3b` and `wp-5a` were capped, 1 and 5 reads.

**Replicates (2026-10-18, owner: "if there are any tests that we can run in 5 hours or less, let's prioritize
those").** Two more reps of the round, each followed by `kane-08`, with the same settings, `read-budget-reps`:

| | rep 1 (above) | rep 2 | rep 3 | all |
|---|---|---|---|---|
| round, every gate | 14 | 14 | 13 | **41 of 45** (mean 13.7) |
| `kane-08` (with the three above) | | FAIL | PASS | **3 of 5** |
| overflows | 0 | 0 | 0 | **0 in 53 runs**, with the six above |
| reads capped in the round | 26 | 27 | 30 | the per-file budget never fired |

- **Per task, over the three rounds:**
  - 13 tasks passed 3 of 3, among them `wp-7a`, `real-01` and `wp-5a`, which had moved between the Ollama reps.
  - `real-02` passed 2 of 3 (rep 3: 1 of 111 hidden tests, the env-var list).
  - `wp-5b` passed 0 of 3, the same hidden test each time. It has failed every round on either engine.
- **`kane-08` rep 4 failed on the code.** Three of the suite's tests went red (kindred and outlet cases). It had no
  overflow, 4 compactions and 2 nudges.
- **The plugin's actions:**
  - The most capped reads in one run was 9 (`wp-5a`, rep 3).
  - All 32 runs were on the GPU.
- **The comparison:** Ollama's four classifier-2 rounds made 45 of 60 (mean 11.25). Step 7's single llama.cpp round
  made 11.

**Not measured:** the shell cap. The 327 shell results across the 53 transcripts were all under 16,384 chars (the
longest was 9,930), so `tool_output.max_bytes` never applied.

**How far this goes:**

- These are assisted runs: three rounds and five `kane-08` runs.
- The step 7 llama.cpp round without the plugin is a single round. The like-for-like four-round baseline is Ollama's,
  on a different engine.
- So the clean claims are:
  - the loop and the overflows are gone;
  - the round is at least as good, 13.7 against 11 to 12.
- How much of the round's gain is the plugin rather than the engine plus noise would take llama.cpp rounds without the
  plugin (`HOMELAB_READ_MAX_CHARS=off`). That control ran 2026-10-19/20: "Plugin-off control" below.
- The plugin makes these rows a new client era (`opencodePlugins` lists two plugins), so they are compared with step 7
  only as before-and-after, not pooled with it.

### Plugin-off control (2026-10-19/20)

The same round of 15, four reps, with the plugin switched off (`HOMELAB_READ_MAX_CHARS=off`). The plugin-on arm got
a fourth rep the same night, and `kane-08` five more runs.

- **Setup:** step 7's settings and the same client config as the plugin-on rounds, both plugins in the config, on
  llama.cpp build b11561. The desktop was the run host, from `main` at `2fad0e1` (2026-10-19) and `c9f60bd` (the night).
- **Results:** private and assisted. The plugin-off rows are in `read-budget-off`, with a README there; the new
  plugin-on rows are in `read-budget-reps`.
- **Telling the arms apart:** the first 38 plugin-off runs predate `readBudget.off` (PR #136). They are told apart by
  their folder, by the plugin's own `loaded` line (read live, `"off":true`) and by 0 capped reads. The 19 night runs
  record `readBudget.off: true`.

| 15-task round, every gate | rep 1 | rep 2 | rep 3 | rep 4 | all |
|---|---|---|---|---|---|
| plugin on | 14 | 14 | 13 | 13 | **54 of 60** (mean 13.5) |
| plugin off | 13 | 13 | 12 | 12 | **50 of 60** (mean 12.5) |
| runs that overflowed, on / off | | | | | **0 of 60 / 15 of 60** |
| refusals, on / off | | | | | **0 / 146** |

- **Three tasks make the whole difference.** The other 12 passed every run in both arms.

  | task | plugin on | plugin off | what failed |
  |---|---|---|---|
  | `wp-4a` | 4 of 4 | 2 of 4 | refusals each run off (42, 13, 41, 3); rep 3 timed out at 45 min with no row; rep 4 failed one hidden test |
  | `real-02` | 2 of 4 | 0 of 4 | one hidden docs-coverage test each time (the newer modules or the env vars), both arms; it never overflowed |
  | `wp-5b` | 0 of 4 | 0 of 4 | the same hidden test as every earlier round; off, two runs ended context-exceeded (`_CTXEXCEEDED_`, no row) |

- **Overflows came back without the plugin.** They hit five tasks: `wp-4a`, `wp-2b` (7, 3, 2, 3), `wp-5a` (6, 0, 3, 6),
  `wp-7a` (7 in one run) and `wp-5b`.
  - Every one was an explicit refusal (HTTP 400, `ContextOverflowError`). Nothing was dropped silently.
  - opencode recovered all but three runs: the two `wp-5b` context-exceeded runs and the `wp-4a` timeout.
  - With the plugin on there were none in 73 runs: the 60 above plus the 13 `kane-08` and `wp-4a` runs of
    "Read-budget window".
- **Time:** the overflowing tasks slowed down without the plugin.
  - `wp-4a`: 526 to 2,671 s, plus the timeout. On: 194 to 445 s.
  - `wp-2b`: 220 to 637 s. On: 114 to 129 s.
- **`kane-08`, five more runs with the plugin on:** 3 passed every gate.
  - The other two had red suites, 3 and 2 tests (kindred and outlet cases), each with both nudges spent and its last
    step at the output cap.
  - None overflowed. Each had 2 to 5 compactions and 2 to 4 capped reads, and took 1,107 to 2,228 s.
  - With the five above that is **6 of 10** (before the plugin: 0 of 3, all looping).
  - The informational acceptance run passed 2 of tonight's 5.
- **The plugin's actions:**
  - Rep 4's plugin-on round capped 26 reads, at most 6 in one run (`wp-4a`).
  - The per-file budget has still never fired, in 73 plugin-on runs.
  - All 73 were on the GPU.
- **How far this goes:** both arms are assisted, on one engine, four reps each.
  - That the plugin removes the overflows is settled: 0 against 146 refusals.
  - It is worth about one task a round: 54 against 50 of 60, all of it `wp-4a` and `real-02`.
  - `real-02`'s 2-of-4 against 0-of-4 is the weaker half: its failing check is a docs-coverage one, never an overflow.
    It could be noise.

### Ollama with the plugin (2026-10-20)

One rep of the same 15-task round on the server's Ollama with the plugin on. This is the engine comparison's missing
cell: the four Ollama rounds of the baseline predate the plugin, and every plugin-on round so far was llama.cpp.

- **Setup:** `ollama-server/qwen3.6:35b-a3b-coding` on Ollama 0.34.3 (65536 ctx), step 7's settings and client config,
  both plugins on (`readBudget.loaded: true, off: false` in every run JSON). The desktop was the run host, from `main` at
  `ddc626f`. No llama.cpp window was opened. 119 minutes of runs.
- **Results:** private and assisted, in `ollama-read-budget` (with a README).

| 15-task round, every gate | rounds |
|---|---|
| Ollama, before the plugin | 11, 12, 11, 11 |
| **Ollama, plugin on** | **12** |
| llama.cpp, plugin on | 14, 14, 13, 13 |

- **The three failures:**
  - `wp-5b` failed, as it has in every round on both engines.
  - `real-02` failed a hidden docs-coverage test (2 failed), as in 2 of 4 llama.cpp plugin-on runs.
  - `real-03` is the only cell that differs from llama.cpp (4 of 4 there). It was a misread, not an overflow: 4 steps,
    a 15k-token prompt, no compaction. It linked Discord's own Terms and Privacy URLs instead of writing the bot's pages.
- **No front-drops in 15 runs.** Before the plugin, 13 of the 60 classifier-2 Ollama runs had one (Ollama cutting the
  oldest messages, task prompt first, without an error). No run asked for its task.
  - Five runs compacted (`wp-7a` 3 times, four others once); the peak prompt was 57,740 tokens.
  - The cap clamped 31 reads, at most 6 in one run (`wp-7a`). The per-file budget still never fired.
  - All 15 runs were on the GPU, 13.59 of 22.68 GB in VRAM.
- **How far this goes:** one assisted rep.
  - The plugin stops Ollama's silent front-drops in the same way it stops llama.cpp's refusals.
  - 12 against llama.cpp's 13 to 14 is one misread task. One rep can't separate that from noise, so this round does not
    show the engine is worth a task a round.
  - With the plugin, no run overflowed on either engine. The engines still differ in what happens when a request does:
    Ollama drops silently, llama.cpp refuses (Step 1, Step 6).

### Gate G1, row by row

| | criterion | result |
|---|---|---|
| must | tool probe through `/v1` | **pass** (step 4) |
| must | explicit, classified overflow; recovers or ends cleanly; zero silent lost briefs | **pass**, read as "loud": 0 silent losses; 58 + 16 overflows recovered; 4 lost-brief runs looped to the cap (not recovered, reported) |
| must | GPU loss detectable, and detected in the drill | **pass**: the GPU was kept through a real `daemon-reload` (E1, natural; the owner's `sudo` drill not run), and a lost GPU is detectable over ssh (`nvidia-smi --query-compute-apps`), not over HTTP (E2) |
| must | soak clean | **pass**: 144 of 144 cycles, flat VRAM and RAM, 0 restarts |
| speed | ≥ 90% at equal or better headroom | **pass** on the MTP arm (106–118%, 1,477 MiB free) |
| screen | round no worse than Ollama's by more than 2 | **pass**: 11 of 15 (12 on hidden tests alone), level with Ollama |

[opencode-provider-npm]: https://raw.githubusercontent.com/sst/opencode/v1.18.34/packages/opencode/src/provider/provider.ts
