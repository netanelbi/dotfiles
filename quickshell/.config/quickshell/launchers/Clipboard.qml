import QtQuick
import Quickshell
import Quickshell.Io
// Theme/Style are singletons in the config root; a subdirectory does not get
// the root's implicit import, so pull it in explicitly.
import ".."

// Replaces the SUPER + V clipboard history:
//
//   selection=$(rofi -dmenu -p "Clipboard" -show-icons < <(~/.local/bin/cliphist-rofi-img))
//   ret=$?
//   [[ $ret -eq 10 ]] && ~/.local/bin/cliphist-preview "$selection"       # Alt+P
//   [[ $ret -eq 0  ]] && echo "$selection" | ~/.local/bin/cliphist-rofi-img
//
// Both scripts are reused as-is. `cliphist-rofi-img` with no argument prints
// the rofi dmenu list (and re-extracts image entries into /tmp/cliphist as a
// side effect); with an argument it decodes that entry back to the clipboard.
// `cliphist-preview` opens an image entry in imv. Nothing here reimplements
// cliphist, so /tmp/cliphist/map stays the single lookup table.
//
// The one upgrade over the rofi version: an image entry renders its real
// thumbnail in the row rather than a generic icon slot, and Alt+P still hands
// it to imv for the full-size look.
//
// IPC:  qs ipc call clipboard toggle | open | close
Scope {
  id: root

  property var group: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string listScript: home + "/.local/bin/cliphist-rofi-img"
  readonly property string previewScript: home + "/.local/bin/cliphist-preview"

  // { display, image } -- `display` is the exact string the scripts expect
  // back, i.e. the raw preview line, or "[image:ID]" for a binary entry.
  property var entries: []
  property var results: []
  property bool loading: false

  // The row the preview pane follows. Bound to the list's cursor, so arrowing
  // through updates the preview -- which is the whole point of the split view:
  // rofi could only ever shell out to imv on Alt+P.
  readonly property var current: (list.currentIndex >= 0 && list.currentIndex < results.length)
                                 ? results[list.currentIndex] : null

  function reload() {
    root.entries = []
    root.results = []
    root.loading = true
    collected = []
    lister.running = false
    lister.running = true
  }

  property var collected: []

  function ingest(line) {
    var raw = String(line)
    if (raw === "") return

    // cliphist-rofi-img emits rofi's icon syntax for images:
    //   [image:123]<NUL>icon<US>/tmp/cliphist/123.png
    // (0x00 and 0x1f both survive the pipe into QString intact -- verified).
    var split = raw.indexOf("\u0000icon\u001f")
    if (split !== -1) {
      collected.push({
        display: raw.substring(0, split),
        image: raw.substring(split + 6)
      })
    } else {
      collected.push({ display: raw, image: "" })
    }
  }

  function finish() {
    root.entries = collected
    root.loading = false
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
      var s = panel.matchScore(root.entries[i].display, q)
      if (s > 0) scored.push({ entry: root.entries[i], score: s, order: i })
    }
    // Ties keep cliphist's recency order -- the newest entry stays on top.
    scored.sort(function (a, b) { return b.score - a.score || a.order - b.order })

    var out = []
    for (var j = 0; j < scored.length; j++) out.push(scored[j].entry)
    root.results = out
    list.moveTo(0)
  }

  function pick(index) {
    var e = root.results[index === undefined ? list.currentIndex : index]
    if (!e) return
    panel.dismiss()
    Quickshell.execDetached([root.listScript, e.display])
  }

  // rofi's kb-custom-1 (Alt+P) -> exit code 10 -> cliphist-preview.
  function preview() {
    var e = root.results[list.currentIndex]
    if (!e || e.image === "") return
    panel.dismiss()
    Quickshell.execDetached([root.previewScript, e.display])
  }

  Process {
    id: lister
    // The script does `[[ ! -t 0 ]] && read -r selected`, so it hangs forever
    // on an inherited pipe. Hyprland runs it with stdin on /dev/null (instant
    // EOF -> list mode); reproduce that exactly.
    command: ["sh", "-c", "exec \"$1\" < /dev/null", "sh", root.listScript]
    stdout: SplitParser { onRead: function (line) { root.ingest(line) } }
    onExited: root.finish()
  }

  // ---------------------------------------------------------------- panel
  LauncherPanel {
    id: panel

    prompt: "Clipboard"
    accent: Theme.accent           // catppuccin.rasi: border-color @mauve
    panelWidth: 900
    cornerRadius: 12
    placeholder: "Search clipboard..."
    list: list

    onPresented: {
      root.reload()
      if (root.group) root.group.claim(panel)
    }
    onDismissed: if (root.group) root.group.release(panel)
    onAccepted: root.pick()
    onAltAccepted: root.preview()
    onQueryChanged: root.refilter()

    Row {
      width: parent.width

    LauncherList {
      id: list
      width: 470
      accent: panel.accent
      rowHeight: 56
      rows: 8
      model: root.results

      delegate: Item {
        id: clipRow
        required property var modelData
        required property int index

        width: ListView.view.width
        height: list.rowHeight

        readonly property bool current: clipRow.ListView.isCurrentItem
        readonly property bool isImage: clipRow.modelData.image !== ""

        Row {
          anchors.fill: parent
          anchors.leftMargin: 10
          anchors.rightMargin: 10
          spacing: 10

          Item {
            width: 48
            height: 48
            anchors.verticalCenter: parent.verticalCenter

            // Image entry: the real thumbnail, rounded like rofi's element-icon.
            Rectangle {
              anchors.fill: parent
              visible: clipRow.isImage
              radius: 6
              color: Theme.surface0
              clip: true

              Image {
                anchors.fill: parent
                anchors.margins: 2
                source: clipRow.isImage ? "file://" + clipRow.modelData.image : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                sourceSize.width: 96
                sourceSize.height: 96
                opacity: status === Image.Ready ? 1 : 0

                Behavior on opacity {
                  NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
                }
              }
            }

            // Text entry: a quiet glyph so the rows stay aligned.
            Text {
              anchors.centerIn: parent
              visible: !clipRow.isImage
              text: "󰅍"
              color: clipRow.current ? list.accent : Theme.overlay0
              font.family: Style.font.family
              font.pixelSize: Style.font.size + 8
              renderType: Text.NativeRendering

              Behavior on color {
                ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
              }
            }
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 48 - parent.spacing
            spacing: 1

            Text {
              width: parent.width
              text: clipRow.modelData.display
              elide: Text.ElideRight
              color: Theme.text
              font.family: Style.font.family
              font.pixelSize: Style.font.size
              font.weight: clipRow.current ? Style.font.boldWeight : Style.font.normalWeight
              renderType: Text.NativeRendering
            }

            Text {
              width: parent.width
              visible: clipRow.isImage && clipRow.current
              text: "Alt+P to open in imv"
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
          onEntered: if (panel.hoverArmed) list.currentIndex = clipRow.index
          onPositionChanged: panel.hoverMoved(mapToItem(null, mouse.x, mouse.y))
          onClicked: root.pick(clipRow.index)
        }
      }
    }

    Item {
      width: parent.width
      height: visible ? 56 : 0
      visible: list.count === 0

      Text {
        anchors.centerIn: parent
        text: root.loading ? "Reading clipboard history…"
          : panel.query === "" ? "Clipboard history is empty"
          : "No matches for “" + panel.query + "”"
        color: Theme.overlay0
        font.family: Style.font.family
        font.pixelSize: Style.font.size
        renderType: Text.NativeRendering
      }
    }

    // ------------------------------------------------------- preview pane
    // Follows the list cursor rather than needing a keypress. An image entry
    // shows the real file at size; a text entry shows the whole thing, which
    // the 1-line list row can only elide.
    Item {
      width: parent.width - list.width
      height: list.height

      Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        color: Theme.mantle
        radius: 8

        // Vertical hairline separating the two panes.
        Rectangle {
          width: 1; height: parent.height
          color: Theme.surface0
        }

        // --- image entry ---
        Image {
          anchors.fill: parent
          anchors.margins: 18
          visible: root.current !== null && root.current.image !== ""
          source: (root.current && root.current.image !== "") ? "file://" + root.current.image : ""
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
          // Cap the decode: some clipboard images are screenshots of a 4K
          // display and decoding them at full size stalls the whole panel.
          sourceSize.width: 900
          opacity: status === Image.Ready ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: Style.anim.opacityDuration } }
        }

        // --- text entry ---
        Flickable {
          anchors.fill: parent
          anchors.margins: 18
          visible: root.current !== null && root.current.image === ""
          contentHeight: fullText.implicitHeight
          clip: true
          interactive: contentHeight > height

          Text {
            id: fullText
            width: parent.width
            text: root.current ? root.current.display : ""
            wrapMode: Text.Wrap
            color: Theme.text
            font.family: Style.font.family
            font.pixelSize: Style.font.size
            renderType: Text.NativeRendering
          }
        }

        // --- nothing selected ---
        Text {
          anchors.centerIn: parent
          visible: root.current === null
          text: root.loading ? "…" : "nothing selected"
          color: Theme.overlay0
          font.family: Style.font.family
          font.pixelSize: Style.font.size
          renderType: Text.NativeRendering
        }
      }
    }
    }
  }

  // ------------------------------------------------------------------ ipc
  IpcHandler {
    target: "clipboard"

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
