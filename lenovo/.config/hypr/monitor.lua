-- lenovo (Intel/1080p laptop) monitor setup — required by hyprland.lua

-- eDP-1 (laptop) - primary at origin, native 1920x1080 (16:9 panel)
hl.monitor({ output = "eDP-1", mode = "1920x1080@60", position = "0x0", scale = 1.3333 })
-- External Dell - auto-placed to the right of the laptop when docked (can be DP-1 or DP-2)
hl.monitor({ output = "desc:Dell Inc. DELL P2722H", mode = "1920x1080@60", position = "auto-right", scale = 1 })
-- Fallback for any other monitor
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

-- Workspace defaults
hl.workspace_rule({ workspace = "1", monitor = "eDP-1", default = true })
hl.workspace_rule({ workspace = "5", monitor = "eDP-1", default = true })
