local wez = require("wezterm")
local act = wez.action
local config = wez.config_builder()

-- ============================================================
-- Server Connection (on demand)
-- YOUR_USER and SERVER_IP below are placeholders: desktop\scripts\sync-wezterm.ps1
-- fills them in from SSH_USER and SERVER_IP in .env when it deploys this file.
-- ============================================================

config.ssh_domains = {
    {
        name = "dev-server",
        username = "YOUR_USER",
        -- Use IP or hostname of your Ubuntu server; add :port if not 22
        remote_address = "SERVER_IP:22",
    },
}

-- ============================================================
-- Default shell: a local PowerShell 7
-- Opening WezTerm must not wait on, or fail because of, the server (it used to
-- connect to it on every launch). The server is one keypress away (Leader, then
-- s) or the first entry of the launcher menu.
-- ============================================================

config.default_prog = { "pwsh.exe", "-NoLogo" }

-- ============================================================
-- Launcher Menu (Ctrl+Shift+Space or the "+" in tabs)
-- ============================================================

config.launch_menu = {
    {
        label = "Server (SSH)",
        domain = { DomainName = "dev-server" },
    },
    {
        label = "PowerShell Core (7+)",
        args = { "pwsh.exe", "-NoLogo", "-NoExit" },
    },
    {
        label = "Windows PowerShell",
        args = { "powershell.exe", "-NoLogo", "-NoExit" },
    },
}

-- ============================================================
-- Multiplexing (split panes)
-- ============================================================

config.unix_domains = {
    {
        name = "unix",
    },
}

-- ============================================================
-- Appearance
-- ============================================================

config.color_scheme = "Tokyo Night"
config.font = wez.font("JetBrains Mono", { weight = "Medium" })
config.font_size = 11.0
config.window_background_opacity = 0.95

-- ============================================================
-- Keybindings
-- ============================================================

config.keys = {
    -- A new tab on the server (SSH)
    { key = "s", mods = "LEADER", action = act.SpawnTab({ DomainName = "dev-server" }) },
    -- Quick split: horizontal
    {
        key = "-",
        mods = "LEADER",
        action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }),
    },
    -- Quick split: vertical
    {
        key = "\\",
        mods = "LEADER",
        action = act.SplitVertical({ domain = "CurrentPaneDomain" }),
    },
    -- Navigate panes with arrow keys
    { key = "LeftArrow",  mods = "LEADER", action = act.ActivatePaneDirection("Left") },
    { key = "RightArrow", mods = "LEADER", action = act.ActivatePaneDirection("Right") },
    { key = "UpArrow",    mods = "LEADER", action = act.ActivatePaneDirection("Up") },
    { key = "DownArrow",  mods = "LEADER", action = act.ActivatePaneDirection("Down") },
}

-- Leader key (double-tap Ctrl+Space)
config.leader = { key = "Space", mods = "CTRL" }

return config
