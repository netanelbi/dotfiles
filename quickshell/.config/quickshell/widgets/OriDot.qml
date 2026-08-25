import QtQml
import QtQuick
import Quickshell
import "root:/"

// Ori's presence in the bar: a readout, not an icon.
//
// The panel was built so that closing it does not cancel -- the process keeps
// working with no window attached and the answer is simply there next time.
// That is only a feature if something tells you it happened. Without this
// widget it is a black hole: you ask, you close, and you never learn it
// finished.
//
// ------------------------------------------------------------- what it says
// A glyph alone can only say "something". The thing this has to compete with
// is Claude Code's status line, which fits VERB + ELAPSED + THROUGHPUT into one
// strip ("Swirling… (29s · ↓ 625 tokens)") and then leaves the receipt behind
// ("Crunched for 9m 38s"). That density is the bar, so this carries the same
// four facts and nothing else:
//
//   glyph     ALIVE, and which way. Hollow ◇ while it is empty-handed,
//             filled ◆ the moment it is holding an answer you have not read.
//             A shape change is legible at a glance in a way a brightness
//             change is not -- which is the whole reason the old version,
//             which only got brighter, did not read.
//   verb      WHAT. The tool in flight (bash / read / grep), or "thinking"
//             between calls. The arguments go in the tooltip; the bar gets
//             the one word.
//   elapsed   HOW LONG, in Claude Code's own format ("12s", "9m 38s"). Taken
//             from PiSession's wall-clock stamp on the turn, NOT from the
//             animation clock: a still frame four minutes into a turn has to
//             read "4m 2s", and a looping animation cannot say that. Frozen at
//             the final figure afterwards, so the finished state still tells
//             you what it cost.
//   ↓ count   THAT IT IS MOVING. Characters streamed on this turn. Characters
//             and not tokens on purpose, even though the token count is right
//             there: this provider reports `usage` as zeroes until the turn's
//             last frame, so a token counter sits at 0 and then jumps -- which
//             is exactly the wrong shape for the one number whose whole job is
//             to distinguish "working" from "hung". The tokens are in the
//             tooltip, where a figure that arrives at the end belongs.
//   ctx %     WHAT THE SESSION WEIGHS, straight off pi's own contextUsage --
//             the same fact Claude Code puts at the end of its strip. Live,
//             because `usage.totalTokens` streams and only the window size has
//             to be asked for. Hidden until the window size is known, which is
//             one round trip after the first answer.
//
// Under all four, a scan line runs left to right: the spinner, drawn as a
// channel of light rather than a rotating character.
//
// -------------------------------------------------------------- the states
//   gone     nothing running, nothing unread. The bar is not a place to
//            advertise an idle process, and idle is most of the day.
//   dim ◇    warm -- a question now costs 1.2s instead of 2.3s. Worth
//            knowing, not worth looking at, so the readout stays collapsed
//            and only the glyph shows.
//   ◇ + strip  thinking. The glyph breathes, the readout counts up.
//   ◆ + strip  an answer is waiting and the panel is closed. The only BRIGHT
//            state, because it is the only one that wants you.
//   ◆ red    it failed. Same shape -- there is still something to read.
//
// Click toggles the panel; clicking while an answer waits is what clears the
// unread state, so the bright glyph cannot be dismissed without being read.
//
// ------------------------------------------------------------------ motion
// ONE clock. A single FrameAnimation drives the breath, the scan and the
// elapsed counter, so all three are phase-locked and there is exactly one
// timeline to stop -- and it is stopped, not hidden, the instant Ori settles.
// (Same idiom as the screensaver, which derives every effect it draws from one
// FrameAnimation.) A FrameAnimation is a display clock: it never reads state
// back to see whether it changed, which is the thing this repo forbids.
BarWidget {
  id: root

  // .active { margin: 0 4px } -- the same 8px footprint every compact
  // indicator here uses.
  horizontalPadding: Style.module.indicatorPaddingH
  spacing: Style.ori.cellGap

  // ------------------------------------------------------------------ state
  // `unread` lives on PiSession so opening the panel from anywhere clears it.
  readonly property bool unread: PiSession.unread
  readonly property bool thinking: PiSession.busy
  readonly property bool failed: PiSession.error !== "" && !thinking
  // Asking again while an older answer is still unread leaves BOTH true. What
  // it is doing now outranks what it has been holding since earlier -- without
  // this the glyph sits filled and bright through a whole new turn, saying
  // "come and read me" about an answer that is already being replaced.
  readonly property bool holding: (unread || failed) && !thinking
  // The readout is only worth its width while there is something to read on
  // it. Warm-and-idle gets the glyph alone.
  readonly property bool expanded: thinking || holding

  // `failed` is listed separately because a crash takes `warm` down with it
  // and never fires settled(), so neither of the other two terms covers the
  // one state that most needs saying.
  shown: thinking || unread || failed || PiSession.warm

  // Ori's colour, and the aura under the bar picks the same one.
  readonly property color tint: thinking ? Theme.sapphire
    : failed ? Theme.urgent
    : unread ? Theme.sky
    : Theme.inactive

  onClicked: PiSession.panelOpen = !PiSession.panelOpen

  // ------------------------------------------------------------- the clock
  // Runs while Ori works and not one frame longer. It is only the TICK: the
  // elapsed figure itself is the difference between now and PiSession's
  // wall-clock stamp, so it is right even if this widget was built halfway
  // through a turn, and it is the same figure on every monitor.
  property int liveSec: 0
  property int streamed: 0

  readonly property int elapsedSec: root.thinking ? root.liveSec : PiSession.turnSeconds

  FrameAnimation {
    id: heart
    running: root.thinking
    onTriggered: {
      var s = Math.max(0, Math.floor((Date.now() - PiSession.askedAt) / 1000))
      // Assigning the same value would be free, but the guard makes it obvious
      // that this is a display clock ticking, not a poll looking for change.
      if (s !== root.liveSec) root.liveSec = s
    }
  }

  onThinkingChanged: if (thinking) {
    root.liveSec = 0
    root.streamed = 0
  }

  // Breath and scan are derived from the one clock. Both collapse to a
  // constant the moment it stops, so nothing is ever stranded mid-animation
  // the way the old opacity pulse could be.
  readonly property real breath: {
    if (!root.thinking) return 1
    var p = (heart.elapsedTime * 1000) % Style.ori.breathMs / Style.ori.breathMs
    return Style.ori.dotFloor + (1 - Style.ori.dotFloor) * (0.5 + 0.5 * Math.cos(2 * Math.PI * p))
  }
  readonly property real scanPhase: {
    if (!root.thinking) return 0
    return (heart.elapsedTime * 1000) % Style.ori.scanMs / Style.ori.scanMs
  }

  // ---------------------------------------------------------- what it is doing
  // `ingest()` writes the tool onto the open turn with ListModel.setProperty,
  // which notifies that model's DELEGATES and nothing else -- a plain
  // `PiSession.turns.get(i).tool` binding is evaluated once and never again,
  // which is why the tool never showed anywhere but the panel. So the readout
  // watches the model the way a view does: one throwaway QObject per turn,
  // each bound to its own row's roles. It lives here rather than on PiSession
  // because it is a VIEW of the engine, not part of it.
  property string liveTool: ""

  Instantiator {
    model: PiSession.turns
    delegate: QtObject {
      required property string tool
      required property bool pending
      // Only the open turn's tool counts; settling clears it by clearing
      // `pending`, without needing a second signal.
      readonly property string live: pending ? tool : ""
      onLiveChanged: root.liveTool = live
    }
  }

  // Characters streamed on this turn -- text plus reasoning, since both are
  // evidence of movement. `appended()` already fires on every delta, so this
  // costs one string length per token and no timer at all.
  Connections {
    target: PiSession
    function onAppended() {
      var i = PiSession.lastAssistant()
      if (i < 0) return
      var t = PiSession.turns.get(i)
      if (!t) return
      root.streamed = String(t.text).length + String(t.thinking).length
    }
  }

  // The one word. `tool` arrives as "bash ls -la /etc" -- the name is the verb,
  // the rest is tooltip material.
  readonly property string verb:
      root.thinking ? (root.liveTool === "" ? "thinking" : String(root.liveTool).split(" ")[0])
    : root.failed ? "failed"
    : root.unread ? "answered"
    : ""

  // Claude Code's own format, so the two strips are comparable at a glance.
  function humanTime(s) {
    if (s < 60) return s + "s"
    return Math.floor(s / 60) + "m " + (s % 60) + "s"
  }

  function humanCount(n) {
    if (n <= 0) return ""
    return n < 1000 ? "↓ " + n : "↓ " + (n / 1000).toFixed(1) + "k"
  }

  // The window is 1M tokens on this model, so a fresh session rounds to 0% and
  // one decimal is what makes it a number that MOVES rather than a constant.
  readonly property bool hasContext: PiSession.contextWindow > 0
  readonly property string contextLabel:
      !hasContext ? "" : PiSession.contextPercent.toFixed(1) + "%"

  // What the bar cannot fit: the tool's arguments, the token counts (which
  // land at the end of a turn, so they belong somewhere you go and look rather
  // than somewhere you glance), and the window they are a fraction of.
  readonly property string usageLine: !hasContext ? ""
      : "\n" + PiSession.tokensTotal + " / " + PiSession.contextWindow
        + " tokens · " + PiSession.contextPercent.toFixed(1) + "% of context"

  tooltip: root.failed ? "Ori failed\n" + PiSession.error
    : root.thinking
      ? "Ori · " + (root.liveTool === "" ? "thinking" : root.liveTool)
        + "\n" + root.humanTime(root.elapsedSec) + " · " + root.streamed
        + " characters streamed" + root.usageLine
    : root.unread ? "Ori answered in " + root.humanTime(root.elapsedSec)
        + " — click to read" + root.usageLine
    : "Ori is warm · click to open" + root.usageLine

  // ------------------------------------------------------------------ glyph
  Item {
    id: glyphSlot
    implicitWidth: glyph.implicitWidth
    implicitHeight: Style.bar.slotHeight

    Text {
      id: glyph
      anchors.centerIn: parent
      // soul.md signs Ori's own work with this diamond, so the bar and the
      // transcript are marked with the same glyph. Filled once it is holding
      // something for you.
      text: root.holding ? "◆" : "◇"
      color: root.tint
      opacity: root.breath
      font.family: Style.font.family
      font.pixelSize: Style.font.size
      renderType: Text.NativeRendering

      Behavior on color {
        ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
      }
    }

    // A single ring when an answer lands, expanding out of the glyph and
    // fading -- the bar-sized echo of the flare the aura throws across the
    // whole edge at the same instant. It fires once per answer and costs
    // nothing the rest of the time: the Rectangle has no size and no colour
    // until the animation drives it.
    Rectangle {
      id: ring
      anchors.centerIn: parent
      width: 0
      height: width
      radius: width / 2
      color: "transparent"
      border.width: 1
      border.color: Theme.sky
      opacity: 0
    }

    ParallelAnimation {
      id: ping
      NumberAnimation { target: ring; property: "width"; from: 4; to: 26; duration: Style.anim.slow; easing.type: Style.anim.easing }
      SequentialAnimation {
        NumberAnimation { target: ring; property: "opacity"; from: 0; to: 0.8; duration: Style.anim.quick }
        NumberAnimation { target: ring; property: "opacity"; to: 0; duration: Style.anim.reveal; easing.type: Style.anim.easingSmooth }
      }
    }
  }

  // ---------------------------------------------------------------- readout
  // Opens to ONE width and holds it for the whole turn (see Style.ori's cell
  // comments): the bar must not shuffle every time a tool call starts.
  Item {
    id: readout
    implicitWidth: !root.expanded ? 0
      : root.hasContext ? Style.ori.readoutWidthCtx : Style.ori.readoutWidth
    implicitHeight: Style.bar.slotHeight
    clip: true
    opacity: root.expanded ? 1 : 0

    Behavior on implicitWidth {
      NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
    }
    Behavior on opacity {
      NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
    }

    Row {
      anchors.left: parent.left
      // Sits a touch high so the scan line below it has its own air.
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: -1
      spacing: Style.ori.cellGap

      Text {
        width: Style.ori.toolWidth
        text: root.verb
        elide: Text.ElideRight
        color: Theme.subtext0
        font.family: Style.font.family
        font.pixelSize: Style.font.tiny
        renderType: Text.NativeRendering
      }

      Text {
        width: Style.ori.timeWidth
        horizontalAlignment: Text.AlignRight
        text: root.humanTime(root.elapsedSec)
        color: root.tint
        font.family: Style.font.family
        font.pixelSize: Style.font.tiny
        renderType: Text.NativeRendering

        Behavior on color {
          ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
        }
      }

      Text {
        width: Style.ori.countWidth
        horizontalAlignment: Text.AlignRight
        text: root.humanCount(root.streamed)
        color: Theme.inactive
        font.family: Style.font.family
        font.pixelSize: Style.font.tiny
        renderType: Text.NativeRendering
      }

      // The context cell has no width at all until pi has told us how big the
      // window is -- an empty slot reserved for a number that may never come
      // is worse than the strip being 40px narrower.
      Text {
        width: root.hasContext ? Style.ori.ctxWidth : 0
        horizontalAlignment: Text.AlignRight
        text: root.contextLabel
        color: Theme.inactive
        font.family: Style.font.family
        font.pixelSize: Style.font.tiny
        renderType: Text.NativeRendering
      }
    }

    // ------------------------------------------------------------- the scan
    // The spinner, as a channel of light under the numbers. The track only
    // exists while the segment is running, so a settled readout is a clean
    // line of text with nothing moving on it.
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: Theme.alpha(root.tint, 0.18)
      opacity: root.thinking ? 1 : 0
      Behavior on opacity {
        NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
      }
    }

    Rectangle {
      id: scanSeg
      width: Math.round(readout.width * 0.4)
      height: 1
      y: readout.height - 1
      // Position is the only thing animated -- a translated texture, which is
      // the cheapest motion there is.
      x: -width + (readout.width + width) * root.scanPhase
      visible: root.thinking
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: Theme.alpha(root.tint, 0) }
        GradientStop { position: 0.5; color: root.tint }
        GradientStop { position: 1.0; color: Theme.alpha(root.tint, 0) }
      }
    }
  }

  // -------------------------------------------------------------- announce
  Connections {
    target: PiSession
    // Only when the panel is CLOSED. With the panel open the answer is already
    // arriving in front of you and a second announcement is noise.
    function onSettled() {
      if (PiSession.panelOpen) return
      PiSession.unread = true
      ping.restart()
    }
  }

  // WHERE THE MARK IS, in this bar window's coordinates. Bar.qml hands it to
  // OriArrival so the thread of light the words hang from comes out of THIS
  // glyph rather than out of the middle of the screen.
  //
  // It has to keep up, and the reason is this widget itself: the instant an
  // answer lands the readout opens from nothing to ~200px, the centre island
  // grows around it, and -- because the island is centre-anchored -- every
  // module in it slides left for the next 240ms. Measured once at the settle,
  // the thread lands 25px to the right of the glyph it is supposed to be coming
  // out of. Measured LIVE, it stays welded to the mark through the reflow,
  // which is the whole claim this surface makes.
  //
  // `mapToItem` is not a reactive expression, so the two things that can move
  // this glyph are read explicitly to make them dependencies: our own width
  // (the readout opening) and our x in the row (any module to our left
  // appearing). One layout pass stale at worst -- invisible at 60fps.
  readonly property real markX: {
    // Read for the dependency, not for the value -- the fallback branch is
    // unreachable while this widget is in a scene, and returning something
    // roughly right beats returning zero if it ever is not.
    var reflow = root.x + root.width
    var p = glyphSlot.mapToItem(null, glyphSlot.width / 2, 0)
    return p ? p.x : reflow
  }

  // ------------------------------------------------ why there is no notify-send
  // This used to spawn `notify-send` on every settle. That drew a rounded card
  // in the top right -- app name, icon, close button -- identical to a Slack
  // ping, produced by starting a process to talk to a notification server that
  // is this very process. OriArrival says it now, in the shell's own vocabulary
  // and out of this glyph.
  //
  // The one thing that goes with it is the row it left in the notification
  // centre, and the centre is genuinely where a person looks for a message they
  // did not catch. That is answered here twice:
  //
  //   NOTHING ORI SAYS EXPIRES. The centre exists because a card is gone in ten
  //   seconds whether or not anyone saw it. Ori's unread state has no timeout:
  //   this glyph stays filled and bright and the aura keeps the edge lit until
  //   the panel is actually opened. A missed arrival is still on screen.
  //
  //   THE TRANSCRIPT IS THE BETTER ARCHIVE. The centre row carried 220
  //   truncated characters with the rest unrecoverable. The panel holds every
  //   turn in full, with its tools and its cost, and SUPER+A is the same
  //   gesture as opening the centre. A lossy duplicate filed among other
  //   applications' interruptions is exactly what this change is undoing.
  //
  // (CalendarReminders still posts through notify-send, correctly: a reminder
  // has no second home to be recovered from.)

  onShownChanged: if (shown) appear.restart()

  NumberAnimation {
    id: appear
    target: glyph
    property: "scale"
    from: 0.4
    to: 1
    duration: Style.anim.reveal
    easing.type: Style.anim.easingEnter
    easing.overshoot: Style.anim.overshoot
  }
}
