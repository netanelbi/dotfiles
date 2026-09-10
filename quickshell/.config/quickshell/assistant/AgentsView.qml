import QtQuick
import QtQuick.Controls
import ".."

// Ctrl+S: the pi processes running on this machine right now.
//
// -------------------------------------------------- what is in this list
// AN AGENT IS A LIVE PI PROCESS. It joins the list when it registers and leaves
// when its process ends -- nothing else. That rule is the whole model, and it
// is what makes this list different from Ctrl+R: a conversation whose child the
// pool idle-killed ten minutes ago is not an agent, it is a transcript, and it
// is still there under Ctrl+R with everything it knew.
//
// (Measured while building this: of six Ori rows in the registry, two had live
// pids. The other four looked like "missing sessions" and were simply over.)
//
// The one exception is the conversation you are LOOKING AT, which stays on the
// list even if its child has just been idle-killed -- a row vanishing out from
// under the panel it belongs to reads as a bug, not as a fact.
//
// -------------------------------------------------- two sections
// ORI first, then OTHERS. Ori's conversations are all the same assistant in the
// same repo, so they are grouped rather than listed as peers of a stranger's
// terminal pi; under one heading, four rows read as one Ori with four sessions
// instead of four Oris. Delegates nest under whoever spawned them.
//
// -------------------------------------------------- what it can do
// Enter switches, but ONLY to one of Ori's own conversations: that is the same
// move as Ctrl+R and stays inside this repo. Switching to somebody else's pi
// would take Ori out of ~/.dotfiles, which it must never do, so those rows say
// no. Ctrl+X stops an agent (never its transcript). Ctrl+R renames one. Ctrl+N
// starts another Ori.
//
// `alive` comes from the HOST, which tests the pid. It is never read off
// `status`: a row says "running" until its own process writes the exit, so a
// killed agent leaves a row that lies, and drawing a dead agent as working is
// the one mistake this view must not make.
Rectangle {
  id: root

  property color accent: Theme.mauve
  // Handed back when this closes, so the caret returns to where you were.
  property var returnFocus: null

  readonly property var peers: OriClient.peers
  property int current: 0
  // Bumped on open so the relative times are recomputed -- `Date.now()` has no
  // change notifier, so a row that said "just now" would go on saying it.
  property int nonce: 0

  readonly property int upCount: {
    var n = 0
    for (var i = 0; i < root.peers.length; i++)
      if (root.peers[i].alive === true) n++
    return n
  }
  readonly property int workingCount: {
    var n = 0
    for (var i = 0; i < root.peers.length; i++) {
      var p = root.peers[i]
      // `busy` is only known for conversations the host owns. For everything
      // else -- terminal pi, delegates -- a live activity line is the evidence.
      if (p.alive && (p.busy === true || (p.busy === undefined && p.activity))) n++
    }
    return n
  }

  // ---------------------------------------------------------------- the tree
  // Flattened here rather than nested in the view, because a ListView of
  // ListViews cannot be walked with two arrow keys, and this surface is
  // keyboard-only. Section headings ride in the same array as rows with a
  // `header` field; the key handler steps over them.
  readonly property var rows: {
    var list = []
    var i, j, k

    // Live only. See the rule at the top of the file.
    var live = []
    for (i = 0; i < root.peers.length; i++) {
      var p = root.peers[i]
      if (p.alive === true || p.active === true) live.push(p)
    }

    var names = ({})
    for (i = 0; i < live.length; i++) names[live[i].name] = true
    var byParent = ({})
    for (i = 0; i < live.length; i++) {
      var q = live[i]
      // A delegate whose parent is not itself a LIVE row is an orphan -- its
      // Ori was stopped or idle-killed while it kept working. It is promoted to
      // the top of OTHERS rather than dropped: a running agent that appears
      // nowhere is the worst outcome this view can produce.
      var key = (q.parent && names[q.parent]) ? q.parent : ""
      if (!byParent[key]) byParent[key] = []
      byParent[key].push(q)
    }

    var tops = byParent[""] || []
    var oris = [], others = []
    for (i = 0; i < tops.length; i++)
      (tops[i].ori ? oris : others).push(tops[i])

    function emit(group, heading) {
      if (group.length === 0) return
      list.push({ header: heading })
      for (var a = 0; a < group.length; a++) {
        var top = group[a]
        var kids = byParent[top.name] || []
        list.push({ row: top, depth: 0, done: 0 })
        for (var b = 0; b < kids.length; b++)
          list.push({ row: kids[b], depth: 1, done: 0 })
      }
    }
    emit(oris, "ORI")
    emit(others, "OTHERS")
    return list
  }

  function isHeader(i) {
    return i >= 0 && i < root.rows.length && root.rows[i].header !== undefined
  }

  // Ori's conversations are numbered, because they are all the same assistant
  // in the same repo and the handle alone (`dotfiles-39162e`) says neither
  // which nor what. Under the ORI heading the word itself would be repetition,
  // so the row carries only the number. Everything else gets its own name --
  // or its handle, when it has no name to give.
  function displayName(r) {
    var n = r.label || r.name
    if (!r.ori) return n
    return "#" + (r.instance ? r.instance : "?") + " - " + n
  }

  // Denser than the card it sits on: a list is read, and glass under glass
  // would let the transcript show through the rows.
  color: Theme.alpha(Theme.mantle, 0.94)
  border.width: 1
  border.color: Theme.alpha(root.accent, 0.35)
  opacity: 0
  visible: opacity > 0
  radius: 10

  Behavior on opacity {
    NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
  }

  // Unlike the resume picker this opens even with nothing in it: "no agents" is
  // a real and useful answer to the question the key asks, and a key that
  // silently does nothing reads as broken.
  function open() {
    root.nonce++
    root.current = root.isHeader(0) ? 1 : 0
    root.confirmStop = false
    root.renaming = false
    root.opacity = 1
    root.forceActiveFocus()
    return true
  }

  function close() {
    root.opacity = 0
    root.renaming = false
    root.confirmStop = false
    if (root.returnFocus) root.returnFocus.forceActiveFocus()
  }

  // Relative, because "3 min ago" is what you want here; past a day the
  // subtraction stops being useful and it flips to a date. `nonce` is named in
  // the call so the delegate's binding depends on it -- that is what makes
  // open() re-read the clock.
  function when(at, nonce) {
    if (!at) return ""
    var ms = Date.now() - at
    if (ms < 60000) return "just now"
    var m = Math.floor(ms / 60000)
    if (m < 60) return m + " min ago"
    var h = Math.floor(m / 60)
    if (h < 24) return h + "h ago"
    return Qt.formatDateTime(new Date(at), "d MMM")
  }

  // WORKING vs UP vs GONE. The registry's own `status` cannot make the first
  // distinction -- it is written once at session_start and again at exit -- so
  // an idle conversation whose child the pool is still holding said "running".
  function stateWord(r) {
    if (r.alive) {
      if (r.busy === true) return "working"
      if (r.busy === false) return "up"
      return r.activity ? "working" : "up"
    }
    // The conversation you are IN, with no child: stopped, or idle-killed by
    // the pool. "gone" is what the pid says and it is the wrong word -- the
    // pool respawns on the next message, so it is asleep, not lost.
    if (r.active) return "asleep"
    return "gone"
  }

  readonly property var currentRow: !root.isHeader(root.current)
      && root.current >= 0 && root.current < root.rows.length
      ? root.rows[root.current].row : null

  // ------------------------------------------------------------- renaming
  // Ctrl+R here, where Ctrl+R in the chat panel is resume. Ori's own rows are
  // renamed through pi's `set_session_name`, so the name lands in the resume
  // picker too; anything else gets its registry `label`, which is also what
  // `peers send` resolves as an address. Either way it is a real name, not a
  // decoration on this list.
  property bool renaming: false

  function beginRename() {
    if (!root.currentRow) return
    renameField.text = root.currentRow.label || ""
    root.confirmStop = false
    root.renaming = true
    renameField.forceActiveFocus()
    renameField.selectAll()
  }

  function commitRename() {
    var t = renameField.text.trim()
    var r = root.currentRow
    root.renaming = false
    root.forceActiveFocus()
    if (t !== "" && r) OriClient.renamePeer(r.name, t)
  }

  function cancelRename() {
    root.renaming = false
    root.forceActiveFocus()
  }

  // --------------------------------------------------------------- stopping
  // Two presses when the agent is mid-turn, one when it is not. Stopping
  // something that is working throws away work that cannot be recovered, and
  // Ctrl+X is one slip away from Ctrl+C; stopping an idle child costs nothing
  // but a respawn, so making that one ask twice would be noise.
  property bool confirmStop: false

  function askStop() {
    var r = root.currentRow
    if (!r) return
    if (root.stateWord(r) === "working" && !root.confirmStop) {
      root.confirmStop = true
      return
    }
    root.confirmStop = false
    OriClient.stopPeer(r.name)
  }

  Keys.onPressed: function (event) {
    // Headers are not rows: step past them so ↑↓ never lands on a heading.
    function move(dir) {
      var i = root.current + dir
      while (i >= 0 && i < root.rows.length && root.isHeader(i)) i += dir
      if (i >= 0 && i < root.rows.length) root.current = i
    }
    switch (event.key) {
    case Qt.Key_Down:
    case Qt.Key_J:
      move(1)
      root.confirmStop = false
      event.accepted = true
      return
    case Qt.Key_Up:
    case Qt.Key_K:
      move(-1)
      root.confirmStop = false
      event.accepted = true
      return
    case Qt.Key_R:
      if (event.modifiers & Qt.ControlModifier) {
        root.beginRename()
        event.accepted = true
      }
      return
    case Qt.Key_X:
      if (event.modifiers & Qt.ControlModifier) {
        root.askStop()
        event.accepted = true
      }
      return
    case Qt.Key_N:
      // A new Ori, in this repo -- the only kind this panel can start. Same
      // thing Ctrl+N does in the composer, offered here because this is the
      // list you are looking at when you decide you want another one.
      if (event.modifiers & Qt.ControlModifier) {
        root.close()
        OriClient.newChat()
        event.accepted = true
      }
      return
    case Qt.Key_Return:
    case Qt.Key_Enter: {
      var r = root.currentRow
      if (r && r.ori && !r.active) {
        root.close()
        OriClient.resume(r.sessionId)
      } else if (r && !r.ori) {
        OriClient.notice = "Ori only opens its own conversations"
      } else {
        root.close()
      }
      event.accepted = true
      return
    }
    case Qt.Key_Escape:
      if (root.confirmStop) root.confirmStop = false
      else root.close()
      event.accepted = true
      return
    }
  }

  // ----------------------------------------------------------------- header
  Text {
    id: title
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
    text: root.renaming
        ? "rename  ·  ⏎ save   esc cancel"
        : root.confirmStop
          ? "ctrl+x again to stop “" + (root.currentRow ? root.displayName(root.currentRow) : "") + "”  ·  esc cancel"
          : "agents  ·  "
            + (root.upCount > 0 ? root.upCount + " up" : "none up")
            + (root.workingCount > 0 ? "  ·  " + root.workingCount + " working" : "")
            + "  ·  ⏎ open   ctrl+r rename   ctrl+x stop   ctrl+n new"
    color: root.confirmStop ? Theme.peach : Theme.overlay0
    elide: Text.ElideRight
    font.family: Style.font.panelMono
    font.pixelSize: Style.font.panelMeta
    renderType: Text.QtRendering
  }

  Text {
    anchors { left: parent.left; right: parent.right; top: title.bottom
              leftMargin: 12; rightMargin: 12; topMargin: 14 }
    visible: root.rows.length === 0
    text: "Nothing is running. Ori's past conversations are under ctrl+r."
    color: Theme.overlay0
    wrapMode: Text.WordWrap
    font.family: Style.font.panelMono
    font.pixelSize: Style.font.panelMeta
    renderType: Text.QtRendering
  }

  // The rename field. Docked at the bottom rather than drawn over the row: an
  // in-place editor would have to fight the delegate's own layout, and the row
  // being renamed still needs to be readable while you type a new name for it.
  Rectangle {
    id: renameBar
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 8 }
    height: root.renaming ? 36 : 0
    visible: root.renaming
    radius: 8
    color: Theme.alpha(Theme.base, 0.8)
    border.width: 1
    border.color: Theme.alpha(root.accent, renameField.activeFocus ? 0.9 : 0.3)

    TextField {
      id: renameField
      anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
      verticalAlignment: TextInput.AlignVCenter
      placeholderText: "new name…"
      placeholderTextColor: Theme.overlay0
      color: Theme.text
      font.family: Style.font.panelMono
      font.pixelSize: Style.font.panelBody
      background: null
      onAccepted: root.commitRename()
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
          root.cancelRename()
          event.accepted = true
        }
      }
    }
  }

  ListView {
    id: list
    anchors { left: parent.left; right: parent.right; top: title.bottom
              bottom: root.renaming ? renameBar.top : parent.bottom
              margins: 6; topMargin: 8 }
    model: root.rows
    clip: true
    spacing: 2
    // Keyboard-driven; a view that can scroll away from the selection would
    // need a scrollbar to explain itself.
    interactive: false

    // Scrolling is the LIST's job, through currentIndex. Calling
    // positionViewAtIndex() by hand from open() runs before the delegates are
    // laid out and parks the view on a guess.
    currentIndex: root.current
    highlightMoveDuration: 0
    highlightRangeMode: ListView.ApplyRange
    preferredHighlightBegin: 0
    preferredHighlightEnd: height

    delegate: Loader {
      required property int index
      required property var modelData
      width: list.width
      sourceComponent: modelData.header !== undefined ? headingPart : rowPart
      property var d: modelData
      property int i: index
    }

    Component {
      id: headingPart
      Item {
        height: 22
        Text {
          anchors { left: parent.left; bottom: parent.bottom; leftMargin: 14; bottomMargin: 3 }
          text: parent.parent.d.header
          color: Theme.overlay0
          font.family: Style.font.panelMono
          font.pixelSize: Style.font.panelMeta
          font.letterSpacing: 1
          renderType: Text.QtRendering
        }
      }
    }

    Component {
      id: rowPart
      Rectangle {
        readonly property var r: parent.d.row
        readonly property int depth: parent.d.depth
        readonly property bool on: parent.i === root.current

        height: label.implicitHeight + meta.implicitHeight + 14
        width: list.width
        radius: 4
        color: on ? Theme.surface1 : "transparent"

        // Selection rail.
        Rectangle {
          width: 2
          anchors { left: parent.left; top: parent.top; bottom: parent.bottom
                    leftMargin: 2; topMargin: 3; bottomMargin: 3 }
          radius: 1
          color: root.accent
          opacity: parent.on ? 1 : 0
        }

        // WORKING, and nothing else. A pip is the only thing an eye scanning a
        // column of names actually catches, so it gets the scarce meaning. It
        // used to mean merely alive, which put a pip on every parked
        // conversation with nothing happening in any of them.
        Rectangle {
          width: 5; height: 5; radius: 2.5
          anchors { right: parent.right; top: parent.top; rightMargin: 10; topMargin: 9 }
          color: root.accent
          opacity: root.stateWord(parent.r) === "working" ? 1 : 0
        }

        Text {
          id: label
          anchors { left: parent.left; right: parent.right; top: parent.top
                    leftMargin: 14 + parent.depth * 16; rightMargin: 22; topMargin: 5 }
          // Capped rather than trusted: an Ori conversation has no session
          // name, so the host substitutes the label it derived for the resume
          // picker, and that is the whole opening question up to 90 characters.
          text: {
            var n = root.displayName(parent.r)
            if (n.length > 52) n = n.slice(0, 52) + "…"
            return (parent.depth > 0 ? "↳ " : "") + n
          }
          color: parent.r.alive ? Theme.text : Theme.subtext0
          elide: Text.ElideRight
          font.family: Style.font.panelMono
          font.pixelSize: Style.font.panelBody
          renderType: Text.QtRendering
        }

        // One grey line under the name carrying everything that is not the
        // name: what it is, how it is, when it started, and what it is doing.
        Text {
          id: meta
          anchors { left: parent.left; right: parent.right; top: label.bottom
                    leftMargin: 14 + parent.depth * 16; rightMargin: 22; topMargin: 2 }
          text: {
            var bits = []
            if (parent.r.ori) bits.push(parent.r.active ? "current" : "parked")
            else if (parent.r.kind !== "root") bits.push("delegate")
            else bits.push("pi")
            bits.push(root.stateWord(parent.r))
            var w = root.when(parent.r.startedAt, root.nonce)
            if (w) bits.push(w)
            var line = bits.join("  ·  ")
            // The live tool line wins the tail of the row when there is one --
            // it is the only human-readable account of a running agent there is.
            if (parent.r.activity) return line + "  ·  " + parent.r.activity
            if (parent.r.task) return line + "  ·  " + parent.r.task
            return line
          }
          color: Theme.overlay0
          elide: Text.ElideRight
          font.family: Style.font.panelMono
          font.pixelSize: Style.font.panelMeta
          renderType: Text.QtRendering
        }
      }
    }
  }
}
