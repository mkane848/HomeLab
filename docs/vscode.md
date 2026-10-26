# VS Code + local models: BYOK setup

> Setup current as of **2026-09-27** (desktop, RX 6800 XT, Ollama 0.34.3). A peer to the OpenCode fleet ([start-here](start-here.md), [model-architecture](model-architecture.md)), not a replacement. Terms: [glossary](glossary.md).

VS Code's BYOK (bring-your-own-key) mechanism treats Ollama's OpenAI-compatible endpoint (`http://127.0.0.1:11434/v1`) as another endpoint; each registered model becomes a picker entry, the role OpenCode's profiles play in the terminal. **Ollama is the only backend** (LM Studio was retired 2026-09-27), so a VS Code run uses the same baked `num_ctx` as OpenCode and the task benchmark.

The review-gate method built on this setup (two/three-seat audit, run protocol, case studies) moved to [review-gate/methodology.md](review-gate/methodology.md). Section names other docs cite — "The PR review that caught the silent bug", "Next steps", "The run protocol" — are there.

## Setup steps

Two files outside this repo, in the VS Code User config (`C:\Users\<you>\AppData\Roaming\Code\User\`):

| Step | File | What to do |
|---|---|---|
| 1 | `settings.json` | Add `"chat.agentHost.byokModels.enabled": true`. Needed since VS Code 1.132: a regression (microsoft/vscode#329545) hides all BYOK models from the agent picker without it |
| 2 | `chatLanguageModels.json` | One provider, `"vendor": "customendpoint"`, `"apiKey": "ollama"` (any placeholder), `"apiType": "chat-completions"`, one `models` entry per seat with `"url": "http://127.0.0.1:11434/v1"`, `toolCalling`, `vision: false`, `maxInputTokens`, `maxOutputTokens` |
| 3 | VS Code | **Reload window** (not just the picker) |
| 4 | Terminal | Check ids resolve: `curl.exe -s http://127.0.0.1:11434/v1/models`; check VRAM: `curl.exe -s http://127.0.0.1:11434/api/ps` |

The list mirrors the `ollama-desktop` block of `opencode/global/opencode.jsonc`: the tool-capable seats from `tests/run-tasks-models.tsv` plus the no-tools reviewer. One entry looks like:

```json
{
	"id": "qwen3.6:35b-a3b-coding",
	"name": "Qwen3.6 35B-A3B coding",
	"url": "http://127.0.0.1:11434/v1",
	"toolCalling": true,
	"vision": false,
	"maxInputTokens": 57344,
	"maxOutputTokens": 8192
}
```

### The budget rule

`maxInputTokens` + `maxOutputTokens` = the `num_ctx` Ollama serves (`$contextModels` in `startup.ps1`), and `maxOutputTokens` = the seat's `limit.output` in `opencode.jsonc`. Declaring the full `num_ctx` as input lets VS Code send a prompt that, plus the reply, overruns the window, and Ollama truncates the front of the prompt (same failure as OpenCode's missing `limit`). This file is the third place a context change must land, after `$contextModels` and `limit.context`.

| id | `num_ctx` | maxInput / maxOutput | toolCalling |
|---|---|---|---|
| `qwen3:14b` | 32768 | 24576 / 8192 | true |
| `qwen3:8b` | 32768 | 28672 / 4096 | true |
| `qwen3.6:35b-a3b-coding` | 65536 | 57344 / 8192 | true |
| `qwen3.5:9b`, `qwen3-coder:30b-a3b`, `laguna-xs-2.1`, `nemotron-3.5-lightning`, `north-mini-code-1.0` | 65536 | 61440 / 4096 | true |
| `devstral:24b`, `devstral-small-2:24b` | 32768 | 28672 / 4096 | true |
| `deepseek-r1:14b` | 16384 | 12288 / 4096 | false (reviewer) |

VS Code's agent preamble (its own system prompt and tool schemas, tens of thousands of tokens) cannot be trimmed the way OpenCode's was, so prefer the 64k seats for agent work here. The large first request also pays a full prefill: budget minutes for an offloaded seat's first turn; follow-ups reuse the KV cache.

## Seats

| Seat | Model | toolCalling | Job | Why |
|---|---|---|---|---|
| Auditor | `qwen3-coder:30b-a3b` | true | Reads files, runs commands, produces a `file:line`-cited audit | Must be tool-capable; only probe-PASS seats emit parseable calls ([tool-calling](tool-calling.md)) |
| Reviewer | `deepseek-r1:14b` | false | Second opinion on a plan handed over as text | Different trained family from the auditor, so no shared blind spots; no tools is a feature |
| Executor / tiebreak | `qwen3:14b` | true | Acts, and breaks Reviewer/Auditor ties | Tool-capable |

| Seat | Resident footprint |
|---|---|
| `qwen3-coder:30b-a3b` @64k | partly offloaded, ~6.8 GB on CPU ([roadmap](roadmap.md) → "Context budget"); ~36 tok/s |
| `deepseek-r1:14b` @16k | ~9–10.5 GB (sources disagree) |
| `qwen3:14b` @32k | 11.03 GB (+ `qwen2.5-coder:3b` = 12.34 GB; `troubleshooting.md` says 13.29, unreconciled) |

The three do not co-reside. Flow: audit with the 30B, review with R1 (Ollama evicts the 30B; review is text-only so slow is fine), execute with `qwen3:14b`.

Reviewer smoke test (measured 2026-09-18: `content` empty, `finish_reason` `"length"`, the budget spent on `reasoning`; hence the 4096 output budget, never a small cap):

```powershell
$body = '{"model":"deepseek-r1:14b","messages":[{"role":"user","content":"Reply with exactly: REVIEWER-OK"}],"max_tokens":64,"stream":false}'
curl.exe -s http://127.0.0.1:11434/v1/chat/completions -H "Content-Type: application/json" -d $body
```

## Gotchas

| Symptom | Cause | Fix |
|---|---|---|
| Chat fails "cannot be parsed as a URL" | `url` missing `/v1` | `http://127.0.0.1:11434/v1`, not `…:11434` |
| Model never appears in the picker | Flag missing, no full reload, or `toolCalling: false` hidden in some builds (microsoft/vscode#318968) | Set the flag, reload the window, then flip `toolCalling` to `true` (harmless for Ask-mode review) |
| Model id doesn't resolve | `id` must equal Ollama's listing | Check `/v1/models`; `:latest` tags resolve without the suffix |
| Long sessions lose their start | `maxInputTokens` declared as the full `num_ctx` | Apply the budget rule |
| Reviewer returns empty content | `max_tokens` too small for a reasoning model | Keep output budget ≥256; we use 4096 |
