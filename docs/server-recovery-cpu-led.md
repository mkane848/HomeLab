# Server Recovery — Solid CPU EZ Debug LED + Flashback hang

Status: **In progress**. Machine: server (`SERVER_IP`), MSI MAG B550 Tomahawk + Ryzen 7 3700X, RTX 4070 Ti Super 16 GB, Corsair Vengeance LPX 2×16 GB, new PSU: **Corsair RM850e** (swap batch Sep 2026). Last updated: 2026-09-16.

## What happened (timeline)

1. Server was healthy all day — served Ollama inference (models pulled + answering: `qwen2.5-coder:14b`, `deepseek-r1:14b`, `qwen3:8b` on top of `qwen2.5-coder:7b`), reachable on the LAN.
2. In BIOS the user changed **PBO → Auto**, saved & exited.
3. Immediately: black screen, no boot. On every subsequent power-on the onboard **CPU EZ Debug LED is solid red** immediately and never clears.
4. An attempt to recover by USB **Flash BIOS Button** produced an **infinite blink** (controller reading but never finishing).

## What we tried

| Step | Result |
|---|---|
| CMOS clear via JBAT1 short | No change — CPU LED still solid |
| CMOS battery pull (board dead, unplugged) | No change |
| Boot **with both RAM sticks** | Solid CPU LED immediately |
| Boot **with zero RAM** (diagnostic probe) | Still **solid CPU LED** — NOT DRAM LED |
| USB drive prep (DiskPart deep clean → MBR → FAT32, `MSI.ROM` at root, hidden extensions verified) | Drive + file verified clean on desktop |
| Flashback with 2 GB control stick | Infinite blink from the start (never left read phase) |
| Flashback with second stick (7.65 GB, USB 2.0) | Read → **entered write phase** (cadence doubled, board powered on), then **hung ~13 min** — past the 4–7 min window for a 32 MB image |
| `MSI.ROM` content check (32,554,432 bytes, `_PT_` AMI header, valid FAT32 BPB) | File is structurally valid — not corrupt/truncated |

## Why we believe what we believe

1. **Solid CPU LED with zero RAM installed rules the RAM out as the *current* blocker.** On a healthy AM4 board, absent DIMMs should stall at the **DRAM** LED. Sitting on CPU LED means the firmware halts *before* it ever reaches memory init — RAM presence is irrelevant to this failure.
2. **It ran all day, then died exactly at a BIOS-settings save, and CMOS clears don't resurrect it.** A physically failed CPU/board doesn't wait for a settings change. This pattern is the classic firmware/AGESA "wedged" pre-boot state that survives battery pulls.
3. **The flashback MCU now reads and enters the write phase** — power/standby and the flash subsystem are demonstrably alive. A dead board doesn't do that. This also downgrades "corrupt SPI chip" as the primary cause.
4. **Cross-checked against MSI flashback behavior:** success = short read blink → cadence doubles (write) → ~4–6 min → LED off → board cycles. Failure signatures: never stops blinking, solid LED that stays on, or a few blinks then stop. We are watching a *write-phase hang*, not a success.
5. **Running total:** the two variables that never changed across every flashback attempt — the file and the stick — have now both been checked/validated (file bytes, second stick). The currently-unproven variable is **sustained power during the write**, i.e. the new PSU.

## Boot flash — expected signatures

- **Healthy flash (MSI):** press button → ~5 s → steady blink → after ~15–30 s cadence **doubles** (write) → 4–6 min (32 MB) → LED goes dark → board turns off/on itself.
- **Failure modes:** never stops blinking · solid LED stuck on · a few blinks then stop. Abort any run whose cadence doesn't double within ~60 s, or that outlasts ~7 min at write cadence.

## Current state

- New PSU is the one installed: **Corsair RM850e**.
- RAM is still seated **out** (from the zero-RAM probe). GPU is installed. CPU + cooler installed.
- Latest flash attempt (second stick): write-phase hang ~13 min; PSU power killed to abort. Board is now **fully powered off**, ready for the next attempt.
- **2026-09-17:** recovery is paused while the desktop dev environment is repaired (that work is done — see `docs/roadmap.md`). The PSU swap has been deprioritised; the next physical step is the GPU-removed reflash in step 2 below. Nothing on the board has changed since the last entry unless the user says otherwise — **ask before assuming**.

## Next troubleshooting steps (ordered)

> **Revised 2026-09-17: the PSU swap is deprioritised** at the user's request.
> The hypothesis it tested — sustained power during the write — is still worth
> testing, so step 2 now attacks it by *removing load* instead of changing the
> supply. That is strictly cheaper than a PSU swap and tests the same thing.

1. **Abort current run** if still blinking: PSU switch off, wait ~30 s.
2. **Reflash on a truly bare board — GPU REMOVED this time.** RAM is already
   out; also pull the RTX 4070 Ti Super and unplug non-essential drives and
   case fans, leaving CPU + PSU only. This is MSI's intended flashback state
   and it drops the 12 V load substantially **without touching the PSU**. Same
   validated second stick, same `MSI.ROM`, 3 s press, hands off. Expect cadence
   to double within ~30 s and the LED to go out by ~7 min; abort outside that
   window. If it completes: reinstall RAM A2/B2, power on, boot.
3. **If it hangs again: different BIOS version.** Download an older AGESA
   release from MSI's B550 Tomahawk support page, rename to `MSI.ROM`, same
   stick, same bare-board state. The ROM *version* has never been varied — only
   its integrity was checked (32,554,432 bytes, `_PT_` AMI header). This is the
   cheapest remaining untested variable.
4. **If it hangs again: a third USB stick** if one is available — ≤8 GB, USB
   2.0, DiskPart clean → MBR → FAT32.
5. **CPU reseat with socket-pin inspection.** The CPU was never touched, so the
   odds are low, but it is non-destructive and it is the last thing before RMA.
6. **Old-PSU swap** — kept only as the final diagnostic before RMA, and only if
   you want it. Otherwise go straight to board RMA / MSI warranty; further
   flashing stops being useful after two identical write-hangs.
7. **On successful recovery:** reinstall both sticks A2/B2 → load Optimized Defaults → enable XMP at 3200 only → validate the kit (memtest86/OCCT loop) before trusting it → PBO stays Auto. Then fix `systemd-networkd-wait-online` so reboots aren't a 10-minute black-screen gamble.

## Open questions / to confirm

- ~~Confirm new PSU model/brand for the record.~~ **Resolved: Corsair RM850e.**
- Whether the write-phase hang repeats identically before we burn another attempt.
- After a completed flash + normal boot: does the LED march CPU → DRAM → VGA → BOOT? That is the proof point for "firmware was the trap."

## Recovery checklist (once booting again)

- [ ] RAM retrained, both sticks visible at 3200 (A-XMP on)
- [ ] GPU verified via `nvidia-smi` (RTX 4070 Ti Super 16 GB)
- [ ] `./server/scripts/status.sh` clean (GPU + loaded models + catalog vs installed)
- [ ] Ollama reachable: `curl http://SERVER_IP:11434/api/version`, `/api/tags` shows the 4 server models
- [ ] `systemd-networkd-wait-online` disabled/limited so future reboots don't stall boot
- [ ] SSH key auth for `YOUR_USER@SERVER_IP` staged (subsequent config/skills sync, `status.sh`, host maintenance)