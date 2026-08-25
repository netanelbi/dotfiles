import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
// Theme/Style are singletons in the config root; a subdirectory does not get
// the root's implicit import, so pull it in explicitly.
import ".."

// Replaces `rofi -show drun` (SUPER + D).
//
//   config.rasi   modi drun, show-icons true, drun-display-format "{name}",
//                 display-drun "Apps"
//   catppuccin.rasi  window 500px, 2px @mauve border, radius 12;
//                    listview lines 8; element-icon size 48px
//
// The app list comes from Quickshell's DesktopEntries (the same
// $XDG_DATA_DIRS/applications scan rofi does), and launching goes through
// DesktopEntry.execute(), which honours Exec field codes, Terminal=true and
// Path= exactly like rofi's drun mode.
//
// IPC:  qs ipc call apps toggle | open | close
Scope {
  id: root

  // Set by Launchers.qml so opening one overlay closes any other.
  property var group: null

  property var allEntries: []
  property var results: []

  // ------------------------------------------------------------- usage
  // rofi's drun sorts by how often you actually launch things, not by name --
  // which is why zen and zapzap were at the top there and "About Xfce" was
  // not. That history is a plain file it has been keeping for months:
  //
  //   ~/.cache/rofi3.druncache      "<count> <desktop-id>.desktop" per line
  //
  // Read it rather than starting a fresh count from zero, and write back to
  // the SAME file on launch, so rofi and this launcher keep one shared history
  // and either can be used without losing the ordering.
  readonly property string druncachePath: Quickshell.env("HOME") + "/.cache/rofi3.druncache"
  property var usage: ({})

  FileView {
    path: root.druncachePath
    watchChanges: true
    onLoaded: root.ingestUsage(this.text())
    onFileChanged: this.reload()
  }

  function ingestUsage(txt) {
    var map = {}
    var lines = String(txt).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = /^\s*(\d+)\s+(.+?)\s*$/.exec(lines[i])
      if (m) map[m[2]] = parseInt(m[1], 10)
    }
    root.usage = map
    root.rebuild()
  }

  function usageOf(entry) {
    if (!entry) return 0
    var n = root.usage[entry.id + ".desktop"]
    return n === undefined ? 0 : n
  }

  function bumpUsage(entry) {
    if (!entry) return
    // Increment in the file itself, so rofi sees it too. Written via awk to
    // keep it a single atomic-ish rewrite rather than a read/modify/write from
    // QML that could race the FileView reload.
    bumper.command = ["sh", "-lc",
      "f=\"$HOME/.cache/rofi3.druncache\"; id='" + entry.id + ".desktop'; " +
      "touch \"$f\"; awk -v id=\"$id\" 'BEGIN{done=0} " +
      "{ if ($2==id) { print $1+1, $2; done=1 } else print } " +
      "END{ if (!done) print 1, id }' \"$f\" > \"$f.tmp\" && mv \"$f.tmp\" \"$f\""]
    bumper.running = true
  }

  Process { id: bumper }

  function rebuild() {
    var apps = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < apps.length; i++) {
      // rofi hides NoDisplay=true entries; so do we.
      if (!apps[i].noDisplay) out.push(apps[i])
    }
    // Most-used first, alphabetical within the same count -- rofi's order.
    out.sort(function (a, b) {
      var d = root.usageOf(b) - root.usageOf(a)
      return d !== 0 ? d : a.name.localeCompare(b.name)
    })
    root.allEntries = out
    root.refilter()
  }

  function refilter() {
    var q = panel.query
    if (q === "") {
      root.results = root.allEntries.slice()
      list.moveTo(0)
      return
    }

    var scored = []
    for (var i = 0; i < root.allEntries.length; i++) {
      var e = root.allEntries[i]
      // Name is the display field, so it ranks highest; the rest are penalised
      // by a fixed offset so a weak name hit still beats a strong keyword hit.
      var s = panel.matchScore(e.name, q)
      s = Math.max(s, panel.matchScore(e.genericName, q) - 120)
      s = Math.max(s, panel.matchScore(e.id, q) - 200)
      s = Math.max(s, panel.matchScore((e.keywords || []).join(" "), q) - 260)
      s = Math.max(s, panel.matchScore(e.comment, q) - 320)
      if (s > 0) scored.push({ entry: e, score: s })
    }
    // Ties go to whatever you launch most -- typing "z" should put zen first.
    scored.sort(function (a, b) {
      return b.score - a.score
          || root.usageOf(b.entry) - root.usageOf(a.entry)
          || a.entry.name.localeCompare(b.entry.name)
    })

    var out = []
    for (var j = 0; j < scored.length; j++) out.push(scored[j].entry)
    root.results = out
    list.moveTo(0)
  }

  function launch(index) {
    var e = root.results[index === undefined ? list.currentIndex : index]
    if (!e) return

    // Capture BEFORE dismiss() -- dismissing tears down this panel's tree.
    var inTerm = e.runInTerminal === true
    var cmd = e.command
    var cwd = e.workingDirectory

    panel.dismiss()
    root.bumpUsage(e)

    // DesktopEntry.execute() does NOT spawn a terminal for Terminal=true
    // entries. Quickshell exposes runInTerminal as a read-only flag and
    // nothing more -- there is no xdg-terminal-exec fallback in the binary.
    // So `btop`, `nvim`, and every other ConsoleOnly entry silently did
    // nothing while GUI entries launched fine. Spawn kitty ourselves.
    if (inTerm && cmd && cmd.length) {
      var argv = ["kitty"]
      if (cwd) argv = argv.concat(["--directory", cwd])
      Quickshell.execDetached(argv.concat(["-e"]).concat(cmd))
    } else {
      e.execute()
    }
  }

  // DesktopEntries scans LAZILY -- the scan only starts on first access to
  // .values, and finishes asynchronously after it. A Connections on
  // onValuesChanged never fired, so rebuild() always ran against an empty
  // model and the drawer showed nothing (Enter then had no entry to launch).
  //
  // A property binding fixes both halves: declaring it TOUCHES .values at
  // startup, which kicks the scan off early, and the binding re-evaluates
  // when the model fills, re-running rebuild() with the real list.
  property var entrySource: DesktopEntries.applications.values
  onEntrySourceChanged: root.rebuild()
  Component.onCompleted: root.rebuild()

  // ---------------------------------------------------------------- panel
  LauncherPanel {
    id: panel

    prompt: "Apps"
    accent: Theme.accent           // catppuccin.rasi: border-color @mauve
    panelWidth: 500
    cornerRadius: 12
    placeholder: "Search..."
    list: list

    onPresented: {
      root.rebuild()
      if (root.group) root.group.claim(panel)
    }
    onDismissed: if (root.group) root.group.release(panel)
    onAccepted: root.launch()
    onQueryChanged: root.refilter()

    LauncherList {
      id: list
      width: parent.width
      accent: panel.accent
      // element-icon { size: 48px } plus element { padding: 6px 10px }
      rowHeight: 56
      rows: 8
      model: root.results

      delegate: Item {
        id: appRow
        required property var modelData
        required property int index

        width: ListView.view.width
        height: list.rowHeight

        readonly property bool current: appRow.ListView.isCurrentItem
        readonly property string iconSource: Quickshell.iconPath(appRow.modelData.icon, "application-x-executable")

        Row {
          anchors.fill: parent
          anchors.leftMargin: 10
          anchors.rightMargin: 10
          spacing: 10

          Item {
            width: 48
            height: 48
            anchors.verticalCenter: parent.verticalCenter

            IconImage {
              id: appIcon
              anchors.fill: parent
              implicitSize: 48
              asynchronous: true
              mipmap: true
              source: appRow.iconSource
              opacity: status === Image.Ready ? 1 : 0

              Behavior on opacity {
                NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
              }
            }

            // Themes miss icons; a tinted initial beats an empty hole.
            Rectangle {
              anchors.fill: parent
              radius: 10
              visible: appIcon.status !== Image.Ready
              color: Theme.alpha(list.accent, 0.18)

              Text {
                anchors.centerIn: parent
                text: appRow.modelData.name.charAt(0).toUpperCase()
                color: list.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.size + 6
                font.weight: Style.font.boldWeight
                renderType: Text.NativeRendering
              }
            }
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 48 - parent.spacing
            spacing: 1

            Text {
              width: parent.width
              text: appRow.modelData.name
              elide: Text.ElideRight
              color: Theme.text
              font.family: Style.font.family
              font.pixelSize: Style.font.size
              font.weight: appRow.current ? Style.font.boldWeight : Style.font.normalWeight
              renderType: Text.NativeRendering
            }

            Text {
              width: parent.width
              visible: text !== ""
              text: appRow.modelData.comment !== "" ? appRow.modelData.comment : appRow.modelData.genericName
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
          onEntered: list.currentIndex = appRow.index
          onClicked: root.launch(appRow.index)
        }
      }
    }

    // rofi just shows an empty box; say why it is empty.
    Item {
      width: parent.width
      height: visible ? 56 : 0
      visible: list.count === 0

      Text {
        anchors.centerIn: parent
        text: panel.query === "" ? "No applications found" : "No matches for “" + panel.query + "”"
        color: Theme.overlay0
        font.family: Style.font.family
        font.pixelSize: Style.font.size
        renderType: Text.NativeRendering
      }
    }
  }

  // ------------------------------------------------------------------ ipc
  IpcHandler {
    target: "apps"

    // `pkill -x rofi || rofi -show drun` was a toggle; keep that contract.
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
