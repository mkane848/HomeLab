# Troubleshooting

Common issues and fixes for the hybrid dev environment.

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
cd ~/dev-docs
./make-executable.sh
```

Or manually: `chmod +x ~/dev-docs/server/scripts/*.sh ~/dev-docs/profiles/*.sh`

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

### Out of VRAM

The server now hosts an RTX 4070 Ti Super (16 GB) with `OLLAMA_NUM_PARALLEL=4`
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
cd M:\Projects\dev-docs
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

> **Historical note (corrected 2026-09-17):** this section used to say the
> Windows Ollama app *overrides* `OLLAMA_CONTEXT_LENGTH` with a VRAM-based
> default and reports `OLLAMA_CONTEXT_LENGTH:0`. That was true on v0.32 and is
> **fixed as of 0.34.0** — the serve-log env map now shows the value you set,
> and `qwen3:8b` (which has no bake) serves at it. Baking is still what we do,
> but for a better reason: the env var is one *global* default and we need
> *per-model* context, because the big models want 32k while the small
> companion must stay at 16k or its KV cache evicts the main model.

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
`/api/chat` and `/v1/chat/completions`):

| Model | `tool_calls` | Probe time | Notes |
|---|---|---|---|
| `qwen3:14b` | ✅ populated | 11.9 s | **the main seat** (dev-workflow-quality) |
| `qwen3:8b` | ✅ populated | 11 s | lighter main seat (resident/desktop-only) |
| `devstral:24b` | ✅ populated | 41.9 s | works, but 8.1 tok/s — see below |
| `qwen2.5-coder` 3b/7b/14b/-16k | ❌ empty | — | prints the JSON as chat text |
| `deepseek-r1` 14b/-16k/-32k | ❌ empty | — | answers in prose, suggests `echo hello > a.txt` |

**Role is not a proxy for this.** `qwen3:14b` is classed `reasoner,general` in
`catalog.tsv` and calls tools fine; `qwen2.5-coder:14b` is classed `coder` and
cannot call a tool at all. `tests/test-profiles.ps1` used to assert the main
seat's *role* — that check was removed on 2026-09-17 because it was both
obsolete and wrong. It now asserts `tool_call` instead.

Iteration | `qwen3:8b` | `qwen3:14b` |
| Probe 1 (dead-end) | truncates message to first word | — |
| Probe 2 (dead-end) | truncates to first word | — |
| Probe 3 (dead-end) | truncates to first word | — |
| `/plan` + manual fix | ✅ single `← Write` | ✅ single `← Write` |

**Quoting gotcha (avoid this dead end):** those first three probes failed
because the *message* was truncated to its first word before it ever reached
the model — a PowerShell→bash inline quoting artifact, not a tool-calling
regression. PowerShell passes `"Create a file at docs/_scratch.md …"` through
`bash -c '… "Create a file …" …'` and bash sees only `Create`. The model
correctly replied "what?" — it was never a permissions problem and never a
model without tools.

Run tool probes as a **script** (`.sh` file), never as an inline `bash -c`
string, and you get the full message. That is what the times above used.
The tray's auto-title-generator receives the same truncated string, so both
captures agree and the mistake is easy to trust — it is the quoting, not the
model. Noted in `docs/roadmap.md` line 101 as well.

`qwen3:14b` end-to-end probe (2026-09-17, re-seat verification):
exactly **one** `← Write` `docs/_scratch.md` (`it works`), 2.9 min. The
repeated-call regression documented below no longer fires on the 14b — the
docs' "Single-Write discipline" check is what passes now.

### `/plan` works now — but verify every claim before acting on it

Fixed 2026-09-17 by **shortening the prompt**, after four tests isolated the
cause. It was never permissions, never a missing tool, never the `--command`
path. Instruction-following on `qwen3:8b` degrades as the prompt gets more
complex, and it degrades in stages:

| Prompt | Length | Read? | Wrote file? | Output |
|---|---|---|---|---|
| `planner.md` subagent | ~40 lines | no | no | prose, asked a question |
| `plan.md` v1 (numbered steps + rules) | ~25 lines | yes | no | stopped mid-task |
| one-sentence message | 1 line | yes | **yes** | 4 bullets, no sections |
| `plan.md` v2 (current) | ~12 lines | yes | **yes** | correct structure + real citations |

The lesson generalises: **on a local 8B, a long careful contract produces worse
compliance than a short blunt one.** If a command stops working, try cutting the
prompt in half before adding more rules to it.

`opencode/agents/planner.md` was deleted — `plan.md` no longer routes to a
subagent, and a dead agent file is how confusion accumulates.

#### The dangerous part

The current output *looks* excellent and is **partly wrong**. From a real run:

> "**Prune logic bypasses DryRun**: Line 145-159 has pruning code that doesn't
> respect the DryRun flag, risking accidental deletions."

`sync-skills.ps1:151` is `if ($DryRun) {` — the prune block **does** respect it.
The model found the right code, cited the right lines, and inverted what it
does. Two of its three claims were wrong in exactly this way: it saw
`if ($DryRun) { log } else { act }` and concluded the guard was missing.

Line numbers were accurate in all three cases. That is what makes it dangerous —
a plan with real citations and confident wording passes a glance, and the
failure mode from earlier that day was an agent executing a task list and
corrupting a file.

**Reproduced verbatim under qwen3:14b the same day** (a fresh `/plan` on the
same script after re-seating `dev-workflow-quality`): same script, same three
inverted claims ("prune has no DryRun guard", "legacy cleanup skips DryRun"),
accurate line numbers. The 14B seat fixed tool-calling discipline, **not**
plan-verification reliability — re-seating changes the model, not the need to
check every cited line. See `docs/implementation-tasks.md` for the corrected
audit.

**Treat `/plan` output as a draft to check, never a task list to execute.** Open
each cited line before believing the claim about it. Do not chain
`/plan` → "execute task #1" without reading the plan yourself.

### Passing the probe is necessary, not sufficient — watch for repeated calls

`test-toolcalls.ps1` answers "can this model emit one tool call?" It does not
answer "does it know when to stop." Measured 2026-09-17, identical prompt
("create a file with one line"), identical config, 32k context:

| Model | Wall time | `write` tool calls |
|---|---|---|
| `qwen3:8b` | **96.1 s** | **1** |
| `qwen3:14b` | 217.2 s | **6** |

`qwen3:14b` wrote the same file six times for a single request. It is harmless
for an idempotent write and **is not harmless** for an append, a `git commit`, a
migration or an `rm`. It is also why it took 2.3x longer — six round trips, not
a slower model.

This is why `dev-workflow-quality` seats the **14B** by default (re-seated
2026-09-17 for its loose-prompt intent handling): it is the largest fully
on-GPU model that can call tools (11.03 GB, 100% on GPU, 48.9 tok/s). But the
repeated-call behaviour above is exactly why the **8B** remains the safe fallback
in the resident/desktop-only profiles — and why you watch a real task before
letting the 14B run. Bigger won on intent; it lost on discipline.

`qwen3:14b` stays registered and is fine for a bounded single-shot job. Before
seating any model, run a real task through it and count the tool calls:

```powershell
opencode run --model ollama-desktop/<tag> "Create a file at docs/_scratch.md whose entire contents are the single line: it works"
```

One `← Write` is correct. Several means the model does not recognise completion,
and you should not point it at anything destructive.

**The config enforces this.** Every model that fails the probe carries
`"tool_call": false` in `opencode/global/opencode.jsonc`, so opencode does not
offer it tools in the first place. If you add a model, probe it and set the flag
honestly — `true` on an unprobed model is a guess, and the failure mode is an
agent that lies about its work.

The Qwen2.5 template requires the model to wrap calls in
`<tool_call></tool_call>`; the coder variants emit bare JSON without the tags,
so Ollama's parser never extracts them. **This is not caused by the `num_ctx`
bake** — a freshly pulled, unbaked `qwen2.5-coder:3b` behaves identically.
`ollama show` listing a `tools` capability means the *template* supports tools,
not that the *weights* reliably use them.

**Consequence:** a `qwen2.5-coder` or `deepseek-r1` model in a seat that has to
read, edit, or run anything is a chat box, not an agent. Only the qwen3 family
(`qwen3:8b`, `qwen3:14b` — `devstral:24b` too, but it partially offloads) can
hold the main seat or a tool-driving subagent. `profiles/dev-workflow-resident.sh`
already said so from experience — this is the measurement behind it.

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

Observed three times on 2026-09-17. A non-interactive `opencode run` completes
the task — the file is written, the reply is produced — and then the process
just sits there, holding its model in VRAM. The wrapping shell never returns, so
anything waiting on it waits forever.

Two consequences worth knowing before they bite you:

- **It starves everything else.** Two of these left running held `qwen3:8b`
  resident and made a separate model probe time out three times at 900 s each.
  The symptom looks like the *probe* being broken; it is not.
- **`Stop-Process` may refuse it** with `Access is denied`, even for processes
  you own.

Check for strays and what they're holding:

```powershell
Get-Process opencode -ErrorAction SilentlyContinue | Select-Object Id, StartTime, CPU
```

```bash
curl.exe -s http://localhost:11434/api/ps
```

A tell-tale sign: each stray `opencode` has a `powershell` parent that started
in the same second. If `Stop-Process` is denied, `taskkill /F /PID <id>` usually
works.

**Implication for automation:** do not assume `opencode run` exits. If you wrap
it in a script, a scheduled task or CI, give it an external timeout and kill the
process yourself rather than waiting on it. The interactive TUI does not have
this problem.

### A game is running — the GPU is shared, and Ollama loses

This desktop is also the gaming machine. A running game holds VRAM that Ollama
then cannot have, and Ollama reacts by evicting models or refusing to load them:

```
msg="gpu memory" library=Vulkan available="12.5 GiB"   <- normally 14.8 GiB
msg="llama-server model predicted to exceed available memory, evicting"
```

Measured with Guild Wars 2 running: available VRAM dropped from **14.8 GiB to
12.5 GiB**. That is enough to break any model over ~12 GB — `devstral:24b`
(14 GB) simply will not load, and `qwen2.5-coder:14b` @32k (11.27 GB) sits right
on the edge. Smaller models still work: `qwen3:8b` (5.93 GB) is unaffected.

**What this does and does not invalidate:**

- **Benchmarks and VRAM figures: yes, invalidated.** Re-measure with the game
  closed. Every number in these docs was taken at 14.8 GiB available.
- **Tool-calling probe results: no.** `tests/test-toolcalls.ps1` asks whether a
  model emits a structured `tool_calls` entry. That is a correctness property of
  the weights and template; it does not change with free VRAM. A *timeout* under
  memory pressure is possible, but a PASS/FAIL verdict is trustworthy.

Check what you are actually working with before trusting a measurement:

```bash
curl.exe -s http://localhost:11434/api/ps
```

```powershell
Select-String -Path "$env:LOCALAPPDATA\Ollama\server.log" -Pattern 'gpu memory' | Select-Object -Last 1
```

Practical rule: the `dev-workflow-quality` pair (qwen3:14b + qwen2.5-coder:3b =
13.29 GB) does **not** coexist with a game — switch to `dev-workflow-resident`
(11.97 GB) when the GPU is shared. Anything that wants a second 14B or larger
needs the game closed.

### Desktop is slow / the main model keeps reloading

Two separate things, both measured — don't guess from catalog disk sizes, which
undercount runtime VRAM by 1–3 GB (they omit KV cache and compute buffers).

**Eviction.** Only ~14.8 GB of the 16 GB is usable. If main + small don't both
fit, loading the small model evicts the main one and the next turn pays a
**14.1 s** reload *plus* a full re-prefill of the lost prompt cache. Measured at
32k context with `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0`:

| Pair | VRAM | Fits? |
|---|---|---|
| `qwen2.5-coder:14b` + `:3b` | 11.27 + 2.26 = **13.54 GB** | ✅ |
| `qwen2.5-coder:14b` + `:7b` | 11.27 + 5.22 = 16.49 GB | ❌ evicts |
| `qwen3:14b` + `qwen2.5-coder:3b` | 11.03 + 2.26 = **13.29 GB** | ✅ |
| `qwen3:8b` + `qwen2.5-coder-16k` | 5.93 + 4.81 = **10.74 GB** | ✅ |

```bash
curl.exe -s http://localhost:11434/api/ps    # expect BOTH models listed
```

**Flash attention is a trade, not a win, on this GPU.** Quantized KV requires
it (`quantized V cache requires flash_attn to be enabled`), but on the Vulkan
backend it costs prefill throughput. Measured, `qwen2.5-coder:14b`, 7,135-token
prompt:

| Config | KV buffer @32k | Prefill |
|---|---|---|
| `FA=1 KV=q8_0` | 3264 MiB | 103.3 tok/s |
| `FA=0 KV=f16` | 6144 MiB | 190.8 tok/s |
| `FA=0 KV=q8_0` | — | **fails to load** |

We run `FA=1 KV=q8_0` anyway: it is the only way the 14B fits at 32k *with* a
companion model, and avoiding eviction is worth more than raw prefill because
Ollama caches the prompt prefix between turns — the big prefill is paid once
per session, an eviction re-pays it every time.

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

Settled 2026-09-17. Don't spend time on this again.

```
level=WARN source=amd.go:485 msg="AMD driver is too old. Update your AMD driver to enable GPU inference."
```

The message is misleading — it is not about how new your driver is. Ollama's
`detectOldAMDDriverWindows()` compares no version numbers at all; it just looks
for two DLLs on `PATH`:

```go
_, errV6 := exec.LookPath("amdhip64_6.dll")
_, errV7 := exec.LookPath("amdhip64_7.dll")
if errV6 == nil && errV7 != nil { /* "AMD driver is too old" */ }
```

On this desktop (Adrenalin 26.8.1, WDDM 32.0.21045.5002, Aug 2026):
`amdhip64_6.dll` is in System32, `amdhip64_7.dll` is nowhere. Ollama 0.34 wants
the HIP 7 runtime; the driver ships HIP 6 for this GPU.

Updating the driver does not fix it, because **gfx1030 is not supported by the
Windows HIP SDK**: AMD's 7.2 system-requirements table marks RX 6950/6900/6800
XT/6800 unsupported (Windows HIP is RDNA3 + RDNA4 only), ROCm/hip#3899 reports
HIP 7.1.1 failing to detect an RX 6800 XT that HIP 6.4 sees on the same
machine, and ollama#12388 shows gfx1030 crashing with an access violation in
`ggml-hip.dll` when it does load. Forcing the issue with `OLLAMA_VULKAN=0`
drops the machine to **CPU-only** — verified.

So the desktop uses the **Vulkan** backend, and that is correct, not a fallback
to apologise for. `HSA_OVERRIDE_GFX_VERSION` is irrelevant here. Confirm which
backend is live:

```powershell
# expect: library=Vulkan ... Vulkan0 (RX 6800 XT)
Select-String -Path "$env:LOCALAPPDATA\Ollama\server.log" -Pattern 'library=|Vulkan0 \('
```

Measured Vulkan performance, `qwen2.5-coder:14b` Q4 on the RX 6800 XT: **49
tok/s** generation, 103–191 tok/s prefill depending on flash attention (see
"Desktop is slow" above). Revisit only if the card changes or AMD adds gfx1030
to the Windows HIP support table.

> **Note:** a manually started `ollama serve` does **not** write to
> `%LOCALAPPDATA%\Ollama\server.log` — only the tray app does. If that log looks
> stale, you are reading a previous session. Capture your own with
> `Start-Process ollama -ArgumentList serve -RedirectStandardError <path>`.

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

# Redeploy the template after editing opencode/global/opencode.jsonc
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
containers are CPU-only and Ollama stays native via ROCm. Don't try to run a
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
# SSH_USER and SERVER_IP come from the .env file at dev-docs root
source dev-docs/.env  # if not already sourced via a profile

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
