import QtQuick
import ".."

// One turn of the conversation.
//
// Who said what is carried by shape, not by labels: a question is a pill that
// hangs off the right edge, an answer is a full-width column hung on a rail
// down the left. The rail is the load-bearing part -- it gives the answer, its
// reasoning, its tool calls and its cost one visible spine, so a scrolled-back
// transcript reads as a sequence of machine actions rather than as loose text.
// It is also the liveness cue: the rail of the turn being written breathes,
// and it is the only one that does.
//
// Order inside an answer is the order things happened: what it thought, what it
// ran, what it said, what it cost.
Item {
  id: turnItem

  required property int index
  property color accent: Theme.sapphire

  // The list is BottomToTop, so index 0 is the NEWEST row; read the model back
  // through `count - 1 - index`.
  readonly property int row: PiSession.turns.count - 1 - index
  readonly property var turn: row >= 0 && row < PiSession.turns.count
    ? PiSession.turns.get(row) : null

  readonly property bool user: turn ? turn.role === "user" : false
  readonly property bool pending: turn ? turn.pending === true : false
  readonly property var calls: PiSession.toolLog[row] || []
  // { ms, tokens } once the turn has settled.
  readonly property var cost: PiSession.turnCost[row] || null

  width: ListView.view ? ListView.view.width : 0
  height: user ? pill.height : answer.height

  Fmt { id: fmt }

  // ------------------------------------------------------------------- ask
  Rectangle {
    id: pill
    visible: turnItem.user

    width: Math.min(turnItem.width * 0.85, said.implicitWidth + 24)
    x: turnItem.width - width
    height: said.implicitHeight + 16
    radius: 10
    // The one blunted corner points back at the composer the message came
    // from, the way the notification cards enter from the edge they arrived on.
    bottomRightRadius: 3
    color: Theme.surface1

    Text {
      id: said
      anchors { left: parent.left; right: parent.right; top: parent.top
                leftMargin: 12; rightMargin: 12; topMargin: 8 }
      text: turnItem.turn ? turnItem.turn.text : ""
      color: Theme.text
      wrapMode: Text.Wrap
      font.family: Style.font.family
      font.pixelSize: Style.font.size
      renderType: Text.NativeRendering
    }
  }

  // ---------------------------------------------------------------- answer
  Item {
    id: answer
    visible: !turnItem.user
    width: turnItem.width
    height: col.implicitHeight + 6

    // The spine. Solid once the turn is done, breathing while it is being
    // written -- the same 2600ms breath as the mark in the header and the dot
    // in the bar, so everything alive on this desktop is alive at one rate.
    Rectangle {
      id: spine
      x: 0
      y: 1
      width: 2
      height: parent.height - 4
      radius: 1
      color: turnItem.pending ? turnItem.accent : Theme.surface1

      Behavior on color {
        ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
      }

      SequentialAnimation {
        running: turnItem.pending
        loops: Animation.Infinite
        alwaysRunToEnd: true
        NumberAnimation {
          target: spine; property: "opacity"; to: 0.3
          duration: Style.ori.breathMs / 2; easing.type: Style.anim.easingSmooth
        }
        NumberAnimation {
          target: spine; property: "opacity"; to: 1
          duration: Style.ori.breathMs / 2; easing.type: Style.anim.easingSmooth
        }
      }

      // Leaving the breath mid-cycle would strand the spine at whatever opacity
      // the animation happened to reach.
      onOpacityChanged: if (!turnItem.pending && opacity !== 1) opacity = 1
    }

    Column {
      id: col
      x: 14
      width: parent.width - 14
      spacing: 6

      // ------------------------------------------------------- reasoning
      // Shown only while the answer itself is still empty: it arrives ~300ms
      // in, so it is the loading state, and unlike a spinner it tells you
      // within a second whether it understood you. Dropped once real text
      // starts -- the answer is what you asked for.
      Text {
        width: parent.width
        visible: !turnItem.user && turnItem.turn
          && turnItem.turn.text === "" && turnItem.turn.thinking !== ""
        text: turnItem.turn ? turnItem.turn.thinking : ""
        color: Theme.overlay0
        font.italic: true
        wrapMode: Text.Wrap
        font.family: Style.font.family
        font.pixelSize: Style.font.small
        renderType: Text.NativeRendering
      }

      // ----------------------------------------------------------- tools
      Repeater {
        model: turnItem.calls

        delegate: ToolCallRow {
          required property var modelData
          width: col.width
          call: modelData
          // Only the last call of the turn being written can still be open;
          // `ms` is stamped the moment a call returns.
          live: turnItem.pending && modelData.ms === 0
          // Deliberately NOT the panel's live accent: a tool block is mauve for
          // good, so scrolling back you can tell at a glance which parts of a
          // conversation touched the machine. Only the panel chrome tracks the
          // state of the turn in flight.
        }
      }

      // ------------------------------------------------------------ said
      Text {
        id: body
        width: parent.width
        // A turn with nothing in it yet must not collapse to zero height, or
        // the list jumps the moment the first token lands.
        text: !turnItem.turn ? ""
          : turnItem.turn.text !== "" ? turnItem.turn.text
          : (turnItem.pending ? " " : "")
        color: Theme.text
        wrapMode: Text.Wrap
        // The model answers in markdown, so render it -- otherwise every
        // emphasis arrives as literal **asterisks** and every code span as
        // backticks. Mid-stream an unclosed marker renders as plain text and
        // settles the moment its partner arrives, which is invisible at these
        // token rates.
        textFormat: Text.MarkdownText
        font.family: Style.font.family
        font.pixelSize: Style.font.size
        renderType: Text.NativeRendering
      }

      // ------------------------------------------------------------ cost
      // What the answer cost, kept with the answer. The rail above the
      // composer only ever describes the turn in flight; this is how a turn
      // from ten minutes ago still says how long it took and what it touched.
      // The diamond is Ori's own signature, the same glyph as the bar's.
      Text {
        width: parent.width
        visible: !turnItem.user && !turnItem.pending && turnItem.cost !== null
        text: "◇ " + fmt.duration(turnItem.cost ? turnItem.cost.ms : 0)
          + (turnItem.cost && turnItem.cost.tokens > 0
              ? " · " + fmt.tokens(turnItem.cost.tokens) + " tok" : "")
          + (turnItem.calls.length > 0
              ? " · " + turnItem.calls.length
                + (turnItem.calls.length === 1 ? " tool" : " tools")
              : "")
        color: Theme.overlay0
        elide: Text.ElideRight
        font.family: Style.font.family
        font.pixelSize: Style.font.tiny
        renderType: Text.NativeRendering
      }
    }
  }
}
