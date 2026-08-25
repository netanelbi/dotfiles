import QtQuick
import Quickshell
import Quickshell.Wayland
import "widgets"

// The bar chrome: one layer-shell surface per monitor, three rounded
// "islands", and the shared tooltip popup.
//
// Geometry is a transcription of the running waybar:
//   config.jsonc  layer top, position top, height 30, margins 2/2/2, spacing 0
//   style.css     .modules-left/.modules-center/.modules-right {
//                   background: alpha(@base, 0.95); border-radius: 14px;
//                   padding: 4px 12px; margin: 2px 0 }
// The window itself is transparent -- only the three islands are painted, which
// is what gives waybar its floating-pill look.
//
// INPUT: nothing is layered above the widgets. No bar-wide MouseArea, no
// HoverHandler, no click router -- a widget's own MouseArea gets the press.
// Keep it that way (see BarWidget.qml's click contract).
PanelWindow {
  id: bar

  property var modelData: null
  screen: modelData

  WlrLayershell.namespace: "quickshell-bar"
  WlrLayershell.layer: WlrLayer.Top

  anchors {
    top: true
    left: true
    right: true
  }

  margins {
    top: Style.bar.marginTop
    left: Style.bar.marginSide
    right: Style.bar.marginSide
  }

  implicitHeight: Style.bar.height
  color: "transparent"

  // ---------------------------------------------------------------- chrome
  Item {
    id: content
    // Sized, not anchored: the intro animation drives `y`, and anchors.fill
    // would fight it (the anchor system owns y on an anchored item).
    width: parent.width
    height: parent.height

    // Startup: the bar drops in rather than blinking into existence.
    opacity: 0
    y: -Style.bar.height
    Component.onCompleted: introAnimation.start()

    ParallelAnimation {
      id: introAnimation
      NumberAnimation { target: content; property: "opacity"; to: 1; duration: Style.anim.slow; easing.type: Style.anim.easingSmooth }
      NumberAnimation { target: content; property: "y"; to: 0; duration: Style.anim.slow; easing.type: Style.anim.easing }
    }

    Island {
      id: leftIsland
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter

      // LEFT SECTION -- waybar's "modules-left", in its order:
      //   hyprland/workspaces, custom/scratchpad, custom/windows.

      // hyprland/workspaces -- the mauve-outlined pills for this monitor.
      Workspaces { barScreen: bar.screen }

      // custom/scratchpad -- the gold 󰝖 counter, gone when nothing is stashed.
      Scratchpad { }

      // custom/windows -- the live title list for the visible workspace.
      Windows { }
    }

    Island {
      id: centerIsland
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter

      // CENTER SECTION -- waybar's "modules-center", in its order:
      //   clock, hyprland/language, custom/capslock, pulseaudio#mic,
      //   power-profiles-daemon, custom/tdp, custom/stay-awake, custom/gamepads.
      // Every one after the clock collapses to zero width in its idle state,
      // which is what waybar's `color: transparent` rules amount to.
      //
      // Clock: waybar's built-in `clock` module -- format "  {:%a %d %b %H:%M}",
      // format-alt "  {:%A, %B %d %Y}" on click.
      BarWidget {
        id: clockWidget
        property bool longFormat: false
        tooltip: Qt.formatDateTime(clock.date, "dddd, d MMMM yyyy")
        onClicked: longFormat = !longFormat

        Text {
          text: ""
          color: Theme.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.size
          font.weight: Style.font.boldWeight
          renderType: Text.NativeRendering
        }

        Text {
          id: clockLabel
          text: Qt.formatDateTime(clock.date, clockWidget.longFormat ? "dddd, d MMMM yyyy" : "ddd dd MMM  HH:mm")
          color: Theme.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.size
          font.weight: Style.font.boldWeight
          renderType: Text.NativeRendering

          // Example of the motion this shell expects from widgets: waybar's
          // clock snaps from one minute to the next; this one lifts into place.
          onTextChanged: tick.restart()
          SequentialAnimation {
            id: tick
            NumberAnimation { target: clockLabel; property: "y"; from: 3; to: 0; duration: Style.anim.normal; easing.type: Style.anim.easing }
          }
        }
      }

      // hyprland/language -- "us" / "il", peach and bold.
      Language { }

      // custom/capslock -- red 󰪛 while the LED is lit, gone otherwise.
      Capslock { }

      // pulseaudio#mic -- a MUTE indicator: nothing at all while the mic is live.
      Microphone { }

      // Sits where waybar's "modules-center" puts power-profiles-daemon:
      // after the clock/language/capslock/mic run.
      PowerProfile { }

      // custom/tdp -- the 11px peach wattage, only when a custom TDP is set.
      Tdp { }

      // custom/stay-awake -- the yellow cup while the lid inhibitor is held.
      StayAwake { }

      // custom/gamepads -- one span per connected pad, in its own lightbar colour.
      Gamepads { }
    }

    Island {
      id: rightIsland
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter

      // RIGHT SECTION -- tray, bluetooth, network, audio, battery.
      // Order is waybar's "modules-right", left to right.
      Tray { }
      Bluetooth { }
      Network { }
      Audio { }
      Battery { }
    }
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }

  // --------------------------------------------------------------- island
  // One rounded group of modules. Sizes itself to its content and animates
  // every width change, so a module appearing or collapsing slides the rest of
  // the group instead of teleporting it.
  component Island: Rectangle {
    id: island
    default property alias content: islandRow.data

    readonly property bool empty: islandRow.implicitWidth <= 0

    implicitWidth: islandRow.implicitWidth + 2 * Style.bar.islandPaddingH
    height: Style.bar.islandHeight
    radius: Style.bar.islandRadius
    color: Theme.islandBackground
    // An empty section paints nothing at all, matching waybar's empty boxes.
    opacity: empty ? 0 : 1
    visible: opacity > 0.01

    // No Behavior on implicitWidth. The left island holds the window-title
    // list, which is replaced wholesale on every workspace switch -- animating
    // the island's own width meant the entire group slid out and back in each
    // time, on top of whatever its contents were already doing. The island
    // resizes instantly; only its contents fade.
    Behavior on opacity {
      NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
    }
    Behavior on color {
      ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
    }

    Row {
      id: islandRow
      anchors.centerIn: parent
      spacing: Style.bar.islandSpacing

      // Reflow when a module appears or disappears: neighbours slide instead of
      // jumping. Only x/y are animated -- opacity and width belong to the
      // widget, and touching them here would break BarWidget's bindings.
      move: Transition {
        NumberAnimation { properties: "x,y"; duration: Style.anim.reveal; easing.type: Style.anim.easing }
      }
    }
  }

  // -------------------------------------------------------------- tooltip
  // A single popup surface shared by every widget. BarWidget reaches it with
  // `QsWindow.window.showTooltip(...)`, so widgets need no injected reference.
  property var tooltipTarget: null
  property string tooltipText: ""
  property bool tooltipRich: false
  property bool tooltipOpen: false

  function showTooltip(item, text, markup) {
    tooltipTarget = item
    tooltipText = text
    tooltipRich = markup === true
    tooltipOpen = text !== ""
  }

  function hideTooltip(item) {
    if (item !== null && item !== undefined && tooltipTarget !== item) return
    tooltipOpen = false
  }

  PopupWindow {
    id: tooltipWindow

    visible: bar.tooltipTarget !== null && bar.tooltipText !== "" && (bar.tooltipOpen || bubble.opacity > 0.01)
    color: "transparent"
    implicitWidth: Math.ceil(bubble.implicitWidth)
    implicitHeight: Math.ceil(bubble.implicitHeight)

    anchor {
      id: tooltipAnchor
      item: bar.tooltipTarget
      adjustment: PopupAdjustment.Slide
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.width: 1
      rect.height: 1

      onAnchoring: {
        var target = bar.tooltipTarget
        if (!target) return
        tooltipAnchor.rect.x = Math.round(target.width / 2 - tooltipWindow.implicitWidth / 2)
        tooltipAnchor.rect.y = Math.round(target.height + 8)
      }
    }

    Rectangle {
      id: bubble
      // tooltip { background: @base; border: 1px solid @surface0; border-radius: 8px }
      implicitWidth: tooltipLabel.implicitWidth + 20
      implicitHeight: tooltipLabel.implicitHeight + 14
      color: Theme.tooltipBackground
      border.width: 1
      border.color: Theme.tooltipBorder
      radius: Style.module.radius

      // waybar's tooltip pops; this one fades up.
      opacity: bar.tooltipOpen ? 1 : 0
      y: bar.tooltipOpen ? 0 : -4
      Behavior on opacity { NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth } }
      Behavior on y { NumberAnimation { duration: Style.anim.normal; easing.type: Style.anim.easing } }

      Text {
        id: tooltipLabel
        anchors.centerIn: parent
        text: bar.tooltipText
        textFormat: bar.tooltipRich ? Text.RichText : Text.PlainText
        color: Theme.tooltipText
        font.family: Style.font.family
        font.pixelSize: Style.font.tooltip
        horizontalAlignment: Text.AlignHCenter
        renderType: Text.NativeRendering
      }
    }
  }
}
