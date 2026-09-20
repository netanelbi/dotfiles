---
name: ori-self-wake-targets-active-conversation
summary: An ask on a BUSY conversation is steered into the running turn (conversation.ts ask() -> steer: busy), never a new turn — so anything the main agent does by itself hijacks the owner's next question; fix = origin: human|self on turns + preempt, strip long tools, task row before work starts
pinned: true
created: 2026-09-19
modified: 2026-09-19
---
Verified 2026-09-19 against ori-host/src/conversation.ts (ask(), ~line 456: `const steer = this.st.busy`) and main.ts #ask on the active conversation; Assistant.qml ask() -> OriClient.ask.

Two consequences of the same seam:
1. A self-wake (`qs ipc call assistant ask`, systemd-run timer) lands in whatever conversation is ACTIVE, so it can interrupt/steer the owner.
2. A human ask on a busy conversation does NOT start a new turn — it is queued into steerQueue and appended to the running turn, so a self-started or long task hijacks the question rather than merely delaying it.

Availability is therefore blocked by OCCUPANCY, not by process lifetime. Agreed direction: (a) tag turns origin: human|self and let a human ask preempt a self-origin turn (barge-in, an orchestrator rule); (b) front-desk capability boundary — no tools that can run long, delegation via backgrounded job only (BgJob reports bg_process_done; BackgroundTray reconciles with the subagent registry); (c) a durable task row + written handoff BEFORE work starts, so preemption loses nothing. State: `bd` has no database in ~/.dotfiles (`no beads database found`), ~/.pi/agent/tasks.json holds only test rows — step (c) is real work.

Continuity that DOES exist: pinned prefix ~11.9KB (soul 3.4K + laptop 4.2K + MEMORY index 2.8K + user 1.5K) via --append-system-prompt; 18 memory files; pi compaction (keepRecentTokens 8000, reserveTokens 6000); rehydrate.ts -> turns wired at main.ts:903 (display only; model context comes from pi reloading the session). Pool: 600s idle kill, 90s orphan grace, 4 parked max.
