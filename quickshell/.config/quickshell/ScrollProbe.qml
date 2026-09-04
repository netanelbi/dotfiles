pragma Singleton

import QtQuick

// A hand the script surface can reach into. The transcript's scroll state
// exists only inside the panel, and a panel is not a thing a shell command
// can read -- so the panel hands its transcript here on completion and
// OriIpc's `scroll` reads the live geometry through it. Diagnostic only; it
// holds no behaviour of its own.
QtObject {
  property var list: null
  property var panel: null
}