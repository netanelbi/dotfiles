-- lenovo (Intel/1080p laptop) machine-specific Hyprland settings — required by hyprland.lua

local mainMod = require("vars").mainMod

-- Cursor + environment (no custom cursor theme on this panel)
hl.env("XCURSOR_SIZE", "24")

hl.config({
    -- Gaps (asymmetric — top smaller to clear the bar)
    general = {
        gaps_out = { top = 4, right = 6, bottom = 6, left = 6 },
    },
})

-- Rescue: force physical displays back on (e.g. if a Sunshine stream left them
-- disabled — not used on lenovo, but harmless to keep as a recovery keybind).
hl.bind(mainMod .. " + ALT + D", hl.dsp.exec_cmd(
    -- eval + hl.monitor, not keyword: the Lua parser rejects keyword outright.
    'hyprctl eval \'hl.monitor({ output = "eDP-1", mode = "1920x1080@60", position = "0x0", scale = 1.3333, disabled = false })\'; ' ..
    'hyprctl eval \'hl.monitor({ output = "DP-2", mode = "1920x1080@60", position = "auto-right", scale = 1, disabled = false })\'; ' ..
    'hyprctl reload'))

-- No TDP / no Sunshine on lenovo — SUPER+O cycles urgent/last instead of the vivo display toggle
hl.bind(mainMod .. " + O", hl.dsp.focus({ urgent_or_last = true }))
