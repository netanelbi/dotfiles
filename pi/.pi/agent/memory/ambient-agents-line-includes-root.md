---
name: ambient-agents-line-includes-root
summary: The [ambient-state] "agents:" line lists my own session too (registry entry kind:"root"), so it is not a delegate list
pinned: false
created: 2026-09-11
modified: 2026-09-11
---
~/.pi/agent/subagents/registry.json holds the current session as well as delegates, distinguished by "kind": "root" vs a delegate kind. Its "task" field is empty for the root, and the description shown in the ambient line is the root's most recent tool description — which makes it look like a running delegate named after whatever I last did.

Practical rule: before telling the owner "N delegates are running", read registry.json and count entries with kind != "root". Session id suffix (last 6 hex) is the handle, e.g. dotfiles-5a5200 was my own session, not a child.
