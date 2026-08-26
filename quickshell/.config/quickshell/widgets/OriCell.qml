import QtQml
import QtQuick
import QtQuick.Shapes
import "root:/"

// Ori's presence in the bar: one cell, in the gap, on nothing.
//
// ------------------------------------------------------------- the rule
// Twelve earlier designs were rejected for the same fault, and the user named
// it once, plainly:
//
//   "they all share the same issue. its on the main windows and it will
//    bother me on other windows."
//
// Ambient light on a working screen is a COST, not a feature. So everything
// this widget draws is inside the bar's own 30px strip, which the compositor
// has already reserved. Nothing bleeds onto a window. Ever. The one surface
// that covers a window is OriVeil, and it exists only while the pointer is
// resting on this cell, because that is what was asked for.
//
// --------------------------------------------------------------- unhoused
// It is not in an island. Bar.qml gives it a fixed-width zone in the gap
// between the centre and right pills and it floats there on the bar's own
// background. Nothing else in this bar is unhoused, and that is the whole
// point: an island pill would make it the ninth status chip in a row of eight,
// read at a glance as a sibling of the battery. Alone in the gap it reads as
// the assistant.
//
// ---------------------------------------------------------------- the keel
// The chosen mark is a GLYPH and a RULE, and no box anywhere -- including at
// the arrival, where every rejected variant flashed a rounded border. A rule
// that spent the whole design refusing to draw a box does not get to draw one
// for 620ms.
//
// MEASURE: the rule runs under the glyph AND the words, and lengthens as the
// cell opens, so it is exactly as long as there is something to read. The two
// alternatives were tested and lost -- MARK (under the glyph alone) leaves the
// words floating unsupported over a window, and BERTH (the whole reserved zone,
// always) is a permanent hairline indistinguishable at real size from MARK's
// stub, so it does not earn its permanence.
//
// It sits 3px under the glyph's foot rather than on any edge of the bar:
// unhoused there is no island floor to align to, so the only honest datum is
// the mark itself.
//
// -------------------------------------------------------------- the states
//   cold     present and DIM. Never invisible -- the previous version hid
//            itself whenever Ori was idle, which is most of the day, and a
//            black hole you cannot point at is the original defect this whole
//            widget exists to fix. The glyph is hollow, the rule is a stub.
//   working  the glyph breathes in sapphire, the readout counts up, and the
//            scan travels the rule at a rate the WORK sets (see the flow gauge
//            in Style.ori). A stalled turn drifts; a streaming one races.
//   unread   filled ◆ in sky, the rule thickens. The only bright state,
//            because it is the only one that wants you.
//   failed   the same shape in red. There is still something to read.
//
// Compact vs expanded is right-click, held on PiSession so both monitors agree.
// Compact is the glyph and its stub, and nothing else; expanded grows only when
// Ori is working or when an answer waits.
//
// ------------------------------------------------------- why not a BarWidget
// Every other module here extends BarWidget, and this one deliberately does
// not. BarWidget centres its content Row in a box whose width animates -- which
// is right for a chip inside an island, and wrong here: the glyph would DRIFT
// sideways for 240ms every time the readout opened, and this glyph is the
// origin the veil's tether hangs from. It also draws a background pill and
// raises a tooltip, both of which this design exists to refuse. What is left of
// BarWidget after removing those three is a MouseArea, which is written below.
Item {
  id: root

  // ------------------------------------------------------------------ state
  readonly property bool thinking: PiSession.busy
  readonly property bool failed: PiSession.error !== "" && !thinking
  readonly property bool unread: PiSession.unread
  // Asking again while an older answer is still unread leaves BOTH true. What
  // it is doing NOW outranks what it has been holding since earlier -- without
  // this the glyph sits filled and bright through a whole new turn, saying
  // "come and read me" about an answer that is already being replaced.
  readonly property bool holding: (unread || failed) && !thinking
  // Set by Bar.qml when the gap between the islands cannot hold the open cell.
  // Treated exactly like the user's own right-click: the cell simply does not
  // open. See the comment at the OriCell instantiation for the measurement.
  property bool cramped: false
  readonly property bool expanded: !cramped && !PiSession.cellCompact && (thinking || holding)

  readonly property color tint: thinking ? Theme.sapphire
    : failed ? Theme.urgent
    : unread ? Theme.sky
    : Theme.subtext0

  // Cold is dim, not absent. subtext0 at 0.42/0.70 rather than `Theme.inactive`
  // (overlay0): unhoused, this sits on the wallpaper instead of on an island's
  // @base fill, and overlay0 on a mid-grey photograph is gone.
  readonly property real markAlpha: root.holding ? 1
    : root.thinking ? 1 : 0.70
  readonly property real ruleAlpha: root.holding ? 1
    : root.thinking ? 0.22 : 0.42

  implicitWidth: Style.ori.zoneWidth
  implicitHeight: Style.bar.islandHeight

  // ------------------------------------------------------------- the clock
  // ONE FrameAnimation for the whole cell -- breath, scan and the elapsed
  // counter -- so all three are phase-locked and there is exactly one timeline
  // to stop. It is STOPPED, not hidden, the instant Ori settles and the arrival
  // has decayed. A FrameAnimation is a display clock: it never reads state back
  // to see whether it changed, which is the thing this repo forbids.
  property int liveSec: 0
  // How fast the scan is currently travelling, 1 = full, floored at the drift.
  property real flow: 1
  // The scan's position, INTEGRATED per frame rather than computed from elapsed
  // time -- which is what lets the rate change without the scan jumping.
  property real scanPhase: 0

  readonly property int elapsedSec: root.thinking
    ? root.liveSec : Math.round(PiSession.turnSeconds)

  FrameAnimation {
    id: heart
    running: root.thinking || root.flash > 0.001
    onTriggered: {
      if (root.thinking) {
        var s = Math.max(0, Math.floor((Date.now() - PiSession.askedAt) / 1000))
        // Assigning the same value would be free, but the guard makes it
        // obvious that this is a display clock ticking, not a poll looking for
        // change.
        if (s !== root.liveSec) root.liveSec = s

        // The flow gauge, harvested wholesale from the deleted OriAura. It
        // reads ONE wall-clock stamp per frame, on a frame it was already
        // drawing, and turns the silence since the last delta into a rate.
        var gap = Date.now() - PiSession.lastAppendAt
        var f = 1
        if (gap > Style.ori.flowGraceMs) {
          f = Math.exp(-(gap - Style.ori.flowGraceMs) / Style.ori.flowDecayMs)
          if (f < Style.ori.driftRate) f = Style.ori.driftRate
        }
        root.flow = f
        // Clamped: the first frame after a reload, and any frame dropped behind
        // a compositor hitch, would otherwise teleport the scan.
        var dt = Math.min(frameTime, 0.1)
        root.scanPhase = (root.scanPhase + f * dt * 1000 / Style.ori.scanMs) % 1
      }
    }
  }

  onThinkingChanged: if (thinking) {
    root.liveSec = 0
    root.scanPhase = 0
    root.flow = 1
  }

  // The breath. Derived from the same clock and collapsing to a constant the
  // moment it stops, so nothing is ever stranded mid-animation.
  readonly property real breath: {
    if (!root.thinking) return 1
    var p = (heart.elapsedTime * 1000) % Style.ori.breathMs / Style.ori.breathMs
    return Style.ori.dotFloor + (1 - Style.ori.dotFloor) * (0.5 + 0.5 * Math.cos(2 * Math.PI * p))
  }

  // ------------------------------------------------------------- the arrival
  // Not a box, not a ring, not a flood across the screen: the rule THICKENS,
  // goes near-white and OVERSHOOTS its own length -- it draws past the last
  // word and comes back. Length is the one dimension a line has, so length is
  // what it announces with.
  //
  // Up fast, down slow: the shape of every light that is switched on and left
  // to decay, and the opposite of a blink.
  property real flash: 0

  SequentialAnimation {
    id: arrive
    NumberAnimation {
      target: root; property: "flash"; to: 1
      duration: Style.anim.quick; easing.type: Style.anim.easingSmooth
    }
    NumberAnimation {
      target: root; property: "flash"; to: 0
      duration: Style.ori.arrivalMs; easing.type: Style.anim.easing
    }
  }

  Connections {
    target: PiSession
    // Only when the panel is CLOSED. With the panel open the answer is already
    // arriving in front of you and a second announcement is noise.
    function onSettled() {
      if (PiSession.panelOpen) return
      PiSession.unread = true
      arrive.restart()
    }
  }

  // ---------------------------------------------------------- what it is doing
  // `ingest()` writes the tool onto the open turn with ListModel.setProperty,
  // which notifies that model's DELEGATES and nothing else -- a plain
  // `PiSession.turns.get(i).tool` binding is evaluated once and never again,
  // which is why the tool never showed anywhere but the panel. So the readout
  // watches the model the way a view does: one throwaway QObject per turn, each
  // bound to its own row's roles. It lives here rather than on PiSession
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

  // The one word. `tool` arrives as "bash ls -la /etc" -- the name is the verb,
  // and the rest is the veil's business.
  readonly property string verb:
      root.thinking ? (root.liveTool === "" ? "thinking" : String(root.liveTool).split(" ")[0])
    : root.failed ? "failed"
    : root.unread ? "answered"
    : ""

  // Claude Code's own format, so the two strips are comparable at a glance.
  function humanTime(s) {
    if (s < 60) return s + "s"
    return Math.floor(s / 60) + "m " + (s % 60 < 10 ? "0" : "") + (s % 60) + "s"
  }

  // ------------------------------------------------------------- legibility
  // THE CASE THAT DECIDES THIS DESIGN. Unhoused, the cell sits on whatever is
  // behind the bar, and the contact sheet's finding was blunt: the glyph and
  // the rule survive a light backdrop, the READOUT TEXT does not, and compact
  // is immune because it has no text. A 1px outline in @crust on the text --
  // no pill, no plate, nothing added to the layout -- was tested against the
  // bare version and survived.
  //
  // It is applied to the glyph as well, which the sheet did not need to prove:
  // cold subtext0 on a white document is the one mark that has to be there and
  // has the least colour to be there with.
  readonly property color inkEdge: Theme.alpha(Theme.crust, 0.85)

  // ================================================================== paint
  // The keel: one rule, and the scan that travels it. MEASURE -- it spans the
  // glyph AND the words, so its length IS the readout's length.
  Item {
    id: keel
    width: root.expanded ? Style.ori.cellFull : Style.ori.haloBox
    height: parent.height

    // The only width animated anywhere in this widget, and it is an Item inside
    // the bar's own surface -- not a surface. Nothing here can cost a
    // configure/ack, and nothing here can move an island: the zone Bar.qml
    // reserves is a constant `Style.ori.zoneWidth` whatever this does.
    Behavior on width {
      NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
    }

    readonly property real thickness: root.holding ? 2 : 1

    Rectangle {
      id: rule
      anchors.left: parent.left
      anchors.right: parent.right
      y: Style.ori.keelY
      height: keel.thickness
      // Rounded caps, so it reads as a drawn stroke and not as a table border.
      radius: height / 2
      color: Theme.alpha(root.tint, root.ruleAlpha)

      Behavior on color {
        ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
      }
    }

    // The spinner, drawn on the one line this design owns. Position is the only
    // thing animated -- a translated texture, the cheapest motion there is --
    // and its SPEED is the flow gauge, so the rule says whether Ori is moving
    // as well as that it is alive.
    Rectangle {
      visible: root.thinking
      y: Style.ori.keelY
      height: keel.thickness
      width: Math.round(keel.width * 0.5)
      x: -width + (keel.width + width) * root.scanPhase
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: Theme.alpha(Theme.sapphire, 0) }
        GradientStop { position: 0.5; color: Theme.sapphire }
        GradientStop { position: 1.0; color: Theme.alpha(Theme.sapphire, 0) }
      }
    }

    // The arrival. It overshoots the rule's own length and comes back.
    Rectangle {
      visible: root.flash > 0.001
      anchors.left: parent.left
      y: Style.ori.keelY - 1
      width: keel.width + 14 * root.flash
      height: 3
      radius: 1.5
      color: Theme.alpha(Qt.lighter(Theme.sky, 1.5), root.flash)
    }
  }

  // ------------------------------------------------------------------ glyph
  Item {
    id: glyphSlot
    width: Style.ori.haloBox
    height: parent.height

    // The halo -- "the original glyph with aura around it", at the only size
    // the user will tolerate an aura: 22px, inside the bar.
    //
    // It is a RADIAL falloff and not a rounded Rectangle, which is not a detail
    // this once. A filled pill behind the mark is a box, and this design spent
    // twelve variants refusing to draw one; a disc with a hard edge is the same
    // box with corners. A gradient that reaches zero INSIDE its own bounds has
    // no edge anywhere, so the mark gains weight in the gap and the cell still
    // has nothing you could point at and call a chip. The box is 4px wider than
    // the gradient's diameter for exactly that reason.
    //
    // Same construction as the pool OriVeil draws, and the same reason: a
    // Rectangle gradient cannot fall off in both axes at once.
    Shape {
      anchors.centerIn: parent
      width: Style.ori.haloBox + 4
      height: Style.ori.haloBox + 4
      preferredRendererType: Shape.CurveRenderer
      opacity: root.thinking ? root.breath : 1

      ShapePath {
        strokeWidth: -1
        fillGradient: RadialGradient {
          centerX: (Style.ori.haloBox + 4) / 2
          centerY: (Style.ori.haloBox + 4) / 2
          centerRadius: Style.ori.haloBox / 2
          focalX: centerX
          focalY: centerY
          // Cold is faint but NOT nothing: at rest the halo is what says the
          // assistant lives here, and it is the state the screen is in most of
          // the day.
          GradientStop {
            position: 0.0
            color: Theme.alpha(root.tint,
              (root.holding ? 0.34 : root.thinking ? 0.20 : 0.09) + 0.30 * root.flash)
          }
          GradientStop {
            position: 0.45
            color: Theme.alpha(root.tint, root.holding ? 0.16 : root.thinking ? 0.09 : 0.04)
          }
          GradientStop { position: 1.0; color: Theme.alpha(root.tint, 0) }
        }
        PathRectangle {
          x: 0; y: 0
          width: Style.ori.haloBox + 4
          height: Style.ori.haloBox + 4
        }
      }
    }

    Text {
      id: glyph
      anchors.centerIn: parent
      // Lifted 2px so the rule below it has its own air.
      anchors.verticalCenterOffset: -2
      // soul.md signs Ori's own work with this diamond, so the bar and the
      // transcript are marked with the same glyph. Filled once it is holding
      // something for you: a SHAPE change is legible at a glance in a way a
      // brightness change is not.
      text: root.holding ? "◆" : "◇"
      color: root.holding ? Qt.lighter(root.tint, 1 + 0.4 * root.flash) : root.tint
      opacity: root.thinking ? root.breath : root.markAlpha
      font.family: Style.font.family
      font.pixelSize: Style.font.size
      font.weight: root.holding ? Style.font.boldWeight : Style.font.normalWeight
      renderType: Text.NativeRendering
      style: Text.Outline
      styleColor: root.inkEdge
      scale: 1 + 0.10 * root.flash

      Behavior on color {
        ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
      }
    }
  }

  // ---------------------------------------------------------------- readout
  // Verb and elapsed, and nothing else. What is MOVING is the rule's job now,
  // and the character count and the context percentage are the veil's -- the
  // panel footer already carried the context all along, so the bar was printing
  // it twice.
  Item {
    id: readout
    x: Style.ori.haloBox + Style.ori.cellGap
    width: root.expanded ? Style.ori.cellReadout : 0
    height: parent.height
    clip: true
    opacity: root.expanded ? 1 : 0

    Behavior on width {
      NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
    }
    Behavior on opacity {
      NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
    }

    Row {
      anchors.left: parent.left
      // Sits a touch high so the rule beneath it has the same air the glyph
      // gives it.
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: -2
      spacing: Style.ori.cellGap

      Text {
        width: Style.ori.toolWidth
        text: root.verb
        elide: Text.ElideRight
        color: Theme.subtext0
        font.family: Style.font.family
        font.pixelSize: Style.font.tiny
        renderType: Text.NativeRendering
        style: Text.Outline
        styleColor: root.inkEdge
      }

      Text {
        width: Style.ori.timeWidth
        horizontalAlignment: Text.AlignRight
        text: root.humanTime(root.elapsedSec)
        color: root.tint
        font.family: Style.font.family
        font.pixelSize: Style.font.tiny
        renderType: Text.NativeRendering
        style: Text.Outline
        styleColor: root.inkEdge

        Behavior on color {
          ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
        }
      }
    }
  }

  // ------------------------------------------------------------------ input
  // Exactly the cell's own extent, not the reserved zone: a 148px invisible
  // target across the bar would eat right-clicks 100px from anything visible.
  // It tracks the keel, which is the one thing here whose length already means
  // "this is how much of me there is".
  //
  // Hover raises the veil (Bar.qml owns the surface -- one per monitor, like
  // the calendar popover). Left click toggles the panel, which is what clears
  // the unread state, so a filled glyph cannot be dismissed without being read.
  // Right click pins the cell compact.
  //
  // This is a KEYBOARD desktop and it stays one: SUPER+A opens the panel and is
  // untouched by any of this. Hover and right-click are here because the user
  // asked for them by name, and nothing else in this shell became mouse-only.
  readonly property bool hovered: mouse.containsMouse

  MouseArea {
    id: mouse
    // Tracks the keel, with a floor. Compact, the keel is 22px wide and a
    // 22x26 target is a thing you aim at rather than move onto -- and hover is
    // the gesture the whole panel hangs off. 44 is the glyph plus one gap of
    // slack on each side: comfortable, and still nowhere near the 148px zone,
    // which would put a right-click 100px from anything visible.
    width: Math.max(keel.width, 2 * Style.ori.haloBox)
    height: parent.height
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor

    onClicked: function (event) {
      if (event.button === Qt.RightButton) PiSession.cellCompact = !PiSession.cellCompact
      else PiSession.panelOpen = !PiSession.panelOpen
    }
  }

  // ------------------------------------------------ why there is no notify-send
  // This used to spawn `notify-send` on every settle. That drew a rounded card
  // in the top right -- app name, icon, close button -- identical to a Slack
  // ping, produced by starting a process to talk to a notification server that
  // is this very process. Then it was replaced by OriArrival, which said the
  // first line of the answer under the bar in the shell's own vocabulary; that
  // is deleted too, because it lay across the user's windows unbidden and that
  // is the fault this whole design exists to remove.
  //
  // What is left is: the glyph fills, the rule thickens and overshoots, and it
  // STAYS that way. Two things answer the notification centre:
  //
  //   NOTHING ORI SAYS EXPIRES. The centre exists because a card is gone in ten
  //   seconds whether or not anyone saw it. Ori's unread state has no timeout:
  //   the mark stays filled until the panel is actually opened. A missed
  //   arrival is still on screen an hour later.
  //
  //   THE TRANSCRIPT IS THE BETTER ARCHIVE. The centre row carried 220
  //   truncated characters with the rest unrecoverable. The panel holds every
  //   turn in full, with its tools and its cost, and SUPER+A is the same
  //   gesture as opening the centre.
  //
  // (CalendarReminders still posts through notify-send, correctly: a reminder
  // has no second home to be recovered from.)
}
