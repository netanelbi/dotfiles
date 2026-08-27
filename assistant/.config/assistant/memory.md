# Memory

Things I learned about this machine that were not obvious and would cost time to
re-derive. I write here myself, without being asked.

One fact per entry. Date it. Delete entries that turn out to be wrong.

## 2026-08-27 — The model I run on is a runtime choice, not an identity

Asked "what model are you", never answer from belief or from a memory note —
the model changes. The live truth, in order of authority:

1. The panel footer (bottom-left of my own panel) shows the serving model.
2. `~/.local/state/quickshell/ori-model.json` — what the panel will spawn next.
3. `PI_MODEL`/`PI_PROVIDER` in my tool env — what THIS pi process reports.

Gotchas learned the hard way on 2026-08-27:

- **A model change only applies to the next cold spawn.** A running pi keeps
  the model it was born with until killed (10-min idle kill, or `qs -p
  ~/.config/quickshell ipc call ori restart`). Netanel set `glm-5.3-flash` and
  I kept answering on `deepseek-v4-flash:0731` for an hour, then confidently
  explained the mismatch as "two different processes" — wrong. There is one
  process: bash → pi → ori-agent → systemd. I verified this by walking
  `/proc/$$/status` PPID chain, the only reliable identity check.
- The panel is a separate face from the model: `ori-model.json` holds the
  choice, PiSession.qml sends it as `__config`, ori-agent builds
  `pi --model <cfg>` per spawn.
- The env `PI_*` vars are set by pi for its tools, reflecting its own config —
  they are a report, not an inherited environment (the pi process's real
  /proc environ does not contain them).

Earlier version of this entry (2026-08-25) recorded answering "GPT-5.1 Codex"
from belief when asked; the lesson stands — ask the machine, never self-report.

## 2026-08-26 — ScriptWidget children leak when quickshell is SIGKILLed

Every ScriptWidget watcher (tdp-watch, hypr-*-watch, stay-awake-watch,
gamepad-watch) used to be spawned through `sh -lc`, so the script's parent was
the sh wrapper. When quickshell hot-reloads it is SIGKILLed, which never
signals children: the sh wrapper was orphaned but stayed alive, orphaning the
script and its own child (inotifywait/socat/evtest/gdbus) forever. Hundreds of
reloads leaked thousands of processes and exhausted the inotify instance limit
(1022/1024) — that is what blocked dev servers, not tdp-watch specifically.

Fixed in ScriptWidget.qml: scripts are now spawned directly (no sh wrapper)
through `~/.local/bin/pdeathsig`, which sets PR_SET_PDEATHSIG(SIGTERM) so the
script dies the moment quickshell dies even on SIGKILL, and its EXIT trap reaps
the child. Two gotchas baked into the fix:
- quickshell's Process PATH does NOT include ~/.local/bin (the old `sh -lc`
  sourced the login profile for it), so pdeathsig must be an absolute path.
- `~` in the script path is expanded in QML (expandHome), not by sh.

If a watcher ever leaks again, the tell is orphaned processes with PPID 1:
`ps -eo pid,ppid,cmd | awk '$2==1 && $0 ~ /\.local\/bin\/(hypr-|stay-awake|gamepad|tdp)/'`.
