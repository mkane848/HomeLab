# After a power cut

What to check, in order, when the house loses power. Written 2026-11-28, after the outage of 2026-11-27. Each step
says what should have come back by itself and how to confirm it. The facts come from the docs linked at each step,
as they stood that day. If something here turns out wrong on the night, fix this file.

## What comes back by itself

| Machine | Powers on by itself? | What starts at boot | Not restarted |
|---|---|---|---|
| server | **Yes** (the outage of 2026-11-27, owner). So "Restore after AC Power Loss" is no longer the default the repo last recorded on 2026-10-11 ([server-recovery-cpu-led.md](server-recovery-cpu-led.md)) | Docker, then `llamacpp-server` (`restart: unless-stopped`, or `llamacpp-server.service` if installed), then the household containers (`unless-stopped`) | the 03:15 backup, if the server was off then; a testing window's watchdog |
| node3 | **Yes** (2026-11-27, owner) | `HomeLab-llamacpp`, a scheduled task at startup (S4U, so nobody has to sign in; [node3/README.md](../node3/README.md)) | a detached window (a one-shot task: its time has passed) |
| desktop | **No** (2026-11-27, owner): press its power button | Nothing the fleet needs: it runs no models | the backup pull runs at the next logon if 07:00 was missed |

A container that was stopped by hand before the cut (the household chat during a testing window, say) stays stopped:
`unless-stopped` restarts only what was running.

## 1. The server

1. **It should be on already.** If it is not, press its power button, and check the BIOS setting at the next boot
   with a monitor: a cleared CMOS resets it (below). It booted in 43 s on 2026-10-11.
2. **From the desktop:** `ssh server`, then in the checkout:

   ```bash
   cd ~/HomeLab && ./server/scripts/status.sh
   ```

   It shows the unit, the container and its restart policy, the GPU on the host and **inside the container**, and the
   seats. What to look for:
   - `llama-server: UP` and the seats listed.
   - `In llamacpp-server: <GPU name>`. If it says `GPU NOT VISIBLE`, the engine is running on the CPU only and still
     answers. The fix it prints: `docker compose -f server/docker/docker-compose.llamacpp.yml up -d --force-recreate`
     ([troubleshooting.md](troubleshooting.md) → "Container lost the GPU").
   - `nvidia-smi not found`, or the host's `nvidia-smi` failing: the driver did not load. A power cut alone should not
     cause this. A cleared CMOS (battery out, or the board resetting it) wipes the enrolled Secure Boot key, and then
     the driver is refused: re-enroll `MOK.der` with a monitor and keyboard for one boot
     ([server-recovery-cpu-led.md](server-recovery-cpu-led.md) → "The CMOS clear also wiped the enrolled Secure Boot
     key"). It also resets "Restore after AC Power Loss".
3. **Nothing else failed:** `systemctl --failed` lists no units.
4. **The household:** `docker ps --filter name=household` shows `household-grocy` and `household-openwebui` up.
   Grocy is on port 9283 and the chat on 3000 ([household-assistant.md](household-assistant.md)).
5. **The model-ports firewall**, only if `model-ports-firewall.service` is installed (an open step in
   [plan.md](plan.md)): the unit runs after Docker, so the rules come back by themselves. `systemctl status
   model-ports-firewall` should say active ([network-topology.md](network-topology.md) → "Limit the model ports to
   named hosts").
6. **The backup:** if the server was off at 03:15, that night's backup did not run and is not made up. The next one
   is the following 03:15. Check `~/backups/household/backup.log` the morning after.

## 2. node3

From the desktop, with `-o BatchMode=yes` so nothing waits on a prompt. node3's ssh shell is cmd
([node3/README.md](../node3/README.md) → "Working on node3 over ssh"):

```powershell
ssh -o BatchMode=yes node3 "schtasks /query /tn HomeLab-llamacpp"
ssh -o BatchMode=yes node3 "curl.exe -s -m 5 http://127.0.0.1:8090/health"
```

- The task should be `Running`, and `/health` should answer. node3's llama-server listens on 127.0.0.1 until its LAN
  firewall rule, so check it from node3, as above.
- If node3 did not power on, start it. Someone may be gaming on it: a window against node3's GPU yields to games
  (`-YieldToGames`).

## 3. The desktop

Nothing the fleet needs runs here. The household backup pull (`HomeLab household backup pull`, daily at 07:00) runs
at the next logon if 07:00 was missed ([household/phase1.md](household/phase1.md)).

**The end-to-end check**, once the server and node3 answer: `tests\test-profiles.ps1` from the desktop. It checks each
live profile's hosts and registration.

## 4. Work that was running

- **A testing window on node3** (`run-window.ps1 -Detach`): a reboot ends it, with no resume
  ([unattended-window.md](unattended-window.md) → "What is verified"). Its output folder has `window.log` up to the
  cut, and no report.
  - The finished runs stay. A later window with `-FillTo` runs only what is missing: a run cut off has no graded row,
    so it counts as missing.
  - The one-shot task `HomeLab-window-<name>` does not run again.
  - The lock (`homelab-window.lock` in node3's temp folder) holds the old pid. A new window starts anyway unless
    another process now has that pid. If a new window is refused naming a pid that is not a window, delete the lock
    file.
- **The server half** (`llamacpp-window.sh up`): its watchdog died with the server. The engine came back by its
  restart policy, without the window's deadline. `bash server/scripts/llamacpp-window.sh status` says whether a
  window is open; `~/llamacpp-window/window.log` has the events up to the cut. A new `up` works: it refuses only while
  the old watchdog's pid is alive.
- **A batch or a planner run started by hand:** the run in progress is lost. The task worktrees are rebuilt on the
  next run (`tests/test-tasks.ps1` prunes and recreates them).
- **A file being written at the cut:** git checkouts and the Grocy database can be left half-written. `git status` in
  each checkout, and opening Grocy, show it.

## 5. Record it

Add a dated line to the CHANGELOG or the roadmap: when the power went, which machines came back by themselves, and
anything that needed a fix. "Powers on by itself?" in the table above is the line to update.

## Open: the owner's choice

- **The desktop's power-loss setting**, if it should come back by itself too. It runs no models, so nothing waits on it.
- **The server's exact setting is not written down.** It came back by itself on 2026-11-27, so it is no longer the
  default the 2026-10-11 note left. When there is a monitor on it, record the value in
  [server-recovery-cpu-led.md](server-recovery-cpu-led.md).
