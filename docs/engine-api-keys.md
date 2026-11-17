# API keys on the model engines (llama-server)

Written 2026-11-17. It closes the audit's "API keys on the engines" item ([audit-2026-11-09.md](audit-2026-11-09.md)),
the precondition of the VPN planned for the phones. **Repo side done; not yet rolled out** (the owner's steps below).

## What changes

`llama-server` on the server (Docker, router mode) and on node3 starts with `--api-key-file`. From then on it answers
only `/health` (and its built-in web page) without a key. Every other path answers **HTTP 401** without
`Authorization: Bearer <key>`: `/props`, `/models`, `/models/load|unload`, `/v1/...`. This was read in llama.cpp's
[server-http.cpp](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/server-http.cpp) (the public paths
are `/health` and `/v1/health`) and [arg.cpp](https://github.com/ggml-org/llama.cpp/blob/master/common/arg.cpp)
(`--api-key-file`: one key per line, `#` lines are comments), on 2026-11-17, at master. In router mode the router
checks the key and starts its children without one, on loopback
([server-models.cpp](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/server-models.cpp)). **The pinned
builds (b11561 on the server, b11562 on node3) are older than that read:** step 6 is what proves them.

**Ollama has no API key.** It stays LAN-only behind the firewall rules ([network-topology.md](network-topology.md)) and
must never be reachable over a VPN.

## Two keys

| Key | Where it lives | Who sends it |
|---|---|---|
| **fleet** | the desktop and node3: `~/.config/opencode/.secrets/llamacpp-api-key`. The server: the **first** key line of `~/.config/llamacpp/api-key` | OpenCode (the `llamacpp-*` providers, `{file:.secrets/llamacpp-api-key}`), the harness and its tools (`tests/engines/llamacpp-auth.ps1`), the server's scripts (`server/scripts/llamacpp-auth.sh`, `llamacpp_check.py`) |
| **household** | the server: the **second** key line of `~/.config/llamacpp/api-key`, and `LLAMACPP_HOUSEHOLD_KEY` in `server/docker/.env` | Open WebUI (`OPENAI_API_KEY` in `docker-compose.household.yml`) |

- **Two keys so either can be revoked alone.** A leaked household key is replaced without touching the fleet's.
- **node3 serves only the fleet key:** the household chat does not use node3.
- **The rules:**
  - Every file is mode 600 (Windows: the user's profile), outside the repo.
  - No key is printed, logged, pasted into chat, or put on a command line. The bash helper passes it to curl through a
    file descriptor.

## How each piece finds its key

| Piece | First match wins |
|---|---|
| PowerShell (`tests/engines/llamacpp-auth.ps1`) | `$env:LLAMACPP_API_KEY`, then `$env:LLAMACPP_API_KEY_FILE`, then `~/.config/opencode/.secrets/llamacpp-api-key` |
| bash (`server/scripts/llamacpp-auth.sh`) and `llamacpp_check.py` | `$LLAMACPP_API_KEY`, then `$LLAMACPP_API_KEY_FILE` (or `--key-file`), then `~/.config/llamacpp/api-key` |
| OpenCode | the file, through `{file:.secrets/llamacpp-api-key}`. **A missing file makes the whole config invalid**, as with `opencode-go-api-key` |
| llama-server, server | compose secret `llamacpp_api_key` ← `${LLAMACPP_API_KEY_FILE:-$HOME/.config/llamacpp/api-key}` |
| llama-server, node3 | `node3/scripts/start-llama-server.ps1 -KeyFile` (default: the OpenCode secrets file). `-Lan` refuses to start without it |
| Open WebUI | `OPENAI_API_KEY` seeds a **new** install only. The running chat keeps its connection in its database (Open WebUI's persistent config, [config.py](https://github.com/open-webui/open-webui/blob/main/backend/open_webui/config.py) `openai.api_keys`), so step 5 sets it once in the UI |

## Safety nets: a key that did not take is caught, not found later

- **The server's healthcheck** fails (container unhealthy) when `/props` answers without a key.
- **`llamacpp-check.sh --url`** has an `auth` check:
  - **FAIL** when `/props` answers without a key, when our key is refused, or when the server wants a key and none
    was found;
  - **WARN** when there is no key on either side.
- **node3's `start-llama-server.ps1`** stops the server and exits 1 if `/props` answers without the key.
- **The server's systemd unit** refuses to start without the key file (`ExecStartPre=test -s ...`). `docker compose`
  itself does not check that a secret's file exists.
- **The harness** names the cause when `/props` answers 401: "no or wrong API key" appears in the engine version line,
  not "unreachable".

## Rollout (the owner, with an agent on the desktop)

Clients first, then the servers. Sending a key to a server that has none is harmless; the reverse breaks every client.

1. **The fleet key, on the desktop** (pwsh; prints nothing):
   ```powershell
   $f = "$HOME\.config\opencode\.secrets\llamacpp-api-key"
   if (-not (Test-Path $f)) { [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLower() | Set-Content -NoNewline $f }
   ```
2. **node3:** `desktop\scripts\sync-opencode.ps1 -Push node3 -Secrets llamacpp-api-key`.
3. **The server's key file.** The fleet key is copied from the desktop; the household key is made on the server. Over
   ssh, as the server user:
   ```bash
   mkdir -p ~/.config/llamacpp && chmod 700 ~/.config/llamacpp
   # from the desktop: scp "$HOME/.config/opencode/.secrets/llamacpp-api-key" server:.config/llamacpp/fleet.tmp
   { echo "# fleet"; cat ~/.config/llamacpp/fleet.tmp; echo; echo "# household"; openssl rand -hex 32; } > ~/.config/llamacpp/api-key
   rm ~/.config/llamacpp/fleet.tmp && chmod 600 ~/.config/llamacpp/api-key
   # Open WebUI's copy of the household key, in the git-ignored compose .env (prints nothing):
   echo "LLAMACPP_HOUSEHOLD_KEY=$(grep -v '^#' ~/.config/llamacpp/api-key | sed -n 2p)" >> ~/HomeLab/server/docker/.env
   ```
4. **Pull `main` everywhere:** the desktop and node3 (OpenCode's config: `sync-opencode.ps1`), then the server. Then
   check that OpenCode still starts on both PCs: the key file has to exist before the config that names it.
5. **Open WebUI's connection** (persistent config): in the chat, open Admin → Settings → Connections. On the
   `http://host.docker.internal:8090/v1` connection, paste the household key (from the server: `sed -n` as in step 3,
   into your clipboard, not the chat). Then `docker compose -p household -f server/docker/docker-compose.household.yml up -d`.
6. **Turn the keys on, and prove them:**
   - **Server:** `docker compose -f server/docker/docker-compose.llamacpp.yml up -d`, then:
     - `server/scripts/llamacpp-check.sh --url http://localhost:8090` must show `[OK] auth refuses requests without a
       key (401) and accepts ours`;
     - `docker inspect --format '{{.State.Health.Status}}' <container>` must be `healthy`.
     - If the systemd unit is installed, re-install it from `server/systemd/` (sudo) for the `ExecStartPre` check.
   - **node3:** `pwsh -File node3\scripts\start-llama-server.ps1 -Lan` must end with `API key on (401 without it,
     checked)`.
   - **Clients:**
     - one OpenCode prompt on a `llamacpp-*` seat from the desktop;
     - `tests\test-toolcalls.ps1 -Engine llamacpp ...` on one model;
     - one household chat question, which proves the household key.
7. **Record** the date and what step 6 showed under "Rolled out", below.

**Undo:** check out the previous `server/docker/docker-compose.llamacpp.yml` (git) and `up -d`, and start node3 with
`-NoKey`. Clients that send a key keep working against a server without one.

## Rolled out

*(date, by whom, what step 6 showed)*
