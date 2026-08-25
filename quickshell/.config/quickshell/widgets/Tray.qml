import QtQuick
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.SystemTray
import "root:/"

// System tray (StatusNotifierItem host).
//
// waybar parity -----------------------------------------------------------
//   config.jsonc  "tray": { "icon-size": 16, "spacing": 10 }
//   style.css     #tray { color: @text; padding: 0 10px }
//                 #tray { padding-right: 6px }
//                 #tray > .passive         { -gtk-icon-effect: dim }
//                 #tray > .needs-attention { -gtk-icon-effect: highlight }
//   behaviour     left click  -> Activate
//                 right click -> the item's dbusmenu
//                 middle click-> SecondaryActivate
//                 wheel       -> Scroll (vertical)
//   These are waybar's tray defaults, not config keys: the module has no
//   on-click entries in config.jsonc.
//
// Motion ------------------------------------------------------------------
// waybar pops an icon into the row the instant an app registers, and dims a
// passive icon with a static GTK effect. Here an icon slides open from zero
// width (BarWidget's own reveal), passive/active cross-fades, and a
// needs-attention item breathes until it is dealt with.
BarWidget {
  id: root

  // This widget is a CONTAINER: every icon owns its own clicks. BarWidget's
  // MouseArea is declared after the content Row, so it sits above the icons --
  // leaving it enabled would swallow every press. `interactive: false` also
  // turns off the container-wide hover tint, which is what we want: the tint
  // belongs to the individual icon under the cursor.
  interactive: false

  // #tray padding is 0 10px; 6 here + 4 on each end icon lands on waybar's 10.
  // waybar's tray geometry is exactly: 16px icons, 10px BETWEEN them, and
  // 6px on the right only ("icon-size": 16, "spacing": 10, padding-right: 6).
  // Giving each entry its own 4px side padding instead made every icon 24px
  // wide and added 8px of edge padding the GTK bar does not have -- 114px
  // against waybar's 100. The gap lives in the Row's spacing now, and the
  // entries carry none, so the icons sit at waybar's pitch.
  horizontalPadding: 3
  // waybar's tray pitch is 10; 12 is a deliberate 2px more, by eye -- the
  // icons here are busier than waybar's and read as crowded at parity.
  spacing: 12

  // waybar draws nothing at all when no app has registered.
  shown: SystemTray.items.values.length > 0

  // SystemTrayItem.display() is the legacy path: it accepts the call and
  // returns cleanly (verified with a synthetic right-click -- hasMenu=true, a
  // valid PanelWindow, "display() returned") but never renders a menu from a
  // layer-shell surface. QsMenuAnchor is the API that actually shows it.
  //
  // ONE anchor for the whole tray, not one per Repeater delegate. A Wayland
  // popup holds an input grab, so with four anchors the first right-click on
  // icon B was swallowed dismissing icon A's menu and only the second opened
  // B -- which is what "slow" felt like. Sharing one anchor means switching
  // icons is a retarget, not a grab fight.
  QsMenuAnchor {
    id: trayMenu
    anchor.edges: Edges.Bottom
    anchor.gravity: Edges.Bottom
  }

  property var pendingItem: null
  property var pendingAnchor: null

  function showMenu(item, anchorItem) {
    if (trayMenu.visible) {
      // Same icon twice = toggle shut.
      if (trayMenu.menu === item.menu) { trayMenu.close(); return }
      root.pendingItem = item
      root.pendingAnchor = anchorItem
      trayMenu.close()
      return
    }
    trayMenu.menu = item.menu
    trayMenu.anchor.item = anchorItem
    trayMenu.open()
  }

  Connections {
    target: trayMenu
    // Re-open on the next icon only once the previous popup has released its
    // grab; opening inside close() races the compositor.
    function onClosed() {
      if (!root.pendingItem) return
      var item = root.pendingItem
      var a = root.pendingAnchor
      root.pendingItem = null
      root.pendingAnchor = null
      trayMenu.menu = item.menu
      trayMenu.anchor.item = a
      trayMenu.open()
    }
  }

  Repeater {
    model: SystemTray.items

    BarWidget {
      id: entry
      required property SystemTrayItem modelData

      readonly property bool passive: modelData.status === Status.Passive
      readonly property bool needsAttention: modelData.status === Status.NeedsAttention

      horizontalPadding: 0

      // Reveal: start collapsed, then let BarWidget's width/opacity Behaviors
      // slide the icon in. An icon leaving is destroyed by the Repeater, so it
      // cannot animate out -- that is a Repeater limitation, not a choice.
      shown: false
      Component.onCompleted: entry.shown = true

      tooltip: {
        var title = modelData.tooltipTitle !== "" ? modelData.tooltipTitle
                  : (modelData.title !== "" ? modelData.title : modelData.id)
        var desc = modelData.tooltipDescription
        return desc !== "" ? title + "\n" + desc : title
      }

      // Left click activates unless the item only offers a menu (onlyMenu),
      // in which case waybar opens the menu with either button.
      onClicked: {
        if (modelData.onlyMenu) entry.openMenu()
        else modelData.activate()
      }
      onRightClicked: entry.openMenu()
      onMiddleClicked: modelData.secondaryActivate()
      onScrolledUp: modelData.scroll(120, false)
      onScrolledDown: modelData.scroll(-120, false)

      function openMenu() {
        if (!modelData.hasMenu) return
        root.showMenu(entry.modelData, entry)
      }

      IconImage {
        id: icon
        source: entry.modelData.icon
        implicitSize: 16          // config.jsonc "icon-size": 16
        asynchronous: true

        // `-gtk-icon-effect: dim` on a passive item, cross-faded instead of
        // switched. NeedsAttention gets the "highlight" half of the same pair.
        opacity: entry.passive ? 0.55 : 1
        Behavior on opacity {
          NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
        }

        // A hovered icon lifts slightly; a needs-attention icon breathes.
        scale: entry.hovered ? 1.12 : 1
        Behavior on scale {
          NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing }
        }

        // `-gtk-icon-effect: highlight`: a soft halo behind the icon that
        // breathes while the item wants attention. A child of the icon (z -1
        // puts it behind the Image), so it never displaces the content Row.
        Rectangle {
          id: attention
          anchors.centerIn: parent
          // Kept inside the 18px content slot: BarWidget clips, so a bigger
          // halo would be sliced into a band instead of reading as a glow.
          width: parent.width + 6
          height: Style.bar.slotHeight
          radius: Style.module.radius
          z: -1
          color: Theme.alpha(Theme.attention, 0.5)
          opacity: 0
          visible: opacity > 0.01
        }

        SequentialAnimation {
          running: entry.needsAttention
          loops: Animation.Infinite
          alwaysRunToEnd: true
          onStopped: attention.opacity = 0
          NumberAnimation { target: attention; property: "opacity"; to: 0.55; duration: 600; easing.type: Easing.InOutSine }
          NumberAnimation { target: attention; property: "opacity"; to: 0; duration: 600; easing.type: Easing.InOutSine }
        }
      }
    }
  }
}
