import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
// Theme/Style/PiSession are singletons in the config root; a subdirectory does
// not get the root's implicit import, so pull it in explicitly.
import ".."

// The assistant panel: a conversation docked to the right edge.
//
// This deliberately is NOT a launcher. The five launchers are modal -- they take
// the keyboard exclusively, you pick one thing, they vanish. A conversation is
// the opposite shape: it stays up while you work, you go back and forth with it,
// and what was said five minutes ago is still on screen. So:
//
//   * WlrKeyboardFocus.OnDemand, not Exclusive. The panel can sit open next to a
//     terminal and only takes the keyboard when you click into it. Exclusive
//     would make the rest of the desktop unusable while it is up, which is fine
//     for a launcher you dismiss in two seconds and wrong for this.
//   * WlrLayer.Top, not Overlay -- it belongs above windows but below the
//     notification popups and the OSD, which still need to be seen over it.
//   * exclusionMode Ignore: it floats over the tiling instead of reshuffling
//     every window each time it opens.
//
// The transcript lives in PiSession, not here, so closing the panel loses
// nothing -- including mid-answer, since the process keeps writing into the turn
// model with no window attached.
//
// ------------------------------------------------------------------ readouts
// A terminal agent gets its legibility from the terminal: unlimited scrollback,
// the full width of a window, and your entire attention. This is 460px pinned to
// an edge that you are meant to work NEXT to, so every readout has to earn its
// row. Four questions have to answer themselves without being asked, and the
// panel is laid out around exactly those four:
//
//   what is it doing   the mark in the header breathes and the rail above the
//                      composer names the state -- "thinking", "running bash".
//   for how long       the rail counts the live turn; every settled answer
//                      keeps its own duration in its footer.
//   what did it touch  each tool call stays in the transcript as a block with
//                      the actual command, and the time it took.
//   how much is left   the hairline above the footer is the context gauge, with
//                      the estimate spelled out beside it.
//
// The numbers come from PiSession's derived readouts; nothing here polls.
//
// -------------------------------------------------------------------- motion
// One frame clock, running only while a turn is. It drives the mark and the
// scan line, and it stamps the wall clock the elapsed readout counts from. When
// the agent settles, the clock stops and every binding it feeds freezes -- this
// surface costs nothing to leave open.
//
// IPC:  qs ipc call assistant toggle | open | close | ask <text> | status
PanelWindow {
  id: panel

  // Hand the transcript to the script surface's probe (OriIpc `scroll`). The
  // list's scroll state exists only in here, and a panel is not a thing a
  // shell command can read -- this is how it becomes one.
  Component.onCompleted: {
    ScrollProbe.list = transcript
    ScrollProbe.panel = panel
  }

  property bool opened: false

  // NOTE these three are no longer the way in. `opened` is a binding onto
  // PiSession.panelOpen so the bar indicator can toggle the same panel, which
  // means the IpcHandler sets that property directly and NOTHING here is
  // called -- open()'s focus call was dead code and the composer never took the
  // keyboard. Focus now happens in onOpenedChanged, which fires either way.
  function open() { PiSession.panelOpen = true }
  function close() { PiSession.panelOpen = false }
  function toggle() { PiSession.panelOpen = !PiSession.panelOpen }

  // --------------------------------------------------------------- geometry
  // Opens on whichever monitor has focus, the same rule the launchers and the
  // polkit dialog use. Only re-targeted while closed: moving a live layer
  // surface between outputs mid-animation is a configure round trip per frame.
  function focusedScreen() {
    var focused = Hyprland.focusedMonitor
    if (!focused) return panel.screen
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (Hyprland.monitorFor(screens[i]) === focused) return screens[i]
    }
    return panel.screen
  }

  // 560, not the 460 it was pinned at for three rounds. The user's verdict was
  // "i feel like its too small or not clear", and then, having seen it, "the
  // size of the panel was better in A". At 460 the answer's measure was 426px --
  // about 58 characters, under a comfortable reading measure and narrow enough
  // that one inline path could take a whole line. 560 gives it 526px, ~66
  // characters of Adwaita Sans at 19: the measure a paragraph wants. On this
  // machine's 1280 logical points that is 44% of the screen, which is what a
  // working sidebar costs. Rendered against THIS frame at that width -- the card
  // still reads as a floating card and needs no adjustment.
  readonly property int panelWidth: 560

  WlrLayershell.namespace: "quickshell-assistant"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
  exclusionMode: ExclusionMode.Ignore

  // LEFT, not right. The right edge is where this shell already puts things
  // that interrupt you -- notification popups stack there. The assistant is
  // something you turn TO, so it gets the other side and does not fight them
  // for the same corner.
  anchors { top: true; bottom: true; left: true }
  // The SURFACE is a fixed width and never resizes; the card slides inside it.
  // A layer surface that changes size waits on a compositor configure/ack per
  // frame, which is what turned the notification popups into a slideshow before
  // they were sized once and animated internally.
  implicitWidth: panelWidth + 24
  color: "transparent"

  visible: opened || revealed > 0.001
  property real revealed: 0

  onOpenedChanged: {
    // Re-target only on the way IN, while the surface is off screen: moving a
    // live layer surface between outputs costs a configure round trip per frame.
    if (opened) panel.screen = focusedScreen()
    revealed = opened ? 1 : 0
    // Opening it means wanting to type into it. callLater because the composer
    // does not exist yet on the frame `opened` flips.
    if (opened) Qt.callLater(function () { entry.forceActiveFocus() })
    // ...and open ON the newest turn. Nothing did this before: the panel is
    // built lazily, so a first open creates the list fresh and it rests where
    // Qt leaves it, which is the OLDEST message -- you opened a conversation
    // and were shown its beginning. Reopening was no better, since the list
    // keeps whatever position it had when it was hidden.
    if (opened) Qt.callLater(function () { transcript.goBottom() })
  }

  Behavior on revealed {
    NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
  }

  // Only the card takes clicks; the empty strip beside it stays click-through so
  // the desktop underneath is still usable with the panel open.
  mask: Region {
    x: card.x
    y: card.y
    width: card.width
    height: card.height
  }

  // ------------------------------------------------------------------ state
  // One accent for the whole surface, so the card edge, the mark, the spine of
  // the turn being written and its tool blocks all say the same thing at once.
  // Mauve while a tool runs is the shell's own "active" colour (Theme.accent);
  // it separates "it is talking to the model" from "it is touching the machine",
  // which is the distinction that matters when you look up mid-turn.
  readonly property color accent:
      PiSession.error !== "" ? Theme.red
    : PiSession.activeTool !== "" ? Theme.accent
    : PiSession.busy ? Theme.sapphire
    : PiSession.bgCount > 0 ? Theme.accent
    : PiSession.warm ? Theme.sapphire
    : Theme.inactive

  // The verb, in the panel's own vocabulary. "thinking" and "answering" are
  // different states and the difference is visible from across the room: one is
  // silence, the other is text arriving.
  readonly property string stateLabel:
      PiSession.error !== "" ? "error"
    : PiSession.activeTool !== "" ? "running " + PiSession.activeTool.split(" ")[0]
    : !PiSession.busy ? ""
    // Background work is NOT named here any more. It has a strip of its own
    // (BackgroundTray) directly above this one, because it is a different kind
    // of fact: this rail describes the turn in flight and collapses with it,
    // and a backgrounded job outlives every turn there is.
    : (PiSession.liveTurn && PiSession.liveTurn.text !== "") ? "answering" : "thinking"

  // WHY it is running that, beside the verb that says it is running something.
  // `activeTool` is the tool name and its one summarised argument joined by a
  // space, and summarizeArgs() prefers the `description` pi's tool-descriptions
  // extension makes every call carry -- so this is the sentence Ori wrote for
  // the call in flight. The panel had it all along and was throwing it away on
  // `.split(" ")[0]`.
  //
  // Here, and not in the turn: this rail is the one place on the card that
  // cannot move. The transcript scrolls, a turn's own rows arrive and grow, but
  // the line directly above where you type is always in the same pixels -- so
  // "what is it doing this second" is readable without looking for it. The
  // transcript keeps the same sentence per call as a ToolLine, which is the
  // record; this is the readout.
  readonly property string stateDetail: {
    if (PiSession.error !== "" || PiSession.activeTool === "") return ""
    var cut = PiSession.activeTool.indexOf(" ")
    return cut < 0 ? "" : PiSession.activeTool.substring(cut + 1)
  }

  Fmt { id: fmt }

  // How full the window is, said as precisely as it is actually known. A
  // percentage needs the session's own contextWindow, which arrives with the
  // stats of the first settled turn; before that there is a real token total to
  // show as soon as usage starts streaming, and before THAT there is nothing,
  // which is what an em dash is for.
  // Both halves are kept: against a million-token window a percentage barely
  // moves for an afternoon, while the running total is what actually tells you
  // the conversation is getting heavy.
  readonly property string contextLabel: {
    if (PiSession.usageTotal <= 0) return "—"
    // `~` while the number is pi's post-compaction estimate: the readout says
    // what it knows and admits it is not measured yet.
    var out = (PiSession.usageEstimated ? "~" : "") + fmt.tokens(PiSession.usageTotal)
    if (!PiSession.contextKnown) return out
    var pct = PiSession.contextFraction * 100
    return out + " · " + (pct < 10 ? pct.toFixed(1) : String(Math.round(pct))) + "%"
  }

  // ------------------------------------------------------------- frame clock
  // Vsync-locked, and it ticks ONLY while a turn is running with the panel on
  // screen. It is not watching for state changes -- it animates the mark, moves
  // the scan line, and advances a display of elapsed time, which is the one
  // thing on this surface that has to move by itself.
  property real nowMs: 0

  // "IS ANYTHING ON THIS SURFACE STILL MOVING?" -- which is a different
  // question from "what is the agent waiting on", and the two must not be
  // confused again. The clock and the breath below both ask the first one;
  // `PiSession.bgCount` answers the second, and deliberately EXCLUDES speech,
  // because counting a speak job there made the bar cell show a phantom `x1`
  // and put the panel in busy chrome over an empty tray. Both things are
  // right, and speech is exactly where they part: nothing is waiting on it,
  // and it is plainly moving -- it has a strip of its own whose comment
  // promises "yellow, breathing, gone the moment it ends", and that promise is
  // kept from here. Named once rather than spelled out twice, because it was
  // spelled out twice that a change to bgCount silently froze the strip.
  readonly property bool inMotion:
    PiSession.busy || PiSession.bgCount > 0 || PiSession.speakJob !== null

  FrameAnimation {
    id: clock
    // Background jobs keep it running. A backgrounded command is the one kind
    // of activity that outlives the turn that started it, so a clock that stops
    // at `agent_settled` leaves every moving thing on the card frozen while
    // work is still going on -- the rail's scan mid-track, the tool rows at
    // whatever opacity the last frame gave them, the speak strip's age stuck on
    // the second the answer ended.
    running: panel.opened && panel.inMotion
    onTriggered: panel.nowMs = Date.now()
  }

  // The panel's one breath, so everything alive on this surface rises and falls
  // together rather than each running a loop of its own. Collapses to a
  // constant when the clock stops, so nothing is stranded mid-cycle.
  readonly property real breath: panel.inMotion
    ? 0.65 + 0.35 * Math.cos(2 * Math.PI * panel.nowMs / Style.ori.breathMs)
    : 1

  readonly property real elapsedMs:
    PiSession.turnStartedAt > 0 ? Math.max(0, panel.nowMs - PiSession.turnStartedAt) : 0

  // Output tokens per second, for the footer. `warm`/`cold` sat there before and
  // said only whether a process existed -- true of nearly every moment you are
  // looking at the panel, so it told you nothing. This moves.
  //
  // The rate itself is PiSession's, measured over GENERATION time rather than
  // the wall clock: a turn that sat nine seconds in bash and then wrote fifty
  // tokens is not a 5 tok/s model, and dividing by the turn made every
  // tool-using answer read as a slow one. Falls back to warm/cold when there is
  // no sample yet.
  readonly property string rateLabel:
    PiSession.tokensPerSecond > 0
      ? (PiSession.tokensPerSecond >= 10 ? Math.round(PiSession.tokensPerSecond)
                                         : PiSession.tokensPerSecond.toFixed(1)) + " tok/s"
      : (PiSession.warm ? "warm" : "cold")

  Connections {
    target: PiSession
    // Stamp the clock at the start of the turn rather than waiting for the
    // first frame, so the readout opens at 0.0s instead of at whatever the last
    // turn left behind.
    function onBusyChanged() { if (PiSession.busy) panel.nowMs = Date.now() }
    // One ring on the mark as the answer lands. The bar deliberately stays
    // quiet when the panel is open; this is the full stop, not an alert.
    function onSettled() { if (panel.opened) mark.ping() }
    // An attached image is announced rather than returned, because wl-paste
    // answers long after the keypress. The marker goes in at the cursor, the
    // way Claude Code does it: the field stays a text field, and the number is
    // what ties the two halves together -- delete `[Image 1]` and that image is
    // not sent.
    function onAttachedImage(n, path) {
      var m = "[Image " + n + "]"
      if (entry.text !== "" && !/\s$/.test(entry.text)) m = " " + m
      entry.insert(entry.cursorPosition, m + " ")
    }
  }

  // The colour per thinking level, shared by the card border and the composer
  // edge. Lives on the panel, not on the card, because both bindings resolve it
  // as panel.effortColor. Unknown or empty (no model yet, level dropped on a
  // switch) falls back to the neutral dim sapphire, so a cold panel looks as
  // before.
  function effortColor(level) {
    switch (String(level)) {
    case "off":    return Theme.overlay0
    case "minimal": return Theme.overlay0
    case "low":    return Theme.blue
    case "medium": return Theme.yellow
    case "high":   return Theme.red
    case "xhigh":  return Theme.red
    default:       return Theme.alpha(Theme.sapphire, 0.4)
    }
  }

  // ------------------------------------------------------------------- card
  Rectangle {
    id: card

    // Floating, not docked: inset from every edge and short of full height, so
    // it reads as a console resting on the desktop rather than a sidebar welded
    // to it. The surface behind it is still fixed-size -- only the card moves.
    width: panel.panelWidth
    height: Math.round(parent.height * 0.78)
    anchors.verticalCenter: parent.verticalCenter
    // Slides in from the left edge it is anchored to.
    x: 16 - (1 - panel.revealed) * (width + 32)
    opacity: panel.revealed

    color: Theme.base
    radius: 16
    border.width: 2
    // The edge of the card is the furthest-away readout there is: dim when
    // nothing is happening, lit in the accent of whatever is. Kept neutral for
    // effort on purpose -- Netanel tried the effort heat scale here and asked
    // for it on the composer edge alone; the full-card flash at every cycle
    // was louder than the signal.
    border.color: PiSession.busy || PiSession.error !== ""
      ? panel.accent : Theme.alpha(Theme.sapphire, 0.4)
    clip: true

    Behavior on border.color {
      ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
    }

    // ---------------------------------------------------------------- header
    // Every full-bleed strip below is inset by the border width and carries the
    // card's corner radius on whichever side it touches: `clip` is rectangular,
    // so a strip anchored flat to the edge would square off the corner it sits
    // in and paint over the border that is doing the talking.
    Rectangle {
      id: header
      anchors { top: parent.top; left: parent.left; right: parent.right
                margins: card.border.width }
      height: 44
      color: Theme.surface0
      topLeftRadius: card.radius - card.border.width
      topRightRadius: card.radius - card.border.width

      OriMark {
        id: mark
        anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
        accent: panel.accent
        alive: PiSession.busy
        phase: clock.elapsedTime
      }

      Text {
        anchors { left: mark.right; leftMargin: 10; verticalCenter: parent.verticalCenter }
        text: "Ori"
        color: Theme.text
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelBody
        font.weight: Style.font.boldWeight
        renderType: Text.QtRendering
      }

      // Where it runs. This is the whole "it manages this machine" claim, and
      // it belongs where a terminal agent puts its working directory: on the
      // chrome, permanently, not in an about box.
      Text {
        anchors { right: newBtn.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
        text: PiSession.workdir
        color: Theme.overlay0
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }

      Rectangle {
        id: newBtn
        anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
        width: 24; height: 24; radius: 6
        color: newArea.containsMouse ? Theme.hoverBackground : Theme.transparent

        Behavior on color {
          ColorAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
        }

        Text {
          anchors.centerIn: parent
          text: "＋"
          color: newArea.containsMouse ? Theme.text : Theme.overlay0
          font.family: Style.font.panelMono
          font.pixelSize: Style.font.panelBody
          renderType: Text.QtRendering
        }

        MouseArea {
          id: newArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: PiSession.newChat()
        }
      }

      Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 1
        color: Theme.surface1
      }
    }

    // ------------------------------------------------------------ transcript
    ListView {
      id: transcript

      anchors {
        top: header.bottom
        left: parent.left
        right: parent.right
        bottom: speakStrip.top
        leftMargin: 10
        rightMargin: 10
        topMargin: 10
        bottomMargin: 4
      }

      model: PiSession.turns
      spacing: 12
      clip: true
      // A conversation is read from the bottom, so that is where it rests.
      // BottomToTop also inverts the model, which is what keeps the view pinned
      // to the newest token for free while a turn streams -- the delegate reads
      // its row back through `count - 1 - index`.
      verticalLayoutDirection: ListView.BottomToTop

      // Stop at the edge, no rubber band. Two reasons: a touchpad flick's
      // overshoot pushes visibleArea past its range for several frames, and
      // the stick logic below reads exactly those numbers -- a bounce at the
      // bottom would read as the view having left the newest turn. And the
      // settle-back animation an overscroll costs carries no information on a
      // surface whose every other motion means something.
      boundsBehavior: Flickable.StopAtBounds

      // Lay out a little beyond the viewport in each direction. Every turn is
      // a column of RichText TextEdits, and building one cold, mid-scroll, is
      // the hitch that made wheel scrolling feel broken: the list stopped, a
      // screenful built, then it moved. Prebuilding one screen and a half of
      // runway amortises that build off the critical path.
      //
      // BUT a floor alone was measured to freeze the wheel after a resume:
      // the view only knows the heights of delegates it has BUILT, and pinned
      // to the bottom it builds only the newest screen and a half -- the
      // older turns are guessed from the ones beside them. Guess short (a
      // session that ends in short exchanges but has long turns above) and
      // contentHeight under-reports, the scroll range collapses, and every
      // wheel notch clamps to a no-op -- the older turns never instantiate
      // because you cannot scroll to them. So the buffer is bound to the
      // content: a bigger measured content builds more of it, whose real
      // heights grow contentHeight again, and the cascade converges on the
      // whole transcript within a few frames. The cold-build hitch moves
      // from mid-scroll to open time, where it belongs.
      //
      // A CAP WAS TRIED HERE AND IS WRONG. Converging on the whole transcript
      // means the view recycles nothing, so bounding the buffer -- four
      // viewports each way -- looks like the obvious economy. Measured on a
      // harness of 150 turns of 90-700px, it costs more than it saves:
      //
      //   * Qt keeps re-guessing the heights of the turns it did not build, so
      //     contentHeight moves DURING a scroll. onContentHeightChanged below
      //     cannot tell that from text arriving, so it applies its reading-view
      //     shift and throws the view away: an 8,400px scroll up landed at
      //     -43,003 in 11 jumps, the worst of them 19,651px, and an extreme
      //     transcript jumped 167,406px to a viewport with nothing in it. The
      //     `!moving && !wheelAnim.running` guard does not catch it, because
      //     wheelPixels writes contentY directly and raises neither.
      //   * The same guessing over-shoots at the far end and left 25,000 to
      //     40,000px of blank above the oldest turn -- which is the "large
      //     blank gaps while scrolling" this was supposed to fix.
      //
      // Uncapped, the same harness gives exact contentHeight, a scroll that
      // lands where it was aimed, and zero blank. And the cap did not even buy
      // the thing it was for: it bounds PIXELS, not delegates, and still left
      // ~48 of them live in a 400px view. The per-frame cost that motivated it
      // is dealt with at its root instead -- see the delegate below.
      cacheBuffer: Math.max(600, contentHeight * 2)

      // `nowMs` is the panel's own frame clock, handed to the delegates so the
      // live tool batch can count its elapsed time off the same tick as the
      // rail -- and stop dead with it when the turn settles.
      //
      // HANDED TO THE LIVE TURN ONLY. The condition says exactly the two
      // states in which a turn has anything left that moves: it is being
      // written (`pending`), or it is a question whose delivery has not been
      // acknowledged yet (`!landed`, the pill that breathes until the agent
      // produces its first token). A settled turn's elapsed time was stamped
      // when it settled and cannot change again, so it has no business holding
      // a subscription to a clock. Everything else gets a constant: its
      // `nowMs` never changes and nothing downstream of it is re-evaluated.
      // Normally that is one delegate on the clock, briefly two while a
      // question waits above the answer to it.
      //
      // SIZE THIS HONESTLY, because the buffer above means every turn in the
      // transcript holds a delegate and it looks like it ought to be
      // expensive. It is not: measured at 50 built delegates over 6000 ticks,
      // the old shape cost 121 MICROSECONDS per tick -- 0.7% of a 16.6ms
      // frame, about 7ms of CPU per second of a running turn. It is cheap for
      // the same reason it looks costly: every readout that reads `breath` is
      // already gated behind `pending` or `landed`, so a settled turn
      // recomputed the cosine and threw it away without touching the scene.
      // And `receiptText` -> `batchMs` only reaches `nowMs` for a call with
      // `ms === 0 && t0 > 0`, a branch a settled turn never takes, so it
      // captured no dependency on the clock at all.
      //
      // SO THIS DOES NOT FIX THE COMPOSER LAG, and must not be read as having
      // done. The clock only runs while the panel is open and something on it
      // is moving (`panel.inMotion`) -- it is STOPPED while you type between
      // turns, so the work removed here was not even running at the moment the
      // lag is felt. That is its own open question.
      //
      // The constant is 0, and freezing at 0 was audited against all four
      // consumers of this property: TurnDelegate's `breath` and `batchMs`, and
      // the two ToolLines it hands down to. None can print anything wrong --
      // both subtractions are wrapped in Math.max(0, ...) and Fmt.duration
      // returns "" at or below 0. One behaviour does change, knowingly: a
      // finished turn that handed a command off to the background stops
      // PULSING that row inside its unrolled tally. The row stays fully
      // visible (breath at 0 is exactly 1.0), it is not drawn at all unless
      // you click the tally open, and the tray above the composer is what owns
      // "still running" -- TurnDelegate says as much where it deleted that
      // row's live copy.
      delegate: TurnDelegate {
        id: turnCell
        accent: panel.accent
        nowMs: (turnCell.pending || !turnCell.landed) ? panel.nowMs : 0
      }

      // --------------------------------------------------------- sticking
      // BottomToTop pins the view to the newest token for free WHILE THE
      // CONTENT ONLY GROWS. It stops being free the moment a delegate
      // SHRINKS -- which is exactly what a thinking block does when the first
      // answer token lands. The block is `visible: text === "" && thinking
      // !== ""` and it is a child of a Column, so the Column drops it from
      // layout outright and the delegate loses its whole height in one frame.
      //
      // Measured on a real turn rather than reasoned about (deepseek-v4-flash,
      // "what is 2+2?", instrumented ListView, timings in ms):
      //
      //   +0     textlen 0 -> 1     contentHeight 1477 -> 1024   (-453px, ONE frame)
      //   +135   atYEnd false       contentY still -415
      //   ...    contentHeight 1064 -> 1449 over the next 650ms, contentY frozen
      //   +718   contentY moves again, then catches up ~22px per frame
      //
      // So the "jump" is three faults, not one: the content loses 453px
      // instantly, the view comes off the end and stops following for 0.7s
      // while the answer is written off screen, and then Qt re-latches and
      // lurches to catch up. Only the last two are fixable from here; the
      // instant collapse belongs to the delegate.
      property bool stuck: true
      // True while the last scroll gesture moved toward the bottom. A
      // contentY tick may RE-stick during a downward move; never during an
      // upward one.
      property bool wheelingDown: false
      // contentHeight as of the last change, for the reading-view anchor.
      property real lastContentHeight: 0

      // How far the newest turn sits below the bottom edge, in pixels. Read off
      // visibleArea rather than contentY on purpose: under BottomToTop the
      // contentY origin MOVES with contentHeight, so there is no stable "this
      // value means bottom" to compare against -- while `yPosition == 1 -
      // heightRatio` is the end of the range in either layout direction.
      readonly property real belowBottom:
          Math.max(0, (1 - visibleArea.heightRatio - visibleArea.yPosition) * contentHeight)

      // Slack, and it has to be pixels rather than `atYEnd`. atYEnd is an exact
      // comparison and it FLICKERS: at the tail of the same measured turn, with
      // contentY unchanged at -539.0 across eight consecutive frames, it
      // reported true, false, true, false. Sticking on that would unstick
      // itself while nothing moved at all. 24px is roughly one line of
      // panelMeta -- near enough that you plainly meant to be at the bottom,
      // far enough that a re-wrap or a rounding error cannot cross it.
      readonly property int stickSlack: 24

      function toBottom() {
        // A pin takes the view; a glide it left running would keep writing
        // contentY against it for the rest of the animation.
        wheelAnim.stop()
        // index 0 under BottomToTop is the NEWEST turn, at the bottom edge --
        // the delegate reads its row back through `count - 1 - index`. So the
        // beginning of the content is the bottom of the conversation.
        transcript.positionViewAtBeginning()
      }

      // One callLater is not enough on a long transcript. The appends that
      // matter land in the same frame as the model change, and the delegates
      // they add -- a RichText answer column above all -- settle their heights
      // over SEVERAL frames, not one. A view positioned against the stale
      // heights can end up outside the laid-out region entirely: a viewport
      // with nothing in it, the history gone "above the chat". Nothing forces
      // a re-latch until the next contentHeight change, which on a cold turn
      // is the first streamed token -- so the transcript read as blank until
      // the answer started. Pin for a window of frames instead: long enough to
      // outlive the settling, short enough that a scroll the user begins in
      // that window still wins, because `moving` sets `stuck` false and the
      // pin refuses to run when it is not stuck.
      property int pinFrames: 0

      Timer {
        id: pinTimer
        interval: 16
        repeat: true
        onTriggered: {
          // The pin window outlives the instant that opened it: a fold settling
          // (delegates shrink) or a re-wrap keeps this timer alive across the
          // frames where the user takes the wheel. Without this gate the timer
          // dragged the view back to the bottom WHILE the user was scrolling
          // up -- `stuck` had already gone false, and the pin overruled them
          // for the rest of its window. A pin is a promise made while stuck;
          // unstuck, it is cancelled.
          // QUALIFIED. A bare `pinFrames = 0` inside the Timer is not a write
          // to the ListView's property -- the Timer has no such property, so
          // QML treats it as a write to a global and refuses it: "Invalid write
          // to global property", 129 times in one session. The stop() beside it
          // still ran, so the symptom was mild and entirely invisible without
          // reading the log: the counter simply kept its old value.
          if (!transcript.stuck) { transcript.pinFrames = 0; pinTimer.stop(); return }
          transcript.toBottom()
          if (--transcript.pinFrames <= 0) pinTimer.stop()
        }
      }

      function pin() {
        // 40 frames (~0.65s at 60Hz), not 12. The settle it has to outlive was
        // measured at 650ms on a two-line answer -- a long RichText turn on a
        // long transcript settles its delegate heights over MORE frames than
        // that, and every frame past the window was a frame the view could be
        // left parked on stale heights: which is exactly "I submitted and it
        // showed me an older message". Re-armed by every contentHeight change
        // while stuck, so a slow settle keeps extending it.
        transcript.pinFrames = 40
        pinTimer.restart()
      }

      function goBottom() {
        transcript.stuck = true
        transcript.toBottom()
        // Again next frame. A single call uses whatever delegate heights are
        // current, and after a model change or a first show they are not final
        // yet -- the list then lands short and stays there, because nothing
        // else is going to correct a position the user asked for by hand.
        // Guarded on stuck, like every queued correction: a wheel notch in
        // between must win.
        Qt.callLater(function () { if (transcript.stuck) transcript.toBottom() })
        // ...and keep catching the frames after that, where the single
        // callLater above was measured to arrive too early.
        transcript.pin()
      }

      // The other end. Unsticks, because arriving at the oldest turn and then
      // being dragged back the moment a token lands would make the key useless.
      function goTop() {
        transcript.stuck = false
        transcript.positionViewAtEnd()
      }

      // ------------------------------------------------------------ wheel
      // Mouse-wheel scrolling. Qt's built-in wheel path on a list moves one
      // fixed step per notch, with no animation, and never raises `moving` --
      // so next to the touchpad flick on the same surface it reads as slow
      // and choppy, and it never participates in the stick logic. This claims
      // only MOUSE wheels: the touchpad keeps the native flick path, which
      // already animates. Each notch becomes a short glide, and the target
      // accumulates while the wheel keeps turning, so a fast run composes
      // into one longer move rather than machine-gun restarts.
      //
      // Direction is MEASURED, not assumed: under BottomToTop the newest
      // message rests at the LEAST negative contentY and the oldest at the most
      // negative -- the [-(contentHeight - height), 0] range one would port
      // from a TopToBottom list is wrong here. So wheel-up, toward older,
      // drives contentY MORE NEGATIVE, and this list's own stick logic below
      // works off visibleArea, which is direction-independent and stayed
      // correct.
      readonly property real wheelStep: 110
      property real wheelTargetY: 0

      // The newest end of the range, i.e. the bottom of the conversation.
      // Every "snap to the bottom" write in this file aims here.
      //
      // Read off the NEWEST DELEGATE, not off contentHeight. Under BottomToTop
      // index 0 is the newest turn, so the end of the content is its bottom
      // edge and "at the bottom" means contentY + height == item0.y +
      // item0.height. contentHeight cannot answer that: it is an extrapolation
      // from whichever delegates happen to be built, and when it drifts
      // (ghost < 0) `originY + contentHeight - height` disagrees with it by
      // hundreds of pixels. Measured at rest, three seconds after a turn
      // settled:
      //
      //   ghost=+349.8   ceil(delegate)=-505.0   ceil(contentHeight)=-155.2
      //   at rest and after a notch re-stick: contentY=-505.0, stuck=true,
      //   contentY + height == newestEnd exactly
      //
      // So the delegate ceiling was load-bearing by 349.8px, and the view
      // landed on the newest turn rather than 349.8px above it. Nothing looks
      // blank in that state; the end of the answer is simply cut off with no
      // way to reach it.
      //
      // DO NOT justify this by "the two go-to-bottom paths disagree". That
      // reasoning was tried and withdrawn: toBottom() lands via
      // positionViewAtBeginning(), which is item-based but then gets CAPPED by
      // Flickable's own extent, which comes from contentHeight -- so it agrees
      // with whichever ceiling is lower at that instant, not with the delegate
      // one. Measured landing 26.0px and 11.3px short of newestEnd in two of
      // three runs. It is not a trustworthy delegate-derived reference here or
      // anywhere else in this file.
      //
      // The acceptance test is contentY + height == newestEnd AT REST, where
      // newestEnd is itemAtIndex(0). Not lastEnd: that is a max over every
      // built delegate and was measured overshooting newestEnd by 343.3px and
      // 135.4px, because delegates can overlap (see the overlap note in the
      // `ori scroll` probe).
      //
      // The asymmetry with the floor -- which stays on originY -- is
      // principled, not a hack. The ceiling needs only the NEWEST delegate, and
      // the view lives at the newest end, so it is essentially always built.
      // The floor would need the OLDEST, which does not exist until you have
      // scrolled to it; there originY is the only answer available.
      //
      // A function, not a property binding: itemAtIndex() is a call, not a
      // notifying property, so a binding on it would latch whatever it saw the
      // first time and never update again -- silently, which is the worst
      // failure mode on offer.
      function bottomY() {
        var newest = itemAtIndex(0)
        // Null whenever that delegate is not built -- a cold list, or the view
        // parked far enough away that the newest turn is outside the cache.
        // Fall back to the contentHeight expression, which is exactly right
        // whenever nothing has drifted (measured: across 42 fully-built
        // samples the two agree to 0.00px). Never fall back to a constant.
        //
        // THE FALLBACK DEPENDS ON cacheBuffer KEEPING THE WHOLE TRANSCRIPT
        // INSTANTIATED. It is safe today only because the two bad conditions
        // cannot co-occur: drift needs built delegates, and in the first frames
        // of a cold open where index 0 is null, originY ~= -contentHeight and
        // the newest turn ends at ~0, so this expression is exactly right. Cap
        // the buffer -- which was tried and reverted once already, and is
        // queued again -- and "drifted while delegate 0 is unbuilt" becomes
        // reachable, at which point the ceiling silently reverts to the old bug
        // with no error and no warning. Re-check this line if cacheBuffer moves.
        if (!newest) return originY + contentHeight - height
        return newest.y + newest.height - height
      }

      // The range is Qt's, and it has to be READ rather than assumed. Under
      // BottomToTop every append is a PREPEND in list terms, and Qt answers a
      // prepend by MOVING originY -- so the content does not stay at
      // [-contentHeight, 0]. Measured on a 43-turn transcript scrolled to the
      // top with all delegates built, stable across four reads:
      //     contentY=-32889.6 height=487.0 contentHeight=32889.6 yPos=-0.029
      //     originY=-31971.0  real=[-31971.0 .. 431.6]
      //                       assumed=[-32889.6 .. -487.0]
      // The old constants let contentY sit 918.6px BELOW the real floor: the
      // viewport parked in blank space above the oldest turn, yPos went
      // negative and STAYED negative, and further wheel-up did nothing. That is
      // one fault, not two -- the blank gap and "only ctrl+down gets me back"
      // are the same clamp.
      //
      // originY must be READ off the list. It cannot be inferred from delegate
      // `y` values: contentItem.children mixes positioned items with POOLED
      // ones whose stale y lands anywhere. Two reviewers got that wrong.
      //
      // These are a generalisation, not a new rule: with nothing prepended
      // (originY === -contentHeight) they reduce to the old -contentHeight and
      // -height exactly, collapse included. belowBottom and toBottom() above
      // were already origin-independent; this is the same insight, applied here
      // at last.
      function clampScrollY(y) {
        var oldest = originY
        var newest = bottomY()
        if (oldest > newest) oldest = newest
        return Math.max(oldest, Math.min(newest, y))
      }

      // n is in notches: +1 = one wheel notch AWAY from the user (up), i.e.
      // toward older messages, which under this list's measured coordinates
      // means subtracting from contentY.
      function wheelNotches(n) {
        // Re-base on the real position when idle, so a settled glide, a pin
        // that moved the view or a flick since the last notch all land in the
        // target rather than being overridden by it.
        if (!wheelAnim.running) wheelTargetY = contentY
        wheelTargetY = clampScrollY(wheelTargetY - n * wheelStep)
        if (wheelTargetY === contentY) return
        // An upward run is a user gesture that owns the view, exactly like the
        // pixel path's dy < 0: release the stick HERE or the next
        // contentHeight change -- a token landing, or the tool batch folding
        // its tallies after the turn settles -- yanks the view straight back
        // to the bottom mid-read. The pixel path always did this; the notch
        // path never did, and `stuck` outlived the scroll-up.
        if (n > 0) stuck = false
        // A wheel move is a user gesture: it takes the view, so the pin
        // window opened by an append is cancelled rather than fought over.
        pinFrames = 0
        pinTimer.stop()
        // A downward run that lands within the stick slack IS the bottom:
        // snap the last pixels exactly and re-engage the stick. Without this,
        // a wheel run that stopped a few pixels short left the view unstuck
        // for good -- the newest turn kept streaming in unwatched, and only
        // the ctrl+down chord got the bottom back. Scrolling down is wanting
        // the bottom; arriving near it is arriving.
        var newest = bottomY()
        if (n < 0 && newest - wheelTargetY <= stickSlack) {
          wheelTargetY = newest
          stuck = true
        }
        wheelAnim.to = wheelTargetY
        wheelAnim.restart()
      }

      // Touchpad scrolls arrive as PIXELS, at event rate, and are applied
      // 1:1 with no animation of our own -- the deltas are already per-frame
      // smooth, and animating a chase of a target that advances every frame
      // reads as lag. Quantising them into notches (dividing their small
      // angle deltas by 120) was the first attempt here and turned a
      // two-finger drag into a crawl that could not cross a screen, let alone
      // reach the bottom.
      //
      // The downward re-stick below needs downward INTENT, not one stray
      // event: touchpad gestures jitter in both directions, and on a short
      // conversation the whole scroll range sits within the stick slack of
      // the bottom -- a single +2px event in the middle of an upward scroll
      // re-stuck the view and snapped it to the bottom, mid-gesture. So the
      // downward pixels ACCUMULATE, and an upward tick resets the count.
      readonly property real downIntentPx: 16
      property real downAcc: 0

      function wheelPixels(dy) {
        if (wheelAnim.running) wheelAnim.stop()
        pinFrames = 0
        pinTimer.stop()
        wheelTargetY = clampScrollY(contentY + dy)
        wheelingDown = dy > 0
        if (wheelTargetY !== contentY) contentY = wheelTargetY
        // A direct write raises no moving/flick signal to lean on, so the
        // stick is handled here explicitly: scrolling up releases it at once
        // (same no-grace rule as the notched wheel), scrolling into the
        // bottom's slack snaps exactly and re-engages. The stick is handled
        // even when the target clamps to where we already are -- an unstuck
        // view parked at the bottom (a short up-scroll clamped back) must
        // still re-engage on the next downward tick.
        if (dy < 0) {
          downAcc = 0
          stuck = false
        } else if (visibleArea.heightRatio > 0.01 && belowBottom <= stickSlack) {
          downAcc += dy
          if (downAcc >= downIntentPx) {
            downAcc = 0
            contentY = bottomY()
            stuck = true
          }
        } else {
          downAcc = 0
        }
      }

      NumberAnimation {
        id: wheelAnim
        target: transcript
        property: "contentY"
        duration: 180
        easing.type: Easing.OutCubic
      }

      // The floor MOVES, and a scroll already in flight was aimed at where it
      // used to be. clampScrollY reads the bounds at the instant a gesture is
      // issued; when the first delegates of a cold open finish building, Qt
      // re-measures and originY walks up by the estimate error -- so an aim
      // that was legal a frame ago is now below the floor. Measured on a cold
      // open, four times out of four -- BY A REVIEWER, not by this harness.
      //
      // Why it resists being forced, which is the useful part: originY only
      // swings during a COLD BUILD. On a warm list under active streaming a
      // reviewer measured 145 samples with ONE distinct originY and a 0px
      // swing, while cold opens swung 77,901px and 95,679px. So this handler is
      // dormant exactly where the reverted 17,215px regression used to live.
      // Fifteen controls run here never reproduced it because they were not
      // cold in the right way.
      //
      //   t=1.03  contentY=-49198.8  originY=-52638.6  children=62  gap=0
      //             <- four delegates build; originY rises by 2085.8
      //   t=1.08  contentY=-50765.1  originY=-50552.8  children=66  gap=212
      //   t=1.24  contentY=-52638.6  originY=-50552.8  below=2085.8 gap=487
      //   t=1.54  contentY=-50552.8  originY=-50552.8  below=0.0    gap=0
      //
      // contentY lands on -52638.6, the OLD originY, to the decimal: the glide
      // kept driving to its stale target, so the overshoot GREW to 2085.8px
      // and the viewport was entirely blank (gap=487, the full height) for
      // ~370ms of a ~460ms excursion. Flickable's own returnToBounds() does
      // clean it up, but only afterwards and over ~140ms more.
      //
      // WHAT THIS FIXES, AND WHAT IT DOES NOT. It is a ~13x improvement, not a
      // cure, and the next person must not take zero as the baseline. After the
      // fix, 10 of 10 cold opens STILL show a floor excursion: peak 303.4px,
      // duration 0-127ms -- 303px of blank in a 487px viewport. Down from
      // 2,085.8-4,570.6px over 430-460ms, so it is worth having, but "0.0px /
      // 0ms / 0 blanks" is not reproducible and was never true.
      // The residue is most likely itemAtIndex(0) holding a mid-relayout
      // position at the instant this handler fires, leaving the range it clamps
      // against one frame stale. Deliberately NOT chased -- the remaining
      // window is a fraction of a frame's worth of blank and the fix for it
      // lives in delegate sizing, not here.
      //
      // Guarded on the stick because every queued correction in this file is:
      // while stuck, toBottom() and the pin own contentY and a second writer
      // would fight them. `dragging` is excluded for the same reason -- a
      // finger on the surface owns the view, and Flickable does its own
      // bounds handling with overshoot while it is down.
      //
      // This is NOT the reverted clamp. That one shifted the reading anchor on
      // every contentHeight change, unconditionally, against a floor that was
      // wrong -- and threw the view ~17,000px backward mid-answer. This fires
      // only when contentY is genuinely outside the range, and the range is
      // now read from originY. Writing contentY here can move originY again,
      // which re-enters this handler; it terminates because the second pass
      // finds the value already in bounds and writes nothing.
      onOriginYChanged: {
        if (transcript.stuck || transcript.dragging) return
        // Re-aim an in-flight glide. Setting `to` on a running NumberAnimation
        // does not move a target Qt has already latched, so it has to be
        // restarted -- from wherever the view is now, which keeps the
        // correction a continuation of the same movement rather than a jump.
        //
        // Only an aim that has fallen OUTSIDE the range is corrected. A stale
        // aim left INSIDE it is deliberately left alone, and that is a decision
        // rather than an oversight: measured 4/4 with this handler off, a glide
        // aimed at the floor as it stood when the notch was issued landed at
        // -34004.1 and stopped 11,177.7px short of the floor as it ended up.
        // Tempting to "fix" -- but a notch means "move N x 110px", not "travel
        // to the end", and re-extending it would silently turn the user's input
        // into a gesture they did not make. Stopping short costs another notch;
        // overshooting past the newest turn is not recoverable at all. Leave it.
        var aim = transcript.clampScrollY(transcript.wheelTargetY)
        if (aim !== transcript.wheelTargetY) {
          transcript.wheelTargetY = aim
          if (wheelAnim.running) {
            wheelAnim.to = aim
            wheelAnim.restart()
          }
        }
        // The pixel path writes contentY directly and has no target to re-aim,
        // so a position that was legal when written is simply left outside the
        // new range -- same blank viewport, no animation involved. Correcting
        // contentY covers that path, the notched one, and goTop(), which
        // unsticks and then positions with no correction of its own.
        var fixed = transcript.clampScrollY(transcript.contentY)
        if (fixed !== transcript.contentY) transcript.contentY = fixed
      }

      // Corrected every frame the content changes, NOT animated. An animation
      // on contentY would be chasing a target that moves again every ~40ms
      // while tokens land, so it would never arrive and would read as
      // permanent lag. Held exactly at the edge, the newest line stays put and
      // the text flows up past it, which is what "smooth" means here.
      // callLater because the delegate heights settle after the model change:
      // positioning on the same frame uses the layout the change invalidated.
      // Corrected on THIS frame and again on the next, not only on the next.
      //
      // callLater alone is what the user saw as "a scrolling jump back and
      // forth, very little but noticeable" while the agent ran command after
      // command: the content grows, the view paints once at the OLD position
      // because the correction has not run yet, and lands on the next frame.
      // One command does that once and it passes for streaming; a tool loop
      // does it several times a second and it reads as the transcript
      // twitching.
      //
      // The immediate call kills that frame. The callLater is still needed
      // behind it, because delegate heights settle AFTER the model change and
      // a correction on the same frame uses the layout the change invalidated
      // -- so the first lands the common case and the second catches the late
      // one. Together they are silent; either alone is not.
      onContentHeightChanged: {
        // Remember the growth: while unstuck it is exactly how far the
        // reading view has to shift to stay still (below).
        var grew = contentHeight - transcript.lastContentHeight
        transcript.lastContentHeight = contentHeight
        if (!transcript.stuck) {
          // An unstuck view anchors to the CONTENT, not to the newest
          // message. Under this direction the live row grows at content y 0
          // and every word above it slides up token by token -- the
          // tug-of-war that made scrolling up mid-answer feel like fighting
          // the stick. Shifting the viewport by the growth keeps the reading
          // position put. Skipped mid-gesture (a drag or a glide owns
          // contentY then) and caught up on the next change.
          if (grew !== 0 && !transcript.moving && !wheelAnim.running
              && transcript.visibleArea.heightRatio > 0.01)
            transcript.contentY = transcript.clampScrollY(transcript.contentY - grew)
          return
        }
        transcript.toBottom()
        // Queued corrections are GUARDED on the stick: a callLater lands
        // after everything else in the current event-loop turn, and a wheel
        // notch that arrived in between has by then released the stick --
        // firing a stale correction then would stop a glide the user just
        // started (measured in the test harness: every glide started in the
        // same turn as a goBottom died exactly this way).
        Qt.callLater(function () { if (transcript.stuck) transcript.toBottom() })
        // A re-wrap mid-stream can move content across frames without a new
        // append; keep the pin window open so a frame that landed short is
        // corrected by the next one rather than by the token after it.
        transcript.pin()
      }

      Connections {
        target: PiSession
        function onAppended() {
          if (!transcript.stuck) return
          transcript.toBottom()
          Qt.callLater(function () { if (transcript.stuck) transcript.toBottom() })
          transcript.pin()
        }
        // The user's own message. Different contract from onAppended: an
        // append landing while they are scrolled up reading is theirs to
        // ignore, but the message they just sent comes with the expectation
        // of watching the answer arrive under it -- so the view goes to the
        // bottom for this one whatever the scroll position was.
        function onAsked() { transcript.goBottom() }
      }

      // Only a move the USER caused may change whether we are stuck. Qt raises
      // `moving` for a wheel or a drag and leaves it false for
      // positionViewAtBeginning(), which is the whole reason the stick cannot
      // unstick itself -- and the reason scrolling up is never overruled.
      //
      // Both paths are GUARDED on heightRatio. Mid-settle, after an append,
      // the viewport can sit briefly outside the laid-out region -- the same
      // stale-heights moment the pin exists for -- and there visibleArea
      // collapses toward heightRatio 0 and belowBottom lies, reporting the
      // view far from the bottom. Recomputing `stuck` from that figure unstuck
      // the pin exactly during the frames it was correcting for, and the
      // settle then finished under a view left parked on an older message.
      // A real viewport always has height; a lie does not.
      onMovingChanged: {
        if (transcript.moving) {
          // The user has taken the view: release at once. The first pixels
          // of a scroll up must not sit inside the slack getting yanked
          // back by the next token.
          wheelAnim.stop()
          if (transcript.visibleArea.heightRatio > 0.01) transcript.stuck = false
          return
        }
        // The gesture settled. Within the slack of the bottom means wanting
        // the bottom: snap exactly and re-engage the stick.
        if (transcript.visibleArea.heightRatio < 0.01) return
        if (transcript.belowBottom <= transcript.stickSlack) {
          transcript.stuck = true
          transcript.toBottom()
        } else {
          transcript.stuck = false
        }
      }
      // Re-stick ONLY, and only on downward motion: a contentY tick elsewhere
      // must never release the stick (releasing is explicit -- the wheel up,
      // the pixel scroll up, the flick taking the view), and must never fire
      // during an upward glide passing back through the slack zone.
      onContentYChanged: {
        var engaged = transcript.moving
          || (wheelAnim.running && transcript.wheelingDown)
        if (!engaged || transcript.visibleArea.heightRatio < 0.01) return
        if (transcript.belowBottom <= transcript.stickSlack) transcript.stuck = true
      }
    }

    // The transcript's wheel face. A SIBLING of the list, not a child: a
    // Flickable with content SMALLER than its viewport stops delivering wheel
    // events to anything inside it (measured), which on a fresh session is
    // exactly the state of this list -- a brand-new conversation would have
    // been deaf to the wheel. Anchored to the list and declared right after
    // it, so it sits above the delegates and below the session picker.
    MouseArea {
      anchors.fill: transcript
      acceptedButtons: Qt.NoButton
      onWheel: function (w) {
        // A touchpad scroll carries pixel deltas and goes 1:1; a discrete
        // mouse wheel has angles only and takes the animated-notch path.
        var pd = w.pixelDelta
        if (pd && (pd.x !== 0 || pd.y !== 0))
          transcript.wheelPixels(-pd.y)
        else
          transcript.wheelNotches(w.angleDelta.y / 120)
      }
    }

    // ----------------------------------------------------------------- toast
    // Says a selection reached the clipboard. It exists because the copy is
    // SILENT otherwise: selecting text is something you do all the time without
    // meaning anything by it, so a copy that leaves no trace is indistinguishable
    // from nothing having happened, and you would reach for Ctrl+C anyway.
    //
    // Over the composer rather than over the transcript, so it never covers the
    // words that were just copied. Bound to Copy.at rather than to a signal:
    // copying again while it is still up restarts this one instead of stacking
    // a second.
    Rectangle {
      id: toast
      anchors { right: composer.right; bottom: composer.top; rightMargin: 12; bottomMargin: 6 }
      width: toastText.implicitWidth + 20
      height: toastText.implicitHeight + 10
      radius: height / 2
      color: Theme.surface1
      opacity: 0
      visible: opacity > 0

      Text {
        id: toastText
        anchors.centerIn: parent
        text: "copied"
        color: Theme.subtext0
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }

      Connections {
        target: Copy
        function onAtChanged() { if (Copy.at > 0) life.restart() }
      }

      // The animation IS the lifetime -- one timeline, no second clock, the
      // same shape NotificationCard uses.
      SequentialAnimation {
        id: life
        NumberAnimation { target: toast; property: "opacity"; to: 1
                          duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
        PauseAnimation { duration: 900 }
        NumberAnimation { target: toast; property: "opacity"; to: 0
                          duration: Style.anim.reveal; easing.type: Style.anim.easingSmooth }
      }
    }

    // Ctrl+R. Sits exactly over the transcript rather than over the whole card,
    // so the composer and the footer stay visible and the panel never stops
    // looking like the same panel.
    SessionPicker {
      id: picker
      anchors.fill: transcript
      accent: panel.accent
      returnFocus: entry
    }

    // A scroll position, not a scrollbar: there is nothing to grab, it only
    // says how much transcript is above you. Hidden entirely when everything
    // fits, which is most of the time.
    Rectangle {
      width: 2
      radius: 1
      x: transcript.x + transcript.width - 3
      // visibleArea is reported in the list's own coordinates, which BottomToTop
      // has already flipped -- at rest, parked on the newest turn, yPosition is
      // (1 - heightRatio) and the thumb belongs at the bottom. Compensating for
      // the flip a second time (the first thing tried here) pinned it to the
      // top and had it travel the wrong way.
      y: transcript.y + transcript.visibleArea.yPosition * transcript.height
      height: Math.max(20, transcript.visibleArea.heightRatio * transcript.height)
      visible: transcript.visibleArea.heightRatio < 0.999
      color: Theme.alpha(Theme.overlay0, transcript.moving ? 0.9 : 0.35)

      Behavior on color {
        ColorAnimation { duration: Style.anim.normal; easing.type: Style.anim.easingSmooth }
      }
    }

    // ------------------------------------------------------------ empty state
    // What it is, where it runs, and how to drive it -- in place of a blank
    // rectangle. The mark is dormant here: nothing is running, so nothing moves.
    Column {
      anchors.centerIn: transcript
      width: transcript.width - 40
      spacing: 6
      visible: PiSession.turns.count === 0
      opacity: 0.9

      OriMark {
        anchors.horizontalCenter: parent.horizontalCenter
        width: 34; height: 34
        accent: panel.accent
      }

      Item { width: 1; height: 8 }

      // Not "Ask me anything" -- what it actually is. The model and the
      // directory are already on the chrome; this is the sentence that says
      // why those two facts matter.
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        horizontalAlignment: Text.AlignHCenter
        width: parent.width - 60
        text: "It runs in this repo, on this machine,\nwith a shell."
        color: Theme.subtext0
        wrapMode: Text.Wrap
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }

      Item { width: 1; height: 10 }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        horizontalAlignment: Text.AlignHCenter
        text: "enter send · shift+enter newline\nctrl+n new · ctrl+c stop · esc close"
        color: Theme.alpha(Theme.overlay0, 0.75)
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }
    }

    // Slash completion. Anchored to the composer rather than filling the
    // transcript the way the picker does: it is an extension of the field you
    // are typing in, so it grows up out of it and leaves the conversation
    // visible above. It rests on the rail, which is zero-high while nothing is
    // running -- so at rest it sits straight on the composer, and mid-turn it
    // moves up off the live line instead of burying it.
    //
    // Declared LAST of the things that share the transcript's box, because
    // painting order here is declaration order and both the scroll thumb and
    // the empty state would otherwise draw through it. The empty state is the
    // one that matters: a brand new conversation is exactly when someone types
    // a slash to find out what there is.
    CommandBar {
      id: commands
      anchors { left: transcript.left; right: transcript.right
                bottom: rail.top; bottomMargin: 4 }
      height: implicitHeight
      accent: panel.accent
      entry: entry
    }

    // ------------------------------------------------------------------ speak
    // Speech gets its own strip, separate from the tray: "you are being
    // spoken to" is a different sentence from "a task is running", and both
    // can be true at once. Yellow, breathing, gone the moment it ends.
    Rectangle {
      id: speakStrip
      anchors { left: parent.left; right: parent.right; bottom: tray.top
                leftMargin: 10; rightMargin: 10; bottomMargin: 4 }
      height: PiSession.speakJob ? 24 : 0
      visible: height > 0
      color: Theme.alpha(Theme.yellow, 0.10)
      radius: 6
      clip: true

      Behavior on height {
        NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing }
      }

      Text {
        id: speakMark
        anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
        text: "🔈"
        opacity: panel.breath
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }

      Text {
        anchors { left: speakMark.right; leftMargin: 8; right: speakAge.left; rightMargin: 8
                  verticalCenter: parent.verticalCenter }
        text: String(PiSession.speakJob ? PiSession.speakJob.label || "speaking" : "")
        color: Theme.subtext0
        elide: Text.ElideRight
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }

      Text {
        id: speakAge
        anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
        text: PiSession.speakJob ? fmt.duration(panel.nowMs - PiSession.speakJob.since) : ""
        color: Theme.overlay0
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }
    }

    // ------------------------------------------------------------------ tray
    // Above the rail, below the conversation. Zero-high when nothing is
    // running, so an idle panel is exactly what it was.
    BackgroundTray {
      id: tray
      anchors { left: parent.left; right: parent.right; bottom: rail.top
                leftMargin: 10; rightMargin: 10; bottomMargin: 4 }
      accent: Theme.accent
      nowMs: panel.nowMs
      breath: panel.breath
    }

    // ------------------------------------------------------------------ rail
    // The live line, in the same place Claude Code puts its spinner: directly
    // above where you type. It describes the turn IN FLIGHT and nothing else --
    // what state it is in, how long it has been in it, and how much has come
    // back so far. It collapses to nothing the moment the agent settles, which
    // is the point: an idle assistant should take up no room saying so.
    Item {
      id: rail
      anchors { left: parent.left; right: parent.right; bottom: errorStrip.top
                leftMargin: card.border.width; rightMargin: card.border.width }
      height: PiSession.busy ? 28 : 0
      clip: true

      Behavior on height {
        NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
      }

      // The scan. A single highlight crossing the top edge of the rail, at a
      // pace nothing else in this shell moves at -- it is ambient, not a state
      // change, and it is the one thing on the surface that says "still
      // working" without saying a word. It is bound to the frame clock, so it
      // stops dead, mid-track, when the turn ends.
      Item {
        id: scanTrack
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 1
        clip: true

        Rectangle {
          anchors.fill: parent
          color: Theme.surface1
          opacity: 0.6
        }

        Rectangle {
          width: 130
          height: 1
          x: (scanTrack.width + width)
             * ((clock.elapsedTime * 1000) % Style.ori.scanMs) / Style.ori.scanMs - width
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Theme.transparent }
            GradientStop { position: 0.5; color: panel.accent }
            GradientStop { position: 1.0; color: Theme.transparent }
          }
        }
      }

      Text {
        id: verb
        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
        // Capped, so a long verb never squeezes the sentence beside it to
        // nothing: the verb is four words the eye already knows and the detail
        // is the part actually worth reading.
        width: Math.min(implicitWidth, parent.width * 0.32)
        text: panel.stateLabel
        color: panel.accent
        elide: Text.ElideRight
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        font.weight: Style.font.boldWeight
        renderType: Text.QtRendering

        Behavior on color {
          ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
        }
      }

      // The intent of the call in flight. Quiet, because the verb beside it is
      // the state and this is the footnote to it -- and one line, elided, since
      // the rail is 28px and a description that wrapped would resize a layer
      // surface mid-turn.
      Text {
        id: detail
        anchors { left: verb.right; leftMargin: 8; right: readout.left; rightMargin: 8
                  verticalCenter: parent.verticalCenter }
        text: panel.stateDetail
        color: Theme.subtext0
        elide: Text.ElideRight
        maximumLineCount: 1
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }

      // Elapsed, and what has come back for it. Both are on the right because
      // they change every frame, and a number that twitches under the first
      // word of a sentence is unreadable.
      Text {
        id: readout
        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
        text: !PiSession.busy ? ""
          : fmt.duration(panel.elapsedMs)
            + (PiSession.liveTokens > 0 ? "  ↓ " + fmt.tokens(PiSession.liveTokens) : "")
        color: Theme.overlay0
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }
    }

    // ----------------------------------------------------------------- error
    Rectangle {
      id: errorStrip
      anchors { left: parent.left; right: parent.right; bottom: composer.top
                leftMargin: card.border.width; rightMargin: card.border.width }
      height: PiSession.error !== "" || PiSession.notice !== ""
              ? errText.implicitHeight + 12 : 0
      color: PiSession.error !== "" ? Theme.alpha(Theme.red, 0.15)
                                    : Theme.alpha(Theme.sapphire, 0.12)
      clip: true

      Behavior on height {
        NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
      }

      Text {
        id: errText
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 6 }
        text: PiSession.error !== "" ? PiSession.error : PiSession.notice
        color: PiSession.error !== "" ? Theme.red : Theme.subtext0
        wrapMode: Text.Wrap
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }
    }

    // -------------------------------------------------------------- composer
    Rectangle {
      id: composer
      anchors { left: parent.left; right: parent.right; bottom: footer.top
                leftMargin: card.border.width; rightMargin: card.border.width }
      // Grows with the draft up to a ceiling, then the field scrolls. The card
      // is a fixed size, so this only moves the boundary between the two panes.
      height: Math.min(entry.implicitHeight, 120) + 20
      color: Theme.surface0
      // No border tint here either: the effort readout lives in the footer --
      // the level's own word carrying the colour -- after the full-card border
      // flash AND a tinted field edge were both tried and disliked. The field
      // stays quiet.
      border.width: 0

      Behavior on height {
        NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing }
      }

      // The prompt. It lights with the accent while the cursor is in the field,
      // which is the only affordance this panel needs for "the keyboard is
      // here" -- the layer surface takes focus on demand, so that is a real
      // question and not a decorative one.
      Text {
        id: caret
        anchors { left: parent.left; leftMargin: 12; top: parent.top; topMargin: 10 }
        text: "⟩"
        color: entry.activeFocus ? panel.accent : Theme.overlay0
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelBody
        renderType: Text.QtRendering

        Behavior on color {
          ColorAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
        }
      }

      // The scrollable draft. TextEdit never scrolls by itself: past the
      // 120px ceiling the field just clipped, and what was typed beyond the
      // edge was written blind. The standard arrangement is the fix -- the
      // field keeps its natural height inside a Flickable, and the caret is
      // followed (onCursorRectangleChanged), so typing or arrowing past the
      // visible edge scrolls just enough to bring the line into view.
      Flickable {
        id: entryScroll
        anchors { fill: parent; leftMargin: 30; rightMargin: 12; topMargin: 10; bottomMargin: 10 }
        contentWidth: width
        contentHeight: entry.implicitHeight
        clip: true
        // A drag inside a TextEdit is a text selection, so the pane is not
        // itself draggable; it is scrolled by the wheel below and by the caret.
        interactive: false

        function ensureVisible(r) {
          if (r.y < contentY) contentY = r.y
          else if (r.y + r.height > contentY + height) contentY = r.y + r.height - height
          contentY = Math.max(0, Math.min(contentY, Math.max(0, contentHeight - height)))
        }

        TextEdit {
          id: entry
          // Width only: the height must stay the field's own implicitHeight
          // for contentHeight above to be the real draft length. Anchoring
          // both edges would pin the field to the viewport height and scroll
          // it INTERNALLY instead -- the exact blind-writing failure this
          // exists to fix.
          width: parent.width

          color: Theme.text
        selectionColor: Theme.sapphire
        selectedTextColor: Theme.base
        selectByMouse: true
        wrapMode: TextEdit.Wrap
        font.family: Style.font.panelFamily
        font.pixelSize: Style.font.panelBody
        renderType: Text.QtRendering
        clip: true

        Text {
          anchors.fill: parent
          visible: entry.text === ""
          // While a turn runs the field is refused, so it says what the key
          // that DOES do something is, rather than inviting a message that
          // would be dropped.
          text: PiSession.busy ? "ctrl+c to stop" : "ask anything — / for commands"
          color: Theme.overlay0
          font.family: Style.font.panelFamily
          font.pixelSize: Style.font.panelBody
          renderType: Text.QtRendering
        }

        Keys.onPressed: function (event) {
          // The completion list gets first refusal, so while it is up ↑↓ move
          // it, ⇥/⏎ complete, and Escape dismisses it instead of closing the
          // panel. It claims nothing while it is shut, and it never claims the
          // Ctrl chords below -- those keep working mid-completion.
          if (commands.handleKey(event)) {
            event.accepted = true
            return
          }
          switch (event.key) {
          case Qt.Key_Down:
            // Ctrl+Down: the newest turn, and stick there again.
            // Ctrl+Up: the oldest. Asked for by name, in place of the Ctrl+End
            // this used to be -- a pair of arrows says which way it goes,
            // where End only says "the end" of something the panel has two of.
            // Hyprland binds SUPER and SUPER+CTRL arrows, not bare Ctrl ones,
            // so nothing upstream swallows these.
            if (event.modifiers & Qt.ControlModifier) {
              transcript.goBottom()
              event.accepted = true
            }
            return
          case Qt.Key_Up:
            if (event.modifiers & Qt.ControlModifier) {
              transcript.goTop()
              event.accepted = true
            }
            return
          case Qt.Key_Tab:
          // Qt folds Shift+Tab into a Backtab key before an event handler ever
          // sees a Key_Tab with ShiftModifier -- the same reason the share
          // picker's grid keys on Backtab. Only the shifted chord is claimed;
          // a bare Tab falls through to the TextEdit's default untouched, and
          // the completion list already had first refusal above.
          case Qt.Key_Backtab:
            if (event.modifiers & Qt.ShiftModifier || event.key === Qt.Key_Backtab) {
              PiSession.cycleEffort()
              event.accepted = true
              return
            }
            return
          case Qt.Key_Return:
          case Qt.Key_Enter:
            // Shift+Enter is a newline; a bare Enter sends. The multi-line field
            // exists for pasting a stack trace, not for composing essays.
            if (event.modifiers & Qt.ShiftModifier) return
            // Only clear the draft if it was actually taken. Asking while a turn
            // is still running is refused, and clearing anyway would delete what
            // you just typed with nothing to show for it.
            if (PiSession.ask(entry.text, PiSession.takeAttachments(entry.text)))
              entry.text = ""
            event.accepted = true
            return
          case Qt.Key_Escape:
            panel.close()
            event.accepted = true
            return
          case Qt.Key_N:
            if (event.modifiers & Qt.ControlModifier) {
              PiSession.newChat()
              event.accepted = true
            }
            return
          case Qt.Key_R:
            // Ctrl+R for history, the shell's own gesture for it. The picker
            // wants the keyboard and the completion list assumes it does not
            // have it, so only one of the two may be up at a time.
            if (event.modifiers & Qt.ControlModifier) {
              commands.close()
              picker.open()
              event.accepted = true
            }
            return
          case Qt.Key_V:
            // NOT accepted: whether the clipboard holds an image is only known
            // once wl-paste has answered, so the field's own paste has to be
            // allowed to run. It inserts nothing when the clipboard offers no
            // text, which is exactly the case where an image is attached.
            if (event.modifiers & Qt.ControlModifier) PiSession.pasteImage()
            return
          case Qt.Key_C:
            // Ctrl+C stops the model; with a selection it is a copy, so only
            // claim it while something is actually running and nothing is selected.
            if ((event.modifiers & Qt.ControlModifier) && PiSession.busy
                && entry.selectedText === "") {
              PiSession.abort()
              event.accepted = true
            }
            return
          }
        }

          // Follow the caret. cursorRectangle is in the field's own
          // coordinates, which are the pane's content coordinates: the field
          // sits at 0,0 inside it.
          onCursorRectangleChanged: entryScroll.ensureVisible(entry.cursorRectangle)
        }
      }

      // Wheel over the draft. A SIBLING of the Flickable, not a child: while
      // the draft is SHORTER than the pane, a Flickable stops delivering wheel
      // events to anything inside it (measured -- the short-draft case went
      // deaf, and that is exactly the case that must forward to the
      // transcript). While the text overflows the pane it scrolls the draft;
      // when the draft fits, the gesture is handed to the transcript, so a
      // short field never eats the wheel. No buttons accepted, so clicks and
      // text selection pass through to the field.
      MouseArea {
        anchors.fill: entryScroll
        acceptedButtons: Qt.NoButton
        onWheel: function (w) {
          var pd = w.pixelDelta
          var down = pd && pd.y !== 0 ? -pd.y : -(w.angleDelta.y / 120) * 44
          if (entryScroll.contentHeight > entryScroll.height + 1) {
            entryScroll.contentY = Math.max(0,
              Math.min(entryScroll.contentY + down,
                       entryScroll.contentHeight - entryScroll.height))
          } else if (pd && (pd.x !== 0 || pd.y !== 0)) {
            transcript.wheelPixels(-pd.y)
          } else {
            transcript.wheelNotches(w.angleDelta.y / 120)
          }
          w.accepted = true
        }
      }
    }

    // ---------------------------------------------------------------- footer
    // The status line, where a terminal agent keeps one: model, and how full the
    // window is. The gauge is the strip's own top edge rather than a widget on
    // it -- the panel runs out of context along that line, so that line is where
    // it should be visible.
    Rectangle {
      id: footer
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                margins: card.border.width }
      height: 24
      color: Theme.mantle
      bottomLeftRadius: card.radius - card.border.width
      bottomRightRadius: card.radius - card.border.width

      Rectangle {
        id: gaugeTrack
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 2
        color: Theme.surface0

        Rectangle {
          anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
          width: parent.width * PiSession.contextFraction
          color: PiSession.contextFraction < 0.7 ? Theme.sapphire
            : PiSession.contextFraction < 0.9 ? Theme.yellow : Theme.red

          Behavior on width {
            NumberAnimation { duration: Style.anim.normal; easing.type: Style.anim.easing }
          }
          Behavior on color {
            ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
          }
        }
      }

      // Model, and the thinking level beside it. Both are what `/model` and
      // `/effort` change, and this is the whole of what those commands SHOW --
      // deliberately, because a state readout that already existed is a better
      // confirmation than a message announcing a change: it is still true five
      // minutes later, and it reports the level pi actually settled on rather
      // than the one that was asked for. set_thinking_level clamps silently
      // (`max` becomes `high` on this model), so the two can differ, and the
      // one worth showing is this one.
      //
      // The level, pinned to the right of the left slot so it cannot be elided
      // away. It is written before the model below purely so the model can
      // anchor to it.
      //
      // Two elements rather than one string, which was the first attempt and was
      // wrong on measurement. This strip is 460px carrying four readouts, and
      // the model is the only one that grows: bound
      // `moonshotai/Kimi-K2-Instruct-0905  ·  minimal` to the ~180px this slot
      // has and ElideRight eats the level first, every time -- including on the
      // default model, where `deepseek-v4-flash:0731  ·  medium` wants 250px. So
      // the level would vanish exactly when someone had just set it, which is
      // the one moment it has to be readable.
      //
      // Blank until a child has reported one, so a panel that has never run says
      // nothing rather than guessing, and the model gets the whole slot back.
      Text {
        id: effortText
        anchors { right: planUsage.left; rightMargin: 10
                  verticalCenter: parent.verticalCenter; verticalCenterOffset: 1 }
        // Carries its own separator, so that the dot goes with the level rather
        // than being left stranded on the end of an elided model id.
        text: PiSession.effortLabel !== "" ? "·  " + PiSession.effortLabel : ""
        // The effort readout: the word itself is the indicator, in the same
        // heat scale everywhere else in pi speaks effort -- neutral for off,
        // then blue, yellow, red as the thinking level rises. One word, in the
        // line the eye already reads for state; nothing else on the panel
        // changes colour for it.
        color: panel.effortColor(PiSession.effortLabel)
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }

      // The model. Both this and the level are what `/model` and `/effort`
      // change, and this pair is the whole of what those commands SHOW --
      // deliberately, because a state readout that already existed is a better
      // confirmation than a message announcing a change: it is still true five
      // minutes later, and it reports the level pi actually settled on rather
      // than the one that was asked for. set_thinking_level clamps silently
      // (`max` becomes `high` on deepseek-v4-flash:0731), so the two can differ,
      // and the one worth showing is this one.
      //
      // The right anchor is what makes the ElideRight below real -- it was
      // declared here long before any of this and could never fire, because
      // nothing bounded the label's width. Now a long id is cut off at the level
      // rather than printed straight through it.
      Text {
        anchors { left: parent.left; leftMargin: 12
                  right: effortText.left; rightMargin: PiSession.effortLabel === "" ? 0 : 8
                  verticalCenter: parent.verticalCenter
                  verticalCenterOffset: 1 }
        text: PiSession.model
        color: Theme.overlay0
        elide: Text.ElideRight
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }

      // Real numbers, in the order they become knowable: nothing before a
      // session exists, then the running token total once usage starts
      // streaming, then a percentage once the session has reported its window.
      // A window this shell has not been told is never guessed at.
      Text {
        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter
                  verticalCenterOffset: 1 }
        text: panel.contextLabel + " ctx · " + panel.rateLabel
        color: Theme.overlay0
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }

      // How much of the Ollama Cloud plan is left. The third "how much is left"
      // number on this strip, and the only one the conversation cannot give
      // back: clearing the transcript empties the context gauge beside it and
      // moves this one not at all. One window rather than two, and a dash
      // rather than a zero when it does not know -- see Usage.qml for both.
      // A hairline where the plan readout sits when it has nothing to say, so
      // the wide gap between the model and the ctx numbers reads as a deliberate
      // split rather than missing text.
      Rectangle {
        anchors { horizontalCenter: parent.horizontalCenter
                  verticalCenter: parent.verticalCenter; verticalCenterOffset: 1 }
        width: 1; height: 12
        visible: Usage.label === ""
        color: Theme.alpha(Theme.overlay0, 0.35)
      }

      Text {
        id: planUsage
        anchors { horizontalCenter: parent.horizontalCenter
                  verticalCenter: parent.verticalCenter; verticalCenterOffset: 1 }
        text: Usage.label
        color: Usage.tint
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering

        Behavior on color {
          ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
        }
      }
    }
  }
}
