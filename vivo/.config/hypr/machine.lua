-- vivo (AMD/1200p Vivobook) machine-specific Hyprland settings — required by hyprland.lua

local mainMod = require("vars").mainMod

-- Cursor + environment
hl.env("XCURSOR_SIZE", "32")
hl.env("XCURSOR_THEME", "Catppuccin-Mocha-Mauve-Cursors")

hl.config({
    cursor = {
        -- Software cursor so the pointer is composited into the framebuffer and
        -- thus captured by screen sharing (hardware cursor lives on a separate
        -- overlay plane that screencasts miss). See `laser-pointer` script.
        no_hardware_cursors = true,
    },

    -- Gaps
    general = {
        gaps_out = 6,
    },
})

-- Sunshine streaming (vivo-only): stream workspace + headless output autostart
hl.workspace_rule({ workspace = "name:stream", monitor = "HEADLESS-1" })

hl.on("hyprland.start", function()
    hl.exec_cmd("hyprctl output create headless")
    hl.exec_cmd("systemctl --user start sunshine")
end)

hl.bind(mainMod .. " + M", hl.dsp.focus({ workspace = "name:stream" }))

-- Displays off / PC up ("server mode"): on -> lock + DPMS off; off -> wake.
-- locked so it fires while locked — that's the deliberate way back on.
-- NOTE: dpms-off hard-reboots the box on kernel 7.1.1 (amdgpu DCN/DMUB hang on
-- external DP-2). Rolled back to 7.0.12 (pinned in pacman.conf) where it's safe.
hl.bind(mainMod .. " + O", hl.dsp.exec_cmd("~/.local/bin/hypr-display-toggle"), { locked = true })

-- Push-to-talk STT: hold right Alt, speak, release — text is typed into the
-- focused app by ydotool. release=true fires the transcribe on key-up;
-- ignore_mods because Alt_R is itself the ALT modifier when held.
-- MODEL=turbo for Hebrew-grade (~4 s after release), default moonshine-tiny
-- (~0.5 s after release, English-grade, 2x faster than whisper tiny). Fallback below uses Alt+Space in case Alt_R as a bare key
-- doesn't fire — comment out whichever loses.
hl.bind("Alt_R", hl.dsp.exec_cmd("~/.local/bin/ptt down"), { ignore_mods = true, non_consuming = true })
hl.bind("Alt_R", hl.dsp.exec_cmd("~/.local/bin/ptt up"),   { release = true, ignore_mods = true, non_consuming = true })

-- fallback: hold Alt+Space instead
-- hl.bind("ALT + Space", hl.dsp.exec_cmd("~/.local/bin/ptt down"), { non_consuming = true })
-- hl.bind("ALT + Space", hl.dsp.exec_cmd("~/.local/bin/ptt up"),   { release = true, non_consuming = true })
