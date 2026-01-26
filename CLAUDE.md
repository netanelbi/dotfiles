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

## Install

```bash
cd ~/.dotfiles
stow hypr waybar swaync swayosd kitty rofi fish starship fastfetch btop gtk qt scripts
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
- `hypr-scratchpad-toggle` - Toggle scratchpad with notifications
- `hypr-scratchpad-move` - Move window to scratchpad with signal
- `hypr-scratchpad-cycle` - Cycle through scratchpad windows
- `hypr-scratchpad-watch` - Event-based scratchpad monitoring for waybar
- `hypr-floating-cycle` - Cycle through floating windows
- `hypr-focus-or-scratchpad` - Smart focus/cycle based on window type
- `hypr-windows-watch` - Event-based window list monitoring for waybar
- `hypr-capslock-watch` - Event-based capslock indicator for waybar
- `hypr-zen-popup-watch` - Watch for Zen browser popup windows

## Hyprland 0.53+ Window Rule Syntax

The windowrule syntax changed significantly in Hyprland 0.53. Key differences:

### Basic Format
```ini
# New syntax: rule first, then match:field pattern
windowrule = float on, match:class myapp
windowrule = size 800 600, match:class myapp
windowrule = pin on, match:class myapp

# Boolean rules need "on/off"
windowrule = float on, match:class myapp    # not just "float"
windowrule = pin on, match:class myapp      # not just "pin"
windowrule = center on, match:class myapp   # not just "center"
```

### Positioning with Expressions
The old `100%-550` syntax no longer works. Use expression variables instead:
```ini
# Position window 50px from right edge, 50px from top
windowrule = move (monitor_w-window_w-50) 50, match:class myapp

# Available variables: monitor_w, monitor_h, window_w, window_h, cursor_x, cursor_y
```

### Match Fields
- `match:class` - window class
- `match:title` - window title
- `match:workspace` - workspace (use `special:name` for special workspaces)

### Rule Names Changed
- `bordercolor` -> `border_color`
- `noblur` -> `no_blur on`

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

## How Stow Works

**Important**: Stow creates **symlinks**, not copies. Once stowed:
- Editing files in the repo directly updates the active config (no restow needed)
- Changes are immediately live
- Only restow when adding/removing files or initially stowing

## Adding new configs

1. Create `newpkg/.config/newpkg/` structure (or `.local/bin/` for scripts)
2. Add config files
3. Run `stow newpkg` (only needed once)
4. Update this CLAUDE.md with documentation

## Editing existing configs

Just edit files in the repo - changes are live immediately (they're symlinks).

**Only restow when**:
- Adding new files to a stowed package
- Removing files from a stowed package
- Initially stowing a new package
