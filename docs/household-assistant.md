# Household assistant: plan

A planning doc, written 2026-11-07 at the owner's request. It covers a private, self-hosted assistant for the owner
and their wife, about the business of running the house. **Nothing here is installed or scheduled.** It stays
non-technical on purpose: what the thing must do, the shape that does it, what already exists, and how a proof of
concept on the existing fleet decides what hardware (if any) to buy. Project facts were read from each project's own
page on 2026-11-07 (sources in [references.md](references.md) → "Household assistant"). Re-read them before any
install; this field moves monthly.

## What it is for

From the owner, 2026-11-07:

1. **Help deciding.** "We have a lot of raw data and good ideas, but sometimes we just need help making a decision or
   finding a new combination with what we've got."
2. **Staying consistent with semi-regular work.** Spring cleaning, maintaining tools and parts of the house.
3. **Not losing the big task ahead.** Something months out that must not slip.
4. **"When did we last do X?"** Replacing a filter, cleaning a thing.

**Hard requirements:** self-hosted, uses the household's own data, private.

**Answers given on 2026-11-07:**
- **Data:** in notes apps, spreadsheets, a shared calendar and people's heads. To be narrowed from real examples.
- **Interface:** chat on both phones.
- **Smart home:** some devices, no Home Assistant yet.
- **Hardware:** a proof of concept on what the fleet already has comes first, and any purchase follows from what it
  finds.

## The core idea: the memory is a database, not the model

Needs 2 to 4 are **facts with dates**: a task, how often it recurs, when it was last done, what's due. A language
model is bad at holding those (it forgets, or invents a plausible date) and good at talking about them. So the design
is three layers, each replaceable on its own:

| Layer | Holds | Works without a GPU? |
|---|---|---|
| **1. System of record** | Tasks, recurrence rules, completion history, the long-range project list, assets (filter sizes, model numbers, manuals, warranties) | **Yes.** Reminders and "last done" keep working with every model host off. |
| **2. Knowledge** | The household's notes, docs, spreadsheets and calendar exports, indexed for retrieval (RAG) | Storage yes; indexing and search need a small embedding model (CPU is enough) |
| **3. Agents** | One chat front end with an agent per area (house upkeep, meals/pantry, projects and planning, later finances). Each has its own instructions, its own slice of layer 2, and **tools** that read and write layer 1 ("we replaced the furnace filter today") | No: needs a model host |

**"Trained on our data" means retrieval plus tools, not fine-tuning.** Retrieval reflects a new note in minutes, can
show where an answer came from, and keeps private facts out of model weights. A fine-tuned model freezes what it knew
at training time, and anyone who gets the weights gets the data. Fine-tuning (a LoRA) stays a later option for *tone
or format* only, if the agents still sound wrong after retrieval works.

This fits the repo's north star (`AGENTS.md`): the household layer does not care which machine answers. A profile
picks the host, as it does for the coding seat.

## What already exists

### Commercial

- **Home-maintenance apps** (HomeZada, Centriq and similar). Their data model is the one to copy: asset → task →
  recurrence → history, with reminders as tasks come due. They are cloud services, so they fail the privacy
  requirement. *Not re-read: their sites were unreachable from this session on 2026-11-07. The description comes from
  search results.*
- **Voice assistants** (Alexa+, Gemini for Home). Good at reminders, lists and calendar, but the household's data
  lives with the vendor. They set the bar for ease of use and are not candidates. *Same caveat.*

### Open source: the system of record (layer 1)

| Project | What it does (from its page, 2026-11-07) | Fit |
|---|---|---|
| [Donetick](https://github.com/donetick/donetick) | Chores and tasks for a household. Natural-language entry ("Change water filter every 6 months" sets the recurrence). Daily to yearly schedules plus an adaptive one that learns from completions. Rotates assignees. Subtasks, labels, REST API, webhooks, a Home Assistant integration. AGPL-3.0. | **Lead candidate** for needs 2 to 4 |
| [Homebox](https://github.com/sysadminsmedia/homebox) | Home inventory (Go, SQLite): items, locations, documents and warranties, "purchase & maintenance tracking … maintenance schedules for your items" | The asset side: which filter, which manual, when bought |
| [Grocy](https://github.com/grocy/grocy) | "ERP beyond your fridge": groceries and household management, with a chores feature set and a REST API. MIT. | One app for pantry plus chores, if the meals agent matters more than rotation |

The likely pick is **Donetick plus Homebox**, or Grocy alone. Phase 0's real list decides which. Writing a custom
tracker is not on the table while these exist.

### Open source: chat, knowledge and agents (layers 2 and 3)

| Project | What it does (from its page, 2026-11-07) | Fit |
|---|---|---|
| [Open WebUI](https://github.com/open-webui/open-webui) | Self-hosted chat UI "built to run entirely offline". Talks to Ollama or any OpenAI-compatible API, which is what the fleet's llama-server seats already speak. RAG and MCP among its topics. Custom licence that requires keeping its branding. | **Lead candidate** for phone chat: a browser app on both phones, one account each |
| [Khoj](https://github.com/khoj-ai/khoj) | "Your AI second brain", self-hostable: chat with local or online models over your own documents, plus scheduled automations and notifications. AGPL-3.0. | Alternative if a daily or weekly briefing ("this week: …") matters more than per-area agents |

### Home Assistant (optional, later)

Home Assistant is not needed for needs 1 to 4. It becomes useful if the agents should see or act on devices, or for
voice. What its docs say (read from the
[docs source on GitHub](https://github.com/home-assistant/home-assistant.io), 2026-11-07):

- **[Ollama integration](https://github.com/home-assistant/home-assistant.io/blob/current/source/_integrations/ollama.markdown)**
  (since 2024.4): a conversation agent backed by an external Ollama server. Controlling the house is "an experimental
  feature", needs a model that supports tools, and the page advises exposing fewer than 25 entities.
- **[MCP Server](https://github.com/home-assistant/home-assistant.io/blob/current/source/_integrations/mcp_server.markdown)**
  (since 2025.2): Home Assistant offers its devices as tools to an outside agent. Its setup examples include OpenCode,
  the client this repo already runs.
- **[MCP client](https://github.com/home-assistant/home-assistant.io/blob/current/source/_integrations/mcp.markdown)**
  (since 2025.2): Home Assistant's own agent can use tools from an outside MCP server (Streamable HTTP, then SSE; tools
  only).
- **[Fully local voice](https://github.com/home-assistant/home-assistant.io/blob/current/source/voice_control/voice_remote_local_assistant.markdown):**
  Whisper speech-to-text takes "around 8 seconds" on a Raspberry Pi 4 and "under a second" on an Intel NUC. The faster
  Speech-to-Phrase engine handles only a fixed set of commands.
- **[home-llm](https://github.com/acon96/home-llm)** (community): a custom integration with small (under 5B) models
  fine-tuned for device control, running on llama.cpp, Ollama or any OpenAI-compatible server.

## Proof of concept on the existing fleet

The owner's call: **no new hardware until a proof of concept (PoC) has run on what we have.** The PoC's second job is
to produce the numbers that decide the purchase. Machines are as in
[reference/machines.md](reference/machines.md).

| Piece | Runs on | Why, and the constraint |
|---|---|---|
| Tracker, Open WebUI, vector store, nightly backup (Docker containers) | `server` | Already Docker and the closest thing to always-on. These containers need no GPU and little CPU, which matters because the 3700X is the fleet's weakest CPU and is busy with qwen3.6's CPU spill. |
| Chat model, a tool-calling 7 to 9B (e.g. `qwen3:8b`, probe-PASS on server and node3) | `server`'s llama-server when no coding run holds the GPU; `node3` as the fallback when it is free | One big job per GPU ([fleet-side-projects.md](fleet-side-projects.md)). Household chat must never overlap a benchmark round or a run window ([unattended-window.md](unattended-window.md)). |
| Embeddings for retrieval (a small model, e.g. `nomic-embed-text`, already in `models/catalog.tsv`) | CPU on the server, or batch indexing on node3 or the desktop | Re-index in batches, not on every edit, to keep load off the 3700X |
| Phone access | Open WebUI in the phones' browsers on the LAN; a VPN (WireGuard or Tailscale) from outside the house | Never port-forward the household's data to the internet |

The tracker sends reminders even with every GPU off, so **the PoC depends on the fleet only for chat.** That is the
risk the PoC measures.

**What the PoC records** (a dated TSV under `tests/results/`, in the repo's usual way):

- **Availability.** How often a question found no model host up, or a GPU busy with coding work.
- **Latency.** Time to the first word and to the full answer, per host, on the real phase-0 questions.
- **Quality.** Pass or fail on each phase-0 question, per model tried. Did the tool call reach the tracker? Was the
  "last done" date right?
- **Load.** The server's CPU and RAM headroom with the containers running, and any slowdown of the coding seat.

**The purchase decision, written now so the numbers make it.** Apply these after about a month of real use:

- **Availability or contention is the problem:** buy a small always-on box (an N100-class mini PC, around 10 W) and
  move the containers off the server. This is the cheap fix, and it also hosts Home Assistant if that is adopted.
- **Quality or latency needs a bigger or always-loaded model:** buy a dedicated GPU box, or a card for one host,
  sized from the measured memory need.
- **Local voice is wanted:** the host needs to be closer to a NUC than a Raspberry Pi 4 (the voice docs above). That
  folds into the first option.
- **None of these bite:** buy nothing.

## Phases

0. **Inventory, no software.** Each of you lists 20 to 30 real recurring things (with the last date, if known), 5 big
   things ahead, and 5 "help us decide" questions you actually had. These become the PoC's test set, and they settle
   which data sources matter.
1. **Tracker only.** Run the tracker in Docker on `server`, load the list, get reminders onto both phones, and live
   with it for a month. This alone answers "when did we last" and "what's due".
2. **Chat over the tracker.** Open WebUI plus one house-upkeep agent whose tools read "due" and "last done" and log a
   completion. The model is a fleet seat.
3. **Knowledge.** Import notes, sheets and calendar exports for retrieval, and add the decision-help agents (meals,
   projects).
4. **The hardware decision.** Apply the criteria above to the PoC's numbers. Record the decision and its evidence here.
5. **Optional.** Home Assistant for devices and sensors (e.g. a filter reminder driven by the furnace's run hours) and
   voice. Fine-tuning only if tone or format is still wrong after phase 3.

A phase is done when your real phase-0 questions get correct answers, not when the software runs.

## Privacy

- Everything stays on the LAN plus the VPN. No cloud model calls by default. A cloud fallback, if ever wanted, is
  opt-in per agent and never for the private areas.
- One account each. Decide up front what is shared and what is personal.
- Back up the tracker's database nightly, with a copy off the server: it holds the history that matters, and the
  server has been down for weeks before ([server-recovery-cpu-led.md](server-recovery-cpu-led.md)).
- Secrets follow the repo's rule: they live outside the repo, never in it.

## Open questions

- Donetick plus Homebox, or Grocy alone? Decided from the phase-0 list.
- Which data sources first? Decided from real examples (owner, 2026-11-07).
- Does a seat on `server` stay loaded for household chat, or load on demand? The PoC's availability numbers decide.
