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
| quickshell | The whole desktop shell: bar, notifications, OSD, wallpaper, launchers |
| kitty | Terminal emulator |
| fish | Fish shell config |
| starship | Prompt customization |
| fastfetch | System info display |
| btop | System monitor |
| gtk | GTK theme settings |
| qt | Qt theme settings |
| scripts | Utility scripts for Hyprland/Waybar |
| vivo | vivo (AMD/1200p Vivobook, the main driver) — AMD TDP scripts, keyboard RGB, Sunshine streaming, per-machine Hyprland/waybar fragments |
| lenovo | lenovo (Intel/1080p laptop) — per-machine Hyprland/waybar fragments | |

**Retired:** `waybar`, `swaync`, `swayosd`, `rofi`. Quickshell replaced all four.
The packages are unstowed and the binaries uninstalled (along with `awww`,
`rofi-calc`, `rofi-emoji`). The `pre-quickshell` tag is the rollback point --
it still holds the machine waybar configs, which were deleted from `vivo/` and
`lenovo/` here.

## Multi-machine model

This repo is single-branch (`master`); machine differences live in **stow packages**, not branches. Stow the shared packages plus your machine's package:

```bash
# on vivo (main driver):
stow hypr quickshell kitty fish starship fastfetch btop gtk qt scripts vivo
# on lenovo:
stow hypr quickshell kitty fish starship fastfetch btop gtk qt scripts lenovo
```

A file lives in **either** a shared package **or** a machine package (never both — stow would conflict). Files that differ per machine but both need use a shared base that `source`s/`include`s/`require`s a machine fragment (e.g. `hyprland.lua` requires `monitor.lua`/`machine.lua`). vivo-only extras (AMD TDP, keyboard RGB, Sunshine) live in `vivo/` so lenovo doesn't carry them.

## Install

```bash
cd ~/.dotfiles
stow hypr quickshell kitty fish starship fastfetch btop gtk qt scripts vivo   # on vivo
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
| `SUPER + D` | Launcher (quickshell) |
| `SUPER + A` | Toggle the assistant panel (Ori) |
| `SUPER + Q` | Close the assistant panel if it is up, else close the window |
| `SUPER + SHIFT + Q` | Exit Hyprland |
| `SUPER + F` | Toggle floating |
| `SUPER + SHIFT + F` | Fullscreen |
| `SUPER + V` | Clipboard history (quickshell) |
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
| `SUPER + K` | Calculator (quickshell) |
| `SUPER + R` | Resize window (cycle ratios) |
| `SUPER + Escape` | Power menu |
| `SUPER + . / ,` | Next/previous workspace |
| `SUPER + 1-0` | Switch workspace |
| `SUPER + SHIFT + 1-0` | Move window to workspace |

### Inside the assistant panel

Verified against `assistant/AssistantPanel.qml` and `assistant/CommandBar.qml`.
They were undocumented anywhere, and the panel's own on-screen hint is gated on
an EMPTY transcript — which the boot-time session restore means you essentially
never see again after the first run. So this table is the only place they exist.

| Key | Action |
|-----|--------|
| `Enter` | Send |
| `Shift + Enter` | Newline |
| `Ctrl + C` | Abort the running turn |
| `Ctrl + N` | New conversation |
| `Ctrl + R` | Session history picker |
| `Ctrl + V` | Attach an image from the clipboard |
| `Shift + Tab` | Cycle the thinking level (arrives as `Key_Backtab`) |
| `Ctrl + ↓` | Jump to the newest turn, and stick there |
| `Ctrl + ↑` | Jump to the oldest turn |
| `Esc` | Close the panel / dismiss the completion popup |
| `/` | Slash-command completion (`Tab`/`↑`/`↓` to pick) |

Panel-owned commands, which never reach the model: `/model` `/effort` `/new`
`/compact` `/name` `/export` `/restart`. See `runPanelCommand` in
`PiSession.qml`.

## Useful Commands

Reload waybar gracefully:
```bash
pkill -SIGUSR2 waybar
```

## Dependencies

```bash
sudo pacman -S hyprland hyprlock hypridle xdg-desktop-portal-hyprland \
  quickshell kitty stow socat \
  grim slurp wl-copy cliphist jq pamixer
```

waybar, swaync, swayosd, awww and rofi were all removed once Quickshell
replaced them; see the retired-packages note above.

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

### A D-Bus-activatable daemon can steal a well-known name
swaync shipped `/usr/share/dbus-1/services/org.erikreider.swaync.service` with
`Name=org.freedesktop.Notifications`, so **any** notification sent while
Quickshell was down D-Bus-activated swaync, which then held the name until it
was killed. Symptom: notifications quietly looked and behaved differently after
a Quickshell restart, for no apparent reason. swaync is uninstalled now, so this
is history -- but the trap generalises to any replaced daemon that ships a
`.service` activation file. Check the current owner with:

```bash
busctl --user list | grep org.freedesktop.Notifications
```

Quickshell re-acquires the name on its own the moment a squatter exits -- it
logs "Registration will be attempted again if the active service is
unregistered" and means it.

### Never read a ListView's geometry off `contentItem.children`
It mixes POSITIONED delegates with POOLED ones the view is holding for reuse,
and a pooled item keeps whatever `y` it last had. Use `itemAtIndex(i)`, which
returns the delegate for a model index or `null` when it has not been created.

This is not a subtle trap — it produced confident, wrong conclusions three
separate times in one evening. Two reviewers independently *inferred*
`ListView.originY` from the span of `children` and reported a divergence that
did not exist; the diagnostic probe built to settle the argument then made the
same mistake and reported `lastEnd=+2686.7` when the newest turn ended at
`-18.0`, plus one delegate with `height=-137.0`.

The general rule it belongs to, learned the same evening: **every quantity Qt
reports about this list has lied at least once.** `contentHeight` is an
extrapolation from whichever delegates happen to be built (measured 3.4x the
true height, and separately *smaller* than the real extent). `originY` agrees
with `-contentHeight` mid-list and diverges at the end of the list by exactly
the residual estimate error. `visibleArea.yPosition` is a CACHED value
refreshed by `updateVisible()`, so it read 0.985 — "at the end" — while the
view was 918.6px short of the end.

What has not lied: the positions of live delegates, and coverage computed from
them. Prefer "is the viewport actually covered by something drawn" over any
assertion comparing two framework numbers. `qs -p ~/.config/quickshell ipc call
ori scroll` reports exactly that (`gap`), and judging it needs `ghost >= 0`,
`children ≈ count + 1`, and the view at rest.

### A scroll/layout measurement taken with the display asleep proves nothing
Qt renders no frames while the output is in DPMS off, so a ListView never
relayouts: delegates are not built, `contentHeight` never moves, and any
assertion over it passes for free. A "520 samples, 0 violations" run was
produced this way and was worthless — the tell was **one distinct
`contentHeight` for the whole run**. Awake, the same harness saw 36 distinct
values swinging 501,733 → 56,196.

Check `hyprctl monitors -j` for `dpmsStatus` before trusting any layout
measurement, and record how many distinct `contentHeight` values a run saw. One
value means the code under test never executed.

### QML errors are NOT invisible — read `qs log` first
The folklore in this repo said quickshell's output goes to /dev/null so runtime
QML errors cannot be seen, and that panel code must be checked with `qmllint`
and never with logs. That is wrong, and believing it cost real debugging time.

Only **stdout/stderr** go to /dev/null. Quickshell keeps its **own** log, and
binding failures land in it with file and line:

```bash
qs -p ~/.config/quickshell log            # whole log
qs -p ~/.config/quickshell log -t 50      # last 50 lines
qs -p ~/.config/quickshell log -f         # follow (prints the backlog first)
qs -p ~/.config/quickshell log -r <rules> # QT_LOGGING_RULES filter
```

That is how `WARN scene: @widgets/Windows.qml[434:11]: Unable to assign
[undefined] to bool` was found — a Repeater sets a delegate's `index` to -1
while the item is being removed, so a guard with an upper bound and no lower
one read `visibleFlags[-1]`. It had been warning on every window close.

Signal is high: the entire log held **two** distinct QML complaints, one of
them a file already deleted. Anything in there is worth reading. Use `qmllint`
for syntax and `qs log` for runtime — they catch different things, and neither
substitutes for the other.

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

