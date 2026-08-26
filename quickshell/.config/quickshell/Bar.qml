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
        tooltip: Qt.formatDateTime(clock.date, "dddd, d MMMM yyyy") + "\nright-click for the long format"
        // waybar's format-alt lived on the left click. It moved to the right
        // button so the left one can open the calendar -- the toggle is still
        // there, it just is not the first thing the clock does any more.
        onClicked: calendarPopup.toggle()
        onRightClicked: longFormat = !longFormat

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

      // NOT a waybar module -- the first thing in this island that is not.
      // swaync's tray icon is what it replaces, and this shell dropped that in
      // the port: the control centre came across whole and nothing was left
      // that opens it (no module, and no keybind either -- hyprland.lua binds
      // eleven other ipc targets and not that one). So this is both the held
      // count and the door.
      //
      // Here rather than in the right island for a measured reason. The right
      // island is anchored right, so a module appearing in it grows the island
      // LEFTWARD -- and oriZone.x is bound to that island's leading edge, so
      // the assistant's mark would slide ~30px sideways every time a batch
      // opened. The comment on `zoneWidth` in Style.qml calls the battery's own
      // 8px of drift out as a problem; four times that, triggered by a Slack
      // message, is not a trade worth making. This island is where every
      // collapse-when-idle indicator already lives.
      Inbox { }

      // Ori is NOT here any more. It used to be the last module in this island
      // and it read as the ninth status chip in a row of eight. It now lives
      // unhoused in the gap to the right -- see `oriZone` below.
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

    // ------------------------------------------------------------- ori's cell
    // The assistant's ONLY permanent presence, and it is entirely inside this
    // bar's own 30px strip. Twelve earlier designs put light on the desktop and
    // every one was rejected for the same reason, in the user's words: "they all
    // share the same issue. its on the main windows and it will bother me on
    // other windows." OriAura (a wash across the whole screen edge) and
    // OriArrival (the answer's first line, hung under the bar) are deleted --
    // they were exactly that fault, 750 lines of it.
    //
    // ------------------------------------------------------------- the zone
    // A fixed-width Item positioned by `x`, deliberately NOT a member of any
    // island's Row. Its width is a constant -- the cell's EXPANDED footprint --
    // and the cell animates inside it. So compact and expanded are the same
    // reservation, and nothing the assistant does can push the clock island or
    // the tray island by a pixel.
    //
    // Its x follows the RIGHT island's leading edge, so what is held constant is
    // the GAP rather than an absolute position: the right island grows by ~8px
    // when the battery drops from 100% to 9%, and anchoring to the bar instead
    // would hold the mark still and let the gap close on it.
    //
    // The right gap and not the left: the left one holds the window-title list,
    // which is replaced wholesale on every workspace switch and can be several
    // hundred px wide.
    Item {
      id: oriZone
      width: Style.ori.zoneWidth
      height: Style.bar.islandHeight
      anchors.verticalCenter: parent.verticalCenter
      // Clamped off the CENTRE island's trailing edge as well, and only ever
      // as a floor. On both of this repo's machines the right gap is far wider
      // than the reservation -- 355px against 172 on eDP-1's 1280 logical --
      // so the clamp never engages and the mark is welded to the right island,
      // which is the whole design: the gap is what is held constant. On a
      // screen narrow enough that the two islands nearly meet, it slides the
      // mark right rather than letting the clock bury it. A mark that moves is
      // a worse mark; a mark that is hidden is not a mark.
      x: Math.max(centerIsland.x + centerIsland.width + Style.bar.islandPaddingH,
                  rightIsland.x - Style.ori.zoneGap - width)
      // Belt and braces on the promise this whole design makes: whatever the
      // cell does, it cannot paint outside the zone, and the zone is inside the
      // bar. Nothing reaches a window.
      clip: true

      OriCell {
        id: oriCell
        // ...and when even the clamp cannot find room, the cell stays shut.
        // Measured on a 960-logical output: the two islands leave 88px, the
        // open cell wants 144, and the tail of "1m 11s" was drawn across the
        // tray icons. Refusing to open is the right failure -- the mark, the
        // rule and the state are all still there, and the hover panel carries
        // every word the readout would have. Nothing is lost but the glance.
        cramped: bar.oriRoom < Style.ori.zoneWidth + 2 * Style.ori.zoneGap
      }
    }
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }

  // ------------------------------------------------------------- calendar
  // The clock's popover. It is its own fullscreen layer surface rather than a
  // PopupWindow anchored to the clock -- see CalendarPopup.qml for why. It
  // needs the bar's origin to convert the clock's position into screen
  // coordinates, and the bar's bottom edge to hang under.
  CalendarPopup {
    id: calendarPopup
    screen: bar.screen
    anchorItem: clockWidget
    barOriginX: Style.bar.marginSide
    cardTop: Style.bar.marginTop + Style.bar.height + 4
  }

  // ------------------------------------------------------------- ori's veil
  // The hover panel -- the one surface allowed to lie over the user's windows,
  // because they asked for it: "when hovering with the mouse it expands under
  // in a good design on top of other windows so i can see the more details."
  //
  // Mounted here for the reason CalendarPopup is: it is one surface PER
  // MONITOR, and the bar is the thing that already exists per monitor. Built
  // already-visible and destroyed on leave, so a desktop nobody is pointing at
  // carries no extra layer surface at all.
  //
  // It is above the widgets in this file, which would normally kill every
  // widget's click (see the INPUT note at the top). It does not, because it is
  // a separate surface whose input mask is the text block alone. Nothing
  // inside `content` may take that liberty.

  // The pointer's own answer, and the ONLY thing that raises the surface.
  readonly property bool veilWanted: oriCell.hovered
  // ...and a second term, because the surface has to OUTLIVE the hover by the
  // length of its exit animation: a loader that dropped the object on the frame
  // the pointer left would cut the retraction off at its first frame. The veil
  // clears this itself when it has finished leaving.
  property bool veilRetaining: false
  onVeilWantedChanged: if (veilWanted) bar.veilRetaining = true

  LazyLoader {
    id: veilLoader
    // An OR and not a latch: `veilWanted` alone decides existence on the way
    // in, so there is no initial-value case where the surface waits for a
    // change signal that a constant true will never send.
    active: bar.veilWanted || bar.veilRetaining

    component: OriVeil {
      barScreen: bar.screen
      // The mark's x on the SCREEN. A live binding, not a measurement -- the
      // zone's x follows the right island, which moves when the battery or the
      // tray changes. It is computed HERE rather than inside the cell because
      // the thing that moves the glyph is the ZONE: `mapToItem` inside the
      // widget is not a reactive expression and had no dependency it could be
      // given (it returned a stale -161 in a capture, which is how this was
      // found). `content` sits at x=0 inside the bar window, so the bar's own
      // side margin is the only other term.
      originX: Style.bar.marginSide + oriZone.x + Style.ori.haloBox / 2
      // PUSHED into the surface, not read out of it -- a loader whose `active`
      // reads a property of the object it decides the existence of is a
      // binding loop (the same shape Assistant.qml solves the same way).
      anchored: bar.veilWanted
      onDone: bar.veilRetaining = false
    }
  }

  // Calendar reminders run whether or not the popover is ever opened, so the
  // singleton has to be CONSTRUCTED at shell start -- Quickshell builds a
  // singleton on first use, and nothing else would touch this one until a
  // click. One instance regardless of how many monitors instantiate this bar.
  //
  // The touch is an ASSIGNMENT, not a `readonly property x: Singleton.y`
  // binding: an unread binding is evaluated lazily, so the singleton came up
  // on some reloads and not others, and reminders silently did not run.
  // How much bar there is between the centre and right islands. Read by the
  // cell, which will not open into a gap that cannot hold it.
  readonly property real oriRoom: rightIsland.x - (centerIsland.x + centerIsland.width)

  property bool remindersLive: false
  Component.onCompleted: bar.remindersLive = CalendarReminders.stateLoaded

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
