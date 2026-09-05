import QtQuick
import ".."

// One turn of the conversation. A question is a pill hung off the right edge; an
// answer is a full-width column on a rail down the left, and the rail of the turn
// being written breathes.
//
// Order inside an answer is the order things happened -- the text is cut where
// each tool call ran, so a turn reads speak, run, speak, run -- and it STAYS
// that way after it settles. A finished turn used to fold everything up to its
// last tool call behind a caret; it no longer does. What the agent did is not
// debugging output you go and dig for, it is half of the answer, and pi now
// writes a one-line `description` per call saying why it made it. So every call
// is one always-visible line (ToolLine), the narration between them is ordinary
// prose in ordinary colour, and nothing on a settled turn is hidden.
Item {
  id: turnItem

  required property int index
  property color accent: Theme.sapphire

  // The list is BottomToTop, so index 0 is the NEWEST row.
  readonly property int row: OriClient.turns.count - 1 - index
  readonly property var turn: row >= 0 && row < OriClient.turns.count
    ? OriClient.turns.get(row) : null

  readonly property bool user: turn ? turn.role === "user" : false
  readonly property bool pending: turn ? turn.pending === true : false
  // Keyed by the turn's own id, not by its row: a steer inserts a row mid-list
  // and every index below it moves, which is the bug class ids delete.
  readonly property var calls:
    (turnItem.turn ? OriClient.toolsById[turnItem.turn.tid] : null) || []
  // protocol.ts TurnCost -- { input, output, seconds, tokensPerSecond } -- once
  // the turn has settled.
  readonly property var cost:
    (turnItem.turn ? OriClient.costById[turnItem.turn.tid] : null) || null

  // The turn, as an ordered run of pieces (Fmt.split).
  //
  // splitCached, not split: this binding re-runs on EVERY delta and `bodyText`
  // is the whole answer, so the plain pass re-derived the entire turn per token.
  // Measured offscreen on Qt 6.11.2's V4, streaming one answer in 20-char
  // deltas: 2k chars 10ms, 10k 253ms, 20k 660ms -- 1.15ms of a 16.7ms frame per
  // token at 20k, and more than four times the total for twice the words.
  // splitCached keeps the settled prefix and re-splits only what arrived since,
  // giving 2ms / 12ms / 54ms for the same three answers, and it returns the
  // same pieces (checked delta by delta against split() over 2.2M deltas of
  // generated markdown -- see the notes on the cache in Fmt.qml). `fmt` is this
  // delegate's own instance, so the cache belongs to this turn and no other.
  readonly property var pieces: fmt.splitCached(bodyText, pending, calls)
  // NOTHING IS FOLDED ANY MORE.
  //
  // A settled turn used to roll everything up to its last tool call into one
  // grey receipt line with a caret on it, and the work only came back if you
  // clicked. Three things were wrong with that, and the user named all three:
  //
  //   * the narration between calls went grey (Theme.overlay0 at panelAside),
  //     which read as the answer having been half-erased;
  //   * the work went behind a disclosure, so "what did it just do" cost a
  //     click on every turn -- and the whole point of pi carrying a per-call
  //     `description` is that you should not have to ask;
  //   * folding is a HEIGHT CHANGE, and a delegate that shrinks the instant a
  //     turn settles is the biggest single source of the scroll flicker. The
  //     list is BottomToTop, so growth is free and shrinkage is a lurch.
  //
  // So the turn renders in the order things happened and stays that way. What
  // used to be a batch line plus a drawer is now one ToolLine per call, always
  // visible, carrying the sentence Ori wrote for it.

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
  // The ledger's QUIET half. The batch lines already say what ran -- "Ran 3
  // steps", in accent, one per batch -- and saying it again here was the
  // doubling. What they cannot say is what the WHOLE turn cost, so this
  // carries only that: "◇ 5.2s · 153 tok". Empty when nothing was measured.
  // A PROPERTY, not a function. As a function it was called twice from the
  // status row -- once to decide `visible`, once to build `text` -- and the two
  // calls are two separate bindings over the same reads. They disagreed: an
  // empty assistant row (the one the steer path closes where it stands, with
  // no text and no calls) came out visible with nothing in it, so a settled
  // conversation grew a stray `\u25c7` floating between two turns. One binding,
  // read twice, cannot disagree with itself.
  // Why this turn ended without finishing, or "". Set by the host on the TURN
  // (protocol.ts `failed`), so it survives scrolling away, a reconnect and a
  // resume from disk -- unlike the `error` banner, which is about the
  // conversation right now and must be clearable.
  readonly property string failed: turn ? String(turn.failed || "") : ""

  readonly property string receiptText: {
    // A turn that DIED says so, in the slot that otherwise reports what it
    // cost. Without this it just stopped -- and because costFor returns nothing
    // for a turn with no content, it stopped with no receipt either, which is
    // exactly what a very short answer looks like. docs/specs/multi-session.md
    // requires the opposite: "shown as failed, never silently dropped".
    if (failed !== "") return failed

    var ms = 0
    for (var i = 0; i < pieces.length; i++)
      if (pieces[i].tool) ms += batchMs(pieces[i].calls)
    var parts = []
    var d = fmt.duration(cost ? cost.seconds * 1000 : ms)
    if (d !== "") parts.push(d)
    if (cost && cost.output > 0) parts.push(fmt.tokens(cost.output) + " tok")
    return parts.join(" \u00b7 ")
  }

  // The panel's frame clock, handed down rather than started again here: it runs
  // only while a turn is in flight with the panel on screen, and a clock of our
  // own would be a second thing to stop at idle.
  property real nowMs: 0

  // One breath, shared: a cosine off that clock, so everything alive on this
  // card rises and falls together instead of each running its own loop.
  readonly property real breath:
    0.65 + 0.35 * Math.cos(2 * Math.PI * nowMs / Style.ori.breathMs)

  // The tail of the reasoning, for the status row at the head of the turn.
  // Reasoning streams into its own role (the host keeps thinking_delta and
  // text_delta apart) and is never rendered as prose -- a SHORT WINDOW of it
  // says what Ori is chewing on without becoming a second answer competing
  // with the real one.
  //
  // Four whole lines, not one, and always the NEWEST four: the window is cut
  // on source newlines off the tail of the stream, so as reasoning arrives the
  // block flows -- lines push up and the line being written is always the one
  // at the bottom. Whole lines rather than a raw character slice so the window
  // never opens mid-word; capped at four so a think made of short lines cannot
  // run away down the card. The last line is mid-write by definition -- that
  // is the flow.
  readonly property string thought: {
    if (!turn) return ""
    var t = String(turn.thinking || "")
    if (t === "") return ""
    // The last four lines that actually SAY something: blank lines are
    // skipped, so a stream that opens with newlines renders words, not an
    // empty slot. The final line is mid-write by definition -- that is the
    // flow.
    var lines = t.slice(-2000).split("\n")
    var out = []
    for (var i = lines.length - 1; i >= 0 && out.length < 4; i--) {
      if (lines[i].trim() === "") continue
      out.unshift(lines[i])
    }
    return out.join("\n")
  }

  // The answer text, placeholder included: a turn with nothing in it yet must not
  // collapse to zero height, or the list jumps on the first token. One SPACE, not
  // a word or a spinner -- the panel header already names the state in a fixed
  // place, and a second announcement changed a row's height mid-flight.
  readonly property string bodyText: !turn ? ""
    : turn.text !== "" ? turn.text
    : (pending ? " " : "")


  width: ListView.view ? ListView.view.width : 0
  height: user ? pill.height : answer.height

  Fmt { id: fmt }

  // One line of the status row's font, for the reasoning slot's reserved
  // height. A hidden one-line Text rather than TextMetrics: TextMetrics.height
  // reads 0 with no text set on this Qt (measured -- the slot collapsed to 2px
  // and clipped the reasoning to a sliver, which is the “i dont see the
  // thinking” bug), while a laid-out Text cannot lie.
  Text {
    id: thinkLine
    visible: false
    text: "Xg"
    font.family: Style.font.panelMono
    font.pixelSize: Style.font.panelMeta
  }


  // ------------------------------------------------------------- vocabulary
  // A batch that is DONE is a count and nothing more -- "Ran 3 shell commands",
  // one grey line. This came back after being deleted: showing every finished
  // call was the overcorrection to hiding them all behind a fold, and neither
  // is what you want to read. What you want is the call happening NOW in full,
  // the ones that already returned as a tally, and the prose between batches
  // intact -- which is what Claude Code does and what the user asked for after
  // putting the two side by side.
  function kindOf(name) {
    var n = String(name).toLowerCase()
    if (n.indexOf("search") >= 0 || n.indexOf("grep") >= 0 || n.indexOf("glob") >= 0
        || n.indexOf("find") >= 0) return "search"
    if (n.indexOf("write") >= 0 || n.indexOf("edit") >= 0) return "edit"
    if (n.indexOf("read") >= 0 || n.indexOf("cat") >= 0 || n.indexOf("ls") >= 0) return "read"
    if (n.indexOf("fetch") >= 0 || n.indexOf("web") >= 0) return "fetch"
    if (n.indexOf("bash") >= 0 || n.indexOf("shell") >= 0 || n.indexOf("exec") >= 0) return "bash"
    return "other"
  }

  // Past tense, and both numbers right: "Ran 1 shell command", never "1
  // commands". "Searched 3 searches" stutters, so a search is counted in
  // searches; a batch of mixed kinds has no one noun and is counted in steps.
  readonly property var noun: ({ read: "Read file", edit: "Edited file",
    fetch: "Fetched page", search: "Ran search", bash: "Ran shell command" })
  function pastLabel(kind, n) {
    var w = String(noun[kind] || "Ran step").split(" ")
    var tail = w[w.length - 1]
    return w[0] + " " + n + " " + w.slice(1, w.length - 1).concat([
      tail + (n === 1 ? "" : tail === "search" ? "es" : "s")]).join(" ")
  }

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

  // A batch, split into the three things that render differently: the calls
  // that are over (a tally), the jobs still alive in the background (a line
  // each, because they are not over), and the one call in flight (in full).
  // Returned as index lists so the delegates below can stay count-driven --
  // see the `noPiece` note for why a fresh array must never be a model.
  // Done means NOT live and NOT backgrounded -- defined by what it is not,
  // deliberately, because the obvious test (`ms > 0`) is wrong on exactly the
  // transcripts you are most likely to be looking at. A session read back off
  // disk has no timings: rehydrate() writes t0 and ms as 0, because a session
  // file records what a tool was asked to do and not when. Under `ms > 0`
  // every restored call was neither done nor live nor backgrounded, so a
  // reopened conversation rendered its tool batches as NOTHING AT ALL -- a gap
  // between two paragraphs where the work had been. Which is also what a QML
  // reload does, since the panel restores the last session on boot.
  function doneOf(cs) {
    var at = liveOf(cs)
    var out = []
    for (var i = 0; i < cs.length; i++) if (i !== at) out.push(i)
    return out
  }
  // Only the last call of a turn being written can still be open. Read off
  // `state`, which protocol.ts makes authoritative, and not off the `ms === 0`
  // proxy: a call with no timing this panel ever saw ALSO has ms 0 (see
  // OriClient.toolRow), so a snapshot of a running conversation whose last call
  // has already returned used to leave that finished call breathing as if it
  // were in flight.
  function liveOf(cs) {
    return (pending && cs.length > 0 && cs[cs.length - 1].state === "running") ? cs.length - 1 : -1
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

  // Whether the agent has the question yet. Sending is not instant: a cold
  // panel has to spawn pi first (measured 6-7s to a first token), and a message
  // typed WHILE a turn runs is a `steer`, which pi holds until the tool call in
  // flight returns. The pill used to look finished the instant you pressed
  // enter, so there was no way to tell "it has this" from "it will have this in
  // a moment".
  //
  // The host tracks three steps (protocol.ts Delivery: 0 queued, 1 on the wire,
  // 2 the agent has demonstrably read it) and this collapses them to the two
  // that are worth a picture.
  // The difference between 0 and 1 is milliseconds on a warm panel and is not
  // the thing anyone is asking; the thing anyone is asking is whether it
  // landed. Nothing in the protocol acknowledges a message by id, so "landed"
  // is inferred from the agent producing its first token or tool call after the
  // message went out, host-side. A rehydrated transcript has no
  // record of any of this and reads as landed, which is true: those messages
  // were plainly answered.
  readonly property bool landed:
    !turn || turn.delivery === undefined || Number(turn.delivery) >= 2

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

    // The question's own rail, and the mirror of the answer's spine: an answer
    // hangs off a rail at x=0 that breathes while it is being written, so a
    // question hangs off one at its right edge that breathes while the agent
    // has not taken it yet. Same breath, same 2px, same settling to a quiet
    // surface colour when there is nothing left to wait for.
    //
    // A mark rather than a glyph on purpose. Ticks in the corner would be a
    // second vocabulary on a card that already has one -- and the state does
    // not need reading, only noticing, which is exactly what a rail is for.
    Rectangle {
      anchors { right: parent.right; top: parent.top; bottom: parent.bottom
                topMargin: 8; bottomMargin: 8 }
      width: 2
      radius: 1
      color: turnItem.landed ? Theme.surface2 : turnItem.accent
      opacity: turnItem.landed ? 1 : turnItem.breath

      Behavior on color {
        ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
      }
    }

    Column {
      id: asked
      anchors { left: parent.left; right: parent.right; top: parent.top
                leftMargin: 12; rightMargin: 12; topMargin: 8 }
      spacing: 6

      TextEdit {
        id: said
        width: parent.width
        // An image-only question is a real thing, and an empty Text would
        // still pay for a line of height.
        visible: text !== ""
        text: turnItem.turn ? turnItem.turn.text : ""
        color: Theme.text
        readOnly: true
        activeFocusOnPress: false
        wrapMode: TextEdit.Wrap
        // Selection is driven from Selection.qml (SelectableArea below), so a
        // drag can start on your own message and cross into the answer -- it
        // used to be a Text and the one thing on the card you could not copy.
        selectByMouse: false
        persistentSelection: true
        selectionColor: Theme.sapphire
        selectedTextColor: Theme.base
        textFormat: TextEdit.RichText
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

        // The mouse face of the question. A CHILD of the field, not a sibling
        // in the Column: an anchored item inside a positioner breaks the
        // positioner's layout outright (measured -- every sibling stayed at
        // y 0), and as a child it rides the field it belongs to.
        SelectableArea { anchors.fill: parent; sel: said }
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

      // ------------------------------------------------------------ status
      // ONE row at the head of every assistant turn, and it is the same row for
      // the whole life of the turn: while it is being written it says what Ori
      // is thinking about, and when it settles it says what the turn cost.
      //
      // The same row on purpose. The old thinking block was `visible: text ===
      // "" && thinking !== ""`, so it vanished the instant the first answer
      // token landed -- 453px of content gone in ONE frame, mid-stream, which
      // is the flicker measured in AssistantPanel's sticking notes. A slot that
      // only ever changes its TEXT cannot do that. Height is fixed; only the
      // words move.
      //
      // The disclosure that used to live here is gone with the fold, and so is
      // the hairline that pointed at it: with nothing hidden there is no
      // boundary to draw.
      Item {
        id: seam
        width: parent.width
        // NOT "visible while pending". The rail above the composer already says
        // `thinking`, in a fixed place, with the elapsed time beside it -- so a
        // turn that says it too is the same word twice on one card, which is
        // what the user saw. This row carries only what the rail cannot: the
        // reasoning itself, and afterwards the turn's cost.
        //
        // The 0 -> 20 step when the first reasoning token lands is safe in a
        // way the old thinking block was not. The list is BottomToTop, so
        // GROWTH is free and only shrinking lurches; this row grows once, near
        // the head of the turn, and never shrinks again -- when the turn
        // settles the receipt takes the same 20px. The block this replaced did
        // the opposite: it was on screen from the start and VANISHED on the
        // first answer token, which is the 453px one-frame collapse measured in
        // AssistantPanel's sticking notes.
        //
        // Since the reasoning window widened to four lines this row is a
        // RESERVED slot, not a measured one: four line-heights from the moment
        // the first reasoning token lands, and the text is anchored to its
        // BOTTOM edge and clipped -- so the block NEVER changes height while
        // the think streams. Lines complete and push the older ones up inside
        // the box; the newest line is always the one at the bottom; nothing
        // outside the slot moves, which is the difference between a flowing
        // readout and the flicker a growing row produced (every delegate
        // re-layout shifted the whole answer, once per completed line). The
        // only height changes left are the slot's opening when reasoning
        // starts and its collapse to the one-line receipt at the settle --
        // both animated, neither per-token.
        visible: (turnItem.pending && turnItem.thought !== "")
                 || turnItem.receiptText !== ""
        height: !visible ? 0
          : turnItem.pending ? thinkLine.height * 4 + 2
          : thinkLine.height + 2
        clip: true

        Behavior on height {
          NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing }
        }

        Text {
          id: told
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          // Reasoning is streamed into its own role and never rendered as
          // prose. The tail of it, bottom-anchored in the reserved slot above:
          // enough to know the shape of what it is considering, not so much
          // that it competes with the answer that follows.
          // A failed turn takes the FILLED glyph and the error colour: a hollow
          // one in overlay grey reads as "here is what it cost", which is the
          // one thing this row must never say about a turn that did not finish.
          text: turnItem.pending ? "\u25c6 " + turnItem.thought
              : turnItem.failed !== "" ? "\u25c6 " + turnItem.receiptText
              : "\u25c7 " + turnItem.receiptText
          color: turnItem.failed !== "" ? Theme.red
               : turnItem.pending ? Theme.subtext0 : Theme.overlay0
          font.italic: turnItem.pending
          wrapMode: Text.Wrap
          font.family: Style.font.panelMono
          font.pixelSize: Style.font.panelMeta
          renderType: Text.QtRendering
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
          // The COUNT, not the array. See the `noPiece` block at the top of
          // this file for why -- a fresh JS array resets a Repeater, and
          // `pieces` is rebuilt on every single token.
          model: turnItem.pieces.length

          delegate: Item {
            id: piece
            // ONLY index is required. An integer model provides nothing else,
            // and a delegate that requires a property the model cannot supply
            // fails to build -- silently, with a clean config log and a panel
            // missing every answer.
            required property int index
            readonly property var m: turnItem.pieces[piece.index] || turnItem.noPiece

            readonly property bool isTool: piece.m.tool === true
            readonly property bool code: piece.m.code === true
            readonly property bool head: piece.m.head === true
            readonly property bool bullet: piece.m.bullet === true
            readonly property bool tbl: piece.m.table === true
            readonly property var cs: piece.isTool ? (piece.m.calls || []) : []

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
              : piece.tbl ? mdTable.implicitHeight
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
              visible: !piece.m.image && !piece.tbl
              // `|| ""`: a tool piece carries no text at all, and binding
              // undefined here logged "Unable to assign [undefined] to QString"
              // on every batch line drawn.
              text: piece.m.image ? "" : (piece.m.text || "")
              color: Theme.text
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
              // Selecting copies, on its own (Copy.qml) -- but the mouse is
              // owned by the SelectableArea below and the selection is set by
              // Selection.qml, so ONE drag crosses blocks: this paragraph, the
              // next one, a table, your own message. What is NOT registered (a
              // collapsed batch tally, a tool row) is skipped for not being a
              // TextEdit, so collapsed areas fall out of a multi-block copy
              // with no special case.
              selectByMouse: false
              persistentSelection: true
              selectionColor: Theme.sapphire
              selectedTextColor: Theme.base
              font.family: piece.code ? Style.font.panelMono : Style.font.panelFamily
              font.pixelSize: piece.code ? Style.font.panelMeta
                : piece.head ? Style.font.panelHead : Style.font.panelBody
              font.weight: piece.head ? Font.DemiBold : Style.font.normalWeight
              renderType: Text.QtRendering
            }

            // The mouse face of this paragraph. List items are lines of one
            // list, so they join a multi-block copy with a single newline;
            // paragraphs with a break.
            SelectableArea {
              anchors.fill: chunk
              sel: chunk
              sep: piece.bullet ? "\n" : "\n\n"
            }

            InlineImage {
              id: shot
              width: parent.width
              visible: piece.m.image
              source: piece.m.image ? piece.m.source : ""
              alt: piece.m.image ? piece.m.alt : ""
            }

            // ------------------------------------------------------ table
            // Qt's markdown engine has rendered GFM tables for years; this
            // panel's earlier attempt to lay them out by hand did not survive
            // contact. The raw block arrives from Fmt and Qt does the rest --
            // wrapping cells, weighting the header, all of it.
            TextEdit {
              id: mdTable
              visible: piece.tbl
              width: parent.width
              height: implicitHeight
              text: piece.tbl ? (piece.m.md || "") : ""
              readOnly: true
              activeFocusOnPress: false
              textFormat: TextEdit.MarkdownText
              wrapMode: TextEdit.Wrap
              color: Theme.text
              // Same arrangement as the answer chunks above: the SelectableArea
              // below owns the mouse, Selection sets the range.
              selectByMouse: false
              persistentSelection: true
              selectionColor: Theme.sapphire
              selectedTextColor: Theme.base
              font.family: Style.font.panelFamily
              font.pixelSize: Style.font.panelAside
              renderType: Text.QtRendering
            }

            SelectableArea { anchors.fill: mdTable; sel: mdTable }

            // ------------------------------------------------------- tools
            // A batch, in two parts, and the order is the order it reads:
            //
            //   ⟩ Ran 3 shell commands                        4.2s
            //   ● restart the shell so the panel reloads
            //     └ systemctl --user restart quickshell
            //
            // The tally is what is OVER. The expanded row is what is happening
            // right now. Anything handed off to the background is over as far
            // as this turn is concerned -- see the note further down.
            //
            // Once the turn settles there is no live row and no bg row left to
            // draw, and the whole batch is the one grey line -- which is why
            // nothing has to fold: the compaction is a consequence of the work
            // finishing, not a second state the card can be put into.
            Column {
              id: batch
              width: piece.width
              visible: piece.isTool
              // Zero when this piece is text: a hidden Column still reports a
              // height, and the column above would space around a row that is
              // not there.
              height: piece.isTool ? implicitHeight : 0
              spacing: 3

              readonly property var done: piece.isTool ? turnItem.doneOf(piece.cs) : []
              readonly property int liveAt: piece.isTool ? turnItem.liveOf(piece.cs) : -1

              // Clicked open: the tally gives way to the calls it counted, each
              // one a full row. Per BATCH, not per turn -- the old fold was one
              // switch over everything a turn did, so opening it to check a
              // single command unrolled twenty. Here you open the three that ran
              // between two paragraphs and the rest stays a count.
              property bool open: false

              // ------------------------------------------------- the tally
              // What is over, as a number. Click it to see what the number was.
              Item {
                width: parent.width
                visible: batch.done.length > 0 && !batch.open
                height: visible ? tally.implicitHeight : 0

                Text {
                  id: tally
                  anchors { left: parent.left; right: tallyMs.left; rightMargin: 8 }
                  text: "\u27e9 " + turnItem.pastLabel(
                    turnItem.batchKind(piece.cs), batch.done.length)
                  color: Theme.overlay0
                  elide: Text.ElideRight
                  font.family: Style.font.panelMono
                  font.pixelSize: Style.font.panelMeta
                  renderType: Text.QtRendering
                }

                Text {
                  id: tallyMs
                  anchors { right: parent.right; baseline: tally.baseline }
                  // The time the FINISHED calls took. The live row keeps its
                  // own clock, so adding it in here would count it twice.
                  text: {
                    var t = 0
                    for (var i = 0; i < batch.done.length; i++)
                      t += piece.cs[batch.done[i]].ms
                    return fmt.duration(t)
                  }
                  color: Theme.overlay0
                  font.family: Style.font.panelMono
                  font.pixelSize: Style.font.panelMeta
                  renderType: Text.QtRendering
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: batch.open = true
                }
              }

              // ---------------------------------------- the tally, unrolled
              // The calls the tally counted, in full. Clicking ANYWHERE on them
              // puts them back -- there is no "hide" button, because a control
              // is only worth its row when the thing it controls is not itself
              // an obvious target. The block you just opened is exactly that
              // target: you looked, you are done, you click it away.
              //
              // The MouseArea is declared AFTER the rows and fills the same
              // box, so it sits on top and takes every click in it. That is
              // deliberate rather than accidental -- it also swallows the
              // per-row "show the whole command" toggle inside an unrolled
              // batch, which is the right trade: two different meanings for one
              // click in one block is worse than losing the second one. The
              // live row and any background job keep that toggle, since neither
              // is inside here.
              Item {
                width: parent.width
                visible: batch.open
                height: visible ? rows.implicitHeight : 0

                Column {
                  id: rows
                  anchors { left: parent.left; right: parent.right; top: parent.top }
                  spacing: 3

                  Repeater {
                    model: batch.open ? batch.done.length : 0

                    delegate: ToolLine {
                      required property int index
                      width: rows.width
                      call: piece.cs[batch.done[index]] || turnItem.noPiece
                      nowMs: turnItem.nowMs
                      breath: turnItem.breath
                    }
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: batch.open = false
                }
              }

              // A BACKGROUNDED JOB GETS NO ROW HERE.
              //
              // It used to keep one -- expanded, pulsing, with its command
              // under it -- on the reasoning that a job still running is not
              // over and should not compact. True, and it stopped being this
              // card's problem the moment the tray existed: the same job was
              // then drawn twice, once in the transcript under the turn that
              // started it and once in the strip above the composer, both
              // pulsing, both saying the same PID.
              //
              // The division that settles it: the TRANSCRIPT is what a turn
              // did, and handing a command off IS what the turn did with it.
              // The TRAY is what is still running. So the row compacts into the
              // tally with every other finished call, and unrolling the tally
              // still shows it, `\u21b3 bg <pid>` and all.
              // --------------------------------------------- the call in flight
              ToolLine {
                width: batch.width
                visible: batch.liveAt >= 0
                height: visible ? implicitHeight : 0
                call: batch.liveAt >= 0 ? piece.cs[batch.liveAt] : turnItem.noPiece
                live: batch.liveAt >= 0
                nowMs: turnItem.nowMs
                breath: turnItem.breath
              }
            }
          }
        }
      }
    }
  }
}
