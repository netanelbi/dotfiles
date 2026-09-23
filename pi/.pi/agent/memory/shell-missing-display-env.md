---
name: shell-missing-display-env
summary: Ori's shell has no DISPLAY/WAYLAND_DISPLAY: prefix GUI tools with XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 (grim), add DISPLAY=:1 for X11/Qt apps; launch apps via systemd-run --user as a *service* with -E env (a --scope dies with the turn)
pinned: true
created: 2026-09-22
modified: 2026-09-22
---
My bash env only has XDG_RUNTIME_DIR=/run/user/1000; DISPLAY and WAYLAND_DISPLAY are empty, so grim says "failed to create display" and Qt apps (onlyoffice-desktopeditors) say "QXcbConnection: Could not connect to display". The systemd --user environment does have DISPLAY=:1 and WAYLAND_DISPLAY=wayland-1 (`systemctl --user show-environment`).

- grim: `XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 grim -o <output> /tmp/x.png`
- GUI apps: `systemd-run --user --unit=<name> --collect -E DISPLAY=:1 -E WAYLAND_DISPLAY=wayland-1 -E XDG_RUNTIME_DIR=/run/user/1000 <cmd>` — service, not `--scope` (a scope's process dies when the turn's shell exits). Use a fresh --unit name each time; reuse without --collect fails with "Unit ... already exists".
- Off-screen screenshot without disturbing the owner: `hyprctl output create headless hl-capture` makes a 1920x1080 output with its own workspace, `hyprctl dispatch movetoworkspacesilent "4,address:0x..."`, grim -o hl-capture, then `hyprctl output remove hl-capture`.
- `pkill -f <name>` kills my own bash call when the pattern appears in the command line (e.g. pkill -f DesktopEditors). Use `pkill -x` / kill by PID.
- onlyoffice-desktopeditors is a libcef app and crashed once under systemd-run (crash dump in libcef.so); treat its launches as flaky.
