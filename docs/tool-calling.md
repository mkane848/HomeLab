# Tool calling: which models can edit files

An agent reads and edits files by emitting a **tool call**, a structured block the runtime executes. A model that cannot produce one often *describes* the call in prose and then claims it worked. This is the most important failure mode in this setup. Terms: [glossary](glossary.md).

## Rules

| Rule | Why |
|---|---|
| Probe before seating: `.\tests\test-toolcalls.ps1 -Model <tag>` | Tool-calling is decided by chat template and weights, not model family or catalog `class` |
| A probe PASS is necessary, not sufficient | `lfm2.5:8b` passes in seconds and made 0 writes on 8 of 8 real tasks. Which seat lands edits is measured by the task benchmark ([roadmap](roadmap.md) → Executor standings) |
| Failing models carry `"tool_call": false` in `opencode.jsonc` | OpenCode then offers them no tools |
| `tests/test-profiles.ps1` FAILs a profile whose main seat is not tool-capable | Enforces the above |
| Coder/reasoner models stay installed for *text* (explanation, review) | Switch to one deliberately, then switch back to drive work |

## What the probe measured

Results are rows in [`tests/results/toolcalls-summary.tsv`](../tests/results/toolcalls-summary.tsv) (host, Ollama version, model, status). A result is stale on host + engine + engine version, so it is re-run on every update. The 2026-09-22/23 sweep (desktop on Ollama 0.34.3, node3 on 0.34.2) found 13 of 22 models passing.

| Family | Can call tools? | Notes |
|---|---|---|
| `qwen3.6:35b-a3b-coding` | yes | The main seat |
| `qwen3:8b`, `qwen3:14b`, `qwen3.5:9b`, `qwen3-coder:30b-a3b` | yes | `qwen3.5:9b` retired as an executor 2026-10-13 (crashes on context overflow in about half its runs) |
| `devstral:24b`, `devstral-small-2:24b` | yes | `devstral:24b` spills out of VRAM: 8.1 tok/s |
| `laguna-xs-2.1`, `nemotron-3.5-lightning`, `north-mini-code-1.0` | yes | desktop |
| `lfm2.5:8b`, `ministral-3:8b`, `ornith:9b` | yes | node3 |
| `qwen2.5-coder` (3b / 7b / 14b / -16k) | **no** | Prints the call as chat text; its template needs `<tool_call>` tags the weights never emit |
| `deepseek-r1` (14b / -16k / -32k / -0528:8b) | **no** | Ignores the tool, answers in prose |
| `glm4:9b` | **no** | Ignores the tool (probed 2026-09-20 on node3) |

## Passing the probe is not enough: repeated calls

Same prompt, same config:

| Model | Wall | `write` calls |
|---|---|---|
| `qwen3:8b` | 96.1 s | 1 |
| `qwen3:14b` | 217.2 s | 6 |

The 14B wrote the same file six times for one request. **If `← Write` lines repeat for a single request, the model does not recognise completion.** For an append, `git commit`, migration or `rm`, drop to `qwen3:8b` first. Count `← Write` lines on any real task.

## Check it yourself

```powershell
.\tests\test-toolcalls.ps1 -Model qwen3:14b   # one model
.\tests\test-toolcalls.ps1                    # everything installed
```

`PASS` means a real `tool_calls` entry came back. `[ERROR] … timed out` is contention (for example gaming), not a verdict.

## `/plan` workflow

`/plan <scope>` (defined in [`opencode/commands/plan.md`](../opencode/commands/plan.md)) runs on the main agent, reads the relevant files and writes `docs/implementation-tasks.md`: risks cited by `file:line`, then numbered file-scoped tasks with a check for each. Then: `execute task #1 from docs/implementation-tasks.md`.

| Gotcha | Detail |
|---|---|
| Verify the plan | In a verified run its line numbers were accurate and two of three interpretations were inverted. Open each cited line |
| The file must exist | If `docs/implementation-tasks.md` did not appear, the model described the write instead of making it |
| Plan/Build toggle is not `/plan` | The toggle only gates tools; Plan mode writes nothing |
| History | `/plan` once dispatched a `planner` subagent that never called the write tool; it was deleted 2026-09-17 and the prompt shortened |
