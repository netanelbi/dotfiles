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
// Those rows carry `busy`, which the meta line says out loud -- picking one is
// instant, and it would be a lie to show it as just another old thread.
Rectangle {
  id: root

  property color accent: Theme.mauve
  // Handed back when this closes, so the caret returns to where you were.
  property var returnFocus: null

  readonly property var sessions: OriClient.sessions
  property int current: 0

  color: Theme.mantle
  opacity: 0
  visible: opacity > 0
  radius: 6

  Behavior on opacity {
    NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
  }

  function open() {
    if (root.sessions.length === 0) return false
    root.current = 0
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
    if (s) OriClient.resume(s.id)
  }

  // ------------------------------------------------------------------ label
  // Relative, because "3 min ago" is what you are actually looking for after a
  // shell reload -- an absolute clock time makes you do the subtraction. Past a
  // day it flips to the date, where the subtraction stops being useful.
  function when(at) {
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
    text: "resume  ·  ↑↓ move   ⏎ open   esc back"
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
      color: on ? Theme.surface1 : "transparent"

      // The selected row is marked on its edge rather than by colour alone --
      // at this size a surface tint is easy to lose against the card behind it.
      Rectangle {
        width: 2
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom
                  leftMargin: 2; topMargin: 3; bottomMargin: 3 }
        radius: 1
        color: root.accent
        opacity: parent.on ? 1 : 0
      }

      // Held in memory, so picking it is instant and -- if `busy` -- it is
      // working RIGHT NOW behind this list. The meta line said so in grey text
      // two sizes below the title, which is not where an eye scanning titles
      // ever goes. A pip on the row edge is read without being looked for.
      //
      // Two states, not one: a parked-and-idle conversation is still worth
      // marking, because "instant, already loaded" is different from "cold
      // resume off disk" and the old list drew them identically.
      Rectangle {
        id: pip
        width: 6; height: 6; radius: 3
        anchors { right: parent.right; top: parent.top; rightMargin: 10; topMargin: 9 }
        visible: modelData.live === true
        color: modelData.busy ? root.accent : Theme.overlay0

        SequentialAnimation on opacity {
          // Bound to `running`, not started once: a delegate is recycled by the
          // view, and an animation left running on a pooled item keeps burning
          // frames for a row nobody is looking at.
          running: pip.visible && modelData.busy === true
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
        anchors { left: parent.left; right: pip.left; top: parent.top
                  leftMargin: 12; rightMargin: 8; topMargin: 5 }
        text: String(modelData.label || "(no title)")
        color: parent.on ? Theme.text : Theme.subtext0
        elide: Text.ElideRight
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }

      Text {
        id: meta
        anchors { left: label.left; top: label.bottom; topMargin: 1 }
        text: root.when(modelData.at) + "  ·  " + (modelData.turns || 0) + " msg"
            + (modelData.busy ? "  ·  running now"
                              : modelData.live ? "  ·  loaded" : "")
        // The busy row's meta line is lifted out of the grey the other rows
        // sit in. "running now" in overlay0 next to "12 msg" in overlay0 is
        // information you have to go looking for.
        color: modelData.busy ? root.accent : Theme.overlay0
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta - 2
        renderType: Text.QtRendering
      }
    }
  }
}
