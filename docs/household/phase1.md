# Household assistant, phase 1: the tracker (runbook)

Phase 1 of [household-assistant.md](../household-assistant.md), planned 2026-11-08. It puts **Grocy** on `server` as the
household's system of record: house tasks, "time to book" reminders for appointments, and the shopping catalogue, each
completion and purchase **dated**. Then the family lives with it for about a month. There is no chat and no AI yet.

**Owner's choices (2026-11-08):**
- **Phones:** home Wi-Fi only, with no VPN yet.
- **Backups:** nightly, with the off-server copy on the desktop.
- **Hardware:** existing machines only.
- **Calendar:** the family's calendar app stays; Grocy's calendar is subscribed on each iPhone.

**No household data goes in this repo.** The seed files live on the server in `~/household-data/`; the API key and the
calendar link live only on the server and the phones.

## Status and handoff (2026-11-08)

Written for whichever agent picks this up next: likely the one on the owner's desktop, since the cloud session that
wrote this cannot reach the LAN.

**Done (in the repo):**
- `server/docker/docker-compose.household.yml`: the Grocy service.
- `server/household/grocy_import.py` and `tests/test_grocy_import.py`. The tests run in CI and were mutation-checked.
- `server/household/backup.sh` and `desktop/scripts/pull-household-backup.ps1`.
- This runbook.

**Not yet verified:**
- **The importer has run only against a fake Grocy:** the cloud session had no Docker daemon. Its first real run is
  the dry run in step 3, so read that output carefully.
- **The `period_interval` field.** It is not in Grocy's OpenAPI spec, though the schedule view uses it. If the API
  rejects it on `--apply`, report the error; do not drop the field silently.

**Next, in order:**
1. Pull `main` on the server (`~/HomeLab`).
2. Step 1: pin `GROCY_TAG` in `server/docker/.env`, then `compose up`. Record the version under "Installed version".
3. Step 2 is the **owner's**: users, password, API key file, calendar link.
4. Step 3: the owner copies `chores.csv` and `products.csv` to `~/household-data/`.
   - Run the dry run and show the owner the summary.
   - Run `--apply` only on the owner's go.
   - A second `--apply` must report `writes: 0`.
5. Phones, as in "On the phones".
6. Step 4: the cron line, then the desktop pull task (the owner registers it), then the restore test.
7. Start the month (step 5), and record what happened at the bottom of this file.

**Rules for this work:**
- **No household data in the repo, a commit message, a PR or a log you paste.** That means names, list contents,
  health details, the API key, and the calendar link.
- **The seed CSVs come from the owner,** who has them from the phase 0 session, and they live only in
  `~/household-data/`.
- **The design and its decisions** are in [household-assistant.md](../household-assistant.md).

## Why Grocy (verified from its source, 2026-11-08)

Read from [Grocy's OpenAPI spec](https://github.com/grocy/grocy/blob/master/grocy.openapi.json) and its
[chores service](https://github.com/grocy/grocy/blob/master/services/ChoresService.php) and
[chores schedule view](https://github.com/grocy/grocy/blob/master/migrations/0185.sql) on GitHub. grocy.info itself
did not resolve from the session.

- **Chores:**
  - **Periods:** manually, hourly, daily, weekly, monthly, yearly, and **adaptive**. Adaptive spaces the next due date
    by the average gap between past completions.
  - **Repeat interval:** each period takes one (e.g. monthly every 3 = quarterly).
  - **Assignment:** none, who-did-it-least, random, alphabetical.
  - **Recording:** each completion is stored with its date.
- **Stock:**
  - **Products:** each has a minimum stock and a store ("shopping location").
  - **Stock entries:** each carries a purchase date.
  - **Shopping list:** has "add missing products" (below minimum).
- **Calendar:** a **public iCal sharing link**. This is the assistant's calendar on the phones. A subscribed calendar
  shows inside the family's calendar app; the owner tested this on 2026-11-08.
- **Also:** batteries, equipment, and users with permissions.

Donetick and Homebox are no longer needed.

## On the phones: browser, plus an optional app

- **Grocy is a web app.** On each iPhone, open `http://<server>:9283` in Safari, then Share → **Add to Home Screen**. It
  opens like an app. Chores (the house tasks and "Book:" reminders) are ticked off here.
- **Grocy Mobile** (search the App Store for it; its listing could not be fetched from the session) is a free
  third-party iPhone app for a self-hosted Grocy. Per its listing and reviews (not re-verified, 2026-11-08), it covers stock, barcode
  scanning and **shopping lists**, but **not chores**. It's worth trying for the in-store list, and it isn't needed.
- **Neither works away from home** until a VPN exists (owner, 2026-11-08: home Wi-Fi only for now).

## 1. Install (server)

The agent can do everything here except the steps marked **owner**. Only the docker group is needed: no sudo.

1. Pick the image tag:
   - The newest on 2026-11-08 was `v4.7.1-ls348` (Grocy 4.7.1); re-check before installing.
   - Take the newest release tag from the
     [linuxserver/grocy releases](https://github.com/linuxserver/docker-grocy/releases) (x86-64).
   - Put it in `~/HomeLab/server/docker/.env` as `GROCY_TAG=<tag>`. That file is git-ignored.
   - Record it under **Installed version** below.
2. Start it, in its own compose project. Don't use the model stack's `docker` project.
   ```bash
   cd ~/HomeLab && docker compose -p household -f server/docker/docker-compose.household.yml up -d
   docker compose -p household -f server/docker/docker-compose.household.yml ps
   ```
3. **Owner:** if the server's firewall is on, allow TCP 9283 from the LAN (sudo).
4. Check it from the desktop: open `http://<server>:9283`. The default login is `admin` / `admin`: **change it at once.**

**Installed version:** *(tag, date, by whom)*

## 2. First-run setup (owner, in the Grocy web UI)

1. **Users:** one per adult. Both see everything, as decided 2026-11-08. Rename or retire `admin`.
2. **API key:**
   - Create one in Grocy (Manage API keys) for the import and, later, the assistant.
   - Save it on the server **only**, in `~/.config/household/grocy-api-key` with `chmod 600`.
   - Never paste it into chat, a commit or a ticket.
3. **Calendar link:**
   - Get it from Grocy's calendar page (share / iCal link).
   - On each iPhone, add it under **Settings → Apps → Calendar → Calendar Accounts → Add Account → Other → Add
     Subscribed Calendar** (older iOS: Settings → Calendar → Accounts).
   - **Do not** use the family calendar app's "share local calendars with family" on it: that copies it to the
     vendor's servers.
   - The link is a secret: anyone with it can read the calendar.

## 3. Import the seed lists

The seed files are two CSVs, in `~/household-data/` on the server. The owner copies them there from the phase 0
session.

| File | Columns |
|---|---|
| `chores.csv` | `name, cadence, last_done, assignee, description` |
| `products.csv` | `name, stores, location, description` |

**Columns:**
- **`cadence`:** weekly, every N weeks, monthly, quarterly, every N months, yearly, every N years, adaptive, or manual.
- **`last_done`:** YYYY-MM-DD, or empty. It becomes the first tracked completion, so "next due" starts right.
- **`assignee`:** a Grocy username, `rotate`, or empty.
- **`stores`:** `Store A + Store B` style. The first is the product's store; the rest go in its description.

**Appointments** go in `chores.csv` as **"Book: <person> <kind>"**, with the visit's usual gap as the cadence and the
last visit as `last_done`. Only the kind and the person: no medical detail in Grocy. The appointment itself stays in
the family calendar.

```bash
cd ~/HomeLab
python3 -I server/household/grocy_import.py                 # dry run: prints what it would create, writes nothing
python3 -I server/household/grocy_import.py --apply         # after the owner reads the dry run and says go
python3 -I server/household/grocy_import.py --apply         # again: must report "writes: 0" (matched by name)
```

**What `--apply` creates:**
- **Products:** a "Piece" quantity unit, the stores, a "Pantry" location (plus any named one), and the products. No
  minimum stock: learn it during the month.
- **Chores:** the chores, with their periods. Weekly follows the weekday of `last_done`; monthly follows its day of the
  month, capped at 28. Each chore gets its `last_done` as a tracked completion.

## 4. Backups

- **On the server**, nightly at 03:15, from `crontab -e` as the server user (no sudo):
  ```
  15 3 * * * $HOME/HomeLab/server/household/backup.sh >> $HOME/backups/household/backup.log 2>&1
  ```
  - **What it does:** pauses the container for a few seconds, tars the `household_grocy_config` volume to
    `~/backups/household/`, checks the archive lists, and keeps 14.
- **On the desktop:** `desktop/scripts/pull-household-backup.ps1` copies the newest one to
  `%USERPROFILE%\Backups\household` and keeps 30. Run it once by hand, then schedule it nightly. The schedule is the
  **owner's** step, from a pwsh prompt:
  ```powershell
  $a = New-ScheduledTaskAction -Execute (Get-Process -Id $PID).Path -Argument "-NoProfile -File `"$HOME\HomeLab\desktop\scripts\pull-household-backup.ps1`""
  Register-ScheduledTask -TaskName 'HomeLab household backup pull' -Action $a -Trigger (New-ScheduledTaskTrigger -Daily -At 7am)
  ```
- **Restore test (do it once in week 1).** A backup is only proven when it restores.
  ```bash
  docker volume create grocy_restore_test
  docker run --rm -v grocy_restore_test:/data -v ~/backups/household:/b alpine:3.20 tar -xzf /b/<newest>.tar.gz -C /data
  docker run --rm -d --name grocy-restore-test -p 9284:80 -v grocy_restore_test:/config lscr.io/linuxserver/grocy:<GROCY_TAG>
  ```
  1. Open `http://<server>:9284` and check that the chores and their last-done dates are there.
  2. Then clean up: `docker rm -f grocy-restore-test && docker volume rm grocy_restore_test`.

## 5. The month: what "done" means

Check these against the phase 0 questions, about a month in:

- **"When did we last…?"** is answered from Grocy with real dates, for the house tasks and the "Book:" reminders.
- **Due tasks show in the family calendar** through the subscribed Grocy calendar. **Week 1 test:** does the iPhone
  alert on a subscribed calendar's events? If not, phase 2 adds push notifications (e.g. a self-hosted ntfy).
- **"What do we need at <store>?"** works from Grocy's list for one store, with purchase dates building up.
- **One restore** of a nightly backup has been done.
- **No measurable slowdown of the model seats** from the tracker: `docker stats household-grocy` during a run. Its
  limits are 0.5 CPU and 512 MB.

Record what happened at the bottom of this file, dated, before planning phase 2 (chat over the tracker).
