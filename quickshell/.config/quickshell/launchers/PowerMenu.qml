import QtQuick
import Quickshell
import Quickshell.Io
// Theme/Style are singletons in the config root; a subdirectory does not get
// the root's implicit import, so pull it in explicitly.
import ".."

// Replaces SUPER + Escape's `pkill -x rofi || ~/.local/bin/powermenu`.
//
// The entries, glyphs and commands are lifted from that script verbatim:
//
//   󰌾  Lock      hyprlock
//   󰗼  Logout    hyprctl dispatch 'hl.dsp.exit()'
//   󰤄  Sleep     systemctl suspend
//   󰜉  Reboot    systemctl reboot
//   󰐥  Shutdown  systemctl poweroff
//
// Note the Logout dispatch: Hyprland 0.56+ parses `hyprctl dispatch`'s
// argument as Lua, so it is `hl.dsp.exit()`, not `exit`.
//
//   powermenu.rasi  window 200px, 2px @mauve border, radius 16, centred
//                   inputbar: prompt only, centred @mauve bold -- no entry
//                   listview lines 5; element padding 10px 14px, radius 10
//                   element selected.normal: @surface1 bg, @mauve text+border
//
// IPC:  qs ipc call power toggle | open | close
Scope {
  id: root

  property var group: null

  readonly property var actions: [
    { icon: "󰌾", label: "Lock",     command: ["hyprlock"] },
    { icon: "󰗼", label: "Logout",   command: ["hyprctl", "dispatch", "hl.dsp.exit()"] },
    { icon: "󰤄", label: "Sleep",    command: ["systemctl", "suspend"] },
    { icon: "󰜉", label: "Reboot",   command: ["systemctl", "reboot"] },
    { icon: "󰐥", label: "Shutdown", command: ["systemctl", "poweroff"] }
  ]

  property var pending: null

  function trigger(index) {
    var a = root.actions[index === undefined ? list.currentIndex : index]
    if (!a) return
    root.pending = a.command
    panel.dismiss()
    // Let the overlay finish closing first: hyprlock wants the layer-shell
    // surface gone before it takes the session, and a suspend that starts
    // mid-animation leaves the dimmed backdrop on screen.
    runAfterClose.start()
  }

  Timer {
    id: runAfterClose
    interval: Style.anim.reveal
    onTriggered: {
      if (root.pending) Quickshell.execDetached(root.pending)
      root.pending = null
    }
  }

  // ---------------------------------------------------------------- panel
  LauncherPanel {
    id: panel

    prompt: "󰐥 Power"
    // powermenu.rasi draws the prompt as centred bare text, not a pill, and
    // disables the entry entirely.
    promptPill: false
    searchEnabled: false
    accent: Theme.accent           // powermenu.rasi: border-color @mauve
    panelWidth: 200
    cornerRadius: 16
    list: list

    onPresented: if (root.group) root.group.claim(panel)
    onDismissed: if (root.group) root.group.release(panel)
    onAccepted: root.trigger()

    LauncherList {
      id: list
      width: parent.width
      accent: panel.accent
      // element { padding: 10px 14px } around a 12px label.
      rowHeight: 40
      rows: 5
      model: root.actions

      delegate: Item {
        id: powerRow
        required property var modelData
        required property int index

        width: ListView.view.width
        height: list.rowHeight

        readonly property bool current: powerRow.ListView.isCurrentItem

        Row {
          anchors.fill: parent
          anchors.leftMargin: 14
          anchors.rightMargin: 14
          spacing: 10

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: powerRow.modelData.icon
            // element selected.normal { text-color: @mauve }
            color: powerRow.current ? list.accent : Theme.text
            font.family: Style.font.family
            font.pixelSize: Style.font.size
            renderType: Text.NativeRendering

            Behavior on color {
              ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: powerRow.modelData.label
            color: powerRow.current ? list.accent : Theme.text
            font.family: Style.font.family
            font.pixelSize: Style.font.small
            font.weight: powerRow.current ? Style.font.boldWeight : Style.font.normalWeight
            renderType: Text.NativeRendering

            Behavior on color {
              ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: if (panel.hoverArmed) list.currentIndex = powerRow.index
          onPositionChanged: panel.hoverMoved(mapToItem(null, mouse.x, mouse.y))
          onClicked: root.trigger(powerRow.index)
        }
      }
    }
  }

  // ------------------------------------------------------------------ ipc
  IpcHandler {
    target: "power"

    function toggle(): string {
      panel.toggle()
      return panel.opened ? "opened" : "closed"
    }

    function open(): string {
      panel.present()
      return "opened"
    }

    function close(): string {
      panel.dismiss()
      return "closed"
    }
  }
}
