---
name: notification-ignores
summary: Notification "never show again" list: $XDG_STATE_HOME/quickshell/notification-ignores.json, rules {app,summary} matched by prefix; driven by qs ipc call notifications ignored|ignore|unignore
pinned: true
created: 2026-09-16
modified: 2026-09-16
---
The quickshell notification centre (services/Notifications.qml) has a second, user-owned blocklist beside the hardcoded blockedApps/historyOnlyApps arrays.

- Rules live in $XDG_STATE_HOME/quickshell/notification-ignores.json (state, not the dotfiles repo): {"version":1,"rules":[{"app":..,"summary":..}]}.
- A rule matches by case-insensitive PREFIX on app-name AND summary; empty summary = whole app. Prefixes so a version number does not resurrect the notification.
- Ignored notifications are expired at the door: no popup, no history, sender told.
- UI: hover a row in the control centre (the panel Super+N toggles), click the struck-bell button left of ✕. An 8s "Ignoring · <app> — <summary>" toast in the panel has the Undo.
- Script/terminal: `qs ipc call notifications ignored` (one line per rule), `ignore "<app>" "<summary>"`, `unignore "<app>" "<summary>"`. Multi-word args need shell quoting — qs ipc takes argv as-is.
- hideOnAction is deliberately false there (swaync's default true shut the panel on every action click); the notification still closes, only the panel stays.
