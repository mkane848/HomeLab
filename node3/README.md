# node3: llama-server

node3 (RTX 3080 FE 10 GB, Ryzen 9 5950X) is the fleet's run host first. This folder is its model-host half on
llama.cpp: "Replacing Ollama" Phase 5 in [`docs/roadmap.md`](../docs/roadmap.md), started 2026-10-31. Ollama keeps
running beside it until Phase 6.

| File | What |
|---|---|
| [`llamacpp/models.ini`](llamacpp/models.ini) | the router preset: `qwen3:8b` (same weights and sampling as node3's Ollama copy and the server's seat) and, since 2026-11-03, `qwen3.6:35b-a3b-coding` as a second agent seat loaded on demand (below) |
| [`scripts/start-llama-server.ps1`](scripts/start-llama-server.ps1) | registers the scheduled task `HomeLab-llamacpp` (starts at boot) and starts it; `-Lan` to listen on the LAN, `-Stop` to remove it |

## Install

The build is pinned: llama.cpp **b11562**, Windows CUDA 12.4. The server runs b11561 in Docker, and that build has no
Windows release; b11562 is the next commit. Unpack both zips from the
[b11562 release](https://github.com/ggml-org/llama.cpp/releases/tag/b11562) into `C:\HomeLab\llama.cpp\b11562\`, after
checking them against the digests GitHub publishes for them:

| Asset | sha256 |
|---|---|
| `llama-b11562-bin-win-cuda-12.4-x64.zip` | `e06a4659435981acc93d4ef37ae6046b72754af968aa2cd6f476a9fa5c4f765c` |
| `cudart-llama-bin-win-cuda-12.4-x64.zip` | `8c79a9b226de4b3cacfd1f83d24f962d0773be79f1e7b75c6af4ded7e32ae1d6` |

Then, from this checkout on node3: `pwsh -File node3\scripts\start-llama-server.ps1`.

The preset's `model` path is node3's own Ollama blob (`C:\Users\<user>\.ollama\models\blobs\sha256-a3de86…`, with the real profile name in `node3/llamacpp/models.ini`): the same
bytes as the server's `qwen3:8b` seat (`models/server-seats.tsv`), so a difference in results is the engine, not the
weights.

## `qwen3.6` as a second seat, on demand (2026-11-03)

The server's main seat also runs here, on the 3080: same weights, sampling and thinking budget, with `n-cpu-moe 32`
and a 4,096 batch, measured best (987 to 1,227 tok/s prefill, 64 to 68 decode; `docs/roadmap.md`). The GGUF is the
server's Ollama blob copied to `C:\HomeLab\models\qwen3.6-35b-a3b-coding.gguf` (21.7 GB; sha256 `d372de8e…`, checked
at both ends), because node3's Ollama has no `qwen3.6`.

Nothing holds the card between uses: the router loads the seat at a window's first request (about 7 s) and the
window unloads it when it ends. node3 is also the family's gaming PC, and their use wins: a window started with
`-YieldToGames` will not start while a game runs and ends itself when one starts
([`docs/unattended-window.md`](../docs/unattended-window.md) → "A window on node3's own GPU"). After a change to
`models.ini`, restart the service so the router reads it: `Stop-ScheduledTask HomeLab-llamacpp; Start-ScheduledTask
HomeLab-llamacpp`.

## On the LAN (the owner's step)

The task listens on `127.0.0.1` until a firewall rule lets the LAN in. Listening on `0.0.0.0` without one makes Windows
show a firewall prompt on node3's screen. In an elevated PowerShell on node3:

```powershell
New-NetFirewallRule -DisplayName "llama-server 8090 (LAN)" -Direction Inbound -Protocol TCP -LocalPort 8090 -RemoteAddress 192.168.1.0/24 -Action Allow
```

then `pwsh -File node3\scripts\start-llama-server.ps1 -Lan`. `profiles/dev-node3.sh` already points
`LLAMACPP_NODE3_BASE_URL` at `http://<NODE3_IP>:8090/v1`.

## Measured (2026-10-31, `qwen3:8b`)

| Check | llama.cpp b11562 | Ollama 0.40.4 (same host, same weights) |
|---|---|---|
| tool-call probe (`tests/test-toolcalls.ps1 -Engine llamacpp`) | PASS, 15.4 s | PASS (2026-09-20, on 0.34.x) |
| over-long request (`tests/probe-overflow.ps1`, ~42,600 tokens at 32,768) | **EXPLICIT-ERROR**: HTTP 400, which OpenCode classifies as a context overflow | SILENT-TRUNCATION: evaluated 16,386 tokens (38%), no error (2026-10-14) |
| prefill / decode at 3k, 16k, 30k tokens (`tests/bench-speed.ps1`, 2 reps) | 4,290 / 3,454 / 2,820 · 97.8 / 72.8 / 57.1 tok/s | 4,237 / 3,405 / 2,777 · 97.2 / 73.1 / 57.1 tok/s |

Rows: `tests/results/toolcalls-summary-llamacpp.tsv`, `tests/results/overflow-probe.tsv`,
`tests/results/bench-speed.tsv`.

## Git on node3 (2026-11-02)

- **`C:\HomeLab\repos\HomeLab`** (public): pulls over https with no credentials. node3 never pushes it.
- **`C:\HomeLab\repos\HomeLab-private`**: `origin` is `git@github-homelab-private:mkane848/HomeLab-private.git`, an
  alias in `~/.ssh/config` for `github.com` with `~/.ssh/id_ed25519_homelab_private` only (`IdentitiesOnly yes`). That
  key is a **deploy key on `HomeLab-private` with write access**, nothing else; node3's own `id_ed25519` is untouched.
  The key has no passphrase, so unattended windows can push. Commits are authored `mikek` (set in this repository only).
- **Why not https:** Git Credential Manager stores its login in the Windows credential vault, which an ssh session can
  neither read nor prompt for, and every unattended run reaches node3 over ssh.
- **What changed:** node3's repos were imported from git bundles on 2026-10-13 with no GitHub credentials and pushing
  disabled (`remote.origin.pushurl = https://push-disabled.invalid/`, `docs/roadmap.md`). The owner lifted that for
  `HomeLab-private` only, so a window's results are committed where they are made. Test runs still cannot push: the
  harness rewrites every push inside a run (`Set-NoPushEnv` in `tests/test-tasks.ps1`).
- **Over ssh, use `ssh -o BatchMode=yes`** for anything that might prompt (`GIT_SSH_COMMAND`), and do not chain
  commands with `;`: node3's ssh shell is `cmd`, which passed `-Apply;` to a script as one argument (2026-11-02). A
  script copied over with `scp` and run with `pwsh -File` reports its errors; one piped into `pwsh -Command -` can fail
  silently.

## Known gaps

- **The harness's GPU-placement check does not work against node3's llama-server.** `Get-EngineGpuPlacement` in
  `tests/engines/llamacpp.ps1` runs `nvidia-smi --query-compute-apps=pid,used_memory` and `ps -eo pid,args` over ssh:
  `ps` is Linux-only, and on Windows (WDDM) `nvidia-smi` reports every process's memory as `[N/A]`. A run against
  `llamacpp-node3` records placement `unchecked` (a WARN, not a grade). A Windows branch would read process command
  lines through CIM and the card's total `memory.used`.
- The two engines share the 10 GB card. Unload one before loading a seat on the other.
