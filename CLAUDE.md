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
| waybar | Status bar |
| fuzzel | Application launcher |
| dunst | Notifications |
| swaylock | Lock screen (swaylock-effects) |
| swayidle | Idle daemon |
| kitty | Terminal emulator |

## Install

```bash
cd ~/.dotfiles
stow hypr waybar fuzzel dunst swaylock swayidle kitty
```

## Uninstall a package

```bash
stow -D package_name
```

## Key Bindings

| Key | Action |
|-----|--------|
| `SUPER + Return` | Terminal (kitty) |
| `SUPER + Space` | Launcher (fuzzel) |
| `SUPER + Q` | Close window |
| `SUPER + F` | Fullscreen |
| `SUPER + V` | Toggle floating |
| `SUPER + L` | Lock screen |
| `SUPER + M` | Exit Hyprland |
| `SUPER + 1-0` | Switch workspace |
| `SUPER + SHIFT + 1-0` | Move window to workspace |
| `SUPER + arrows` | Move focus |

## Dependencies

```bash
sudo pacman -S hyprland xdg-desktop-portal-hyprland \
  swaylock-effects swayidle kitty fuzzel waybar dunst swww stow
```

## Adding new configs

1. Create `newpkg/.config/newpkg/` structure
2. Add config files
3. Run `stow newpkg`
