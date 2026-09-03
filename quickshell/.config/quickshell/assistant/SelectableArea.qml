import QtQuick
import ".."

// The mouse face of one selectable block.
//
// The transcript's TextEdits cannot each run their own selection: a drag has
// to be able to LEAVE the block it started in, so the press is reported to
// Selection (the coordinator) rather than handled here, and apply() lights
// every block in the anchor..head range -- full ones between, partial ends --
// while the drag is still moving. What this area adds locally is only the
// registration of its TextEdit and the I-beam.
//
// preventStealing keeps the drag a SELECTION when it moves vertically: a drag
// across text means select, and scrolling has the wheel and the touchpad. The
// TextEdit underneath keeps selectByMouse off -- the mouse belongs to this
// area, and the selection is set programmatically from the coordinator.
MouseArea {
  id: area

  // The TextEdit this area drives and reports for.
  property Item sel
  // How this block joins the NEXT one in a multi-block copy: list items and
  // table rows are lines of one list and join with a newline; everything else
  // with a paragraph break.
  property string sep: "\n\n"

  acceptedButtons: Qt.LeftButton
  preventStealing: true
  cursorShape: Qt.IBeamCursor

  onPressed: function (m) { Selection.begin(area, m.x, m.y) }
  onPositionChanged: function (m) { Selection.drag(area, m.x, m.y) }
  // Double-click selects one word; a plain click clears (Selection.begin
  // clears first), so a click is also how a selection is dismissed.
  onDoubleClicked: function (m) { Selection.wordSelect(area, m.x, m.y) }

  Component.onCompleted: Selection.register(area.sel, area.sep)
  // A block that streams away or scrolls out of instantiation takes its
  // selection with it -- unregistering clears the whole drag rather than
  // leaving half of one pointing at a dead item.
  Component.onDestruction: Selection.unregister(area.sel)
}