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
| hypr | Hyprland window manager config |
| waybar | Status bar (island style) |
| swaync | Notification center |
| swaylock | Lock screen (swaylock-effects) |
| swayidle | Idle daemon |
| kitty | Terminal emulator |

## Install

```bash
cd ~/.dotfiles
stow hypr waybar swaync swaylock swayidle kitty
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
| `SUPER + S` | Toggle scratchpad |
| `SUPER + ALT + S` | Move to scratchpad |
| `SUPER + B` | Cycle power profile |
| `SUPER + C` | Screenshot focused window |
| `SUPER + SHIFT + S` | Screenshot selection |
| `SUPER + 1-0` | Switch workspace |
| `SUPER + SHIFT + 1-0` | Move window to workspace |
| `SUPER + arrows` | Move focus |

## Useful Commands

Reload waybar gracefully:
```bash
pkill -SIGUSR2 waybar
```

## Dependencies

```bash
sudo pacman -S hyprland xdg-desktop-portal-hyprland \
  swaylock-effects swayidle kitty rofi waybar swaync swww stow \
  grim slurp wl-copy cliphist jq pamixer
```

## Adding new configs

1. Create `newpkg/.config/newpkg/` structure
2. Add config files
3. Run `stow newpkg`
