# Network Topology

LAN connection map for the dev environment.

This page is network facts only (hosts, ports, firewall, SSH). Models: [profiles.md](profiles.md).

## Machines

| Machine | Role | IP | OS | Notes |
|---------|------|----|----|-------|
| Ubuntu Server | Model host (llama.cpp :8090) | `SERVER_IP` | Ubuntu | RTX 4070 Ti Super, Docker. No OpenCode client (removed 2026-10-19) |
| Windows Desktop | OpenCode client, harness run host, WezTerm | `DESKTOP_IP` | Windows 11 | RX 6800 XT; runs no models since 2026-11-21 |
| Third node | Model host (llama.cpp :8090), OpenCode client, tool-run host | `NODE3_IP` | Windows 11 | RTX 3080 FE, 5950X; onboarded 2026-09-20; also a gaming PC |

Ollama (port 11434) was removed from the fleet on 2026-11-21; llama.cpp's `llama-server` is the only engine.

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
│  │   harness run host  │─HTTP────>│   main seat qwen3.6 │           │
│  │   (no models)       │          │   (Docker) 0.0.0.0  │           │
│  └─────────────────────┘          └─────────────────────┘           │
│          │                                                           │
│          │         ┌──────────────┐                ┌──────────────┐  │
│          ├────────>│  CLOUD APIs  │                │ THIRD NODE   │  │
│          │         │  OpenCode Go │                │ (node3)      │  │
│          │         └──────────────┘                │ llama.cpp    │  │
│          └────────────────────────────────────────>│ :8090        │  │
│                                                    └──────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

## Ports

| Service | Port | Protocol | Bound To | Notes |
|---------|------|----------|----------|-------|
| Server llama.cpp (`llama-server`) | 8090 | TCP | 0.0.0.0 | Docker container; the engine that starts at boot since 2026-11-01. **API key** once [engine-api-keys.md](engine-api-keys.md) is rolled out: everything but `/health` answers 401 without it. Until then, and until the rule under "Limit the model ports to named hosts" is applied, any LAN host can use it |
| node3 llama.cpp (`llama-server`) | 8090 | TCP | 127.0.0.1 until its LAN firewall rule ([node3/README.md](../node3/README.md)) | Native, scheduled task `HomeLab-llamacpp`; API key as above |
| SSH | 22 | TCP | 0.0.0.0 | Server access |
| Household tracker (Grocy) | 9283 | TCP | 0.0.0.0 (LAN only, never port-forwarded) | Docker, `household` project ([docs/household/phase1.md](household/phase1.md)) |
| Household chat (Open WebUI) | 3000 | TCP | 0.0.0.0 (LAN only, never port-forwarded) | Docker, `household` project ([docs/household/phase2-chat.md](household/phase2-chat.md)) |

OpenCode reaches each engine through a per-host provider (`llamacpp-server`,
`llamacpp-node3`) whose `baseURL` comes from the active profile's
`LLAMACPP_*_BASE_URL` — one provider per machine because a single provider can
only point at one host. (Diagram and ports brought up to the removal of Ollama
on 2026-11-22.)

## Firewall Rules Needed

### Windows (Desktop)
- **Outbound**: Allow TCP 22 and 8090 to server IP (SSH, llama-server), TCP 8090 to node3
- No inbound model port: the desktop serves no models

### Ubuntu (Server)
- **Inbound**: Allow TCP 8090 from desktop + node3 IPs (below: "Limit the model ports to named hosts")
- **Inbound**: Allow TCP 22 from desktop IP (SSH)

### Windows (Third node)
- **Inbound**: Allow TCP 8090 from the LAN (OpenCode → its llama-server; the owner's step, [node3/README.md](../node3/README.md))

## Limit the model ports to named hosts

**Status (2026-11-13): written and tested against a stand-in `iptables`; not yet applied on the server.** Applying it is
the owner's step, because it needs `sudo`.

**The gap.** The server's llama-server (8090) takes no API key until [engine-api-keys.md](engine-api-keys.md) is
rolled out, and Docker publishes it on every interface (Ollama's 11434 was the same until its removal on 2026-11-21). Any device on the LAN can run inference and load or unload models. `ufw` does not close this: Docker routes
published ports through its own rules, "effectively ignoring your firewall configuration"
([Docker, "Packet filtering and firewalls"](https://raw.githubusercontent.com/docker/docs/main/content/manuals/engine/network/packet-filtering-firewalls.md)).

**The fix (owner, 2026-11-11): a firewall rule by host now, API keys before any VPN.**
`server/scripts/model-ports-firewall.sh` adds rules to the `DOCKER-USER` chain, the place Docker documents for rules
of your own, matched on the original destination port with the `conntrack` extension
([Docker, "Docker with iptables"](https://raw.githubusercontent.com/docker/docs/main/content/manuals/engine/network/firewall-iptables.md)).
Only the hosts you name reach 8090 from the LAN.

| Still works | Why |
|---|---|
| The desktop and node3 | They are the allowed hosts (`DESKTOP_IP`, `NODE3_IP` in `.env`, or `--allow`) |
| The server itself (`localhost:8090`) | It does not arrive on the LAN interface |
| The household chat (Open WebUI → 8090) | It reaches the engine over a Docker bridge, not the LAN interface |
| Grocy (9283) and the chat's web page (3000), from the phones | They are not model ports; the rule names 8090 only |

**Steps (on the server; the `sudo` ones are the owner's):**

1. Pull `main`. Check `.env` in the checkout has `DESKTOP_IP` and `NODE3_IP`.
2. Look before changing anything. This needs no root and changes nothing:
   ```bash
   server/scripts/model-ports-firewall.sh apply --dry-run
   ```
   It prints the `iptables` commands, with the interface it found from the default route. A wrong interface: add
   `--iface <name>`.
3. Apply it, and look at the result:
   ```bash
   sudo server/scripts/model-ports-firewall.sh apply
   sudo server/scripts/model-ports-firewall.sh status
   ```
4. **Check it from three places.** This is the test the stand-in cannot make.
   - **The desktop (allowed):** `curl.exe -s -m 5 http://<SERVER_IP>:8090/health` answers.
   - **A device that is not on the list** (a phone's browser, or node3 with its address left out for the test):
     `http://<SERVER_IP>:8090/health` times out, while `http://<SERVER_IP>:3000` still opens.
   - **The household chat:** `docker exec household-openwebui curl -s -m 5 http://host.docker.internal:8090/v1/models`
     still lists the models.
5. **IPv6.** The rule is IPv4 only. From a LAN device with an IPv6 address, try the server's IPv6 address:
   `curl -g -s -m 5 "http://[<server IPv6>]:8090/health"`. If it answers, tell the agent: that path needs its own rule.
6. **Make it survive a reboot.** The rules live in memory. Install the unit, which runs after Docker and again whenever
   Docker restarts (the commands are in its header):
   `server/systemd/model-ports-firewall.service`.
7. Record the date and what step 4 showed, here.

**Undo:** `sudo server/scripts/model-ports-firewall.sh remove` (and `sudo systemctl disable --now
model-ports-firewall.service` if the unit is installed). The ports are open to the LAN again.

**Not covered, on purpose or not yet:**
- **API keys** are a separate layer: [engine-api-keys.md](engine-api-keys.md) (llama-server only). With both, a host
  must be on the list *and* hold a key. Keys on the engines are a precondition of the VPN planned for the phones
  ([household-assistant.md](household-assistant.md)): a VPN peer is one more device on the network.
- **Ollama** had no API key; it was removed from the fleet on 2026-11-21 (still installed on each machine until the
  owner confirms the uninstall, and not serving). It must never be reachable over the VPN.
- **node3's own llama-server** gets a Windows firewall rule for the LAN range (`node3/README.md`), not per host.
- **Whether Docker keeps `DOCKER-USER` rules across its own restart** is not stated in the pages read, which is why the
  unit is tied to `docker.service`.

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

The server's llama-server binds `0.0.0.0:8090` inside its container (`server/docker/docker-compose.llamacpp.yml`).
node3's binds `127.0.0.1` until `start-llama-server.ps1 -Lan` ([node3/README.md](../node3/README.md)).

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
  `docker` group: llama-server, models, compose. Do not add a passwordless-sudo rule for convenience.
- **Server layout.** A checkout (or `git archive` extract) of this repo at `~/HomeLab`; the compose project there is
  named `docker`. The weights are GGUF files in `~/models`, mounted read-only into the llama-server container. The old
  Ollama volume `docker_ollama_data` is no longer mounted (its blobs were copied to `~/models` on 2026-11-21); deleting
  it is part of the Ollama uninstall, the owner's step.
  `~/dev-docs` is the pre-outage copy (Sep 2026, not a repo; this repo was called dev-docs before it was renamed HomeLab) and can be removed once nothing points at it.

## Verification

With a profile sourced (which loads `.env`):

```bash
# From desktop, test the server's llama-server (/health needs no API key)
curl.exe http://${SERVER_IP}:8090/health

# From desktop, test node3's llama-server (once it listens on the LAN)
curl.exe http://${NODE3_IP}:8090/health

# Test SSH
ssh ${SSH_USER}@${SERVER_IP}
```

OpenCode-side: `select-model.sh` offering the profile is the end-to-end check
that a provider can reach its node.