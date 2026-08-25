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

  // The panel's frame clock, handed down rather than started again here: it
  // already runs only while a turn is in flight with the panel on screen, and
  // it is the only thing that makes the live batch's elapsed number move. A
  // clock of our own would be a second thing to stop at idle.
  property real nowMs: 0

  // The answer text, placeholder included: a turn with nothing in it yet must
  // not collapse to zero height, or the list jumps the moment the first token
  // lands.
  readonly property string bodyText: !turn ? ""
    : turn.text !== "" ? turn.text
    : (pending ? " " : "")

  // Whether this turn's tool batch is open. One flag per turn, and it starts
  // closed: the detail is a click away, not a wall.
  property bool toolsOpen: false

  width: ListView.view ? ListView.view.width : 0
  height: user ? pill.height : answer.height

  Fmt { id: fmt }

  // ------------------------------------------------------------- vocabulary
  // A batch is a COUNT plus the latest action, never a list of rows -- the same
  // shape the other assistant settles a turn into. Each kind of call carries
  // three words: what it is doing, what it did, and the noun it is counted in,
  // so a settled batch reads as English ("Ran 3 commands", "Read 1 file")
  // rather than as an inventory of tool names.
  function kindOf(name) {
    var n = String(name).toLowerCase()
    if (n.indexOf("search") >= 0 || n.indexOf("grep") >= 0 || n.indexOf("glob") >= 0) return "search"
    if (n.indexOf("write") >= 0 || n.indexOf("edit") >= 0) return "edit"
    if (n.indexOf("read") >= 0 || n.indexOf("cat") >= 0) return "read"
    if (n.indexOf("fetch") >= 0) return "fetch"
    if (n.indexOf("bash") >= 0 || n.indexOf("shell") >= 0 || n.indexOf("exec") >= 0) return "bash"
    return "other"
  }

  function liveVerb(kind) {
    return kind === "search" ? "Searching"
      : kind === "edit" ? "Editing"
      : kind === "read" ? "Reading"
      : kind === "fetch" ? "Fetching"
      : "Running"
  }

  // Past tense, and both numbers right: "Ran 1 command", never "Ran 1 commands".
  function pastLabel(kind, n) {
    if (kind === "read") return "Read " + n + (n === 1 ? " file" : " files")
    if (kind === "edit") return "Edited " + n + (n === 1 ? " file" : " files")
    if (kind === "fetch") return "Fetched " + n + (n === 1 ? " page" : " pages")
    // "Searched 3 searches" stutters; the noun is the part that says what kind.
    if (kind === "search") return "Ran " + n + (n === 1 ? " search" : " searches")
    if (kind === "bash") return "Ran " + n + (n === 1 ? " command" : " commands")
    // A batch of mixed kinds has no one noun, so it is counted in steps.
    return "Ran " + n + (n === 1 ? " step" : " steps")
  }

  // The kind of the whole batch, or "mixed" when it had more than one.
  readonly property string batchKind: {
    var k = ""
    for (var i = 0; i < calls.length; i++) {
      var ki = kindOf(calls[i].name)
      if (k === "") k = ki
      else if (k !== ki) return "mixed"
    }
    return k === "" ? "other" : k
  }

  // A call is still open when it has no duration stamped yet. Only the last
  // call of the turn being written can be.
  readonly property bool batchLive: pending && calls.length > 0
    && calls[calls.length - 1].ms === 0

  // Time spent in tools this turn. The open call is measured against the
  // panel's clock, so this counts up by itself while it runs and freezes at the
  // moment the call returns.
  readonly property real batchMs: {
    var t = 0
    for (var i = 0; i < calls.length; i++) {
      var c = calls[i]
      t += c.ms > 0 ? c.ms : Math.max(0, turnItem.nowMs - c.t0)
    }
    return t
  }

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
      font.pixelSize: Style.font.panelBody
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
        font.pixelSize: Style.font.panelMeta
        renderType: Text.NativeRendering
      }

      // ----------------------------------------------------------- tools
      // ONE line for the whole batch, not one block per call. While the turn
      // runs it is rewritten in place -- the current action, then a quiet tail
      // of target, elapsed and a step COUNT -- and when the turn settles it
      // freezes into a single past-tense line. Three commands is three lines of
      // command text forever otherwise, which on a 460px card buries the answer.
      //
      // The verbosity is not deleted, only folded: clicking the line runs the
      // drawer open on the real ToolCallRow blocks, commands and all.
      Item {
        id: batch
        width: col.width
        visible: turnItem.calls.length > 0
        height: summary.height + drawer.height

        Column {
          id: summary
          anchors { left: parent.left; right: parent.right; top: parent.top }
          spacing: 1

          Item {
            width: parent.width
            height: head.implicitHeight

            Text {
              id: head
              anchors { left: parent.left; right: chevron.left; rightMargin: 8 }
              // Live: what it is doing this second. Settled: what it did, in
              // total. The tool name only earns a word when the verb does not
              // already contain it -- "Running bash", but just "Reading".
              text: {
                if (!turnItem.batchLive)
                  return "⟩ " + turnItem.pastLabel(turnItem.batchKind, turnItem.calls.length)
                    + (fmt.duration(turnItem.batchMs) !== ""
                        ? " · " + fmt.duration(turnItem.batchMs) : "")
                var last = turnItem.calls[turnItem.calls.length - 1]
                var kind = turnItem.kindOf(last.name)
                var verb = turnItem.liveVerb(kind)
                return "⟩ " + (kind === "bash" || kind === "other"
                  ? verb + " " + String(last.name).toLowerCase() : verb) + "…"
              }
              color: Theme.accent
              elide: Text.ElideRight
              font.family: Style.font.family
              font.pixelSize: Style.font.panelMeta
              font.weight: Style.font.boldWeight
              renderType: Text.NativeRendering

              // The same breath the spine and the bar dot keep, so the line
              // that is still being rewritten is visibly the live one. Gated on
              // `batchLive`, so a settled batch animates nothing.
              SequentialAnimation {
                running: turnItem.batchLive
                loops: Animation.Infinite
                alwaysRunToEnd: true
                NumberAnimation {
                  target: head; property: "opacity"; to: 0.45
                  duration: Style.ori.breathMs / 2; easing.type: Style.anim.easingSmooth
                }
                NumberAnimation {
                  target: head; property: "opacity"; to: 1
                  duration: Style.ori.breathMs / 2; easing.type: Style.anim.easingSmooth
                }
              }

              onOpacityChanged: if (!turnItem.batchLive && opacity !== 1) opacity = 1
            }

            // The disclosure. It points down once the drawer is open, and it is
            // the only thing on the line that says the detail still exists.
            Text {
              id: chevron
              anchors.right: parent.right
              anchors.baseline: head.baseline
              text: "›"
              color: Theme.overlay0
              rotation: turnItem.toolsOpen ? 90 : 0
              transformOrigin: Item.Center
              font.family: Style.font.family
              font.pixelSize: Style.font.panelMeta
              renderType: Text.NativeRendering

              Behavior on rotation {
                NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing }
              }
            }
          }

          // The stat tail: everything that is NOT the current action, in one
          // quiet line. It counts the steps rather than enumerating them --
          // that is the whole point of the collapse.
          Text {
            width: parent.width
            visible: turnItem.batchLive
            text: {
              if (!turnItem.batchLive) return ""
              var parts = []
              var last = turnItem.calls[turnItem.calls.length - 1]
              if (String(last.arg) !== "") parts.push(String(last.arg))
              var d = fmt.duration(turnItem.batchMs)
              if (d !== "") parts.push(d)
              parts.push(turnItem.calls.length
                + (turnItem.calls.length === 1 ? " step" : " steps"))
              return parts.join(" · ")
            }
            color: Theme.overlay0
            elide: Text.ElideRight
            maximumLineCount: 1
            font.family: Style.font.family
            font.pixelSize: Style.font.panelMeta
            renderType: Text.NativeRendering
          }
        }

        // The whole summary is the affordance, not a hit-box the size of a
        // chevron. It does not cover the drawer: clicking a command you opened
        // the drawer to read should not shut it again.
        MouseArea {
          anchors.fill: summary
          cursorShape: Qt.PointingHandCursor
          onClicked: turnItem.toolsOpen = !turnItem.toolsOpen
        }

        // ------------------------------------------------------- the detail
        // Collapsed by animating to zero height, not by being switched off --
        // the animation is what removes the row, the same idiom the
        // notification cards close with.
        Item {
          id: drawer
          anchors { left: parent.left; right: parent.right; top: summary.bottom }
          height: turnItem.toolsOpen ? detail.implicitHeight : 0
          clip: true
          // At rest and closed it leaves the column entirely, so it cannot pay
          // for a row of spacing it does not use.
          visible: turnItem.toolsOpen || height > 0.01

          Behavior on height {
            NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
          }

          Column {
            id: detail
            width: parent.width
            topPadding: 4
            spacing: 4

            Repeater {
              model: turnItem.calls

              delegate: ToolCallRow {
                required property var modelData
                width: detail.width
                call: modelData
                // Only the last call of the turn being written can still be
                // open; `ms` is stamped the moment a call returns.
                live: turnItem.pending && modelData.ms === 0
                // Deliberately NOT the panel's live accent: a tool block is
                // mauve for good, so scrolling back you can tell at a glance
                // which parts of a conversation touched the machine. Only the
                // panel chrome tracks the state of the turn in flight.
              }
            }
          }
        }
      }

      // ------------------------------------------------------------ said
      // The answer, cut at its pictures. Ori shows a file by writing
      // `![alt](/path.png)` and the picture is painted where the syntax stood
      // (Fmt.split decides what counts; only local absolute paths do).
      //
      // A run of pieces rather than one Text because a QML Text cannot put an
      // ITEM inside its flow -- there is no way to hang an Image off a
      // character position -- so the text is ended before the picture and
      // resumed after it. An answer with no image is one piece and behaves
      // exactly as it did before.
      Column {
        id: body
        width: parent.width
        spacing: 6

        Repeater {
          // Recomputed per token while the answer streams, which rebuilds
          // these pieces each time. That is affordable because it always was:
          // the single Text this replaced re-laid out the whole answer per
          // token too, and an image re-created against Qt's pixmap cache
          // repaints in the same frame.
          model: fmt.split(turnItem.bodyText, turnItem.pending)

          delegate: Item {
            id: piece
            required property var modelData

            width: body.width
            implicitHeight: piece.modelData.image ? shot.implicitHeight : chunk.implicitHeight
            height: implicitHeight

            Text {
              id: chunk
              width: parent.width
              visible: !piece.modelData.image
              text: piece.modelData.image ? "" : piece.modelData.text
              color: Theme.text
              wrapMode: Text.Wrap
              // The model answers in markdown, so render it -- otherwise every
              // emphasis arrives as literal **asterisks** and every code span as
              // backticks. Mid-stream an unclosed marker renders as plain text and
              // settles the moment its partner arrives, which is invisible at these
              // token rates.
              textFormat: Text.MarkdownText
              font.family: Style.font.family
              font.pixelSize: Style.font.panelBody
              renderType: Text.NativeRendering
            }

            InlineImage {
              id: shot
              width: parent.width
              visible: piece.modelData.image
              source: piece.modelData.image ? piece.modelData.source : ""
              alt: piece.modelData.image ? piece.modelData.alt : ""
            }
          }
        }
      }

      // ------------------------------------------------------------ cost
      // What the answer cost, kept with the answer. The rail above the
      // composer only ever describes the turn in flight; this is how a turn
      // from ten minutes ago still says how long it took and what it touched.
      // The diamond is Ori's own signature, the same glyph as the bar's.
      Text {
        width: parent.width
        visible: !turnItem.user && !turnItem.pending && turnItem.cost !== null
        // The tool count used to ride here too; the settled batch line above now
        // states it in words, and saying "3 tools" again two rows later is the
        // kind of noise this whole change is about.
        text: "◇ " + fmt.duration(turnItem.cost ? turnItem.cost.ms : 0)
          + (turnItem.cost && turnItem.cost.tokens > 0
              ? " · " + fmt.tokens(turnItem.cost.tokens) + " tok" : "")
        color: Theme.overlay0
        elide: Text.ElideRight
        font.family: Style.font.family
        font.pixelSize: Style.font.panelMeta
        renderType: Text.NativeRendering
      }
    }
  }
}
