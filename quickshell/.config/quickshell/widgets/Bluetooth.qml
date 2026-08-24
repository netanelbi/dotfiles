import QtQuick
import Quickshell
// QUALIFIED ON PURPOSE. This file is itself the type `Bluetooth` in the
// `widgets` directory, and QML's implicit same-directory import would let that
// name resolve to this component instead of the service singleton -- i.e.
// infinite recursion. The alias makes the service unambiguous.
import Quickshell.Bluetooth as Bluez
import "root:/"

// Bluetooth controller state.
//
// waybar parity -----------------------------------------------------------
//   config.jsonc  format            "󰂯"                    (on, nothing paired up)
//                 format-connected  "󰂱 {num_connections}"
//                 format-disabled   "󰂲"                    (no controller)
//                 format-off        "󰂲"                    (controller powered off)
//                 tooltip-format            "{controller_alias}: {status}"
//                 tooltip-format-connected  "{controller_alias}\n\n{device_enumerate}"
//                 tooltip-format-enumerate-connected  "  {device_alias}"
//                 on-click        kitty --class bluetui-popup -e bluetui
//                 on-click-right  blueman-manager
//   style.css     #bluetooth { color: @blue; padding: 0 10px }
//                 #bluetooth.disabled, #bluetooth.off { color: @overlay0 }
//
// Motion ------------------------------------------------------------------
// waybar swaps glyph and colour in one frame, and the connection count appears
// out of nowhere. Here blue<->overlay0 cross-fades, the count slides open from
// zero width, and a controller mid-enable/disable pulses instead of sitting
// silently on the old glyph.
BarWidget {
  id: root

  // waybar keeps this module on screen in every state (there is a format for
  // each), so it never collapses.
  shown: true

  clickCommand: "kitty --class bluetui-popup -e bluetui"
  rightClickCommand: "blueman-manager"

  readonly property var adapter: Bluez.Bluetooth.defaultAdapter
  readonly property bool hasAdapter: adapter !== null && adapter !== undefined
  readonly property int adapterState: hasAdapter ? adapter.state : Bluez.BluetoothAdapterState.Disabled
  readonly property bool powered: hasAdapter && adapterState === Bluez.BluetoothAdapterState.Enabled
  // Enabling/Disabling: the controller is mid-flight, so the glyph is stale.
  readonly property bool settling: hasAdapter
      && (adapterState === Bluez.BluetoothAdapterState.Enabling
          || adapterState === Bluez.BluetoothAdapterState.Disabling)

  readonly property var connectedDevices: {
    var out = []
    if (!root.hasAdapter) return out
    var devices = Bluez.Bluetooth.devices.values
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].connected) out.push(devices[i])
    }
    return out
  }
  readonly property int connectionCount: connectedDevices.length
  readonly property bool connected: powered && connectionCount > 0

  // The last non-zero count, held so the number does not flicker to "0" while
  // the slot animates shut.
  property string lastConnectionCount: ""
  onConnectionCountChanged: if (connectionCount > 0) lastConnectionCount = String(connectionCount)

  // waybar's {status}, verbatim: the state name it also uses as the CSS class.
  readonly property string status: !hasAdapter ? "disabled" : (powered ? (connected ? "connected" : "on") : "off")

  tooltip: {
    if (!root.hasAdapter) return "Bluetooth: disabled"
    var alias = root.adapter.name
    if (!root.connected) return alias + ": " + root.status
    var lines = []
    for (var i = 0; i < root.connectedDevices.length; i++) {
      var device = root.connectedDevices[i]
      lines.push("  " + (device.name !== "" ? device.name : device.deviceName))
    }
    return alias + "\n\n" + lines.join("\n")
  }

  Text {
    id: glyph
    text: root.connected ? "󰂱" : (root.powered ? "󰂯" : "󰂲")
    color: root.powered ? Theme.blue : Theme.inactive
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    renderType: Text.NativeRendering

    Behavior on color {
      ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
    }

    // A radio that is powering up or down breathes until it settles.
    opacity: 1
    SequentialAnimation {
      running: root.settling
      loops: Animation.Infinite
      alwaysRunToEnd: true
      onStopped: glyph.opacity = 1
      NumberAnimation { target: glyph; property: "opacity"; to: 0.4; duration: 450; easing.type: Easing.InOutSine }
      NumberAnimation { target: glyph; property: "opacity"; to: 1; duration: 450; easing.type: Easing.InOutSine }
    }

    // The glyph itself changes shape between states; a short pop sells the swap.
    onTextChanged: glyphPop.restart()
    SequentialAnimation {
      id: glyphPop
      NumberAnimation {
        target: glyph; property: "scale"
        from: 0.72; to: 1
        duration: Style.anim.normal
        easing.type: Style.anim.easingEnter
        easing.overshoot: Style.anim.overshoot
      }
    }
  }

  // {num_connections}. Collapses to nothing when there is nobody connected,
  // which is waybar's `format` vs `format-connected` swap with motion attached.
  Item {
    id: countSlot
    implicitWidth: root.connected ? countLabel.implicitWidth : 0
    implicitHeight: countLabel.implicitHeight
    clip: true
    opacity: root.connected ? 1 : 0

    Behavior on implicitWidth {
      NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
    }
    Behavior on opacity {
      NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
    }

    Text {
      id: countLabel
      anchors.verticalCenter: parent.verticalCenter
      text: root.lastConnectionCount
      color: glyph.color
      font.family: Style.font.family
      font.pixelSize: Style.font.size
      renderType: Text.NativeRendering
    }
  }
}
