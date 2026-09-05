import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import "root:/"
import "../assistant"

// The hover panel: the ONE surface in this design allowed to cover a window.
//
// -------------------------------------------------------------------- why
// Everything else about Ori was pushed back inside the bar's own 30px, because
// ambient light on a working screen is a cost the user refused twelve times.
// This is the exception, and it is an exception because they asked for it in
// the same breath:
//
//   "when hovering with the mouse it expands under in a good design on top of
//    other windows so i can see the more details."
//
// So it is allowed to lie over a maximised editor -- and it is bound by the
// strictest possible reading of that permission. It exists only while the
// pointer is on the mark, it takes input nowhere except the block of text
// itself, and it is destroyed, not hidden, the moment the pointer leaves.
//
// ------------------------------------------------------------------ VEIL
// No card and no edge anywhere. The chosen variant out of five: the scrim
// OriArrival used under its two lines of text, scaled up to carry a block. The
// four rejected alternatives all drew a rectangle of some kind -- welded to the
// bar (PLINTH), detached with a border (POPOVER), wide with a rail (LEDGER), or
// solid on top and dissolved at the bottom (SEAM) -- and a rectangle over
// someone's document is a dialog. This is a shadow with a hairline coming out
// of the mark, and nothing else.
//
// The scrim construction is HARVESTED from OriArrival, which this change
// deletes, including the tuning it took two passes to get: a Shape holding a
// square with a RadialGradient, squashed by a transform into a flat ellipse.
// Drawing the ellipse directly would give the gradient ONE centreRadius -- the
// square's -- so the light would fall off over 700px vertically inside a 340px
// surface, which is no falloff at all. That was OriArrival's first version and
// it read as a flat sheet for exactly this reason.
//
// ------------------------------------------------------ what it says, ONLY
// Four facts, and they are the four the bar cell structurally cannot carry:
//
//   the QUESTION   a sentence. A 148px strip has never had room for one, and
//                  after four minutes away it is what makes the rest mean
//                  anything at all.
//   the ARGUMENTS  the bar says "bash". This says WHICH bash --
//                  `rg -n 'implicitHeight' quickshell/widgets/*.qml`. The one
//                  word is a deliberate truncation up there; this is the rest
//                  of it, and the panel's own footer has never carried it.
//   THIS CALL's age  not the turn's. A turn four minutes old whose current
//                  call is 2s in is healthy; the same turn with a call 3m50s
//                  in is stuck. The bar shows only the turn, so that
//                  distinction lives here and nowhere else.
//   three lines    of the answer, at reading size, without opening anything.
//
// It used to also show a trail of the turn's last four calls, and that was the
// panel's loudest justification. The user cut it -- "we dont need the short
// trail of the turns recent tool the user doesnt care" -- so it is gone, along
// with the engine accessor written to serve it. The surface is shorter for it.
//
// What it deliberately does NOT show, and the reason is the same for all four:
// the model id, the thinking level, the plan usage and the context percentage
// are already on the panel's footer, and not one of them changes on the
// timescale of a hover. Repeating them here would cost the whole width of the
// block to tell you something that was true a minute ago and will be true a
// minute from now. The turn's ELAPSED is left out for a nearer reason -- it is
// 30px above, in the cell the cursor is resting on.
//
// -------------------------------------------------------------- the rules
// FIXED SIZE. `implicitHeight` is a constant and nothing ever touches it. A
// layer surface that changes size waits on a compositor configure/ack round
// trip PER FRAME -- this repo measured a 180ms entrance landing as five lurches
// at 2% CPU (CLAUDE.md). The block INSIDE grows and shrinks freely between
// working, unread and idle; that costs nothing at all.
//
// INPUT ONLY WHERE THE WORDS ARE. The mask is the text block and nothing else,
// so the rest of the strip under the bar -- most of the screen's width -- stays
// clickable straight through to whatever is beneath. The rect is computed once
// per appearance and never per frame: an input region that changes with an
// animating value is a commit on every frame of the entrance.
//
// NOTHING WHEN IDLE. Bar.qml builds this from a LazyLoader on hover and drops
// it on leave, so a desktop nobody is pointing at carries no extra layer
// surface at all. It must be built ALREADY VISIBLE: a PanelWindow created with
// `visible: false` and shown later maps at 0x0 and the compositor never
// configures a real size, so it renders nothing (measured here, on the surface
// this file replaces).
PanelWindow {
  id: veil

  // Set by Bar.qml, so there is one of these per monitor exactly like the bar.
  property var barScreen: null
  screen: barScreen

  // Screen x of the bar's mark, bound live by Bar.qml.
  property real originX: -1

  // True while the pointer is on the cell. Pushed in rather than read out: the
  // loader that decides this object's existence cannot also read a property of
  // it without a binding loop (the same problem Assistant.qml solves the same
  // way).
  property bool anchored: false
  // Raised once the retraction has run, so Bar.qml can free the surface.
  signal done()

  WlrLayershell.namespace: "quickshell-ori-veil"
  // The bar's own layer, so the panel lies over a maximised window rather than
  // being buried by one.
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  // Reserve nothing of its own, but respect what the bar reserved -- that is
  // what parks y=0 exactly on the bar's underside without this file having to
  // know the bar's height, and keeps it there if the bar's height ever changes.
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: 0

  anchors { top: true; left: true; right: true }

  // Fixed, forever. See the rules above.
  implicitHeight: Style.ori.veilHeight
  color: "transparent"

  Fmt { id: fmt }

  // The answer's line box, measured rather than assumed. A Text with `elide`
  // set fits as many lines as its HEIGHT allows, so `height: implicitHeight`
  // on one is a binding loop -- and sizing it off `pixelSize` instead is the
  // trap OriArrival documented and paid for: 16px times three lines is 48
  // against a real line height of 26, which silently turned a three-line gist
  // into one elided line. Caught in a capture, not in review; caught here in a
  // warning, from the same mistake.
  FontMetrics {
    id: bodyMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.panelBody
  }
  // lineSpacing, not height: `height` is ascent+descent and Text lays lines out
  // on the spacing, so three lines measured the other way came up two pixels
  // short and the third line was elided away. Measured, in a capture.
  readonly property int answerLineH: Math.ceil(bodyMetrics.lineSpacing * 1.3) + 1

  // ------------------------------------------------------------------ state
  readonly property bool working: OriClient.busy
  readonly property bool failed: OriClient.error !== "" && !working
  readonly property bool holding: (OriClient.unread || failed) && !working

  readonly property color tint: working ? Theme.sapphire
    : failed ? Theme.urgent
    : OriClient.unread ? Theme.sky
    : Theme.overlay0

  // ------------------------------------------------- what is working ELSEWHERE
  // The bar cell's quietest register says "parked ×2" and cannot say more in
  // 58px. This surface exists to be the rest of that sentence, and the host
  // already sends what it needs: the session list carries `busy` and a label per
  // conversation. Nothing is derived here -- a row is busy because the host says
  // so, and it is somebody else because its id is not this conversation's.
  readonly property var othersBusy: {
    var me = OriClient.sessionId
    if (me === "") return []
    var list = OriClient.sessions
    var out = []
    for (var i = 0; i < list.length; i++)
      if (list[i].busy === true && String(list[i].id) !== me)
        out.push(String(list[i].label || "(no title)"))
    return out
  }

  readonly property string elsewhereLine: {
    var rows = veil.othersBusy
    if (rows.length === 0) return ""
    // One is the case worth naming: WHICH conversation is still going is the
    // whole reason you would want to know. Past one, the count is the fact and
    // the picker is where the names are.
    return rows.length === 1 ? "still working  ·  " + rows[0]
                             : rows.length + " other conversations still working"
  }

  // What you asked. One line, dim, and the most valuable thing on the surface
  // after four minutes away -- it is what makes "bash rg -n implicitHeight"
  // mean anything. Read through `turns.count` so it re-reads on append.
  readonly property string ask: {
    var n = OriClient.turns.count
    if (n <= 0) return ""
    var i = OriClient.lastUser()
    return i < 0 ? "" : String(OriClient.turns.get(i).text).replace(/\s+/g, " ").trim()
  }

  // The answer's opening, at reading size: the one fact that decides whether
  // the panel is worth opening at all. Whitespace collapsed because an answer
  // arrives as markdown, and bullets and blank lines turn three lines of column
  // into three words of column. The panel has the real thing, formatted.
  //
  // PUSHED by the `appended` signal rather than bound through the turn model:
  // a delta is applied with ListModel.setProperty, which notifies that model's
  // delegates and nothing else, so a binding through `turns.get(i).text` is
  // evaluated once and never again. Here there is one string and one signal, so
  // a slot is the whole of it.
  property string answer: ""

  function readAnswer() {
    if (veil.failed) { veil.answer = OriClient.error; return }
    var i = OriClient.lastAssistant()
    if (i < 0) { veil.answer = ""; return }
    var t = String(OriClient.turns.get(i).text).replace(/\s+/g, " ").trim()
    veil.answer = t === "" ? "…" : t
  }

  Connections {
    target: OriClient
    function onAppended() { veil.readAnswer() }
    function onSettled() { veil.readAnswer() }
    function onErrorChanged() { veil.readAnswer() }
  }

  // ...and the one case `appended` does not cover: the transcript being
  // REPLACED under an open veil -- cleared, or swapped for a resumed session.
  // Every ordinary token goes through grow(), which raises `appended`; a whole
  // new conversation arriving does not have to.
  Connections {
    target: OriClient.turns
    function onCountChanged() { veil.readAnswer() }
  }

  // -------------------------------------------------------- the call in flight
  // The turn's record of what it has touched, straight off `toolsById` -- the
  // same read the panel's transcript already makes (TurnDelegate.qml). Keyed by
  // TURN ID, not by row: a steer inserting a turn mid-list re-keys nothing. The
  // map is rebuilt by ASSIGNMENT on every tool boundary, which is what makes a
  // plain binding through it follow the turn.
  //
  // NOTHING HERE IS HISTORY. An earlier version drew a trail of the turn's last
  // four calls under a divider; the user cut it -- "we dont need the short
  // trail of the turns recent tool the user doesnt care" -- and the engine
  // accessor that existed to serve it went with it. What is read is the LAST
  // entry and only while it is still open: its `t0` is the only place its start
  // time is recorded, which is the whole reason this surface touches the tool
  // map at all.
  readonly property var turnCalls: {
    var n = OriClient.turns.count
    if (n <= 0) return []
    return OriClient.toolsById[OriClient.turns.get(n - 1).tid] || []
  }

  // `state`, not `ms === 0`: a call the panel first saw ALREADY FINISHED -- one
  // restored in a snapshot -- carries the unknown pair t0=0/ms=0, and timing it
  // from t0 would print the milliseconds since the epoch. `t0 > 0` is the
  // invariant every other consumer of these rows is written against.
  readonly property var liveCall: {
    var all = veil.turnCalls
    var last = all.length > 0 ? all[all.length - 1] : null
    return (last && last.state === "running" && last.t0 > 0 && veil.working) ? last : null
  }

  // How long ago the last answer landed, in the coarsest unit that is still
  // true. Read ONCE, when the surface is built: a hover lasts seconds and a
  // figure in minutes cannot change inside one, so there is nothing here to
  // tick and no second clock to outlive the surface.
  readonly property string settledAgo: {
    var at = OriClient.lastSettledAt
    if (at <= 0) return ""
    var s = Math.max(0, (Date.now() - at) / 1000)
    return s < 60 ? "just now"
      : s < 3600 ? Math.round(s / 60) + "m ago"
      : Math.round(s / 3600) + "h ago"
  }

  // Ticks the live call's duration and nothing else. One display clock, running
  // only while there is a running call to time, and stopped the frame there is
  // not -- so a veil over a settled answer animates nothing at all.
  property int liveMs: 0
  FrameAnimation {
    running: veil.liveCall !== null
    onTriggered: {
      var ms = Math.max(0, Date.now() - veil.liveCall.t0)
      // A guard, not a poll: the value is derived on a frame already being
      // drawn, and only written when the tenth of a second it prints changes.
      if (Math.floor(ms / 100) !== Math.floor(veil.liveMs / 100)) veil.liveMs = ms
    }
  }

  // ------------------------------------------------------------------ motion
  // ONE scalar drives everything, through three overlapping windows, so the
  // exit is a genuine retraction rather than a fade: run it back down and the
  // words sink first, the tether closes to a point, and the pool is drawn back
  // into the seam last. Free, and impossible to get out of sync.
  property real reveal: 0
  property bool closing: false

  function stage(a, b) {
    var t = Math.max(0, Math.min(1, (veil.reveal - a) / (b - a)))
    return t * t * (3 - 2 * t)
  }
  readonly property real poolT: stage(0.00, 0.70)
  readonly property real tetherT: stage(0.10, 0.55)
  readonly property real wordsT: stage(0.35, 1.00)

  NumberAnimation {
    id: open
    target: veil; property: "reveal"; to: 1
    duration: Style.ori.veilOpenMs; easing.type: Style.anim.easing
  }

  NumberAnimation {
    id: shut
    target: veil; property: "reveal"; to: 0
    duration: Style.ori.veilCloseMs; easing.type: Style.anim.easingSmooth
    // Deferred a tick: `done` is what makes Bar.qml's loader destroy this
    // object, and doing that inside the emitting animation's own callback frees
    // it mid-emit.
    onFinished: Qt.callLater(veil.done)
  }

  // The grace. The pointer crossing the seam between the cell and this surface
  // flickers hover off for a frame; without it the panel would strobe on the
  // boundary pixel. It is a Timer and not a sleep because nothing here may
  // block, and it is stopped -- not merely ignored -- the moment the pointer
  // comes back.
  Timer {
    id: linger
    interval: Style.ori.veilGraceMs
    onTriggered: if (!veil.held) veil.retract()
  }

  readonly property bool held: veil.anchored || words.containsMouse

  onHeldChanged: {
    if (veil.held) {
      linger.stop()
      if (veil.closing) {
        veil.closing = false
        shut.stop()
        open.restart()
      }
    } else {
      linger.restart()
    }
  }

  function retract() {
    if (veil.closing) return
    veil.closing = true
    open.stop()
    shut.start()
  }

  Component.onCompleted: {
    veil.readAnswer()
    open.start()
  }

  // --------------------------------------------------------------- geometry
  // Clamped to the screen so the column never runs off an edge on a narrow
  // monitor. The mark sits near the right-hand island, so on a 960px logical
  // output this clamp is doing real work rather than guarding a corner case.
  readonly property real markX: veil.originX >= 0 ? veil.originX : veil.width / 2
  readonly property real blockX: {
    // Hung LEFT of the mark, not extending right from it. The original offset
    // of 44 put the block's first character just left of the tether and let it
    // run rightward -- which is fine for a mark in the middle of a bar and
    // wrong for this one, because the cell sits beside the RIGHT island and
    // there is barely any screen left in that direction. Reported as "aligned
    // to the right too much".
    //
    // So the block's far edge sits near the mark and the text grows back
    // towards the middle of the screen, where there is room. The 44 is kept as
    // an overhang past the tether, so the tether still lands INSIDE the block
    // rather than off its corner.
    var x = veil.markX + 44 - Style.ori.veilBlockWidth
    return Math.max(10, Math.min(veil.width - Style.ori.veilBlockWidth - 10, x))
  }

  // ------------------------------------------------------------------- mask
  // The words are the target; the whole rest of this strip passes through to
  // whatever window is under it. NOT bound to anything the animation drives --
  // `reveal` does not appear here, so the input region is committed once.
  mask: Region {
    x: Math.round(veil.blockX - 12)
    y: Style.ori.veilBlockY - 8
    width: Style.ori.veilBlockWidth + 24
    height: Math.round(block.height) + 16
  }

  // --------------------------------------------------- how big the shadow is
  // The SURFACE is a constant -- see the rules in the header, and CLAUDE.md.
  // The POOL inside it is not, and that is the whole difference between a
  // shadow and a card: it is sized to the block it has to make legible, so a
  // working panel of three short rows does not lay 320px of dark over someone's
  // document to hold 110px of text. Changing a Shape's geometry costs a
  // repaint; it costs no configure/ack.
  //
  // One animated scalar, so a state change under a live hover -- an answer
  // landing while you are still pointing at the mark -- grows the shadow rather
  // than cutting to the new size.
  property real poolBox: block.height
  Behavior on poolBox {
    NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
  }

  readonly property real poolCy: Style.ori.veilBlockY + veil.poolBox / 2
  // Two limits, and the tighter one wins. The block's own half-height over
  // 0.42 puts the LAST LINE inside the gradient's plateau (which runs to 0.55
  // of the radius) with room to spare; and the pool may never be cut by the
  // surface's bottom edge, because a clipped falloff is the one hard line this
  // design exists to avoid. The floor keeps a one-line panel from getting a
  // shadow so tight it reads as a highlighter.
  readonly property real poolRy: Math.min(Style.ori.veilHeight - veil.poolCy - 2,
                                          Math.max(120, (veil.poolBox / 2) / 0.42))

  // ------------------------------------------------------------------ paint
  // ---------------------------------------------------------------- the pool
  // ------------------------------------------------------------------- card
  // A DROPPED ISLAND, not a shadow. This was an edgeless scrim -- a squashed
  // radial disc of @crust, sized to the text, with all the falloff spent
  // between r=0.55 and r=1.0 so the dim rows stayed above their own
  // background. It was carefully built and it was the wrong idea.
  //
  // Over a dark wallpaper it read as light coming through. Over Gmail it read
  // as a grey smudge left on the screen: "its beed big... doesnt feel
  // embeded". An edgeless surface needs something to bleed INTO, and an
  // arbitrary bright document is not it.
  //
  // What makes a surface feel embedded is looking like part of the thing it
  // hangs off. So it borrows the bar's own language exactly -- island radius,
  // surface colour, one hairline edge -- and reads as the bar extending
  // downward rather than as something floating over an unrelated app.
  //
  // Sized to the block plus padding rather than to a fixed rectangle, so three
  // short lines do not lay a card the height of a paragraph over someone's
  // inbox.
  Rectangle {
    id: card
    readonly property int pad: 12
    // FLUSH to the bar, not floating under it. As a free-standing rounded box
    // it read as a panel from another application that happened to be near the
    // top of the screen -- "its beed big... doesnt feel embeded", and then
    // "disgusting" once it was seen over a real window. Nothing about it said
    // where it came from.
    //
    // Hung from y=0 with only the BOTTOM corners rounded, in the bar's own
    // colour, it reads as the bar growing downward, which is the one thing it
    // actually is.
    x: Math.round(veil.blockX - pad)
    y: 0
    width: Style.ori.veilBlockWidth + 2 * pad
    height: Style.ori.veilBlockY + Math.round(block.height) + pad
    topLeftRadius: 0
    topRightRadius: 0
    bottomLeftRadius: Style.bar.islandRadius
    bottomRightRadius: Style.bar.islandRadius
    color: Theme.base
    border.width: 1
    border.color: Theme.alpha(Theme.surface1, 0.9)
    opacity: veil.poolT

    Behavior on height {
      NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing }
    }
  }

  // -------------------------------------------------------------- the tether
  // The hairline that says which mark this came out of. Brightest where it
  // meets the bar, because that is where the light is coming from.
  Rectangle {
    x: Math.round(veil.markX)
    y: 0
    width: 1
    height: Math.round(14 * veil.tetherT)
    opacity: veil.tetherT
    gradient: Gradient {
      GradientStop { position: 0.0; color: Theme.alpha(veil.tint, 0.85) }
      GradientStop { position: 1.0; color: Theme.alpha(veil.tint, 0.20) }
    }
  }

  // ------------------------------------------------------------------ words
  Column {
    id: block
    x: veil.blockX
    // Lifts the last few pixels into place rather than appearing at rest -- the
    // same rise the clock label uses when a minute turns.
    y: Style.ori.veilBlockY + 6 * (1 - veil.wordsT)
    width: Style.ori.veilBlockWidth
    opacity: veil.wordsT
    spacing: 0

    // ------------------------------------------------------ what you asked
    Text {
      width: parent.width
      text: veil.ask
      // Not @overlay0. Over a bright window the pool lands near overlay0's own
      // luminance and this line -- the most valuable one on the surface after
      // four minutes away -- read as a watermark.
      color: Theme.alpha(Theme.subtext0, 0.80)
      elide: Text.ElideRight
      font.family: Style.font.family
      font.pixelSize: Style.font.panelMeta
      renderType: Text.NativeRendering
    }

    Item { width: 1; height: 12 }

    // ------------------------------------------- WORKING: the call in flight
    // With its arguments, which is the whole point: the bar says "bash", this
    // says WHICH bash.
    Item {
      width: parent.width
      visible: veil.liveCall !== null
      height: visible ? 22 : 0

      Text {
        id: verb
        text: veil.liveCall ? String(veil.liveCall.name) : ""
        color: veil.tint
        font.family: Style.font.family
        font.pixelSize: Style.font.size
        renderType: Text.NativeRendering
      }

      Text {
        anchors { left: verb.right; leftMargin: 8; right: dur.left; rightMargin: 10 }
        text: veil.liveCall ? String(veil.liveCall.arg) : ""
        color: Theme.subtext1
        // Middle, not right: a path's tail is what identifies it, and so is a
        // ripgrep pattern's flag. Cutting either end loses the file.
        elide: Text.ElideMiddle
        font.family: Style.font.family
        font.pixelSize: Style.font.size
        renderType: Text.NativeRendering
      }

      Text {
        id: dur
        anchors.right: parent.right
        text: fmt.duration(veil.liveMs)
        color: veil.tint
        font.family: Style.font.family
        font.pixelSize: Style.font.panelMeta
        renderType: Text.NativeRendering
      }
    }

    // ------------------------------------------- WORKING, between tool calls
    // There is no call in flight and the answer is still being written. Saying
    // nothing here would leave the surface looking like it had lost the turn.
    Text {
      width: parent.width
      visible: veil.working && veil.liveCall === null
      height: visible ? 22 : 0
      text: "thinking"
      color: veil.tint
      font.family: Style.font.family
      font.pixelSize: Style.font.size
      renderType: Text.NativeRendering
    }

    // ------------------------------------------------- FAILED: say it failed
    // Without this line the error text below sits exactly where an ANSWER sits,
    // in the three-line reading layout the unread state uses, and reads as one.
    // The frame turning red is not a label.
    Text {
      width: parent.width
      visible: veil.failed
      height: visible ? 22 : 0
      text: "failed"
      color: veil.tint
      font.family: Style.font.family
      font.pixelSize: Style.font.size
      renderType: Text.NativeRendering
    }

    // ---------------------------------------------- UNREAD: what it answered
    // Three lines while the answer is UNREAD and one, elided, once it has been
    // read. The difference is the whole point of the state: an unread answer is
    // being offered and the three lines are what decide whether to open it; a
    // read one is a receipt, and a ghost of its first line is enough to say
    // which conversation this is. Nothing on this surface should ask twice.
    Text {
      width: parent.width
      visible: !veil.working && veil.answer !== ""
      // Fixed at its line count, not derived from the text: see bodyMetrics.
      // It also makes the block one height whether the answer is eight words
      // or eight hundred, which is what keeps the input mask still.
      height: visible ? (veil.holding ? 3 : 1) * veil.answerLineH : 0
      text: veil.answer
      color: veil.holding ? Theme.text : Theme.alpha(Theme.subtext0, 0.75)
      wrapMode: veil.holding ? Text.Wrap : Text.NoWrap
      // Three lines is a gist. The answer is one click away and SUPER+A is
      // written at the bottom of this block.
      maximumLineCount: veil.holding ? 3 : 1
      elide: Text.ElideRight
      lineHeight: 1.3
      // The panel's reading size, not the bar's: this is a sentence, at
      // whatever distance you happen to be from the screen.
      font.family: Style.font.family
      font.pixelSize: Style.font.panelBody
      renderType: Text.NativeRendering
    }

    // ------------------------------------------------------- nothing yet said
    Text {
      width: parent.width
      visible: !veil.working && veil.answer === ""
      height: visible ? implicitHeight : 0
      text: OriClient.warm ? "warm · nothing asked yet" : "SUPER+A to ask"
      color: Theme.alpha(Theme.subtext0, 0.75)
      font.family: Style.font.family
      font.pixelSize: Style.font.panelBody
      renderType: Text.NativeRendering
    }

    // ------------------------------------------- ELSEWHERE: the parked turn
    // A conversation you parked mid-answer is still being answered, and until
    // now the only surface that knew was a modal you had to remember to open.
    // In sapphire, the working colour, because that is what it is -- just not
    // here. Absent renders as absent: no row, no gap.
    Text {
      width: parent.width
      visible: veil.elsewhereLine !== ""
      height: visible ? implicitHeight + 10 : 0
      text: veil.elsewhereLine
      color: Theme.alpha(Theme.sapphire, 0.85)
      elide: Text.ElideRight
      font.family: Style.font.family
      font.pixelSize: Style.font.panelMeta
      renderType: Text.NativeRendering
    }

    Item { width: 1; height: 12 }

    Rectangle { width: parent.width; height: 1; color: Theme.alpha(Theme.surface2, 0.75) }

    // Collapses with the receipt. While Ori works there is no receipt yet, and
    // a 10px band under a rule with nothing beneath it reads as something that
    // failed to load.
    Item { width: 1; height: veil.working ? 0 : 10 }

    // --------------------------------------------------- SETTLED: the receipt
    // Tool count and throughput. NOT elapsed -- that is 30px above, in the cell
    // the pointer is resting on, and printing it twice would be the same
    // mistake the context percentage was making in the bar.
    Text {
      width: parent.width
      visible: !veil.working
      height: visible ? implicitHeight : 0
      text: {
        var parts = []
        // WHEN, but only once the answer has been read: while it is still
        // waiting, "just now" is the only possible value and the elapsed figure
        // is 30px above in the cell the cursor is on.
        if (!veil.holding && veil.settledAgo !== "") parts.push("answered " + veil.settledAgo)
        var n = veil.turnCalls.length
        if (n > 0) parts.push(n + (n === 1 ? " tool" : " tools"))
        if (OriClient.usageTotal > 0) parts.push("↓ " + fmt.tokens(OriClient.usageTotal))
        return parts.join("  ·  ")
      }
      color: Theme.alpha(Theme.subtext0, 0.72)
      font.family: Style.font.family
      font.pixelSize: Style.font.tiny
      renderType: Text.NativeRendering
    }

    Item { width: 1; height: 6 }

    // ------------------------------------------------------------ the hints
    // The ONLY place the right-click toggle is written down, and it costs
    // nothing on a working screen because it is only ever on this surface --
    // which is only ever up while someone is pointing at the mark.
    Item {
      width: parent.width
      height: 14

      Text {
        text: "SUPER+A  transcript"
        color: Theme.alpha(Theme.subtext0, 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.tiny
        renderType: Text.NativeRendering
      }
      Text {
        anchors.right: parent.right
        text: OriClient.cellCompact ? "right-click  let it open" : "right-click  keep compact"
        color: Theme.alpha(Theme.subtext0, 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.tiny
        renderType: Text.NativeRendering
      }
    }
  }

  // The only interactive thing on the surface, and it is exactly the masked
  // rect. It holds the panel open while the pointer is on the words -- reaching
  // for something that withdraws under the cursor is the one failure mode a
  // hover surface has -- and clicking it opens the transcript, which is what
  // anyone who has read this far wanted.
  MouseArea {
    id: words
    x: veil.blockX - 12
    y: Style.ori.veilBlockY - 8
    width: Style.ori.veilBlockWidth + 24
    height: block.height + 16
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: OriClient.panelOpen = true
  }
}
