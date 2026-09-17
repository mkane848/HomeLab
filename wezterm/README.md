# WezTerm Configuration

WezTerm config for connecting to the Ubuntu server via SSH.

## Setup

1. Copy `wezterm.lua` to your WezTerm config directory:
   - Windows: `C:\Users\<username>\.wezterm.lua` (or `%APPDATA%\wezterm\wezterm.lua`)
   - Or use `WZTERM_CONFIG_DIR` env var

   From the dev-docs repo, use the sync script (keeps the repo template and the
   live desktop config in sync):

   ```powershell
   # from M:\Projects\dev-docs
   .\desktop\scripts\sync-wezterm.ps1
   ```

2. Update the SSH host/IP to match your server (edit `wezterm/wezterm.lua`,
   then re-run the sync script).

3. Optionally enable multiplexing for split pane layouts.

## SshDomain fields

`config.ssh_domains` entries support `name`, `username`, `remote_address`,
`default_prog`, `default_cwd`, `ssh_config`, `no_agent_auth`, etc. Note:

- **`port` is NOT a valid field.** Put the port in `remote_address`:
  `remote_address = "SERVER_IP:22"` (omit `:22` for the default).
- **`username`, not `remote_username`.** This is the SSH login user, same as
  the `SSH_USER` value in the dev-docs `.env`.

## Features

- SSH connection to server on startup
- Custom domain for quick reconnects
- Split pane layout for server + desktop monitoring

## Files

- `wezterm.lua` — main config scaffold (source of truth)
- `desktop/scripts/sync-wezterm.ps1` — deploys this template to `C:\Users\<username>\.wezterm.lua`