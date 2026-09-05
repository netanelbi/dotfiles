import QtQuick
import ".."

// Ctrl+R: the past conversations, over the transcript.
//
// A list and nothing else -- no buttons, no close affordance, no mouse target.
// This is a keyboard surface on a keyboard desktop: up/down to move, Enter to
// take one, Escape to leave. The panel already takes focus on demand, so this
// only has to take it from the composer and give it back.
//
// The list is OriClient.sessions, which is the index the host keeps -- not a
// directory scan. It is Ori's conversations only, and it is readable while pi
// is cold, which is the whole reason the index exists.
//
// It now includes PARKED conversations: Ctrl+N and Ctrl+R park rather than
// stop, so a child can still be finishing a turn behind a row in this list.
// Those rows carry `busy`, which the meta line says out loud -- it would be a
// lie to show a conversation that is mid-answer as just another old thread.
//
// -------------------------------------------------- what a row may claim
// `busy` and "this is the one you are in" are the only two states drawn here,
// because they are the only two the user can act on. The list used to draw a
// third -- a dim pip and the word "loaded" for `SessionEntry.live`, meaning the
// host is holding the conversation in memory rather than on disk. That is an
// implementation fact wearing a status's clothes: it is not something you can
// do anything about, the "instant switch" it implied is the switch the user
// reported as SLOW, and it stays true after the session's pi child has been
// idle-killed (measured: sessionsJson said live:true for two conversations
// whose children the journal had killed for 'idle 600s'). It is off the screen.
// `live` is still on the wire, where it belongs -- it is a scheduling hint for
// the host, not a label.
Rectangle {
  id: root

  property color accent: Theme.mauve
  // Handed back when this closes, so the caret returns to where you were.
  property var returnFocus: null

  readonly property var sessions: OriClient.sessions
  property int current: 0

  // WHICH ROW IS THE ONE YOU ARE READING. The host has always known -- it sends
  // `activeId` beside the entries -- and it is also the session id already in
  // OriClient, in the same id space (checked live: `ipc call ori state` reports
  // session=01a05285… and sessionsJson's second row carries that exact id).
  // Without it the list answered "where am I?" with nothing, and the reflex
  // gesture -- Ctrl+R, look, Enter to back out -- landed on row 0, which is NOT
  // your session, and paid a full transcript rebuild to leave the conversation
  // you were in.
  readonly property string activeId: OriClient.sessionId
  function isActive(s) { return s !== undefined && root.activeId !== "" && String(s.id) === root.activeId }

  function indexOfActive() {
    for (var i = 0; i < root.sessions.length; i++)
      if (root.isActive(root.sessions[i])) return i
    return -1
  }

  // Bumped on every open so the relative times below are recomputed. `Date.now()`
  // has no change notifier, so `when(at)` on its own is evaluated once per
  // delegate creation and then frozen -- a row that said "just now" went on
  // saying it hours later.
  property int nonce: 0

  readonly property int running: {
    var n = 0
    for (var i = 0; i < root.sessions.length; i++)
      if (root.sessions[i].busy === true) n++
    return n
  }

  color: Theme.mantle
  opacity: 0
  visible: opacity > 0
  radius: 6

  Behavior on opacity {
    NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
  }

  function open() {
    if (root.sessions.length === 0) return false
    // Recompute the ages: see `nonce`.
    root.nonce++
    // Opens ON the conversation you are in, so the list answers "where am I?"
    // before you have read a single row -- and so the cheapest gesture in it
    // (Enter, straight away) is the one that costs nothing.
    var i = root.indexOfActive()
    root.current = i >= 0 ? i : 0
    root.opacity = 1
    root.forceActiveFocus()
    return true
  }

  function close() {
    root.opacity = 0
    if (root.returnFocus) root.returnFocus.forceActiveFocus()
  }

  function take() {
    var s = root.sessions[root.current]
    root.close()
    // Resuming the conversation you are ALREADY IN is not a switch: the host
    // takes the exact-match branch, activate() re-emits the whole snapshot, and
    // the panel clears and rebuilds every delegate to land you on the screen you
    // were already looking at. So Enter on your own row just shuts the list.
    if (s && !root.isActive(s)) OriClient.resume(s.id)
  }

  // ------------------------------------------------------------------ label
  // Relative, because "3 min ago" is what you are actually looking for after a
  // shell reload -- an absolute clock time makes you do the subtraction. Past a
  // day it flips to the date, where the subtraction stops being useful.
  // `nonce` is unused and deliberate: naming it in the call is what makes the
  // delegate's binding depend on it, so bumping it on open() re-reads the clock.
  function when(at, nonce) {
    var ms = Date.now() - (at || 0)
    if (ms < 60000) return "just now"
    var m = Math.floor(ms / 60000)
    if (m < 60) return m + " min ago"
    var h = Math.floor(m / 60)
    if (h < 24) return h + "h ago"
    var d = new Date(at)
    return Qt.formatDateTime(d, "d MMM")
  }

  Keys.onPressed: function (event) {
    switch (event.key) {
    case Qt.Key_Down:
    case Qt.Key_J:
      root.current = Math.min(root.current + 1, root.sessions.length - 1)
      event.accepted = true
      return
    case Qt.Key_Up:
    case Qt.Key_K:
      root.current = Math.max(root.current - 1, 0)
      event.accepted = true
      return
    case Qt.Key_Return:
    case Qt.Key_Enter:
      root.take()
      event.accepted = true
      return
    case Qt.Key_Escape:
      root.close()
      event.accepted = true
      return
    }
  }

  // ----------------------------------------------------------------- header
  Text {
    id: title
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
    // The count of conversations actually WORKING right now, in the one place
    // you have already come to look at conversations. It is the host's own
    // per-session `busy`, re-sent whenever a conversation is parked, settles or
    // loses its child -- not a guess made here.
    text: "resume" + (root.running > 0 ? "  ·  " + root.running + " running" : "")
        + "  ·  ↑↓ move   ⏎ open   esc back"
    color: Theme.overlay0
    font.family: Style.font.panelMono
    font.pixelSize: Style.font.panelMeta
    renderType: Text.QtRendering
  }

  ListView {
    id: list
    anchors { left: parent.left; right: parent.right; top: title.bottom
              bottom: parent.bottom; margins: 6; topMargin: 8 }
    model: root.sessions
    clip: true
    spacing: 2
    // No interactive flick: this list is driven by the keys above, and a view
    // that can scroll away from the selection needs a scrollbar to explain
    // itself.
    interactive: false

    // Scrolling is the LIST's job, through currentIndex, not a
    // positionViewAtIndex() next to every key. Calling that by hand from open()
    // ran before the delegates had been laid out, so it parked the view on a
    // guess -- the selected row ended up at the bottom and the top row's title
    // was clipped under the header.
    currentIndex: root.current
    highlightMoveDuration: 0
    highlightRangeMode: ListView.ApplyRange
    preferredHighlightBegin: 0
    preferredHighlightEnd: height

    delegate: Rectangle {
      required property int index
      required property var modelData

      width: list.width
      height: label.implicitHeight + meta.implicitHeight + 14
      radius: 4
      readonly property bool on: index === root.current
      readonly property bool here: root.isActive(modelData)
      color: on ? Theme.surface1 : "transparent"

      // THREE THINGS, THREE PLACES. They were sharing two, and the collision
      // lost the one that mattered: a row that was BOTH the current
      // conversation and working printed "open" and never said it was running,
      // because the status slot was spent on the focus word. Focus is not a
      // status -- a conversation does not stop working because you are looking
      // at it. So:
      //   selection (where ↑↓ is)   -> this rail + the surface tint
      //   focus (what the panel shows) -> the gutter caret below
      //   status (working or not)   -> the pip and the meta line, ALWAYS
      Rectangle {
        width: 2
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom
                  leftMargin: 2; topMargin: 3; bottomMargin: 3 }
        radius: 1
        color: root.accent
        opacity: parent.on ? 1 : 0
      }

      // FOCUS: the conversation the panel is showing behind this list. A fixed
      // gutter, so every title starts on the same column and the caret is the
      // only thing that varies -- an indent that moved per row would read as a
      // layout bug rather than a mark.
      Text {
        id: caret
        anchors { left: parent.left; top: parent.top; leftMargin: 12; topMargin: 5 }
        width: 10
        text: parent.here ? "▸" : ""
        color: Theme.text
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }

      // ONE meaning: this conversation is working RIGHT NOW, behind this list.
      // The meta line says so too, in grey text two sizes below the title, which
      // is not where an eye scanning titles ever goes -- a pip on the row edge is
      // read without being looked for.
      //
      // It used to have a second, dimmer state for `live` ("loaded"). See the
      // note at the top of this file: that was a fact about which side of an
      // in-RAM/on-disk line the bytes were on, and the user cannot act on it.
      Rectangle {
        id: pip
        width: 6; height: 6; radius: 3
        anchors { right: parent.right; top: parent.top; rightMargin: 10; topMargin: 9 }
        visible: modelData.busy === true
        color: root.accent

        SequentialAnimation on opacity {
          // Bound to `running`, not started once: a delegate is recycled by the
          // view, and an animation left running on a pooled item keeps burning
          // frames for a row nobody is looking at.
          running: pip.visible
          loops: Animation.Infinite
          NumberAnimation { to: 0.25; duration: 620; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 1.0;  duration: 620; easing.type: Easing.InOutQuad }
          // A stopped animation leaves opacity wherever the last frame put it,
          // so a turn settling mid-fade would strand the pip at 0.25 and read
          // as "half off" forever.
          onRunningChanged: if (!running) pip.opacity = 1
        }
      }

      Text {
        id: label
        anchors { left: caret.right; right: pip.left; top: parent.top
                  rightMargin: 8; topMargin: 5 }
        text: String(modelData.label || "(no title)")
        // The current conversation reads at full strength even when the
        // selection has arrowed away from it, so "where was I" survives
        // browsing the list.
        color: (parent.on || parent.here) ? Theme.text : Theme.subtext0
        elide: Text.ElideRight
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }

      Text {
        id: meta
        anchors { left: label.left; top: label.bottom; topMargin: 1 }
        // "exchanges", not "msg": the store counts USER messages only
        // (store.ts summarise), so this figure is half the row count the panel
        // shows for the same conversation -- live, 119 here against 235 there.
        // Two counts of the same thing on two surfaces is a bug report waiting
        // to happen; naming the unit stops it being one.
        // STATUS ONLY. "open" used to live here and won the slot whenever the
        // current conversation was also working, which is exactly when its
        // status was worth reading. Focus moved to the gutter caret; this line
        // now answers one question and always answers it.
        text: root.when(modelData.at, root.nonce) + "  ·  " + (modelData.turns || 0) + " exchanges"
            + (modelData.busy ? "  ·  running now" : "")
        // The busy row's meta line is lifted out of the grey the other rows
        // sit in. "running now" in overlay0 next to "12 exchanges" in overlay0
        // is information you have to go looking for.
        color: modelData.busy ? root.accent : parent.here ? Theme.subtext0 : Theme.overlay0
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta - 2
        renderType: Text.QtRendering
      }
    }
  }
}
