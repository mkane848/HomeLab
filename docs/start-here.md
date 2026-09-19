# Start Here

The one page to read when you sit down. Every command below has been run on
this desktop and the output is what you should actually see.

**Right now:** the server (`SERVER_IP`) will not POST — hardware recovery is
in progress ([`server-recovery-cpu-led.md`](server-recovery-cpu-led.md)). So
everything runs on the Windows desktop, and the profile you want is
`dev-workflow-quality` (qwen3:14b at 32k). Nothing below needs the server.

---

## The 90-second version

```powershell
cd M:\Projects\dev-docs
.\desktop\scripts\startup.ps1
.\desktop\scripts\opencode.ps1
```

Then in OpenCode, type a request. That's it. Everything after this explains
what those three lines did and how to tell when one of them didn't work.

---

## Step 1 — Start Ollama and set each model's context

```powershell
.\desktop\scripts\startup.ps1
```

**What it does:** starts `ollama serve` if it isn't running, then *bakes* a
context size into each model it manages and prints the contract:

```
[startup] Context contract (must match opencode.jsonc limit.context):
  qwen3:14b              32768
  qwen3:8b               32768
  qwen2.5-coder:3b       16384
  deepseek-r1:14b        16384  (deepseek-r1-16k@16384, deepseek-r1-32k@32768)
  qwen2.5-coder:7b       16384  (qwen2.5-coder-16k@16384)
  qwen2.5-coder:14b      32768
[startup] Desktop ready.
```

**What "baking" means.** A model's *context* is how many tokens it can hold at
once — your prompt, the files it has read, and its own reply all share that
budget. Ollama has one global default (`OLLAMA_CONTEXT_LENGTH`), but different
models here need different sizes, so we write a `num_ctx` parameter directly
into each model. That's the bake. It's a Modelfile with two lines:

```
FROM qwen2.5-coder:14b
PARAMETER num_ctx 32768
```

Re-running `startup.ps1` is always safe — it just rewrites those parameters.

> Older docs said baking existed because the Windows Ollama app ignored the env
> var. That was a v0.32 bug and it's fixed in 0.34.0. We still bake, but for a
> better reason: **per-model** control that one global setting can't give.

**Verify it worked:**

```powershell
curl.exe -s http://localhost:11434/api/version
```

```powershell
curl.exe -s http://localhost:11434/api/tags
```

The first returns the running version — `{"version":"0.34.1"}` as of
2026-09-19. The second lists every installed model. If either hangs or refuses,
Ollama isn't up — check `Get-Process ollama`.

> **If the version differs from the one above**, the desktop has auto-updated
> again (it is a native install, so the server's image pin does not cover it).
> Re-run `.\tests\test-toolcalls.ps1` before trusting any agent seat — see the
> tool-calling section below.

> **`curl.exe`, not `curl`.** In PowerShell, `curl` is an *alias* for
> `Invoke-WebRequest`, which doesn't understand `-s` — it swallows the flag and
> then sits there prompting `Uri:` for a URL you already typed. Press Ctrl+C.
> The `.exe` reaches the real curl that ships with Windows 11, so bash-style
> flags work unchanged. The native alternative, if you prefer it:
>
> ```powershell
> Invoke-RestMethod http://localhost:11434/api/version
> ```
>
> Same trap exists for `wget`, `ls`, `rm` and a few others — PowerShell aliases
> them to its own cmdlets with different flags. When a doc gives you a Unix-ish
> command and PowerShell asks for a parameter you thought you supplied, an alias
> is usually why.

---

## Step 2 — Launch OpenCode with a profile

```powershell
.\desktop\scripts\opencode.ps1
```

You should see this line before the UI appears:

```
[opencode] profile=dev-workflow-quality OPENCODE_MODEL=ollama-desktop/qwen3:14b
```

**What a profile is.** A profile is a shell script that exports environment
variables — nothing more. It doesn't install anything or start anything. It
just answers "which models, on which machines, for this shell":

```bash
export OPENCODE_MODEL="ollama-desktop/qwen3:14b"        # the agent you talk to
export OPENCODE_SMALL_MODEL="ollama-desktop/qwen2.5-coder:3b"  # titles, summaries
export OLLAMA_DESKTOP_BASE_URL="http://localhost:11434/v1"
export DEV_TIERS_DESKTOP=true                          # startup.ps1 reads this
```

OpenCode's config refers to those variables as `{env:OPENCODE_MODEL}`, so the
profile is what fills in the blanks.

**Two things that trip people up:**

1. **Profiles are per-shell.** Sourcing one in a terminal does not affect any
   other terminal, and closing that terminal forgets it. `opencode.ps1` exists
   precisely so you never have to remember — it sources the profile into its own
   process, then launches OpenCode.
2. **A bare `opencode` is not the same.** It falls back to whatever Windows
   User-level environment variables happen to be set. Those are currently
   correct, but the wrapper is the reliable path.

To use a different profile:

```powershell
.\desktop\scripts\opencode.ps1 -Profile dev-workflow-resident
```

**Verify it worked** — this prints the config OpenCode actually resolved, which
is the only thing that counts:

```powershell
opencode debug config
```

Look for `"model": "ollama-desktop/qwen3:14b"` and, under
`provider.ollama-desktop.models`, a `limit` block on every model. If `limit` is
missing, see [`troubleshooting.md`](troubleshooting.md) — that exact bug made
every request fail for weeks.

---

## Step 3 — Prove it can actually do something

Type this into OpenCode:

```
Create a file at docs/_scratch.md containing the single line: it works
```

It should ask permission to write (the config sets `edit: "ask"`), you approve,
and the file appears. You'll see:

```
← Write docs/_scratch.md
Wrote file successfully.
```

Delete it afterwards. **If the agent says it created the file but the file isn't
there, that is the single most important failure mode in this setup** — read the
next section.

---

## The thing that will confuse you most: not every model can use tools

An agent that can read and edit files does it by emitting a **tool call** — a
structured block the runtime executes. A model that can't produce one will
often *describe* the call in prose instead, and then claim it worked.

Measured on this desktop 2026-09-17 on Ollama 0.34.0, and re-measured
2026-09-19 on **0.34.1** after the desktop auto-updated — **5 of 13 installed
models pass**. Every previously-measured model reproduced its earlier result,
including the *mode* of each failure, so the two versions behave identically
here. Raw output: [`tests/results/toolcalls-0.34.1.txt`](../tests/results/toolcalls-0.34.1.txt).

| Model | Can call tools? |
|---|---|
| `qwen3:14b` | **yes** — the main seat (watch for repeated calls below) |
| `qwen3:8b` | **yes** — the lighter main seat in `dev-workflow-resident`/`dev-desktop-only` |
| `qwen3.5:9b` | **yes** — first measured 2026-09-19 |
| `qwen3-coder:30b-a3b` | **yes** — first measured 2026-09-19; the review-gate auditor seat |
| `devstral:24b` | yes, but 8.1 tok/s — it spills out of VRAM |
| `qwen2.5-coder` (3b / 7b / 14b / -16k) | no — prints the call as chat text |
| `deepseek-r1` (14b / -16k / -32k / -0528:8b) | no — ignores the tool, answers in prose |

The count moved 3/10 → 5/13 only because three models were installed after the
first baseline; two of them pass. No model changed its result.

**Role tells you nothing about this.** `qwen3:14b` is classed `reasoner` in the
catalog and calls tools fine. `qwen2.5-coder:14b` is classed `coder` and cannot
call one at all.

**And passing the probe isn't enough.** Same prompt, same config, measured:

| Model | Wall | `write` calls |
|---|---|---|
| `qwen3:8b` | **96.1 s** | **1** |
| `qwen3:14b` | 217.2 s | **6** |

The 14B wrote the same file six times for one request. It won the seat anyway
on 2026-09-17 for its loose-prompt intent handling — that is the north-star
trade (see [`roadmap.md`](roadmap.md) → "End goal"). Both costs stand: it is
~2.3× slower and it repeats tool calls. **If the `← Write` lines repeat for a
single request, it does not recognise completion — for an append, a `git
commit`, a migration or an `rm`, drop back to `qwen3:8b` before letting it
continue.** Count the `← Write` lines on any real task and treat repeats as the
safe-stop signal.

Check any model yourself:

```powershell
.\tests\test-toolcalls.ps1 -Model qwen3:14b
```

```powershell
.\tests\test-toolcalls.ps1
```

The first tests one model, the second tests everything installed. `PASS` means
it returned a real `tool_calls` entry.

**Why this matters more than model size.** `qwen2.5-coder:14b` writes better
code than either qwen3 — and is still the wrong choice to drive a session,
because it cannot touch a file. That's why every main seat is a qwen3, and why
`/implement` and its coder subagent were deleted rather than left in place
looking functional.

The config enforces it: every model that fails the probe carries
`"tool_call": false`, so OpenCode doesn't offer it tools at all. And
`tests\test-profiles.ps1` FAILs any profile whose main seat isn't tool-capable.

The coder and reasoner models are still installed and registered on purpose.
Switch to one deliberately when you want *text* — an explanation, a review, a
tricky function — and switch back to drive work.

---

## The `/plan` workflow

For anything bigger than a single edit:

```
/plan add a --DryRun switch to desktop/scripts/sync-skills.ps1
```

It runs on the main agent, defined in
[`opencode/commands/plan.md`](../opencode/commands/plan.md). It reads the
relevant files and writes `docs/implementation-tasks.md` with two sections:
risks and gaps cited by `file:line`, then a numbered task list where each task
names the files it changes and how to check it worked.

> This used to dispatch a `planner` subagent. That agent was deleted on
> 2026-09-17 — it never called the write tool, and the parent then reported a
> file that did not exist. The fix that made `/plan` work was **shortening the
> prompt**: on an 8B, a long careful contract produces worse compliance than a
> short blunt one.

**Read the plan before acting on it.** In a verified run its line numbers were
accurate and two of its three interpretations were inverted — it saw
`if ($DryRun) { log } else { act }` and reported the guard as missing. Open each
cited line before believing the claim about it.

Then, in the same session:

```
execute task #1 from docs/implementation-tasks.md
```

**Why split it at all?** The planner gets one job and a clean context window, so
it reads broadly without the conversation history competing for space. The main
agent then executes with a concrete list instead of a vague goal.

> The bottom-left **Plan/Build toggle is not `/plan`.** The toggle only changes
> which tools the current model may use. `/plan` is a command that dispatches a
> different agent. In Plan mode nothing is ever written to disk.

**Status:** `/plan` runs on the main agent — the planner subagent
(`opencode/agents/planner.md`) was deleted on 2026-09-17. It had been pinned to
`deepseek-r1-32k`, which cannot call the write tool: it answered at length and
claimed "The task tool has written `docs/implementation-tasks.md`" without
writing anything. The write path itself is proven (qwen3:14b writes files
correctly), so this should work; the thing to check the first time you run it
is simply whether `docs/implementation-tasks.md` actually appears on disk. If
it does not, the model described the call instead of making it — same failure,
and worth reporting.

---

## Knowing what's loaded, and why it matters

```powershell
curl.exe -s http://localhost:11434/api/ps
```

This shows which models are in VRAM right now, with their context and size:

```
qwen3:8b            ctx=32768  vram=7.16GB
qwen2.5-coder:3b    ctx=16384  vram=1.31GB
```

**Residency and eviction.** Your RX 6800 XT has 16 GB, of which ~14.8 GB is
usable. If a second model doesn't fit alongside the first, Ollama **evicts** the
first. That costs ~14 seconds to reload *and* throws away the cached prompt
prefix, so the next turn re-processes everything from scratch.

This is why the small model is a 3B. The pair above is **13.29 GB** and both
stay put. The old setup paired a 14B (11.27 GB) with a 7B (5.22 GB) = 16.5 GB,
which does not fit — so every title generation silently evicted the main agent.

**Why 32k and not 16k.** The system prompt plus tool schemas measure 11,441
tokens. Subtract the 4,096 reserved for output and a 16k window leaves about
**850 tokens** of actual working room — you'd hit the ceiling on the first real
question. At 32k it's ~17,200. That's the difference between a model that runs
and one you can use.

Budget from `/api/ps`, never from `catalog.tsv`. The catalog lists the file size
on disk; real VRAM adds the KV cache and compute buffers and runs 1–3 GB higher.

**If you're gaming, the GPU is shared.** Measured with Guild Wars 2 running,
available VRAM drops from 14.8 GiB to **12.5 GiB**, and Ollama starts refusing
or evicting anything large:

```
msg="llama-server model predicted to exceed available memory, evicting"
```

Only `dev-workflow-resident` survives gaming (its pair is 11.97 GB), so that is
the profile to switch to when the GPU is shared. The `dev-workflow-quality`
pair does *not*:

| Profile | Pair | VRAM | While gaming (~12.5 GB) |
|---|---|---|---|
| `dev-workflow-quality` | `qwen3:14b` @32k + 3b | 13.29 GB | **no — evicts** |
| `dev-workflow-resident` | `qwen3:8b` @32k + coder-16k | 11.97 GB | fine |

What will *not* survive it at all: anything you deliberately switch to that's
over ~12 GB — `qwen3:14b` (11.03 GB) is borderline, `qwen2.5-coder:14b`
(11.27 GB) likewise, `devstral:24b` (13.89 GB) has no chance. Close the game
first (or use `dev-workflow-resident`).

Benchmarks taken while gaming are meaningless — but `test-toolcalls.ps1`
verdicts are still valid, because whether a model emits a tool call has nothing
to do with free VRAM. Watch for `[ERROR] … timed out` rather than `[FAIL]`:
that's contention, not a verdict.

---

## Tools: skills and MCP servers

Two ways to give the agent extra abilities, and both cost tokens on **every
single request**:

- A **skill** is a folder with a `SKILL.md` — instructions the agent loads when
  relevant. Its name and description sit in the system prompt permanently.
- An **MCP server** is an external process exposing tools (Vercel, Render,
  Docker, a browser, Postgres). Its entire tool schema sits in the system prompt
  permanently.

With everything switched on, that preamble measured **46,505 tokens** — roughly
three times what a 16k model can even hold. Ollama truncated it, threw away the
system prompt, and every request died after five minutes.

So the layering is:

| Layer | Contains | Why |
|---|---|---|
| Global (`opencode/global/opencode.jsonc`) | no MCP servers, 8 skills | every project pays this cost |
| Project (`<project>/opencode.jsonc`) | whatever that project needs | only that project pays |

Copy [`opencode/project-override/opencode.jsonc`](../opencode/project-override/opencode.jsonc)
into a project and uncomment what it needs. Project config merges over global,
and `{ "enabled": false }` switches off anything inherited. Skills are pointed
at in place, never copied:

```jsonc
"skills": { "paths": ["M:/Projects/dev-docs/skills/vercel"] }
```

Current preamble: **11,441 tokens**. To re-measure after any change, run a
trivial request and read `task.n_tokens` from the Ollama log.

---

## When something looks wrong

Run this first — it checks every live profile against what is actually configured
and serving (expect 81 PASS, 0 FAIL, 0 WARN):

```powershell
.\tests\test-profiles.ps1
```

Expect `0 FAIL` and `0 WARN`. Server-related WARNs disappeared when those
profiles were parked. Then, by symptom:

| Symptom | Likely cause | Where |
|---|---|---|
| Agent claims an edit that didn't happen | model can't call tools | [troubleshooting.md](troubleshooting.md) → "Agent 'says' it edited a file" |
| Request hangs minutes then fails | preamble too big / missing `limit` | → "OpenCode request hangs ~5 minutes" |
| Everything got slow | main model was evicted | → "Desktop is slow" |
| "AMD driver is too old" | ROCm is unavailable on this GPU, permanently | → "ROCm not detected" |
| Model not in `/models` | not registered in `opencode.jsonc` | → "Local model not in /models" |

---

## Where to go next

| I want to… | Read |
|---|---|
| understand which profile to use | [profiles.md](profiles.md) |
| know what runs where | [model-architecture.md](model-architecture.md) |
| check VRAM and GPU facts | [hardware.md](hardware.md) |
| add or change a model | [AGENTS.md](../AGENTS.md) → "Model catalog" |
| fix the server | [server-recovery-cpu-led.md](server-recovery-cpu-led.md) |
| run models in VS Code / review-gate a plan | [lmstudio-vscode.md](lmstudio-vscode.md) |
| see what's still open | [roadmap.md](roadmap.md) |
