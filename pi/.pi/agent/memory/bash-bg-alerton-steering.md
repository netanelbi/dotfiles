---
name: bash-bg-alerton-steering
summary: bash backgrounding — `background: true` / `wait` / `timeout` (kill); alertOn and BG_PROCESS_DONE arrive at my next tool-call boundary, never mid-call; trailing '&' is plain bash, not a tool feature
pinned: false
created: 2026-09-29
modified: 2026-09-29
---
Tested 2026-09-29, then the tool was fixed the same day.

- `bash` waits `wait` seconds (default 15), then backgrounds and returns a PID + log file. `background: true` backgrounds at once. `timeout` (default 1800s, 0 = never) kills the whole process group. Old meaning of `timeout` (= wait) is gone.
- BG_PROCESS_DONE fires when the LAST process holding the output pipes exits, so `( job ) &` is tracked to its real end. Before the fix it reported "exit 0" at once — that was a tool bug, now gone; trust the flag.
- To let a daemon go, redirect its output: `nohup x >log 2>&1 &` returns immediately. It still dies if ori-agent restarts (same cgroup); for that use `systemd-run --user --scope`.
- alertOn reads the job's output pipe (including what it printed during the wait). Alerts and DONE are steer messages: they land before my next LLM call, but never cut a running tool call short.
