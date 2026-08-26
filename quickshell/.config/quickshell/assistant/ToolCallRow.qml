import QtQuick
import ".."

// One tool call, kept in the transcript after it finishes.
//
// This is the panel's version of Claude Code's indented tool block, and it is
// there for the same reason: an agent that says "thinking…" and then hands back
// a number is asking to be trusted, while one that shows the command it ran has
// already proved it. The name is typeset as a name and the argument as what it
// is -- a path, a pattern, a shell line -- because at 460px the argument is the
// part that says WHICH file, and it is the part that gets cut if anything does.
//
// The block keeps its duration once the call returns. That is the only place in
// the panel where "how long did that take" survives the turn.
Item {
  id: row

  // { name, arg, t0, ms } from PiSession.toolLog.
  property var call: null
  // Still running: no duration to print yet, so the block pulses instead.
  property bool live: false
  // The shell's own "active" colour, and it never changes: mauve means the
  // agent touched the machine, sapphire means it was talking to the model.
  property color accent: Theme.accent

  implicitHeight: block.implicitHeight
  height: implicitHeight

  Fmt { id: fmt }

  Rectangle {
    id: block
    anchors { left: parent.left; right: parent.right }
    implicitHeight: inner.implicitHeight + 12
    radius: 6
    // Half-strength surface0: the block has to read as a distinct object
    // against the answer text without becoming heavier than the answer.
    color: Theme.alpha(Theme.surface0, 0.55)

    // The accent edge is what makes a run of calls read as one column of
    // machine activity rather than as three loose boxes.
    Rectangle {
      anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
      width: 2
      radius: 1
      color: row.accent
      opacity: row.live ? 1 : 0.55

      Behavior on opacity {
        NumberAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
      }
    }

    Column {
      id: inner
      anchors { left: parent.left; right: parent.right; top: parent.top
                leftMargin: 12; rightMargin: 10; topMargin: 6 }
      spacing: 1

      // ------------------------------------------------------ name + cost
      Item {
        width: parent.width
        height: name.implicitHeight

        Text {
          id: name
          anchors { left: parent.left; right: cost.left; rightMargin: 8 }
          text: "⟩ " + (row.call ? row.call.name : "")
          color: row.accent
          elide: Text.ElideRight
          font.family: Style.font.panelMono
          font.pixelSize: Style.font.panelMeta
          font.weight: Style.font.boldWeight
          renderType: Text.QtRendering
        }

        Text {
          id: cost
          anchors.right: parent.right
          anchors.baseline: name.baseline
          // While it runs there is no number to give, so it says so; the
          // running total for the whole turn is on the rail above the composer.
          text: row.live ? "running" : (row.call ? fmt.duration(row.call.ms) : "")
          color: Theme.overlay0
          font.family: Style.font.panelMono
          font.pixelSize: Style.font.panelMeta
          renderType: Text.QtRendering

          // A slow fade in place, not a blink: the same heartbeat the mark and
          // the bar dot keep, so everything alive on this surface breathes
          // together. Gated on `live`, so a finished block animates nothing.
          SequentialAnimation {
            running: row.live
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation {
              target: cost; property: "opacity"; to: 0.35
              duration: Style.ori.breathMs / 2; easing.type: Style.anim.easingSmooth
            }
            NumberAnimation {
              target: cost; property: "opacity"; to: 1
              duration: Style.ori.breathMs / 2; easing.type: Style.anim.easingSmooth
            }
          }

          onOpacityChanged: if (!row.live && opacity !== 1) opacity = 1
        }
      }

      // ------------------------------------------------------------- what
      Text {
        width: parent.width
        visible: text !== ""
        text: row.call ? String(row.call.arg) : ""
        color: Theme.subtext0
        wrapMode: Text.WrapAnywhere
        // Two lines is the whole budget: a command long enough to need three
        // is one whose tail no longer identifies it anyway.
        maximumLineCount: 2
        elide: Text.ElideRight
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }
    }
  }
}
