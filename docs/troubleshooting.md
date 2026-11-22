# Troubleshooting

Common issues and fixes for the hybrid dev environment. Paths written `~/dev-docs` or `dev-docs` below mean your checkout of this repo (its old name).

## Symptom index

| Symptom | Section |
|---|---|
| Agent says it edited a file; nothing changed | Agent "says" it edited a file |
| Same file written several times for one request | Passing the probe is necessary, not sufficient |
| Request hangs ~5 min then 500s, or model ignores its system prompt | OpenCode request hangs ~5 minutes |
| `exceed_context_size_error`, or the session forgets its task | "exceed_context_size_error" |
| Server is slow, `Failed to initialize NVML` | Container lost the GPU |
| Engine down, connection refused on 8090 | llama-server not responding |
| `401` / Invalid API Key | `401` / "Invalid API Key" from llama-server |
| Game running on node3, seats slow or not loading | A game is running on node3 |
| Desktop model problems (Ollama, ROCm, Vulkan) | The desktop runs no models |
| Model missing from `/models` | Local model not in `/models` |
| `cannot be parsed as a URL` | `"<path>" cannot be parsed as a URL` |
| Empty or reasoning-only replies | Model "doesn't respond" |
| `opencode run` finishes but never exits | `opencode run` finishes its work |
| Scripts: permission denied after copying from Windows | "Permission denied" running scripts |
| Server will not POST | No POST / solid CPU EZ Debug LED |
| SSH fails, LAN latency | Network Issues |

## Server Issues

### No POST / solid CPU EZ Debug LED (boot stuck before memory init)

Full recovery playbook (timeline, attempts, flashback signatures, next steps):
[`docs/server-recovery-cpu-led.md`](server-recovery-cpu-led.md).

### "Permission denied" running scripts (after copying from Windows)

Files copied from Windows (e.g. via scp) don't carry the executable bit:

```bash
./server/scripts/startup.sh: Permission denied
```

Fix — mark all project scripts executable in one go:

```bash
cd ~/HomeLab
./make-executable.sh
```

Or manually: `chmod +x ~/HomeLab/server/scripts/*.sh ~/HomeLab/profiles/*.sh`

### Docker container won't start

```bash
# Check if nvidia-container-toolkit is installed
docker info | grep -i nvidia

# If missing:
# https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### llama-server not responding

```bash
# Engine, container, GPU, seats in one go
./server/scripts/status.sh

# Check if the container is running, and its logs
docker ps | grep llamacpp-server
docker logs llamacpp-server --tail 50

# Check if the port is in use
sudo lsof -i :8090

# Start it (systemd unit if installed, else docker compose)
./server/scripts/startup.sh
```

An HTTP 401 means it is up and wants the API key: see "`401` / Invalid API Key" below.

### Container lost the GPU: slow server, `Failed to initialize NVML: Unknown Error`

**Symptom.** Everything answers, but the server is many times slower than it was, and `nvidia-smi` on the **host**
looks perfectly fine, with 0 MiB used. Inside the container it fails:

```bash
docker exec llamacpp-server nvidia-smi -L      # Failed to initialize NVML: Unknown Error
```

When it was first seen (2026-10-12, on the since-removed Ollama container) `ollama ps` showed the main seat at
`100% CPU` (38 GB instead of 22.7 GB, with 60% on the GPU); the API still worked, so an old healthcheck stayed green
and nothing failed loudly.

**Cause.** Docker here uses the **systemd cgroup driver on cgroup v2**. A systemd reload (any package install or
upgrade, the daily `apt-daily` / snap timers) rewrites the device-access rules of running containers. The
`/dev/nvidia*` nodes are still listed inside the container, but access to them is denied, so the engine finds no GPU
and loads models onto the CPU. Seen 2026-10-12: `systemd[1]: Reloading...` at 11:12:20Z, as `apt-daily` started
(`journalctl --since "<container start>" | grep -i reloading`). The container had been up since 04:19Z and had
used the GPU fine until then. A first launch of the nudged 15-task round ran for 31 minutes on the CPU before it was
noticed; it was stopped and left no result rows.

**Fix now.** Recreate the container (the volume and the models are kept):

```bash
docker compose -f server/docker/docker-compose.llamacpp.yml up -d --force-recreate
docker exec llamacpp-server nvidia-smi -L      # GPU 0: NVIDIA GeForce RTX 4070 Ti SUPER
```

**Prevention.**

| Layer | What it does |
|---|---|
| `docker-compose.llamacpp.yml` | Lists the five `/dev/nvidia*` nodes explicitly; its healthcheck fails when `nvidia-smi -L` fails inside the container, so `docker ps` and `status.sh` show it |
| Test (once, 2026-10-12, on the Ollama container) | `sudo systemctl daemon-reload` left the GPU visible and the container healthy. Repeat after any Docker, driver or toolkit upgrade |
| If it ever fails | `"exec-opts": ["native.cgroupdriver=cgroupfs"]` in `/etc/docker/daemon.json` (needs `sudo`; restarts Docker) |
| Harness | After each exit-0 run on a llama.cpp provider, the engine is asked where the model sits; none of it in VRAM is exit -5 (`_CPUONLY_`), no summary row, and the batch stops that host. `-NoGpuCheck` skips it. Guard: `tests/test-gpu-placement.ps1` |
| By hand | `status.sh` shows the container's health and the GPU; `docker exec llamacpp-server nvidia-smi -L` is the direct test |

### Out of VRAM

The server hosts an RTX 4070 Ti Super (16 GB). llama-server runs in router mode
with one slot per model (`parallel = 1` in `server/llamacpp/models.ini`). If you see OOMs:

```bash
# Quick one-shot check (engine, GPU, seats)
./server/scripts/status.sh

# Raw GPU memory
nvidia-smi --query-gpu=memory.used,memory.free --format=csv

# Then, in the model's section of server/llamacpp/models.ini: raise n-cpu-moe
# (more expert layers on the CPU) or lower c (that changes the seat's contract:
# models/server-seats.tsv and opencode.jsonc must follow). Restart to apply:
./server/scripts/stop.sh && ./server/scripts/startup.sh
```

### "exceed_context_size_error" / request exceeds available context

The seat's context (`n_ctx`) is smaller than what the client is sending, and
llama-server refuses the request:

```
{"error":{"code":400,"type":"exceed_context_size_error","message":"request (9734 tokens) exceeds the available context size (4096 tokens)..."}}
```

**Context is set per model in the router preset.** Each section of
`server/llamacpp/models.ini` (node3: `node3/llamacpp/models.ini`) sets `c`
explicitly, and three places must agree:

| Where | Key |
|---|---|
| `server/llamacpp/models.ini` | `c` in the model's section |
| `models/server-seats.tsv` | `num_ctx` in the seat's row |
| `opencode/global/opencode.jsonc` | `limit.context` on the `llamacpp-server` model |

`tests/check_config_drift.py` and `./server/scripts/llamacpp-check.sh` check them;
`.\tests\test-profiles.ps1` checks the value the live server reports. One slot
per model (`parallel = 1`): `c` is shared across slots, so more slots would cut
each request's window. The session itself forgetting its task is a different
problem: [reference/gotchas.md](reference/gotchas.md) → "A long session can lose its task silently".

Context history from the Ollama era (the Windows app's `OLLAMA_CONTEXT_LENGTH`
override, the per-model `num_ctx` bake): [archive](archive/troubleshooting-incidents.md).

### Agent "says" it edited a file but nothing changed — the model cannot call tools

The most important finding in this setup. **Not every local model that
advertises `tools` can actually produce a tool call the engine can parse.**

Symptom: the agent claims success ("The task tool has written
`docs/implementation-tasks.md`…"), or prints a tool call as literal text —

```json
{ "name": "write", "arguments": { "content": "...", "filePath": "..." } }
```

— and no file is ever written. It is not a permission problem and not an
OpenCode problem.

Test any model directly, bypassing OpenCode entirely, with the probe:

```powershell
.\tests\test-toolcalls.ps1 -Engine llamacpp -EngineHost http://SERVER_IP:8090 -Model qwen3:8b
```

It sends one chat request with a tool schema to llama-server's
`/v1/chat/completions`; `tool_calls` must be **non-empty**. The table below is
the first measurement, on Ollama 0.34.0 and re-measured on **0.34.1**
(2026-09-19) with every result reproduced, each failure in the same mode —
`tests/results/toolcalls-0.34.1.txt`. It is history (Ollama was removed on
2026-11-21); a verdict is per engine and build, so re-probe on llama-server
before seating any model ([tool-calling.md](tool-calling.md)):

| Model | `tool_calls` | Probe time | Notes |
|---|---|---|---|
| `qwen3:14b` | ✅ populated | 11.9 s | the main seat 2026-09-17 to 2026-10-03 (now `qwen3.6:35b-a3b-coding`, PASS in the 2026-09-22 re-probe) |
| `qwen3:8b` | ✅ populated | 11 s | lighter main seat (today node3's seat, on llama-server) |
| `devstral:24b` | ✅ populated | 41.9 s | works, but 8.1 tok/s — see below |
| `qwen2.5-coder` 3b/7b/14b/-16k | ❌ empty | — | prints the JSON as chat text |
| `deepseek-r1` 14b/-16k/-32k | ❌ empty | — | answers in prose, suggests `echo hello > a.txt` |

Role is not a proxy for tool-calling (`qwen3:14b` is classed `reasoner,general` and calls tools; `qwen2.5-coder:14b` is `coder` and cannot). Run tool probes as a script, never an inline `bash -c` string, or the message is truncated to its first word. More: [archive](archive/troubleshooting-incidents.md)

### `/plan` works now — but verify every claim before acting on it

Treat `/plan` output as a draft to check, never a task list to execute: on a real run, two of three cited claims inverted what the code does while the line numbers were accurate. Open each cited line before believing the claim. On a local 8B, a short blunt prompt beats a long careful one. Full write-up: [archive](archive/troubleshooting-incidents.md).

### Passing the probe is necessary, not sufficient — watch for repeated calls

`test-toolcalls.ps1` answers "can this model emit one tool call?", not "does it know when to stop". Same prompt ("create a file with one line"), 32k context, measured 2026-09-17:

| Model | Wall time | `write` calls |
|---|---|---|
| `qwen3:8b` | 96.1 s | 1 |
| `qwen3:14b` | 217.2 s | 6 |

Six identical writes are harmless for a write and not for an append, a commit, a migration or `rm`. Before seating a model, run one real task and count the calls (one `← Write` is correct):

```powershell
opencode run --model llamacpp-server/<tag> "Create a file at docs/_scratch.md whose entire contents are the single line: it works"
```

The config enforces the rest: every model that fails the probe carries `"tool_call": false` in `opencode/global/opencode.jsonc`; set it honestly when adding a model. A `qwen2.5-coder` or `deepseek-r1` model in an editing seat is a chat box (the Qwen2.5 template needs `<tool_call>` tags the coder weights never emit; not caused by the `num_ctx` bake). Current pass list and the "probe PASS, zero writes" cases: [tool-calling.md](tool-calling.md).

### OpenCode request hangs ~5 minutes then 500s / model "ignores" its system prompt

The single most useful diagnostic in this setup's history, from the Ollama log
(2026-09; Ollama was removed on 2026-11-21):

```
truncating input prompt limit=8194 prompt=46505 keep=4
```

That meant OpenCode sent a 46,505-token prompt to a model serving 16,384, and
the engine threw away everything but the last 8,194 tokens (`keep=4` = only the
first 4 survive). The system prompt and tool definitions were gone, the model
answered nonsense or nothing, and the request timed out. llama-server does not
truncate silently: it refuses an over-long request with `exceed_context_size_error`
(below), so today the same mistake fails fast.

Two causes, both of which have to be fixed:

**1. The model entry used keys OpenCode silently drops.** `context_window` and
a bare `input` are *not* in OpenCode's schema. Unknown model keys are discarded
without an error, so the model resolved with **no limits at all**: OpenCode
never trimmed the prompt, and reserved its ~8192-token default for output —
which is what halves a 16384 window down to `limit=8194`. The real keys are
`limit: { context, output }`, `modalities: { input, output }`, `tool_call`.

```powershell
# THE check - if `limit` is missing here, the key was rejected
opencode debug config
```

Never trust the template alone; only the resolved config proves a key was
accepted. `tests\test-profiles.ps1` checks registration, not schema validity,
so it happily passed 141 checks against a config that could not serve one
request.

**2. The preamble was too big for a local model.** Every MCP server injects its
full tool schema, and every installed skill its name + description, into
*every* request. Measured on this repo:

| Change | Preamble |
|---|---|
| 5 MCP servers + 64 global skills | **46,505 tokens** |
| MCP moved to per-project configs | 18,020 tokens |
| Skills scoped to 8 global | **11,441 tokens** |

Global config ships zero MCP servers and only `frontend-design` +
`ui-ux-pro-max`; projects opt in via their own `opencode.jsonc`
(`opencode/project-override/opencode.jsonc` is the template). Re-measure any
time with:

```powershell
opencode run --model llamacpp-server/qwen3:8b "Reply with exactly: OK"
```

then read the request's prompt token count from llama-server's log on the server (`docker logs llamacpp-server --tail 50`).

### `opencode run` finishes its work but never exits

Seen 2026-09-17: the task completes, the process stays alive holding its model in VRAM, and anything waiting on it waits forever. Strays starve other work (two held `qwen3:8b` and made a probe time out three times) and `Stop-Process` may say `Access is denied`.

| Step | Command |
|---|---|
| Find strays | `Get-Process opencode -ErrorAction SilentlyContinue \| Select-Object Id, StartTime, CPU` |
| See what is loaded | `curl.exe -s http://SERVER_IP:8090/models` (with the fleet key once API keys are rolled out) |
| Kill | `taskkill /F /PID <id>` (each stray has a `powershell` parent started in the same second) |

In scripts, scheduled tasks and CI, give `opencode run` an external timeout and kill it yourself. The TUI does not have this problem.

### A game is running on node3 — the GPU is shared

node3 is also a gaming PC. A running game takes VRAM from its 10 GB card, so a seat may not load or may spill.
Benchmarks and VRAM figures taken beside a game are invalid; tool-call probe verdicts are not. Use the server's seats
while node3 is in use ([hardware.md](hardware.md)). The desktop runs no models, so a game there no longer affects any
seat. Older desktop measurements: [archive](archive/troubleshooting-incidents.md).

## Desktop Issues

### WezTerm: `port is not a valid SshDomain field`

```
error converting Lua table to Config (Config::from_dynamic: Error processing
Config::ssh_domains: `port` is not a valid SshDomain field. ...)
```

WezTerm's `SshDomain` has **no `port` field**. The port belongs in
`remote_address`, and the login user field is `username` (not
`remote_username`):

```lua
config.ssh_domains = {
    {
        name = "dev-server",
        username = "YOUR_USER",                 -- SSH login user (SSH_USER from .env)
        remote_address = "SERVER_IP:22", -- host:port (omit :22 for default)
    },
}
```

Fix the template in `wezterm/wezterm.lua`, then redeploy to the desktop:

```powershell
.\desktop\scripts\sync-wezterm.ps1
```

### The desktop runs no models

Since 2026-11-21 the desktop is only the OpenCode client and the harness run host: Ollama was removed from the fleet
and its GPU has unresolved crashes. Its old model-serving issues (Ollama not starting, ROCm never detected on the
RX 6800 XT, the Vulkan backend, VRAM pairs beside a game) are history in
[archive/troubleshooting-incidents.md](archive/troubleshooting-incidents.md).

## OpenCode Issues

### `401` / "Invalid API Key" from llama-server, or "props answered 401" in a run's engine line

The engine has an API key and the client sent none, or the wrong one ([engine-api-keys.md](engine-api-keys.md)).
`/health` still answers, so the engine looks alive while serving nothing.

- **OpenCode:** `~/.config/opencode/.secrets/llamacpp-api-key` must hold the fleet key (node3: push it with
  `sync-opencode.ps1 -Push node3 -Secrets llamacpp-api-key`). A missing file makes the whole config invalid.
- **The harness and tools:** the same file, or `LLAMACPP_API_KEY` / `LLAMACPP_API_KEY_FILE`.
- **The server's scripts:** the first key line of `~/.config/llamacpp/api-key`.
- **The household chat:** Admin → Settings → Connections holds its key (the environment only seeds a new install).
- **Check:** `server/scripts/llamacpp-check.sh --url http://localhost:8090` → the `auth` line says which side is wrong.

### Models not appearing

```bash
# Check secrets file exists (API keys are stored here, not env vars)
ls -la ~/.config/opencode/.secrets/

# Verify the secret file has a value (not empty)
cat ~/.config/opencode/.secrets/opencode-go-api-key

# Verify config is loaded
opencode debug config

# Check provider status
opencode debug providers
```

### Wrong model being used

```bash
# Check current model in config
opencode debug config | grep model

# Override at runtime
opencode --model opencode-go/deepseek-v4-flash
```

### OpenCode Go models not loading

```bash
# Verify your Go subscription is active at https://opencode.ai/auth
# Check that the secret file has your key
cat ~/.config/opencode/.secrets/opencode-go-api-key

# If empty, add it:
#   "your-key" | Out-File "$env:USERPROFILE\.config\opencode\.secrets\opencode-go-api-key" -NoNewline

# Test the endpoint directly
curl.exe -H "Authorization: Bearer $(cat ~/.config/opencode/.secrets/opencode-go-api-key)" \
  https://opencode.ai/zen/go/v1/models
```

### Local model not in `/models` or unmatched provider

The config registers models under per-host providers — IDs look like
`llamacpp-server/qwen3.6:35b-a3b-coding` or `llamacpp-node3/qwen3:8b`, and the part
after the `/` must equal a section name in that host's `models.ini`:

```bash
# Confirm the merged config has the provider (baseURL from the active profile)
opencode debug config | grep -A2 llamacpp-server

# Confirm the model is served (with the fleet key once API keys are rolled out)
curl.exe $LLAMACPP_SERVER_BASE_URL/models

# Re-stage the template locally after editing opencode/global/opencode.jsonc
.\desktop\scripts\sync-opencode.ps1
```

### `"<path>" cannot be parsed as a URL` when talking to a local model

OpenCode's `{env:...}` substitution does **not** support shell-style
`:-default` fallbacks. `"{env:LLAMACPP_SERVER_BASE_URL:-http://...}"` resolves
to an **empty string**, so the provider has no base URL and requests fail with
`"/chat/completions" cannot be parsed as a URL`:

```bash
# Symptom check — resolved baseURL must NOT be blank
opencode debug config | grep -A1 llamacpp-server
#   "baseURL": ""   <-- BROKEN (env var unset, no fallback in config)
#   "baseURL": "http://SERVER_IP:8090/v1"   <-- OK

# Fix: the value must come from the env var (profile or user-level default):
#   1. launch through a profile: .\desktop\scripts\opencode.ps1 (or opencode server-llamacpp)
#   2. or set it as a Windows User-level default so bare `opencode` works
#      — do not re-add ":-..." to the config.
```

### Model "doesn't respond" / returns empty / reasoning-only replies

Reasoning models (DeepSeek-R1, Qwen3) emit a `reasoning` block *before* the
final answer. With a small `max_tokens` ceiling they burn the whole budget on
reasoning and return **empty content** with `finish_reason: "length"` — which
looks like the model "isn't accepting prompts". Reproduced with
`deepseek-r1-16k` at `max_tokens=8` (2026-09, on the since-removed Ollama); at
`max_tokens=4096` it replied normally.

```bash
# Reproduce: curl a chat completion with a tiny max_tokens (add the fleet key once
# the engine API keys are rolled out: docs/engine-api-keys.md)
curl.exe -s http://SERVER_IP:8090/v1/chat/completions -H "Content-Type: application/json" \
  -d '{"model":"qwen3:8b","messages":[{"role":"user","content":"Say OK"}],"max_tokens":8}'
# -> message.content == ""  (reasoning only, finish_reason "length")
```

Fix: keep `max_tokens` generous (≥256) for reasoning models. OpenCode's
default budget is plenty; this bites direct API calls and custom tools.

### Validating a profile end-to-end

`tests/test-profiles.ps1` runs every live profile by default (`-Profile <name>`
runs one), each checked against its intent manifest (purpose, tier flags, main
model vars, and whether the main seat can call tools), OpenCode registration,
host liveness, and (with `-RoundTrip`) a capability probe plus latency benchmark.
With `-Bench` over-budget becomes FAIL and a summary table prints.

```powershell
.\tests\test-profiles.ps1            # intent + liveness + registration, all profiles
.\tests\test-profiles.ps1 -Profile dev-workflow-server-llamacpp -RoundTrip # probe + benchmark one profile (slow, loads VRAM)
.\tests\test-profiles.ps1 -Bench      # all profiles, over-budget FAILs + summary table
```

WARN = state to fix (e.g. blank `LLAMACPP_SERVER_BASE_URL`, unprovisioned host);
FAIL = profile broken. Exit code is 1 on any FAIL. A reasoning model that
returns "EMPTY content" here is the empty-max_tokens bug above — run the model
with default OpenCode settings first before suspecting the profile.

## Desktop Docker (dev environments)

### Docker engine won't start

Docker Desktop on the desktop needs `C:\Users\<username>\.wslconfig` to contain
`[wsl2] gpuSupport=false` (WSL ConfigureGpu workaround) or its engine fails to
start. If the engine is down, `docker` CLI commands fail immediately — start
Docker Desktop first.

### Containers can't see the GPU

By design. `.wslconfig` disables GPU passthrough (`gpuSupport=false`) so
containers are CPU-only. The desktop runs no models (since 2026-11-21); point a
container that needs one at the server's llama-server (`http://SERVER_IP:8090/v1`).

### Local Postgres/Redis don't come up

- `desktop/docker/.env` missing → `docker compose up` fails fast with a
  `POSTGRES_PASSWORD` error. `Copy-Item desktop/docker/.env.example
  desktop/docker/.env` and set a real password; keep the two in sync with
  `~/.config/opencode/.secrets/postgres-dsn` (used by the read-only pg-ro-mcp OpenCode provider).
- Port 5432/6379 already in use on loopback → set `POSTGRES_PORT`/`REDIS_PORT`
  in `desktop/docker/.env` and point the pg-ro-mcp DSN at the new port.
- Check health: `.\desktop\scripts\docker-stack.ps1 status` (container +
  health column). A red `unhealthy` container → `logs` for details.

### Devcontainer / sandbox memory

WSL2 (incl. Docker Desktop) is capped at 12 GB via `.wslconfig`; every
throwaway container also gets `--memory`/`--cpus` caps. If a dev container
crashes (OOM), raise its `runArgs` memory and/or the `.wslconfig` cap, then
`wsl --shutdown` + restart Docker Desktop to apply.

### Ports are LAN-visible?

They should not be. The compose file binds `127.0.0.1` explicitly. Verify with:
`docker ps --format "{{.Names}} {{.Ports}}"` — expect `127.0.0.1:<port>->...`.
Never remove the loopback prefix.

## Network Issues

### SSH connection fails

```bash
# SSH_USER and SERVER_IP come from the .env file at the repo root
source <repo>/.env  # if not already sourced via a profile

# Test basic connectivity
ping $SERVER_IP

# Test SSH port
nc -zv $SERVER_IP 22

# Check SSH server status (on server)
sudo systemctl status sshd
```

### LAN latency is high

```bash
# Check network speed
iperf3 -c SERVER_IP  # run iperf3 server on server first

# Check for WiFi vs Ethernet
# Wired connections strongly recommended for LAN LLM routing
```

## Getting More Help

- OpenCode docs: https://opencode.ai/docs
- llama.cpp server docs: [llama.cpp's `tools/server/README.md`](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/tools/server/README.md) (catalogued as `llama-cpp-server` in [references.md](references.md))
- OpenCode Discord: https://opencode.ai/discord
