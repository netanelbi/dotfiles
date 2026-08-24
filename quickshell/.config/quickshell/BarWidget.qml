import QtQuick
import Quickshell

// Base component every bar widget extends.
//
// ---------------------------------------------------------------- content
// Children are laid out in a horizontal Row (the default property), centred in
// the widget, with `spacing` between them:
//
//     BarWidget {
//       clickCommand: "pavucontrol"
//       Text { text: "󰕾"; color: Theme.mauve; font.family: Style.font.family }
//     }
//
// Children must NOT anchor to their parent -- the Row positions them and the
// base derives its implicit width from the Row. Use Layout-free plain Items.
//
// ----------------------------------------------------------- click contract
// THE WIDGET'S OWN MouseArea RECEIVES THE PRESS. There is no bar-level click
// router, no hit-test registry, no "triggerPress" indirection: Bar.qml puts
// nothing above the widgets, so the press lands here directly. If you ever add
// an overlay inside Bar.qml, it MUST be transparent to input
// (`acceptedButtons: Qt.NoButton`, no HoverHandler that grabs) or every widget
// below it goes dead.
//
// Two ways to react, mirroring waybar's config keys 1:1:
//   * commands  -- clickCommand / rightClickCommand / middleClickCommand /
//                  scrollUpCommand / scrollDownCommand. Same strings you would
//                  put in on-click / on-click-right / on-click-middle /
//                  on-scroll-up / on-scroll-down. Run via `sh -lc`, detached.
//   * signals   -- clicked / rightClicked / middleClicked / scrolledUp /
//                  scrolledDown, for anything that needs QML logic.
// Both fire; the signal is emitted even when a command is set.
//
// Hyprland note: `hyprctl dispatch` parses its argument as LUA on 0.56+, so a
// dispatch command must read:
//     hyprctl dispatch 'hl.dsp.focus({ workspace = "2" })'
// The old `hyprctl dispatch workspace 2` is a syntax error.
Item {
  id: root

  default property alias content: row.data

  // ------------------------------------------------------------- geometry
  property int spacing: 4
  property int horizontalPadding: Style.module.paddingH
  property int verticalPadding: 0
  property int minWidth: 0
  // Extra outer gap, matching style.css's per-module `margin: 0 4px`.
  property int sideMargin: 0

  // Natural width with padding applied.
  readonly property real fullWidth: Math.max(minWidth, row.implicitWidth + 2 * horizontalPadding + 2 * sideMargin)

  // Collapse control. waybar hides an inactive indicator by painting it
  // `color: transparent`; here it animates to zero width and fades out, which
  // is the same end state with motion attached.
  property bool shown: true

  implicitWidth: shown ? fullWidth : 0
  implicitHeight: Style.bar.slotHeight
  opacity: shown ? 1 : 0
  visible: opacity > 0.01
  clip: true

  Behavior on implicitWidth {
    NumberAnimation {
      duration: Style.anim.reveal
      easing.type: Style.anim.easing
    }
  }

  Behavior on opacity {
    NumberAnimation {
      duration: Style.anim.opacityDuration
      easing.type: Style.anim.easingSmooth
    }
  }

  // ----------------------------------------------------------- background
  // Defaults to nothing drawn, which is what most waybar modules look like.
  // The pill (radius 8) plus a 2px border reproduces `#custom-scratchpad.active`
  // and the active workspace outline.
  property color backgroundColor: "transparent"
  property color borderColor: "transparent"
  property int borderWidth: 0
  property int radius: Style.module.radius
  // Hover tint, matching `#workspaces button:hover`.
  property bool hoverHighlight: interactive
  property color hoverColor: Theme.hoverBackground

  readonly property bool hovered: mouse.containsMouse
  readonly property bool pressed: mouse.pressed

  Rectangle {
    id: background
    anchors.fill: parent
    anchors.leftMargin: root.sideMargin
    anchors.rightMargin: root.sideMargin
    radius: root.radius
    color: root.hoverHighlight && root.hovered ? root.hoverColor : root.backgroundColor
    border.width: root.borderWidth
    border.color: root.borderColor

    // waybar snaps; we cross-fade.
    Behavior on color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }
    Behavior on border.color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }
    Behavior on border.width { NumberAnimation { duration: Style.anim.normal; easing.type: Style.anim.easing } }

    // A press dips the whole widget a touch. Cheap, and it makes clicks feel
    // acknowledged in a way waybar never does.
    scale: root.pressed && root.interactive ? 0.94 : 1
    Behavior on scale { NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing } }
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: root.spacing
    scale: background.scale
  }

  // -------------------------------------------------------------- tooltip
  // Raised by the bar window (Bar.qml owns the single popup surface) after a
  // hover delay. Set `tooltipMarkup` when the string carries pango/HTML.
  property string tooltip: ""
  property bool tooltipMarkup: false

  Timer {
    id: tooltipTimer
    interval: Style.anim.tooltipDelay
    onTriggered: root.showTooltip()
  }

  function barWindow() {
    var w = root.QsWindow ? root.QsWindow.window : null
    return w && typeof w.showTooltip === "function" ? w : null
  }

  function showTooltip() {
    var w = barWindow()
    if (w && root.tooltip !== "") w.showTooltip(root, root.tooltip, root.tooltipMarkup)
  }

  function hideTooltip() {
    tooltipTimer.stop()
    var w = barWindow()
    if (w) w.hideTooltip(root)
  }

  onTooltipChanged: {
    // Keep an already-open tooltip live while the underlying script updates.
    var w = barWindow()
    if (w && hovered && tooltip !== "") w.showTooltip(root, tooltip, tooltipMarkup)
    else if (w && tooltip === "") w.hideTooltip(root)
  }

  onShownChanged: if (!shown) hideTooltip()
  Component.onDestruction: hideTooltip()

  // ---------------------------------------------------------------- input
  property bool interactive: true

  property string clickCommand: ""
  property string rightClickCommand: ""
  property string middleClickCommand: ""
  property string scrollUpCommand: ""
  property string scrollDownCommand: ""

  signal clicked()
  signal rightClicked()
  signal middleClicked()
  signal scrolledUp()
  signal scrolledDown()

  // Detached so a long-lived popup (kitty -e impala, pavucontrol, ...) does not
  // hang off the shell process. `sh -lc` so the strings copied out of
  // config.jsonc -- pipes, `~`, quoting and all -- behave identically.
  function run(command) {
    if (!command || command === "") return
    Quickshell.execDetached(["sh", "-lc", command])
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    enabled: root.interactive
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor

    onEntered: if (root.tooltip !== "") tooltipTimer.restart()
    onExited: root.hideTooltip()

    onClicked: function (event) {
      if (event.button === Qt.LeftButton) {
        root.run(root.clickCommand)
        root.clicked()
      } else if (event.button === Qt.RightButton) {
        root.run(root.rightClickCommand)
        root.rightClicked()
      } else if (event.button === Qt.MiddleButton) {
        root.run(root.middleClickCommand)
        root.middleClicked()
      }
    }

    // Wheel notches arrive as 120ths of a degree; accumulate so a high-res
    // touchpad scroll does not fire once per pixel.
    property int wheelAccum: 0
    onWheel: function (event) {
      wheelAccum += event.angleDelta.y
      while (wheelAccum >= 120) {
        wheelAccum -= 120
        root.run(root.scrollUpCommand)
        root.scrolledUp()
      }
      while (wheelAccum <= -120) {
        wheelAccum += 120
        root.run(root.scrollDownCommand)
        root.scrolledDown()
      }
    }
  }
}
