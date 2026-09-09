# Memory

Pinned facts. Full text is in ~/.pi/agent/memory/<name>.md; `memory search` also finds the unpinned ones.

- board-wedged-quickshell — If board edits wedge quickshell: overwrite the revisioned file in /tmp/.board-load/ so reload is safe, then restart quickshell per laptop.md; wrap board IPC in timeout when testing unproven QML
- boards — Floating desktop cards: read ~/.pi/agent/skills/board/SKILL.md before driving them; qs ipc call board <qml|html|question|move|read|snapshot|close> <name>
- ephemeral-state-hooks — speak.ts/ambient.ts context hooks append [speech-state]/[ambient-state] before every LLM call; speech-state: voice-in orb = speak(), voice-mode on = speak by default, off = text unless asked
- hebrew-tts-lang — kokoro speak: Hebrew text must be paired with lang 'he'; the en-us default mangles Hebrew characters
- hyprland-lua-binds — hl.bind registers only at Hyprland start: bind edits need a Hyprland restart, not hyprctl reload; hyprctl keyword cannot parse Lua, use hyprctl eval
- qs-log-and-dead-socket — qmllint noise is baseline, only 'Type X unavailable' in qs log is real; a dead panel socket needs a full quickshell restart (laptop.md says how)
- whisper-npu — whisper-npu (~/Development/Personal/whisper-npu): encoder on the XDNA2 NPU, decoder on CPU; English PTT is Moonshine v2 on CPU
