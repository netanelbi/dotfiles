import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import "root:/"

// Ori speaking: the words themselves, hung from the bar on a thread of light.
//
// -------------------------------------------------------------------- why
// This replaces a `notify-send`. That call drew a rounded card in the top
// right with a border, an app name, an icon and a close button -- the same
// chrome a Slack ping and a battery warning arrive in, three hundred pixels
// away from anything of Ori's, produced by spawning a process to talk to a
// notification server that is THIS PROCESS. It said "an application would like
// your attention". The desktop already has an assistant embedded in it -- a
// mark in the bar and a light under it -- and the moment it finishes should
// come out of that presence, not out of the generic interruption channel.
//
// So: nothing arrives from off-screen. A drop of light leaves the seam at
// exactly the x of the bar's ◆, falls a little, opens sideways into a hairline,
// and the answer's first words fade up underneath it. It is the aura's flare,
// held still long enough to be read.
//
// ------------------------------------------------------ what it says, only
// Three surfaces now speak for one event, and they do not repeat each other:
//   OriDot    the METADATA -- ◆, "answered", elapsed, characters, context.
//             That strip is already lit 30px above this text.
//   OriAura   the PRESENCE -- the whole edge floods, then holds a low wash
//             for as long as the answer is unread. No content, no edges.
//   this      the WORDS. The one fact neither of the others can carry, and
//             the only reason a person would want to be told at all.
// Which is why there is no summary line, no "Ori", no timestamp and no icon
// here: a bold title over a dim body IS the shape of the thing being replaced,
// and every field it would hold is already on screen. The thread says who is
// speaking, the tint says which state, the bar says how long it took.
//
// -------------------------------------------------------------- the rules
// Same three as OriAura, for the same reasons (CLAUDE.md):
//   FIXED SIZE -- implicitHeight is a constant and nothing ever touches it. A
//   layer surface that resizes waits on a compositor configure/ack per frame;
//   this repo measured a 180ms animation landing as five lurches. It borrows
//   the aura's exact height, because it is meant to occupy the aura's band.
//
//   INPUT ONLY WHERE THE WORDS ARE -- unlike the aura this one IS a target, so
//   it cannot take `Region {}`. The mask is the text block and nothing else, so
//   the rest of the strip under the bar stays clickable. The rect is computed
//   once per announcement, never per frame: an input region that changes with
//   an animating value is churn on every commit.
//
//   NOTHING WHEN IDLE -- Bar.qml builds this from a LazyLoader on settle and
//   drops it when `done` fires. There is no FrameAnimation in this file at all:
//   the entire gesture is one animation driving one property, `reveal`, so at
//   rest there is neither a surface nor a running animation to gate.
//
// ------------------------------------------------------------------ motion
// One scalar, `reveal`, drives everything through three overlapping windows
// (drop -> thread -> words). That is what makes the exit a genuine retraction
// rather than a fade: run the scalar back down and the words sink first, the
// thread closes to a point, and the drop is drawn back into the seam last --
// free, and impossible to get out of sync.
//
// The dwell is a PauseAnimation inside that sequence, not a Timer, for
// NotificationCard's reason: the animation IS the lifetime, so there is one
// timeline to stop and no second clock that can outlive the surface.
//
// Two exits, deliberately different lengths:
//   ignored   it withdraws over ~420ms. Nothing was wrong; it just finished
//             saying it, and the aura keeps the room lit for as long as the
//             answer is unread. This is not a notification timeout -- the
//             STATE does not expire, only the sentence does.
//   read      the panel opens and it leaves in `quick`. The full answer is now
//             in front of you and a ghost of its first line hanging over it is
//             an artefact. (The screensaver argues the same asymmetry: an
//             entrance may take its time, a thing you have answered may not.)
PanelWindow {
  id: arrival

  // Set by Bar.qml -- one per monitor, exactly like the bar mark and the aura.
  property var barScreen: null
  screen: barScreen

  // Screen x of the bar's ◆, bound live by Bar.qml. The light has to come out
  // of the mark, and the mark MOVES: the readout opens on the same signal that
  // builds this surface and slides the centre island left for 240ms after.
  // See OriDot.markX for how a non-reactive `mapToItem` is made to keep up.
  property real originX: -1

  // Emitted once the gesture has fully retracted and the surface may be freed.
  signal done()
  function finish() { arrival.done() }

  WlrLayershell.namespace: "quickshell-ori-arrival"
  // Same layer as the bar and the aura, so the words lie over a maximised
  // window rather than under it.
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  // Reserve nothing, but respect the bar's zone -- that is what parks y=0 on
  // the bar's underside without this file knowing the bar's height.
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: 0

  anchors { top: true; left: true; right: true }

  // Fixed, forever. The aura's band, to the pixel.
  implicitHeight: Style.ori.auraHeight
  color: "transparent"

  // ------------------------------------------------------------ local tokens
  // These belong in Style.ori next to auraFlareMs -- they are the third member
  // of the same family. They are local only because Style.qml is owned by
  // another change in flight; move them when it lands.
  //
  // Opening: slower than any bar transition and deliberately so. The 320ms rule
  // covers reactions to something you did; this is Ori speaking unprompted, and
  // it opens INSIDE the aura's 1100ms flare so the two read as one event.
  readonly property int openMs: 520
  // Two of Ori's breaths. Long enough to read fifteen words without hurrying,
  // and phrased as breaths on purpose: the dwell is the assistant holding a
  // sentence, so it is measured in the same unit as everything else it does.
  readonly property int dwellMs: 2 * Style.ori.breathMs
  readonly property int closeMs: 420
  // The words' column. Two lines at Style.font.small, which is about thirty
  // words -- a gist, not the answer. The answer is one click away.
  readonly property int blockWidth: 560
  // ...and the box is exactly those two lines, whether or not the answer fills
  // them. Deliberately not `implicitHeight`: a wrapped Text reports the height
  // of everything it WOULD have laid out, so a long answer would hand the mask
  // below a five-line rect to swallow clicks with.
  //
  // Off FontMetrics rather than off the pixel size, because they are not the
  // same number and the difference is not cosmetic: a Text with `elide` set
  // fits as many lines as its HEIGHT allows, so sizing this from pixelSize
  // (14 -> 36px for two lines, against a real line height of 24) silently
  // turned the gist into one elided line. Caught in a capture, not in review.
  readonly property int lineH: Math.ceil(metrics.height * 1.25)
  readonly property int wordsH: 2 * lineH + 2
  // How far the drop falls out of the seam before it opens.
  readonly property int dropPx: 18
  // The scrim's width. Wide and soft, like the aura's pool: the words need to
  // be legible over an arbitrary wallpaper, and the only way to buy that
  // without drawing a card is a shadow with no edge anywhere.
  readonly property int scrimW: 900

  FontMetrics {
    id: metrics
    font.family: Style.font.family
    font.pixelSize: Style.font.panelBody
  }

  // ------------------------------------------------------------------ state
  // The gist and the tint are latched at announce() rather than bound live, so
  // a turn that starts while these words are still on screen cannot rewrite
  // them mid-sentence.
  property string gist: ""
  property bool failed: false

  readonly property color tint: failed ? Theme.urgent : Theme.sky

  // The one animated value. Everything below is a function of it.
  property real reveal: 0
  property bool closing: false

  // Three overlapping stages cut out of the one scalar, each smoothstepped so
  // it eases at both ends without a second easing curve anywhere.
  function stage(a, b) {
    var t = Math.max(0, Math.min(1, (arrival.reveal - a) / (b - a)))
    return t * t * (3 - 2 * t)
  }
  readonly property real dropT: stage(0.00, 0.38)
  readonly property real threadT: stage(0.18, 0.72)
  readonly property real wordsT: stage(0.42, 1.00)

  readonly property real nodeY: arrival.dropPx * arrival.dropT
  // Clamped to the screen so the column never runs off an edge on a narrow
  // monitor, or when the mark sits near the right-hand island.
  readonly property real blockX: {
    var x = (arrival.originX >= 0 ? arrival.originX : arrival.width / 2) - arrival.blockWidth / 2
    return Math.max(12, Math.min(arrival.width - arrival.blockWidth - 12, x))
  }
  readonly property real markX: arrival.originX >= 0 ? arrival.originX : arrival.width / 2

  // --------------------------------------------------------------- lifetime
  function announce() {
    arrival.failed = PiSession.error !== ""
    arrival.gist = arrival.failed ? PiSession.error : arrival.lastAnswer()
    arrival.closing = false
    quickOut.stop()
    speak.restart()
  }

  // Read once, at announce. Whitespace is collapsed because an answer arrives
  // as markdown -- bullets and blank lines turn two lines of column into two
  // words of column, and this is a gist, not a rendering. The panel has the
  // real thing, formatted properly.
  function lastAnswer() {
    var i = PiSession.lastAssistant()
    if (i < 0) return "Done."
    var t = String(PiSession.turns.get(i).text).replace(/\s+/g, " ").trim()
    return t === "" ? "Done." : t
  }

  // The read exit: stop the sentence wherever it is and take it away quickly.
  function dismiss() {
    if (arrival.closing) return
    arrival.closing = true
    speak.stop()
    quickOut.start()
  }

  Component.onCompleted: arrival.announce()

  SequentialAnimation {
    id: speak
    NumberAnimation {
      target: arrival; property: "reveal"; to: 1
      duration: arrival.openMs; easing.type: Style.anim.easing
    }
    PauseAnimation { duration: arrival.dwellMs }
    NumberAnimation {
      target: arrival; property: "reveal"; to: 0
      duration: arrival.closeMs; easing.type: Style.anim.easingSmooth
    }
    // `finished` fires on natural completion only -- stop() and restart() do
    // not raise it, so neither a re-announcement nor a click can drop the
    // surface out from under a running animation. Deferred a tick regardless:
    // `done` is what makes Bar.qml's loader destroy this object, and doing that
    // inside the emitting animation's own callback frees it mid-emit.
    onFinished: Qt.callLater(arrival.finish)
  }

  NumberAnimation {
    id: quickOut
    target: arrival; property: "reveal"; to: 0
    duration: Style.anim.quick; easing.type: Style.anim.easingSmooth
    onFinished: Qt.callLater(arrival.finish)
  }

  Connections {
    target: PiSession
    // Reading is the dismissal. However the panel came up -- this click,
    // the bar's ◆, SUPER+A -- the sentence is redundant the moment the
    // transcript is on screen.
    function onPanelOpenChanged() {
      if (PiSession.panelOpen) arrival.dismiss()
    }
  }

  // ------------------------------------------------------------------- mask
  // The words are the target; everything else on this strip passes through.
  // NOT bound to anything the animation drives: `reveal` never appears here, so
  // the input region is not recommitted on every frame of the entrance. It
  // follows the mark while the bar is still reflowing under it -- a handful of
  // frames right after the answer -- and is then constant for the whole time
  // the words are on screen.
  mask: Region {
    x: Math.round(arrival.blockX - 10)
    y: Math.round(arrival.dropPx + 4)
    width: arrival.blockWidth + 20
    height: arrival.wordsH + 16
  }

  // ------------------------------------------------------------------ paint
  // ---------------------------------------------------------------- the scrim
  // A squashed radial disc of @crust under the words. Same construction as the
  // aura's travelling pool, and for the same reason: a Rectangle gradient
  // cannot fall off in both axes, and an ellipse drawn directly would get one
  // centreRadius for both. This is the aura's pool, come to rest and gone dark
  // so that something can be read inside it.
  Shape {
    id: scrim
    width: arrival.scrimW
    height: arrival.scrimW
    x: arrival.markX - width / 2
    y: arrival.dropPx + 30 - height / 2
    opacity: arrival.wordsT
    preferredRendererType: Shape.CurveRenderer

    transform: Scale {
      origin.x: scrim.width / 2
      origin.y: scrim.height / 2
      // Taller than it was (56): the words sat near the scrim's falloff, where
      // its alpha is a fraction of the number written below, so over a bright
      // window they were being read against almost nothing.
      yScale: 72 / (scrim.height / 2)
    }

    ShapePath {
      strokeWidth: -1
      fillGradient: RadialGradient {
        centerX: scrim.width / 2
        centerY: scrim.height / 2
        centerRadius: scrim.width / 2
        focalX: centerX
        focalY: centerY
        // The words sit between r=0.30 and r=0.40 of this radius, so the
        // second stop is the one that actually does the work: measured off a
        // capture, it puts ~0.6 alpha of @crust behind the text and reaches
        // zero long before the disc has an edge anyone could point at.
        // Darker than the first pass, which was tuned against a dark wallpaper
        // and disappeared over a bright window. The outer stops stay near zero,
        // so this is still a shadow with no edge anywhere rather than a card.
        GradientStop { position: 0.0; color: Theme.alpha(Theme.crust, 0.94) }
        GradientStop { position: 0.35; color: Theme.alpha(Theme.crust, 0.82) }
        GradientStop { position: 0.70; color: Theme.alpha(Theme.crust, 0.34) }
        GradientStop { position: 1.0; color: Theme.alpha(Theme.crust, 0) }
      }
      startX: 0; startY: 0
      PathLine { x: scrim.width; y: 0 }
      PathLine { x: scrim.width; y: scrim.height }
      PathLine { x: 0; y: scrim.height }
      PathLine { x: 0; y: 0 }
    }
  }

  // -------------------------------------------------------------- the light
  // Tether, thread and drop are one group so that hovering the words brightens
  // the whole structure rather than a part of it -- the acknowledgement that
  // the sentence is being held open for you.
  //
  // The hover factor lives on the GROUP and the reveal on the children on
  // purpose: a `Behavior` on a property that an animation is already driving
  // fights that animation frame by frame. Here the Behavior only ever sees the
  // hover step, and `reveal` reaches the children untouched.
  Item {
    id: light
    anchors.fill: parent
    opacity: hover.containsMouse ? 1 : 0.82
    Behavior on opacity {
      NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
    }

    // ----------------------------------------------------------- the tether
    // The hairline the drop left behind on its way out of the seam. Brightest
    // where it meets the bar, because that is where the light is coming from.
    Rectangle {
      width: 1
      x: Math.round(arrival.markX)
      y: 0
      height: arrival.nodeY
      opacity: arrival.dropT
      gradient: Gradient {
        GradientStop { position: 0.0; color: Theme.alpha(arrival.tint, 0.75) }
        GradientStop { position: 1.0; color: Theme.alpha(arrival.tint, 0.35) }
      }
    }

    // ----------------------------------------------------------- the thread
    // Opens sideways out of the drop. Only its width is animated, and it fades
    // out at both tips, so it has no ends to be seen snapping into place.
    Rectangle {
      height: 1
      width: Math.round(arrival.blockWidth * arrival.threadT)
      x: Math.round(arrival.markX - width / 2)
      y: Math.round(arrival.nodeY)
      opacity: arrival.threadT
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: Theme.alpha(arrival.tint, 0) }
        GradientStop { position: 0.5; color: arrival.tint }
        GradientStop { position: 1.0; color: Theme.alpha(arrival.tint, 0) }
      }
    }

    // ------------------------------------------------------------- the drop
    // The bright point the whole gesture comes out of, sitting where the tether
    // crosses the thread: the bar's ◆ reduced to a point.
    Rectangle {
      width: 3
      height: 3
      radius: 1.5
      x: Math.round(arrival.markX - 1.5)
      y: Math.round(arrival.nodeY - 1.5)
      color: arrival.tint
      opacity: arrival.dropT
    }
  }

  // --------------------------------------------------------------- the words
  Text {
    id: words
    x: arrival.blockX
    // Lifts the last few pixels into place rather than appearing at rest --
    // the same rise the clock label uses when a minute turns.
    y: arrival.dropPx + 12 + 6 * (1 - arrival.wordsT)
    width: arrival.blockWidth
    height: arrival.wordsH
    opacity: arrival.wordsT

    text: arrival.gist
    color: Theme.text
    wrapMode: Text.Wrap
    maximumLineCount: 2
    verticalAlignment: Text.AlignTop
    elide: Text.ElideRight
    font.family: Style.font.family
    // The panel's reading size, not the bar's. This is a sentence, at whatever
    // distance you happen to be from the screen when it lands -- the bar's 14px
    // is for a strip you are already looking at.
    font.pixelSize: Style.font.panelBody
    lineHeight: 1.25
    renderType: Text.NativeRendering
  }

  // The only interactive thing on the surface, and it is exactly the masked
  // rect. Hovering holds the sentence open -- reaching for something that then
  // withdraws under the cursor is the one failure mode a self-timed message has.
  MouseArea {
    id: hover
    x: arrival.blockX - 10
    y: arrival.dropPx + 4
    width: arrival.blockWidth + 20
    height: arrival.wordsH + 16
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onContainsMouseChanged: {
      if (!speak.running) return
      if (containsMouse) speak.pause()
      else if (speak.paused) speak.resume()
    }

    onClicked: PiSession.panelOpen = true
  }
}
