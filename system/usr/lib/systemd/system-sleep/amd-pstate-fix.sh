#!/bin/bash
# Resume fixups for vivo (AMD Strix Point). Runs from /usr/lib/systemd/system-sleep/
# — systemd 261 scans that path and no /etc equivalent.
#
# MUST run synchronously. The previous version did its work in a backgrounded
# subshell -- `( sleep 1; ... ) &` -- which never executed: systemd-suspend.service
# deactivates immediately after thaw and its cgroup is torn down, killing the
# subshell before the `sleep 1` returned. systemd waits for this script's
# foreground, so everything has to happen inline.
#
# Two things are restored here, both wiped by a suspend/resume cycle:
#   1. amd_pstate gets stuck reporting a 2GHz ceiling; toggling the driver
#      passive->active forces it to re-read the real limits.
#   2. powerprofilesctl resets the SMU power limits to firmware defaults, so the
#      ryzenadj values must be re-applied afterwards or the machine silently runs
#      at ~43W/tctl 100 instead of the configured profile until the next SUPER+B.

[ "$1" = "post" ] || exit 0

TDPHOOK=/home/netanel/.local/bin/power-profile-tdp-hook

sleep 1

echo passive > /sys/devices/system/cpu/amd_pstate/status
echo active  > /sys/devices/system/cpu/amd_pstate/status

current=$(powerprofilesctl get 2>/dev/null) || current=balanced
powerprofilesctl set balanced
powerprofilesctl set "$current"

# Re-apply TDP last: the profile changes above are what clear it.
if [ -x "$TDPHOOK" ]; then
    "$TDPHOOK" "$current"
    rc=$?
else
    rc=127
fi

# Leave a trace. This whole path failed silently for a long time; without a log
# line there is no way to tell a working resume from a dead one.
logger -t amd-pstate-fix \
  "resume: profile=$current maxfreq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null) tdp-hook-rc=$rc"
