#!/bin/bash
if [ "$1" = "post" ]; then
      (
          sleep 1
          echo passive > /sys/devices/system/cpu/amd_pstate/status
          echo active > /sys/devices/system/cpu/amd_pstate/status
          current=$(powerprofilesctl get)
          powerprofilesctl set balanced
          powerprofilesctl set "$current"
          # profile changes wipe the SMU limits — put them back
          [ -x /home/netanel/.local/bin/power-profile-tdp-hook ] && /home/netanel/.local/bin/power-profile-tdp-hook "$current"
      ) &
fi
