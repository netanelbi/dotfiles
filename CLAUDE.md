# Dotfiles

Hyprland setup for CachyOS (Arch-based) managed with GNU Stow.

## Structure

Each folder is a stow package that symlinks to `~/.config/`:

```
package/.config/package/ -> ~/.config/package
```

## Packages

| Package | Description |
|---------|-------------|
| hypr | Hyprland, hyprlock, hypridle configs |
| waybar | Status bar (island style) |
| swaync | Notification center |
| swayosd | OSD for volume/brightness |
| kitty | Terminal emulator |
| rofi | Application launcher |
| fish | Fish shell config |
| starship | Prompt customization |
| fastfetch | System info display |
| btop | System monitor |
| gtk | GTK theme settings |
| qt | Qt theme settings |
| scripts | Utility scripts for Hyprland/Waybar |
| vivo | vivo (AMD/1200p Vivobook, the main driver) — AMD TDP scripts, keyboard RGB, Sunshine streaming, per-machine Hyprland/waybar fragments |
| lenovo | lenovo (Intel/1080p laptop) — per-machine Hyprland/waybar fragments | |

## Multi-machine model

This repo is single-branch (`master`); machine differences live in **stow packages**, not branches. Stow the shared packages plus your machine's package:

```bash
# on vivo (main driver):
stow hypr waybar swaync swayosd kitty rofi fish starship fastfetch btop gtk qt scripts vivo
# on lenovo:
stow hypr waybar swaync swayosd kitty rofi fish starship fastfetch btop gtk qt scripts lenovo
```

A file lives in **either** a shared package **or** a machine package (never both — stow would conflict). Files that differ per machine but both need use a shared base that `source`s/`include`s/`require`s a machine fragment (e.g. `hyprland.lua` requires `monitor.lua`/`machine.lua`). vivo-only extras (AMD TDP, keyboard RGB, Sunshine) live in `vivo/` so lenovo doesn't carry them.

## Install

```bash
cd ~/.dotfiles
stow hypr waybar swaync swayosd kitty rofi fish starship fastfetch btop gtk qt scripts vivo   # on vivo
# replace `vivo` with `lenovo` on the lenovo machine
```

## Uninstall a package

```bash
stow -D package_name
```

## Key Bindings

| Key | Action |
|-----|--------|
| `SUPER + Return` | Terminal (kitty) |
| `CTRL + ALT + T` | Terminal (alternative) |
| `CTRL + ALT + W` | Terminal in ~/Work |
| `SUPER + D` | Launcher (rofi) |
| `SUPER + Q` | Close window |
| `SUPER + SHIFT + Q` | Exit Hyprland |
| `SUPER + F` | Toggle floating |
| `SUPER + SHIFT + F` | Fullscreen |
| `SUPER + V` | Clipboard history (rofi) |
| `SUPER + L` | Lock screen |
| `SUPER + E` | File manager (Thunar) |
| `SUPER + ~` | Toggle scratchpad |
| `SUPER + S` | Move window to scratchpad |
| `SUPER + ALT + S` | Move to scratchpad silently |
| `SUPER + arrows` | Move focus (cycle floating windows if on floater) |
| `SUPER + SHIFT + arrows` | Swap window |
| `SUPER + CTRL + arrows` | Move workspace to monitor |
| `SUPER + Tab` | Focus next (like SUPER + right) |
| `SUPER + B` | Cycle power profile |
| `SUPER + C` | Screenshot focused window |
| `SUPER + SHIFT + S` | Screenshot selection |
| `SUPER + Print` | Screenshot selection to file |
| `Print` | Screenshot selection to clipboard |
| `SHIFT + Print` | Screenshot full screen |
| `SUPER + K` | Calculator (rofi) |
| `SUPER + R` | Resize window (cycle ratios) |
| `SUPER + Escape` | Power menu |
| `SUPER + . / ,` | Next/previous workspace |
| `SUPER + 1-0` | Switch workspace |
| `SUPER + SHIFT + 1-0` | Move window to workspace |

## Useful Commands

Reload waybar gracefully:
```bash
pkill -SIGUSR2 waybar
```

## Dependencies

```bash
sudo pacman -S hyprland hyprlock hypridle xdg-desktop-portal-hyprland \
  kitty rofi waybar swaync swww stow socat \
  grim slurp wl-copy cliphist jq pamixer
```

## Features

### Scratchpad Management
- **Visual indicator** in Waybar showing window count
- **Gold borders** and **dimmed opacity** for scratchpad windows
- **Event-based updates** - no polling, instant feedback
- **Smart arrow cycling** - `SUPER + arrows` cycles through floating windows when focused on one

### Window Display
- **Live window list** in Waybar showing active workspace windows
- **Focus indication** - focused window is bold and colored (purple for workspace, yellow for scratchpad)
- **Unfocused windows** shown in dim gray
- **Click to switch** - rofi menu to select window
- **Stable ordering** by PID
- **Pango markup** for per-window styling

### Event-Driven Architecture
All indicators use event sockets for real-time updates (no polling):
- `hypr-scratchpad-watch` - scratchpad window count and visibility (Hyprland socket)
- `hypr-windows-watch` - active workspace window list with focus tracking (Hyprland socket)
- `hypr-capslock-watch` - capslock state indicator (evtest events)

### Scripts Package
Located in `scripts/.local/bin/`:

**Hyprland helpers**
- `hypr-scratchpad-toggle` - Toggle scratchpad with notifications
- `hypr-scratchpad-move` - Move window to scratchpad with signal
- `hypr-scratchpad-cycle` - Cycle through scratchpad windows
- `hypr-scratchpad-watch` - Event-based scratchpad monitoring for waybar
- `hypr-floating-cycle` - Cycle through floating windows
- `hypr-focus-or-scratchpad` - Smart focus/cycle based on window type
- `hypr-windows-watch` - Event-based window list monitoring for waybar
- `hypr-capslock-watch` - Event-based capslock indicator for waybar
- `hypr-network-watch` - Event-based network indicator for waybar
- `hypr-zen-popup-watch` - Watch for Zen browser popup windows

**Power / thermal** (shared)
- `power-profile-cycle` - Cycle power profiles (mapped to `SUPER + B`); calls the
  optional `power-profile-tdp-hook` for per-profile TDP + freq-cap fix (vivo only)
- `power-profile-auto` - udev-triggered AC profile switch; same optional hook

**Power / thermal** (vivo-only, in the `vivo/` stow package)
- `fix-cpu-freq` - Toggle amd_pstate driver to clear 2GHz frequency cap on AC change
- `tdp` - ryzenadj TDP control
- `tdp-watch` - Event-based TDP indicator for waybar
- `power-profile-tdp-hook` - Per-profile ryzenadj TDP + `fix-cpu-freq`; called by
  `power-profile-auto`/`power-profile-cycle` when present (no-op on Intel)

**Streaming / misc** (vivo-only, in the `vivo/` stow package)
- `sunshine-prep` / `sunshine-unprep` - Switch monitor to 1920x1080@60 for Moonlight, restore native on disconnect
- `imv-dir` - Open imv with directory navigation

## Hyprland Lua config (0.56+)

Hyprland 0.56 added a Lua config manager and **`.conf` support is removed in 0.57**. The
compositor config is Lua: `hyprland.lua` requires `vars`/`monitor`/`input`/`machine`. The
`.conf` files are kept only as a rollback — Hyprland prefers `hyprland.lua` when present, so
reverting is `mv ~/.config/hypr/hyprland.lua{,.off}`.

Only the compositor moved. `hyprlock`/`hypridle`/`hyprsunset`/`xdph` are separate binaries
with their own hyprlang parsers and still use `.conf`.

### Verify before you restart
```bash
Hyprland --verify-config -c ~/.config/hypr/hyprland.lua
```
It is strict — unknown rule fields and config keys are errors, and dispatcher errors
enumerate the valid arguments. Always run it after editing; a Lua error that registers zero
binds trips **Emergency mode**, leaving only `SUPER + Q` bound.

### Gotchas
- **`package.path` comes from the file's realpath**, which under stow is
  `~/.dotfiles/hypr/.config/hypr/` — where the machine fragments deliberately do not live.
  `hyprland.lua` prepends `~/.config/hypr/?.lua` (the stow convergence point) so
  `require("machine")` picks up whichever machine package is stowed. Don't remove that line.
- **Long strings collide with shell `[[ ]]` tests.** A bind body containing `[[ $x -eq 1 ]]`
  terminates a `[[...]]` Lua literal early — use `[==[...]==]`.
- **Modifiers need `+` separators**: `SUPER + SHIFT + left`, not `SUPER SHIFT + left`.
- **Autostart goes in `hl.on("hyprland.start", ...)`**, not a bare `hl.exec_cmd` at top level —
  that keeps `exec-once` semantics, so `hyprctl reload` doesn't re-spawn daemons.

### Rule/dispatcher mapping
```lua
-- windowrule = float on, match:class myapp   ->  one rule carries all props:
hl.window_rule({ name = "myapp", match = { class = "myapp" },
    float = true, size = "800 600", pin = true,
    move = "(monitor_w-window_w-50) 50" })   -- expression vars still apply
```
Expression variables: `monitor_w`, `monitor_h`, `window_w`, `window_h`, `cursor_x`, `cursor_y`.
Match fields: `class`, `title`, `workspace` (`special:name` for special workspaces).

| hyprlang | Lua |
|---|---|
| `bind`/`binde`/`bindl`/`bindm` | `hl.bind(keys, dsp, { repeating/locked/mouse = true })` |
| `killactive` / `exit` | `hl.dsp.window.close()` / `hl.dsp.exit()` |
| `togglefloating` / `fullscreen` | `hl.dsp.window.float({action="toggle"})` / `hl.dsp.window.fullscreen()` |
| `workspace, N` / `movetoworkspace, N` | `hl.dsp.focus({workspace=N})` / `hl.dsp.window.move({workspace=N})` |
| `swapwindow, l` / `layoutmsg, x` | `hl.dsp.window.swap({direction="l"})` / `hl.dsp.layout("x")` |
| `focusurgentorlast` | `hl.dsp.focus({ urgent_or_last = true })` |
| `monitor =` / `workspace =` | `hl.monitor{}` / `hl.workspace_rule{}` |

The full API stub (autogenerated, 1777 lines) ships at `/usr/share/hypr/stubs/hl.meta.lua`;
a reference config at `/usr/share/hypr/hyprland.lua`.

## Development Guidelines

### Adding DE Configs/Scripts

**IMPORTANT**: All desktop environment setup, configs, and scripts must be managed through this stow repository.

1. **Create proper package structure**:
   ```bash
   mkdir -p newpkg/.config/newpkg  # for configs
   # OR
   mkdir -p newpkg/.local/bin      # for scripts
   ```

2. **Add your files** to the package directory

3. **Apply with stow**:
   ```bash
   stow newpkg
   ```

4. **Never install directly** to `~/.config/` or `~/.local/bin/` - always use stow

**Note:** Stow creates symlinks, so editing files in this repo updates the active config immediately — only re-run `stow <pkg>` when adding or removing files.

### Long-running daemons: systemd vs exec-once

Default is `exec-once`. Only move a daemon to a systemd user unit when there's a concrete reason (observed crash pattern needing `Restart=on-failure`, ordering dependencies, etc.) — see waybar (`680c261`) and sunshine for the precedents.

**Gotcha when you do migrate:** Upstream user units typically have `Requisite=graphical-session.target`, which Hyprland never raises. Drop-ins can't reset `Requisite=`, so ship a **full-file override** in the relevant stow package (e.g. `waybar/.config/systemd/user/waybar.service`) and start it from `exec-once = systemctl --user start <unit>`. Use `waybar.service` as the template.

### Event-Based Design

**CRITICAL**: Never use polling for status indicators or monitoring.

**Bad** (polling):
```bash
while true; do
    count=$(get_count)
    echo "$count"
    sleep 1  # ❌ Wasteful polling
done
```

**Good** (event-based):
```bash
socat -u "UNIX-CONNECT:$SOCKET" - | while read -r event; do
    case "$event" in
        relevant_event*)
            update_status  # ✅ Only updates on changes
            ;;
    esac
done
```

**Benefits**:
- Zero CPU waste
- Instant updates
- Scales to many indicators
- Proper event-driven architecture

### Waybar Custom Modules

For custom waybar modules with per-item styling:
1. Use **Pango markup** with `"escape": false` in config
2. Use **event-based exec** (no interval)
3. Return JSON with `text` and `class` fields
4. Use `<span foreground='#color' weight='bold'>text</span>` for styling

Example:
```json
"custom/mymodule": {
    "exec": "~/.local/bin/my-watch-script",
    "return-type": "json",
    "format": "{}",
    "escape": false
}
```

## Troubleshooting

### swaync silently steals the notifications
`/usr/share/dbus-1/services/org.erikreider.swaync.service` claims
`Name=org.freedesktop.Notifications`, so **any** notification sent while
Quickshell is down D-Bus-activates swaync, which then holds the name until it is
killed. Symptom: notifications look and behave differently after a Quickshell
restart, for no apparent reason. Blocked with:

```bash
systemctl --user mask swaync.service     # undo: systemctl --user unmask
```

Quickshell re-acquires the name on its own the moment swaync exits — it logs
"Registration will be attempted again if the active service is unregistered"
and means it. Check the current owner with:

```bash
busctl --user list | grep org.freedesktop.Notifications
```

### Layer-shell windows must not resize while animating
A layer surface that changes size has to wait for a compositor configure/ack
round trip before it may commit, so a `PanelWindow` whose `implicitHeight` is
bound to animating content does one round trip **per frame**. Measured on the
notification popups: a 180ms entrance took 467ms and rendered as five lurches
~100ms apart, at only ~2% CPU — the client was blocked, not busy. Size the
surface once and animate inside it; frames then land at a flat 16ms.

Diagnose by logging the window's `onImplicitHeightChanged` with `Date.now()` and
reading it back with `qs -p ~/.config/quickshell log -f` (note: that prints the
existing log before following, so compare against a line count taken first).

### Hyprland log
`/run/user/$UID/hypr/$HYPRLAND_INSTANCE_SIGNATURE/hyprland.log` — first stop for idle/inhibit/dpms diagnostics. Find via `find /run/user/$UID/hypr -name hyprland.log`.

### Idle / lock not firing
- hypridle uses `ext-idle-notify-v1` from Hyprland. Restart it (`pkill hypridle; hypridle & disown`) if its event subscription desyncs (e.g. after being SIGSTOP'd or paused for a long time).
- hypridle owns `org.freedesktop.ScreenSaver` D-Bus — confirm with `busctl --user list | grep -i screensaver`. Its interface exposes only `Inhibit`/`UnInhibit` (no list), so use `dbus-monitor --session "interface='org.freedesktop.ScreenSaver'"` to watch live inhibit calls.
- **Gotcha:** `hyprctl clients`'s `idleInhibitMode` field is the *windowrule* setting (`none`/`always`/`focus`/`fullscreen`), not actual Wayland idle-inhibit-v1 protocol state. A `null` value means "no rule set" — it does **not** indicate the client is inhibiting.
- Never `SIGSTOP` a Wayland client (hypridle, waybar, etc.) — events queue on its socket and the protocol state desyncs after `SIGCONT`. Use D-Bus inhibit instead.

