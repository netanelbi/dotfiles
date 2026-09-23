---
name: wifi-second-netdev-stray-wlan1
summary: The MT7922 phy sometimes carries a second, permanently DOWN netdev (wlan1 next to wlan0); anything that picks "the first wlan from `iw dev`" gets the dead one
pinned: false
created: 2026-09-22
modified: 2026-09-22
---
Symptom (2026-09-22): the QS bar showed the crossed-out wifi glyph while wlan0 was connected to h0me — `iw dev` listed wlan1 (DOWN, qdisc noop, its own random local MAC, no traffic ever, same PCI device 62:00.0) before wlan0, and `hypr-network-watch`'s `awk '/Interface/{print $2; exit}'` took it, so the script honestly reported "Disconnected".

Fix: scripts/.local/bin/hypr-network-watch now loops the interfaces and prefers the first whose `iw dev <if> link` says "Connected to", falling back to the first. Verified in the bar (green signal + ₆ subscript). Killing the script process is enough to apply an edit — ScriptWidget respawns it after 2s (no quickshell restart needed).

Not established: what creates wlan1. Nothing in ~/.dotfiles, /etc/systemd, udev rules or modprobe does; it was present 10s after boot this boot, while the previous boot's iwd log showed two udev interface events both named wlan0 (ifindex 3 and 4) — so the kernel/udev naming of a second netdev on this phy is the suspicious part. `iw dev wlan1 del` clears it until next boot.
