# Multi-session support for the Ori panel — minimal spec

Written 2026-09-07 by Ori, from Netanel's request. Bare minimum only.

## Problem

The panel has one live PiSession. Ctrl+N (new) and Ctrl+R (SessionPicker)
switch away from the current session; a turn mid-run is orphaned. No way to
know another session is still working.

Key point from Netanel: switching sessions must never stop a running turn.
Ctrl+N and Ctrl+R both park; several sessions can run at the same time.

## What is wanted — exactly this, nothing more

1. **Ctrl+N parks the current session.** The parked session's pi child keeps
   running; a turn mid-run finishes in the background. A new session becomes
   the active one.
2. **Ctrl+R also parks the current session.** Opening the picker and choosing
   any session — past or parked — never stops the active one. Many sessions
   can be mid-turn at the same time; each keeps its own running pi child.
3. **The picker shows every parked session** at the top of the existing
   list, each with an indicator while it is mid-turn. Picking a parked
   session switches to it instantly — transcript already in memory, no disk
   resume, no reload.

Out of scope (explicitly cut by Netanel): bar mark for background activity,
unread indicators, changes to usage/cost display.

## Implementation

- A SessionManager holds sessionId → PiSession instances. One is active and
  renders into the panel; the rest are parked — still connected, still
  updating their turn models, rendering nothing.
- SessionPicker reads busy state from the manager, not only from
  ori-sessions.json.
- Ctrl+C applies only to the active session.
- Lifecycle: if a parked busy session's pi child dies (10-min idle kill or
  cold spawn), the parked turn is shown as failed, never silently dropped.
- Cap parked sessions at 4; when full, the oldest idle one is flushed to disk
  resume only.