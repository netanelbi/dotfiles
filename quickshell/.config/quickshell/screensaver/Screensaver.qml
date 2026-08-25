import QtQuick
import Quickshell
import Quickshell.Io

// The screensaver, driven by hypridle.
//
//   hypridle.conf   timeout 150  ->  qs -p ~/.config/quickshell ipc call screensaver start
//                   lock_cmd     ->  qs ... ipc call screensaver stop ; hyprlock
//
// Nothing exists until `start`: LazyLoader keeps the windows, the shader and
// the frame clock unbuilt, so an idle machine that never reaches 150s pays
// nothing at all for this file.
Scope {
  id: root

  property bool active: false

  function start() {
    if (root.active) return
    // Never draw behind the lock. hypridle fires the screensaver at 150s and
    // locks at 300s, but a lock can arrive first (SUPER+L, lid close,
    // loginctl lock-session) and idle keeps counting underneath it -- so the
    // 150s timeout can land while hyprlock owns the session. The compositor
    // would stack the lock above this surface anyway; the point is to not
    // spend a GPU on a shader nobody can see.
    lockCheck.running = true
  }

  function stop() {
    root.active = false
  }

  function toggle() {
    if (root.active) root.stop()
    else root.start()
  }

  Process {
    id: lockCheck
    command: ["pidof", "hyprlock"]
    // pidof exits 1 when nothing matches, which is the case we want.
    onExited: function (exitCode) {
      if (exitCode !== 0) root.active = true
    }
  }

  LazyLoader {
    active: root.active

    component: Variants {
      model: Quickshell.screens

      delegate: ScreensaverWindow {
        onDismissed: root.stop()
      }
    }
  }

  IpcHandler {
    target: "screensaver"

    function start(): string {
      root.start()
      return "ok"
    }

    function stop(): string {
      root.stop()
      return "ok"
    }

    function toggle(): string {
      root.toggle()
      return root.active ? "open" : "closed"
    }

    function status(): string {
      return root.active ? "open" : "closed"
    }
  }
}
