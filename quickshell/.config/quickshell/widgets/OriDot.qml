import QtQuick
import Quickshell
import Quickshell.Io
import "root:/"

// Ori's presence in the bar.
//
// The panel was built so that closing it does not cancel -- the process keeps
// working with no window attached and the answer is simply there next time. That
// is only a feature if something tells you it happened. Without this widget it
// is a black hole: you ask, you close, and you never learn it finished.
//
// So the diamond is the assistant's heartbeat, and it says exactly one thing at
// a time:
//
//   gone     nothing running, nothing unread. The bar is not a place to
//            advertise an idle process.
//   dim      warm and idle -- a question now costs 1.2s instead of 2.3s.
//            Worth knowing, not worth looking at.
//   pulsing  thinking. The pulse is slow and never fully fades: a heartbeat,
//            not a blink.
//   solid    an answer is waiting and the panel is closed. This is the only
//            state that is BRIGHT, because it is the only one that wants you.
//
// Click toggles the panel; clicking while an answer waits is what clears the
// unread state, so the bright dot cannot be dismissed without being read.
BarWidget {
  id: root

  // .active { margin: 0 4px } -- the same 8px footprint every compact
  // indicator here uses.
  horizontalPadding: Style.module.indicatorPaddingH

  // `unread` lives on PiSession so opening the panel from anywhere clears it.
  readonly property bool unread: PiSession.unread

  shown: PiSession.busy || root.unread || PiSession.warm

  tooltip: PiSession.busy
      ? (PiSession.turns.count > 0 && PiSession.turns.get(PiSession.lastAssistant()).tool !== ""
          ? "Ori: " + PiSession.turns.get(PiSession.lastAssistant()).tool
          : "Ori is thinking…")
      : root.unread ? "Ori answered — click to read"
      : "Ori is warm · click to open"

  onClicked: PiSession.panelOpen = !PiSession.panelOpen

  Text {
    id: dot
    text: "◇"
    // soul.md signs Ori's own work with this diamond, so the bar and the
    // transcript are marked with the same glyph.
    color: root.unread ? Theme.sapphire
      : PiSession.busy ? Theme.sapphire
      : Theme.inactive
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    renderType: Text.NativeRendering

    Behavior on color {
      ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
    }

    // THE HEARTBEAT. Opacity rather than scale, because a bar 30px tall has no
    // room for something that grows, and it bottoms out at 0.35 rather than 0 --
    // a dot that disappears reads as a fault, a dot that dims reads as breathing.
    SequentialAnimation {
      running: PiSession.busy
      loops: Animation.Infinite
      alwaysRunToEnd: true

      NumberAnimation {
        target: dot; property: "opacity"; to: 0.35
        duration: 700; easing.type: Style.anim.easingSmooth
      }
      NumberAnimation {
        target: dot; property: "opacity"; to: 1
        duration: 700; easing.type: Style.anim.easingSmooth
      }
    }

    // Leaving the pulse mid-breath would strand the dot at whatever opacity the
    // animation happened to reach.
    onOpacityChanged: if (!PiSession.busy && opacity !== 1) opacity = 1
  }

  // A single ring when an answer lands, expanding out of the dot and fading.
  // It fires once per answer and costs nothing the rest of the time -- the
  // Rectangle has no size and no colour until the animation drives it.
  Item {
    width: 0
    height: 0

    Rectangle {
      id: ring
      anchors.centerIn: parent
      width: 0
      height: width
      radius: width / 2
      color: "transparent"
      border.width: 1
      border.color: Theme.sapphire
      opacity: 0
    }

    ParallelAnimation {
      id: ping
      NumberAnimation { target: ring; property: "width"; from: 4; to: 26; duration: 520; easing.type: Style.anim.easing }
      SequentialAnimation {
        NumberAnimation { target: ring; property: "opacity"; from: 0; to: 0.8; duration: 120 }
        NumberAnimation { target: ring; property: "opacity"; to: 0; duration: 400; easing.type: Style.anim.easingSmooth }
      }
    }

    Connections {
      target: PiSession
      // Only when the panel is CLOSED. With the panel open the answer is already
      // arriving in front of you and a second announcement is noise.
      function onSettled() {
        if (PiSession.panelOpen) return
        PiSession.unread = true
        ping.restart()
        notify.running = true
      }
    }
  }

  // The desktop's own notification server is this same process, so a plain
  // `notify-send` is the shortest path back to it -- no internal coupling, and
  // it lands in the notification centre with everything else, which is where
  // someone would look for a message they missed.
  Process {
    id: notify
    command: ["notify-send", "-a", "Ori", "-i", "dialog-information", "Ori",
              PiSession.error !== "" ? PiSession.error : root.lastAnswer()]
  }

  function lastAnswer() {
    var i = PiSession.lastAssistant()
    if (i < 0) return "Done."
    var t = String(PiSession.turns.get(i).text).trim()
    if (t === "") return "Done."
    // The popup is a few lines tall; the full answer is in the panel.
    return t.length > 220 ? t.substring(0, 220) + "…" : t
  }

  onShownChanged: if (shown) appear.restart()

  NumberAnimation {
    id: appear
    target: dot
    property: "scale"
    from: 0.4
    to: 1
    duration: Style.anim.reveal
    easing.type: Style.anim.easingEnter
    easing.overshoot: Style.anim.overshoot
  }
}
