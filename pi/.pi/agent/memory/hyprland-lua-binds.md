---
name: hyprland-lua-binds
summary: hl.bind registers only at Hyprland start: bind edits need a Hyprland restart, not hyprctl reload; hyprctl keyword cannot parse Lua, use hyprctl eval
pinned: true
created: 2026-09-09
modified: 2026-09-09
---
Hyprland config is Lua (hyprland.lua + machine.lua; hl.bind("MOD+Key", hl.dsp.exec_cmd(cmd), {release:true}); stubs /usr/share/hypr/stubs/hl.meta.lua). hl.bind registers ONLY at Hyprland start — hyprctl reload keeps old binds, new ones dead; hyprctl eval hl.bind works only pre-reload. Bind edits need a Hyprland restart; hyprctl keyword can't parse Lua — use hyprctl eval.
