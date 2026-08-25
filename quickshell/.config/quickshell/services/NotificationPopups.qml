import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "root:/"

// The floating notification stack -- swaync's "notificationwindow".
//
// config.json parity:
//   "positionX": "right", "positionY": "top"   -> anchored top-right
//   "layer": "overlay"                         -> WlrLayer.Overlay
//   "notification-window-width": 400           -> implicitWidth 400
//   "notification-window-height": -1 (default) -> as tall as the compositor
//                                                 allows, oldest clipped
//   "notification-window-preferred-output": "" -> the focused output
//
// The 400px window holds a 352px card: 12px of .notification margin plus 12px
// of the packaged .notification-background padding on each side. Newest sits
// at the top -- verified against the running daemon, where a second popup
// pushed the first one down rather than stacking under it.
//
// The window is anchored top+right only and sized to its content, and its
// input mask is the card column, so the right-hand strip of the screen stays
// clickable when nothing is showing. `exclusiveZone: 0` reserves nothing but
// still respects the bar's zone, which is why swaync's popups land under the
// bar rather than behind it.
PanelWindow {
  id: popups

  required property var store

  WlrLayershell.namespace: "quickshell-notifications"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: 0

  anchors {
    top: true
    right: true
  }

  color: "transparent"
  visible: store.popups.length > 0

  implicitWidth: store.popupWidth
  // The surface is sized once, to the tallest stack the screen can hold, and
  // is never resized again while cards come and go. A layer surface that
  // changes size has to wait for a compositor configure/ack round trip before
  // it may commit the new size, so binding this to the animating column height
  // meant one round trip per frame: measured, a 180ms entrance took 467ms and
  // landed in five visible lurches, ~100ms apart. The cards animate inside a
  // fixed surface instead, which is also what "notification-window-height: -1"
  // means in swaync -- as tall as the compositor allows, oldest clipped.
  implicitHeight: screen ? screen.height - 24 : 800

  mask: Region {
    x: 24                       // 12px margin + 12px padding
    y: 0
    width: popups.store.popupWidth - 48
    height: Math.ceil(column.height + 6)
  }

  // swaync opens the popup window on the focused output. Retargeting a live
  // layer surface would yank the stack across monitors mid-life, so the
  // monitor is only re-picked while nothing is showing -- which is also why
  // this is imperative: `screen: <expression involving screen>` is a loop.
  readonly property bool idle: store.popups.length === 0

  onIdleChanged: if (idle) retarget()
  Component.onCompleted: retarget()

  Connections {
    target: Hyprland
    function onFocusedMonitorChanged() { if (popups.idle) popups.retarget() }
  }

  function retarget() {
    var focused = Hyprland.focusedMonitor
    if (!focused) return
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (Hyprland.monitorFor(screens[i]) === focused) {
        popups.screen = screens[i]
        return
      }
    }
  }

  Item {
    anchors.fill: parent
    clip: true

    Column {
      id: column
      anchors.top: parent.top
      anchors.topMargin: 6
      anchors.right: parent.right
      anchors.rightMargin: 12
      width: popups.store.popupWidth - 24

      Repeater {
        model: popups.store.popupModel

        NotificationCard {
          id: card
          required property var modelData

          entry: modelData
          cardWidth: popups.store.popupWidth - 48
          showTime: false
          leaving: popups.store.popupLeaving.indexOf(modelData.key) >= 0

          onDefaultActivated: popups.store.activateDefault(modelData)
          onActionActivated: index => popups.store.invokeAction(modelData, index)
          onCloseRequested: popups.store.close(modelData)
          onLinkActivated: link => popups.store.openLink(link)
          onFinished: popups.store.dropPopup(modelData.key)
        }
      }
    }
  }
}
