import QtQuick
import Quickshell
import Quickshell.Services.UPower
import "root:/"

// Battery.
//
// waybar parity -----------------------------------------------------------
//   config.jsonc  "bat": "BAT1"
//                 format          "{icon} {capacity}%"
//                 format-charging "󰂄 {capacity}%"
//                 format-plugged  "󰚥 {capacity}%"
//                 format-icons    11 glyphs, empty -> full
//                 tooltip-format  "{timeTo}\nPower: {power}W"
//                 states          warning 20, critical 10
//   style.css     #battery { color: @green; padding: 0 10px }
//                 #battery.warning  { color: @yellow }
//                 #battery.critical { color: @red; animation: blink 1s infinite }
//                 #battery.charging { color: @green }
//                 @keyframes blink { to { color: @text } }
//   The .charging rule is last in the stylesheet, so at equal specificity it
//   beats .critical: a battery that is charging at 5% is green, not red.
//
// Motion ------------------------------------------------------------------
// waybar's blink is a GTK animation with a single `to` keyframe and the default
// `animation-direction: normal`, so it fades red -> text over a second and then
// SNAPS back to red. Here the same one-second cadence runs as a sine pulse in
// both directions. Everything else -- the icon stepping down the ladder, green
// -> yellow -> red, the label gaining a digit -- cross-fades or slides instead
// of switching in one frame.
BarWidget {
  id: root

  // config.jsonc pins the module to BAT1; UPower's display device is the
  // fallback for a machine where that name does not exist.
  readonly property var device: {
    var devices = UPower.devices.values
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].nativePath === "BAT1") return devices[i]
    }
    return UPower.displayDevice
  }

  readonly property bool present: device !== null && device !== undefined && device.isPresent
  // UPowerDevice.percentage is a 0..1 fraction (unlike healthPercentage, which
  // is 0..100) -- verified live: 0.82 for an 82% battery. Reading it as a
  // percentage outright would pin the widget at 1% and permanently critical.
  readonly property int capacity: present ? Math.round(device.percentage * 100) : 0
  // NOT `state`: that name already belongs to Item (QML states).
  readonly property int batteryState: present ? device.state : UPowerDeviceState.Unknown

  readonly property bool charging: batteryState === UPowerDeviceState.Charging
  // waybar's "plugged": on mains but not taking charge -- which on this laptop
  // is the normal resting state, because BAT1 has a 75/80% charge threshold.
  readonly property bool plugged: batteryState === UPowerDeviceState.FullyCharged
                                  || batteryState === UPowerDeviceState.PendingCharge
  readonly property bool critical: capacity <= 10
  readonly property bool warning: !critical && capacity <= 20

  // waybar's AModule::getIcon with 11 icons: idx = capacity / (100 / 11), whole
  // division, so 9 points per step, clamped to the last glyph.
  readonly property var icons: ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  readonly property string icon: charging ? "󰂄"
      : (plugged ? "󰚥"
                 : icons[Math.max(0, Math.min(icons.length - 1, Math.floor(capacity / Math.floor(100 / icons.length))))])

  shown: present

  // waybar's formatTimeRemaining: "{H} h {M} min", prefixed "Empty in " /
  // "Full in ".
  function formatDuration(seconds) {
    var hours = Math.floor(seconds / 3600)
    var minutes = Math.floor((seconds - hours * 3600) / 60)
    return hours + " h " + minutes + " min"
  }

  readonly property string timeTo: {
    if (!root.present) return ""
    if (root.charging && root.device.timeToFull > 0) return "Full in " + root.formatDuration(root.device.timeToFull)
    if (!root.charging && root.device.timeToEmpty > 0) return "Empty in " + root.formatDuration(root.device.timeToEmpty)
    return ""
  }

  // waybar formats {power} with fmt's "{:.3}" -- three significant digits, with
  // trailing zeros dropped.
  function formatPower(watts) {
    var text = Number(watts).toPrecision(3)
    if (text.indexOf(".") !== -1) text = text.replace(/\.?0+$/, "")
    return text
  }

  tooltip: {
    if (!root.present) return ""
    var power = "Power: " + root.formatPower(root.device.changeRate) + "W"
    return root.timeTo === "" ? power : root.timeTo + "\n" + power
  }

  // ------------------------------------------------------------- colouring
  readonly property color stateColor: charging ? Theme.green
      : (critical ? Theme.red : (warning ? Theme.yellow : Theme.green))

  // The ladder transition lives here, on the state colour. Putting a Behavior
  // on the final colour instead would fight the blink pulse and smear it.
  property color smoothStateColor: stateColor
  Behavior on smoothStateColor {
    ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
  }

  // 0 = the state colour, 1 = @text. Driven by the blink pulse below.
  property real blink: 0
  readonly property color displayColor: Qt.rgba(
      smoothStateColor.r + (Theme.foreground.r - smoothStateColor.r) * blink,
      smoothStateColor.g + (Theme.foreground.g - smoothStateColor.g) * blink,
      smoothStateColor.b + (Theme.foreground.b - smoothStateColor.b) * blink,
      1)

  SequentialAnimation {
    running: root.critical && !root.charging
    loops: Animation.Infinite
    alwaysRunToEnd: true
    onStopped: root.blink = 0
    NumberAnimation { target: root; property: "blink"; to: 1; duration: 500; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "blink"; to: 0; duration: 500; easing.type: Easing.InOutSine }
  }

  Text {
    id: glyph
    text: root.icon
    color: root.displayColor
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    renderType: Text.NativeRendering

    // Stepping to the next glyph in the ladder, or swapping to 󰂄 the moment the
    // charger goes in, is a shape change: pop it.
    onTextChanged: glyphPop.restart()
    SequentialAnimation {
      id: glyphPop
      NumberAnimation {
        target: glyph; property: "scale"
        from: 0.8; to: 1
        duration: Style.anim.normal
        easing.type: Style.anim.easingEnter
        easing.overshoot: Style.anim.overshoot
      }
    }
  }

  Text {
    id: label
    text: root.capacity + "%"
    color: root.displayColor
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    renderType: Text.NativeRendering

    onTextChanged: labelTick.restart()
    SequentialAnimation {
      id: labelTick
      NumberAnimation {
        target: label; property: "y"
        from: 2; to: 0
        duration: Style.anim.quick
        easing.type: Style.anim.easing
      }
    }
  }
}
