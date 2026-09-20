---
name: hyprland-lua-binds
summary: hl.bind: new binds usually need a Hyprland restart, but a file edit CAN go live on its own (verified 2026-09-16); hyprctl reload keeps old binds, and hyprctl keyword cannot parse Lua — use hyprctl eval
pinned: true
created: 2026-09-09
modified: 2026-09-16
---
Hyprland config is Lua (hyprland.lua + machine.lua; hl.bind("MOD+Key", hl.dsp.exec_cmd(cmd), {release:true}); stubs /usr/share/hypr/stubs/hl.meta.lua).

Originally recorded (2026-09-09) as: hl.bind registers ONLY at Hyprland start — hyprctl reload keeps old binds, new ones dead; hyprctl eval hl.bind works only pre-reload; bind edits need a restart.

But 2026-09-16: added `hl.bind(mainMod .. " + N", ... notifications toggle)` to hyprland.lua with no restart and no reload. `hyprctl binds -j` showed it (modmask 64, key N, dispatcher __lua) and sending the chord over uinput (ydotool key 125:1 49:1 49:0 125:0) opened the panel, then closed it on the second press. So a file edit can go live by itself (Hyprland auto-reloads the config on mtime change).

Practical rule: after editing hyprland.lua, check `hyprctl binds -j` for the new bind before declaring a restart necessary; if it is missing, restart Hyprland. `hyprctl keyword` still cannot parse Lua — use `hyprctl eval` for runtime writes.
