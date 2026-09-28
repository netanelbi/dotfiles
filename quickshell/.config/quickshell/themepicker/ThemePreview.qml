import QtQuick
import ".."

// A thumbnail of ONE theme, drawn in that theme's own look rather than the
// active one: its desk, a tiny window card in its base colour, an accent title
// strip and two "text" lines -- plus, if the theme is brutal, the ink border
// and hard offset shadow; if not, rounded corners. A schema-v2 theme adds its
// own shape: its wallpaper image, window radius, translucent surface, hairline
// outline and a sketch of its bar (islands / strip / flat / nothing).
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
  readonly property var bar: detail && detail.bar ? detail.bar : null
  readonly property var roles: detail && detail.roles ? detail.roles : ({})
  readonly property var srf: detail && detail.surface ? detail.surface : ({})
  readonly property bool v2: bar !== null

  // theme.json colours are CSS `#rrggbbaa`; Theme.css() reorders them for QML.
  readonly property color base: Theme.css(pal.base, sw[0] || "#1e1e2e")
  readonly property color ink: Theme.css(pal.text, info.dark === false ? "#111111" : "#cdd6f4")
  // v2: the theme's second voice (paper's ink red, void's coral); its swatch[1]
  // is often a surface tone.
  readonly property color accent: v2 ? Theme.css(roles.accent2 || roles.accent, ink)
                                     : Theme.css(sw[1] || pal.mauve, ink)
  readonly property color desk: Theme.css(dsk.background || pal.mantle, base)
  readonly property color grid: Theme.css(dsk.grid, "transparent")
  readonly property color edge: Theme.css(shp.borderColor, ink)
  readonly property color shadow: Theme.css(shp.shadowColor, edge)
  readonly property string image: v2 && dsk.mode === "image" && dsk.image && info.name
                                  ? "file://" + Theme.themesDir + "/" + info.name + "/" + dsk.image : ""
  // Radii shrunk to thumbnail scale (a 26px tonal card is ~5px here).
  readonly property real winRadius: brutal ? 0 : (v2 ? Math.min(6, (shp.radius || 0) / 4) : 5)
  readonly property real surfaceOpacity: srf.opacity === undefined ? 1 : srf.opacity
  readonly property int outline: v2 && (shp.border || 0) > 0 && edge.a > 0 ? 1 : 0

  implicitWidth: 72
  implicitHeight: 48

  // The desk.
  Rectangle {
    id: deskRect
    anchors.fill: parent
    color: tile.desk
    radius: tile.brutal ? 0 : 6
    border.width: 1
    border.color: tile.brutal ? tile.edge : Qt.rgba(tile.ink.r, tile.ink.g, tile.ink.b, 0.18)
    clip: true

    // The theme's wallpaper, when it has one on disk (falls back to the colour).
    Image {
      anchors.fill: parent
      anchors.margins: 1
      visible: status === Image.Ready
      source: tile.image
      sourceSize.width: 144
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      smooth: true
    }

    // The bar, sketched: islands, one strip, a flat edge-to-edge band with a
    // hairline, or nothing (bare).
    Item {
      visible: tile.v2
      x: 0; y: 0
      width: parent.width
      height: 7
      readonly property string mode: tile.bar ? (tile.bar.mode || "islands") : ""
      readonly property color fill: Theme.css(tile.bar ? tile.bar.background : "", tile.base)
      readonly property color line: Theme.css(tile.bar ? (tile.bar.border || tile.bar.hairline) : "", "transparent")

      Rectangle {
        visible: parent.mode === "strip"
        x: 3; y: 2; width: parent.width - 6; height: 5
        radius: 2
        color: parent.fill
        border.width: 1
        border.color: parent.line
      }
      Rectangle {
        visible: parent.mode === "flat"
        width: parent.width; height: 6
        color: parent.fill
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: parent.parent.line }
      }
      Repeater {
        model: parent.mode === "islands" ? [[3, 14], [parent.width / 2 - 8, 16], [parent.width - 15, 12]] : []
        Rectangle {
          required property var modelData
          x: modelData[0]; y: 2; width: modelData[1]; height: 4
          radius: 2
          color: parent.fill
        }
      }
      Row {
        visible: parent.mode === "bare"
        x: 4; y: 3; spacing: 2
        Repeater {
          model: 3
          Rectangle { required property int index; width: index === 2 ? 5 : 2; height: 2; radius: 1
                      color: index === 2 ? tile.accent : tile.ink; opacity: index === 2 ? 1 : 0.5 }
        }
      }
    }

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
    y: tile.v2 ? 10 : 8
    width: parent.width - 22
    height: parent.height - (tile.v2 ? 22 : 20)
    color: Qt.rgba(tile.base.r, tile.base.g, tile.base.b, tile.surfaceOpacity)
    radius: tile.winRadius
    border.width: tile.brutal ? 2 : tile.outline
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
