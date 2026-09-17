# Network Topology

LAN connection map for the dev environment.

## Machines

| Machine | Role | IP | OS | Notes |
|---------|------|----|----|-------|
| Ubuntu Server | Ollama host (Qwen Coder 7B/14B, DeepSeek 14B, Qwen3, embed), OpenCode CLI | `SERVER_IP` | Ubuntu | RTX 4070 Ti Super, Docker |
| Windows Desktop | Ollama host (DeepSeek-R1 16k, Qwen Coder 7B, GLM4, embed), WezTerm | `DESKTOP_IP` | Windows 11 | RX 6800 XT, native Vulkan |
| Third node *(future)* | Ollama node (Qwen3 8B, GLM4 9B) | `NODE3_IP` | Windows 11 | RTX 3080 FE, 5950X |

Replace `SERVER_IP`, `DESKTOP_IP`, and `NODE3_IP` with your actual LAN addresses
(`.env` at repo root; `NODE3_IP` is a commented placeholder until their node is onboarded).

## Connections

```
┌──────────────────────────────────────────────────────────────────────┐
│                          LAN (your network)                         │
│                                                                      │
│  ┌─────────────────────┐          ┌─────────────────────┐           │
│  │   WINDOWS DESKTOP   │          │   UBUNTU SERVER     │           │
│  │   WezTerm ──────────┼──SSH────>│   OpenCode CLI      │           │
│  │                     │          │   Qwen Coder 7B/14B │           │
│  │   DeepSeek-R1 14B   │<─────┼──>│   DeepSeek-R1 14B   │           │
│  │   (native Vulkan)   │ :11434   │   (Docker) 0.0.0.0  │           │
│  │   :11434            │          │   :11434            │           │
│  └─────────────────────┘          └─────────────────────┘           │
│          │                                │                          │
│          │         ┌──────────────┐       │        ┌──────────────┐  │
│          ├────────>│  CLOUD APIs  │<──────┼───────>│ THIRD NODE    │  │
│          │         │  OpenCode Go │       │        │ (future)     │  │
│          │         └──────────────┘       │        │ :11434       │  │
│          │                                │        └──────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

## Ports

| Service | Port | Protocol | Bound To | Notes |
|---------|------|----------|----------|-------|
| Server Ollama | 11434 | TCP | 0.0.0.0 | Docker container |
| Desktop Ollama | 11434 | TCP | 0.0.0.0 | Native install |
| Third-node Ollama (future) | 11434 | TCP | 0.0.0.0 | Native install |
| SSH | 22 | TCP | 0.0.0.0 | Server access |

OpenCode reaches each Ollama node through a per-host provider (`ollama-server`,
`ollama-desktop`, `ollama-node3`) whose `baseURL` comes from the active profile's
`OLLAMA_*_BASE_URL` — one provider per machine because a single ollama provider
can only point at one host.

## Firewall Rules Needed

### Windows (Desktop)
- **Inbound**: Allow TCP 11434 from server IP (so server can reach desktop Ollama)
- **Outbound**: Allow TCP 22 to server IP (SSH)

### Ubuntu (Server)
- **Inbound**: Allow TCP 11434 from desktop IP (if server calls desktop)
- **Inbound**: Allow TCP 22 from desktop IP (SSH)

### Windows (Third node — when onboarded)
- **Inbound**: Allow TCP 11434 from desktop + server IPs (OpenCode → its Ollama)

## Environment Variables

These are defined in the shared `.env` file at the dev-docs root and
auto-sourced by all profiles:

```bash
# M:\Projects\dev-docs\.env
SERVER_IP=        # your Ubuntu server LAN IP
DESKTOP_IP=       # your Windows desktop LAN IP
SSH_USER=         # your SSH username on the server
# NODE3_IP=        # uncomment when the node is onboarded
```

On each Ollama host, also set the bind:

```powershell
# Windows (Desktop / Node3, permanent)
[System.Environment]::SetEnvironmentVariable("OLLAMA_HOST", "0.0.0.0", "User")
```

Server binds via `OLLAMA_HOST=0.0.0.0` in `server/docker/.env`.

## Verification

With a profile sourced (which loads `.env`):

```bash
# From server, test desktop Ollama
curl.exe http://${DESKTOP_IP}:11434/api/tags

# From desktop, test server Ollama
curl.exe http://${SERVER_IP}:11434/api/tags

# From desktop, test node3 Ollama (once onboarded)
curl.exe http://${NODE3_IP}:11434/api/tags

# Test SSH
ssh ${SSH_USER}@${SERVER_IP}
```

OpenCode-side: `select-model.sh` offering the profile is the end-to-end check
that a provider can reach its node.