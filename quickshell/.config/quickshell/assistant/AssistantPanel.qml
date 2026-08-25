import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
// Theme/Style/PiSession are singletons in the config root; a subdirectory does
// not get the root's implicit import, so pull it in explicitly.
import ".."

// The assistant panel: a conversation docked to the right edge.
//
// This deliberately is NOT a launcher. The five launchers are modal -- they take
// the keyboard exclusively, you pick one thing, they vanish. A conversation is
// the opposite shape: it stays up while you work, you go back and forth with it,
// and what was said five minutes ago is still on screen. So:
//
//   * WlrKeyboardFocus.OnDemand, not Exclusive. The panel can sit open next to a
//     terminal and only takes the keyboard when you click into it. Exclusive
//     would make the rest of the desktop unusable while it is up, which is fine
//     for a launcher you dismiss in two seconds and wrong for this.
//   * WlrLayer.Top, not Overlay -- it belongs above windows but below the
//     notification popups and the OSD, which still need to be seen over it.
//   * exclusionMode Ignore: it floats over the tiling instead of reshuffling
//     every window each time it opens.
//
// The transcript lives in PiSession, not here, so closing the panel loses
// nothing -- including mid-answer, since the process keeps writing into the turn
// model with no window attached.
//
// IPC:  qs ipc call assistant toggle | open | close | ask <text> | status
PanelWindow {
  id: panel

  property bool opened: false

  function open() { panel.opened = true; Qt.callLater(function () { entry.forceActiveFocus() }) }
  function close() { panel.opened = false }
  function toggle() { if (panel.opened) close(); else open() }

  // --------------------------------------------------------------- geometry
  // Opens on whichever monitor has focus, the same rule the launchers and the
  // polkit dialog use. Only re-targeted while closed: moving a live layer
  // surface between outputs mid-animation is a configure round trip per frame.
  function focusedScreen() {
    var focused = Hyprland.focusedMonitor
    if (!focused) return panel.screen
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (Hyprland.monitorFor(screens[i]) === focused) return screens[i]
    }
    return panel.screen
  }

  readonly property int panelWidth: 460

  WlrLayershell.namespace: "quickshell-assistant"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
  exclusionMode: ExclusionMode.Ignore

  anchors { top: true; bottom: true; right: true }
  // The SURFACE is a fixed width and never resizes; the card slides inside it.
  // A layer surface that changes size waits on a compositor configure/ack per
  // frame, which is what turned the notification popups into a slideshow before
  // they were sized once and animated internally.
  implicitWidth: panelWidth + 24
  color: "transparent"

  visible: opened || revealed > 0.001
  property real revealed: 0

  onOpenedChanged: {
    // Re-target only on the way IN, while the surface is off screen: moving a
    // live layer surface between outputs costs a configure round trip per frame.
    if (opened) panel.screen = focusedScreen()
    revealed = opened ? 1 : 0
  }

  Behavior on revealed {
    NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
  }

  // Only the card takes clicks; the empty strip beside it stays click-through so
  // the desktop underneath is still usable with the panel open.
  mask: Region {
    x: card.x
    y: card.y
    width: card.width
    height: card.height
  }

  // ------------------------------------------------------------------- card
  Rectangle {
    id: card

    width: panel.panelWidth
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.topMargin: Style.bar.height + 8
    anchors.bottomMargin: 8
    x: parent.width - width - 12 + (1 - panel.revealed) * (width + 24)
    opacity: panel.revealed

    color: Theme.base
    radius: 16
    border.width: 2
    border.color: Theme.sapphire
    clip: true

    // ---------------------------------------------------------------- header
    Rectangle {
      id: header
      anchors { top: parent.top; left: parent.left; right: parent.right }
      height: 44
      color: Theme.surface0

      Text {
        anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
        text: "Ori"
        color: Theme.sapphire
        font.family: Style.font.family
        font.pixelSize: Style.font.size
        font.weight: Style.font.boldWeight
        renderType: Text.NativeRendering
      }

      // Doubles as the liveness indicator: the model name while idle, what it is
      // doing while not. Cheaper than a spinner and says more.
      Text {
        anchors { right: newBtn.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
        text: PiSession.busy ? "thinking…" : PiSession.warm ? PiSession.model : "cold"
        color: PiSession.busy ? Theme.sapphire : Theme.overlay0
        font.family: Style.font.family
        font.pixelSize: Style.font.tiny
        renderType: Text.NativeRendering

        Behavior on color {
          ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
        }
      }

      Rectangle {
        id: newBtn
        anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
        width: 24; height: 24; radius: 6
        color: newArea.containsMouse ? Theme.hoverBackground : "transparent"

        Text {
          anchors.centerIn: parent
          text: "＋"
          color: Theme.overlay0
          font.family: Style.font.family
          font.pixelSize: Style.font.size
          renderType: Text.NativeRendering
        }

        MouseArea {
          id: newArea
          anchors.fill: parent
          hoverEnabled: true
          onClicked: PiSession.newChat()
        }
      }
    }

    // ------------------------------------------------------------ transcript
    ListView {
      id: transcript

      anchors {
        top: header.bottom
        left: parent.left
        right: parent.right
        bottom: composer.top
        margins: 10
      }

      model: PiSession.turns
      spacing: 10
      clip: true
      // A conversation is read from the bottom, so that is where it rests.
      verticalLayoutDirection: ListView.BottomToTop
      // BottomToTop inverts the model, so index 0 must be the NEWEST turn --
      // hence the delegate reads its row back through `count - 1 - index`.
      // Doing it this way rather than scrolling a normal list is what keeps the
      // view pinned to the newest token for free while a turn streams.

      delegate: Item {
        required property int index
        readonly property var turn: PiSession.turns.get(PiSession.turns.count - 1 - index)

        width: ListView.view.width
        height: bubble.height

        Rectangle {
          id: bubble
          // A user turn is a right-aligned pill; the assistant answers full
          // width. The asymmetry is the only thing marking who said what --
          // no labels, no avatars, no timestamps.
          width: turn.role === "user"
            ? Math.min(parent.width * 0.85, body.implicitWidth + 24)
            : parent.width
          x: turn.role === "user" ? parent.width - width : 0
          // Measured from the column rather than summed by hand: the reasoning
          // and tool rows animate their own heights, and an arithmetic guess
          // that forgets a margin clips whichever row is last -- which is
          // exactly the tool row, the one that most needs to be seen.
          height: col.implicitHeight + 16
          radius: 10
          color: turn.role === "user" ? Theme.surface1 : "transparent"

          Column {
            id: col
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: 8 }
            spacing: 0

            Text {
              id: body
              width: parent.width
              // A turn with nothing in it yet must not collapse to zero height,
              // or the list jumps the moment the first token lands.
              text: turn.text !== "" ? turn.text : (turn.pending ? " " : "")
              color: Theme.text
              wrapMode: Text.Wrap
              // The model answers in markdown, so render it -- otherwise every
              // emphasis arrives as literal **asterisks** and every code span as
              // backticks. Mid-stream an unclosed marker renders as plain text
              // and settles the moment its partner arrives, which is invisible
              // at these token rates.
              textFormat: Text.MarkdownText
              font.family: Style.font.family
              font.pixelSize: Style.font.size
              renderType: Text.NativeRendering
            }

            // Streamed reasoning, shown ONLY while the answer is still empty. It
            // arrives ~300ms in, so it is the loading state -- and unlike a
            // spinner it tells you within a second whether it understood you.
            // Once real text starts it is dropped, not kept.
            Item {
              id: reasoning
              width: parent.width
              height: showing ? reasonText.implicitHeight + 6 : 0
              clip: true

              readonly property bool showing:
                turn.role === "assistant" && turn.text === "" && turn.thinking !== ""

              Behavior on height {
                NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
              }

              Text {
                id: reasonText
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                text: turn.thinking
                color: Theme.overlay0
                font.italic: true
                wrapMode: Text.Wrap
                font.family: Style.font.family
                font.pixelSize: Style.font.small
                renderType: Text.NativeRendering
              }
            }

            // The other half of "show the work": while a tool runs nothing
            // streams at all, and without this the panel looks frozen for the
            // whole several seconds a bash call takes.
            Item {
              id: toolRow
              width: parent.width
              height: turn.tool !== "" ? 22 : 0
              clip: true

              Behavior on height {
                NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
              }

              Text {
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                text: "⟩ " + turn.tool
                color: Theme.sapphire
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.small
                renderType: Text.NativeRendering
              }
            }
          }
        }
      }
    }

    // The empty state, in place of a blank rectangle.
    Text {
      anchors.centerIn: transcript
      visible: PiSession.turns.count === 0
      text: "Ask me anything."
      color: Theme.overlay0
      font.family: Style.font.family
      font.pixelSize: Style.font.size
      renderType: Text.NativeRendering
    }

    // -------------------------------------------------------------- composer
    Rectangle {
      id: composer
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      // Grows with the draft up to a ceiling, then the field scrolls. The card
      // is a fixed size, so this only moves the boundary between the two panes.
      height: Math.min(entry.implicitHeight, 120) + 20
      color: Theme.surface0

      Behavior on height {
        NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing }
      }

      TextEdit {
        id: entry
        anchors { fill: parent; margins: 10 }

        color: Theme.text
        selectionColor: Theme.sapphire
        selectedTextColor: Theme.base
        selectByMouse: true
        wrapMode: TextEdit.Wrap
        font.family: Style.font.family
        font.pixelSize: Style.font.size
        renderType: Text.NativeRendering
        clip: true

        Text {
          anchors.fill: parent
          visible: entry.text === ""
          text: PiSession.busy ? "…" : "Message"
          color: Theme.overlay0
          font.family: Style.font.family
          font.pixelSize: Style.font.size
          renderType: Text.NativeRendering
        }

        Keys.onPressed: function (event) {
          switch (event.key) {
          case Qt.Key_Return:
          case Qt.Key_Enter:
            // Shift+Enter is a newline; a bare Enter sends. The multi-line field
            // exists for pasting a stack trace, not for composing essays.
            if (event.modifiers & Qt.ShiftModifier) return
            // Only clear the draft if it was actually taken. Asking while a turn
            // is still running is refused, and clearing anyway would delete what
            // you just typed with nothing to show for it.
            if (PiSession.ask(entry.text)) entry.text = ""
            event.accepted = true
            return
          case Qt.Key_Escape:
            panel.close()
            event.accepted = true
            return
          case Qt.Key_N:
            if (event.modifiers & Qt.ControlModifier) {
              PiSession.newChat()
              event.accepted = true
            }
            return
          case Qt.Key_C:
            // Ctrl+C stops the model; with a selection it is a copy, so only
            // claim it while something is actually running and nothing is selected.
            if ((event.modifiers & Qt.ControlModifier) && PiSession.busy
                && entry.selectedText === "") {
              PiSession.abort()
              event.accepted = true
            }
            return
          }
        }
      }
    }

    // ----------------------------------------------------------------- error
    Rectangle {
      anchors { left: parent.left; right: parent.right; bottom: composer.top }
      height: PiSession.error !== "" ? errText.implicitHeight + 12 : 0
      color: Theme.alpha(Theme.red, 0.15)
      clip: true

      Behavior on height {
        NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
      }

      Text {
        id: errText
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 6 }
        text: PiSession.error
        color: Theme.red
        wrapMode: Text.Wrap
        font.family: Style.font.family
        font.pixelSize: Style.font.small
        renderType: Text.NativeRendering
      }
    }
  }
}
