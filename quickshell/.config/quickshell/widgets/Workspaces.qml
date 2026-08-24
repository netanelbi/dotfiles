import QtQuick
import Quickshell.Hyprland
import "root:/"

// Replaces waybar's `hyprland/workspaces`.
//
// config.jsonc:  { "on-click": "activate", "format": "{name}" }
//   -- `format-icons` is set but never reached: waybar only consults it when
//      `format` contains {icon}, and this one is "{name}", so the label is
//      always the workspace name. Reproduced literally below.
//   -- neither `all-outputs` nor `show-special` is set, so waybar defaults to
//      "non-special workspaces on THIS bar's monitor". Same filter here.
//   -- no on-scroll keys, so scrolling does nothing. Deliberately not "improved".
//
// style.css:
//   #workspaces               { background: transparent; padding: 0 }
//   #workspaces button        { color: @overlay0; background: transparent;
//                               padding: 4px 8px; margin: 0 2px; border-radius: 8px }
//   #workspaces button:hover  { color: @lavender; background: alpha(@surface1, 0.5) }
//   #workspaces button.active { color: @mauve; font-weight: bold;
//                               border: 2px solid @mauve; background: transparent }
//   #workspaces button.urgent { color: @base; background: @red }
//
// MOTION: deliberately restrained. Hyprland destroys a workspace the moment it
// empties, so this row gains and loses pills during ordinary switching -- any
// motion here fires constantly, not rarely. So nothing slides or pops: the 2px
// mauve outline simply cross-fades in on the active pill, and the label colour
// cross-fades with it. waybar snaps both; the fade is the whole difference.
BarWidget {
  id: root

  // Each pill owns its own MouseArea, so the base widget's full-cover
  // MouseArea must stand down or it would swallow every press.
  interactive: false
  hoverHighlight: false
  // `#workspaces { padding: 0 }` -- the island's own 12px is the only padding.
  horizontalPadding: 0
  // `margin: 0 2px` on each button: 4px between pills, 2px at each end.
  sideMargin: Style.module.workspaceSpacing / 2

  // A workspace button is taller than the default indicator slot -- it carries
  // 4px of padding plus a 2px outline, and in waybar it very nearly fills the
  // island.
  readonly property int pillHeight: Style.bar.islandHeight - 4
  implicitHeight: pillHeight

  // ------------------------------------------------------------ hyprland
  // The monitor this bar is on, so we show the same workspaces waybar does.
  // Null until the window exists (and on a non-Hyprland compositor), in which
  // case we fall back to showing every workspace rather than showing none.
  readonly property var barMonitor: {
    var w = root.QsWindow ? root.QsWindow.window : null
    return w && w.screen ? Hyprland.monitorFor(w.screen) : null
  }

  function onThisMonitor(ws) {
    if (!root.barMonitor) return true
    return ws.monitor === null || ws.monitor === undefined || ws.monitor === root.barMonitor
  }

  // waybar lists the workspaces that exist, plus the focused one; it does not
  // pad out to a fixed 1..N. Special workspaces (negative ids) are excluded,
  // matching `show-special: false`.
  // Hyprland gives NAMED workspaces negative ids, the same sign it uses for
  // special/scratchpad ones. Filtering on `id > 0` dropped the scratchpad as
  // intended but silently threw out every named workspace with it, so a
  // workspace like `stream` showed in waybar and not here. Filter on the
  // `special:` name prefix instead -- that is what actually identifies a
  // scratchpad (the Scratchpad widget owns those).
  function isSpecial(ws) {
    return ws === null || String(ws.name).indexOf("special:") === 0
  }

  function workspaceIds() {
    var ids = []
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      if (!isSpecial(ws) && onThisMonitor(ws) && ids.indexOf(ws.id) === -1) ids.push(ws.id)
    }

    var focused = Hyprland.focusedWorkspace
    if (!isSpecial(focused) && ids.indexOf(focused.id) === -1) ids.push(focused.id)

    // Numbered workspaces ascending, then named ones -- waybar's order.
    ids.sort(function (a, b) {
      if (a > 0 && b > 0) return a - b
      if (a > 0) return -1
      if (b > 0) return 1
      return b - a
    })
    return ids
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  // waybar's `on-click: activate`. Quickshell's activate() emits
  // `hl.dsp.focus({ workspace = "N" })`, which is the only form Hyprland 0.56+
  // accepts -- it parses the dispatch argument as Lua.
  function activate(id) {
    var ws = workspaceById(id)
    if (ws !== null) ws.activate()
    else Hyprland.dispatch("hl.dsp.focus({ workspace = \"" + id + "\" })")
  }

  // Positioners skip children that are not visible, and the left island paints
  // nothing while it is empty (`visible: opacity > 0.01`, Bar.qml) -- which is
  // its state for the first second or so, until Hyprland's IPC model populates
  // and the pills appear. Re-running both positioners on every pill change is
  // what stops the row from getting stuck at one pill's width.
  function relayout() {
    pills.forceLayout()
    if (container.parent && container.parent.forceLayout) container.parent.forceLayout()
  }

  function scheduleRelayout() { Qt.callLater(root.relayout) }

  Item {
    id: container
    implicitWidth: pills.implicitWidth
    implicitHeight: root.pillHeight

    Row {
      id: pills
      spacing: Style.module.workspaceSpacing

      // Hyprland DESTROYS a workspace the moment it empties, so this Row gains
      // and loses children constantly during ordinary switching -- not just on
      // rare events. A scale-from-0.5 pop with overshoot plus a 240ms neighbour
      // slide turned every switch into the group visibly filling and emptying.
      // A plain quick fade reads as "it appeared" without the theatre; the
      // active pill's outline cross-fade is the only motion this widget has.
      add: Transition {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
      }
      move: Transition {
        NumberAnimation { properties: "x,y"; duration: Style.anim.quick; easing.type: Style.anim.easing }
      }

      Repeater {
        id: repeater
        model: root.workspaceIds()

        onItemAdded: root.scheduleRelayout()
        onItemRemoved: root.scheduleRelayout()

        delegate: Rectangle {
          id: pill
          required property int modelData

          readonly property var workspace: root.workspaceById(modelData)
          // waybar's `.active` is "the workspace this OUTPUT is showing", not
          // "the globally focused workspace" -- with two monitors both bars
          // outline their own visible workspace. Quickshell's `active` carries
          // exactly that meaning (`focused` is the global one), so it is what
          // the outline follows. The focused-workspace fallback only covers the
          // frame before the IPC model has populated.
          readonly property bool isActive: workspace !== null
                                           ? workspace.active === true
                                           : (Hyprland.focusedWorkspace !== null
                                              && Hyprland.focusedWorkspace.id === modelData)
          readonly property bool isUrgent: workspace !== null && workspace.urgent === true
          readonly property bool isHovered: hover.containsMouse

          // `padding: 4px 8px`, with a floor so single digits stay square-ish.
          implicitWidth: Math.max(label.implicitWidth + 2 * Style.module.workspacePaddingH, root.pillHeight)
          width: implicitWidth
          height: root.pillHeight
          radius: Style.module.radius

          color: isUrgent ? Theme.urgent
                          : (isHovered ? Theme.hoverBackground : Theme.transparent)

          // Each pill owns its outline and simply CROSS-FADES it in and out,
          // which is waybar's own model (`#workspaces button.active` has the
          // border) with a fade where waybar snaps. The previous single
          // Rectangle that slid between pills read as too busy: on a switch it
          // travelled the whole row, and Hyprland destroying emptied
          // workspaces meant the row moved underneath it at the same time.
          border.width: Style.module.borderWidth
          border.color: (isActive && !isUrgent) ? Theme.accent : Theme.transparent

          Behavior on border.color {
            ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
          }

          scale: hover.pressed ? 0.9 : 1

          Behavior on color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }
          Behavior on scale { NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing } }
          // No Behavior on implicitWidth: a pill's width only changes when its
          // label does (1 -> 10), and animating it made the whole group breathe
          // sideways on every workspace switch. Width snaps; position glides.

          Text {
            id: label
            anchors.centerIn: parent
            // waybar's `format: "{name}"`.
            text: pill.workspace !== null ? pill.workspace.name : String(pill.modelData)
            color: pill.isUrgent ? Theme.base
                                 : (pill.isActive ? Theme.accent
                                                  : (pill.isHovered ? Theme.accentAlt : Theme.inactive))
            font.family: Style.font.family
            font.pixelSize: Style.font.size
            font.weight: pill.isActive ? Style.font.boldWeight : Style.font.normalWeight
            renderType: Text.NativeRendering

            Behavior on color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }
          }

          MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            cursorShape: Qt.PointingHandCursor
            onClicked: root.activate(pill.modelData)
          }
        }
      }
    }
  }
}
