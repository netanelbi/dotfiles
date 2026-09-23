import QtQuick
import Quickshell
import Quickshell.Wayland

// One black surface over one physical panel. Variants makes one per monitor.
//
// Deliberately different from ScreensaverWindow in three ways:
//
//   * keyboardFocus None. The screensaver grabs the keyboard Exclusive so any
//     key dismisses it. Here the remote player is typing into a game, and
//     Sunshine's injected keys are indistinguishable from real ones at the
//     Wayland level -- an exclusive grab would eat the game's input, and every
//     remote keypress would dismiss the blackout. Waking up is instead driven
//     by sunshine-blank-watch, which reads the real (non-virtual) evdev nodes.
//   * Pure black, no shader and no art. The point is to stop lighting the desk
//     and to leave the whole GPU for the game's encoder.
//   * No entrance fade. Nobody is watching this surface appear; the person who
//     would see it has walked away.
PanelWindow {
  id: win

  signal dismissed()

  // Variants hands each delegate its screen through modelData.
  property var modelData: null
  screen: modelData

  WlrLayershell.namespace: "quickshell-gameblank"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore

  // All four edges: the surface is sized once, by the compositor, and never
  // resized. See CLAUDE.md -- a layer surface that changes size waits for a
  // configure/ack round trip per frame.
  anchors { top: true; bottom: true; left: true; right: true }

  color: "black"

  // Not an idle inhibitor: sunshine-prep already holds a logind idle inhibit
  // for the whole stream (the sunshine-inhibit transient unit).

  // Manual escape hatch. sunshine-blank-watch is the intended way out, so this
  // only matters if the watcher died -- without it a dead watcher would leave
  // the desk black with no way back short of an ipc call. Sunshine keeps its
  // pointer on HEADLESS-1, which this surface does not cover, so a remote
  // player cannot reach it.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    onPressed: win.dismissed()
  }
}
