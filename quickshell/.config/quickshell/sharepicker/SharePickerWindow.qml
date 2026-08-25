import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
// Theme/Style are singletons in the config root; a subdirectory does not get
// the root's implicit import, so pull it in explicitly.
import ".."

// The picker overlay. One window, on whatever output has focus when the
// request arrives -- the choice is modal to the user, not to a monitor.
//
// ------------------------------------------------------------------ layout
// The layer surface is the whole screen and is sized exactly once, by the
// compositor. Everything that moves -- the backdrop fade, the card rising into
// place -- moves INSIDE it. A layer surface that changes size has to wait for
// a configure/ack round trip before it may commit, which costs one round trip
// per animated frame; the notification popups turned a 180ms entrance into
// 467ms of visible lurching that way. See CLAUDE.md.
//
// -------------------------------------------------------------- the mirror
// The Screens tab captures the composited output, and this overlay is part of
// that output -- so a screen thumbnail contains a small copy of the picker,
// which contains a smaller copy, and so on. That is not a bug to hide: it is
// exactly what the other end of the call would see if you picked that screen.
// The card is kept off to one side of nothing and the backdrop is only partly
// opaque so the desktop still reads through the recursion. Window thumbnails
// are unaffected -- hyprland-toplevel-export captures a window's own buffer.
PanelWindow {
  id: win

  property var controller: null

  WlrLayershell.namespace: "quickshell-share-picker"
  WlrLayershell.layer: WlrLayer.Overlay
  // Exclusive: this is a security prompt for "may an app watch your screen".
  // It must have the keyboard, and Escape must reach it rather than whatever
  // is underneath.
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  screen: focusedScreen()

  // rofi opens on the monitor with focus; Quickshell.screens is indexed by Qt
  // screen, so go through Hyprland's monitor mapping to find the match.
  function focusedScreen() {
    var focused = Hyprland.focusedMonitor
    if (!focused) return null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (Hyprland.monitorFor(screens[i]) === focused) return screens[i]
    }
    return null
  }

  // --------------------------------------------------------------- entrance
  // Driven from a plain bool rather than Component.onCompleted alone so the
  // card can also animate OUT before the surface is torn down.
  property bool shown: false
  Component.onCompleted: win.shown = true

  readonly property var screens: Quickshell.screens
  readonly property var windows: controller ? controller.windowEntries : []

  // 0 = Screens, 1 = Windows. Held per tab so switching back returns you to
  // where you were.
  property int tab: 0
  property int screenIndex: 0
  property int windowIndex: 0

  readonly property int count: tab === 0 ? screens.length : windows.length
  property int index: tab === 0 ? screenIndex : windowIndex

  function setIndex(i) {
    if (win.count === 0) return
    var clamped = Math.max(0, Math.min(i, win.count - 1))
    if (win.tab === 0) win.screenIndex = clamped
    else win.windowIndex = clamped
  }

  // Vertical movement is by ROW, and refuses to leave the grid. Clamping the
  // way the horizontal keys do would make Down on a single-row grid jump to
  // the last tile, which looks like the key did something other than what it
  // says. Within the grid it still clamps, so Down from a full row into a
  // short last row lands on that row's final tile rather than nowhere.
  function moveRow(delta) {
    if (win.count === 0) return
    var rowCount = Math.ceil(win.count / win.columns)
    var target = Math.floor(win.index / win.columns) + delta
    if (target < 0 || target >= rowCount) return
    win.setIndex(win.index + delta * win.columns)
  }

  // ------------------------------------------------------------- decisions
  function accept() {
    if (win.count === 0) return
    if (win.tab === 0) {
      var s = win.screens[win.index]
      if (s) win.finish("screen:" + s.name)
    } else {
      var e = win.windows[win.index]
      if (e) win.finish("window:" + e.handle)
    }
  }

  // slurp cannot draw a selection over an exclusive-keyboard overlay, so the
  // region path is a handoff: this closes, and the waiting script runs slurp
  // and does the coordinate math. Nothing about the region is decided here.
  function chooseRegion() { win.finish("region") }

  function cancel() { win.finish("cancel") }

  function finish(body) {
    if (!win.controller) return
    win.shown = false
    // Let the card fall away before the surface goes. The controller drops
    // `opened` as soon as it is told, which unloads this window, so the exit
    // has to be started first and the answer sent after.
    exitDelay.body = body
    exitDelay.start()
  }

  Timer {
    id: exitDelay
    property string body: ""
    interval: Style.anim.quick
    onTriggered: if (win.controller) win.controller.finish(body)
  }

  // ------------------------------------------------------------- backdrop
  Rectangle {
    anchors.fill: parent
    // Held well short of opaque. At full strength the screen thumbnails would
    // be a picture of a black rectangle with a picker on it, which tells the
    // user nothing about the screen they are being asked to share.
    color: Theme.alpha(Theme.crust, 0.45)
    opacity: win.shown ? 1 : 0
    Behavior on opacity {
      NumberAnimation { duration: Style.anim.normal; easing.type: Style.anim.easingSmooth }
    }

    MouseArea {
      anchors.fill: parent
      onClicked: win.cancel()
    }
  }

  // ----------------------------------------------------------------- card
  // The card is sized to its content and animates between tabs. That is only
  // safe because it is a Rectangle INSIDE a surface that is already the whole
  // screen -- the layer surface itself never resizes, so none of this costs a
  // configure/ack round trip.
  readonly property int cardMargin: 16
  readonly property int headerHeight: 34
  readonly property int footerHeight: 30
  readonly property int rowSpacing: 12

  readonly property int cardWidth: Math.min(1040, width - 96)

  // Screens are few and worth showing big; windows are many and still have to
  // be recognisable, hence the different column counts. Never more columns
  // than there are things to put in them, or a lone screen sits in a third of
  // the card with two empty columns beside it.
  readonly property int columns: Math.max(1, Math.min(tab === 0 ? 2 : 3, count))

  // The tile's own chrome, from SharePickerTile: 6px margins, a 34px label
  // strip and the 4px between it and the preview.
  readonly property int tileChromeW: 12
  readonly property int tileChromeH: 34 + 4 + 12
  readonly property real thumbAspect: 1.6

  readonly property int chromeHeight:
    2 * cardMargin + headerHeight + footerHeight + 2 * rowSpacing
  readonly property int maxContentHeight: height - 96 - chromeHeight
  readonly property int rows: Math.max(1, Math.ceil(Math.max(count, 1) / columns))

  // Width first: divide the card between the columns. Then check that the
  // resulting 16:10 preview still fits vertically -- with one screen and one
  // column it does not, and an uncapped cell would be taller than the card and
  // get clipped in half. When height is the binding constraint the cell shrinks
  // in BOTH directions so the preview keeps its shape, and the grid is centred
  // in the leftover width rather than stretching to fill it.
  readonly property int widthCell: Math.floor((cardWidth - 2 * cardMargin) / columns)
  readonly property int heightCell: Math.floor(maxContentHeight / Math.min(rows, 2))
  readonly property int cellHeight: Math.max(
    120, Math.min(Math.round((widthCell - tileChromeW) / thumbAspect) + tileChromeH, heightCell))
  readonly property int cellWidth: Math.min(
    widthCell, Math.round((cellHeight - tileChromeH) * thumbAspect) + tileChromeW)

  readonly property int contentHeight: Math.min(maxContentHeight, rows * cellHeight)
  readonly property int cardHeight: contentHeight + chromeHeight

  Rectangle {
    id: card

    width: win.cardWidth
    height: win.cardHeight
    x: (win.width - width) / 2
    // Rises 14px into place. Only y, scale and opacity move -- never the
    // surface, never this rectangle's width or height.
    y: (win.height - height) / 2 + (win.shown ? 0 : 14)

    color: Theme.base
    // .notification / rofi window: 12px radius, 2px accent border on @base.
    radius: 12
    border.width: Style.module.borderWidth
    border.color: Theme.accent

    opacity: win.shown ? 1 : 0
    scale: win.shown ? 1 : 0.97
    transformOrigin: Item.Center

    Behavior on y {
      NumberAnimation { duration: Style.anim.normal; easing.type: Style.anim.easing }
    }
    Behavior on height {
      NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
    }
    Behavior on opacity {
      NumberAnimation { duration: Style.anim.opacityDuration }
    }
    Behavior on scale {
      NumberAnimation { duration: Style.anim.normal; easing.type: Style.anim.easing }
    }

    // Swallow clicks so a miss inside the card does not hit the backdrop and
    // cancel the whole request.
    MouseArea { anchors.fill: parent }

    Column {
      anchors.fill: parent
      anchors.margins: win.cardMargin
      spacing: win.rowSpacing

      // ------------------------------------------------------------ header
      Item {
        width: parent.width
        height: win.headerHeight

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Share your screen"
          color: Theme.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.size
          font.weight: Style.font.boldWeight
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 6

          Repeater {
            model: [
              { label: "Screens", n: win.screens.length },
              { label: "Windows", n: win.windows.length }
            ]

            Rectangle {
              required property int index
              required property var modelData

              readonly property bool current: win.tab === index

              width: pill.implicitWidth + 2 * Style.bar.islandPaddingH
              height: 28
              radius: Style.module.radius
              color: current ? Theme.accent
                             : (pillHover.hovered ? Theme.hoverBackground : Theme.surface0)

              Behavior on color { ColorAnimation { duration: Style.anim.colorDuration } }

              Text {
                id: pill
                anchors.centerIn: parent
                text: modelData.label + "  " + modelData.n
                color: parent.current ? Theme.base : Theme.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.tiny
                font.weight: parent.current ? Style.font.boldWeight : Style.font.normalWeight
              }

              HoverHandler { id: pillHover }
              MouseArea {
                anchors.fill: parent
                onClicked: win.tab = index
              }
            }
          }
        }
      }

      // ------------------------------------------------------------- grid
      // One Loader per tab, so the tab you are not looking at has no
      // ScreencopyView at all. Hiding them would keep them capturing.
      Item {
        id: content
        width: parent.width
        height: win.contentHeight

        // Centred at exactly the grid's width rather than filling the card:
        // when the cells are capped by height there is width left over, and a
        // grid left-aligned in it reads as a layout bug.
        Loader {
          anchors.horizontalCenter: parent.horizontalCenter
          height: parent.height
          width: win.columns * win.cellWidth
          active: win.tab === 0
          sourceComponent: screenGrid
        }

        Loader {
          anchors.horizontalCenter: parent.horizontalCenter
          height: parent.height
          width: win.columns * win.cellWidth
          active: win.tab === 1
          sourceComponent: windowGrid
        }

        Text {
          anchors.centerIn: parent
          visible: win.count === 0
          text: win.tab === 0 ? "No outputs" : "No shareable windows"
          color: Theme.inactive
          font.family: Style.font.family
          font.pixelSize: Style.font.size
        }
      }

      // ------------------------------------------------------------ footer
      Item {
        width: parent.width
        height: win.footerHeight

        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8

          // The stock picker's "Allow a restore token" checkbox. It is the
          // difference between being asked every time and never being asked
          // again for this app, so it stays visible and stays a choice.
          Rectangle {
            width: tokenRow.implicitWidth + 2 * Style.module.paddingH
            height: 26
            radius: Style.module.radius
            color: tokenHover.hovered ? Theme.hoverBackground : Theme.transparent

            Row {
              id: tokenRow
              anchors.centerIn: parent
              spacing: 8

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 14
                height: 14
                radius: 4
                color: win.controller && win.controller.allowToken
                  ? Theme.accent : Theme.transparent
                border.width: Style.module.borderWidth
                border.color: win.controller && win.controller.allowToken
                  ? Theme.accent : Theme.surface2
                Behavior on color { ColorAnimation { duration: Style.anim.colorDuration } }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Don't ask again for this app"
                color: Theme.subtext0
                font.family: Style.font.family
                font.pixelSize: Style.font.tiny
              }
            }

            HoverHandler { id: tokenHover }
            MouseArea {
              anchors.fill: parent
              onClicked: if (win.controller)
                win.controller.allowToken = !win.controller.allowToken
            }
          }

          Rectangle {
            width: regionText.implicitWidth + 2 * Style.module.paddingH
            height: 26
            radius: Style.module.radius
            color: regionHover.hovered ? Theme.hoverBackground : Theme.transparent

            Text {
              id: regionText
              anchors.centerIn: parent
              text: "Select region..."
              color: Theme.subtext0
              font.family: Style.font.family
              font.pixelSize: Style.font.tiny
            }

            HoverHandler { id: regionHover }
            MouseArea {
              anchors.fill: parent
              onClicked: win.chooseRegion()
            }
          }
        }

        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "Tab switch  ·  Enter share  ·  Esc cancel"
          color: Theme.inactive
          font.family: Style.font.family
          font.pixelSize: Style.font.tiny
        }
      }
    }
  }

  // ------------------------------------------------------------ components
  Component {
    id: screenGrid

    SharePickerGrid {
      capturing: win.tab === 0
      currentIndex: win.screenIndex
      model: win.screens
      cellWidth: win.cellWidth
      cellHeight: win.cellHeight
      onRequestIndex: function (i) { win.setIndex(i) }
      onAccepted: win.accept()

      labelFor: function (m) { return m.name }
      // The stock picker's one genuinely useful string, kept.
      sublabelFor: function (m) { return m.width + "x" + m.height + " at " + m.x + ", " + m.y }
      sourceFor: function (m) { return m }
    }
  }

  Component {
    id: windowGrid

    SharePickerGrid {
      capturing: win.tab === 1
      currentIndex: win.windowIndex
      model: win.windows
      cellWidth: win.cellWidth
      cellHeight: win.cellHeight
      onRequestIndex: function (i) { win.setIndex(i) }
      onAccepted: win.accept()

      labelFor: function (m) { return m.cls }
      sublabelFor: function (m) { return m.title }
      sourceFor: function (m) { return m.toplevel }
    }
  }

  // ------------------------------------------------------------- keyboard
  Item {
    anchors.fill: parent
    focus: true

    Keys.onPressed: function (event) {
      event.accepted = true
      switch (event.key) {
        case Qt.Key_Escape:
          win.cancel(); return
        case Qt.Key_Return:
        case Qt.Key_Enter:
          win.accept(); return
        case Qt.Key_Tab:
          win.tab = (win.tab + 1) % 2; return
        case Qt.Key_Backtab:
          win.tab = (win.tab + 1) % 2; return
        case Qt.Key_Left:
        case Qt.Key_H:
          win.setIndex(win.index - 1); return
        case Qt.Key_Right:
        case Qt.Key_L:
          win.setIndex(win.index + 1); return
        case Qt.Key_Up:
        case Qt.Key_K:
          win.moveRow(-1); return
        case Qt.Key_Down:
        case Qt.Key_J:
          win.moveRow(1); return
        case Qt.Key_Home:
          win.setIndex(0); return
        case Qt.Key_End:
          win.setIndex(win.count - 1); return
        case Qt.Key_R:
          // Ctrl, because plain R is a navigation-adjacent letter and the
          // region path throws the picker away.
          if (event.modifiers & Qt.ControlModifier) win.chooseRegion()
          return
        case Qt.Key_T:
          if ((event.modifiers & Qt.ControlModifier) && win.controller)
            win.controller.allowToken = !win.controller.allowToken
          return
      }
      event.accepted = false
    }
  }
}
