-- vivo (AMD/1200p Vivobook) monitor setup — required by hyprland.lua

-- External Dell - primary, left (can be DP-1 or DP-2 depending on port)
hl.monitor({ output = "desc:Dell Inc. DELL P2722H", mode = "1920x1080@60", position = "0x0", scale = 1 })
-- eDP-1 (laptop) - right of external
hl.monitor({ output = "eDP-1", mode = "1920x1200@60", position = "1920x0", scale = 1.5 })
-- Headless output for Sunshine streaming - created at startup, kept disabled until prep enables it
hl.monitor({ output = "HEADLESS-1", disabled = true })
-- Fallback for any other monitor
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

-- Workspace defaults
hl.workspace_rule({ workspace = "1", monitor = "desc:Dell Inc. DELL P2722H", default = true })
hl.workspace_rule({ workspace = "5", monitor = "eDP-1", default = true })
