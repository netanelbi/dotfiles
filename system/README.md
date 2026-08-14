# `system/` — root-owned files (NOT a stow package)

Stow only targets `$HOME`, so these cannot be symlinked as a normal user. The tree
mirrors the absolute install path; copy them into place with sudo.

Do **not** run `stow system` — it would symlink this tree into `~/usr/...`.

## Install

```bash
sudo install -Dm755 system/usr/lib/systemd/system-sleep/amd-pstate-fix.sh \
                    /usr/lib/systemd/system-sleep/amd-pstate-fix.sh
```

## Contents

| file | why it is tracked |
|---|---|
| `usr/lib/systemd/system-sleep/amd-pstate-fix.sh` | vivo-only. Clears the 2GHz amd_pstate cap after resume **and** re-applies the ryzenadj TDP limits, which `powerprofilesctl` wipes back to firmware defaults on every profile change. Hand-written and owned by no package, so a machine rebuild would lose it. |

`/usr/lib/systemd/system-sleep/` is the correct (and only) location — systemd 261's
`systemd-sleep` binary scans that path and no `/etc` equivalent. Upstream calls such
scripts "hacks", but there is no supported alternative for reacting to resume.
