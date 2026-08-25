# This machine

`netanel-vivo` — ASUS Vivobook S14 M5406WA. CachyOS (Arch), Hyprland, fish.
There is a second machine, `lenovo` (Intel/1080p), sharing the same dotfiles
repo through different stow packages. Anything machine-specific here is about
vivo unless it says otherwise.

- Display: eDP-1, 1920x1200 physical at **scale 1.5** — so 1280x800 logical.
  Screenshots come out in physical pixels; a 460px panel measures ~690px in a
  grab. Do not "fix" a size based on a screenshot without dividing by 1.5.
- **No sudo.** Not "avoid it" — the owner does not have it. Print the command.
- GPU: AMD Strix Point (Radeon 890M), ROCm available for local inference.

## Traps that have already cost time

- **amdgpu DCN 3.5 hard-reboots on dpms-off** with an external monitor attached.
  Mitigated with `amdgpu.dcdebugmask=0x800`; it recurred once after a kernel
  update. Never add a code path that blanks an output without checking this.
- **Disabling the only active monitor segfaults Hyprland.** Every
  `monitor,disable` path needs a guard.
- **ryzenadj races itself.** Two concurrent runs desync the SMU mailbox and
  freeze the machine. `power-profile-cycle` is flock-serialized for this reason.
- **The keyboard is RGB but not Aura.** It is HID LampArray (ITE5570,
  `0b05:5570`) — asusctl and OpenRGB do nothing. Use `vrgb set <rrggbb>` over
  hidraw; `vrgb status` reads the saved colour back.
- **Never SIGSTOP a Wayland client.** Events queue on its socket and the
  protocol desyncs after SIGCONT.

## Tools worth reaching for

In `~/.local/bin` (the `scripts` and `vivo` stow packages):

- `power-profile-cycle`, `tdp`, `fix-cpu-freq` — power and thermals
- `vrgb` — keyboard RGB
- `hypr-*-watch` — event-driven Hyprland state (never poll; the repo forbids it)
- `recall <query>` — BM25 search over every past Claude session and memory file
- `bd` — beads issue tracker, works from any directory
- `gws` — Google Workspace CLI (calendar/gmail/drive), work profile by default
- `slk` — Slack CLI
- `canvas show <file>` — put something on screen for the owner to look at

## Waking myself up

There is no cron daemon here and I do not need one — systemd takes a one-shot
timer with no unit file, so I can schedule my own work in a single command:

```bash
# once, in 30 minutes
systemd-run --user --on-active=30min \
  qs -p ~/.config/quickshell ipc call assistant ask "check the batch job"

# every half hour
systemd-run --user --on-calendar='*:0/30' --unit=ori-watch \
  qs -p ~/.config/quickshell ipc call assistant ask "anything on fire?"
```

`ipc call assistant ask` does not need the panel open. The answer lands in the
transcript and the bar mark goes bright, so the next time the owner looks it is
waiting for them.

Housekeeping, because a forgotten timer is worse than no timer:
`systemctl --user list-timers` to see mine, `systemctl --user stop <unit>.timer`
to cancel one, and `systemctl --user reset-failed <unit>` after a one-shot to
clear its leftover unit. Name every recurring timer with `--unit=ori-*` so they
are obviously mine and easy to sweep.

## Talking to the shell I live in

Any script can drive the desktop:

```
qs -p ~/.config/quickshell ipc call <target> <function> [args]
```

Targets include `assistant` (me), `apps`, `clipboard`, `calc`, `emoji`, `power`,
`screensaver`, `sharepicker`. `qs -p ~/.config/quickshell ipc show` lists them
all with their signatures — read that before guessing.
