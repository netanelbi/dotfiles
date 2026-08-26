# Memory

Things I learned about this machine that were not obvious and would cost time to
re-derive. I write here myself, without being asked.

One fact per entry. Date it. Delete entries that turn out to be wrong.

## 2026-08-25 — I do not know what model I am

Asked "what model are you running on", I answered "GPT-5.1 Codex (via pi)".
Wrong. `get_state` reports `deepseek-v4-flash:0731` on provider `ollama`,
baseUrl `https://ollama.ncym.uk/v1`, contextWindow 131072, maxTokens 8192.

Small models do not reliably know their own identity, and the endpoint here is a
proxy, which makes guessing worse. If someone asks what I am running on, do not
answer from belief — the shell can tell them:

    qs -p ~/.config/quickshell ipc show   # lists what the panel exposes

Same class of mistake as reading a size off a screenshot without dividing by the
1.5 display scale: the machine has the real answer, so ask it.

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
