# Household assistant: the Health agent (runbook)

**Health** is the household's appointments helper, the first area agent of
[household-assistant.md](../household-assistant.md) (requirement: track, manage and help schedule each family
member's appointments). Planned with the owner on 2026-11-17 to 19, in five approved chunks. It is a separate chat in
Open WebUI ("Health" in the model menu), next to the house agent of [phase2-chat.md](phase2-chat.md), and built the
same way: one tool, one short prompt, one local model.

It answers four things and records two:
- **What is due to book:** the "Book: <person> <kind>" chores in Grocy that are due or overdue, with the provider and
  how to book (phone or portal).
- **What is coming up:** booked appointments, from each adult's private family-calendar feed.
- **When someone was last seen** for a kind of appointment: the chore's last tracked date.
- **Whether a day is free:** both feeds on that date.
- **Records, only after the user's plain OK:** a visit (completes the "Book:" chore on the visit's date), and a new
  appointment kind.

**It never books.** It says how to book and offers to check the day first. **It gives no medical advice.**

## The pieces

| Piece | File | Notes |
|---|---|---|
| Tool | [`server/household/openwebui_health_tool.py`](../../server/household/openwebui_health_tool.py) | Six tools: `appointments_due`, `upcoming`, `last_visit`, `check_clash`, `log_visit`, `add_kind`. Its own file, so the house agent never sees health |
| Prompt | [`server/household/openwebui-health-prompt.md`](../../server/household/openwebui-health-prompt.md) | Appointments only; never guess; ask before writing; never book |
| Install | [`server/household/openwebui_push.py`](../../server/household/openwebui_push.py) `--agent health` | Updates the tool's code and the model's prompt; **refuses a base model the server's llama-server does not serve** |
| Import | [`server/household/grocy_import.py`](../../server/household/grocy_import.py) with `appointment_kinds.csv` | Creates the Grocy list Health reads |
| Tests | `tests/test_openwebui_health_tool.py`, `tests/test_openwebui_push.py`, `tests/test_grocy_import.py` | A fake Grocy and fake calendar feeds; run in CI |

## Where the data lives

| What | Where |
|---|---|
| How often each kind repeats, and "time to book" | A Grocy chore **"Book: <person> <kind>"** (yearly, monthly ×N or adaptive), as in phase 1. Its tracked executions are the visits |
| One record per person and kind: provider, how to book, visit notes (fasting, arrive early), and the **calendar words** that pick its events out of a feed (e.g. `dentist, dental`) | A Grocy **user entity** `appointment_kinds` with six user fields: `person`, `kind`, `provider`, `how_to_book`, `notes`, `match_words`. With no calendar words, the kind's own name is used |
| Booked and past appointments | Each adult's private family-calendar feed, **read only**. The two feed links are encrypted Valves in Open WebUI, never in the repo or a chat |

How the user entity works was read in Grocy's source on 2026-11-19: the tables
([`migrations/0085.sql`](https://github.com/grocy/grocy/blob/master/migrations/0085.sql)); the entity
`userentity-<name>`, the field types and reading and writing values
([`services/UserfieldsService.php`](https://github.com/grocy/grocy/blob/master/services/UserfieldsService.php));
`created_object_id` from `POST /objects/...`
([`GenericEntityApiController.php`](https://github.com/grocy/grocy/blob/master/controllers/Api/GenericEntityApiController.php));
names of letters, digits and `_`
([`views/userfieldform.blade.php`](https://github.com/grocy/grocy/blob/master/views/userfieldform.blade.php)); and the
`Userfield` schema and the exposed entities `userentities`, `userfields`, `userobjects`
([`grocy.openapi.json`](https://github.com/grocy/grocy/blob/master/grocy.openapi.json)).

**A "Book:" chore and its record go together.** `log_visit` and `last_visit` need both; `appointments_due` lists a due
chore even without a record (with no provider shown). The chore's name must be exactly `Book: <person> <kind>` with
the record's person and kind (case does not matter).

## Privacy and safety (what is enforced, and where)

- **Never a cloud model.** `openwebui_push.py --agent health` reads the base model of the `health` workspace model and
  refuses, before writing anything, unless the server's llama-server (`--engine-url`, default
  `http://localhost:8090`, its `/v1/models`) serves it. It sends the fleet key from `~/.config/llamacpp/api-key` when
  that file exists ([engine-api-keys.md](../engine-api-keys.md)). It checks again after writing.
- **Only appointments leave the feeds.** `upcoming` returns only events whose title matches one of that feed
  person's kinds (whole words). `check_clash` names a matched event as "<kind> appointment" and shows every other
  event as **"busy"**, with its time and no title. Nothing else in the calendar reaches the model.
- **Nothing is written without the user's OK.** `log_visit` and `add_kind` return a preview first. A write happens only
  with `confirm=true` **and** the last user message approving with nothing else asked (the same check as the house
  tool's receipts). A visit dated in the future is refused.
- **Secrets never appear in an answer.** A feed that fails is named by its person, never its link; the Grocy key and
  the feed links are replaced by `[secret]` in any error.
- **Both adults see everything** (owner, 2026-11-08): the Health model is shared with both accounts.
- **No household data in the repo.** The CSV lives in `~/household-data/` on the server, as phase 1's do.

## Setting it up (the owner's steps)

1. **Pull the change on the server.** `cd ~/HomeLab && git pull`.
2. **The appointment list.** Put `appointment_kinds.csv` in `~/household-data/` with the header
   `person,kind,provider,how_to_book,notes,match_words`, one row per person and kind. Add any missing
   `Book: <person> <kind>` rows to `chores.csv`. Then:
   ```bash
   python3 -I server/household/grocy_import.py --url http://localhost:9283            # dry run: read the plan
   python3 -I server/household/grocy_import.py --url http://localhost:9283 --apply    # writes
   python3 -I server/household/grocy_import.py --url http://localhost:9283 --apply    # again: "writes: 0"
   ```
   Grocy's sidebar now has "Appointment kinds"; rows can also be edited there.
3. **The tool and the model in Open WebUI** (once, as admin):
   - **Workspace → Tools → New:** id `health_appointments`, name "Health". Paste the tool file's contents, save.
   - **Workspace → Models → New:** id `health`, name "Health". **Base model: a local llama-server model** (today
     `qwen3-vl:8b`, the house agent's). Tools: only "Health". Share it with both accounts.
   - From then on, after every `git pull`:
     ```bash
     python3 -I server/household/openwebui_push.py --agent health            # dry run
     python3 -I server/household/openwebui_push.py --agent health --apply
     ```
     The first line it prints must be `model health: base model <id> is local`.
4. **Valves** (Workspace → Tools → Health → Valves; stored encrypted, `ENABLE_VALVE_ENCRYPTION=true`):
   - `api_key`: the Grocy API key (the same as the house tool's, or a separate one).
   - `feed_1_person` / `feed_1_url`, `feed_2_person` / `feed_2_url`: each adult's name as written in the "Book:"
     chores, and their private feed link. Paste the links only here, never in a chat.
   - `time_zone`: the household's zone (e.g. `America/Chicago`), for feed times given in UTC. Empty means the
     server's zone, which inside a container is often UTC.
5. **The live check: ask it the four questions** (what's due to book; what's coming up; when was <person> last seen
   for <kind>; is <date> free) and record the result under "Status" below. **Pass:** "due to book" matches Grocy,
   "coming up" matches the calendar, and **no event that is not an appointment appears in any answer** (other events
   appear only as "busy").

## Later

- **The baby.** After the birth: a person's rows and "Book: <name> well visit" chores, with the visit schedule taken
  from a pediatric source (e.g. the American Academy of Pediatrics' periodicity schedule), fetched and cited then, not
  guessed now.
- **Its own calendar.** Appointments come due in the phones' calendar through Grocy's iCal link already (phase 1). A
  separate Health calendar is not planned.

## Status

- **2026-11-19:** built and tested in the repo (PR #246). Steps 1 to 5 are the owner's, not yet done.
