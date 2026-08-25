-- Hyprland Config (shared)
-- Machine-specific monitor/input/environment/cursor/gaps/keybind bits live in
-- fragments provided by the machine's stow package (vivo/ or lenovo/).
-- See CLAUDE.md "Multi-machine model".

-- Hyprland derives package.path from this file's REALPATH, which under stow is
-- ~/.dotfiles/hypr/.config/hypr/ — where the machine fragments deliberately do
-- not live. Search the stow convergence point instead, so monitor/machine
-- resolve to whichever machine package is currently stowed.
package.path = os.getenv("HOME") .. "/.config/hypr/?.lua;" .. package.path

local v        = require("vars")
local mainMod  = v.mainMod
local terminal = v.terminal

require("monitor")
require("input")
require("machine")

-- Autostart
hl.on("hyprland.start", function()
    hl.exec_cmd("xrdb ~/.Xresources")
    hl.exec_cmd("hyprlock")
    -- restart (not start): the user manager lingers across SUPER+SHIFT+Q, so a stale
    -- waybar from the previous Hyprland instance can stay active and `start` would
    -- no-op — leaving hyprland/workspaces bound to the dead IPC socket (frozen
    -- workspace numbers until reboot). restart always rebinds to the live session.
    -- Quickshell replaces waybar + swaync + swayosd + awww in ONE process:
    -- the bar, notifications, the OSD, the wallpaper and the rofi replacements
    -- all live in ~/.config/quickshell. hypridle stays (below) because it owns
    -- the org.freedesktop.ScreenSaver D-Bus name and Quickshell exposes no way
    -- to register one.
    --
    -- To fall back, comment this line out and uncomment the four below it.
    hl.exec_cmd("quickshell -n -p ~/.config/quickshell")

    -- hl.exec_cmd("systemctl --user restart waybar.service")
    -- hl.exec_cmd("swaync")
    -- hl.exec_cmd("awww-daemon &")
    -- hl.exec_cmd("sleep 1 && awww img /usr/share/hypr/wall2.png")
    -- restart (not start): same lingering-user-manager trap as waybar — a stale
    -- hypridle from a previous Hyprland instance stays active, so `start` no-ops and
    -- it keeps polling a dead compositor (idle locks dead; before_sleep_cmd's hyprlock
    -- can't bind ext-session-lock-v1 → lid-close suspends WITHOUT locking).
    hl.exec_cmd("systemctl --user restart hypridle.service")

    -- Monitor hotplug - reapply wallpaper on connect, switch to workspace 1 on disconnect
    hl.exec_cmd("~/.local/bin/hypr-monitor-handler")
    -- hl.exec_cmd("swayosd-server")   -- replaced by Quickshell's OSD
    hl.exec_cmd("wl-paste --type text --watch cliphist store")
    hl.exec_cmd("wl-paste --type image --watch cliphist store")
    hl.exec_cmd("~/.local/bin/hypr-zen-popup-watch")
    hl.exec_cmd("~/.local/bin/usb-suspend-guard")
end)

-- Environment (shared) — XCURSOR_* is machine-specific (see machine.lua)
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
hl.env("TERMINAL", "kitty")

hl.config({
    -- XWayland scaling - let Hyprland handle it
    -- DPI set to 96 (standard), Hyprland scales per-monitor
    xwayland = {
        force_zero_scaling = true,
    },

    misc = {
        mouse_move_enables_dpms = true,
        key_press_enables_dpms  = true,
    },

    -- Look and feel - Catppuccin Mocha (gaps_out is machine-specific; see machine.lua)
    general = {
        gaps_in     = 5,
        border_size = 2,
        col = {
            active_border   = { colors = { "rgba(cba6f7ee)", "rgba(89b4faee)" }, angle = 45 },
            inactive_border = "rgba(585b70aa)",
        },
        layout = "dwindle",
    },

    decoration = {
        rounding = 10,
        blur = {
            enabled = true,
            size    = 3,
            passes  = 1,
        },
        shadow = {
            enabled      = true,
            range        = 20,
            render_power = 3,
            color        = "rgba(00000080)",
        },
    },

    animations = {
        enabled = true,
    },

    dwindle = {
        preserve_split = true,
    },
})

hl.curve("myBezier", { type = "bezier", points = { { 0.05, 0.9 }, { 0.1, 1.05 } } })

hl.animation({ leaf = "windows",          enabled = true, speed = 7, bezier = "myBezier" })
hl.animation({ leaf = "windowsOut",       enabled = true, speed = 7, bezier = "default", style = "popin 80%" })
hl.animation({ leaf = "border",           enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "fade",             enabled = true, speed = 7, bezier = "default" })
hl.animation({ leaf = "workspaces",       enabled = true, speed = 6, bezier = "default" })
hl.animation({ leaf = "specialWorkspace", enabled = true, speed = 6, bezier = "default", style = "slidevert" })

---------------------
---- KEYBINDINGS ----
---------------------

-- Lid switch - disable laptop display when closed, but ONLY when docked.
-- Disabling the last monitor crashes Hyprland 0.55 (unsafe-state headless
-- transition segfault); undocked, logind's HandleLidSwitch=suspend handles it.
-- eDP re-enable resolution is machine-specific (see lid-switch.env).
hl.bind("switch:on:Lid Switch",  hl.dsp.exec_cmd("~/.local/bin/hypr-lid-switch close"), { locked = true })
hl.bind("switch:off:Lid Switch", hl.dsp.exec_cmd("~/.local/bin/hypr-lid-switch open"),  { locked = true })

-- Apps
hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind("CTRL + ALT + T",       hl.dsp.exec_cmd(terminal))
hl.bind("CTRL + ALT + W",       hl.dsp.exec_cmd(terminal .. " --working-directory ~/Work"))
hl.bind(mainMod .. " + D",      hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call apps toggle"))
hl.bind(mainMod .. " + E",      hl.dsp.exec_cmd("thunar"))

-- Window management
hl.bind(mainMod .. " + Q",         hl.dsp.window.close())
hl.bind(mainMod .. " + SHIFT + Q", hl.dsp.exit())
hl.bind(mainMod .. " + F",         hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + SHIFT + F", hl.dsp.window.fullscreen())
hl.bind(mainMod .. " + J",         hl.dsp.layout("togglesplit"))

-- Move focus (or cycle scratchpad if in scratchpad)
for key, dir in pairs({ left = "l", right = "r", up = "u", down = "d" }) do
    hl.bind(mainMod .. " + " .. key, hl.dsp.exec_cmd("~/.local/bin/hypr-focus-or-scratchpad " .. dir))
    -- Swap windows
    hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.swap({ direction = dir }))
end
hl.bind(mainMod .. " + Tab", hl.dsp.exec_cmd("~/.local/bin/hypr-focus-or-scratchpad r"))

-- Move workspace to other monitor
hl.bind(mainMod .. " + CTRL + left",  hl.dsp.exec_cmd([==[hyprctl dispatch "hl.dsp.workspace.move({ workspace = $(hyprctl activeworkspace -j | jq .id), monitor = '-1' })"]==]))
hl.bind(mainMod .. " + CTRL + right", hl.dsp.exec_cmd([==[hyprctl dispatch "hl.dsp.workspace.move({ workspace = $(hyprctl activeworkspace -j | jq .id), monitor = '+1' })"]==]))

-- Cycle workspaces
hl.bind(mainMod .. " + period",         hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + comma",          hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mainMod .. " + SHIFT + period", hl.dsp.window.move({ workspace = "e+1" }))
hl.bind(mainMod .. " + SHIFT + comma",  hl.dsp.window.move({ workspace = "e-1" }))

-- Workspaces / move to workspace
for i = 1, 10 do
    local key = i % 10 -- 10 maps to key 0
    hl.bind(mainMod .. " + " .. key,             hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. key,     hl.dsp.window.move({ workspace = i }))
end

-- Mouse bindings
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Screenshots
hl.bind("Print",                    hl.dsp.exec_cmd('grim -g "$(slurp)" - | wl-copy'))
hl.bind("SHIFT + Print",            hl.dsp.exec_cmd('grim - | wl-copy && notify-send "Screenshot" "Full screen captured!"'))
hl.bind(mainMod .. " + SHIFT + S",  hl.dsp.exec_cmd('grim -g "$(slurp)" - | wl-copy'))
hl.bind(mainMod .. " + Print",      hl.dsp.exec_cmd('grim -g "$(slurp)" ~/Pictures/$(date +%Y%m%d_%H%M%S).png'))
hl.bind(mainMod .. " + C",          hl.dsp.exec_cmd([[grim -g "$(hyprctl activewindow -j | jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')" - | wl-copy && notify-send "Screenshot" "Window captured!"]]))

-- Screenshot with flash effect
-- Runtime option writes are `hyprctl eval` + hl.config(), NOT `hyprctl keyword` —
-- the Lua provider rejects keyword outright, so the flash silently never fired.
-- Restores dim_strength to 0.5 (the configured value), not 0, which is what the
-- keyword version would have left behind had it ever run.
hl.bind(mainMod .. " + SHIFT + Print", hl.dsp.exec_cmd(
  'grim - | wl-copy && ' ..
  'hyprctl eval \'hl.config({ decoration = { dim_strength = 1 } })\' >/dev/null && ' ..
  'sleep 0.1 && ' ..
  'hyprctl eval \'hl.config({ decoration = { dim_strength = 0.5 } })\' >/dev/null && ' ..
  'notify-send "Screenshot" "Full screen captured!"'))

-- Clipboard history (with image preview, Alt+P to preview image)
hl.bind(mainMod .. " + V", hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call clipboard toggle"))

-- Lock screen
hl.bind(mainMod .. " + L", hl.dsp.exec_cmd("hyprlock"))

-- Stay awake: hold a logind block inhibitor so a lid close does not suspend.
-- Waybar shows a coffee cup (modules-center) while it is held.
hl.bind(mainMod .. " + SHIFT + L", hl.dsp.exec_cmd("~/.local/bin/stay-awake toggle"))

-- Scratchpad
hl.bind(mainMod .. " + grave",     hl.dsp.exec_cmd("~/.local/bin/hypr-scratchpad-toggle"))
hl.bind(mainMod .. " + S",         hl.dsp.exec_cmd("~/.local/bin/hypr-scratchpad-move"))
hl.bind(mainMod .. " + ALT + S",   hl.dsp.exec_cmd("~/.local/bin/hypr-scratchpad-move silent"))

-- Power profile toggle
hl.bind(mainMod .. " + B", hl.dsp.exec_cmd("~/.local/bin/power-profile-cycle"))

-- Brightness controls (with OSD)
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call osd brightness raise"), { repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call osd brightness lower"), { repeating = true })

-- Volume controls (with OSD)
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call osd outputVolume raise"), { repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call osd outputVolume lower"), { repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call osd outputVolume mute-toggle"))
hl.bind("XF86AudioMicMute",     hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call osd inputVolume mute-toggle"))

-- Emoji picker (overrides bluetooth toggle on Fn+emoji key)
hl.bind("XF86Bluetooth", hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call emoji toggle"))

-- Calculator (live results)
hl.bind(mainMod .. " + K", hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call calc toggle"))

-- Resize cycle (tiled: 33%->50%->67%, floating: 90% centered)
-- Percent sizes have no typed equivalent in the 0.55+ Lua dispatchers (x/y are
-- numeric px), so the monitor's logical size is resolved here and the resize is
-- issued in pixels.
hl.bind(mainMod .. " + R", hl.dsp.exec_cmd([==[bash -c 'w=$(hyprctl activewindow -j); [[ "$w" == "null" ]] && exit; read mw mh < <(hyprctl monitors -j | jq -r "first(.[]|select(.focused)) | [(.width/.scale|floor),(.height/.scale|floor)] | @tsv"); [[ -z "$mw" ]] && exit; if [[ $(echo "$w"|jq ".floating") == "true" ]]; then hyprctl dispatch "hl.dsp.window.resize({ x = $((mw*90/100)), y = $((mh*80/100)) })" && hyprctl dispatch "hl.dsp.window.center()"; else f=/tmp/hypr-resize-state; r=$(cat $f 2>/dev/null); case $r in 33) r=50;; 50) r=67;; *) r=33;; esac; echo $r > $f; hyprctl dispatch "hl.dsp.window.resize({ x = $((mw*r/100)), y = $((mh*r/100)) })"; fi']==]))

-- Power menu
hl.bind(mainMod .. " + Escape", hl.dsp.exec_cmd("qs -p ~/.config/quickshell ipc call power toggle"))

----------------------
---- WINDOW RULES ----
----------------------

-- Prevent idle lock for games (gamepad input doesn't reset idle timer)

hl.window_rule({ name = "idle-inhibit-steam",     match = { class = "^steam_app" }, idle_inhibit = "always" })
hl.window_rule({ name = "idle-inhibit-gamescope", match = { class = "^gamescope" }, idle_inhibit = "always" })

hl.window_rule({ name = "floating-generic", match = { class = "floating" },
    float = true, size = "500 400", center = true })
hl.window_rule({ name = "pavucontrol", match = { class = "org.pulseaudio.pavucontrol" },
    float = true, size = "600 500" })
hl.window_rule({ name = "nm-connection-editor", match = { class = "nm-connection-editor" },
    float = true, size = "500 400" })

-- Top-right dropdown popups (blueman / wifi / bluetooth / audio)
local function popup(name, class, w, h, accent)
    hl.window_rule({
        name  = name,
        match = { class = class },

        float        = true,
        size         = "(monitor_w*" .. w .. ") (monitor_h*" .. h .. ")",
        move         = "(monitor_w*0.98-window_w) (monitor_h*0.075)",
        opacity      = "0.95 0.9",
        rounding     = 16,
        border_color = "rgba(" .. accent .. ") rgba(" .. accent .. ")",
        pin          = true,
    })
end

popup("blueman", "blueman-manager", 0.35, 0.5,  "89b4faee")
popup("impala",  "impala-popup",    0.55, 0.6,  "a6e3a1ee")
popup("bluetui", "bluetui-popup",   0.55, 0.5,  "89b4faee")
popup("wiremix", "wiremix-popup",   0.55, 0.5,  "cba6f7ee")

-- Media viewers (float, no forced size - respect media dimensions)
hl.window_rule({ name = "mpv", match = { class = "^mpv$" }, float = true, center = true })
hl.window_rule({ name = "imv", match = { class = "^imv$" }, float = true, center = true })

-- File picker dialogs
hl.window_rule({
    name  = "file-pickers",
    match = { title = "^(Open File|Save File|Open Folder|Select Folder|Choose Files|Enter name of file)" },
    float = true, center = true, size = "900 600",
})

-- Scratchpad rules
hl.window_rule({
    name  = "scratchpad",
    match = { workspace = "special:magic" },
    size         = "80% 80%",
    border_color = "rgba(f9e2afee) rgba(f9e2afee)",
})
