# Homies: a blueprint for self-hosted household agents

**Homies** are specialized housekeeping agents that help keep a household's processes in motion: one small chat
agent per area of home life (appointments, meals, upkeep), each with its own tools, its own short instructions and a
local model. This page records the pattern so others can try it. It is a **blueprint, not a framework**: there is no
library to install. It puts existing pieces together (a tracker, a chat front end, a small tool per area) under a few
rules, and the rules are what make it work.

Written 2026-11-19 from what this repo built: the household plan ([household-assistant.md](household-assistant.md)),
the house agent ([household/phase2-chat.md](household/phase2-chat.md)) and the first Homie built to this pattern,
**Health** ([household/health-agent.md](household/health-agent.md)). **Next: Meals**, then an overall agent that
routes a question to the right Homie (see "Later").

**The name:** another open-source, self-hosted household project also calls itself "Homies" (found by a web search
on 2026-11-19; its page could not be opened from the session that wrote this). "Homies" is this repo's working name;
a public name is settled if this ever moves to a repository of its own.

## The pattern

| Layer | What it is here | Why |
|---|---|---|
| 1. **System of record** | A tracker database (Grocy): chores with repeat rules and dated completions, products, stores, custom lists | **The memory is a database, not the model.** Dates and history are facts; reminders keep working with every model off |
| 2. **Sources it reads** | Read-only feeds the household already keeps (each adult's private calendar feed) | Nothing is copied or re-typed |
| 3. **Homies** | One Open WebUI model per area: its own tool file, its own prompt, its own base model | One area's data never reaches another area's chat; each prompt stays short |

**How it relates to known agent patterns.** In the terms of Anthropic's
[Building effective agents](https://www.anthropic.com/engineering/building-effective-agents) (2024-12-19), a Homie is
closer to a *workflow*, "LLMs and tools orchestrated through predefined code paths", than to an open-ended agent: the
tool decides what is read and written, and the model chooses which tool to call and says the answer. The planned
overall agent is that post's *routing* workflow: it "classifies an input and directs it to a specialized followup
task", here a Homie.

## The rules

These are enforced in code and tests, not only written down. Each names where Health does it.

1. **The tool carries the reliability, not the model.** Every check that can be code is code, so a smaller model
   still gets it right:
   - names are matched by the tool, which **asks instead of guessing** when several or none match;
   - inputs are validated (a visit date in the future is refused, a date in another format is refused);
   - every refusal **says what to do next**, so a small model can recover without a retry loop.
2. **Nothing is written without the user's plain OK.** A write tool returns a preview first and writes only when it
   is called again with `confirm=true` **and** the user's last message approves with nothing else asked.
3. **Private areas run only on local models, and the install refuses anything else.** `openwebui_push.py --agent
   health` checks the base model against what the household's own model server serves, before and after writing.
4. **Each Homie sees only its own area.** Its tool returns only what belongs to it; Health names a calendar event only
   if it matches an appointment kind, and shows any other event as "busy".
5. **Secrets never reach the model or a log.** Keys and feed links live in encrypted settings (Open WebUI Valves) and
   are replaced by `[secret]` in any error.
6. **Tests against fakes, mutation-checked.** Each tool is tested against a fake tracker and fake feeds (local HTTP
   servers, synthetic data). Each rule above has a test that goes red when the rule is removed.
7. **No household data in the repository.** Data lives on the server; the repo holds code, blank templates and
   synthetic fixtures only.

## System requirements

Every number below is dated and tied to the run that measured it. **"Not measured yet"** means exactly that: the
numbers come from the household's own fleet (a server with a GPU, a desktop, a second PC) and from the small-model
eval being built next, not from guesses.

| Piece | Needs | Measured |
|---|---|---|
| Tracker (Grocy) | CPU only; a small container | Not measured yet (to come: `docker stats` on the server over a week of use) |
| Chat front end (Open WebUI) | CPU only; a few GB of RAM | Not measured yet (same) |
| Model | A GPU, or CPU only if slower answers are fine; memory grows with model size | Not measured yet (the eval below) |
| Phones | A browser on the home Wi-Fi | Nothing to measure: the chat is a web page |

**Tiers**, filled in from the eval:

| Tier | Meaning | Smallest model that passes | Seconds per answer | Hardware |
|---|---|---|---|---|
| **No GPU** | A mini PC or an old laptop | Not measured yet | Not measured yet | Not measured yet |
| **Minimum** | Every question answered right, slowly | Not measured yet | Not measured yet | Not measured yet |
| **Recommended** | Answers in a few seconds | Not measured yet | Not measured yet | Not measured yet |
| **Ours** | This household's fleet today | `qwen3-vl:8b` on the server's llama-server | Not measured yet | See [reference/machines.md](reference/machines.md) |

**The tracker and its reminders need no model at all.** If every model is off, chores still come due and the phones'
calendar still shows them; only the chat stops.

### Aiming small

The goal is the smallest model that still answers every question right, so more households can run it. The way
there is rule 1: each time a small model fails a question, the first fix to try is in the tool (a tighter input, a
clearer refusal, one tool doing the whole job), and only then a bigger model.

**The eval:** `tests/homies_eval.py` sends each Homie's real questions with the Homie's own prompt and tool
definitions (built from the tool file, as Open WebUI builds them) to a local model server, runs every tool call
against the same fakes the unit tests use, and scores each question on five checks:
- **tool:** the expected tool was called;
- **args:** with the expected arguments;
- **answer:** the final answer holds the facts the tool gave (a date may be written either way, `2026-05-10` or
  "May 10th");
- **private:** nothing from outside the area is named;
- **write:** a write happened only after the user's OK, and wrote exactly the expected record, or none at all.

A question passes when all five do. Health's six questions: what is due to book; what is coming up for one person;
when someone was last seen; whether a day is free; recording a visit (a preview, then the user's OK); and recording
a visit dated in the future, which must write nothing even after "OK". Its scoring is tested against scripted
stand-in models in `tests/test_homies_eval.py` (in CI): a careful one passes every question, and each kind of mistake
fails the check meant to catch it.

**The ladder (owner, 2026-11-19): Qwen3 at 0.6B, 1.7B, 4B and 8B**, smallest first. The first size that passes every
question fills the "minimum" row, and that model is then run on CPU only for the "no GPU" row. Compare models
question by question, paired, as in [methodology.md](methodology.md); one repetition is a first look, not a result.

**Running it (on the server; the fleet's step, not CI's):**
1. **Serve the four sizes** on the server's llama-server: pull `qwen3:0.6b`, `qwen3:1.7b` and `qwen3:4b` into the
   server's Ollama and add a section each to `server/llamacpp/models.ini`, keeping that file's contracts (exact tag
   name plus `alias`, Ollama's blob as `model`, explicit `c`, the sampling `ollama show --parameters` gives).
   `qwen3:8b` is already there. Check with `server/scripts/llamacpp-check.sh`.
2. **Run the ladder** outside a test window ([unattended-window.md](unattended-window.md)):
   ```bash
   python3 -I tests/homies_eval.py --url http://localhost:8090 --host server --stop-at-first-pass \
       --model qwen3:0.6b --model qwen3:1.7b --model qwen3:4b --model qwen3:8b
   ```
   Rows go to `tests/results/homies-eval.tsv`; the exit code is 0 when the last model run passed every question.
3. **The "no GPU" row:** add a CPU-only section for the smallest passing size (as `qwen2.5-coder-3b-cpu` does:
   `n-gpu-layers = 0`, `device = none`), run it alone with `--model <that section>`, and record its seconds.
4. **Fill the tiers table above** from the TSV, with the date and the run's commit. When a size fails, read the
   failing checks first: a wrong tool or argument points at the tool's descriptions, which may be the cheaper fix.

## Adding a Homie

Health is the worked example; each step names its file.

1. **Agree the scope with the people who will use it:** the questions it must answer, what it may write, what it must
   never see or do. Health: four questions, two writes, never books, no medical advice.
2. **Put the data in the tracker,** or name the read-only source. Health: "Book: <person> <kind>" chores plus a Grocy
   user entity `appointment_kinds`, loaded by `server/household/grocy_import.py`.
3. **Write the tool**, one file: `server/household/openwebui_health_tool.py`. Reuse the shared pieces: the OK check,
   ask-don't-guess matching, secret scrubbing.
4. **Write the prompt**, a few lines: `server/household/openwebui-health-prompt.md`.
5. **Test it against fakes and mutation-check every rule:** `tests/test_openwebui_health_tool.py`, run in CI.
6. **Add it to the install script:** an entry in `AGENTS` in `server/household/openwebui_push.py`, with
   "local model only" set for any private area.
7. **Write its runbook,** including a live check by the people who use it:
   [household/health-agent.md](household/health-agent.md).

## What not to do

- **Don't make the model remember.** Anything with a date goes in the tracker.
- **Don't give one chat every tool.** One area per Homie; a router can sit on top later.
- **Don't fix a tool's job with a longer prompt or a bigger model** before trying the tool itself.
- **Don't let a write happen on the model's say-so.** The user's own words decide.
- **Don't fine-tune on household data.** Tools and a database keep the data out of the model.

## Later

- **Meals** (next): what to cook with what is in the house, and the shopping list per store from the week's plan.
- **The overall agent:** one chat that routes each question to the right Homie. Open questions: whether it relays to
  the Homie's own model (keeping each area's data apart) or calls tools directly, and keeping private areas on local
  models.
- **Its own repository**, if others pick this up: the blueprint, the shared tool pieces and the eval, with the name
  settled first.
