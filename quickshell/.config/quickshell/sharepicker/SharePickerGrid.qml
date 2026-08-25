import QtQuick
// Theme/Style are singletons in the config root; a subdirectory does not get
// the root's implicit import, so pull it in explicitly.
import ".."

// The tile grid, shared by the Screens and Windows tabs. Both tabs differ only
// in what a row of the model means, so the accessors are passed in rather than
// the grid growing a "which tab am I" branch.
GridView {
  id: grid

  // Handed down to every tile. The tab that is not on screen loads no grid at
  // all, but this also stops the captures during the closing animation, which
  // is the window that `visible: false` would miss.
  property bool capturing: false

  // model row -> tile fields.
  property var labelFor: function (m) { return "" }
  property var sublabelFor: function (m) { return "" }
  property var sourceFor: function (m) { return null }

  // The selection lives in the window so it survives a tab switch; the grid
  // asks for a change rather than owning one.
  signal requestIndex(int index)
  signal accepted()

  // cellWidth/cellHeight are set by the window, which needs the same numbers to
  // size the card around this grid -- deriving them twice would let the card
  // and its contents disagree.
  clip: true

  // Keyboard navigation happens in the window's key handler, so the view never
  // takes focus -- but it still has to follow the selection when the choice
  // moves past the bottom row.
  onCurrentIndexChanged: positionViewAtIndex(currentIndex, GridView.Contain)

  // Momentum flicking on a 6-tile grid overshoots and bounces; a plain drag
  // is what a short list wants.
  boundsBehavior: Flickable.StopAtBounds

  delegate: SharePickerTile {
    required property int index
    required property var modelData

    width: grid.cellWidth
    height: grid.cellHeight

    source: grid.sourceFor(modelData)
    label: grid.labelFor(modelData)
    sublabel: grid.sublabelFor(modelData)
    selected: grid.currentIndex === index
    capturing: grid.capturing

    onClicked: grid.requestIndex(index)
    onDoubleClicked: {
      grid.requestIndex(index)
      grid.accepted()
    }
  }
}
