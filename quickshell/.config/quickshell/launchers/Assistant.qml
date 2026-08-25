import QtQuick
import Quickshell
import Quickshell.Io
// Theme/Style/PiSession are singletons in the config root; a subdirectory does
// not get the root's implicit import, so pull it in explicitly.
import ".."

// The sixth launcher: ask a question, read the answer, close.
//
// It lives here rather than in a directory of its own because it IS a launcher
// -- same card, same backdrop, same entrance, same Escape, and the same
// exclusive-focus handover through the Launchers group. What it is NOT is a chat
// window; there is one exchange on screen at a time. A launcher that answers
// questions, not a terminal with extra steps.
//
// IPC:  qs ipc call assistant toggle | open | close
//
// ------------------------------------------------------------------- waiting
// Every other launcher answers instantly (qalc takes 90ms). This one takes
// 1.2s, or ~5s once it runs a tool. That is the whole design problem, and the
// answer is: never show a spinner, show the work.
//
//   * the prompt pill flips Ask -> Thinking. That is the "it is running" signal.
//   * reasoning streams into the body ~300ms in, dimmed. Within one second you
//     can see whether it understood the question, which a spinner never tells you.
//   * the first token of the real answer replaces it.
//   * a tool call shows as one line naming the tool and its argument.
//
// ------------------------------------------------------------------ detaching
// Escape closes the panel; it does NOT cancel. The session lives in PiSession
// (a singleton), so the question keeps running with nothing on screen and the
// finished answer is simply there the next time the panel opens. Nothing had to
// be built for that -- it falls out of the engine outliving the window.
Scope {
  id: root

  property var group: null

  LauncherPanel {
    id: panel

    // Distinct from the five rofi replacements (apps/clipboard green/calc
    // green/emoji/power) so the accent alone says which overlay is up.
    prompt: PiSession.busy ? "Thinking" : "Ask"
    accent: Theme.sapphire
    panelWidth: 620
    cornerRadius: 16
    placeholder: "Ask anything…"
    // Nothing to navigate: one question, one answer.
    list: null

    onPresented: if (root.group) root.group.claim(panel)
    onDismissed: if (root.group) root.group.release(panel)
    onAccepted: PiSession.ask(panel.query)

    // ---------------------------------------------------------------- body
    Item {
      width: parent.width
      // Collapsed to nothing until there is something to say, so an unasked
      // panel is just the input bar -- and it opens as the first token lands.
      height: bodyText.text === "" ? 0 : bodyText.implicitHeight + 40
      clip: true

      Behavior on height {
        NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
      }

      Text {
        id: bodyText
        anchors.centerIn: parent
        width: parent.width - 40

        // Strict precedence, and the order is the point: an error always wins,
        // then the answer, and reasoning only shows while there is no answer
        // yet. So the thinking text IS the loading state, and it is replaced
        // rather than accumulated the moment the real answer starts streaming.
        text: PiSession.error !== "" ? PiSession.error
          : PiSession.answer !== "" ? PiSession.answer
          : PiSession.thinking

        color: PiSession.error !== "" ? Theme.red
          : PiSession.answer !== "" ? Theme.text
          : Theme.overlay0
        font.italic: PiSession.answer === "" && PiSession.error === ""

        wrapMode: Text.Wrap
        font.family: Style.font.family
        font.pixelSize: Style.font.size
        renderType: Text.NativeRendering

        Behavior on color {
          ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
        }
      }
    }

    // ---------------------------------------------------------------- tool
    // The other half of "show the work": while a tool runs there is no text
    // streaming at all, so without this the panel looks frozen for the whole
    // five seconds a bash call takes.
    Item {
      width: parent.width
      height: PiSession.tool === "" ? 0 : 26
      clip: true

      Behavior on height {
        NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
      }

      Text {
        anchors.centerIn: parent
        width: parent.width - 40
        text: "⟩ " + PiSession.tool
        color: Theme.sapphire
        elide: Text.ElideRight
        font.family: Style.font.family
        font.pixelSize: Style.font.small
        renderType: Text.NativeRendering
      }
    }

    // ---------------------------------------------------------------- hint
    Item {
      width: parent.width
      height: 30

      Text {
        anchors.centerIn: parent
        // Escape not cancelling is the one genuinely surprising thing here, so
        // it is what the hint spends its line on.
        text: PiSession.busy ? "Esc leaves it running" : "Enter asks"
        color: Theme.overlay0
        opacity: panel.query !== "" || PiSession.busy ? 1 : 0
        font.family: Style.font.family
        font.pixelSize: Style.font.small
        renderType: Text.NativeRendering

        Behavior on opacity {
          NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
        }
      }
    }
  }

  // ------------------------------------------------------------------ ipc
  IpcHandler {
    target: "assistant"

    function toggle(): string {
      panel.toggle()
      return panel.opened ? "opened" : "closed"
    }

    function open(): string {
      panel.present()
      return "opened"
    }

    function close(): string {
      panel.dismiss()
      return "closed"
    }

    // Ask without opening the panel at all, so a script can drive it:
    //   qs ipc call assistant ask "why is the fan loud"
    function ask(question: string): string {
      PiSession.ask(question)
      return "asked"
    }

    function status(): string {
      return PiSession.busy ? "busy" : PiSession.warm ? "warm" : "cold"
    }

    // The last answer as plain text, so `ask` + `answer` is a usable pair from
    // a script: ask, poll status until it leaves "busy", read this.
    function answer(): string {
      return PiSession.error !== "" ? "error: " + PiSession.error : PiSession.answer
    }
  }
}
