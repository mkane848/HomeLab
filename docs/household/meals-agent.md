# Household assistant: the Meals agent (runbook)

**Meals** is the household's cooking helper, the second Homie ([homies.md](../homies.md)) after Health
([health-agent.md](health-agent.md)). Planned with the owner on 2026-11-19 in five approved chunks. It is a separate
chat in Open WebUI ("Meals" in the model menu), built the same way: one tool, one short prompt, a local model.

It answers:
- **"What can we make tonight / tomorrow?"** The household's recipes that can be made with what is in stock, then
  those missing one or two ingredients, naming them. Grocy works out what is in stock, not the model.
- **"What's planned this week?"** The meal plan for seven days.
- **"What do we need from <store>?"** The planned recipes' missing ingredients, for products bought at that store or
  at any store, minus what is already on the shopping list.
- **"When did we last have <dish>?"** The last day it was on the meal plan, so meals do not repeat too often.

It records, **only after the user's plain OK**: a meal on the plan, the shopping for a store (onto Grocy's shopping
list, each item noted "Meals: <recipe>"), and a recipe the user sent as a file or a link.

**It never orders or buys anything, and gives no diet or nutrition advice.** The owner asked for no dietary filtering
for now (2026-11-19).

## The pieces

| Piece | File | Notes |
|---|---|---|
| Tool | [`server/household/openwebui_meals_tool.py`](../../server/household/openwebui_meals_tool.py) | Six tools: `what_can_we_make`, `week_plan`, `plan_meal`, `shopping_for`, `last_had`, `add_recipe` |
| Prompt | [`server/household/openwebui-meals-prompt.md`](../../server/household/openwebui-meals-prompt.md) | Meals only; never guess; ask before writing; copy recipes as sent |
| Install | [`server/household/openwebui_push.py`](../../server/household/openwebui_push.py) `--agent meals` | Refuses a base model the server's llama-server does not serve |
| Tests | `tests/test_openwebui_meals_tool.py`; Meals' questions in `tests/homies_eval.py` | A fake Grocy with made-up recipes, stock, a plan and three stores; run in CI |

## Where the data lives: all in Grocy

| What | Grocy |
|---|---|
| Recipes and their ingredients | `recipes` (name, description, type) and `recipes_pos` (one line per ingredient, linked to a product) |
| What a recipe is missing | Grocy's own `recipes_pos_resolved` view and `/recipes/fulfillment`: per ingredient, whether it is in stock, how much is missing, how much is already on the shopping list |
| The meal plan | `meal_plan` (a day, a recipe or a note) |
| The shopping list | Grocy's default list, as the house agent uses; a product's store is its `shopping_location_id` |

Read in Grocy's source on 2026-11-19: the tables' columns from its migrations
([`0045.sql`](https://github.com/grocy/grocy/blob/master/migrations/0045.sql) `recipes_pos`,
[`0071.sql`](https://github.com/grocy/grocy/blob/master/migrations/0071.sql) recipe `type`,
[`0096.sql`](https://github.com/grocy/grocy/blob/master/migrations/0096.sql) `meal_plan`,
[`0249.sql`](https://github.com/grocy/grocy/blob/master/migrations/0249.sql) `recipes_pos_resolved`), and the
endpoints from [`grocy.openapi.json`](https://github.com/grocy/grocy/blob/master/grocy.openapi.json).

**Two things to know:**
- **Grocy keeps hidden recipes of its own** for meal plan days and weeks (types `mealplan-day`, `mealplan-week`,
  `mealplan-shadow`). Meals shows only the household's recipes (type `normal`).
- **Quantities stay in the recipe's text.** A recipe says "2 cups onion"; Grocy stocks onions by the piece. Meals
  links each ingredient line to its product with an amount of 1 and keeps the line as written, so "can we make it"
  means "every ingredient is in the house", not "there is enough". Amounts can be set per line in Grocy where it
  matters.

## Getting recipes in

- **The CopyMeThat migration (one time; owner, 2026-11-19).** The household is leaving CopyMeThat. Its export is
  loaded into Grocy by `grocy_import.py`, built against a real export the owner sends, **not yet written**: dry run
  first, listing each recipe and which product each ingredient matched, then `--apply`. PDFs and printable recipes
  follow the same way when the owner supplies them.
- **In chat, from then on.** Either adult sends a recipe file or link to the Meals chat. The model copies its name,
  ingredients (one per line, as written) and steps into `add_recipe`, which shows what it will add:
  - an ingredient is linked to a product only when exactly one product matches (the more specific one wins: "green
    onion" over "onion");
  - every other line is kept in the recipe's text and listed as "not linked", **never made into a product**;
  - nothing is written until the user says OK.

## Privacy and safety

- **Every write waits for the user's own OK**, checked by the tool from the chat, as in Health.
- **Local model by default:** `openwebui_push.py --agent meals` refuses a base model the server's llama-server does
  not serve.
- **The Grocy key** is an encrypted Valve, replaced by `[secret]` in any error.
- **No household data in the repository**; the tests use made-up recipes and stores.

## Setting it up (the owner's steps)

1. **Pull the change on the server.** `cd ~/HomeLab && git pull`.
2. **Recipes:** send the CopyMeThat export when convenient (only its format is used to build the importer; the recipes
   stay out of the repository). Until then, add a few regular dinners in Grocy (Recipes) to try Meals with.
3. **The tool and model in Open WebUI** (once, as admin):
   - **Workspace → Tools → New:** id `meals_recipes`, name "Meals". Paste the tool file's contents, save. Set its
     `api_key` Valve to the Grocy key (the house tool's, or a separate one).
   - **Workspace → Models → New:** id `meals`, name "Meals". Base model: a local llama-server model (today
     `qwen3-vl:8b`). Tools: only "Meals". Share it with both accounts.
   - After every `git pull`:
     ```bash
     python3 -I server/household/openwebui_push.py --agent meals            # dry run
     python3 -I server/household/openwebui_push.py --agent meals --apply
     ```
4. **The live check:** ask "what can we make tonight?", "plan this week", "what do we need from Aldi?", "when did we
   last have <dish>?", and add one recipe by sending a link. Record the result under "Status".

## Status

- **2026-11-19:** built and tested in the repo. The owner's steps 1 to 4 and the CopyMeThat importer are still to do.
