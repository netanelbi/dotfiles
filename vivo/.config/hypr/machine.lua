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

-- SUPER + O ("server mode": lock + blank the panels) is GONE, along with
-- hypr-display-toggle. It drove `dpms off`, and "all displays off" is the state
-- that arms IPS2 on this DCN 3.5 part and hard-resets the machine -- three times
-- on 2026-09-23 alone (memory: amdgpu_dpms_reboot). No kernel flag both guards
-- it and keeps deep sleep, so the trigger was removed instead of mitigated.
-- To blank the panel now: `brightnessctl --save set 0`, restore with --restore.

-- Push-to-talk: hold right Alt, speak, release. Voice capsule (Ori), not
-- dictation — the message lands in Ori's session marked [voice]; whether Ori
-- answers out loud is Ori's call, not the keybind's. Capsule IPC lives in
-- quickshell assistant/Voice.qml. ignore_mods because Alt_R IS the ALT
-- modifier while held; release=true fires the send on key-up.
-- Alt_R, NOT R_ALT: R_ALT fails as `Unknown keysym` in hl.bind on this build
-- (verified 2026-09-20 — and it stayed latent for a while because a stale real
-- ~/.config/hypr/machine.lua shadowed this symlink, so the broken name was never
-- loaded). Both binds are dead with the wrong spelling, silently.
hl.bind("Alt_R", hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call voice start"), { ignore_mods = true, non_consuming = true })
hl.bind("Alt_R", hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call voice stop"),  { release = true, ignore_mods = true, non_consuming = true })

-- dictation (typed into the focused app) retired 2026-09-06 — right Alt now
-- belongs to the voice capsule. ptt script kept in vivo/.local/bin for revival.
-- hl.bind("Alt_R", hl.dsp.exec_cmd("~/.local/bin/ptt down"), { ignore_mods = true, non_consuming = true })
-- hl.bind("Alt_R", hl.dsp.exec_cmd("~/.local/bin/ptt up"),   { release = true, ignore_mods = true, non_consuming = true })
-- fallback: hold Alt+Space instead
-- hl.bind("ALT + Space", hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call voice start"), { non_consuming = true })
-- hl.bind("ALT + Space", hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call voice stop"),  { release = true, non_consuming = true })
