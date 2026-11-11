# Network Topology

LAN connection map for the dev environment.

This page is network facts only (hosts, ports, firewall, SSH). Models: [profiles.md](profiles.md).

## Machines

| Machine | Role | IP | OS | Notes |
|---------|------|----|----|-------|
| Ubuntu Server | Model host (Ollama :11434, llama.cpp :8090) | `SERVER_IP` | Ubuntu | RTX 4070 Ti Super, Docker. No OpenCode client (removed 2026-10-19) |
| Windows Desktop | Model host, OpenCode client, WezTerm | `DESKTOP_IP` | Windows 11 | RX 6800 XT, native Vulkan |
| Third node | Model host, OpenCode client, tool-run host | `NODE3_IP` | Windows 11 | RTX 3080 FE, 5950X; onboarded 2026-09-20; also a gaming PC |

Replace `SERVER_IP`, `DESKTOP_IP`, and `NODE3_IP` with your actual LAN addresses
(`.env` at repo root).

## Connections

```
┌──────────────────────────────────────────────────────────────────────┐
│                          LAN (your network)                         │
│                                                                      │
│  ┌─────────────────────┐          ┌─────────────────────┐           │
│  │   WINDOWS DESKTOP   │          │   UBUNTU SERVER     │           │
│  │   WezTerm ──────────┼──SSH────>│   (model host)      │           │
│  │   OpenCode client   │          │   llama.cpp :8090   │           │
│  │   Ollama, fallback  │<─────┼──>│   main seat qwen3.6 │           │
│  │   (native Vulkan)   │          │   (Docker) 0.0.0.0  │           │
│  │   :11434            │          │   Ollama :11434 off │           │
│  └─────────────────────┘          └─────────────────────┘           │
│          │                                │                          │
│          │         ┌──────────────┐       │        ┌──────────────┐  │
│          ├────────>│  CLOUD APIs  │<──────┼───────>│ THIRD NODE   │  │
│          │         │  OpenCode Go │       │        │ (node3)      │  │
│          │         └──────────────┘       │        │ :11434       │  │
│          │                                │        └──────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

## Ports

| Service | Port | Protocol | Bound To | Notes |
|---------|------|----------|----------|-------|
| Server llama.cpp (`llama-server`) | 8090 | TCP | 0.0.0.0 | Docker container; the engine that starts at boot since 2026-11-01. No API key: any LAN host can use it |
| Server Ollama | 11434 | TCP | 0.0.0.0 | Docker container, stopped since 2026-11-01 and kept as the rollback engine (`startup.sh --engine ollama`). No API key |
| Desktop Ollama | 11434 | TCP | 0.0.0.0 | Native install |
| Third-node Ollama | 11434 | TCP | 0.0.0.0 | Native install |
| SSH | 22 | TCP | 0.0.0.0 | Server access |
| Household tracker (Grocy) | 9283 | TCP | 0.0.0.0 (LAN only, never port-forwarded) | Docker, `household` project ([docs/household/phase1.md](household/phase1.md)) |
| Household chat (Open WebUI) | 3000 | TCP | 0.0.0.0 (LAN only, never port-forwarded) | Docker, `household` project ([docs/household/phase2-chat.md](household/phase2-chat.md)) |

OpenCode reaches each engine through a per-host provider (`llamacpp-server`,
`ollama-server`, `ollama-desktop`, `ollama-node3`) whose `baseURL` comes from the
active profile's `LLAMACPP_*_BASE_URL` or `OLLAMA_*_BASE_URL` — one provider per
machine because a single provider can only point at one host. (Diagram and ports
brought up to the 2026-11-01 engine change on 2026-11-11.)

## Firewall Rules Needed

### Windows (Desktop)
- **Inbound**: Allow TCP 11434 from server IP (so server can reach desktop Ollama)
- **Outbound**: Allow TCP 22 to server IP (SSH)

### Ubuntu (Server)
- **Inbound**: Allow TCP 11434 from desktop IP (if server calls desktop)
- **Inbound**: Allow TCP 22 from desktop IP (SSH)

### Windows (Third node)
- **Inbound**: Allow TCP 11434 from desktop + server IPs (OpenCode → its Ollama)

## Environment Variables

These are defined in the ignored `.env` at the repo root and
auto-sourced by all profiles:

```bash
# <repo root>/.env
SERVER_IP=        # your Ubuntu server LAN IP
DESKTOP_IP=       # your Windows desktop LAN IP
SSH_USER=         # your SSH username on the server
NODE3_IP=         # third-node LAN IP (onboarded 2026-09-20)
```

On each Ollama host, also set the bind:

```powershell
# Windows (Desktop / Node3, permanent)
[System.Environment]::SetEnvironmentVariable("OLLAMA_HOST", "0.0.0.0", "User")
```

Server binds via `OLLAMA_HOST=0.0.0.0` in `server/docker/.env`.

## SSH access

Recorded 2026-10-12, when the server came back on a replacement board. Placeholders as
elsewhere; the real values are in the git-ignored `.env` and in `~/.ssh/config`.

- **Desktop → hosts.** `~/.ssh/config` has a `Host server` and a `Host node3` entry (HostName from `.env`,
  `User` = `SSH_USER` for the server), both `IdentityFile ~/.ssh/<fleet key>` with `IdentitiesOnly yes`. So
  `ssh server` and `ssh node3` work, and key auth means no prompt: scripts and agents can run `ssh -o BatchMode=yes server <cmd>`.
  The key is a single ed25519 pair used for this fleet; the private half stays on the desktop and is never copied
  to a phone or into the repo. The server's `authorized_keys` holds its public half.
- **Phone / other clients (Terminus).** Host = `SERVER_IP`, port 22, user = `SSH_USER`, LAN only. Prefer a key
  generated in the client with its public half appended to the server's `~/.ssh/authorized_keys`; the server does
  not disable password login in its config files, so a password may also work (unconfirmed without root). Check
  the first-connect fingerprint against `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` run on the server.
  A replaced board or reinstall changes the host keys: expect a one-time "host key changed" warning on every client.
- **`sudo` on the server asks for a password.** Anything privileged (extending the root LV, installing packages,
  `systemctl`) is run by the owner in their own session. Agents and scripts do everything that needs only the
  `docker` group: Ollama, models, compose. Do not add a passwordless-sudo rule for convenience.
- **Server layout.** A checkout (or `git archive` extract) of this repo at `~/HomeLab`; the compose project there is
  named `docker`, which owns the models' volume `docker_ollama_data`. Renaming that directory orphans the volume.
  `~/dev-docs` is the pre-outage copy (Sep 2026, not a repo; this repo was called dev-docs before it was renamed HomeLab) and can be removed once nothing points at it.

## Verification

With a profile sourced (which loads `.env`):

```bash
# From server, test desktop Ollama
curl.exe http://${DESKTOP_IP}:11434/api/tags

# From desktop, test server Ollama
curl.exe http://${SERVER_IP}:11434/api/tags

# From desktop, test node3 Ollama
curl.exe http://${NODE3_IP}:11434/api/tags

# Test SSH
ssh ${SSH_USER}@${SERVER_IP}
```

OpenCode-side: `select-model.sh` offering the profile is the end-to-end check
that a provider can reach its node.