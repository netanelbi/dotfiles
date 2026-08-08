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
    'hyprctl keyword monitor "eDP-1,1920x1080@60,0x0,1.3333"; ' ..
    'hyprctl keyword monitor "DP-2,1920x1080@60,auto-right,1"; ' ..
    'hyprctl reload'))

-- No TDP / no Sunshine on lenovo — SUPER+O cycles urgent/last instead of the vivo display toggle
hl.bind(mainMod .. " + O", hl.dsp.focus({ urgent_or_last = true }))
