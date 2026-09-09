import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import ".."
import "Md.js" as Md

// The boards: floating cards the agent renders onto, by name, in any number,
// on any monitor. It is the agent's own surface layer -- it spawns them,
// moves, resizes, retargets screens, reads their live state (including a
// free-form draft BEFORE it is submitted) and snapshots their pixels.
//
//   qs -p ~/.config/quickshell ipc call board qml main /tmp/card.qml
//   qs -p ~/.config/quickshell ipc call board html side "<b>hi</b>"
//   qs -p ~/.config/quickshell ipc call board question main "Ship it?" "Yes,No"
//   qs -p ~/.config/quickshell ipc call board move main 900 120
//   qs -p ~/.config/quickshell ipc call board screen main DP-2
//   qs -p ~/.config/quickshell ipc call board read main
//   qs -p ~/.config/quickshell ipc call board snapshot main /tmp/snap.png
//   qs -p ~/.config/quickshell ipc call board close main
//   qs -p ~/.config/quickshell ipc call board list
//
// A board that was never mentioned does not exist; the first call naming it
// spawns it. "main" is the everyday one. The user can also drag a board by
// its header -- and the drag reads the cursor's GLOBAL position (hyprctl
// cursorpos), never the local coordinates, because local coordinates move
// with the surface and feed the delta back into itself: the runaway drag.
Scope {
  id: root

  property var boardNames: []
  // name -> the live BoardCard. Windows are not Items, so a Repeater cannot
  // hold them -- they are created here, once per name, and kept for good:
  // closing a board hides it, spawning the same name again reuses it.
  property var boardMap: ({})

  function ensure(name: string): string {
    var n = String(name || "").trim() === "" ? "main" : String(name).trim()
    if (root.boardNames.indexOf(n) < 0) {
      root.boardNames = root.boardNames.concat([n])
      root.boardMap[n] = boardComp.createObject(root, { name: n })
    }
    return n
  }

  function get(name: string) {
    return root.boardMap[root.ensure(name)]
  }

  Component {
    id: boardComp
    BoardCard { }
  }

  // ----------------------------------------------------------------- ipc
  IpcHandler {
    target: "board"

    // Render a QML file. The file is a plain Item subclass and imports ".."
    // for Theme/Style like the rest of the config.
    function qml(name: string, path: string): string {
      if (String(path || "").trim() === "") return "refused: qml needs <name> <path>"
      var c = root.get(name)
      return c ? c.showQml(String(path)) : "error"
    }

    // Raw HTML in the rich-text scroll -- no web view in the process.
    function html(name: string, html: string, title: string): string {
      if (String(html || "").trim() === "") return "refused: html needs <name> <html> [title]"
      var c = root.get(name)
      return c ? c.showHtml(String(html), String(title || "")) : "error"
    }

    // A built-in question card: buttons + free-form field, CSV options.
    // The answer returns as a [board] turn in the conversation.
    function question(name: string, q: string, options: string): string {
      if (String(q || "").trim() === "") return "refused: question needs <name> <q> [options]"
      var c = root.get(name)
      return c ? c.askQuestion(String(q), String(options || "")) : "error"
    }

    // A markdown file, rendered (headings, code, tables) and scrollable.
    function md(name: string, path: string, title: string): string {
      if (String(path || "").trim() === "") return "refused: md needs <name> <path> [title]"
      var c = root.get(name)
      return c ? c.showMd(String(path), String(title || "")) : "error"
    }

    function title(name: string, title: string): string {
      var c = root.get(name)
      if (!c) return "error"
      c.title = String(title || "").toUpperCase()
      return "titled " + c.title
    }

    function move(name: string, x: string, y: string): string {
      var c = root.get(name)
      return c ? c.move(String(x), String(y)) : "error"
    }

    function resize(name: string, w: string, h: string): string {
      var c = root.get(name)
      return c ? c.resize(String(w), String(h)) : "error"
    }

    // Put a board on a named monitor.
    function screen(name: string, monitor: string): string {
      var c = root.get(name)
      return c ? c.setScreen(String(monitor || "")) : "error"
    }

    // Logical + physical geometry -- the physical half is what a screenshot
    // crop needs on this 1.5x panel.
    function geometry(name: string): string {
      var c = root.get(name)
      return c ? c.geometry() : "error"
    }

    // Live state: mode, title, question, and the free-form draft AS TYPED.
    function read(name: string): string {
      var c = root.get(name)
      return c ? c.readState() : "error"
    }

    // Grab the card's own pixels, cropped to the card.
    function snapshot(name: string, path: string): string {
      var c = root.get(name)
      return c ? c.snapshot(String(path || "")) : "error"
    }

    function close(name: string): string {
      var c = root.get(name)
      if (!c) return "error"
      c.close()
      return "closed " + c.name
    }

    // Close everything.
    function closeAll(): string {
      var out = []
      for (var k in root.boardMap) {
        root.boardMap[k].close()
        out.push(k)
      }
      return "closed: " + (out.join(", ") || "none")
    }

    function list(): string {
      var out = []
      for (var k in root.boardMap)
        out.push(k + ": " + root.boardMap[k].readState())
      return out.length === 0 ? "(none)" : out.join("\n")
    }

    // Kept for the old one-board habit.
    function state(): string { return root.read("main") }
  }

  // ====================================================== one board card
  component BoardCard: PanelWindow {
    id: board

    property string name: "main"

    property int cardWidth: 520
    property int cardHeight: 640

    property bool opened: false
    property string title: "BOARD"
    property string mode: ""
    property url qmlSource: ""
    property int qmlRev: 0
    property string html: ""
    property string mdPath: ""
    property string mdBuf: ""
    property string mdHtml: ""
    property string question: ""
    property var options: []
    // The free-form field AS IT IS BEING TYPED.
    property string draft: ""

    // Position in logical points from the screen's top-left. -1 = not placed.
    property real posX: -1
    property real posY: -1
    property string placedOn: ""

    function open() { board.opened = true }

    function showQml(path: string): string {
      if (String(path || "").trim() === "") return "refused: no qml path"
      // The QML engine caches components by URL, so setSource on an EDITED
      // file still serves the stale copy. Copy to a revisioned path and load
      // that -- every push is a distinct URL, therefore a fresh read.
      var src = String(path)
      board.qmlRev++
      var dest = "/tmp/.board-load/" + board.name + "-" + board.qmlRev + ".qml"
      board.qmlSource = Qt.resolvedUrl(dest)
      board.mode = "qml"
      board.open()
      cpFile.target = board.qmlSource
      cpFile.command = ["sh", "-c",
        "mkdir -p /tmp/.board-load && cp -- '"
        + src.replace(/'/g, "'\\''") + "' " + dest]
      cpFile.running = true
      return "showing " + path + " on " + board.name
    }

    function showHtml(html: string, title: string): string {
      if (String(html || "").trim() === "") return "refused: no html"
      board.html = String(html)
      if (String(title || "") !== "") board.title = String(title).toUpperCase()
      board.mode = "html"
      board.open()
      return "showing html on " + board.name
    }

    // A markdown file, read + converted to styled rich text and rendered
    // scrollable. Buffer-then-assign-once: never feed a rich/markdown text
    // element incrementally, that wedges the engine (see SKILL.md).
    function showMd(path: string, title: string): string {
      if (String(path || "").trim() === "") return "refused: no md path"
      board.mdPath = String(path)
      board.mdBuf = ""
      mdRead.buf = ""
      var base = board.mdPath.split("/").pop()
      board.title = String(title || "").trim() !== "" ? String(title).toUpperCase() : "📄 " + base.toUpperCase()
      board.mode = "md"
      board.open()
      resize("680", "780")
      mdRead.command = ["cat", "--", board.mdPath]
      mdRead.running = true
      return "showing " + path + " on " + board.name
    }

    function askQuestion(q: string, optionsCsv: string): string {
      if (String(q || "").trim() === "") return "refused: no question"
      var opts = []
      var parts = String(optionsCsv || "").split(",")
      for (var i = 0; i < parts.length; i++)
        if (parts[i].trim() !== "") opts.push(parts[i].trim())
      board.question = String(q)
      board.options = opts
      board.title = "QUESTION"
      board.mode = "question"
      board.open()
      return "asking on " + board.name + "; the answer lands in the conversation"
    }

    // The answer's way back. Everything the question card offers ends here.
    function respond(text: string) {
      board.close()
      OriClient.ask("[" + board.name + "] " + text)
    }

    // Clamp so a drag (or a resize) can never park the card over the panel
    // strip or off the screen.
    function clampPos() {
      var s = board.screen
      if (!s) return
      var minX = panelReserved()
      board.posX = Math.max(minX, Math.min(board.posX, s.width - cardWidth - 12))
      board.posY = Math.max(0, Math.min(board.posY, s.height - cardHeight - 40))
    }

    function move(x: string, y: string): string {
      var nx = Number(x), ny = Number(y)
      if (isNaN(nx) || isNaN(ny)) return "refused: move needs two numbers"
      board.posX = nx
      board.posY = ny
      clampPos()
      board.placedOn = board.screen ? board.screen.name : ""
      return board.name + " moved to " + Math.round(board.posX) + "," + Math.round(board.posY)
    }

    function resize(w: string, h: string): string {
      var nw = Number(w), nh = Number(h)
      if (isNaN(nw) || isNaN(nh)) return "refused: resize needs two numbers"
      board.cardWidth = Math.max(240, Math.min(1600, Math.round(nw)))
      board.cardHeight = Math.max(160, Math.min(2000, Math.round(nh)))
      board.clampPos()
      return board.name + " resized to " + board.cardWidth + "x" + board.cardHeight
    }

    function setScreen(monitor: string): string {
      var want = String(monitor || "").trim()
      if (want === "") return "refused: screen needs a monitor name"
      var screens = Quickshell.screens
      for (var i = 0; i < screens.length; i++) {
        if (screens[i].name === want) {
          board.screen = screens[i]
          board.placedOn = ""
          board.clampPos()
          return board.name + " -> " + want
        }
      }
      return "no such monitor: " + want
    }

    function geometry(): string {
      var s = board.screen
      if (!s) return "no screen"
      var scale = s.devicePixelRatio || 1
      return "screen=" + s.name
        + " logical=" + Math.round(board.posX) + "," + Math.round(board.posY)
        + " " + board.cardWidth + "x" + board.cardHeight
        + " phys=" + Math.round(board.posX * scale + 12 * scale)
        + "," + Math.round(board.posY * scale + 12 * scale)
        + " " + Math.round(board.cardWidth * scale) + "x" + Math.round(board.cardHeight * scale)
    }

    function readState(): string {
      return "open=" + board.opened + " mode=" + board.mode + " title=" + board.title
        + " screen=" + (board.screen ? board.screen.name : "-")
        + (board.mode === "question" ? " q=\"" + board.question + "\"" : "")
        + " draft=\"" + board.draft + "\""
    }

    function snapshot(path: string): string {
      var s = board.screen
      if (!s) return "no screen"
      var scale = s.devicePixelRatio || 1
      var out = String(path || "").trim() === ""
        ? "/tmp/board-" + board.name + ".png" : String(path)
      var full = "/tmp/board-full-" + board.name + ".png"
      snapCmd.command = ["sh", "-c",
        "grim -o " + s.name + " " + full + " && magick " + full + " -crop "
        + Math.round(board.cardWidth * scale) + "x" + Math.round(board.cardHeight * scale)
        + "+" + Math.round(board.posX * scale + 12 * scale)
        + "+" + Math.round(board.posY * scale + 12 * scale)
        + " +repage " + out]
      snapCmd.running = true
      return "snapshot -> " + out
    }

    function close() {
      board.opened = false
      // Drop the payload with the card: an old render has no business sitting
      // in memory, and the next show must not flash the previous one.
      board.mode = ""
      board.qmlSource = ""
      board.html = ""
      board.draft = ""
    }

    // ---------------------------------------------------------------- placement
    // The assistant panel's reserved strip, in logical points: when it is open
    // on THIS board's screen, nothing spawned may slide under it. 584 = panel
    // 560 + its surface padding; +16 keeps a gutter.
    function panelReserved(): real {
      if (!OriClient.panelOpen) return 0
      var dock = OriClient.panelDock
      if (!board.screen || dock.screen !== board.screen.name) return 0
      return 586
    }

    // Does rect (x, y, w, h) overlap any other OPEN board on this screen?
    function overlapsAny(x: real, y: real, w: real, h: real): bool {
      for (var k in root.boardMap) {
        var o = root.boardMap[k]
        if (o === board || !o.opened) continue
        if (o.screen !== board.screen) continue
        if (x < o.posX + o.cardWidth + 12 && x + w + 12 > o.posX
            && y < o.posY + o.cardHeight + 12 && y + h + 12 > o.posY)
          return true
      }
      return false
    }

    // First free slot: scan a grid, right-to-left then top-to-bottom. If the
    // grid is saturated (panel strip + big cards on a small screen), walk a
    // ladder of shrinking sizes rather than ever overlap. Last resort keeps
    // the old position (x = -1 says so).
    function findFreeSpot() {
      var s = board.screen
      if (!s) return Qt.point(0, 0)
      var sizes = [
        [cardWidth, cardHeight],
        [cardWidth, Math.round(cardHeight * 0.8)],
        [Math.round(cardWidth * 0.85), Math.round(cardHeight * 0.6)],
        [Math.round(cardWidth * 0.7), Math.round(cardHeight * 0.45)]
      ]
      for (var i = 0; i < sizes.length; i++) {
        var spot = scanGrid(s, sizes[i][0], sizes[i][1])
        if (spot.x >= 0) {
          cardWidth = sizes[i][0]
          cardHeight = sizes[i][1]
          return spot
        }
      }
      return Qt.point(-1, -1)
    }

    function scanGrid(s, w: real, h: real) {
      var minX = panelReserved()
      var top = Style.bar.marginTop + Style.bar.height + 12
      var stepX = w + 48
      var stepY = h + 48
      var cols = Math.floor((s.width - 36 - minX + 12) / stepX)
      var rows = Math.floor((s.height - top - 40 + 12) / stepY)
      for (var r = 0; r < Math.max(1, rows); r++) {
        for (var c = 0; c < Math.max(1, cols); c++) {
          var x = minX + c * stepX
          var y = top + r * stepY
          if (x + w + 36 > s.width) break
          if (y + h + 40 > s.height) break
          if (!overlapsAny(x, y, w, h)) return Qt.point(x, y)
        }
      }
      return Qt.point(-1, -1)
    }

    // Opens on whichever monitor has focus, the same rule the panel uses --
    // unless screen() already sent it somewhere on purpose.
    function focusedScreen() {
      var focused = Hyprland.focusedMonitor
      if (!focused) return board.screen
      var screens = Quickshell.screens
      for (var i = 0; i < screens.length; i++) {
        if (Hyprland.monitorFor(screens[i]) === focused) return screens[i]
      }
      return board.screen
    }

    // Per-name namespace: SUPER+Q's helper matches the layer line under the
    // cursor and closes THAT board by name. All share the quickshell-board
    // prefix.
    WlrLayershell.namespace: "quickshell-board-" + board.name
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; left: true }
    margins {
      left: Math.max(0, Math.round(board.posX))
      top: Math.max(0, Math.round(board.posY))
    }

    implicitWidth: cardWidth + 24
    implicitHeight: cardHeight + 24
    color: "transparent"
    visible: opened

    onOpenedChanged: {
      if (!opened) return
      var s = focusedScreen()
      if (s) board.screen = s
      var sn = board.screen ? board.screen.name : ""
      if (board.posX < 0 || board.placedOn !== sn) {
        var p = findFreeSpot()
        if (p.x >= 0) { board.posX = p.x; board.posY = p.y }
        board.placedOn = sn
      } else if (overlapsAny(board.posX, board.posY, cardWidth, cardHeight)) {
        // A placed board that now collides (another board spawned, panel
        // opened) gives way -- being visible beats staying put.
        var p2 = findFreeSpot()
        if (p2.x >= 0) { board.posX = p2.x; board.posY = p2.y }
      }
    }

    // Only the card takes clicks.
    mask: Region { x: 12; y: 12; width: card.width; height: card.height }

    Shortcut {
      sequence: "Escape"
      context: Qt.WindowShortcut
      enabled: board.opened
      onActivated: board.close()
    }

    Process { id: snapCmd }

    // Copies a pushed qml to its revisioned slot, then loads it. On a copy
    // failure the old render stays and the exit code says why.
    Process {
      id: cpFile
      property url target: ""
      onExited: function (code) {
        if (code === 0) qmlLoader.setSource(board.qmlSource)
        else console.warn("[board] copy failed for", target, "code", code)
      }
    }

    // Reads a markdown file into mdBuf; onExited converts + assigns ONCE.
    Process {
      id: mdRead
      property string buf: ""
      stdout: SplitParser { onRead: data => mdRead.buf += data + "\n" }
      onExited: {
        board.mdBuf = mdRead.buf
        mdAssign.restart()
      }
    }
    Timer {
      id: mdAssign
      interval: 250; repeat: false
      onTriggered: board.mdHtml = Md.toHtml(board.mdBuf)
    }

    // ------------------------------------------------------------ card
    Rectangle {
      id: card

      x: 12; y: 12
      width: board.cardWidth
      height: board.cardHeight

      color: Theme.alpha(Theme.base, 0.88)
      radius: 12
      border.width: 1
      border.color: Theme.alpha(Theme.sapphire, 0.5)
      clip: true

      // ---------------------------------------------------------- header
      Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right
                  margins: card.border.width }
        height: 40
        color: Theme.transparent
        topLeftRadius: card.radius - card.border.width
        topRightRadius: card.radius - card.border.width

        // Drag by the header. The cursor's position is read from the
        // COMPOSITOR (hyprctl cursorpos, global physical px) on a poll, never
        // from the MouseArea's local coordinates: the surface moves under the
        // cursor, so local coordinates feed the surface's own motion back
        // into the delta and the card runs away. Global position is stable
        // no matter what the surface does, so the delta is exact.
        MouseArea {
          id: dragArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.SizeAllCursor
          onPressed: function (m) {
            board.pressCur = Qt.point(-1, -1)
            dragPoll.restart()
          }
          onReleased: dragPoll.stop()
        }

        Timer {
          id: dragPoll
          interval: 30
          repeat: true
          onTriggered: dragPos.running = true
        }

        Process {
          id: dragPos
          command: ["hyprctl", "cursorpos"]
          stdout: SplitParser {
            onRead: function (d) {
              var parts = String(d).trim().split(/[\s,]+/)
              if (parts.length < 2) return
              var gx = parseFloat(parts[0]), gy = parseFloat(parts[1])
              if (isNaN(gx) || isNaN(gy)) return
              var s = board.screen
              var scale = s ? (s.devicePixelRatio || 1) : 1
              if (board.pressCur.x < 0) {
                // First sample after press: remember where the drag started.
                board.pressCur = Qt.point(gx, gy)
                board.pressPos = Qt.point(board.posX, board.posY)
                return
              }
              board.posX = board.pressPos.x + (gx - board.pressCur.x) / scale
              board.posY = board.pressPos.y + (gy - board.pressCur.y) / scale
              board.clampPos()
              board.placedOn = s ? s.name : ""
            }
          }
        }

        Text {
          id: boardTitle
          anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
          text: board.title + (board.name !== "main" ? " · " + board.name : "")
          color: Theme.sapphire
          font.family: Style.font.panelMono
          font.pixelSize: Style.font.panelMeta - 1
          font.letterSpacing: 3
          renderType: Text.QtRendering
        }

        Rectangle {
          anchors { left: boardTitle.right; right: closeBtn.left; leftMargin: 12; rightMargin: 12
                    verticalCenter: parent.verticalCenter }
          height: 1
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Theme.alpha(Theme.sapphire, 0.5) }
            GradientStop { position: 1.0; color: Theme.alpha(Theme.sapphire, 0.0) }
          }
        }

        Rectangle {
          id: closeBtn
          anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
          width: 24; height: 24; radius: 6
          color: closeArea.containsMouse ? Theme.hoverBackground : Theme.transparent
          Text {
            anchors.centerIn: parent
            text: "✕"
            color: closeArea.containsMouse ? Theme.text : Theme.overlay0
            font.family: Style.font.panelMono
            font.pixelSize: Style.font.panelBody
            renderType: Text.QtRendering
          }
          MouseArea {
            id: closeArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: board.close()
          }
        }

        Rectangle {
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          height: 1
          color: Theme.alpha(Theme.sapphire, 0.15)
        }
      }

      // -------------------------------------------------------- content
      Loader {
        id: qmlLoader
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        active: board.opened && board.mode === "qml"
        onStatusChanged: if (status === Loader.Error)
          console.warn("[board] qml failed to load:", board.qmlSource)
        clip: true
      }

      Flickable {
        id: questionScroll
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        contentWidth: width
        contentHeight: questionCard.height + 32
        visible: board.mode === "question"
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        BoardQuestion {
          id: questionCard
          x: 16; y: 16
          width: questionScroll.width - 32
          board: board
        }
      }

      Flickable {
        id: htmlScroll
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        contentWidth: width
        contentHeight: htmlBody.height + 24
        visible: board.mode === "html"
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Text {
          id: htmlBody
          x: 16; y: 12
          width: htmlScroll.width - 32
          text: board.html
          textFormat: Text.RichText
          color: Theme.text
          font.family: Style.font.panelFamily
          font.pixelSize: Style.font.panelBody - 3
          wrapMode: Text.WordWrap
          onLinkActivated: function (link) { Qt.openUrlExternally(link) }
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
          }
        }
      }

      // Markdown file, converted by Md.js to styled rich text and rendered
      // like the html card -- one-shot text assignment, wheel to scroll.
      Flickable {
        id: mdScroll
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        contentWidth: width
        contentHeight: mdBody.height + 24
        visible: board.mode === "md"
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        // Flickable's native wheel step is timid; real steps per notch and
        // 1:1 pixel tracking for touchpads (same rules as the panel scroll).
        WheelHandler {
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          onWheel: function (ev) {
            var dy = ev.pixelDelta.y !== 0 ? ev.pixelDelta.y : ev.angleDelta.y / 120 * 200
            var max = Math.max(0, mdScroll.contentHeight - mdScroll.height)
            mdScroll.contentY = Math.max(0, Math.min(max, mdScroll.contentY - dy))
          }
        }

        Text {
          id: mdBody
          x: 16; y: 12
          width: mdScroll.width - 32
          text: board.mdHtml
          textFormat: Text.RichText
          color: Theme.text
          font.family: Style.font.panelFamily
          font.pixelSize: Style.font.panelBody - 2
          wrapMode: Text.WordWrap
          onLinkActivated: function (link) { Qt.openUrlExternally(link) }
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
          }
        }
      }
    }

    // Drag state: the press's global cursor and the position it started from.
    property point pressCur: Qt.point(-1, -1)
    property point pressPos: Qt.point(0, 0)
  }
}