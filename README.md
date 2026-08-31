# dotfiles

My Linux desktop configuration: a Hyprland setup on CachyOS (Arch-based),
managed with GNU Stow, covering two machines.

The bulk of it is **quickshell** — a desktop shell written from scratch in
QML/[Quickshell](https://quickshell.org) that replaced Waybar, SwayNC, SwayOSD
and Rofi. It provides the bar, notification centre, volume/brightness OSD,
application and clipboard launchers, a calendar popover backed by the Google
Calendar CLI, and an assistant panel.

## Layout

Each top-level folder is a stow package that symlinks into `~/.config`:

```
package/.config/package/  ->  ~/.config/package
```

| Package | Contents |
|---|---|
| `hypr` | Hyprland, hyprlock, hypridle |
| `quickshell` | The desktop shell: bar, notifications, OSD, launchers, calendar, assistant |
| `fish` | Fish shell config, functions and `conf.d` fragments |
| `scripts` | Utility scripts on `~/.local/bin` |
| `kitty`, `starship`, `fastfetch`, `gtk`, `qt` | Terminal, prompt, theming |
| `vivo`, `lenovo` | Per-machine fragments (monitors, TDP, keyboard RGB) |
| `assistant`, `system` | Assistant prompt files and systemd units |
| `waybar`, `swaync`, `swayosd`, `rofi` | Retired — kept for the `pre-quickshell` rollback point |

## Multi-machine model

Single branch. Machine differences live in **stow packages**, not branches: a
file lives in either a shared package or a machine package, never both. Files
that differ per machine but are both needed use a shared base that sources a
machine fragment.

## Install

```bash
git clone https://github.com/netanelbi/dotfiles ~/.dotfiles
cd ~/.dotfiles
stow hypr quickshell kitty fish starship fastfetch gtk qt scripts vivo
# swap `vivo` for `lenovo` on the other machine
```

Remove a package with `stow -D <package>`.

## Local configuration

Machine-local values (private repo paths, credentials, per-host aliases) belong
in `fish/.config/fish/conf.d/secrets.fish`, which is gitignored and never
committed. A few scripts read optional environment variables instead:

| Variable | Used by | Meaning |
|---|---|---|
| `ADM_REPO` | `scripts/.local/bin/ADM` | Path to the admin-console checkout to run |
| `CALENDAR_ACCOUNT` | `quickshell/…/CalendarActions.qml` | Google account to pin calendar links to; unset means no hint |

## License

MIT — see [LICENSE](LICENSE).
