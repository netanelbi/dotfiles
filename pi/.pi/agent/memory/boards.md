---
name: boards
summary: Floating desktop cards: read ~/.pi/agent/skills/board/SKILL.md before driving them; qs ipc call board <qml|html|question|move|read|snapshot|close> <name>
pinned: true
created: 2026-09-09
modified: 2026-09-09
---
Boards (floating desktop cards I spawn): see the "board" skill at ~/.pi/agent/skills/board/SKILL.md BEFORE driving them. `qs ipc call board <qml|html|question|move|read|snapshot|close> <name> ...`; answers return as "[name]" turns; `read` shows free-form drafts live; placement auto-avoids the panel and other boards.

Full screen: the header's ⛶ button in Board.qml (assistant/Board.qml, toggleFullscreen) fills the screen down to the bar strip and remembers the old size/place; `qs ipc call board fullscreen <name>` does the same, and an explicit `resize` cancels it. While maximized the card ignores the panel strip (clampPos has a maximized branch) and onOpenedChanged skips re-placing it.
