pragma Singleton

import QtQuick
import Quickshell

// Selection copying for the assistant panel.
//
// Selecting text puts it on the clipboard by itself -- no Ctrl+C, no menu.
// That is how the panel is used: you drag across a path or a command and you
// want it, and reaching for a second key to confirm an intention you already
// expressed is a step that only exists because most apps cannot tell the
// difference between selecting and wanting.
//
// It is safe here in a way it would not be in an editor, because the
// transcript is READ-ONLY: the only thing a selection can mean is "this".
//
// `wl-copy` rather than a QML clipboard API: this is the Wayland tool the rest
// of the desktop already uses (see CLAUDE.md), and it puts the text on the
// same clipboard cliphist is watching, so a copy from Ori shows up in the
// clipboard history like any other.
Singleton {
  id: root

  // The last thing copied, and when -- the panel binds its toast to `at`
  // rather than to a signal, so a second copy while the first is still on
  // screen restarts the same toast instead of stacking another one.
  property string last: ""
  property double at: 0

  // A drag emits a new selection on every pixel of movement. Copying each one
  // would run a process per frame and leave the clipboard holding whatever the
  // cursor happened to be over when it stopped moving, so the copy waits for
  // the drag to settle. Short enough to feel immediate, long enough that no
  // ordinary drag outruns it.
  readonly property int settleMs: 220

  property string queued: ""

  function take(text) {
    var t = String(text || "")
    // Deselecting (a plain click) must not clear what you just copied.
    if (t === "") return
    root.queued = t
    settle.restart()
  }

  Timer {
    id: settle
    interval: root.settleMs
    onTriggered: {
      if (root.queued === "") return
      // `--` so a selection beginning with a dash is text, not a flag.
      Quickshell.execDetached(["wl-copy", "--", root.queued])
      root.last = root.queued
      root.queued = ""
      root.at = Date.now()
    }
  }
}
