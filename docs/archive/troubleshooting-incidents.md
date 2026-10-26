# Troubleshooting: incidents and long write-ups

Moved out of [troubleshooting.md](../troubleshooting.md) 2026-10-26 to keep that page scannable. Text is as it stood; dated facts are not re-verified.

| Section | Origin |
|---|---|
| [Context-length history](#context-length-history) | exceed_context_size_error |
| [Probe notes: role, quoting, end-to-end](#probe-notes-role-quoting-end-to-end) | Agent "says" it edited a file |
| [`/plan` works now](#plan-works-now--but-verify-every-claim-before-acting-on-it) | 2026-09-17 prompt shortening |
| [A game is running](#a-game-is-running--the-gpu-is-shared-and-ollama-loses) | shared GPU |
| [Desktop is slow](#desktop-is-slow--the-main-model-keeps-reloading) | eviction, flash attention |
| [ROCm not detected](#rocm-not-detected--it-never-will-be-on-this-card-the-desktop-runs-vulkan) | Vulkan, settled |

## Context-length history

> **Historical note (corrected 2026-09-17):** this section used to say the
> Windows Ollama app *overrides* `OLLAMA_CONTEXT_LENGTH` with a VRAM-based
> default and reports `OLLAMA_CONTEXT_LENGTH:0`. That was true on v0.32 and is
> **fixed as of 0.34.0** — the serve-log env map now shows the value you set,
> and `qwen3:8b` (which has no bake) serves at it. Baking is still what we do,
> but for a better reason: the env var is one *global* default and we need
> *per-model* context, because the big models want 32k while the small
> companion must stay at 16k or its KV cache evicts the main model.

## Probe notes: role, quoting, end-to-end

**Role is not a proxy for this.** `qwen3:14b` is classed `reasoner,general` in
`catalog.tsv` and calls tools fine; `qwen2.5-coder:14b` is classed `coder` and
cannot call a tool at all. `tests/test-profiles.ps1` used to assert the main
seat's *role* — that check was removed on 2026-09-17 because it was both
obsolete and wrong. It now asserts `tool_call` instead.

| Iteration | `qwen3:8b` | `qwen3:14b` |
|---|---|---|
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

## `/plan` works now — but verify every claim before acting on it

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

### The dangerous part

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

## A game is running — the GPU is shared, and Ollama loses

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

Practical rule: the `dev-workflow-quality` seat (`qwen3.6:35b-a3b-coding`, which
already fills the GPU at 12.51 GB and spills the rest to RAM; its companion
runs on the CPU) is not measured beside a game — switch to
`dev-workflow-resident` (11.97 GB) when the GPU is shared. (Its previous pair,
qwen3:14b + qwen2.5-coder:3b = 13.29 GB, did **not** coexist with one.) Anything that wants a second 14B or larger
needs the game closed.

## Desktop is slow / the main model keeps reloading

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

## ROCm not detected — it never will be on this card. The desktop runs Vulkan.

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
