# Memory

Pinned facts. Full text is in ~/.pi/agent/memory/<name>.md; `memory search` also finds the unpinned ones.

- board-wedged-quickshell — If board edits wedge quickshell: overwrite the revisioned file in /tmp/.board-load/ so reload is safe, then restart quickshell per laptop.md; wrap board IPC in timeout when testing unproven QML
- boards — Floating desktop cards: read ~/.pi/agent/skills/board/SKILL.md before driving them; qs ipc call board <qml|html|question|move|read|snapshot|close> <name>
- bun-pnpm-exec-bit — AUR builds that call pnpm fail with "Permission denied"/Error 126 when ~/.bun/bin/pnpm's target pnpm.mjs has lost its exec bit; chmod +x fixes it
- dpms-monitor-wedge-recovery — Idle DPMS-off can wedge the external monitor's DP alt mode; recovery = power-cycle the monitor, not the laptop side
- ephemeral-state-hooks — speak.ts/ambient.ts context hooks append [speech-state]/[ambient-state] before every LLM call; speech-state: voice-in orb = speak(), voice-mode on = speak by default, off = text unless asked
- gamepad-idle-wljoywake — Gamepads never reset the idle timer (ext-idle-notify is kbd/pointer only); wljoywake (AUR) reads js* and holds a Wayland idle inhibitor — installed here, package ships its own user unit, default -t 30
- hebrew-tts-lang — kokoro speak: Hebrew text must be paired with lang 'he'; the en-us default mangles Hebrew characters
- hyprland-lua-binds — hl.bind: new binds usually need a Hyprland restart, but a file edit CAN go live on its own (verified 2026-09-16); hyprctl reload keeps old binds, and hyprctl keyword cannot parse Lua — use hyprctl eval
- israel-2026-payroll — Israel 2026 payroll constants + Netanel's terms, validated to the shekel against his Aug-2026 payslip
- kokoro-french-voice — French TTS: use kokoro voice ff_siwis with lang fr-fr (owner's choice after audition); it's the only native French voice
- notification-ignores — Notification "never show again" list: $XDG_STATE_HOME/quickshell/notification-ignores.json, rules {app,summary} matched by prefix; driven by qs ipc call notifications ignored|ignore|unignore
- ori-self-wake-targets-active-conversation — An ask on a BUSY conversation is steered into the running turn (conversation.ts ask() -> steer: busy), never a new turn — so anything the main agent does by itself hijacks the owner's next question; fix = origin: human|self on turns + preempt, strip long tools, task row before work starts
- pacman-sc-download-dirs — pacman -Sc errors ("could not open file download-XXXXX") on empty alpm:alpm temp dirs left by killed pacman runs; rm -rf them first
- pdf-to-docx-hebrew — pdf2docx (and LibreOffice PDF import) sort spans by x, which reverses Hebrew and drops paragraph direction — use ~/.local/bin/pdf2docx-rtl instead (rebuilds real RTL Word paragraphs from the PDF's logical text order)
- qs-log-and-dead-socket — qmllint noise is baseline, only 'Type X unavailable' in qs log is real; a dead panel socket needs a full quickshell restart (laptop.md says how)
- shell-missing-display-env — Ori's shell has no DISPLAY/WAYLAND_DISPLAY: prefix GUI tools with XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 (grim), add DISPLAY=:1 for X11/Qt apps; launch apps via systemd-run --user as a *service* with -E env (a --scope dies with the turn)
- subagent-parallel-failed-label — Parallel subagent rollup mislabels children that outlive the 2s grace as "failed" though they ran fine
- subagent-wedge-and-tray — pi -p children wedged forever after answering a bg-job followUp (patched dist/main.js to waitForIdle+process.exit); ori-host tray rows now reconcile against the subagent registry — both fixes need an ori-host restart to be live
- whisper-npu — whisper-npu (~/Development/Personal/whisper-npu): encoder on the XDNA2 NPU, decoder on CPU; English PTT is Moonshine v2 on CPU
