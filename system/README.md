# `system/` — root-owned files (NOT a stow package)

Stow only targets `$HOME`, so anything here cannot be symlinked as a normal user.
The tree mirrors the absolute install path; copy files into place with sudo.

Do **not** run `stow system` — it would symlink this tree into `~/usr/...`.

## Install

```bash
sudo install -Dm644 system/etc/systemd/system/post-resume-check.service \
                    /etc/systemd/system/post-resume-check.service
sudo systemctl daemon-reload
sudo systemctl enable post-resume-check.service
```

```bash
sudo install -Dm644 system/etc/systemd/logind.conf.d/lid.conf \
                    /etc/systemd/logind.conf.d/lid.conf
sudo systemctl reload systemd-logind
```

## Contents

| file | why |
|---|---|
| `etc/systemd/logind.conf.d/lid.conf` | Lid close suspends on battery only. On AC it is ignored, so the machine keeps working with the lid shut. Set on AC power rather than on `HandleLidSwitchDocked`, which silently stops applying the moment the displays are blanked — see the comment in the file. |
| `etc/systemd/system/post-resume-check.service` | Runs `post-resume-check` ~20s after resume, ordered `After=suspend.target` so it is an ordinary unit rather than a sleep hook. Re-applies the ryzenadj TDP limits (a suspend clears them) and read-only *reports* whether the 2GHz frequency cap survived. |

## Do not re-add `amd-pstate-fix.sh`

It lived at `/usr/lib/systemd/system-sleep/amd-pstate-fix.sh` and toggled
`amd_pstate/status` passive->active on resume to clear a 2GHz frequency cap.

Two things were wrong with it:

1. It did all its work in a backgrounded subshell, `( sleep 1; ... ) &`.
   `systemd-suspend.service` deactivates immediately after thaw and its cgroup is
   torn down, so the subshell was killed before it ever ran. The script had been
   dead code for its entire life — the 2GHz fix never actually happened, and
   nobody noticed, which is itself evidence the cap is no longer a problem.

2. Making it synchronous so it *would* run then oopsed the kernel on the first
   resume (2026-08-14, hard power-off):

       BUG: kernel NULL pointer dereference, address: 0000000000000000
       #PF: supervisor instruction fetch in kernel mode
       Oops: 0010 [#1] SMP NOPTI
       CPU: 7 UID: 0 PID: 119741 Comm: amd-pstate-fix.

   A supervisor *instruction* fetch at NULL means the kernel jumped through a
   NULL function pointer: switching amd_pstate's mode while the driver is itself
   resuming races its own callback table.

TDP after resume is not worth a kernel oops. `ppd-tdp-watch` already covers boot
and every profile change; after a resume, SUPER+B re-applies it by hand. If this
is ever revisited, do the work from a `systemd-run` transient unit well after
resume completes — never inline in a sleep hook.
