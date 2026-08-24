import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "root:/"

// swaync's control center: the notification history, the title/Clear All row
// and the Do Not Disturb toggle.
//
// config.json parity:
//   "control-center-width": 400            -> a 400px window...
//   "control-center-margin-*": 10          -> ...10px off every edge...
//   .control-center { margin: 10px }       -> ...and 10px more inside, so the
//                                             panel is 380px and sits 20px in
//   "control-center-layer": "top"          -> WlrLayer.Top
//   "fit-to-screen": true                  -> full height; the 600px
//                                             control-center-height is
//                                             explicitly ignored by swaync
//   "widgets": ["title", "dnd", "notifications"]
//   "text-empty": "No Notifications"
//   "hide-on-clear": false                 -> Clear All leaves it open
//   "hide-on-action": true                 -> an action closes it
//   "notification-grouping": true (default)-> rows grouped by app
//   "keyboard-shortcuts": true             -> the swaync(1) shortcut table
//
// style.css parity:
//   .control-center { background: @base; border-radius: 12px;
//                     border: 2px solid @surface0; padding: 12px }
//   .control-center-list-placeholder { color: @overlay0; padding: 20px }
//   .widget-title { color: @text; font-weight: bold; font-size: 16px;
//                   padding: 8px 12px }
//   .widget-title > button { background: @surface0; border-radius: 8px;
//                            padding: 6px 12px }  :hover { background: @red }
//   .widget-dnd { padding: 8px 12px; color: @text }
//   .widget-dnd > switch { background: @surface0; border-radius: 12px }
//   .widget-dnd > switch:checked { background: @mauve }
//   .widget-dnd > switch slider { background: @text; border-radius: 10px }
//   .notification-group-headers { padding: 8px 12px; color: @text; bold }
//   .notification-group-icon { color: @mauve }
//   .notification-group-close-button { background: @surface0; ... }
//
// -------------------------------------------------------------------- motion
// swaync slides its panel in over `transition-time` (200ms) and that is all.
// Here the panel slides and fades from the right edge it lives on, the
// backdrop dims behind it, and group expansion animates its own height so the
// stack unfolds instead of teleporting.
PanelWindow {
  id: center

  required property var store

  readonly property bool opened: store.centerOpen

  WlrLayershell.namespace: "quickshell-notification-center"
  WlrLayershell.layer: WlrLayer.Top
  // swaync grabs the keyboard while the panel is up -- that is what makes
  // Escape, Shift+D and the arrow keys work the moment it opens.
  WlrLayershell.keyboardFocus: opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: 0

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  color: "transparent"

  // The window outlives `opened` by exactly one animation so the panel can
  // leave the way it arrived.
  property real revealed: 0
  visible: opened || revealed > 0.001
  onOpenedChanged: {
    revealed = opened ? 1 : 0
    if (opened) {
      center.screen = focusedScreen()
      Qt.callLater(function () { keyScope.forceActiveFocus() })
    } else {
      center.selectedKey = ""
    }
  }

  Behavior on revealed {
    NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
  }

  function focusedScreen() {
    var focused = Hyprland.focusedMonitor
    if (!focused) return center.screen
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (Hyprland.monitorFor(screens[i]) === focused) return screens[i]
    }
    return center.screen
  }

  // swaync paints a transparent "blank-window" over the rest of the screen so
  // a click anywhere outside dismisses the panel.
  MouseArea {
    anchors.fill: parent
    onClicked: center.store.closeCenter()
  }

  FocusScope {
    id: keyScope
    anchors.fill: parent
    focus: true

    // swaync(1), Control Center Keyboard Shortcuts.
    Keys.onPressed: function (event) { center.handleKey(event) }

    Rectangle {
      id: panel

      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.right: parent.right
      anchors.topMargin: 20            // config margin 10 + .control-center 10
      anchors.bottomMargin: 20
      anchors.rightMargin: 20
      width: center.store.centerWidth - 20

      color: Theme.base
      radius: 12
      border.width: 2
      border.color: Theme.surface0
      clip: true

      opacity: center.revealed
      x: (1 - center.revealed) * 24    // slides out towards its own edge

      Column {
        id: body
        anchors.fill: parent
        anchors.margins: 12            // .control-center padding

        // ------------------------------------------------- title widget
        Item {
          id: titleWidget
          width: parent.width
          height: 40 + 16              // .widget-title padding 8px vertical
          // .widget margin: 8px
          Item {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8

            Text {
              anchors.left: parent.left
              anchors.leftMargin: 12   // .widget-title padding-left
              anchors.verticalCenter: parent.verticalCenter
              text: "Notifications"    // widget-config.title.text
              color: Theme.text
              font.family: Style.font.family
              font.pixelSize: Style.font.size + 2   // .widget-title 16px
              font.weight: Style.font.boldWeight
              renderType: Text.NativeRendering
            }

            // widget-config.title: clear-all-button, button-text "Clear All"
            Rectangle {
              id: clearAll
              anchors.right: parent.right
              anchors.rightMargin: 12
              anchors.verticalCenter: parent.verticalCenter
              width: clearLabel.implicitWidth + 24   // padding: 6px 12px
              height: clearLabel.implicitHeight + 12
              radius: 8
              color: clearArea.containsMouse ? Theme.red : Theme.surface0

              Behavior on color {
                ColorAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
              }

              Text {
                id: clearLabel
                anchors.centerIn: parent
                text: "Clear All"
                color: clearArea.containsMouse ? Theme.base : Theme.text
                font.family: Style.font.family
                font.pixelSize: Style.font.size
                renderType: Text.NativeRendering

                Behavior on color {
                  ColorAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
                }
              }

              MouseArea {
                id: clearArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // "hide-on-clear": false -- the panel stays up.
                onClicked: center.store.clearAll()
              }
            }
          }
        }

        // --------------------------------------------------- dnd widget
        Item {
          id: dndWidget
          width: parent.width
          height: 36 + 16              // .widget-dnd padding 8px vertical

          Item {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8

            Text {
              anchors.left: parent.left
              anchors.leftMargin: 12
              anchors.verticalCenter: parent.verticalCenter
              text: "Do Not Disturb"   // widget-config.dnd.text
              color: Theme.text
              font.family: Style.font.family
              font.pixelSize: Style.font.size
              renderType: Text.NativeRendering
            }

            // GTK switch: 48x27 track, 10px-radius slider, measured off the
            // running control center.
            Rectangle {
              id: dndSwitch
              anchors.right: parent.right
              anchors.rightMargin: 12
              anchors.verticalCenter: parent.verticalCenter
              width: 48
              height: 27
              radius: 12               // .widget-dnd > switch
              color: center.store.dnd ? Theme.mauve : Theme.surface0

              Behavior on color {
                ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
              }

              Rectangle {
                width: 21
                height: 21
                radius: 10             // switch slider
                color: Theme.text
                anchors.verticalCenter: parent.verticalCenter
                x: center.store.dnd ? parent.width - width - 3 : 3

                Behavior on x {
                  NumberAnimation { duration: Style.anim.normal; easing.type: Style.anim.easing }
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: center.store.toggleDnd()
              }
            }
          }
        }

        // ------------------------------------------- notifications widget
        // widget-config.notifications.vexpand: true
        Item {
          width: parent.width
          height: body.height - titleWidget.height - dndWidget.height

          // .control-center-list-placeholder { color: @overlay0; padding: 20px }
          Text {
            anchors.centerIn: parent
            visible: center.store.history.length === 0
            opacity: visible ? 1 : 0
            text: center.store.textEmpty
            color: Theme.overlay0
            font.family: Style.font.family
            font.pixelSize: Style.font.size
            renderType: Text.NativeRendering

            Behavior on opacity {
              NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
            }
          }

          Flickable {
            id: list
            anchors.fill: parent
            contentHeight: groups.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: groups
              width: list.width

              Repeater {
                model: center.store.groupModel

                NotificationGroup {
                  required property var modelData

                  store: center.store
                  appKey: modelData
                  width: groups.width
                  selectedKey: center.selectedKey
                  now: center.store.clockTick
                }
              }
            }
          }

          // A hairline scrollbar; swaync has a GTK one, this one only shows
          // itself while there is something to scroll.
          Rectangle {
            anchors.right: parent.right
            anchors.rightMargin: 2
            width: 4
            radius: 2
            color: Theme.surface2
            visible: list.contentHeight > list.height
            opacity: list.moving || listHover.hovered ? 0.9 : 0.35
            y: list.contentHeight > 0 ? list.visibleArea.yPosition * parent.height : 0
            height: list.contentHeight > 0 ? Math.max(24, list.visibleArea.heightRatio * parent.height) : 0

            Behavior on opacity {
              NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
            }
          }

          HoverHandler { id: listHover }
        }
      }
    }
  }

  // ------------------------------------------------------------ keyboard
  // The keyboard-selected row, by entry key. swaync draws it with
  // .notification-row:focus; here the card lights its hover tint.
  property string selectedKey: ""

  function navigate(delta) {
    var nav = store.navigableEntries()
    if (nav.length === 0) return
    var at = -1
    for (var i = 0; i < nav.length; i++) if (nav[i].key === selectedKey) at = i
    var next = at < 0 ? (delta > 0 ? 0 : nav.length - 1) : at + delta
    selectedKey = nav[Math.max(0, Math.min(nav.length - 1, next))].key
  }

  function selectedEntry() {
    var nav = store.navigableEntries()
    for (var i = 0; i < nav.length; i++) if (nav[i].key === selectedKey) return nav[i]
    return null
  }

  function handleKey(event) {
    var entry = selectedEntry()

    switch (event.key) {
    case Qt.Key_Escape:
    case Qt.Key_CapsLock:
      store.closeCenter()
      event.accepted = true
      return
    case Qt.Key_Down:
      navigate(1)
      event.accepted = true
      return
    case Qt.Key_Up:
      navigate(-1)
      event.accepted = true
      return
    case Qt.Key_Home:
      var first = store.navigableEntries()
      if (first.length > 0) selectedKey = first[0].key
      event.accepted = true
      return
    case Qt.Key_End:
      var last = store.navigableEntries()
      if (last.length > 0) selectedKey = last[last.length - 1].key
      event.accepted = true
      return
    case Qt.Key_Return:
    case Qt.Key_Enter:
      // "Execute default action or close notification if none".
      if (entry) store.activateDefault(entry)
      event.accepted = true
      return
    case Qt.Key_Delete:
    case Qt.Key_Backspace:
      if (entry) {
        navigate(1)
        store.close(entry)
      }
      event.accepted = true
      return
    case Qt.Key_C:
      if (event.modifiers & Qt.ShiftModifier) {
        store.clearAll()
        event.accepted = true
      }
      return
    case Qt.Key_D:
      if (event.modifiers & Qt.ShiftModifier) {
        store.toggleDnd()
        event.accepted = true
      }
      return
    }

    // "Buttons 1-9: Execute alternative actions".
    if (entry && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
      store.invokeActionAt(entry, event.key - Qt.Key_1)
      event.accepted = true
    }
  }
}
