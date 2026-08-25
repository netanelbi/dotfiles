import QtQuick
// Theme/Style are singletons in the config root; a subdirectory does not get
// the root's implicit import, so pull it in explicitly.
import ".."

// The rofi `listview` + `element` block, as a reusable list.
//
//   listview { padding: 8px; spacing: 4px; lines: 8; fixed-height: true }
//   element  { padding: 6px 10px; border-radius: 6px }
//   element selected.normal { background: @surface1; border: 1px solid <accent> }
//
// Two departures from rofi, both motion:
//   * the selection is a single highlight rectangle that SLIDES between rows
//     instead of repainting a different element;
//   * the list's height animates as the model shrinks under a query, so the
//     panel closes around the matches rather than holding eight empty rows
//     (rofi's `fixed-height: true` keeps the box the same size forever).
Item {
  id: root

  property alias model: view.model
  property alias delegate: view.delegate
  property alias currentIndex: view.currentIndex
  property alias count: view.count
  readonly property alias view: view

  // element-icon { size: 48px } drives the app launcher's row height; the
  // text-only lists are shorter.
  property int rowHeight: 40
  // listview { lines: N }
  property int rows: 8
  // listview { padding: 8px }
  property int inset: 8
  // listview { spacing: 4px }
  property int rowSpacing: 4
  property color accent: Theme.accent

  readonly property int visibleRows: Math.min(count, rows)
  readonly property int naturalHeight: count === 0
    ? 0
    : visibleRows * rowHeight + (visibleRows - 1) * rowSpacing + 2 * inset

  implicitHeight: naturalHeight
  height: implicitHeight

  Behavior on implicitHeight {
    NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
  }

  // Deliberately NOT rofi's `cycle: true`. Wrapping means Up on the first row
  // teleports to the last, which in the clipboard -- hundreds of entries deep,
  // most of them looking alike -- loses your place completely for the sake of
  // a keypress you did not mean. Both ends just stop.
  function move(delta) {
    if (view.count === 0) return
    view.currentIndex = Math.max(0, Math.min(view.currentIndex + delta, view.count - 1))
  }

  function moveTo(index) {
    if (view.count === 0) return
    view.currentIndex = Math.max(0, Math.min(index, view.count - 1))
  }

  ListView {
    id: view
    anchors.fill: parent
    anchors.margins: root.inset
    clip: true
    spacing: root.rowSpacing
    currentIndex: 0
    boundsBehavior: Flickable.StopAtBounds
    // Scrolling the viewport should glide, not teleport.
    highlightMoveDuration: Style.anim.normal
    highlightMoveVelocity: -1
    highlightResizeDuration: Style.anim.quick
    highlightResizeVelocity: -1
    highlightFollowsCurrentItem: true
    preferredHighlightBegin: 0
    preferredHighlightEnd: height
    highlightRangeMode: ListView.ApplyRange
    cacheBuffer: root.rowHeight * 4

    // element selected.normal { background: @surface1; border: 1px solid <accent> }
    highlight: Rectangle {
      color: Theme.surface1
      radius: 6
      border.width: 1
      border.color: root.accent
      opacity: view.count > 0 ? 1 : 0

      Behavior on border.color {
        ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
      }
      Behavior on opacity {
        NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
      }
    }

    // A row appearing or leaving under a query fades rather than pops.
    add: Transition {
      NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Style.anim.opacityDuration }
    }
    displaced: Transition {
      NumberAnimation { properties: "x,y"; duration: Style.anim.normal; easing.type: Style.anim.easing }
    }
  }

  // scrollbar { background: @surface0; handle-color: <accent>; handle-width: 4px }
  Rectangle {
    id: scrollTrack
    visible: root.count > root.rows
    anchors.right: parent.right
    anchors.rightMargin: root.inset / 2
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.topMargin: root.inset
    anchors.bottomMargin: root.inset
    width: 4
    radius: 2
    color: Theme.surface0
    opacity: visible ? 1 : 0

    Behavior on opacity {
      NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
    }

    Rectangle {
      width: parent.width
      radius: parent.radius
      color: root.accent
      height: Math.max(16, parent.height * Math.min(1, view.visibleArea.heightRatio))
      y: parent.height * Math.max(0, Math.min(1 - Math.min(1, view.visibleArea.heightRatio), view.visibleArea.yPosition))

      Behavior on y {
        NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing }
      }
    }
  }
}
