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

**Verified on the server (2026-11-08, desktop session).** The test used a throwaway Grocy `v4.7.1-ls348`, bound to
localhost, with made-up data; it was removed after.
- **Importer:**
  - the dry run wrote nothing;
  - `--apply` made 26 writes for 10 chores and 3 products;
  - a second `--apply` made 0.
- **`period_interval`:** Grocy accepts it, and the next due dates are right. Every 2 weeks from 10-30 is due 11-13;
  quarterly from 09-15 is due 12-15; every 2 years from 2025-01-10 is due 2027-01-10; the 31st becomes the 28th.
- **Backups:** `backup.sh` keeps the newest `KEEP` copies and leaves the container running. The restore test, as
  written below, brought back every chore and tracked completion.
- **The desktop pull:** `pull-household-backup.ps1` copies the newest backup, skips one it already has, and exits 1
  when there is none.
- **Load:** Grocy idles at about 40 MB of its 512 MB.

**Done on the server (2026-11-08):**
- **Step 1, the install.** See "Installed version".
- **Step 2, in part (owner):** the admin password was changed (the default login is refused), and the API key file is
  in place (mode 600; the key check returns 200).
- **Step 3, the import.**
  - **The seed CSVs** were rebuilt with the owner from the phase 0 session's files. They are kept in
    `~/household-data/` on the server, with a working copy on the desktop outside the repo.
  - **Result:** the dry run was approved, then `--apply` made 142 writes and a second `--apply` made 0. Grocy now holds
    111 products (56 for any store), 3 stores, 8 locations and 12 chores, 9 of them with a tracked last completion. A
    backup was taken just before.
  - **Owner's exception:** the owner allowed the cloud model (Claude) to see this initial import, its appointment
    reminders included. From here on, the rule in household-assistant.md applies as written: health entries are never
    sent to a cloud model.
  - **Store convention:** a blank store means "any store" (the description starts "Any store"); a named store means
    that store only.

**Next, in order:**
1. **The rest of step 2 (owner):** one user per adult, then the calendar link on each phone.
2. **Phones,** as in "On the phones".
3. **Step 4:** the desktop pull task (the owner registers it), then the restore test in week 1. The server's nightly
   cron line is in place (2026-11-08).
4. **Start the month (step 5),** and record what happened at the bottom of this file.

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
3. **Let it set up its database before anyone logs in.** On a new volume the first page request creates the
   database, and the login page alone does not. Seen twice on 2026-11-08: logging in on a new install gave HTTP 500
   ("no such table: migrations") until `/` had been opened again. So wait for the init line, then open `/` once:
   ```bash
   until docker logs household-grocy 2>&1 | grep -q 'init\] done'; do sleep 2; done
   curl -s -o /dev/null http://127.0.0.1:9283/ && docker exec household-grocy stat -c '%s bytes' /config/data/grocy.db
   ```
   A database of a few hundred KB is right (602,112 bytes on 4.7.1); 0 bytes means open `/` again.
4. **No firewall step is needed.** `ufw` is active on the server, but Docker publishes its ports through its own
   iptables rules, which `ufw` does not filter. The desktop reached 9283 with no rule added (2026-11-08). The
   other side of this: `ufw` does not protect the port either, so never forward it from the router.
5. Check it from the desktop: open `http://<server>:9283`. The default login is `admin` / `admin`: **change it at once.**

**Installed version:** `v4.7.1-ls348` (Grocy 4.7.1), 2026-11-08, by Claude Code on the owner's desktop at the
owner's go. The tag is in `~/HomeLab/server/docker/.env` (mode 600). Volume `household_grocy_config`; the limits of
0.5 CPU and 512 MB are in force.

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
  - **`adaptive` with one `last_done`:** it is due on that same date, so it starts overdue. Grocy spaces adaptive chores by
    the average gap between completions, and one completion has no gap (seen on 4.7.1, 2026-11-08). Give such a chore a
    fixed cadence for the first month, or accept that it starts overdue.
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

- **On the server**, nightly at 03:15, from `crontab -e` as the server user (no sudo). **Make the folder first:**
  cron opens the log before the script runs, so with no `~/backups/household/` the redirect fails and the backup never
  starts. Installed 2026-11-08; the line below is the one in the crontab.
  ```
  mkdir -p ~/backups/household
  15 3 * * * $HOME/HomeLab/server/household/backup.sh >> $HOME/backups/household/backup.log 2>&1
  ```
  - **What it does:** pauses the container for a few seconds, tars the `household_grocy_config` volume to
    `~/backups/household/`, checks the archive lists, and keeps 14.
- **On the desktop:** `desktop/scripts/pull-household-backup.ps1` copies the newest one to
  `%USERPROFILE%\Backups\household` and keeps 30. Run it once by hand, then schedule it nightly. The schedule is the
  **owner's** step, from a pwsh prompt. Set `$repo` to this repo's checkout on the desktop: `M:\Projects\dev-docs`
  on the owner's desktop, not `$HOME\HomeLab`. With the wrong path the task fails every night without a word.
  ```powershell
  $repo = 'M:\Projects\dev-docs'
  $a = New-ScheduledTaskAction -Execute (Get-Process -Id $PID).Path -Argument "-NoProfile -File `"$repo\desktop\scripts\pull-household-backup.ps1`""
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
