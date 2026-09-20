---
name: gamepad-idle-wljoywake
summary: Gamepads never reset the idle timer (ext-idle-notify is kbd/pointer only); wljoywake (AUR) reads js* and holds a Wayland idle inhibitor — installed here, package ships its own user unit, default -t 30
pinned: true
created: 2026-09-20
modified: 2026-09-20
---
hypridle cannot see a controller: ext-idle-notify-v1 reports keyboard and pointer idle only, so a pad leaves the 150s screensaver and 300s lock running (same upstream gap as Hyprland #996 touch / #4028 stylus, closed as "compositor should handle it"). Not a hypridle bug — any daemon on that protocol (swayidle too) is equally blind, and replacing hypridle would also lose the dbus/logind inhibitor support that sunshine-inhibit and stay-awake depend on.

Fix: wljoywake (AUR, nowrep/wljoywake) — reads js* via libudev, holds zwp_idle_inhibit_manager_v1 while pads are active, releases after -t seconds. Installed 2026-09-20. The AUR package SHIPS /usr/lib/systemd/user/wljoywake.service (WantedBy=graphical-session.target), so do not write a unit in the dotfiles repo — same name shadows the package. Default timeout is 30s (main.c: static int timeout_sec = 30); change it with a drop-in at ~/.config/systemd/user/wljoywake.service.d/ if ever needed.

Why the design is safe: hypridle re-registers its idle notifications when an inhibitor is released if the session is idle (upstream PR #72, merged 2024-06-22, included in the 0.1.8-2.1 installed here) — so the clock restarts from release, and the screensaver fires 150s after the last button press, not 150s after boot.

The idle_inhibit window rules in hyprland.lua stay: belt to this braces, covering a session started before the service or a dead wljoywake. Sunshine streams need neither — sunshine-prep holds a logind idle inhibitor for the stream's whole duration.
