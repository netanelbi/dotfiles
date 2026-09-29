import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "widgets"
import "assistant"

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

  // The surface spans the whole top edge with NO layer margins: the theme's
  // margin is drawn inside it (`body` below), so a soft shadow or glow has room
  // on every side of a floating strip. The exclusive zone is set explicitly to
  // what the old margins reserved: margin + bar (+ a brutal hard shadow), which
  // is 32 in catppuccin, as ever.
  exclusiveZone: bar.barBottom
  // Everything below the bar hangs off this line (popups, Ori's veil, the board
  // compute the same sum from Style.bar).
  readonly property int barBottom: Style.bar.marginTop + Style.bar.height + Theme.shadowY

  // Sized ONCE per theme to include the transparent shadow room under the bar
  // (0 in catppuccin), never animated -- see the layer-surface note in CLAUDE.md.
  implicitHeight: bar.barBottom + Style.bar.shadowRoom
  color: "transparent"

  // The shadow room is paint only: clicks there fall through to the window
  // underneath.
  mask: Region { item: inputZone }
  Item { id: inputZone; width: bar.width; height: bar.barBottom }

  // ---------------------------------------------------------------- chrome
  Item {
    id: content
    // Sized, not anchored: the intro animation drives `y`, and anchors.fill
    // would fight it (the anchor system owns y on an anchored item).
    width: parent.width
    height: parent.height

    // Startup: the bar drops in rather than blinking into existence.
    // The start pose is ASSIGNED, not bound: an animation does not break a
    // binding, so `y: -Style.bar.height` re-fired on every theme switch that
    // changed the bar height and parked the islands above the screen.
    Component.onCompleted: {
      content.opacity = 0
      content.y = -Style.bar.height
      introAnimation.start()
    }

    // A hot reload can race the animation driver on a second output: the
    // intro never ticks and the bar stays at opacity 0 forever -- seen on
    // DP-2 while eDP-1's identical bar was fine. This watchdog forces the
    // end state if the intro has not landed; a bar that finished its intro
    // is untouched.
    Timer {
      interval: 1500
      running: true
      onTriggered: if (content.opacity < 1) { content.opacity = 1; content.y = 0 }
    }

    ParallelAnimation {
      id: introAnimation
      NumberAnimation { target: content; property: "opacity"; to: 1; duration: Style.anim.slow; easing.type: Style.anim.easingSmooth }
      NumberAnimation { target: content; property: "y"; to: 0; duration: Style.anim.slow; easing.type: Style.anim.easing }
    }

    // The bar proper, inset by the theme's margin. Strip/flat themes paint one
    // background across it; islands themes paint each island; bare paints none.
    Item {
      id: body
      x: Style.bar.marginSide
      y: Style.bar.marginTop
      width: content.width - 2 * Style.bar.marginSide
      height: Style.bar.height

    SoftShadow { target: strip; shown: Theme.barMode === "strip" }

    Rectangle {
      id: strip
      visible: Theme.barMode === "strip" || Theme.barMode === "flat"
      anchors.fill: parent
      radius: Theme.barMode === "strip" ? Theme.barRadius : 0
      color: Theme.barBackground
      border.width: Theme.barMode === "strip" && Theme.barBorder.a > 0 ? 1 : 0
      border.color: Theme.barBorder

      // flat (paper): one ink hairline along the bottom edge.
      Rectangle {
        visible: Theme.barMode === "flat" && Theme.barHairline.a > 0
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 1
        color: Theme.barHairline
      }
    }

    Island {
      id: leftIsland
      anchors.left: parent.left
      anchors.leftMargin: Theme.barEdgePadding
      anchors.top: parent.top
      anchors.topMargin: Style.bar.islandInset

      // LEFT SECTION -- waybar's "modules-left", in its order:
      //   hyprland/workspaces, custom/scratchpad, custom/windows.

      // hyprland/workspaces -- the mauve-outlined pills for this monitor.
      Workspaces { id: workspacesWidget; barScreen: bar.screen }

      // custom/scratchpad -- the gold 󰝖 counter, gone when nothing is stashed.
      Scratchpad { id: scratchpadWidget }

      // custom/windows -- the live title list for the visible workspace.
      Windows {
        id: windowsWidget
        barScreen: bar.screen
        // The title list may not run under the clock. Its budget is everything
        // from the island's leading edge to the centre island's, minus this
        // island's own padding, the two pills beside it, and one island-gap of
        // breathing room; titles that do not fit collapse into the "+N" chip
        // (see widgets/Windows.qml). centreIsland's x depends on the centre
        // island's own width and nothing else, so the binding cannot loop back
        // through this island.
        maxListWidth: Math.max(0,
            centerIsland.x - Style.bar.islandGap
            - (leftIsland.x + 2 * Style.bar.islandPaddingH)
            - workspacesWidget.implicitWidth
            - scratchpadWidget.implicitWidth)
      }
    }

    Island {
      id: centerIsland
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.bar.islandInset
      // An unread answer breathes around the whole pill -- the state has to
      // read from across the room, and a 10px orb cannot carry it alone.
      aura: OriClient.unread

      // CENTER SECTION -- waybar's "modules-center", in its order:
      //   clock, hyprland/language, custom/capslock, pulseaudio#mic,
      //   power-profiles-daemon, custom/tdp, custom/stay-awake, custom/gamepads.
      // Every one after the clock collapses to zero width in its idle state,
      // which is what waybar's `color: transparent` rules amount to.
      //
      // The orb's perch. Ori lives at the left end of this pill; it leaves
      // from here when you talk and comes back here when it is done. See
      // widgets/OrbDock.qml and assistant/OrbOverlay.qml.
      OrbDock { id: orbDock }

      // Clock: waybar's built-in `clock` module -- format "  {:%a %d %b %H:%M}",
      // format-alt "  {:%A, %B %d %Y}" on click.
      BarWidget {
        id: clockWidget
        property bool longFormat: false
        // The clock follows the theme (Theme.clock*): catppuccin plain text,
        // brutal an ink block, glass a frosted chip, tonal a green pill, paper
        // italic serif, neon glowing cyan, void plain.
        readonly property bool chip: Theme.clockBackground.a > 0
        backgroundColor: Theme.clockBackground
        radius: Theme.barRound ? height / 2
              : (Theme.v2 ? (Theme.chipRadius >= 0 ? Theme.chipRadius : Style.module.radius) : Style.module.radius)
        // A chip keeps clear of the island/bar edge by its own padding.
        horizontalPadding: chip && Theme.v2 ? 10 : Style.module.paddingH
        hoverHighlight: !Theme.brutal && !chip
        readonly property color ink: Theme.clockForeground
        readonly property string face: Theme.clockFont || Style.font.family
        // The glow is drawn outside the text; clipping is only there for the
        // collapse animation, which the clock never does.
        clip: !Theme.clockHasGlow
        tooltip: Qt.formatDateTime(clock.date, "dddd, d MMMM yyyy") + "\nright-click for the long format"
        // waybar's format-alt lived on the left click. It moved to the right
        // button so the left one can open the calendar -- the toggle is still
        // there, it just is not the first thing the clock does any more.
        onClicked: calendarPopup.toggle()
        onRightClicked: longFormat = !longFormat

        // The v2 clocks are text only (the prototype has no glyph; paper's
        // serif has none either).
        Text {
          visible: !Theme.v2
          text: ""
          color: clockWidget.ink
          font.family: Style.font.family
          font.pixelSize: Style.font.size
          font.weight: Style.font.boldWeight
          renderType: Text.NativeRendering
        }

        Text {
          id: clockLabel
          text: Qt.formatDateTime(clock.date, clockWidget.longFormat ? "dddd, d MMMM yyyy" : "ddd dd MMM  HH:mm")
          color: clockWidget.ink
          font.family: clockWidget.face
          font.pixelSize: Theme.clockSize > 0 ? Theme.clockSize : Style.font.size
          font.weight: Theme.clockWeight > 0 ? Theme.clockWeight : Style.font.boldWeight
          font.italic: Theme.clockItalic
          font.letterSpacing: Theme.clockLetterSpacing
          renderType: Text.NativeRendering

          // neon: the cyan glow around the digits.
          layer.enabled: Theme.clockHasGlow
          layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Theme.clockGlow
            shadowBlur: 0.6
            shadowHorizontalOffset: 0
            shadowVerticalOffset: 0
            blurMax: 12
          }

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

      // Vitals -- per-thread CPU bars + CPU temp; hover for GPU and memory.
      // Fixed width, so it never shoves this island around.
      Vitals { }

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
      // Room for its shadow inside the surface (0 in catppuccin).
      anchors.rightMargin: Theme.shadowX + Theme.barEdgePadding
      anchors.top: parent.top
      anchors.topMargin: Style.bar.islandInset

      // RIGHT SECTION -- tray, bluetooth, network, audio, battery.
      // Order is waybar's "modules-right", left to right.
      Tray { }
      Bluetooth { }
      Network { }
      Audio { }
      Battery { }
    }
    }

    // Ori's old cell (the bolt and its readout in the gap) is retired: the orb
    // on the centre pill is the assistant's presence now. OriCell/OriVeil
    // stay on disk, unreferenced.
  }

  // Render this bar to a PNG (its own pixels, no wallpaper and no compositor
  // blur) -- for checking a theme while a fullscreen window hides the bar:
  //   qs -p ~/.config/quickshell ipc call bar-eDP-1 snapshot /tmp/bar.png
  IpcHandler {
    target: "bar-" + (bar.screen ? bar.screen.name : "none")
    function snapshot(path: string): string {
      content.grabToImage(function (r) { r.saveToFile(path) })
      return "saving " + path
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
    cardTop: Style.bar.marginTop + Style.bar.height + Theme.shadowY + 4
  }

  // Calendar reminders run whether or not the popover is ever opened, so the
  // singleton has to be CONSTRUCTED at shell start -- Quickshell builds a
  // singleton on first use, and nothing else would touch this one until a
  // click. One instance regardless of how many monitors instantiate this bar.
  //
  // The touch is an ASSIGNMENT, not a `readonly property x: Singleton.y`
  // binding: an unread binding is evaluated lazily, so the singleton came up
  // on some reloads and not others, and reminders silently did not run.
  property bool remindersLive: false
  Component.onCompleted: {
    bar.remindersLive = CalendarReminders.stateLoaded
    bar.publishDock()
  }

  // ------------------------------------------------------------- orb dock
  // Where the docked orb sits on THIS screen, in the screen's logical px, so
  // the overlay can fly the orb out of the pill and back into it. A live
  // binding, not a mapToItem: the centre island moves when its contents do.
  readonly property real orbDockX: Style.bar.marginSide + centerIsland.x + centerIsland.rowX
    + orbDock.x + orbDock.width / 2
  readonly property real orbDockY: Style.bar.marginTop + Style.bar.height / 2
  onOrbDockXChanged: publishDock()
  // The bar's height is theme-dependent, so a live switch moves the dock point.
  onOrbDockYChanged: publishDock()
  function publishDock() {
    if (bar.screen) OriClient.setOrbDock(bar.screen.name, bar.orbDockX, bar.orbDockY)
  }

  // --------------------------------------------------------------- island
  // One rounded group of modules. Sizes itself to its content and animates
  // every width change, so a module appearing or collapsing slides the rest of
  // the group instead of teleporting it.
  component Island: Rectangle {
    id: island
    default property alias content: islandRow.data

    // Brutal: the hard offset shadow, as a child drawn outside the island
    // and below it (z -1 puts it under the island's own fill).
    Rectangle {
      z: -1
      x: Theme.shadowX
      y: Theme.shadowY
      width: island.width
      height: island.height
      radius: island.radius
      color: Theme.shadowColor
      visible: Theme.hasShadow
      antialiasing: false
    }

    // islands mode (tonal): each pill floats on its own soft shadow. A child
    // at z -1 draws under the island's fill; its geometry is the island's own.
    SoftShadow {
      z: -1
      target: island
      shown: island.painted
      x: 0
      y: 0
      opacity: 1
    }

    // The unread aura: a sky ring breathing just outside the pill while an
    // answer sits unread. Only the centre island sets it (OriClient.unread).
    // It runs one opacity animation while unread -- unread is temporary by
    // construction (cleared the moment the panel opens) -- and paints nothing
    // at all otherwise, so the bar keeps its no-idle-cost rule.
    property bool aura: false

    Rectangle {
      anchors { fill: parent; margins: -4 }
      radius: island.radius + 4
      color: "transparent"
      border.color: Theme.sky
      border.width: 1.5
      visible: island.aura
      opacity: 0
      SequentialAnimation on opacity {
        running: island.aura
        loops: Animation.Infinite
        NumberAnimation { to: 0.8; duration: 900; easing.type: Easing.OutQuad }
        NumberAnimation { to: 0.25; duration: 2100; easing.type: Easing.InQuad }
      }
    }

    readonly property bool empty: islandRow.implicitWidth <= 0
    // The row's offset inside the island (it is centred), for anyone who
    // needs a member's position on the screen.
    readonly property real rowX: islandRow.x

    // Only islands mode paints the island itself; strip/flat paint one bar
    // behind all three, bare paints nothing.
    readonly property bool painted: Theme.barMode === "islands"

    implicitWidth: islandRow.implicitWidth + 2 * Style.bar.islandPaddingH
    height: Style.bar.islandHeight
    radius: Style.bar.islandRadius
    color: painted ? Theme.barBackground : Theme.transparent
    border.width: painted && Theme.brutal ? Theme.borderWidth : 0
    border.color: Theme.borderColor
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
    // Transparent room on every side for a soft shadow/glow (0 in catppuccin).
    readonly property int pad: Theme.shadowPad
    implicitWidth: Math.ceil(bubble.implicitWidth) + Theme.shadowX + 2 * pad
    implicitHeight: Math.ceil(bubble.implicitHeight) + Theme.shadowY + 2 * pad

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
        tooltipAnchor.rect.x = Math.round(target.width / 2 - (tooltipWindow.implicitWidth - Theme.shadowX) / 2)
        tooltipAnchor.rect.y = Math.round(target.height + 8 - tooltipWindow.pad)
      }
    }

    HardShadow { target: bubble }
    SoftShadow { target: bubble }

    Rectangle {
      id: bubble
      // tooltip { background: @base; border: 1px solid @surface0; border-radius: 8px }
      implicitWidth: tooltipLabel.implicitWidth + 20
      implicitHeight: tooltipLabel.implicitHeight + 14
      color: Theme.tooltipBackground
      border.width: Theme.tooltipBorderWidth
      border.color: Theme.tooltipBorder
      radius: Theme.chipRadius >= 0 ? Theme.chipRadius : Style.module.radius
      x: tooltipWindow.pad

      // waybar's tooltip pops; this one fades up.
      opacity: bar.tooltipOpen ? 1 : 0
      y: tooltipWindow.pad + (bar.tooltipOpen ? 0 : -4)
      Behavior on opacity { NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth } }
      Behavior on y { NumberAnimation { duration: Style.anim.normal; easing.type: Style.anim.easing } }

      Text {
        id: tooltipLabel
        anchors.centerIn: parent
        text: bar.tooltipText
        textFormat: bar.tooltipRich ? Text.RichText : Text.PlainText
        color: Theme.tooltipText
        font.family: Theme.v2 ? Style.font.ui : Style.font.family
        font.pixelSize: Style.font.tooltip
        horizontalAlignment: Text.AlignHCenter
        renderType: Text.NativeRendering
      }
    }
  }
}
