# Handoff prompt — server recovery (paste into a new agent)

> Save this verbatim and open a fresh session with it when you pick the work back up.
> Read `docs/server-recovery-cpu-led.md` first — it is the source of truth for this incident
> and is updated as the situation changes.

---

You're taking over an active hardware recovery for the dev server at SERVER_IP
(MSI MAG B550 Tomahawk, Ryzen 7 3700X, RTX 4070 Ti Super 16GB, Corsair Vengeance LPX
2x16GB, NEW PSU from Sep 2026 swap). Read M:\Projects\dev-docs\docs\server-recovery-cpu-led.md
FIRST — it has the full timeline, every attempt with results, and the reasoning. Also read
AGENTS.md for the repo/scripts context.

Also read, for context: M:\Projects\dev-docs\docs\troubleshooting.md (Server Issues),
M:\Projects\dev-docs\docs\hardware.md.

CURRENT STATE (as of 2026-09-16):
- Server won't POST after the user set PBO->Auto in BIOS and saved. Onboard EZ Debug CPU LED
  is solid red immediately, always, even with ZERO RAM installed (should be DRAM LED if CPU
  passed init -> firmware halts before memory init).
- CMOS clear via JBAT1 + battery pull: no change.
- USB BIOS flashback (MSI Flash BIOS Button, grey-outlined port): 2GB control stick never
  left read phase (infinite blink). Second stick (7.65GB USB2.0) DID enter the write phase
  (cadence doubled, board powered on) but HUNG ~13min — way past the 4-7min window. MSI.ROM
  file verified valid (33554432 bytes, _PT_ AMI header, clean MBR/FAT32).
- The MSI.ROM file and that second stick have been validated. The last unproven variable is
  sustained power during the write. PSU swap deprioritised 2026-09-17 - test it by REMOVING LOAD (pull the GPU) instead.
- Hardware config right now: NEW PSU installed, RAM REMOVED (from the zero-RAM probe), GPU
  installed. CPU+cooler in. PSU is a Corsair RM850e (resolved).
- SSH to YOUR_USER@SERVER_IP is NOT usable yet (no key auth; needs password).

YOUR MISSION: drive the recovery to completion, in this order. You may interact with the user
for physical steps (they're hands-on at the machine) — report the machine's POST/flash state
verbatim and adjust.
NOTE (2026-09-17): the user has DEPRIORITISED the PSU swap. The revised order below
tests the same "sustained power during the write" hypothesis by REMOVING LOAD instead
of changing the supply. Do not lead with a PSU swap.

1. Ensure any blinking flashback run is aborted (PSU off) before new attempts.
2. Have the user reflash on a TRULY BARE board — GPU REMOVED this time. RAM is already
   out; also pull the 4070 Ti Super and unplug non-essential drives/fans, leaving CPU +
   PSU only. This is MSI's intended flashback state and drops the 12V load a lot without
   touching the PSU. Same validated second stick, 3s press, hands off. Watch: blink
   starts -> cadence should DOUBLE within ~30s (write) -> LED out after 4-6min -> board
   cycles itself. Abort at ~60s if cadence never doubles; abort if write phase outlasts
   ~7min.
3. If it hangs again: try a DIFFERENT BIOS VERSION (older AGESA from MSI's B550 Tomahawk
   support page) renamed to MSI.ROM on the same stick. The ROM *version* has never been
   varied — only its integrity was checked (32,554,432 bytes, _PT_ AMI header).
4. If it hangs again: a THIRD USB stick if available (<=8GB, USB 2.0, DiskPart clean ->
   MBR -> FAT32).
5. CPU reseat w/ socket-pin inspection (CPU was never touched, so low odds, but it is
   non-destructive and it is the last thing before RMA).
6. Old-PSU swap ONLY as the final diagnostic before RMA, and only if the user wants it.
   Otherwise go straight to board RMA — do NOT propose more flashing after two identical
   write-hangs.
7. ON SUCCESS: walk the user through this checklist (do whatever of it you can from your side):
   - Reinstall both RAM sticks in A2/B2, boot, confirm the LED marches CPU->DRAM->VGA->BOOT.
     That march is the proof firmware was the trap.
   - Enable A-XMP at 3200 ONLY (kit is CMK32GX4M2...3200C16 — 3600 is NOT guaranteed; do not
     push it), leave PBO at Auto, validate RAM (memtest86/OCCT loop) before trusting it.
   - Confirm network + Ollama from your side: ping SERVER_IP, `curl :11434/api/version`,
     `/api/tags` (expect qwen2.5-coder:7b/14b, deepseek-r1:14b, qwen3:8b).
   - Fix systemd-networkd-wait-online so reboots don't stall ~10min (needs SSH/console).
   - Stage SSH key auth for YOUR_USER@SERVER_IP (key: C:\Users\<username>\.ssh\dev-docs,
     pubkey exists; user must authorize once w/ password). Then run sync-opencode.ps1 -Template
     and sync-skills.ps1 -Server, plus server/scripts/status.sh to verify GPU + models.
8. Update docs/server-recovery-cpu-led.md as the situation changes (mark checklist items done,
   append new attempts/results, record PSU model).

Be the coordinator + remote verifier; the user physically handles the board. Do not re-ask the
PSU model - it is a Corsair RM850e. Keep asking "what does the board tell you" rather than assuming
the last run's state.