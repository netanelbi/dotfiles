import QtQuick
import ".."

// One turn of the conversation. A question is a pill hung off the right edge; an
// answer is a full-width column on a rail down the left, and the rail of the turn
// being written breathes.
//
// Order inside an answer is the order things happened -- the text is cut where
// each tool call ran, so a working turn reads speak, run, speak, run. Which is
// right WHILE it happens and wrong once it has: a finished turn is not a
// recording of a process, it is an answer. So the moment a turn settles,
// everything up to its last tool call rolls up into one receipt line and the
// answer takes the card. Nothing is thrown away -- the receipt says what the work
// was, in the words the batch lines used, and opens back onto all of it.
Item {
  id: turnItem

  required property int index
  property color accent: Theme.sapphire

  // The list is BottomToTop, so index 0 is the NEWEST row.
  readonly property int row: PiSession.turns.count - 1 - index
  readonly property var turn: row >= 0 && row < PiSession.turns.count
    ? PiSession.turns.get(row) : null

  readonly property bool user: turn ? turn.role === "user" : false
  readonly property bool pending: turn ? turn.pending === true : false
  readonly property var calls: PiSession.toolLog[row] || []
  // { ms, tokens } once the turn has settled.
  readonly property var cost: PiSession.turnCost[row] || null

  // The turn, as pieces, and where its answer starts (Fmt.split / Fmt.answerAt).
  // Rebuilt per token while the answer streams, which is affordable because it
  // always was: the single Text this replaced re-laid out the whole answer too.
  readonly property var pieces: fmt.split(bodyText, pending, calls)
  readonly property int cut: fmt.answerAt(pieces)

  // A turn in flight shows everything -- watching it work IS the point while it
  // works, and there is no answer yet to find. The fold is what settling looks
  // like.
  //
  // A turn that ended ON a tool call has no answer half. This used to refuse to
  // fold it, on the grounds that folding a turn into nothing is worse than not
  // folding -- but the receipt renders either way, so the result was the receipt
  // AND the work it summarises, on screen together. Steering mid-turn produces
  // exactly that shape, and it read as the panel rendering the turn twice.
  // A turn with no answer folds to its receipt, which is not nothing: it is the
  // one line that says what happened, and the caret unrolls it.
  readonly property bool folded: !user && !pending && !workOpen && cut > 0
  readonly property var shown: folded ? pieces.slice(cut) : pieces

  // ------------------------------------------------------------ piece model
  // `shown` is a NEW ARRAY every time anything changes -- per token while the
  // answer streams, and again the moment a tool call is logged. A Repeater
  // handed a fresh JS array does not update its rows: it resets, destroying and
  // recreating EVERY delegate. So one call arriving rebuilt the whole turn, each
  // TextEdit re-laying out its entire answer, and that is the flicker you see
  // when a batch line ticks from "Ran 2 commands" to "Ran 3".
  //
  // ---------------------------------------------------------------- churn
  // The Repeater below is driven by a COUNT, not by `shown` itself, and the
  // delegate looks its own piece up by index. That is the whole fix for the
  // flicker the user reported -- "the moment a new bash is running it says 2
  // commands run then switch to 3, there is a flicker like something is
  // rendering and then switching and settling".
  //
  // `pieces` is `fmt.split(...)`, which builds a BRAND NEW JS array on every
  // token and every tool-call update. A Repeater handed a fresh array does not
  // update its rows -- it resets: every delegate destroyed and rebuilt, every
  // TextEdit re-laying out the whole answer from scratch. That teardown and
  // rebuild IS the render-then-settle flash.
  //
  // A count is an int. When a token arrives and the piece list is the same
  // LENGTH, the binding produces the same int, no change is signalled, and not
  // one delegate is touched. The delegates' own `m` bindings do re-evaluate
  // against the new array, but assigning a TextEdit the string it already holds
  // is a no-op inside Qt -- so an unchanged piece costs one property read and an
  // equality test. Only a real structural change (a piece appended, or the fold
  // slicing some away) creates or destroys anything, and then only the
  // difference.
  //
  // Measured, not assumed. ../fixtureE.py drives a twelve-step turn with three
  // tool calls landing one at a time -- the exact moment the user described --
  // and the piece delegate logs its own creation. Two builds differing ONLY in
  // this model line:
  //   model: turnItem.shown          50 piece delegates built
  //   model: turnItem.shown.length   22
  // The outer TurnDelegate is built twice in both runs, so that residue is
  // genuine structural growth inside one turn (the answer really does gain
  // pieces as each batch lands), not the list recycling rows underneath.
  //
  // A ListModel was tried first and is the wrong tool twice over: with
  // `dynamicRoles: true` the roles are never injected into the delegate, so
  // `required property var m` cannot resolve and NOTHING is built (the panel
  // renders every turn as a bare receipt line with no answer); and without
  // dynamicRoles a ListModel flattens nested objects, so a piece -- which is a
  // different shape per kind, and carries a `calls` array -- cannot live in a
  // role at all.
  //
  // The empty piece is a stable object, not a fresh `{}` per evaluation: the
  // index can briefly sit past the end of a shrinking array, and a literal there
  // would hand every delegate a new identity on every pass.
  readonly property var noPiece: ({})

  // The ledger of a settled turn on one line -- what it did, how long it took,
  // what it cost -- in the words the batch lines already print, with ONE label
  // over every call in the fold ("Ran 1 command · Ran 2 steps" is the inventory
  // it replaces). Duration and tokens used to sit in a `◇` footer UNDER the
  // answer, a strange place for the receipt of what you just read.
  function receipt() {
    var all = [], ms = 0
    for (var i = 0; i < cut; i++) {
      if (!pieces[i].tool) continue
      all = all.concat(pieces[i].calls)
      ms += batchMs(pieces[i].calls)
    }
    var parts = []
    if (all.length > 0) parts.push(pastLabel(batchKind(all), all.length))
    // The turn's total when the engine recorded one; the time inside the tool
    // calls is all a restored transcript can offer.
    var d = fmt.duration(cost ? cost.ms : ms)
    if (d !== "") parts.push(d)
    if (cost && cost.tokens > 0) parts.push(fmt.tokens(cost.tokens) + " tok")
    return "\u25c7 " + parts.join(" · ")
  }

  // The panel's frame clock, handed down rather than started again here: it runs
  // only while a turn is in flight with the panel on screen, and a clock of our
  // own would be a second thing to stop at idle.
  property real nowMs: 0

  // One breath, shared: a cosine off that clock, so everything alive on this
  // card rises and falls together instead of each running its own loop.
  readonly property real breath:
    0.65 + 0.35 * Math.cos(2 * Math.PI * nowMs / Style.ori.breathMs)

  // The answer text, placeholder included: a turn with nothing in it yet must not
  // collapse to zero height, or the list jumps on the first token. One SPACE, not
  // a word or a spinner -- the panel header already names the state in a fixed
  // place, and a second announcement changed a row's height mid-flight.
  readonly property string bodyText: !turn ? ""
    : turn.text !== "" ? turn.text
    : (pending ? " " : "")

  // Whether this turn's work is unrolled. ONE control for the whole turn, up on
  // the receipt: every batch used to carry a drawer of its own as well, which is
  // two nested disclosures on a 460px card, and the second one only ever said
  // what the first already summarised. Unrolled means unrolled -- narration,
  // batch lines and the commands themselves.
  property bool workOpen: false

  width: ListView.view ? ListView.view.width : 0
  height: user ? pill.height : answer.height

  Fmt { id: fmt }

  // ------------------------------------------------------------- vocabulary
  // A batch is a COUNT plus the latest action, never a list of rows: each kind of
  // call carries what it is doing, what it did and the noun it is counted in, so
  // it reads as English. The receipt is built from the same words.
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
    return ({ search: "Searching", edit: "Editing", read: "Reading",
              fetch: "Fetching" })[kind] || "Running"
  }

  // Past tense, and both numbers right: "Ran 1 command", never "Ran 1 commands".
  // "Searched 3 searches" stutters, so a search is counted in searches; a batch
  // of mixed kinds has no one noun and is counted in steps.
  readonly property var noun: ({ read: "Read file", edit: "Edited file",
    fetch: "Fetched page", search: "Ran search", bash: "Ran command" })
  function pastLabel(kind, n) {
    var w = String(noun[kind] || "Ran step").split(" ")
    return w[0] + " " + n + " " + w[1]
      + (n === 1 ? "" : w[1] === "search" ? "es" : "s")
  }

  // Functions over ONE batch, not properties over the turn: a turn now has as
  // many batches as it had things to say between its tool calls.

  // The kind of a batch, or "mixed" when it had more than one.
  function batchKind(cs) {
    var k = ""
    for (var i = 0; i < cs.length; i++) {
      var ki = kindOf(cs[i].name)
      if (k === "") k = ki
      else if (k !== ki) return "mixed"
    }
    return k === "" ? "other" : k
  }

  // A call is still open when it has no duration stamped yet. Only the last
  // call of the turn being written can be, so only the last batch can be live.
  function batchLive(cs) {
    return pending && cs.length > 0 && cs[cs.length - 1].ms === 0
  }

  // Time spent in a batch. The open call is measured against the panel's clock,
  // so this counts up by itself and freezes when the call returns.
  function batchMs(cs) {
    var t = 0
    for (var i = 0; i < cs.length; i++) {
      var c = cs[i]
      if (c.ms > 0) { t += c.ms; continue }
      // t0 of 0 means UNKNOWN, not "the epoch": rehydrate() writes it that way,
      // and subtracting it from the panel's clock rendered `Ran 5 steps ·
      // 148974714m 11s`. A restored call contributes nothing instead.
      if (c.t0 > 0) t += Math.max(0, turnItem.nowMs - c.t0)
    }
    return t
  }

  // ------------------------------------------------------------------- ask
  // What the user attached: absolute paths for a paste, a label for anything
  // that never had a file (Fmt.attached explains which is which).
  readonly property var sent: turn && turn.images
    ? fmt.attached(turn.images) : []

  // The width thumbnails are laid out in: the pill's WIDEST possible content,
  // not its actual width, which would be measuring the pill with the pill.
  readonly property int sentWidth: Math.round(width * 0.85) - 24

  Rectangle {
    id: pill
    visible: turnItem.user

    width: Math.min(turnItem.width * 0.85,
                    Math.max(said.implicitWidth, shots.implicitWidth) + 24)
    x: turnItem.width - width
    height: asked.implicitHeight + 16
    radius: 10
    // The one blunted corner points back at the composer the message came
    // from, the way the notification cards enter from the edge they arrived on.
    bottomRightRadius: 3
    color: Theme.surface1

    Column {
      id: asked
      anchors { left: parent.left; right: parent.right; top: parent.top
                leftMargin: 12; rightMargin: 12; topMargin: 8 }
      spacing: 6

      Text {
        id: said
        width: parent.width
        // An image-only question is a real thing, and an empty Text would
        // still pay for a line of height.
        visible: text !== ""
        text: turnItem.turn ? turnItem.turn.text : ""
        color: Theme.text
        wrapMode: Text.Wrap
        font.family: Style.font.panelFamily
        font.pixelSize: Style.font.panelBody
        // MEDIUM, and only here. "my input messages render a little blurry" is
        // this one Text and no other, and the geometry was measured clean before
        // anything was changed: pill x=66 w=374 h=60, the text at scene 104,214,
        // listW=440 -- every one an integer, so nothing was landing off the
        // device grid at 1.5x. What makes THIS text softer than the answer is
        // that it is the only prose on the card sitting on a LIGHT ground
        // (surface1), where the distance-field renderer's edge falloff eats a
        // larger share of an already thin stem. Measured over the bubble's own
        // glyph pixels, the share that are solid rather than partial coverage
        // goes 54.2% -> 64.8% with the new face at this weight
        // (../frames2/bubble-2x.png). renderType is NOT touched: NativeRendering
        // is what made this panel look thin at 1.5x in the first place.
        font.weight: Font.Medium
        renderType: Text.QtRendering
      }

      // ------------------------------------------------------- attachments
      // The picture you sent, under the words you sent with it -- the referent
      // of the draft's `[Image 1]` marker. Capped at HALF what an answer's
      // picture gets: that one is content, this one is a receipt. Every row
      // sizes to its OWN content, never to this column, because the pill is
      // sized from it -- taking width from the column collapsed an image-only
      // question to a 30px stub with its label out of the side.
      Column {
        id: shots
        spacing: 4

        Repeater {
          model: turnItem.sent

          delegate: Item {
            id: sent
            // `model` here is still the ARRAY turnItem.sent, so this row is
            // handed `modelData`, not a role. The piece Repeater below moved to
            // a count model and its delegate renamed this to `m`; this one was
            // renamed with it by mistake while its body still read modelData,
            // so every attachment resolved to undefined and no thumbnail drew.
            required property var modelData

            implicitWidth: sent.modelData.image ? thumb.implicitWidth : gone.width
            implicitHeight: sent.modelData.image ? thumb.implicitHeight : gone.implicitHeight
            width: implicitWidth
            height: implicitHeight

            InlineImage {
              id: thumb
              // The BOX, not the picture: it paints inside this and reports back.
              width: turnItem.sentWidth
              maxHeight: 120
              visible: sent.modelData.image
              source: sent.modelData.image ? sent.modelData.source : ""
              // No alt to give -- the user picked a file, they did not name it --
              // so an unreadable one falls back to the path.
              alt: ""
            }

            // Not a path, so nothing to paint: a resumed transcript, or a data
            // URI. Printed rather than dropped -- it is the only mark left that
            // this question carried a picture.
            Text {
              id: gone
              width: Math.min(turnItem.sentWidth, implicitWidth)
              visible: !sent.modelData.image
              text: sent.modelData.label
              color: Theme.subtext0
              font.italic: true
              elide: Text.ElideRight
              maximumLineCount: 1
              font.family: Style.font.panelMono
              font.pixelSize: Style.font.panelMeta
              renderType: Text.QtRendering
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- answer
  Item {
    id: answer
    visible: !turnItem.user
    width: turnItem.width
    height: col.implicitHeight + 6

    // The spine. Solid once the turn is done, breathing while it is written --
    // the same breath as the header mark and the bar dot, so everything alive on
    // this desktop is alive at one rate. Off the panel's frame clock rather than
    // a private animation, so no cycle is stranded mid-way when it settles.
    Rectangle {
      id: spine
      x: 0
      y: 1
      width: 2
      height: parent.height - 4
      radius: 1
      color: turnItem.pending ? turnItem.accent : Theme.surface1
      opacity: turnItem.pending ? turnItem.breath : 1

      Behavior on color {
        ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
      }
    }

    Column {
      id: col
      x: 14
      width: parent.width - 14
      spacing: 6

      // ------------------------------------------------------------ seam
      // The receipt: one line standing where the work was, with a hairline off it
      // to the card's edge -- the turn's header and its disclosure at once. A
      // rule rather than a fill or a frame, because the work is not somewhere
      // else on this card: it is NOT THERE, and a boundary is the honest mark for
      // that. One row where the work cost four, and at a squint every settled
      // turn is the same three beats: question, thin line, block of prose.
      Item {
        id: seam
        width: parent.width
        // A live turn has no receipt: nothing is settled to fold.
        visible: !turnItem.pending && (turnItem.cut > 0 || turnItem.cost !== null)
        height: visible ? 22 : 0

        Text {
          id: told
          anchors { left: parent.left; verticalCenter: parent.verticalCenter }
          // Capped, not anchored to the caret: a rule with 3px to cross is a
          // smudge, so the text gives way before the rule does.
          width: Math.min(implicitWidth, parent.width - 90)
          text: turnItem.receipt()
          color: Theme.overlay0
          elide: Text.ElideRight
          font.family: Style.font.panelMono
          font.pixelSize: Style.font.panelMeta
          renderType: Text.QtRendering
        }

        Rectangle {
          anchors { left: told.right; right: caret.left; leftMargin: 10; rightMargin: 10
                    verticalCenter: parent.verticalCenter }
          height: 1
          color: Theme.surface1
        }

        Text {
          id: caret
          anchors { right: parent.right; rightMargin: 4; verticalCenter: parent.verticalCenter }
          // Nothing to unroll on a turn that only thought.
          visible: turnItem.cut > 0
          text: "\u203a"
          color: Theme.overlay0
          rotation: turnItem.workOpen ? 90 : 0
          transformOrigin: Item.Center
          font.family: Style.font.panelMono
          font.pixelSize: Style.font.panelMeta
          renderType: Text.QtRendering

          Behavior on rotation {
            NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing }
          }
        }

        MouseArea {
          anchors.fill: parent
          enabled: turnItem.cut > 0
          cursorShape: Qt.PointingHandCursor
          onClicked: turnItem.workOpen = !turnItem.workOpen
        }
      }

      // ------------------------------------------------------------ said
      // What is on screen, in the order it happened. A picture is painted where
      // its `![alt](/path)` stood and a tool batch is ONE line standing where it
      // ran (Fmt.split cuts both out). A run of pieces rather than one Text
      // because a QML Text cannot put an ITEM inside its flow.
      Column {
        id: body
        width: parent.width
        spacing: 6

        Repeater {
          // The fold is a MODEL, not a layout: a folded turn has fewer pieces,
          // and nothing moves when it settles -- the list is BottomToTop, so the
          // answer keeps its place and the work above it stops being drawn.
          // The COUNT. See the `noPiece` block at the top of this file for why
          // this is not `turnItem.shown`.
          model: turnItem.shown.length

          delegate: Item {
            id: piece
            // ONLY index is required. An integer model provides nothing else,
            // and a delegate that requires a property the model cannot supply
            // fails to build -- silently, with a clean config log and a panel
            // missing every answer.
            required property int index
            readonly property var m: turnItem.shown[piece.index] || turnItem.noPiece

            readonly property bool isTool: piece.m.tool === true
            readonly property bool code: piece.m.code === true
            readonly property bool head: piece.m.head === true
            readonly property bool bullet: piece.m.bullet === true
            // Work, not the answer: on screen only while a turn is live or
            // unrolled, and quieter than the answer in both cases.
            readonly property bool aside: piece.m.aside === true
            readonly property var cs: piece.isTool ? (piece.m.calls || []) : []
            readonly property bool live: piece.isTool && turnItem.batchLive(piece.cs)
            // The commands themselves. Never while the batch is live: the line
            // above already names the command it is running this second, and
            // three rows of shell under it is what the collapse exists to stop.
            readonly property bool open: piece.isTool && turnItem.workOpen && !piece.live

            // A list marker sits in the gutter and the item hangs off it: 14px,
            // not the 55 Qt indents a markdown list by, which at 426px of measure
            // cost a bullet its last word. Two levels of nesting, then it stops.
            // 22, not 14. A bullet is one narrow glyph, but an ORDERED list
            // marker is "1." -- two characters of Adwaita Sans at 19 -- and at
            // 14 the number sat straight against its own item: `1.Wed 26 Aug`
            // in ../frames2/real-answers.png, on the user's own transcript.
            // Wide enough for "10." before it needs thinking about again.
            readonly property int gutter: piece.bullet ? 22 : 0
            readonly property int lead: (piece.m.depth || 0) * 22

            width: body.width
            implicitHeight: piece.isTool ? batch.height
              : piece.m.image ? shot.implicitHeight
              : chunk.y + chunk.implicitHeight + (piece.code ? 6 : 0)
            height: implicitHeight

            // A fenced block, on its own surface. Inside the markdown it was
            // prose-sized, container-less and CLIPPED: MarkdownText does not wrap
            // one, so a long command stopped dead at the card's edge.
            Rectangle {
              anchors.fill: parent
              visible: piece.code
              radius: 6
              color: Theme.alpha(Theme.surface0, 0.55)
            }

            // The bullet, in the gutter its item hangs off.
            Text {
              visible: piece.bullet
              x: piece.lead
              y: chunk.y
              width: piece.gutter
              text: piece.bullet ? piece.m.mark : ""
              color: Theme.overlay0
              font.family: Style.font.panelFamily
              font.pixelSize: Style.font.panelBody
              renderType: Text.QtRendering
            }

            // A TextEdit, not a Text, for ONE reason: Text has no selectedText
            // change signal, so there is no moment at which to notice a
            // selection. Read-only, and it never takes the keyboard.
            TextEdit {
              id: chunk
              x: piece.code ? 10 : piece.lead + piece.gutter
              // A heading takes its space from ABOVE: it belongs to what follows
              // it, and a column with one spacing cannot say so on its own.
              y: piece.head ? 12 : piece.code ? 6 : 0
              width: parent.width - x - (piece.code ? 10 : 0)
              visible: !piece.m.image
              // `|| ""`: a tool piece carries no text at all, and binding
              // undefined here logged "Unable to assign [undefined] to QString"
              // on every batch line drawn.
              text: piece.m.image ? "" : (piece.m.text || "")
              color: piece.aside ? Theme.overlay0 : Theme.text
              readOnly: true
              activeFocusOnPress: false
              wrapMode: TextEdit.Wrap
              // RICH text, not markdown. Fmt.rich() has already turned this
              // paragraph's `code`, **bold** and *emphasis* into spans, and the
              // whole point of doing it there is the one thing Qt's markdown
              // renderer will not allow: an inline code span at a size and in a
              // face of our choosing. An unclosed marker mid-stream renders
              // plain and settles on its partner exactly as before. PlainText
              // for a fence, where markup would eat a shell line's punctuation.
              textFormat: piece.code ? TextEdit.PlainText : TextEdit.RichText
              // Selecting copies, on its own (Copy.qml). Per BLOCK: the answer is
              // a column of pieces, and a drag cannot cross from one to the next.
              selectByMouse: true
              selectionColor: Theme.sapphire
              selectedTextColor: Theme.base
              // Minus Fmt's invisible wrap guards, so a paste that looks right
              // also RUNS: real hyphens, real spaces, no zero-width anything.
              onSelectedTextChanged: Copy.take(selectedText
                .replace(/\u200b/g, "").replace(/\u2011/g, "-").replace(/\u00a0/g, " "))
              font.family: piece.code ? Style.font.panelMono : Style.font.panelFamily
              font.pixelSize: piece.code ? Style.font.panelMeta
                : piece.head ? Style.font.panelHead
                : piece.aside ? Style.font.panelAside : Style.font.panelBody
              font.weight: piece.head ? Font.DemiBold : Style.font.normalWeight
              renderType: Text.QtRendering
            }

            InlineImage {
              id: shot
              width: parent.width
              visible: piece.m.image
              source: piece.m.image ? piece.m.source : ""
              alt: piece.m.image ? piece.m.alt : ""
            }

            // ------------------------------------------------------- tools
            // ONE line for the whole batch, not one block per call: rewritten in
            // place while it runs, frozen into a past-tense line when it closes.
            // The breath survives the per-token rebuild only because nothing
            // streams while a tool runs.
            Item {
              id: batch
              width: piece.width
              visible: piece.isTool
              // Zero when this piece is text: a hidden Item still reports a height,
              // and the column would space around a row that is not there.
              height: piece.isTool ? summary.height + drawer.height : 0

              Column {
                id: summary
                anchors { left: parent.left; right: parent.right; top: parent.top }
                spacing: 1

                Text {
                  id: head
                  width: parent.width
                  // Live: what it is doing this second. Settled: what it did, in
                  // total. The tool name only earns a word when the verb does not
                  // already contain it -- "Running bash", but just "Reading".
                  text: {
                    if (!piece.live)
                      return "⟩ " + turnItem.pastLabel(turnItem.batchKind(piece.cs), piece.cs.length)
                        + (fmt.duration(turnItem.batchMs(piece.cs)) !== ""
                            ? " · " + fmt.duration(turnItem.batchMs(piece.cs)) : "")
                    var last = piece.cs[piece.cs.length - 1]
                    var kind = turnItem.kindOf(last.name)
                    var verb = turnItem.liveVerb(kind)
                    return "⟩ " + (kind === "bash" || kind === "other"
                      ? verb + " " + String(last.name).toLowerCase() : verb) + "…"
                  }
                  color: Theme.accent
                  elide: Text.ElideRight
                  // The same breath the spine and the bar dot keep, so the line
                  // still being rewritten is visibly the live one.
                  opacity: piece.live ? turnItem.breath : 1
                  font.family: Style.font.panelMono
                  font.pixelSize: Style.font.panelMeta
                  font.weight: Style.font.boldWeight
                  renderType: Text.QtRendering
                }

                // The stat tail: everything that is NOT the current action, in
                // one quiet line, counted rather than enumerated.
                Text {
                  width: parent.width
                  visible: piece.live
                  text: {
                    if (!piece.live) return ""
                    var parts = []
                    var last = piece.cs[piece.cs.length - 1]
                    if (String(last.arg) !== "") parts.push(String(last.arg))
                    var d = fmt.duration(turnItem.batchMs(piece.cs))
                    if (d !== "") parts.push(d)
                    parts.push(piece.cs.length
                      + (piece.cs.length === 1 ? " step" : " steps"))
                    return parts.join(" · ")
                  }
                  color: Theme.overlay0
                  elide: Text.ElideRight
                  maximumLineCount: 1
                  font.family: Style.font.panelMono
                  font.pixelSize: Style.font.panelMeta
                  renderType: Text.QtRendering
                }
              }

              // ------------------------------------------------------- the detail
              // The commands themselves, when the work is unrolled. Switched, not
              // animated: the narration and the batch lines above it appear the
              // instant the receipt is clicked, and one row sliding under three
              // that did not is worse than none sliding at all.
              Column {
                id: drawer
                anchors { left: parent.left; right: parent.right; top: summary.bottom }
                topPadding: 4
                spacing: 4
                visible: piece.open
                height: piece.open ? implicitHeight : 0

                Repeater {
                  // A count here too: `cs` is a slice of the same rebuilt
                  // array, so it is a new identity on every update as well.
                  model: piece.cs.length

                  delegate: ToolCallRow {
                    required property int index
                    readonly property var modelData: piece.cs[index] || turnItem.noPiece
                    width: drawer.width
                    call: modelData
                    // Only the last call of the turn being written can still be
                    // open; `ms` is stamped the moment a call returns.
                    live: turnItem.pending && modelData.ms === 0
                    // Deliberately NOT the panel's live accent: a tool block is
                    // mauve for good, so scrolling back you can tell which parts
                    // of a conversation touched the machine.
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
