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

  readonly property int panelWidth: 460

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
    : PiSession.warm ? Theme.sapphire
    : Theme.inactive

  // The verb, in the panel's own vocabulary. "thinking" and "answering" are
  // different states and the difference is visible from across the room: one is
  // silence, the other is text arriving.
  readonly property string stateLabel:
      PiSession.error !== "" ? "error"
    : PiSession.activeTool !== "" ? "running " + PiSession.activeTool.split(" ")[0]
    : !PiSession.busy ? ""
    : (PiSession.liveTurn && PiSession.liveTurn.text !== "") ? "answering" : "thinking"

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
    var out = fmt.tokens(PiSession.usageTotal)
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

  FrameAnimation {
    id: clock
    running: panel.opened && PiSession.busy
    onTriggered: panel.nowMs = Date.now()
  }

  readonly property real elapsedMs:
    PiSession.turnStartedAt > 0 ? Math.max(0, panel.nowMs - PiSession.turnStartedAt) : 0

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

  // ------------------------------------------------------------------- card
  Rectangle {
    id: card

    // Floating, not docked: inset from every edge and short of full height, so
    // it reads as a console resting on the desktop rather than a sidebar welded
    // to it. The surface behind it is still fixed-size -- only the card moves.
    width: panel.panelWidth
    height: Math.round(parent.height * 0.72)
    anchors.verticalCenter: parent.verticalCenter
    // Slides in from the left edge it is anchored to.
    x: 16 - (1 - panel.revealed) * (width + 32)
    opacity: panel.revealed

    color: Theme.base
    radius: 16
    border.width: 2
    // The edge of the card is the furthest-away readout there is: dim when
    // nothing is happening, lit in the accent of whatever is.
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
        font.family: Style.font.family
        font.pixelSize: Style.font.panelBody
        font.weight: Style.font.boldWeight
        renderType: Text.NativeRendering
      }

      // Where it runs. This is the whole "it manages this machine" claim, and
      // it belongs where a terminal agent puts its working directory: on the
      // chrome, permanently, not in an about box.
      Text {
        anchors { right: newBtn.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
        text: PiSession.workdir
        color: Theme.overlay0
        font.family: Style.font.family
        font.pixelSize: Style.font.panelMeta
        renderType: Text.NativeRendering
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
          font.family: Style.font.family
          font.pixelSize: Style.font.panelBody
          renderType: Text.NativeRendering
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
        bottom: rail.top
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

      // `nowMs` is the panel's own frame clock, handed to the delegates so the
      // live tool batch can count its elapsed time off the same tick as the
      // rail -- and stop dead with it when the turn settles.
      delegate: TurnDelegate { accent: panel.accent; nowMs: panel.nowMs }

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
        // index 0 under BottomToTop is the NEWEST turn, at the bottom edge --
        // the delegate reads its row back through `count - 1 - index`. So the
        // beginning of the content is the bottom of the conversation.
        transcript.positionViewAtBeginning()
      }

      function goBottom() {
        transcript.stuck = true
        transcript.toBottom()
        // Again next frame. A single call uses whatever delegate heights are
        // current, and after a model change or a first show they are not final
        // yet -- the list then lands short and stays there, because nothing
        // else is going to correct a position the user asked for by hand.
        Qt.callLater(transcript.toBottom)
      }

      // The other end. Unsticks, because arriving at the oldest turn and then
      // being dragged back the moment a token lands would make the key useless.
      function goTop() {
        transcript.stuck = false
        transcript.positionViewAtEnd()
      }

      // Corrected every frame the content changes, NOT animated. An animation
      // on contentY would be chasing a target that moves again every ~40ms
      // while tokens land, so it would never arrive and would read as
      // permanent lag. Held exactly at the edge, the newest line stays put and
      // the text flows up past it, which is what "smooth" means here.
      // callLater because the delegate heights settle after the model change:
      // positioning on the same frame uses the layout the change invalidated.
      onContentHeightChanged: if (transcript.stuck) Qt.callLater(transcript.toBottom)

      Connections {
        target: PiSession
        function onAppended() { if (transcript.stuck) Qt.callLater(transcript.toBottom) }
      }

      // Only a move the USER caused may change whether we are stuck. Qt raises
      // `moving` for a wheel or a drag and leaves it false for
      // positionViewAtBeginning(), which is the whole reason the stick cannot
      // unstick itself -- and the reason scrolling up is never overruled.
      onMovingChanged: transcript.stuck = transcript.belowBottom <= transcript.stickSlack
      onContentYChanged: if (transcript.moving)
          transcript.stuck = transcript.belowBottom <= transcript.stickSlack
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
        font.family: Style.font.family
        font.pixelSize: Style.font.panelMeta
        renderType: Text.NativeRendering
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
        font.family: Style.font.family
        font.pixelSize: Style.font.panelMeta
        renderType: Text.NativeRendering
      }

      Item { width: 1; height: 10 }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        horizontalAlignment: Text.AlignHCenter
        text: "enter send · shift+enter newline\nctrl+n new · ctrl+c stop · esc close"
        color: Theme.alpha(Theme.overlay0, 0.75)
        font.family: Style.font.family
        font.pixelSize: Style.font.panelMeta
        renderType: Text.NativeRendering
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
        text: panel.stateLabel
        color: panel.accent
        elide: Text.ElideRight
        font.family: Style.font.family
        font.pixelSize: Style.font.panelMeta
        font.weight: Style.font.boldWeight
        renderType: Text.NativeRendering

        Behavior on color {
          ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
        }
      }

      // Elapsed, and what has come back for it. Both are on the right because
      // they change every frame, and a number that twitches under the first
      // word of a sentence is unreadable.
      Text {
        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
        text: fmt.duration(panel.elapsedMs)
          + (PiSession.liveTokens > 0 ? "  ↓ " + fmt.tokens(PiSession.liveTokens) : "")
        color: Theme.overlay0
        font.family: Style.font.family
        font.pixelSize: Style.font.panelMeta
        renderType: Text.NativeRendering
      }
    }

    // ----------------------------------------------------------------- error
    Rectangle {
      id: errorStrip
      anchors { left: parent.left; right: parent.right; bottom: composer.top
                leftMargin: card.border.width; rightMargin: card.border.width }
      height: PiSession.error !== "" ? errText.implicitHeight + 12 : 0
      color: Theme.alpha(Theme.red, 0.15)
      clip: true

      Behavior on height {
        NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
      }

      Text {
        id: errText
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 6 }
        text: PiSession.error
        color: Theme.red
        wrapMode: Text.Wrap
        font.family: Style.font.family
        font.pixelSize: Style.font.panelMeta
        renderType: Text.NativeRendering
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
        font.family: Style.font.family
        font.pixelSize: Style.font.panelBody
        renderType: Text.NativeRendering

        Behavior on color {
          ColorAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
        }
      }

      TextEdit {
        id: entry
        anchors { fill: parent; leftMargin: 30; rightMargin: 12; topMargin: 10; bottomMargin: 10 }

        color: Theme.text
        selectionColor: Theme.sapphire
        selectedTextColor: Theme.base
        selectByMouse: true
        wrapMode: TextEdit.Wrap
        font.family: Style.font.family
        font.pixelSize: Style.font.panelBody
        renderType: Text.NativeRendering
        clip: true

        Text {
          anchors.fill: parent
          visible: entry.text === ""
          // While a turn runs the field is refused, so it says what the key
          // that DOES do something is, rather than inviting a message that
          // would be dropped.
          text: PiSession.busy ? "ctrl+c to stop" : "Message"
          color: Theme.overlay0
          font.family: Style.font.family
          font.pixelSize: Style.font.panelBody
          renderType: Text.NativeRendering
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
      // Appended to the existing label rather than given a slot of its own,
      // because the footer is 24px with a context readout already on the right
      // and a second element would be laying claim to room another widget may
      // want. The level is blank until a child has reported one, so a panel that
      // has never run says nothing rather than guessing.
      Text {
        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter
                  verticalCenterOffset: 1 }
        text: PiSession.model + (PiSession.effortLabel !== "" ? "  ·  " + PiSession.effortLabel : "")
        color: Theme.overlay0
        elide: Text.ElideRight
        font.family: Style.font.family
        font.pixelSize: Style.font.panelMeta
        renderType: Text.NativeRendering
      }

      // Real numbers, in the order they become knowable: nothing before a
      // session exists, then the running token total once usage starts
      // streaming, then a percentage once the session has reported its window.
      // A window this shell has not been told is never guessed at.
      Text {
        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter
                  verticalCenterOffset: 1 }
        text: panel.contextLabel + " ctx · "
          + (PiSession.busy ? "live" : PiSession.warm ? "warm" : "cold")
        color: Theme.overlay0
        font.family: Style.font.family
        font.pixelSize: Style.font.panelMeta
        renderType: Text.NativeRendering
      }

      // How much of the Ollama Cloud plan is left. The third "how much is left"
      // number on this strip, and the only one the conversation cannot give
      // back: clearing the transcript empties the context gauge beside it and
      // moves this one not at all. One window rather than two, and a dash
      // rather than a zero when it does not know -- see Usage.qml for both.
      Text {
        anchors { horizontalCenter: parent.horizontalCenter
                  verticalCenter: parent.verticalCenter; verticalCenterOffset: 1 }
        text: Usage.label
        color: Usage.tint
        font.family: Style.font.family
        font.pixelSize: Style.font.panelMeta
        renderType: Text.NativeRendering

        Behavior on color {
          ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
        }
      }
    }
  }
}
