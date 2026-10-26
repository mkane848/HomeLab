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
| Desktop slow, main model keeps reloading | Desktop is slow |
| Game running, models evicted | A game is running |
| "AMD driver is too old" / ROCm | ROCm not detected |
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

### Ollama API not responding

```bash
# Check if container is running
docker ps | grep ollama

# Check container logs
docker logs ollama-server --tail 50

# Check if port is in use
sudo lsof -i :11434
```

### Container lost the GPU: slow server, `Failed to initialize NVML: Unknown Error`

**Symptom.** Everything answers, but the server is many times slower than it was, `ollama ps` shows the main seat at
`100% CPU` (38 GB instead of 22.7 GB, with 60% on the GPU), and `nvidia-smi` on the **host** looks perfectly fine,
with 0 MiB used. Inside the container it fails:

```bash
docker exec ollama-server nvidia-smi -L        # Failed to initialize NVML: Unknown Error
```

`ollama list` and the API still work, so an old healthcheck stayed green and nothing failed loudly.

**Cause.** Docker here uses the **systemd cgroup driver on cgroup v2**. A systemd reload (any package install or
upgrade, the daily `apt-daily` / snap timers) rewrites the device-access rules of running containers. The
`/dev/nvidia*` nodes are still listed inside the container, but access to them is denied, so Ollama finds no GPU
and loads models onto the CPU. Seen 2026-10-12: `systemd[1]: Reloading...` at 11:12:20Z, as `apt-daily` started
(`journalctl --since "<container start>" | grep -i reloading`). The container had been up since 04:19Z and had
used the GPU fine until then. A first launch of the nudged 15-task round ran for 31 minutes on the CPU before it was
noticed; it was stopped and left no result rows.

**Fix now.** Recreate the container (the volume and the models are kept):

```bash
docker compose -f server/docker/docker-compose.yml up -d --force-recreate
docker exec ollama-server nvidia-smi -L        # GPU 0: NVIDIA GeForce RTX 4070 Ti SUPER
```

**Prevention.**

| Layer | What it does |
|---|---|
| `docker-compose.yml` | Lists the five `/dev/nvidia*` nodes explicitly; its healthcheck fails when `nvidia-smi -L` fails inside the container, so `docker ps` and `status.sh` show it |
| Test (once, 2026-10-12) | `sudo systemctl daemon-reload` left the GPU visible and the container healthy. Repeat after any Docker, driver or toolkit upgrade |
| If it ever fails | `"exec-opts": ["native.cgroupdriver=cgroupfs"]` in `/etc/docker/daemon.json` (needs `sudo`; restarts Docker) |
| Harness | After each exit-0 Ollama run, `/api/ps` is checked; `size_vram` 0 is exit -5 (`_CPUONLY_`), no summary row, and the batch stops that host. `-NoGpuCheck` skips it. Guard: `tests/test-gpu-placement.ps1` |
| By hand | `status.sh` prints each loaded model's GPU share; `docker exec ollama-server nvidia-smi -L` is the direct test |

### Out of VRAM

The server now hosts an RTX 4070 Ti Super (16 GB) with `OLLAMA_NUM_PARALLEL=1`
and `OLLAMA_MAX_LOADED_MODELS=2` by default. If you see OOMs:

```bash
# Quick one-shot check (GPU + loaded models + catalog vs installed)
./server/scripts/status.sh

# Raw GPU memory
nvidia-smi --query-gpu=memory.used,memory.free --format=csv

# Lower parallel requests in server/docker/.env
OLLAMA_NUM_PARALLEL=1
OLLAMA_MAX_LOADED_MODELS=1

# Restart the service
./server/scripts/stop.sh && ./server/scripts/startup.sh
```

### "exceed_context_size_error" / request exceeds available context

The Ollama server's context cap (`n_ctx`) is smaller than what the client is
sending:

```
{"error":{"code":400,"message":"request (9734 tokens) exceeds the available context size (4096 tokens)..."}}
```

On the server (Docker/Linux) the cap is `OLLAMA_CONTEXT_LENGTH` — 16384 by
default; raise it in `server/docker/.env`.

**On the desktop, context is baked per model.** `startup.ps1` writes a
`PARAMETER num_ctx` into each tag it manages:

```powershell
cd <path-to-HomeLab-checkout>
.\desktop\scripts\startup.ps1            # per-model contexts from $contextModels
.\desktop\scripts\startup.ps1 -ContextLength 16384   # override every model
```

Current contract (`$contextModels` in `startup.ps1` ⇄ `limit.context` in
`opencode/global/opencode.jsonc` — keep the two in sync):

| Tag | Served context |
|---|---|
| `qwen2.5-coder:14b` | 32768 |
| `deepseek-r1-32k` | 32768 |
| `deepseek-r1:14b`, `deepseek-r1-16k` | 16384 |
| `qwen2.5-coder:7b`, `-16k`, `:3b`, `qwen3:8b` | 16384 |

```bash
curl.exe -s http://192.168.1.169:11434/api/ps   # context_length per loaded model
```

Context history: the Windows app once overrode `OLLAMA_CONTEXT_LENGTH` (v0.32, fixed in 0.34.0); we bake per model because the variable is one global default. See [archive](archive/troubleshooting-incidents.md).

### Agent "says" it edited a file but nothing changed — the model cannot call tools

The most important finding in this setup. **Not every local model that
advertises `tools` can actually produce a tool call Ollama can parse.**

Symptom: the agent claims success ("The task tool has written
`docs/implementation-tasks.md`…"), or prints a tool call as literal text —

```json
{ "name": "write", "arguments": { "content": "...", "filePath": "..." } }
```

— and no file is ever written. It is not a permission problem and not an
OpenCode problem.

Test any model directly, bypassing OpenCode entirely:

```powershell
$body = @{
  model = "qwen3:8b"
  messages = @(@{ role="user"; content="Write the text 'hello' to a file named a.txt. Use the tool." })
  tools = @(@{ type="function"; function=@{ name="write_file"; description="Write text to a file"
    parameters=@{ type="object"; properties=@{ path=@{type="string"}; content=@{type="string"} }; required=@("path","content") } } })
  stream = $false
} | ConvertTo-Json -Depth 10
(Invoke-RestMethod "http://localhost:11434/api/chat" -Method Post -Body $body -ContentType "application/json").message.tool_calls
```

`tool_calls` must be **non-empty**. Measured on Ollama 0.34.0 (identical on
`/api/chat` and `/v1/chat/completions`), and re-measured on **0.34.1**
(2026-09-19) with every result reproduced, each failure in the same mode —
`tests/results/toolcalls-0.34.1.txt`:

| Model | `tool_calls` | Probe time | Notes |
|---|---|---|---|
| `qwen3:14b` | ✅ populated | 11.9 s | the main seat 2026-09-17 to 2026-10-03 (now `qwen3.6:35b-a3b-coding`, PASS in the 2026-09-22 re-probe) |
| `qwen3:8b` | ✅ populated | 11 s | lighter main seat (resident/desktop-only) |
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
opencode run --model ollama-desktop/<tag> "Create a file at docs/_scratch.md whose entire contents are the single line: it works"
```

The config enforces the rest: every model that fails the probe carries `"tool_call": false` in `opencode/global/opencode.jsonc`; set it honestly when adding a model. A `qwen2.5-coder` or `deepseek-r1` model in an editing seat is a chat box (the Qwen2.5 template needs `<tool_call>` tags the coder weights never emit; not caused by the `num_ctx` bake). Current pass list and the "probe PASS, zero writes" cases: [tool-calling.md](tool-calling.md).

### OpenCode request hangs ~5 minutes then 500s / model "ignores" its system prompt

The single most useful diagnostic in this whole setup, from the Ollama log:

```
truncating input prompt limit=8194 prompt=46505 keep=4
```

That means OpenCode sent a 46,505-token prompt to a model serving 16,384, and
Ollama threw away everything but the last 8,194 tokens (`keep=4` = only the
first 4 survive). The system prompt and tool definitions are gone, the model
answers nonsense or nothing, and the request times out.

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
opencode run --model ollama-desktop/qwen2.5-coder:14b "Reply with exactly: OK"
```

then read `task.n_tokens` from the `new prompt` line in the Ollama log.

### `opencode run` finishes its work but never exits

Seen 2026-09-17: the task completes, the process stays alive holding its model in VRAM, and anything waiting on it waits forever. Strays starve other work (two held `qwen3:8b` and made a probe time out three times) and `Stop-Process` may say `Access is denied`.

| Step | Command |
|---|---|
| Find strays | `Get-Process opencode -ErrorAction SilentlyContinue \| Select-Object Id, StartTime, CPU` |
| See what is loaded | `curl.exe -s http://localhost:11434/api/ps` |
| Kill | `taskkill /F /PID <id>` (each stray has a `powershell` parent started in the same second) |

In scripts, scheduled tasks and CI, give `opencode run` an external timeout and kill it yourself. The TUI does not have this problem.

### A game is running — the GPU is shared, and Ollama loses

A running game takes ~2.3 GiB of VRAM (available 14.8 → 12.5 GiB), so models over ~12 GB are evicted or won't load. Benchmarks and VRAM figures taken beside a game are invalid; tool-call probe verdicts are not.

| Check | Command |
|---|---|
| What is loaded | `curl.exe -s http://localhost:11434/api/ps` |
| VRAM Ollama sees | `Select-String -Path "$env:LOCALAPPDATA\Ollama\server.log" -Pattern 'gpu memory' \| Select-Object -Last 1` |

Switch to `dev-workflow-resident` (11.97 GB) while the GPU is shared. Details: [archive](archive/troubleshooting-incidents.md).

### Desktop is slow / the main model keeps reloading

Usable VRAM is ~14.8 of 16 GB, and catalog sizes undercount by 1–3 GB. If main + small don't both fit, the small model evicts the main one (14.1 s reload plus a full re-prefill).

| Pair (32k, FA=1, KV q8_0) | VRAM | Fits? |
|---|---|---|
| `qwen2.5-coder:14b` + `:3b` | 13.54 GB | yes |
| `qwen2.5-coder:14b` + `:7b` | 16.49 GB | no, evicts |
| `qwen3:14b` + `qwen2.5-coder:3b` | 13.29 GB | yes |
| `qwen3:8b` + `qwen2.5-coder-16k` | 10.74 GB | yes |

Check `curl.exe -s http://localhost:11434/api/ps` and expect both models listed. Flash attention costs prefill on Vulkan (103 vs 191 tok/s) but is kept because it lets two models fit. These pair figures disagree with `hardware.md` on `qwen3:14b` + 3b (13.29 vs 12.34 GB) and are unreconciled. Measurements: [archive](archive/troubleshooting-incidents.md).

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

### Ollama not starting on Windows

```powershell
# Check if already running
Get-Process ollama

# Check for port conflicts
netstat -ano | findstr :11434

# Restart Ollama
Stop-Process -Name ollama -Force -ErrorAction SilentlyContinue
Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden
```

### ROCm not detected — it never will be on this card. The desktop runs Vulkan.

Settled 2026-09-17. "AMD driver is too old" is a misleading message (Ollama only looks for `amdhip64_7.dll`), and gfx1030 is not supported by the Windows HIP SDK. `OLLAMA_VULKAN=0` drops to CPU-only. Confirm the backend:

```powershell
# expect: library=Vulkan ... Vulkan0 (RX 6800 XT)
Select-String -Path "$env:LOCALAPPDATA\Ollama\server.log" -Pattern 'library=|Vulkan0 \('
```

A hand-started `ollama serve` does not write that log; only the tray app does. Evidence and sources: [archive](archive/troubleshooting-incidents.md).

### Server can't reach desktop Ollama

```powershell
# Verify Ollama is binding to 0.0.0.0
$env:OLLAMA_HOST = "0.0.0.0"

# Check Windows firewall
# Open Windows Defender Firewall > Advanced Settings
# Inbound Rules > New Rule > Port > TCP 11434 > Allow
```

## OpenCode Issues

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

The config registers catalog models under per-host providers — IDs look like
`ollama-server/qwen2.5-coder:14b`, not `ollama/qwen2.5-coder:7b`:

```bash
# Confirm the merged config has the provider (baseURL from the active profile)
opencode debug config | grep -A2 ollama-server

# Confirm the model is reachable
curl.exe $OLLAMA_SERVER_BASE_URL/models

# Re-stage the template locally after editing opencode/global/opencode.jsonc
.\desktop\scripts\sync-opencode.ps1
```

### `"<path>" cannot be parsed as a URL` when talking to a local model

OpenCode's `{env:...}` substitution does **not** support shell-style
`:-default` fallbacks. `"{env:OLLAMA_DESKTOP_BASE_URL:-http://...}"` resolves
to an **empty string**, so the provider has no base URL and requests fail with
`"/chat/completions" cannot be parsed as a URL`:

```bash
# Symptom check — resolved baseURL must NOT be blank
opencode debug config | grep -A1 ollama-desktop
#   "baseURL": ""   <-- BROKEN (env var unset, no fallback in config)
#   "baseURL": "http://localhost:11434/v1"   <-- OK

# Fix: the value must come from the env var (profile or user-level default):
#   1. source profiles/dev-desktop-only.sh  (or run \profiles\dev-desktop-only.ps1)
#   2. Windows User-level defaults are set on the desktop so OpenCode works
#      even without sourcing the profile — do not re-add ":-..." to the config.
```

### Model "doesn't respond" / returns empty / reasoning-only replies

Reasoning models (DeepSeek-R1, Qwen3) emit a `reasoning` block *before* the
final answer. With a small `max_tokens` ceiling they burn the whole budget on
reasoning and return **empty content** with `finish_reason: "length"` — which
looks like the model "isn't accepting prompts". Reproduced with
`deepseek-r1-16k` at `max_tokens=8`; at `max_tokens=4096` it replied normally.

```bash
# Reproduce: curl a chat completion with a tiny max_tokens
curl.exe -s http://localhost:11434/v1/chat/completions -H "Content-Type: application/json" \
  -d '{"model":"deepseek-r1-16k","messages":[{"role":"user","content":"Say OK"}],"max_tokens":8}'
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
.\tests\test-profiles.ps1 -Profile dev-workflow-quality -RoundTrip # probe + benchmark one profile (slow, loads VRAM)
.\tests\test-profiles.ps1 -Bench      # all profiles, over-budget FAILs + summary table
```

WARN = state to fix (e.g. blank `OLLAMA_SERVER_BASE_URL`, unprovisioned host);
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
containers are CPU-only and Ollama stays native (Vulkan) on the host. Don't try to run a
model inside a container on the desktop; point it at the host
(`OLLAMA_DESKTOP_BASE_URL` / `http://localhost:11434`).

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
- Ollama docs: https://ollama.com/docs
- OpenCode Discord: https://opencode.ai/discord
