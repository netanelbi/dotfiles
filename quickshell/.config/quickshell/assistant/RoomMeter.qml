import QtQuick
import ".."

// One live meter: a label, a thin track with the threshold drawn on it, and
// the number. The fill turns `onColor` once the value clears the threshold --
// the meter answers its own question ("loud enough?", "is it you?") without
// a word.
Item {
  id: mt

  property string label: ""
  property real value: 0          // in [lo, hi]
  property real lo: 0
  property real hi: 1
  property real mark: -1e9        // threshold, in the same units; off by default
  property real floorMark: -1e9   // a second, dim tick (room noise)
  property string readout: ""
  property bool known: true
  property color onColor: Theme.green
  property color offColor: Theme.overlay0

  readonly property real frac: Math.max(0, Math.min(1, (value - lo) / (hi - lo)))
  readonly property real markFrac: (mark - lo) / (hi - lo)
  readonly property bool over: known && value >= mark

  implicitHeight: 34

  Text {
    id: lab
    anchors { left: parent.left; top: parent.top }
    text: mt.label
    color: Theme.subtext0
    font.family: RoomLook.sans
    font.pixelSize: RoomLook.small
    renderType: Text.QtRendering
  }
  Text {
    anchors { right: parent.right; baseline: lab.baseline }
    text: mt.known ? mt.readout : "–"
    color: mt.over ? Theme.text : Theme.subtext0
    font.family: RoomLook.mono
    font.pixelSize: RoomLook.small
    renderType: Text.QtRendering
  }

  Rectangle {
    id: track
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: 4 }
    height: 6
    radius: 3
    color: Theme.alpha(Theme.surface1, 0.55)

    Rectangle {
      anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
      width: mt.known ? Math.max(mt.frac > 0 ? 6 : 0, parent.width * mt.frac) : 0
      radius: 3
      color: mt.over ? mt.onColor : mt.offColor
      Behavior on width { NumberAnimation { duration: 90 } }
      Behavior on color { ColorAnimation { duration: Style.anim.quick } }
    }
    // the threshold
    Rectangle {
      visible: mt.markFrac >= 0 && mt.markFrac <= 1
      x: Math.round(parent.width * mt.markFrac) - 1
      y: -3
      width: 2
      height: parent.height + 6
      radius: 1
      color: Theme.text
      opacity: 0.85
    }
    // the floor (room noise)
    Rectangle {
      readonly property real f: (mt.floorMark - mt.lo) / (mt.hi - mt.lo)
      visible: f >= 0 && f <= 1
      x: Math.round(parent.width * f)
      y: -1
      width: 1
      height: parent.height + 2
      color: Theme.overlay0
    }
  }
}
