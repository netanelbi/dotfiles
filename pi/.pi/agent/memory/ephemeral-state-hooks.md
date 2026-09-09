---
name: ephemeral-state-hooks
summary: speak.ts/ambient.ts context hooks append [speech-state]/[ambient-state] before every LLM call; speech-state: voice-in orb = speak(), voice-mode on = speak by default, off = text unless asked
pinned: true
created: 2026-09-09
modified: 2026-09-09
---
Ephemeral state: speak.ts + ambient.ts `context` hooks append [speech-state] / [ambient-state] notes (assistant-role, own message — custom role gets flattened to user text on the wire, so assistant-role + tag prefix is the attribution fix) before EVERY LLM call — never persisted, cache-safe. speech-state = per-turn intent, three states: "voice-in: orb" → reply via speak() (voice-mode irrelevant); "voice-mode: on" → speak by default; "off" → text unless he asks. Explicit "speak" overrides off for that turn, never flips the mode.
