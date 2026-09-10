import QtQuick
import ".."

// Ctrl+S: every pi session on this machine, as a tree.
//
// A VIEWER. No Enter, no switching, no actions -- deliberately, and not as a
// first cut. Ori is a conversation that lives in ~/.dotfiles; opening someone
// else's session here would move Ori out of its own repo, which is exactly what
// it must not do. Ctrl+R remains the only thing that changes which conversation
// you are in, and it only ever offers Ori's own.
//
// So this answers one question -- what is running, and who started it -- and
// then gets out of the way. Reaching an agent is `peers send`, from the
// composer, in words. There is nothing to click here on purpose.
//
// The model is OriClient.peers: the host's read of the peers registry
// (~/.pi/agent/subagents/registry.json), which every pi session writes at start
// and at exit. It is NOT OriClient.sessions -- that is Ori's own conversations
// and belongs to Ctrl+R. A session can be in both lists; they are two views of
// one machine, not two populations.
//
// -------------------------------------------------- what a row may claim
// `alive` comes from the HOST, which tests the pid. It is never read off
// `status`: a row says "running" until its own process writes the exit, so a
// killed agent leaves a row that lies, and drawing a dead delegate as working
// is the one mistake this view must not make.
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

  readonly property int running: {
    var n = 0
    for (var i = 0; i < root.peers.length; i++)
      if (root.peers[i].alive === true) n++
    return n
  }

  // ---------------------------------------------------------------- the tree
  // Flattened here rather than nested in the view, because a ListView of
  // ListViews cannot be walked with two arrow keys, and this surface is
  // keyboard-only.
  //
  // Roots always, newest first. Under each, its LIVE delegates -- a finished
  // delegate is a row you cannot act on, and forty of them would bury the two
  // that are working. What is lost is only ever a count, and the count is
  // printed on the parent, so nothing disappears silently.
  //
  // A delegate whose parent is not itself a row -- forgotten, never registered,
  // or written before rows carried a parent at all -- is an ORPHAN. A live one
  // is promoted to the top level, because a running agent that appears nowhere
  // is the worst outcome this view can produce. A dead one is dropped: it has
  // no parent to be folded under, nothing here can act on it, and there are
  // currently 35 of them left over from testing, which would bury everything
  // real. They stay in the registry and `peers list` still shows them.
  readonly property var rows: {
    var list = []
    var byParent = ({})
    var names = ({})
    var i
    for (i = 0; i < root.peers.length; i++) names[root.peers[i].name] = true
    for (i = 0; i < root.peers.length; i++) {
      var p = root.peers[i]
      var known = p.parent && names[p.parent]
      if (!known && p.kind !== "root" && !p.alive) continue
      var key = known ? p.parent : ""
      if (!byParent[key]) byParent[key] = []
      byParent[key].push(p)
    }
    var tops = byParent[""] || []
    for (i = 0; i < tops.length; i++) {
      var top = tops[i]
      var kids = byParent[top.name] || []
      var live = []
      var doneCount = 0
      for (var k = 0; k < kids.length; k++) {
        if (kids[k].alive) live.push(kids[k])
        else doneCount++
      }
      list.push({ row: top, depth: 0, done: doneCount })
      for (var j = 0; j < live.length; j++)
        list.push({ row: live[j], depth: 1, done: 0 })
    }
    return list
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
    root.current = 0
    root.opacity = 1
    root.forceActiveFocus()
    return true
  }

  function close() {
    root.opacity = 0
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

  function stateWord(r) {
    if (r.alive) return "running"
    // "running" on a row whose pid is gone is the registry mid-write or a
    // process that died without settling. Neither is running.
    if (r.status === "running") return "gone"
    return r.status || "idle"
  }

  Keys.onPressed: function (event) {
    switch (event.key) {
    case Qt.Key_Down:
    case Qt.Key_J:
      root.current = Math.min(root.current + 1, root.rows.length - 1)
      event.accepted = true
      return
    case Qt.Key_Up:
    case Qt.Key_K:
      root.current = Math.max(root.current - 1, 0)
      event.accepted = true
      return
    case Qt.Key_Escape:
    case Qt.Key_Return:
    case Qt.Key_Enter:
      // Enter closes rather than doing nothing: it is the reflex after reading
      // a list, and a key that is swallowed reads as a hang.
      root.close()
      event.accepted = true
      return
    }
  }

  // ----------------------------------------------------------------- header
  Text {
    id: title
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
    text: "agents  ·  " + (root.running > 0 ? root.running + " running" : "none running")
        + "  ·  ↑↓ move   esc back"
    color: Theme.overlay0
    font.family: Style.font.panelMono
    font.pixelSize: Style.font.panelMeta
    renderType: Text.QtRendering
  }

  Text {
    anchors { left: parent.left; right: parent.right; top: title.bottom
              leftMargin: 12; rightMargin: 12; topMargin: 14 }
    visible: root.rows.length === 0
    text: "No pi sessions have registered yet."
    color: Theme.overlay0
    font.family: Style.font.panelMono
    font.pixelSize: Style.font.panelMeta
    renderType: Text.QtRendering
  }

  ListView {
    id: list
    anchors { left: parent.left; right: parent.right; top: title.bottom
              bottom: parent.bottom; margins: 6; topMargin: 8 }
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

    delegate: Rectangle {
      required property int index
      required property var modelData

      readonly property var r: modelData.row
      readonly property int depth: modelData.depth
      readonly property int doneCount: modelData.done
      readonly property bool on: index === root.current

      width: list.width
      height: label.implicitHeight + meta.implicitHeight + 14
      radius: 4
      color: on ? Theme.surface1 : "transparent"

      // Selection rail. The only mark this view carries: with nothing to
      // activate there is no "focused" row to distinguish from a selected one,
      // which is the collision the resume picker had to solve with three marks.
      Rectangle {
        width: 2
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom
                  leftMargin: 2; topMargin: 3; bottomMargin: 3 }
        radius: 1
        color: root.accent
        opacity: parent.on ? 1 : 0
      }

      // ALIVE, and nothing else. A pip is the only thing an eye scanning a
      // column of names actually catches.
      Rectangle {
        width: 5; height: 5; radius: 2.5
        anchors { right: parent.right; top: parent.top; rightMargin: 10; topMargin: 9 }
        color: root.accent
        opacity: parent.r.alive ? 1 : 0
      }

      Text {
        id: label
        anchors { left: parent.left; right: parent.right; top: parent.top
                  leftMargin: 14 + parent.depth * 16; rightMargin: 22; topMargin: 5 }
        // The tree mark is the indent's explanation. Without it a nested row
        // just looks misaligned.
        // Handle first, name second. The handle is what you type at `peers
        // send`, so it cannot be replaced by the name -- but a row that was
        // only a handle said nothing about what the conversation IS.
        //
        // Capped here rather than trusted: an Ori conversation has no session
        // name, so the host substitutes the label it derived for the resume
        // picker, and that is the whole opening question up to 90 characters.
        // Elide alone would let one row's title push the state line off screen.
        text: (parent.depth > 0 ? "↳ " : "")
            + parent.r.name
            + (parent.r.label
               ? "  “" + (parent.r.label.length > 44
                          ? parent.r.label.slice(0, 44) + "…"
                          : parent.r.label) + "”"
               : "")
        color: parent.r.alive ? Theme.text : Theme.subtext0
        elide: Text.ElideRight
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelBody
        renderType: Text.QtRendering
      }

      // One grey line under the name carrying everything that is not the name:
      // what it is, how it is, when it started, what it is doing, and -- on a
      // root -- how many finished delegates are folded away beneath it.
      Text {
        id: meta
        anchors { left: parent.left; right: parent.right; top: label.bottom
                  leftMargin: 14 + parent.depth * 16; rightMargin: 22; topMargin: 2 }
        text: {
          var bits = []
          bits.push(parent.r.kind === "root" ? "root" : "delegate")
          bits.push(root.stateWord(parent.r))
          var w = root.when(parent.r.startedAt, root.nonce)
          if (w) bits.push(w)
          if (parent.doneCount > 0)
            bits.push(parent.doneCount + " done")
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
