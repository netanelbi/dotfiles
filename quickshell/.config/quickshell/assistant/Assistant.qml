import Quickshell
import Quickshell.Io
// PiSession is a singleton in the config root; a subdirectory does not get the
// root's implicit import, so pull it in explicitly.
import ".."

// Mount point for the assistant, so shell.qml adds one line:
//
//     Assistant { }
//
// The window is built lazily -- nothing exists (and above all no `pi` process)
// until the panel is first opened. The IpcHandler has to exist from the start
// though, since it is what the keybind talks to, so it lives out here rather
// than inside the LazyLoader.
Scope {
  id: root

  // The bar indicator toggles the panel too, so "is it open" cannot live in
  // this file alone -- it is on PiSession, which both windows can see.
  readonly property bool opened: PiSession.panelOpen

  // Held true through the exit animation so the panel can slide out before it is
  // destroyed. It is a plain flag PUSHED by the panel rather than `active`
  // reading back `loader.item.revealed` -- that reads a property of the very
  // object the binding decides the existence of, which Quickshell correctly
  // reports as a binding loop.
  property bool retain: false

  LazyLoader {
    id: loader
    // `activeAsync` would let the first SUPER+A open onto a half-built window;
    // the panel is small enough that building it synchronously is imperceptible.
    active: root.opened || root.retain

    component: AssistantPanel {
      opened: root.opened
      // Opening it IS reading it -- the bright dot in the bar cannot be
      // dismissed without the answer actually being on screen.
      onOpenedChanged: if (opened) PiSession.unread = false
      onRevealedChanged: root.retain = revealed > 0.001
    }
  }

  IpcHandler {
    target: "assistant"

    function toggle(): string {
      PiSession.panelOpen = !PiSession.panelOpen
      return PiSession.panelOpen ? "opened" : "closed"
    }

    function open(): string {
      PiSession.panelOpen = true
      return "opened"
    }

    function close(): string {
      PiSession.panelOpen = false
      return "closed"
    }

    // Ask without opening the panel, so a script can drive it:
    //   qs ipc call assistant ask "why is the fan loud"
    // The answer lands in the transcript either way, so opening the panel later
    // shows it.
    function ask(question: string): string {
      PiSession.ask(question)
      return "asked"
    }

    function clear(): string {
      PiSession.newChat()
      return "cleared"
    }

    function status(): string {
      return PiSession.busy ? "busy" : PiSession.warm ? "warm" : "cold"
    }

    // The last assistant turn as plain text, so `ask` + `answer` is a usable
    // pair from a script: ask, poll status until it leaves "busy", read this.
    function answer(): string {
      if (PiSession.error !== "") return "error: " + PiSession.error
      var i = PiSession.lastAssistant()
      return i < 0 ? "" : PiSession.turns.get(i).text
    }
  }
}
