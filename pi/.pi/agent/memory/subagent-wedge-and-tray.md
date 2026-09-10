---
name: subagent-wedge-and-tray
summary: pi -p children wedged forever after answering a bg-job followUp (patched dist/main.js to waitForIdle+process.exit); ori-host tray rows now reconcile against the subagent registry — both fixes need an ori-host restart to be live
pinned: true
created: 2026-09-10
modified: 2026-09-10
---
2026-09-10 diagnosis: a pi `--mode json -p` child that processes a `bg_process_done` followUp turn NEVER exits — sits idle in epoll_wait indefinitely (reproduced 3x; control children without a followUp exit in ~3s; a never-finishing bg job without followUp also exits fine). Root fix patched into installed pi's dist/main.js print-mode branch: after runPrintMode, `await runtime.session.waitForIdle()` then `process.exit(exitCode)`. If pi is ever updated via bun, this patch disappears — re-check.

Second bug (fixed in ~/.dotfiles ori-host): BgJob.activity was declared but never joined — main.ts #onCatalogChange dropped "activity" changes and #broadcastBg never merged catalog.agentActivity; now joins by handle at broadcast time, re-broadcasts on activity change, and reconciles agent-kind tray rows against catalog.registryRows (settled status or dead pid → row dropped) with a 60s unref'd sweep. Tray rows were previously immortal when the delegate's report-back followUp died with the parent pi (research-compare-three showed 30+ min after death).

Testing pi children manually: must run from a trusted cwd (e.g. ~/.dotfiles — from /tmp tools are disabled: "bash isn't available"), stdin </dev/null (open stdin hangs even -p), and extension paths like /home/netanel/Development/... (NOT ~/.Development). Pre-existing failing test in ori-host: pi-argv "all four prompt files and all six extensions" — fails on clean tree too.
