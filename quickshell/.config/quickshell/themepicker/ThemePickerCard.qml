import QtQuick
// Theme/Style are singletons in the config root; a subdirectory does not get
// the root's implicit import, so pull it in explicitly.
import ".."

// The picker's card, drawn in the ACTIVE theme's look. Plain QtQuick (no
// Quickshell types) so it can be rendered headless for review.
//
//   catppuccin: the launcher chrome -- @base card, 2px accent border, radius 12,
//               @surface0 header with an accent prompt pill, @surface1 +
//               1px-accent selection sliding between rows (LauncherList).
//   brutal:     cream card, ink border, hard ink offset shadow, square corners,
//               yellow-filled selected row with an ink outline.
//   v2 themes:  the theme's surface (translucent on glass/neon), hairline
//               outline, radii and soft shadow/glow; the selection is the
//               theme's selection role with onSelection text.
//
// The Item is sized to include the shadow, so a host can centre it as-is.
Item {
  id: root

  // Theme.available entries.
  property var model: []
  // name -> parsed theme.json, for the previews. May be empty.
  property var details: ({})
  property string currentName: ""
  property int currentIndex: 0

  signal activated(int index)
  signal hovered(int index)
  // Emitted with scene coordinates from row hover; lets the host arm hover
  // only after deliberate pointer travel (see LauncherPanel.hoverMoved).
  signal pointerMoved(point p)

  readonly property bool brutal: Theme.brutal
  readonly property bool v2: Theme.v2
  readonly property int edge: Theme.panelBorderOr(2)
  readonly property color edgeColor: Theme.panelBorderColorOr(Theme.accent)
  readonly property int radius: brutal ? 0 : Theme.radiusOr(12)
  readonly property int chipRadius: brutal ? 0 : Theme.chipRadiusOr(6)
  readonly property int rowHeight: 64
  readonly property int rowSpacing: 6
  readonly property int inset: 10
  // Theme.accentInk / onSelection read #000000 at runtime (measured: every
  // `on<Upper>` role property of the Theme singleton comes back black, while
  // Theme.role() returns the right value), so resolve the roles here.
  readonly property color onAccentInk: Theme.role("onAccent", Theme.base)
  readonly property color onSelectionInk: Theme.role("onSelection", Theme.text)
  readonly property color selText: brutal ? Theme.onFill : (v2 ? onSelectionInk : Theme.text)

  implicitWidth: 540 + (brutal ? Theme.shadowX : 0)
  implicitHeight: card.height + (brutal ? Theme.shadowY : 0)
  width: implicitWidth
  height: implicitHeight

  // Soft shadow / glow (glass, tonal, neon); nothing elsewhere. The host
  // surface is full-screen, so there is room for it.
  SoftShadow { target: card }

  // Hard offset shadow.
  Rectangle {
    visible: root.brutal && Theme.hasShadow
    x: Theme.shadowX
    y: Theme.shadowY
    width: card.width
    height: card.height
    color: Theme.shadowColor
  }

  Rectangle {
    id: card
    width: 540
    height: header.height + list.height + root.edge
    // Glass is 62% base: fine for a panel over the wallpaper, too thin for a
    // list read over a busy window, so the picker floors it at 85%.
    color: root.v2 ? Theme.alpha(Theme.base, Math.max(Theme.surfaceOpacity, 0.85)) : Theme.base
    radius: root.radius
    border.width: root.edge
    border.color: root.edgeColor
    clip: true

    // ------------------------------------------------------------ header
    Rectangle {
      id: header
      x: root.edge
      y: root.edge
      width: parent.width - 2 * root.edge
      height: 48
      color: root.brutal ? Theme.mantle : (root.v2 ? Theme.surfaceInner : Theme.surface0)
      topLeftRadius: Math.max(0, root.radius - root.edge)
      topRightRadius: Math.max(0, root.radius - root.edge)

      // An outline rule under the header, like the mockup's title bars
      // (brutal ink, paper's hairline, glass/neon's soft edge).
      Rectangle {
        visible: root.brutal || (root.v2 && root.edge > 0)
        anchors.bottom: parent.bottom
        width: parent.width
        height: root.brutal ? Theme.borderWidth : root.edge
        color: root.brutal ? Theme.borderColor : Theme.softBorderOr(Theme.surface0)
      }

      Rectangle {
        id: prompt
        x: 12
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: root.brutal ? -1 : 0
        width: promptLabel.implicitWidth + 24
        height: promptLabel.implicitHeight + (root.brutal ? 8 : 12)
        radius: root.chipRadius
        color: root.brutal ? Theme.fillYellow : Theme.accent
        border.width: root.brutal ? 2 : 0
        border.color: Theme.borderColor

        Text {
          id: promptLabel
          anchors.centerIn: parent
          text: root.brutal ? "THEME" : "󰏘 Theme"
          color: root.brutal ? Theme.onFill : root.onAccentInk
          font.family: Style.font.family
          font.pixelSize: root.brutal ? Style.font.tiny : Style.font.small
          font.weight: Style.font.boldWeight
          font.letterSpacing: root.brutal ? 1 : 0
          renderType: Text.NativeRendering
        }
      }

      Text {
        anchors.left: prompt.right
        anchors.leftMargin: 12
        anchors.verticalCenter: prompt.verticalCenter
        text: Theme.label
        color: Theme.subtext0
        font.family: Style.font.ui
        font.pixelSize: Style.font.small
        renderType: Text.NativeRendering
      }

      Text {
        anchors.right: parent.right
        anchors.rightMargin: 14
        anchors.verticalCenter: prompt.verticalCenter
        text: "↑↓  ⏎ apply  esc"
        color: root.brutal ? Theme.subtext0 : Theme.overlay0
        font.family: Theme.monoFont
        font.pixelSize: Style.font.tiny
        renderType: Text.NativeRendering
      }
    }

    // -------------------------------------------------------------- rows
    Item {
      id: list
      x: root.edge
      anchors.top: header.bottom
      width: parent.width - 2 * root.edge
      readonly property int n: root.model ? root.model.length : 0
      height: n === 0 ? 56 : n * root.rowHeight + (n - 1) * root.rowSpacing + 2 * root.inset

      Text {
        visible: list.n === 0
        anchors.centerIn: parent
        text: "No themes in ~/.config/theme"
        color: Theme.subtext0
        font.family: Style.font.ui
        font.pixelSize: Style.font.small
        renderType: Text.NativeRendering
      }

      // The selection: one rectangle that slides between rows.
      Rectangle {
        id: highlight
        visible: list.n > 0
        x: root.inset
        width: parent.width - 2 * root.inset
        height: root.rowHeight
        y: root.inset + Math.max(0, Math.min(root.currentIndex, list.n - 1)) * (root.rowHeight + root.rowSpacing)
        color: root.brutal ? Theme.fillYellow : Theme.selectionOr(Theme.surface1)
        radius: root.chipRadius
        // v2: the selection role is the whole mark, no outline.
        border.width: root.brutal ? 2 : (root.v2 ? 0 : 1)
        border.color: root.brutal ? Theme.borderColor : Theme.accent

        Behavior on y {
          NumberAnimation { duration: Style.anim.normal; easing.type: Style.anim.easing }
        }
      }

      Repeater {
        model: root.model

        delegate: Item {
          id: row
          required property var modelData
          required property int index

          readonly property bool selected: index === root.currentIndex
          readonly property bool isCurrent: modelData.name === root.currentName
          readonly property color fg: selected ? root.selText : Theme.text
          readonly property color fgDim: selected && root.brutal ? Theme.onFill
                                       : (selected && root.v2 ? Theme.alpha(root.onSelectionInk, 0.7) : Theme.subtext0)
          // Tags on a v2 selected row sit on the selection fill (paper's is ink),
          // so they take its ink instead of their own colours.
          readonly property bool onSel: selected && root.v2

          x: root.inset
          y: root.inset + index * (root.rowHeight + root.rowSpacing)
          width: list.width - 2 * root.inset
          height: root.rowHeight

          ThemePreview {
            id: preview
            x: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 72
            height: 48
            info: row.modelData
            detail: root.details[row.modelData.name] || null
          }

          Column {
            anchors.left: preview.right
            anchors.leftMargin: 14
            anchors.right: tags.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3

            Text {
              width: parent.width
              elide: Text.ElideRight
              text: row.modelData.label || row.modelData.name
              color: row.fg
              font.family: Style.font.ui
              font.pixelSize: Style.font.size + 1
              font.weight: Style.font.boldWeight
              renderType: Text.NativeRendering
            }
            Text {
              width: parent.width
              elide: Text.ElideRight
              text: row.modelData.name
              color: row.fgDim
              font.family: Theme.monoFont
              font.pixelSize: Style.font.tiny
              renderType: Text.NativeRendering
            }
          }

          Column {
            id: tags
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            Row {
              anchors.right: parent.right
              spacing: 6

              // Marks the active theme.
              Rectangle {
                visible: row.isCurrent
                width: curLabel.implicitWidth + 12
                height: curLabel.implicitHeight + 4
                radius: root.brutal ? 0 : (Theme.chipRadius >= 0 ? Math.min(height / 2, Theme.chipRadius) : height / 2)
                color: root.brutal ? Theme.fillGreen
                     : (row.onSel ? Theme.alpha(root.onSelectionInk, 0.16)
                        : (root.v2 ? Theme.okBackground : Theme.alpha(Theme.green, 0.18)))
                border.width: root.brutal ? 2 : (root.v2 && Theme.okBackground.a === 0 ? 1 : 0)
                border.color: root.brutal ? Theme.borderColor : (row.onSel ? root.onSelectionInk : Theme.ok)
                Text {
                  id: curLabel
                  anchors.centerIn: parent
                  text: root.brutal ? "ACTIVE" : "󰄬 active"
                  color: root.brutal ? Theme.onFill : (row.onSel ? root.onSelectionInk : (root.v2 ? Theme.ok : Theme.green))
                  font.family: Style.font.family
                  font.pixelSize: Style.font.tiny - 1
                  font.weight: Style.font.boldWeight
                  renderType: Text.NativeRendering
                }
              }

              // dark / light tag.
              Rectangle {
                width: modeLabel.implicitWidth + 12
                height: modeLabel.implicitHeight + 4
                radius: root.brutal ? 0 : (Theme.chipRadius >= 0 ? Math.min(height / 2, Theme.chipRadius) : height / 2)
                color: root.brutal ? Theme.base
                     : (row.onSel ? Theme.alpha(root.onSelectionInk, 0.16) : (root.v2 ? Theme.surfaceInner : Theme.surface0))
                border.width: root.brutal ? 2 : 0
                border.color: Theme.borderColor
                Text {
                  id: modeLabel
                  anchors.centerIn: parent
                  text: row.modelData.dark === false ? (root.brutal ? "LIGHT" : "󰖨 light")
                                                     : (root.brutal ? "DARK" : "󰖔 dark")
                  color: root.brutal ? Theme.text : (row.onSel ? root.onSelectionInk : Theme.subtext0)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.tiny - 1
                  font.weight: Style.font.boldWeight
                  renderType: Text.NativeRendering
                }
              }
            }

            // Swatch strip.
            Row {
              anchors.right: parent.right
              spacing: root.brutal ? 0 : 3
              Repeater {
                model: row.modelData.swatch || []
                Rectangle {
                  required property var modelData
                  width: 14
                  height: 14
                  radius: root.brutal ? 0 : Math.min(3, Theme.chipRadiusOr(3))
                  color: modelData
                  border.width: root.brutal ? 2 : 1
                  border.color: root.brutal ? Theme.borderColor
                              : (row.onSel ? Theme.alpha(root.onSelectionInk, 0.35) : Theme.alpha(Theme.text, 0.15))
                }
              }
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: root.hovered(row.index)
            onPositionChanged: function (mouse) {
              root.pointerMoved(mapToItem(null, mouse.x, mouse.y))
              root.hovered(row.index)
            }
            onClicked: root.activated(row.index)
          }
        }
      }
    }
  }
}
