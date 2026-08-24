import QtQuick
import Quickshell
import Quickshell.Io
// Theme/Style are singletons in the config root; a subdirectory does not get
// the root's implicit import, so pull it in explicitly.
import ".."

// Replaces the XF86Bluetooth (Fn + emoji key) picker, `rofi -modi emoji -show emoji`.
//
// rofi-emoji reads /usr/share/rofi-emoji/all_emojis.txt, one entry per line:
//
//   <emoji>\t<group>\t<subgroup>\t<name>\t<keyword | keyword | ...>
//
// so this reads the same file rather than embedding a copy. The plugin's
// action menu leads with "Copy emoji" and offers "Copy name"; Enter and Alt+P
// map onto those two.
//
// Styling follows catppuccin.rasi, which is what `rofi -show emoji` picks up
// from config.rasi's `@theme "catppuccin"`.
//
// The file is 5042 lines, so it is only read the first time the picker is
// opened -- the shell pays nothing for it at startup.
//
// IPC:  qs ipc call emoji toggle | open | close
Scope {
  id: root

  property var group: null

  readonly property string dataPath: "/usr/share/rofi-emoji/all_emojis.txt"

  property bool wanted: false
  property var entries: []
  property var results: []

  function parseFile(content) {
    var lines = String(content).split("\n")
    var out = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line === "") continue
      var f = line.split("\t")
      if (f.length < 4) continue
      out.push({
        emoji: f[0],
        group: f[1],
        subgroup: f[2],
        name: f[3],
        keywords: f.length > 4 ? f[4] : ""
      })
    }
    root.entries = out
    root.refilter()
  }

  function refilter() {
    var q = panel.query
    if (q === "") {
      root.results = root.entries.slice()
      list.moveTo(0)
      return
    }

    var scored = []
    for (var i = 0; i < root.entries.length; i++) {
      var e = root.entries[i]
      var s = panel.matchScore(e.name, q)
      s = Math.max(s, panel.matchScore(e.keywords, q) - 200)
      s = Math.max(s, panel.matchScore(e.subgroup, q) - 300)
      s = Math.max(s, panel.matchScore(e.group, q) - 340)
      if (s > 0) scored.push({ entry: e, score: s, order: i })
    }
    // Ties keep the file's order, which is the Unicode ordering rofi shows.
    scored.sort(function (a, b) { return b.score - a.score || a.order - b.order })

    var out = []
    for (var j = 0; j < scored.length; j++) out.push(scored[j].entry)
    root.results = out
    list.moveTo(0)
  }

  function copy(value) {
    if (!value) return
    panel.dismiss()
    // The same thing clipboard-adapter.sh does for `copy` on Wayland.
    Quickshell.execDetached(["sh", "-c", "printf %s \"$1\" | wl-copy", "sh", value])
  }

  function pick(index) {
    var e = root.results[index === undefined ? list.currentIndex : index]
    if (e) root.copy(e.emoji)
  }

  // rofi-emoji's "Copy name (<tt>{name}</tt>)" action.
  function copyName() {
    var e = root.results[list.currentIndex]
    if (e) root.copy(e.name)
  }

  FileView {
    id: emojiFile
    path: root.wanted ? root.dataPath : ""
    printErrors: true
    onLoaded: root.parseFile(text())
  }

  // ---------------------------------------------------------------- panel
  LauncherPanel {
    id: panel

    prompt: "Emoji"
    accent: Theme.accent           // catppuccin.rasi: border-color @mauve
    panelWidth: 500
    cornerRadius: 12
    placeholder: "Search emoji..."
    list: list

    onPresented: {
      root.wanted = true
      root.refilter()
      if (root.group) root.group.claim(panel)
    }
    onDismissed: if (root.group) root.group.release(panel)
    onAccepted: root.pick()
    onAltAccepted: root.copyName()
    onQueryChanged: root.refilter()

    LauncherList {
      id: list
      width: parent.width
      accent: panel.accent
      rowHeight: 44
      rows: 8
      model: root.results

      delegate: Item {
        id: emojiRow
        required property var modelData
        required property int index

        width: ListView.view.width
        height: list.rowHeight

        readonly property bool current: emojiRow.ListView.isCurrentItem

        Row {
          anchors.fill: parent
          anchors.leftMargin: 10
          anchors.rightMargin: 10
          spacing: 12

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: 34
            text: emojiRow.modelData.emoji
            horizontalAlignment: Text.AlignHCenter
            font.family: "Noto Color Emoji"
            font.pixelSize: Style.font.size + 8
            // The selected glyph grows a touch: the pointer for a list where
            // every row is one character wide.
            scale: emojiRow.current ? 1.15 : 1

            Behavior on scale {
              NumberAnimation { duration: Style.anim.normal; easing.type: Style.anim.easing }
            }
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 34 - parent.spacing
            spacing: 1

            Text {
              width: parent.width
              text: emojiRow.modelData.name
              elide: Text.ElideRight
              color: Theme.text
              font.family: Style.font.family
              font.pixelSize: Style.font.size
              font.weight: emojiRow.current ? Style.font.boldWeight : Style.font.normalWeight
              renderType: Text.NativeRendering
            }

            Text {
              width: parent.width
              visible: emojiRow.current
              text: emojiRow.modelData.subgroup.split("-").join(" ")
              elide: Text.ElideRight
              color: Theme.overlay0
              font.family: Style.font.family
              font.pixelSize: Style.font.small
              renderType: Text.NativeRendering
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: list.currentIndex = emojiRow.index
          onClicked: root.pick(emojiRow.index)
        }
      }
    }

    Item {
      width: parent.width
      height: visible ? 56 : 0
      visible: list.count === 0

      Text {
        anchors.centerIn: parent
        text: root.entries.length === 0 ? "Loading emoji…"
          : "No matches for “" + panel.query + "”"
        color: Theme.overlay0
        font.family: Style.font.family
        font.pixelSize: Style.font.size
        renderType: Text.NativeRendering
      }
    }
  }

  // ------------------------------------------------------------------ ipc
  IpcHandler {
    target: "emoji"

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
