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
| scripts | Utility scripts for Hyprland/Waybar |

## Install

```bash
cd ~/.dotfiles
stow hypr waybar swaync swayosd kitty rofi fish starship fastfetch btop scripts
```

## Uninstall a package

```bash
stow -D package_name
```

## Key Bindings

| Key | Action |
|-----|--------|
| `SUPER + Return` | Terminal (kitty) |
| `SUPER + Space` | Launcher (rofi) |
| `SUPER + Q` | Close window |
| `SUPER + F` | Fullscreen |
| `SUPER + SHIFT + V` | Toggle floating |
| `SUPER + V` | Clipboard history |
| `SUPER + L` | Lock screen |
| `SUPER + M` | Exit Hyprland |
| `SUPER + ~` | Toggle scratchpad |
| `SUPER + S` | Move window to scratchpad |
| `SUPER + ALT + S` | Move to scratchpad silently |
| `SUPER + arrows` | Move focus (cycle floating windows if on floater) |
| `SUPER + B` | Cycle power profile |
| `SUPER + C` | Screenshot focused window |
| `SUPER + SHIFT + S` | Screenshot selection |
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
All indicators use Hyprland's event socket (`socat`) for real-time updates:
- `hypr-scratchpad-watch` - scratchpad window count and visibility
- `hypr-windows-watch` - active workspace window list with focus tracking

### Scripts Package
Located in `scripts/.local/bin/`:
- `hypr-scratchpad-toggle` - Toggle scratchpad with notifications
- `hypr-scratchpad-move` - Move window to scratchpad with signal
- `hypr-scratchpad-cycle` - Cycle through scratchpad windows
- `hypr-scratchpad-count` - Count scratchpad windows (legacy, replaced by watch)
- `hypr-scratchpad-watch` - Event-based scratchpad monitoring
- `hypr-floating-cycle` - Cycle through floating windows
- `hypr-focus-or-scratchpad` - Smart focus/cycle based on window type
- `hypr-windows-watch` - Event-based window list monitoring
- `hypr-window-switcher` - Rofi menu for window selection

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
