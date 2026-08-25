import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import "root:/"

// Ori's light: a wash that bleeds out from under the bar while it is working.
//
// -------------------------------------------------------------------- why
// The bar readout answers "what is it doing" but it is 22px tall in the middle
// of eight other indicators, and you have to be looking at it. The thing that
// makes the assistant feel EMBEDDED in the machine rather than bolted to the
// panel is peripheral: light on the desktop that changes when Ori's state
// changes, that you catch without turning your head. This is that light.
//
// It is deliberately not a widget and not a notification. It has no edges you
// can point at, no text, and nothing to click -- it is the room being lit.
//
// --------------------------------------------------------------- the rules
// Three things constrain this surface absolutely, and all three are in
// CLAUDE.md:
//
//   FIXED SIZE. A layer surface that resizes waits on a compositor
//   configure/ack round trip PER FRAME -- this repo measured a 180ms animation
//   taking 467ms and landing as five lurches. `implicitHeight` is a constant
//   and nothing ever touches it; everything that moves, moves INSIDE.
//
//   NO INPUT. `mask: Region {}` gives the surface an empty input region, so
//   every click, hover and scroll passes straight through to whatever is
//   underneath. Without it a band across the top of the screen would eat the
//   bar's clicks and the top edge of every window.
//
//   NOTHING WHEN IDLE. This surface does not EXIST when Ori is idle: Bar.qml
//   builds it from a LazyLoader and drops it again afterwards. (It has to be
//   built already-visible. A PanelWindow created with `visible: false` and
//   shown later maps at 0x0 -- measured here: `visible` goes true while width
//   and height are still 0, and the compositor never configures a real size,
//   so the surface renders nothing at all.) The one FrameAnimation that drives
//   every effect gates on `running:` -- not on `visible: false`, which stops
//   painting but not animating.
//
// ------------------------------------------------------------------ motion
//   thinking   a pool of light travels the width of the screen and back on a
//              cosine, so it eases at the turns and never jumps at a seam,
//              while the seam itself breathes on the bar readout's period.
//              Two incommensurate cycles: it never repeats visibly.
//   answered   the travel stops dead and the whole edge floods once, then
//              decays to a low steady wash that stays until the answer is
//              read. An unread answer leaves the room lit.
//   failed     the same, in red.
PanelWindow {
  id: aura

  // Set by Bar.qml, so there is one of these per monitor exactly like the bar.
  property var barScreen: null
  screen: barScreen

  WlrLayershell.namespace: "quickshell-ori-aura"
  // Same layer as the bar, so the light lies over windows rather than being
  // buried by a maximised one. Peripheral only works if it is always there.
  WlrLayershell.layer: WlrLayer.Top

  // Reserve NOTHING of its own, but respect what the bar reserved -- that is
  // what parks the surface exactly on the bar's underside without this file
  // having to know the bar's height, and keeps it there if the bar's height
  // ever changes.
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: 0

  anchors {
    top: true
    left: true
    right: true
  }

  // Fixed, forever. See the rules above.
  implicitHeight: Style.ori.auraHeight
  color: "transparent"

  // Empty input region: the surface is light, not a target.
  mask: Region {}

  // ------------------------------------------------------------------ state
  readonly property bool thinking: PiSession.busy
  readonly property bool failed: PiSession.error !== "" && !thinking
  readonly property bool waiting: (PiSession.unread || failed) && !thinking
  // Driven once by flareAnim when an answer lands; also what keeps the surface
  // mapped through the tail of the flare after `unread` is cleared by a click.
  property real flare: 0

  // Read back by Bar.qml's LazyLoader so the surface survives the tail of a
  // flare even after the answer has been read. PUSHED to the loader rather
  // than read by it: a loader whose `active` binding reads a property of the
  // object it decides the existence of is a binding loop (see Assistant.qml,
  // which solves the same problem the same way).
  readonly property bool fading: flare > 0.001

  // The same three colours the bar readout uses, so the glyph and the light
  // are never two different opinions about what Ori is doing -- INCLUDING the
  // precedence, which matters when a new question is asked while an older
  // answer is still unread: what it is doing now wins over what it is holding.
  readonly property color tint: thinking ? Theme.sapphire
    : failed ? Theme.urgent
    : PiSession.unread ? Theme.sky
    : Theme.sapphire

  // ------------------------------------------------------------- the clock
  // One FrameAnimation for the whole surface, vsync-locked, and stopped dead
  // the moment the work does. Same idiom as the screensaver. Only the travel
  // and the breath need it -- the flare is a plain animation and the waiting
  // wash does not move at all, so a surface that is merely lit costs nothing.
  FrameAnimation {
    id: clock
    running: aura.thinking
  }

  // Travel: a full round trip on a cosine, so the pool decelerates into each
  // edge and accelerates out of it instead of wrapping.
  readonly property real travel: {
    if (!aura.thinking) return 0.5
    var p = (clock.elapsedTime * 1000) % Style.ori.auraSweepMs / Style.ori.auraSweepMs
    return 0.5 - 0.5 * Math.cos(2 * Math.PI * p)
  }

  // Breath: the seam brightening and dimming on the readout's period.
  readonly property real breath: {
    if (!aura.thinking) return 1
    var p = (clock.elapsedTime * 1000) % Style.ori.breathMs / Style.ori.breathMs
    return 0.62 + 0.38 * (0.5 + 0.5 * Math.cos(2 * Math.PI * p))
  }

  // ------------------------------------------------------------------ paint
  Item {
    id: field
    anchors.fill: parent
    // The travelling pool is a disc centred ABOVE the top edge, so only its
    // lower half is ever drawn -- which is how light actually escapes a seam.
    // Clipping is what makes that half-disc, and it is free.
    clip: true

    // How much light is in the room at all. The flare rides on top of this
    // rather than replacing it, so the transition from working to answered is
    // one continuous brightening.
    opacity: aura.thinking ? aura.breath
      : aura.waiting ? Style.ori.auraRest
      : aura.flare
    Behavior on opacity {
      NumberAnimation { duration: Style.anim.slow; easing.type: Style.anim.easingSmooth }
    }

    // ------------------------------------------------------------ the seam
    // A wash pinned to the top edge and gone by a third of the way down. The
    // falloff is what sells it as light COMING OUT of the bar rather than a
    // coloured band sitting on the wallpaper: most of the alpha is spent in
    // the first few pixels and the rest is a long, weak tail.
    Rectangle {
      anchors.fill: parent
      // Turned down while the pool is travelling over it, so the pool is the
      // bright thing and the seam is only the floor it rides on.
      opacity: aura.thinking ? Style.ori.auraSeamWhileTravelling : 1
      Behavior on opacity {
        NumberAnimation { duration: Style.anim.slow; easing.type: Style.anim.easingSmooth }
      }
      gradient: Gradient {
        GradientStop { position: 0.0; color: Theme.alpha(aura.tint, Style.ori.auraCore) }
        GradientStop { position: 0.10; color: Theme.alpha(aura.tint, Style.ori.auraCore * 0.45) }
        GradientStop { position: 0.35; color: Theme.alpha(aura.tint, Style.ori.auraCore * 0.14) }
        GradientStop { position: 1.0; color: Theme.alpha(aura.tint, 0) }
      }
    }

    // ---------------------------------------------------- the travelling pool
    // A radial falloff, which a Rectangle gradient cannot do in either axis at
    // once -- hence the Shape. Only its `x` is ever animated: a translated
    // texture, the cheapest motion available, and no gradient is rebuilt.
    //
    // The Shape is a SQUARE holding a true circle, then squashed by the
    // transform below into a flat ellipse. Drawing the ellipse directly would
    // mean a RadialGradient whose single `centerRadius` is the circle's -- so
    // the light would fall off over 360px vertically inside a 132px surface,
    // which is no falloff at all. That was the first version, and it read as a
    // flat blue sheet for exactly this reason.
    Shape {
      id: pool
      width: Style.ori.auraBlobW
      height: Style.ori.auraBlobW
      // Centred ON the seam, so only the lower half of the pool is ever drawn.
      y: -height / 2
      // The pool's CENTRE travels edge to edge, so at the ends of the sweep it
      // is half off-screen rather than entirely gone. Travelling the full
      // width plus the pool's own width instead would park it completely off
      // screen at both extremes -- and because the cosine decelerates INTO the
      // ends, that is exactly where it lingers. Measured: whole seconds of a
      // 7.8s cycle with no pool visible at all, and a thinking state that read
      // as a flat band. Half a pool in the corner reads as light pooling
      // against the edge, which is what it should do.
      x: field.width * aura.travel - width / 2

      transform: Scale {
        origin.x: pool.width / 2
        origin.y: pool.height / 2
        yScale: (Style.ori.auraHeight * Style.ori.auraBlobFall) / (pool.height / 2)
      }
      // Motion means work. Nothing travels once the answer has landed.
      opacity: aura.thinking ? 1 : 0
      preferredRendererType: Shape.CurveRenderer
      Behavior on opacity {
        NumberAnimation { duration: Style.anim.slow; easing.type: Style.anim.easingSmooth }
      }

      ShapePath {
        strokeWidth: -1
        fillGradient: RadialGradient {
          centerX: pool.width / 2
          centerY: pool.height / 2
          centerRadius: pool.width / 2
          focalX: centerX
          focalY: centerY
          GradientStop { position: 0.0; color: Theme.alpha(aura.tint, Style.ori.auraPoolPeak) }
          GradientStop { position: 0.25; color: Theme.alpha(aura.tint, Style.ori.auraPoolPeak * 0.40) }
          GradientStop { position: 0.62; color: Theme.alpha(aura.tint, Style.ori.auraPoolPeak * 0.09) }
          GradientStop { position: 1.0; color: Theme.alpha(aura.tint, 0) }
        }
        startX: 0
        startY: 0
        PathLine { x: pool.width; y: 0 }
        PathLine { x: pool.width; y: pool.height }
        PathLine { x: 0; y: pool.height }
        PathLine { x: 0; y: 0 }
      }
    }

    // ----------------------------------------------------------- the flare
    // One event, announced at two sizes: the bar glyph throws a 26px ring at
    // the same instant this floods the whole edge. Additive on top of the
    // seam, so the peak is genuinely brighter than anything the working state
    // ever reaches -- an answer landing should be the brightest thing Ori does.
    Rectangle {
      anchors.fill: parent
      opacity: aura.flare
      gradient: Gradient {
        GradientStop { position: 0.0; color: Theme.alpha(aura.tint, Style.ori.auraCore) }
        GradientStop { position: 0.25; color: Theme.alpha(aura.tint, Style.ori.auraCore * 0.35) }
        GradientStop { position: 1.0; color: Theme.alpha(aura.tint, 0) }
      }
    }
  }

  SequentialAnimation {
    id: flareAnim
    // Up fast, down slow: the shape of every light that is switched on and
    // then left to decay, and the opposite of a blink.
    NumberAnimation {
      target: aura; property: "flare"; to: 1
      duration: Style.anim.quick; easing.type: Style.anim.easingSmooth
    }
    NumberAnimation {
      target: aura; property: "flare"; to: 0
      duration: Style.ori.auraFlareMs; easing.type: Style.anim.easing
    }
  }

  Connections {
    target: PiSession
    // Only when the panel is CLOSED -- with it open the answer is already in
    // front of you, and lighting the room as well is noise.
    function onSettled() {
      if (PiSession.panelOpen) return
      flareAnim.restart()
    }
  }
}
