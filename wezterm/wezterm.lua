local wez = require("wezterm")
local act = wez.action
local config = wez.config_builder()

-- ============================================================
-- Server Connection
-- Update these to match your network
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
-- Launcher Menu (Ctrl+Shift+Space or the "+" in tabs)
-- ============================================================

config.launch_menu = {
    {
        label = "Windows PowerShell",
        args = { "powershell.exe", "-NoLogo", "-NoExit" },
    },
    {
        label = "PowerShell Core (7+)",
        args = { "pwsh.exe", "-NoLogo", "-NoExit" },
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

-- Default startup: connect to server via SSH
config.default_domain = "dev-server"

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
