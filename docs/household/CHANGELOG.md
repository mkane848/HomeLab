# Household assistant: changelog

Changes to the household assistant: `server/household/`, `server/docker/docker-compose.household.yml`,
`docs/household*`, the desktop's backup pull, and their tests. Newest first, written like the repo's
[CHANGELOG.md](../../CHANGELOG.md), which keeps the fleet's changes. A change that touches both (a shared seat in
`models/server-seats.tsv`, a check both use) is entered there, with one line here pointing at it.

The entries from 2026-11-07 to 2026-11-12 were moved here from the repo's changelog on 2026-11-13, word for word.
**No household data in this file**: counts and versions only, as in the runbooks.

## [Unreleased]

- **fix: household tool 0.3.5 reads a receipt pasted as one line, and skips its footer (2026-11-12).**
  - **Why:** in the live run the chat sent the whole receipt, footer included, as one string with backslash-n breaks.
    The tool read it as one line and refused it. Nothing was written.
  - **Change:** a literal backslash-n counts as a line break. Footer lines (subtotal, tax, card, item count, barcode,
    date) are skipped, not read as items.
  - **Test:** `test_receipt_whole_pasted_receipt_with_footer_and_literal_breaks`; mutation-checked: skipping the footer
    or splitting on literal breaks each fails it.

- **fix: household tool 0.3.4 says what to do next in its receipt messages (2026-11-12).**
  - **Why:** the 30B trial and the 8B both failed the same way on the 2026-11-12 receipt. "skip BOOK" matched no line and
    nothing said so. An unknown line said only "ask the user", not what to call next. A product name that matched
    nothing gave no way out but a retry.
  - **Change:** a skip word that matches no line is reported, with the item number as the fix. An unknown line says
    to ask which product or whether to skip it, and gives the two calls (`matches`, `skip`). A product name that is
    not found says to put the item number in `skip` if the user does not want that line.
  - **Test:** `test_receipt_messages_say_what_to_do_next`; mutation-checked: removing the skip-miss message or the
    skip hint each fails it.

- **fix: household tool 0.3.3 checks the user's OK itself, and counts skipped lines left out (2026-11-10).**
  - **Why:** the 0.3.2 re-run matched every known line, and applied both discounts correctly. But `qwen3-vl:8b`:
    - never added the book to `skip`, though the owner asked twice;
    - called `record_receipt` with `confirm=true` right after "skip the book" (nothing was written: the book was
      unknown);
    - misread the result, asking about a line that had matched.

    The count warning was also false: the chat named the game in `skip` but left its line out, so 12 lines were
    read of 13.
  - **Change:**
    - `record_receipt` and `undo_last_purchase` read the chat's last user message (Open WebUI's `__messages__`,
      hidden from the model). They write only when that message is an OK that asks for nothing else, so "Yes, but
      skip the milk" writes nothing. Called outside a chat, they behave as before.
    - A skip naming an item number that is not among the lines counts as a line read.
    - The count warning is calmer: "ask the user whether a line is missing".
    - The prompt says skips go in `skip` with their item numbers, including ones the user names later.
  - **Tests:** 3 new; 48 OK. Mutation-checked six ways, each failing a test, restored byte-identical.
  - **Still a model problem:** a guard stops wrong writes; it cannot make the chat follow "skip the book". The model
    question is back with the owner (the 2026-11-09 plan: reconsider if 0.3 still fails).
- **feat: `openwebui_push.py` pushes the household tool and prompt into Open WebUI (2026-11-10).**
  - **Why:** the owner pasted the tool by hand three times in one evening (0.3.0, 0.3.1, 0.3.2) and asked for the
    agent to do it.
  - **What:** `server/household/openwebui_push.py` compares the tool's code and the Household model's system prompt
    with the repo's files. It writes only with `--apply`, and only what differs, through Open WebUI's API. It keeps
    the tool's Valves and every other model setting, and it fails if the base model changed. The API key is the
    owner's, in a 600 file, and it is never printed.
  - **Tests:** `tests/test_openwebui_push.py`, 7 tests against a fake Open WebUI, added to CI. Mutation-checked: dropping
    access from the update, the base-model check, the up-to-date check or the dry run each makes a test fail.
  - **Runbook:** `docs/household/phase2-chat.md` → "Updating the tool and prompt", with the one-time key step.

- **fix: household tool 0.3.1 reads a tax flag touching the price, as in `2.50-A` (2026-11-10).**
  - **Why:** the first live 0.3.0 receipt run stopped at a discount line. Costco prints the tax letter straight after
    the price's minus sign, and 0.3.0 dropped a tax letter only when it stood apart. The chat then offered to skip
    the line, which would have lost the discount; the owner did not accept.
  - **Change:** the price pattern allows one letter touching the price. The unreadable-line error now tells the chat
    not to skip or change the line itself but to ask the user.
  - **Test:** `test_receipt_tax_flag_touching_the_price` (item and discount lines, both kinds of minus sign);
    mutation-checked: with 0.3.0's pattern it fails, and the restored file is byte-identical.
  - **0.3.2, same day:** the re-run with 0.3.1 stopped at the next discount line. The chat had read `/1234567` (made-up number) as
    `/ 234567`, losing a digit. A discount whose named number matches no item above now goes to the one item above
    whose number ends with it, if exactly one does and the named number has at least 5 digits; otherwise it is still
    an error. The preview shows which item took the discount. Test `test_receipt_discount_with_a_lost_leading_digit`,
    mutation-checked three ways (no fallback, no uniqueness rule, no length floor): each fails it.

- **feat: household tool 0.3.0, receipt bookkeeping in code, purchase history and undo (2026-11-09).**
  - **Why:** the first live receipt was recorded correctly only after the owner corrected the chat 4 times:
    - discount lines listed as items;
    - a skipped line kept;
    - a discount on the wrong line;
    - item numbers not saved.

    A second chat answered "when did I last buy X" from the product's usual store, and "corrected" a purchase by
    recording a new one with an invented date. The reading was right every time; the bookkeeping was not.
  - **`record_receipt`:** the model copies the lines as printed, and the code does the rest. It:
    - matches the item numbers saved for the store;
    - applies each discount to the item it names, or to the line above;
    - drops skipped lines with their discounts;
    - reads `MM/DD/YYYY`;
    - totals the lines and compares them with "Items Sold".

    Without `confirm` it writes nothing. With it, it refuses while a line is unknown, records each line, and saves
    the newly matched item numbers. A second OK writes nothing twice.
  - **Corrections and questions:**
    - `last_purchases` reads the stock log;
    - `undo_last_purchase` shows the purchase first and undoes it only with `confirm`;
    - a purchase date in the future or more than 60 days back is refused;
    - plurals fall back to the singular.
  - **Prompt:** the receipt rule now says "copy, call, show unchanged, confirm after OK".
  - **Tests:** 43, up from 28, all synthetic. Each of the 15 new rules was mutation-checked and goes red with it
    disabled. An offline replay of the real receipt, kept outside the repo, gave the reference's 11 products and
    prices exactly.

- **fix: the Grocy tool's examples use made-up item numbers (2026-11-09; tool 0.2.1).** The docstrings of 0.2.0
  used two real item numbers from the owner's receipt as examples. They are now 1234567 and 7654321, so no household
  data is in the tree. Only the text changed; the 28 tests pass unchanged. #229 was merged with a merge commit, so its
  first commit's receipt figures (the subtotal, the tax and one item number) stay in `main`'s history. Removing them
  would need a force-push to `main`, and that is the owner's call.

- **feat: household receipts, so a photo becomes dated purchases (2026-11-09, the owner's first feature wish).**
  - **The vision seat:** `qwen3-vl:8b` (Qwen's own Qwen3-VL-8B GGUF plus its vision projector, sha256-pinned) in
    `server/llamacpp/models.ini`. It is the new seat source `import-server`, a GGUF only the server serves.
    `llamacpp_check.py` and `check_config_drift.py` accept it, with tests and mutation checks for both.
  - **The tool, 0.2.0:**
    - `find_by_receipt_code` and `save_receipt_code`: item numbers are stored as Grocy barcodes, tied to the store;
    - `record_purchase` takes the total paid, the location and the purchase date.
  - **The prompt:** for a receipt, show one list (matches, quantities, prices, lines read against "Items Sold", the date)
    and write nothing before OK.
  - **Gate, on the owner's real receipt (4 reads per photo):**
    - the tool-call probe passes;
    - an upright photo gives 11 to 13 of 13 lines, with every price found right;
    - a sideways photo gives 10 to 11;
    - the date is misread every time, so the confirmation list carries it.
  - **Checked live on a throwaway Grocy:** a past `purchased_date` is kept, the price is stored per unit, and codes
    are per store.

- **feat: household phase 2 started, a basic chat over Grocy (2026-11-08, the owner's choice, ahead of phase 1's month).**
  - **The chat:** Open WebUI goes in the `household` compose project, on `server:3000`, LAN only. The tag is pinned,
    `WEBUI_SECRET_KEY` is required, and Valve encryption is on. It uses the llama-server router's models; no GPU of its own.
  - **The tool:** `server/household/openwebui_grocy_tool.py`, with eight tools (find, shopping list, add, remove,
    purchase, stock, chores due, complete chore).
    - An ambiguous or unknown name comes back as a question. A purchase is dated by Grocy, tied to a store, and leaves
      the list alone. The API key is redacted from every result.
  - **The prompt:** `openwebui-household-prompt.md`, five lines.
  - **Tests:** `tests/test_openwebui_grocy_tool.py` (20 tests against a fake Grocy, in CI). Mutation-checked: an
    ambiguous name picking the first match, no store filter, no key redaction, no best-before date.
  - **Checked against a throwaway real Grocy 4.7.1.** That run caught that purchases took a best-before date of today,
    so every product would show as expired the next day. Purchases now send Grocy's "never overdue" date.
  - **Runbook:** `docs/household/phase2-chat.md`.

- **docs: household phase 1, step 1 done on the server, and the runbook corrected from a live test (2026-11-08).**
  - **Installed:** Grocy `v4.7.1-ls348` on `server:9283`, with its database set up, the nightly backup cron line, and one
    backup pulled to the desktop.
  - **Verified first on a throwaway Grocy with made-up data:** the importer (26 writes, then 0 on a re-run),
    `period_interval` and the due dates it gives, `backup.sh`, the restore test, and the desktop pull.
  - **Runbook fixes:**
    - a new install's first login can fail with HTTP 500 until `/` is opened;
    - `ufw` does not filter Docker's ports, so no firewall step is needed (and none protects it);
    - the cron log folder must exist first, or the backup never runs;
    - the desktop task's path was `$HOME\HomeLab`, which does not exist on the owner's desktop;
    - an `adaptive` chore with one completion starts overdue.

- **feat: household assistant phase 1, the tracker (2026-11-08, owner's go).** Grocy on the server as the household's
  system of record. Chosen after checking its source: chores with yearly and adaptive periods, products with a store and
  minimum stock, dated purchases, and a public iCal link the phones subscribe to.
  - `server/docker/docker-compose.household.yml`: its own `household` project, a tag that must be pinned, LAN port
    9283, 0.5 CPU and 512 MB.
  - `server/household/grocy_import.py`: loads chores and products from CSVs kept outside the repo. Dry run by default;
    matches on name, so it can be re-run.
  - `tests/test_grocy_import.py`: runs against a fake Grocy, mutation-checked, and in CI.
  - Backups: `server/household/backup.sh` (nightly, keeps 14) and `desktop/scripts/pull-household-backup.ps1`.
  - The runbook, `docs/household/phase1.md`.
  - Not yet installed on the server.

- **docs: household assistant, phase 0 findings and an appointments area (2026-11-08, owner's request).** What the family's
  real exports taught, with none of the data committed: exports carry plans, not completions, so the tracker dates every
  completion and purchase; repeats come out as copies; shopping is one catalogue across stores with a glossary; the pantry
  leans toward Grocy, unverified. New requirement: doctor's appointments per family member, as a separate health area that
  never goes to a cloud model. The calendar: the family keeps its app; the assistant reads one feed per adult and publishes its own calendar that the
  phones subscribe to, which the app shows (tested by the owner); a CalDAV server stays the option for two-way editing. An entry's owner comes from whose feed it is in, or from ink
  colour on paper. The blank inventory
  template is now `docs/household/phase0-inventory.md`, and `.gitignore` keeps `*-filled.md` copies out.

- **docs: a plan for a household assistant (2026-11-07, owner's request).** `docs/household-assistant.md`: a private,
  self-hosted chat assistant for running the house (decision help, recurring upkeep, big tasks ahead, "when did we last
  do X"). The design keeps dates and history in a tracker (Donetick/Homebox or Grocy), with chat agents over it
  (Open WebUI on a fleet seat) and retrieval rather than fine-tuning. A proof of concept on the existing fleet comes
  first; purchase criteria are written down for its numbers to decide. Nothing installed. Sources in `docs/references.md`
  → "Household assistant".
