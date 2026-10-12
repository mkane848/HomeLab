# Server Recovery — Solid CPU EZ Debug LED + Flashback hang

Status: **Resolved 2026-10-11: the board had failed.** Machine: server (`SERVER_IP`), Ryzen 7 3700X, RTX 4070 Ti Super 16 GB, Corsair Vengeance LPX 2×16 GB, PSU **Corsair RM850e** (swap batch Sep 2026). Board: the original MSI MAG B550 Tomahawk (effectively new) failed; replaced by an **MSI MAG B550 Tomahawk MAX WiFi**. Last updated: 2026-10-11.

> **Outcome.** Eleven Flashback attempts hung in the write phase across two verified ROMs, four sticks, with
> and without the GPU, and with no CPU in the socket, so the old board could not write its own BIOS chip. A
> new board booted first time with every other part, and Ubuntu came up from the existing drive. Two things
> to know about the new board, both in "Current state": **every CMOS clear wipes the enrolled Secure Boot key**
> (re-enroll `MOK.der` or the GPU driver stops loading), and **A-XMP froze it at power-on**, so XMP is off.
> Open: RMA the old board; the kit's exact part number; the model bring-up (`docs/roadmap.md` → "Next up").

## What happened (timeline)

1. Server was healthy all day — served Ollama inference (models pulled + answering: `qwen2.5-coder:14b`, `deepseek-r1:14b`, `qwen3:8b` on top of `qwen2.5-coder:7b`), reachable on the LAN.
2. In BIOS the user changed **PBO → Auto**, saved & exited.
3. Immediately: black screen, no boot. **The BIOS menu could not be reached either, from that restart on** (owner, confirmed 2026-10-10), so no setting could be changed back. On every subsequent power-on the onboard **CPU EZ Debug LED is solid red** immediately and never clears.
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
| `MSI.ROM` content check (33,554,432 bytes, `_PT_` AMI header, valid FAT32 BPB) | File is structurally valid — not corrupt/truncated. (This row said 32,554,432 until 2026-10-10, a typo: the file is exactly 32 MiB.) |

### 2026-10-10 session

Every attempt: no RAM, 24-pin + 8-pin CPU cable only, all cables from the RM850e's own box, abort at
10 min of write cadence.

| # | ROM | Stick | GPU | Write cadence from | Result |
|---|---|---|---|---|---|
| 3 | AL2 | 8 GB "USB DISK 2.0" (the second stick) | fully installed | 15:50 | Still writing at ~16:00. PSU off. |
| 4 | vAJ | same | installed, PCIe power cable off (card's RGB and its "no aux power" LED lit from slot power) | 16:08 | Still writing at 16:18. PSU off. CPU EZ Debug LED solid during the write. |
| 5 | vAJ | same | **fully out** | 16:49 | Still writing at 16:57. PSU off. |
| 6 | vAJ (verified by hash) | **third stick:** TONPHA USB 2.0, 16 GB, fresh FAT32 | fully out; 24-pin and 8-pin reseated first | 19:07 | Still writing at 19:23. PSU off. |
| 7 | vAJ (verified by hash) | **fourth stick:** SanDisk Cruzer Blade, 4 GB, fresh FAT32 | fully out | 19:38 | Still writing at 19:58. PSU off. |
| 8 | vAJ (verified by hash) | the Sept 2 GB "USB Flash Disk" (FAT32 from Sept's DiskPart clean) | fully out | 20:05 | Still writing at 20:17. PSU off. |

### 2026-10-11: attempt 9, 8-pin CPU cable unplugged

Same setup as attempt 8 (no RAM, GPU out, the 2 GB stick with vAJ), but **only the 24-pin connected**. The
idea was to stop the CPU's cores from powering up during the write. The CPU's SPI-side logic runs on standby
power from the 24-pin, so this was never as strong a test as removing the CPU.

| Try | What happened |
|---|---|
| 9a | Click heard; the Flash BIOS LED was **fully off** afterwards and the stick's light solid. PSU off. |
| 9b | LED **slow-blinked** while the button was pressed (the read), the board clicked on, and the LED **stayed dark**: no fast blink at all. |

Result: Flashback reads the stick but **won't start a write without the 8-pin**, which matches MSI's
instruction to connect both CPU_PWR1 and ATX_PWR1. It tells us nothing about the CPU. Going dark seconds
after the click is not a finished write: rewriting the 32 MB chip takes minutes.

### 2026-10-11: attempt 10, CPU out

MSI's documented Flashback state: **no CPU, no RAM, no GPU**, 24-pin and 8-pin connected (all RM850e cables),
battery in. The only other part on the board is the M.2 drive, as on every attempt. ROM vAJ on the 2 GB stick.

| # | Setup | Write cadence from | Result |
|---|---|---|---|
| 10 | CPU and cooler removed | 12:16 | Still writing at 12:26. PSU off. |

Result: **the write hangs with nothing in the socket.** The CPU is not what stops Flashback, and Flashback is
exhausted: two ROMs, four sticks, with and without GPU, with and without CPU. What's left is the board's own
flash path: the SPI chip itself, or the Flashback controller and its wiring to the chip.

### 2026-10-11: attempt 11, the long run

Same setup as attempt 10 (CPU out). The 8 GB stick was on the desktop at the time, so this is presumably the
2 GB stick with vAJ. The only change is the cutoff: **up to 60 minutes** instead of 10. A worn flash chip
erases and writes more slowly, and a 32 MB chip's worst-case datasheet times add up to roughly 13 minutes
before any Flashback overhead. The longest earlier run was about 20 minutes (attempt 7).

| # | Write cadence from | Result |
|---|---|---|
| 11 | 13:25 | In progress; cutoff 14:25. |

#### USB sticks tried with MSI Flashback (this board)

Public advice on which sticks MSI's Flashback controller accepts is thin and anecdotal (mostly "8 GB or
smaller, USB 2.0, FAT32"), so every stick is recorded here with its exact identity: USB vendor and product ID
(`VID:PID`) and firmware revision from Windows' device history
(`HKLM\SYSTEM\CurrentControlSet\Enum\USBSTOR`). "Read OK" means the LED reached write cadence, which shows the
controller read the stick. None has completed a write yet, so no stick here is proven good.

| Stick | VID:PID, rev | Size | Format when used | Read OK? | Write finished? | Attempts |
|---|---|---|---|---|---|---|
| 2 GB "control" stick (Sept): "USB Flash Disk" (identified 2026-10-10: it still held the Sept `MSI.ROM`, byte-identical to MSI's AL2) | `090C:1000`, rev 1100 | 2 GB (2,004,877,312 B) | DiskPart clean, MBR, FAT32 (partition type "FAT32 XINT13"), 4 KB clusters | Sept: recorded as **no** (never left read cadence). **2026-10-10: yes**, write cadence from 20:05 with vAJ. The owner thinks the Sept "no" was probably a misread, so don't count it as evidence the stick fails. | No | Sept, 8 |
| "USB DISK 2.0" (the owner recalls installing Ubuntu on the server from it, unconfirmed since its contents were wiped 2026-09-16) | `1516:1213`, rev 0119 | 8 GB (8,210,350,080 B) | MBR, FAT32, 4 KB clusters | Yes | No | Sept, 3, 4, 5 |
| TONPHA USB 2.0 Classic | `2022:0722`, rev 8.07 | 16 GB (15,728,640,000 B) | Explorer quick format, MBR, FAT32, 8 KB clusters | Yes | No | 6 |
| SanDisk Cruzer Blade | `0781:5567`, rev 1.18 | 4 GB (4,004,511,744 B) | Explorer quick format, MBR, FAT32 (partition type "FAT32 XINT13", i.e. LBA; the TONPHA's read plain "FAT32"), 4 KB clusters | Yes | No | 7 |

Other sticks in this PC's device history, not yet tried: Kingston DataTraveler 2.0 (`0930:6545`, rev PMAP),
SanDisk Cruzer ×2 (`0781:5530`, rev 1.26), SanDisk Cruzer Glide (`0781:5575`, rev 1.26).

| Check | Result |
|---|---|
| AL2 on the stick against MSI's own download (`download.msi.com/bos_exe/mb/7C91vAL2.zip`, read 2026-10-10) | **Byte-identical.** `E7C91AMS.AL2`, built 2026-08-14, released 2026-08-21 (PS/2 S3 resume fix). SHA256 `F0EB41925463734A08BB991313A476C32E0B9896D74626187C316EE18DF4A70E`. |
| vAJ from MSI (`7C91vAJ.zip`) | `E7C91AMS.AJ0`, 33,554,432 bytes, `_PT_` at 0x0 and 0x1000000, released 2025-09-09, AGESA ComboAm4v2PI 1.2.0.F. SHA256 `5063D0B2B7798C365386BE607CE510AE2FDCF39F8172611D1BE257C57E42A329`. Copied to the stick and verified by hash. |
| Battery out ~1 h, PSU off, then power on (no RAM, no GPU, no flash) | **Still solid CPU LED.** Not the DRAM LED a board that passed CPU init stops at. |

Closest community match, found 2026-10-10: an MSI B550M Mortar that stopped posting with a solid CPU LED
after a BIOS settings save (fan speeds). CMOS clears did nothing, and Flashback blinked 30+ min without
finishing across 4–5 sticks, 4+ BIOS versions, a stripped board and a second CPU
([Tom's Hardware thread](https://forums.tomshardware.com/threads/msi-b550m-mortar-bios-flash-boot-issues.3664291/)).
The original poster never reported a fix; a later poster with the same board recovered by a 10-minute
battery pull.

## Why we believe what we believe

1. **Solid CPU LED with zero RAM installed rules the RAM out as the *current* blocker.** On a healthy AM4 board, absent DIMMs should stall at the **DRAM** LED. Sitting on CPU LED means the firmware halts *before* it ever reaches memory init — RAM presence is irrelevant to this failure.
2. **It ran all day, then died exactly at a BIOS-settings save, and CMOS clears don't resurrect it.** A physically failed CPU/board doesn't wait for a settings change. This pattern is the classic firmware/AGESA "wedged" pre-boot state that survives battery pulls.
3. **The flashback MCU now reads and enters the write phase** — power/standby and the flash subsystem are demonstrably alive. A dead board doesn't do that. This also downgrades "corrupt SPI chip" as the primary cause.
4. **Cross-checked against MSI flashback behavior:** success = short read blink → cadence doubles (write) → ~4–6 min → LED off → board cycles. Failure signatures: never stops blinking, solid LED that stays on, or a few blinks then stop. We are watching a *write-phase hang*, not a success.
5. **Running total:** the two variables that never changed across every flashback attempt — the file and the stick — have now both been checked/validated (file bytes, second stick). The currently-unproven variable is **sustained power during the write**, i.e. the new PSU.
6. **2026-10-10 update: the file and the load are ruled out.** Two different ROMs, both verified (AL2 byte-identical to MSI's download), hang identically in the write phase, including on a board with no GPU and no RAM. Point 2 above is weaker than it reads: PBO "Auto" is MSI's default, so the save probably changed nothing, and a restart is when a failing part shows. The PSU, GPU and RAM were all new in Sep 2026. What remains:
   - **The settings change left the BIOS chip stuck.** It's still possible, since MSI keeps some settings in the SPI chip, which a CMOS clear doesn't touch, and no rewrite has completed. A finished write would fix it.
   - **The Flashback write path:** the stick (picky MCU), or the board's flash circuit.
   - **A board fault:** the one cause that explains both the no-POST and the write hang. A failed CPU explains only the no-POST, since Flashback doesn't use the CPU.
7. **2026-10-11 update: the CPU is ruled out as the cause of the hang, and so are the sticks.** Attempt 10
   hung with no CPU in the socket; attempts 6–8 hung on three more sticks. The remaining explanation for
   both symptoms is the BIOS (SPI) chip or the board's path to it. A failing flash chip also fits the
   trigger: saving BIOS settings is a write to that chip, so a chip that started failing would show up
   at exactly that save. A finished write from an SPI programmer would tell "stuck contents" (fixed)
   apart from "chip won't take a write" (replace the chip or the board).

## Boot flash — expected signatures

- **Healthy flash (MSI):** press button → ~5 s → steady blink → after ~15–30 s cadence **doubles** (write) → 4–6 min (32 MB) → LED goes dark → board turns off/on itself.
- **Failure modes:** never stops blinking · solid LED stuck on · a few blinks then stop. Abort any run whose cadence doesn't double within ~60 s, or that outlasts ~7 min at write cadence.

## Current state

**The failed MAG B550 Tomahawk was effectively brand new** (owner, 2026-10-11), so this was an early failure
of a new board, and a warranty RMA to MSI is the obvious route for it. Which part of the board failed (the
BIOS chip, the Flashback controller, or something else) was never pinned down.

**2026-10-11, later:** the owner bought a replacement board, an **MSI MAG B550 Tomahawk MAX WiFi**, to bench-test
with the server's CPU, RAM, GPU and PSU before it goes into the case. Attempt 11's result is not recorded yet.
The CPU's pins were inspected while it was out: no bent or misaligned pins (owner).

**2026-10-11: the new board boots.** Bench test on the cardboard box: the server's own 3700X (cooler and fresh
paste), both RAM sticks in A2/B2, the 4070 Ti Super powered, the M.2, all RM850e cables. EZ Debug LEDs stepped
CPU → DRAM → VGA, GRUB came up from the existing M.2, and Ubuntu booted to a login with the existing account.
**So the CPU, RAM, GPU, PSU and drive are all fine, and the old MAG B550 Tomahawk was the fault.** Still to
check on the bench: network (new MAC, maybe a new interface name), `nvidia-smi`, CPU temperature, then
Optimized Defaults in the BIOS.

**Bench checks over SSH (2026-10-11, key `dev-docs` now authorized for the server user):**

- Board reports `MAG B550 TOMAHAWK MAX WIFI (MS-7C91)`, BIOS `2.B0` (2026-04-16). Ubuntu 26.04.1, kernel
  `7.0.0-31-generic`.
- Network: `enp42s0` UP at `SERVER_IP` **by DHCP**, with the new board's MAC (`ip -br link` shows it). Same
  name as before, so netplan needed no change; the router needs a reservation for the new MAC to keep the
  address.
- CPU `k10temp` 50 °C idle on the bench; 30 GB RAM visible; no failed systemd units.
- **GPU driver not loaded** (`nvidia-smi` fails). Cause: the DKMS `nvidia` 580.178.04-server module is signed
  with this machine's own key (`<hostname> Secure Boot Module Signature key`, `/var/lib/shim-signed/mok/MOK.der`,
  made 2026-09-07). That key was enrolled in the **old board's** firmware, where it loaded fine with Secure Boot
  on (journal, 2026-09-16 01:58). The new board has Secure Boot on and only Canonical's key enrolled, so the
  locked-down kernel refuses the module. Fix: re-enroll the key (`mokutil --import`, then MokManager at reboot)
  or turn Secure Boot off.
- Ollama container `ollama-server` exited 2026-09-16 02:27:45, at the shutdown before the PBO change ("nvml
  error: driver not loaded" as the module unloaded). Restart policy `unless-stopped`.
- Root LV is 100 GB (35 GB free) of a 928.5 GB partition; the rest of the volume group is unallocated.
- apt cache last refreshed 2026-09-16; it shows 5 upgradable (netplan, thermald), so `apt update` is due.

**GPU fixed (2026-10-11):** `sudo mokutil --import /var/lib/shim-signed/mok/MOK.der`, reboot, Enroll MOK in
MokManager. (`mokutil --list-new` without `sudo` prints nothing even when a key is queued: `MokNew` is
root-only.) After the reboot the key is enrolled, the `nvidia` modules load with Secure Boot still on, and
`nvidia-smi` shows the RTX 4070 Ti SUPER on driver 580.178.04. `ollama-server` came back by itself
(`unless-stopped`), Ollama 0.33.3, reachable from the desktop at `SERVER_IP:11434`, and the container sees the
GPU. Installed models: `deepseek-r1:14b`, `qwen2.5-coder:14b`, `qwen3:8b`, `qwen2.5-coder:7b`. Smoke test:
`qwen3:8b` loaded 7.5 GB, all of it in VRAM, and generated at ~108 tok/s warm.

**Updated (2026-10-11):** `apt full-upgrade`, 59 upgraded + 7 new: kernel 7.0.0-31 → **7.0.0-38**,
nvidia-container-toolkit 1.20.0 → 1.20.1, openssh, sudo, netplan, openssl and others; the NVIDIA driver itself
unchanged. DKMS rebuilt `nvidia-srv` 580.178.04 for -38 and signed it with the enrolled key before the reboot.
After the reboot: kernel -38, Secure Boot on, `nvidia-smi` OK, `ollama-server` healthy and sees the GPU, no
failed units, `qwen3:8b` all in VRAM at ~111 tok/s warm. Held back by Ubuntu's phased rollout: `open-iscsi`,
`libopeniscsiusr`.

**BIOS settings on the new board (2026-10-11, owner):** Restore after AC Power Loss → **Power On** (always-on
server), and **A-XMP enabled** for the Vengeance LPX (the 35B main seat spills ~8.6 GB to system RAM, so memory
speed matters). PBO and everything else left at defaults.

**A-XMP did not boot (2026-10-11).** After saving it, the board powered on with the fans running but no EZ
Debug LED lit, "No signal" on DisplayPort, Num Lock and Caps Lock dead, and nothing on the network for 10+
minutes. The journal has no entry for that boot, so it hung in firmware before Linux started. A **CMOS clear**
(battery out) brought it back; it then booted in 42 s (userspace 9.5 s, so no `systemd-networkd-wait-online`
stall on this board). XMP is off for now. The kit's exact part number is still to be read off the label (an
older note has `CMK32GX4M2...3200C16`).

**The CMOS clear also wiped the enrolled Secure Boot key.** Afterwards only Canonical's key was enrolled and
the `nvidia` module was refused again, as on the first boot. On this board, **every CMOS clear means
re-enrolling `MOK.der`** (`sudo mokutil --import /var/lib/shim-signed/mok/MOK.der`, reboot, Enroll MOK), or the
GPU driver silently stops loading. The power-loss setting has to be set again too.

**Paused here (2026-10-11, owner's call):** the board goes into the case as it is, with BIOS defaults, XMP off,
Restore after AC Power Loss back at its default (after an outage, press the power button), and the key **not
yet re-enrolled**, so the GPU driver and Ollama are down until it is. Re-enrolling needs a monitor and keyboard
for one boot, but no BIOS settings. Everything else (SSH, updates, the rest of bring-up) works.

**CPU thermals on the bench (2026-10-11, open air, fresh paste):** idle Tctl ~40 °C; under a 60 s all-core load
on all 16 threads it rose to 59 °C in the first 10 s and levelled off at ~62 °C, holding ~4.0 GHz on every core.
The 3700X's limit is 95 °C. Re-check once it's in the case, where expect a few degrees more.

**Key re-enrolled (2026-10-11):** after `mokutil --import` and MokManager, the key is enrolled again, the GPU
driver loads, `ollama-server` came back by itself and sees the GPU, it answers from the desktop (0.33.3), and
`qwen3:8b` runs entirely in VRAM. Ready to go into the case.

**In the case (2026-10-11):** boots in 43 s; Secure Boot on with both keys enrolled; `enp42s0` at
`SERVER_IP`; GPU on PCIe **Gen 4 x16**; `ollama-server` healthy and answering from the desktop; no failed
units, no hardware errors in the kernel log. Idle: CPU 31 °C, GPU 29 °C, NVMe 27 °C. Under a 60 s all-core
CPU load with a `qwen3:8b` generation on the GPU at the same time: CPU levelled at 58–60 °C (~4.0 GHz all
cores); GPU peaked at 50 °C at ~259 W, 92 % busy, during its ~20 s of work (1,212 tokens at ~106 tok/s). Back
to 38 °C / 31 °C within 20 s. Sustained GPU load is still untested; the model bring-up will be the first.

**2026-10-11, after attempt 10:** CPU and cooler **out** (CPU stored pins up), RAM out, GPU out, M.2 in,
24-pin and 8-pin connected, battery in, PSU off. The 2 GB stick holds vAJ. Thermal paste and isopropyl
alcohol on hand. Flashback is exhausted; next steps are in the 2026-10-11 revision below.

**2026-10-11, after attempt 9:** the 8-pin CPU cable was plugged back in for attempt 10.

**2026-10-10:** RAM out, GPU **out**, only the 24-pin and 8-pin CPU cable connected, battery back in, PSU
off. The 8 GB stick holds vAJ. A third stick (TONPHA USB 2.0, 16 GB) is being prepared with vAJ for attempt
6; its old contents were backed up and verified byte-identical before it was wiped.
The entries below are the 2026-09 state, kept for the record.

- New PSU is the one installed: **Corsair RM850e**.
- RAM is still seated **out** (from the zero-RAM probe). GPU is installed. CPU + cooler installed.
- Latest flash attempt (second stick): write-phase hang ~13 min; PSU power killed to abort. Board is now **fully powered off**, ready for the next attempt.
- **2026-09-17:** recovery is paused while the desktop dev environment is repaired (that work is done — see `docs/roadmap.md`). The PSU swap has been deprioritised; the next physical step is the GPU-removed reflash in step 2 below. Nothing on the board has changed since the last entry unless the user says otherwise — **ask before assuming**.

## Next troubleshooting steps (ordered)

> **Revised 2026-10-11.** Step 2 of the 2026-10-10 revision is done (attempt 10): Flashback hangs with the
> CPU out, so it's exhausted. The choice now:
>
> 1. **SPI programmer** (CH341A with a SOIC-8 clip, 3.3 V-safe, about $15). Read the chip's marking first,
>    then use the programmer to identify, erase, write and verify vAJ without Flashback. A verified write
>    that boots means the chip's contents were stuck, which was fixable all along. A chip that won't erase
>    or verify means it has failed: replace the chip (a soldering job) or the board.
> 2. **Replacement board** (any AM4 B550): the fastest way back up, reusing the CPU, RAM, GPU, PSU and M.2.
>    The CPU itself is still untested in another board; a new board would test it.
> 3. **MSI RMA** if the board is still under warranty.
>
> The 2026-10-10 revision follows, kept for the record.
>
> **Revised 2026-10-10.** Steps 2 and 3 below are done (attempts 3–5). The owner's order from here: rule out
> everything on the reflash side before treating the CPU or PSU as suspects.
>
> 1. ~~Attempt 6: vAJ from a third stick, cables reseated.~~ Done, hung. Attempt 7 (a fourth stick, SanDisk)
>    hung too. Three sticks of three brands, controllers and sizes all read and then hang at the same point,
>    so the stick is ruled out.
> 2. **Next: Flashback with the CPU out** (MSI's documented state: no CPU, no memory). On AM4 the BIOS chip
>    hangs off the CPU's SPI bus, so a CPU in the socket is the one part on that bus never removed. Inspect
>    the CPU's pins while it's out; reapplying thermal paste is needed afterwards.
>    - Finishes, then boots with the CPU back: firmware was the problem.
>    - Finishes, but solid CPU LED with the CPU back: the CPU (test it in the desktop or node3).
>    - Still hangs with no CPU: the board can't write its own chip, so it's a board fault.
> 3. **If it still hangs:** Flashback is exhausted. Choose between:
>    - writing the chip directly with an SPI programmer (CH341A, 3.3 V-safe, SOIC-8 clip; the chip is
>      32 MB), which tests "stuck BIOS chip" without Flashback;
>    - a CPU-swap test (the desktop and node3 are AM4) to settle board vs CPU;
>    - a replacement board.
> 3. **On success:** RAM in A2/B2, GPU in and powered, then watch the LED march CPU → DRAM → VGA → BOOT and
>    load Optimized Defaults. Leave PBO alone.
>
> The 2026-09-17 plan follows, kept for the record.

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
   its integrity was checked (33,554,432 bytes, `_PT_` AMI header). This is the
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

Status as of 2026-10-11, on the replacement board:

- [ ] ~~RAM retrained, both sticks visible at 3200 (A-XMP on)~~ Both sticks visible (30 GB usable) at the
      default speed. A-XMP froze the board at power-on, so it is off; not retried.
- [x] GPU verified via `nvidia-smi` (RTX 4070 Ti Super 16 GB, driver 580.178.04, PCIe Gen 4 x16)
- [ ] `./server/scripts/status.sh` clean (GPU + loaded models + catalog vs installed): not run yet
- [x] Ollama reachable: `curl http://SERVER_IP:11434/api/version` (0.33.3), `/api/tags` shows the 4 server models
- [x] ~~`systemd-networkd-wait-online` disabled/limited~~ Not needed on this board: boots in ~43 s, userspace
      under 14 s
- [x] SSH key auth for `YOUR_USER@SERVER_IP` with the `dev-docs` key (`ssh server` from the desktop)
- [ ] Router reservation for the new board's MAC (the address currently comes from DHCP)
- [ ] RMA the failed MAG B550 Tomahawk