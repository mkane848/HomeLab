# Household assistant, phase 2: a basic chat over Grocy (runbook)

Phase 2 of [household-assistant.md](../household-assistant.md), started on 2026-11-08 at the owner's choice, before
phase 1's month was up. It is **the most basic agent possible**: a chat (Open WebUI) whose one tool reads and changes
Grocy, with a five-line prompt. It is the baseline the area agents (upkeep, meals, projects) are built from later. The
first proof of concept was a Costco trip:
- building the list;
- checking it in the store;
- logging what was bought, dated and tied to the store.

**The pieces:**
- **The chat front end:** `openwebui`, in `server/docker/docker-compose.household.yml` (the `household` project, next
  to Grocy). It runs on `server:3000`, LAN only. It uses the models of the server's llama-server router (`:8090`) and
  has no GPU of its own.
- **The tool:** [`server/household/openwebui_grocy_tool.py`](../../server/household/openwebui_grocy_tool.py), with
  eight tools: `find_products`, `shopping_list`, `add_to_shopping_list`, `remove_from_shopping_list`,
  `record_purchase`, `stock`, `chores_due`, `complete_chore`.
  - A name that matches several products, or none, is sent back as a question. The tool never picks.
  - A purchase does not change the shopping list. Taking items off is asked for separately.
  - Tests: `tests/test_openwebui_grocy_tool.py`, against a fake Grocy, run in CI.
- **The prompt:** [`server/household/openwebui-household-prompt.md`](../../server/household/openwebui-household-prompt.md).
  It is deliberately bare: nothing about meals, budgets or advice.
- **The model:** `qwen3:8b`, the plan's "tool-calling 7 to 9B". Every router model is listed, so others can be
  compared from the model menu.

**How Open WebUI Tools work** ([Open WebUI's tools docs](https://docs.openwebui.com/features/extensibility/plugin/tools),
read 2026-11-08):
- **The schema:** each public method of `class Tools` is a tool. The text above its first `:param` is the tool's
  description ([development guide](https://docs.openwebui.com/features/extensibility/plugin/tools/development)).
- **Where it runs:** inside Open WebUI's server, with full access to it. So only the admin adds tools.
- **The Grocy key:** it is a Valve, encrypted at rest because `ENABLE_VALVE_ENCRYPTION=true` is set
  ([Valves](https://docs.openwebui.com/features/extensibility/plugin/development/valves)).

## Rules
- **Do not use the chat during a test window.** It shares the GPU with the coding seat (`--models-max 2`): see
  [unattended-window.md](../unattended-window.md).
- **No household data** in the repo, a commit, a PR or a pasted log.
- **Health stays off cloud models** ([household-assistant.md](../household-assistant.md) → Privacy). This chat uses
  only local models.

## 1. Install (agent, on the server)
1. **Pull `main`** in `~/HomeLab`.
2. **Set the variables** in `server/docker/.env` (git-ignored, mode 600):
   - `OPENWEBUI_TAG`: the newest [release](https://github.com/open-webui/open-webui/releases); `v0.13.2` on 2026-11-08.
   - `WEBUI_SECRET_KEY`: generated once with `openssl rand -hex 32`, never printed.
3. **Start it:** `cd ~/HomeLab && docker compose -p household -f server/docker/docker-compose.household.yml up -d`.
   This leaves Grocy as it is.
4. **Check it:**
   - the container is `Up` and within its limits (`docker stats household-openwebui`);
   - `http://<server>:3000` opens from the desktop;
   - the router's models are listed from inside the container:
     `docker exec household-openwebui curl -s http://host.docker.internal:8090/v1/models`.

**Installed version:** *(tag, date, by whom)*

## 2. First setup (owner, in the browser at `http://<server>:3000`)
1. **Create the admin account straight away.** The first account made is the admin. Then go to Admin Panel → Settings
   → General and turn off **Enable New Sign Ups**.
2. **A key for the chat:** in Grocy, under the user menu → Manage API keys, create a second key. The chat gets its own
   key so it can be revoked on its own.
3. **The tool:**
   - Workspace → Tools → **+**. Paste the whole of `openwebui_grocy_tool.py` and save.
   - Open the tool's **Valves** (the gear) and paste the key. Leave `grocy_url` as `http://grocy:80`.
4. **The model:** Workspace → Models → **+**.
   - Name it "Household", with base model `qwen3:8b`.
   - Paste the prompt file's text as the system prompt.
   - Under Tools, tick the Grocy tool.
   - Under Advanced Params, set Function Calling to **Native**. Save.
5. **Other users:** Admin Panel → Users → **+** for each adult. They pick "Household" from the model menu.
6. **On the phone:** open the same address in Safari, then Share → Add to Home Screen.

## 3. Using it: the Costco trip
- **Before:** "add dried mangoes and paper towels to the list". Then "what's on the list for Costco?": that shows
  Costco's items plus the items any store sells.
- **In the store:** ask the same, or use Grocy's own shopping list page.
- **After:** "we bought the dried mangoes, 2 egg bites and toilet paper at Costco". Each one becomes a dated Costco
  purchase. Then "take them off the list".
- **If the chat misbehaves,** Grocy itself has all of it at `http://<server>:9283`.

**What to note while using it** (it feeds the plan's PoC record, and the next agents):
- answers that were wrong, or tools it should have used and didn't;
- how long answers took;
- anything you wished it could do. That is the backlog for the area agents.

## Status
*(dated notes go here)*
