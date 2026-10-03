import QtQuick
import ".."

// The control room's one button. Three weights:
//   primary  filled in `tint` (the one action a view is for: Start call)
//   plain    a quiet outline (Open, Accept, Calibrate)
//   danger   red text, red fill on hover (Stop, End call)
//   good     green text, green fill on hover (Accept)
// Keyboard-reachable (Tab), Enter/Space press it, focus draws a ring.
Rectangle {
  id: b

  property string text: ""
  property string kind: "plain"
  property color tint: Theme.accent
  property bool compact: false
  signal clicked()

  readonly property bool hot: area.containsMouse || b.activeFocus
  readonly property color ink:
      !b.enabled ? Theme.overlay0
    : kind === "primary" ? (Theme.brutal ? Theme.onFill : Theme.crust)
    : kind === "danger" ? (hot ? Theme.crust : Theme.red)
    : kind === "good" ? (hot ? Theme.crust : Theme.green)
    : hot ? Theme.text : Theme.subtext1

  implicitWidth: label.implicitWidth + (compact ? 20 : 28)
  implicitHeight: compact ? 26 : 32
  radius: Theme.brutal ? 0 : height / 2
  opacity: enabled ? 1 : 0.55
  activeFocusOnTab: enabled

  color: !b.enabled ? Theme.transparent
    : kind === "primary" ? (hot ? Qt.lighter(tint, 1.08) : tint)
    : kind === "danger" ? (hot ? Theme.red : Theme.transparent)
    : kind === "good" ? (hot ? Theme.green : Theme.alpha(Theme.green, 0.08))
    : hot ? Theme.alpha(Theme.surface1, 0.6) : Theme.alpha(Theme.surface0, 0.35)
  border.width: kind === "primary" ? 0 : 1
  border.color: kind === "danger" ? Theme.alpha(Theme.red, 0.6)
    : kind === "good" ? Theme.alpha(Theme.green, 0.55)
    : b.activeFocus ? Theme.alpha(b.tint, 0.8)
    : Theme.alpha(Theme.overlay0, 0.35)

  Behavior on color { ColorAnimation { duration: Style.anim.quick } }

  // Focus ring, outside the shape so it never changes the button's size.
  Rectangle {
    anchors { fill: parent; margins: -3 }
    radius: parent.radius + 3
    color: Theme.transparent
    border.width: 2
    border.color: Theme.alpha(b.tint, 0.55)
    visible: b.activeFocus
  }

  Text {
    id: label
    anchors.centerIn: parent
    text: b.text
    color: b.ink
    font.family: RoomLook.sans
    font.pixelSize: b.compact ? RoomLook.small + 1 : RoomLook.meta
    font.weight: b.kind === "primary" ? Font.DemiBold : Font.Medium
    renderType: Text.QtRendering
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: b.clicked()
  }

  Keys.onPressed: function (e) {
    if (!b.enabled) return
    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) {
      b.clicked()
      e.accepted = true
    }
  }
}
