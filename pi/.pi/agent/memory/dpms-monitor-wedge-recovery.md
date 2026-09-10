---
name: dpms-monitor-wedge-recovery
summary: Idle DPMS-off can wedge the external monitor's DP alt mode; recovery = power-cycle the monitor, not the laptop side
pinned: true
created: 2026-09-09
modified: 2026-09-09
---
2026-09-09: after idle DPMS-off the external monitor (USB-C DP alt mode) stayed dark. All DRM connectors `disconnected`, USB hub still enumerated (partner present, no alt mode). Neither hyprctl dpms toggle, UCSI rebind (`pkexec sh -c 'echo USBC000:00 > /sys/bus/platform/drivers/ucsi_acpi/unbind; sleep 2; echo USBC000:00 > /sys/bus/platform/drivers/ucsi_acpi/bind'`), nor replug fixed it. Monitor power button off→5s→on re-asserted HPD and it recovered instantly. Recipe: check /sys/class/drm/card1-DP-*/status; if all disconnected but hub alive, tell him to power-cycle the monitor before any debugging.
