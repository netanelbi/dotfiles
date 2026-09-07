import QtQuick
import "root:/"
import "../assistant"

// The orb's perch: the left end of the bar's centre pill. This is where Ori
// lives when nothing is happening -- a small, dim spirit resting on the
// clock, breathing not at all (a permanent animation in the bar is a cost).
//
// It is HIDDEN, not moved, when the orb is elsewhere: the overlay draws the
// orb leaving from exactly this spot when you talk, and the panel draws it at
// the input row while the panel is open. Two windows cannot share one item,
// so the flight is a hand-off -- this fades as that appears.
Item {
  id: root

  // Out for voice: the perch closes up and the pill shrinks around the gap --
  // the orb has LEFT, and the bar says so. Into the panel: the perch stays,
  // and a dark hole is left where the orb was, until it comes back.
  readonly property bool outVoice: (OriClient.voiceState !== "hidden" || OriClient.orbFree) && !OriClient.panelOpen
  readonly property bool inPanel: OriClient.panelOpen
  readonly property bool away: outVoice || inPanel

  // Out, the perch shrinks to a nest: a faint dot, and a place to click to
  // call it home. Not zero -- a gap you cannot point at is not a control.
  implicitWidth: outVoice ? 12 : Style.ori.haloBox + 6
  implicitHeight: Style.bar.islandHeight
  clip: true
  Behavior on implicitWidth {
    NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
  }

  // The nest: what is left while it is out. Click it to call the orb home.
  Rectangle {
    anchors.centerIn: parent
    width: 4; height: 4; radius: 2
    color: Theme.alpha(Theme.mauve, poke.containsMouse ? 0.9 : 0.45)
    opacity: root.outVoice ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Style.anim.quick } }
    Behavior on color { ColorAnimation { duration: Style.anim.quick } }
  }

  // The hole: a crust disc with a faint rim, the negative of the orb.
  Rectangle {
    anchors.centerIn: parent
    width: 14; height: 14; radius: 7
    color: Theme.alpha(Theme.crust, 0.95)
    border.width: 1
    border.color: Theme.alpha(Theme.mauve, 0.25)
    opacity: root.inPanel ? 1 : 0
    scale: root.inPanel ? 1 : 0.4
    Behavior on opacity { NumberAnimation { duration: Style.anim.quick } }
    Behavior on scale { NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing } }
  }

  Orb {
    id: orb
    anchors.centerIn: parent
    // Leans toward the pointer while it is on the perch, and its rings wake.
    anchors.horizontalCenterOffset: poke.containsMouse ? poke.lean : 0
    Behavior on anchors.horizontalCenterOffset { NumberAnimation { duration: 120 } }
    poked: poke.containsMouse
    size: 10
    alive: !root.away
    breathe: false
    // At rest it still says what the session is doing, in the same colours
    // the overlay uses: blue while a turn runs, lavender while it talks, sky
    // while an answer sits unread -- the pinging state, Orb.qml's "ready".
    mode: OriClient.speaking ? "speaking"
        : OriClient.working ? "working"
        : OriClient.busy ? "thinking"
        : OriClient.error !== "" ? "failed"
        : OriClient.unread ? "ready" : "idle"
    level: OriClient.speaking ? OriClient.voiceLevel : 0
    opacity: root.away ? 0 : (OriClient.unread ? 1 : 0.85)
    // Into the panel it shrinks into the hole; back out it grows from it.
    scale: root.away ? 0.2 : 1
    Behavior on opacity { NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth } }
    Behavior on scale { NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing } }
  }

  MouseArea {
    id: poke
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    property real lean: 0
    onPositionChanged: function (mouse) { lean = (mouse.x - width / 2) / width * 5 }
    // Left: let it out, or call it home. Right: the panel.
    onClicked: function (event) {
      if (event.button === Qt.RightButton) OriClient.panelOpen = !OriClient.panelOpen
      else if (!OriClient.panelOpen) OriClient.orbFree = !OriClient.orbFree
    }
  }
}
