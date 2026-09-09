---
name: panel-scroll-internals
summary: AssistantPanel ListView: BTT contentY anchors, wheel faces must be siblings, reading-anchor capture points, qmltestrunner harness
pinned: false
created: 2026-09-09
modified: 2026-09-09
---
BTT ListView: newest at contentY == -height, oldest at -contentHeight; both collapse to -height when content fits. Flickable with content smaller than viewport drops wheel events to children — wheel faces must be siblings. Touchpad wheel = pixelDelta, apply 1:1, no animation. Reading anchor: while unstuck the view anchors on a DELEGATE (updateReadAnchor/reaimReadAnchor; readIndex adjusted by count delta — appends prepend, shrink = session switch → invalidate). Capture at onContentYChanged (unstuck+laidOut) and end of wheelPixels (its contentY write fires while stuck is still true — order is load-bearing). Harness: /usr/lib/qt6/bin/qmltestrunner -platform offscreen -input <file>. Selection: Selection.qml singleton + SelectableArea. ListView geometry traps and dpms: ~/.dotfiles/CLAUDE.md.
