import QtQuick
import Quickshell
import Quickshell.Io

// The gaming blackout, driven by sunshine-prep / sunshine-unprep.
//
//   sunshine-prep    ->  qs -p ~/.config/quickshell ipc call gameblank start
//   sunshine-unprep  ->  qs -p ~/.config/quickshell ipc call gameblank stop
//
// This exists because sunshine-prep used to hide the desk by DISABLING both
// physical monitors. With HEADLESS-1 the only output left, the GPU saw "all
// displays off", which is the one state that arms IPS2 on this DCN 3.5 part
// and hard-resets the machine (memory: amdgpu_dpms_reboot; it took the box
// down on 2026-09-20 11:19 at stream start). Covering the panels with a black
// surface leaves both display engines running, so that state is never reached.
//
// Nothing is built until `start`: the LazyLoader keeps the windows unbuilt, so
// a machine that never streams pays nothing for this file.
Scope {
  id: root

  property bool active: false

  function start() { root.active = true }
  function stop() { root.active = false }

  function toggle() {
    if (root.active) root.stop()
    else root.start()
  }

  LazyLoader {
    active: root.active

    component: Variants {
      // Physical panels only. Covering HEADLESS-1 would paint the black
      // surface straight into the video Sunshine is encoding -- the remote
      // player would get a black screen and the desk would stay lit, which is
      // exactly backwards.
      model: Quickshell.screens.filter(s => !s.name.startsWith("HEADLESS"))

      delegate: GameBlankWindow {
        onDismissed: root.stop()
      }
    }
  }

  IpcHandler {
    target: "gameblank"

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
