import QtQuick

// A thumbnail of ONE theme, drawn in that theme's own look rather than the
// active one: its desk, a tiny window card in its base colour, an accent title
// strip and two "text" lines -- plus, if the theme is brutal, the ink border
// and hard offset shadow; if not, rounded corners.
//
// `info` is the entry from Theme.available ({name,label,dark,brutal,swatch});
// `detail` is the parsed theme.json when ThemePicker managed to read it, and
// the tile falls back to the swatch when it did not.
Item {
  id: tile

  property var info: ({})
  property var detail: null

  readonly property var sw: info.swatch || []
  readonly property var pal: detail && detail.palette ? detail.palette : ({})
  readonly property var shp: detail && detail.shape ? detail.shape : ({})
  readonly property var dsk: detail && detail.desk ? detail.desk : ({})
  readonly property bool brutal: info.brutal === true

  readonly property color base: pal.base || sw[0] || "#1e1e2e"
  readonly property color ink: pal.text || (info.dark === false ? "#111111" : "#cdd6f4")
  readonly property color accent: sw[1] || pal.mauve || ink
  readonly property color desk: dsk.background || pal.mantle || base
  readonly property color grid: dsk.grid || "transparent"
  readonly property color edge: shp.borderColor || ink
  readonly property color shadow: shp.shadowColor || edge

  implicitWidth: 72
  implicitHeight: 48

  // The desk.
  Rectangle {
    anchors.fill: parent
    color: tile.desk
    radius: tile.brutal ? 0 : 6
    border.width: 1
    border.color: tile.brutal ? tile.edge : Qt.rgba(tile.ink.r, tile.ink.g, tile.ink.b, 0.18)
    clip: true

    // A hint of the brutal desk grid.
    Repeater {
      model: tile.grid.a > 0 ? 5 : 0
      Rectangle {
        required property int index
        x: 12 * (index + 1)
        width: 1
        height: parent.height
        color: tile.grid
      }
    }
  }

  // The window's hard shadow (brutal only).
  Rectangle {
    visible: tile.brutal
    x: win.x + 3
    y: win.y + 3
    width: win.width
    height: win.height
    color: tile.shadow
  }

  Rectangle {
    id: win
    x: 9
    y: 8
    width: parent.width - 22
    height: parent.height - 20
    color: tile.base
    radius: tile.brutal ? 0 : 5
    border.width: tile.brutal ? 2 : 0
    border.color: tile.edge
    clip: true

    // Title strip: a filled chip on brutal, a thin accent bar on soft themes.
    Rectangle {
      x: tile.brutal ? 4 : 5
      y: tile.brutal ? 4 : 5
      width: tile.brutal ? 14 : parent.width - 10
      height: tile.brutal ? 6 : 3
      radius: tile.brutal ? 0 : 1.5
      color: tile.accent
      border.width: tile.brutal ? 1 : 0
      border.color: tile.edge
    }
    Rectangle {
      x: 5; y: 14
      width: parent.width * 0.62
      height: 2
      radius: tile.brutal ? 0 : 1
      color: tile.ink
      opacity: 0.85
    }
    Rectangle {
      x: 5; y: 19
      width: parent.width * 0.4
      height: 2
      radius: tile.brutal ? 0 : 1
      color: tile.ink
      opacity: 0.5
    }
  }
}
