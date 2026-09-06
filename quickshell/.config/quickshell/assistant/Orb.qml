import QtQuick
import QtQuick.Shapes
import ".."

// The orb: Ori's body. One drawing, used at three sizes in three places --
// docked in the bar's centre pill, out on the screen while you talk to it,
// and at the panel's input row while the panel is open. Same shape everywhere,
// so it reads as one creature moving between perches rather than three
// indicators that happen to match.
//
// It is a spirit, not a widget: a soft radial core with a halo that falls off
// to nothing inside its own bounds (no edge, no box), two dashed rings that
// only turn while something is happening, rings on every sound it hears, satellites
// while it thinks, and a swell on the voice level while it speaks.
//
// Every animation gates on `mode` and `alive`, so a docked idle orb costs
// nothing: no clock runs, no frame is painted, until it wakes.
Item {
  id: orb

  // idle | listening | thinking | working | speaking | done | failed
  // "thinking" is the model; "working" is a tool touching the machine, in
  // the shell's own mauve for that (Theme.accent).
  property string mode: "idle"
  // Live level 0..1: the voice while listening, the speech while speaking.
  property real level: 0
  // Core diameter. The halo is 3.4x this, the rings 1.6x and 2.1x.
  property real size: 24
  // False freezes every animation regardless of mode: the docked orb in the
  // bar, and the overlay orb while it is off screen.
  property bool alive: true
  // Slow breath while idle. Off for the bar (a permanent 4s animation in a
  // 30px strip is a cost the shell refuses); on for the overlay.
  property bool breathe: false
  // The pointer is on it: the rings wake and turn, even at rest. Event-driven
  // -- a hover, not a clock -- so the docked orb can afford it.
  property bool poked: false
  // A slow drift, up and down and a little sideways, while it floats free or
  // rests in the panel. Never in the bar.
  property bool floating: false

  transform: Translate {
    id: drift
    x: 0
    y: 0
    SequentialAnimation on y {
      running: orb.alive && orb.floating
      loops: Animation.Infinite
      NumberAnimation { to: -7; duration: 1900; easing.type: Easing.InOutSine }
      NumberAnimation { to: 4;  duration: 2300; easing.type: Easing.InOutSine }
      NumberAnimation { to: -2; duration: 1500; easing.type: Easing.InOutSine }
      NumberAnimation { to: 5;  duration: 2100; easing.type: Easing.InOutSine }
      NumberAnimation { to: 0;  duration: 1700; easing.type: Easing.InOutSine }
    }
    SequentialAnimation on x {
      running: orb.alive && orb.floating
      loops: Animation.Infinite
      NumberAnimation { to: 4;  duration: 2600; easing.type: Easing.InOutSine }
      NumberAnimation { to: -5; duration: 3100; easing.type: Easing.InOutSine }
      NumberAnimation { to: 2;  duration: 1900; easing.type: Easing.InOutSine }
      NumberAnimation { to: 0;  duration: 2400; easing.type: Easing.InOutSine }
    }
  }

  // Not readonly: the Behavior below animates the change.
  property color tint:
      mode === "listening" ? Theme.sapphire
    : mode === "thinking"  ? Theme.blue
    : mode === "working"   ? Theme.accent
    : mode === "speaking"  ? Theme.lavender
    : mode === "done"      ? Theme.green
    : mode === "failed"    ? Theme.red
    : Theme.mauve

  readonly property bool busy: alive && (mode !== "idle" || poked)
  readonly property real haloD: size * 3.4

  implicitWidth: haloD
  implicitHeight: haloD

  Behavior on tint { ColorAnimation { duration: Style.anim.colorDuration * 2; easing.type: Style.anim.easingSmooth } }

  // ------------------------------------------------------------------ halo
  // A radial falloff, not a disc: it reaches zero inside its own bounds so
  // there is no edge anywhere. This is what spills light onto the wallpaper
  // and onto the windows below the orb when it is out.
  Shape {
    id: halo
    anchors.centerIn: parent
    width: orb.haloD
    height: orb.haloD
    preferredRendererType: Shape.CurveRenderer
    opacity: orb.mode === "idle" ? 0.55 : 0.95
    Behavior on opacity { NumberAnimation { duration: 400 } }

    // The breath: a slow swell on the whole halo. Speaking rides the level on
    // top of it, so the light answers the words.
    // The pulse: the whole halo swells with the level -- the mic while it
    // listens, the speaker while it talks. Squared, so quiet stays quiet and
    // a loud word lands.
    scale: (1 + orb.level * orb.level * 0.9) * breath.value
    Behavior on scale { NumberAnimation { duration: 70 } }

    ShapePath {
      strokeWidth: -1
      fillGradient: RadialGradient {
        centerX: orb.haloD / 2; centerY: orb.haloD / 2
        focalX: centerX; focalY: centerY
        centerRadius: orb.haloD / 2
        GradientStop { position: 0.0;  color: Theme.alpha(orb.tint, 0.55) }
        GradientStop { position: 0.35; color: Theme.alpha(orb.tint, 0.22) }
        GradientStop { position: 0.7;  color: Theme.alpha(orb.tint, 0.06) }
        GradientStop { position: 1.0;  color: Theme.alpha(orb.tint, 0.0) }
      }
      PathRectangle { x: 0; y: 0; width: orb.haloD; height: orb.haloD }
    }
  }

  QtObject {
    id: breath
    property real value: 1
    // 4.2s in, out. Only while asked to breathe, or while awake.
    SequentialAnimation on value {
      running: orb.alive && (orb.breathe || orb.mode !== "idle")
      loops: Animation.Infinite
      NumberAnimation { to: 1.07; duration: 2100; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1.0;  duration: 2100; easing.type: Easing.InOutSine }
    }
  }

  // ------------------------------------------------------------- hearing
  // The second layer, and the one that means "I hear you": a ring leaves the
  // core on every burst of sound, as wide as the burst was loud. Not on a
  // clock -- on the LEVEL. Silence sends nothing, so an orb that is not
  // hearing you is visibly deaf. The same rings leave it when it talks, off
  // the speaker's level.
  property real lastLevel: 0
  property int lastPing: 0
  onLevelChanged: {
    var now = Date.now()
    var rising = level > lastLevel + 0.05
    lastLevel = level
    if (!alive || level < 0.15 || !rising || now - lastPing < 110) return
    lastPing = now
    ping(level)
  }
  property int pingSlot: 0
  function ping(strength) {
    var r = rings.itemAt(pingSlot % 4)
    pingSlot++
    if (!r) return
    r.reach = 1.6 + strength * 2.2
    r.kick()
  }
  Repeater {
    id: rings
    model: 4
    Rectangle {
      id: rip
      property real reach: 2.4
      anchors.centerIn: parent
      width: orb.size * 1.1
      height: width
      radius: width / 2
      color: "transparent"
      border.width: 1.2
      border.color: orb.tint
      opacity: 0
      scale: 1
      function kick() { burst.restart() }
      ParallelAnimation {
        id: burst
        SequentialAnimation {
          PropertyAction { target: rip; property: "scale"; value: 1 }
          NumberAnimation { target: rip; property: "scale"; to: rip.reach; duration: 900; easing.type: Easing.OutQuad }
        }
        SequentialAnimation {
          PropertyAction { target: rip; property: "opacity"; value: 0.85 }
          NumberAnimation { target: rip; property: "opacity"; to: 0; duration: 900; easing.type: Easing.InQuad }
        }
      }
    }
  }

  // ----------------------------------------------------------------- rings
  // Two dashed rings turning against each other. Faint at rest, bright and
  // fast while thinking.
  component Ring: Shape {
    id: ring
    property real d: orb.size * 1.8
    property real dashOn: 8
    property real dashOff: 5
    property real speed: 16000
    property bool reverse: false
    anchors.centerIn: parent
    width: d
    height: d
    preferredRendererType: Shape.CurveRenderer
    opacity: orb.mode === "idle" ? (orb.poked ? 0.6 : 0.0) : (orb.mode === "thinking" || orb.mode === "working") ? 0.9 : 0.35 + orb.level * 0.5
    Behavior on opacity { NumberAnimation { duration: 400 } }
    scale: 1 + orb.level * 0.35
    Behavior on scale { NumberAnimation { duration: 90 } }
    RotationAnimation on rotation {
      running: orb.busy
      loops: Animation.Infinite
      from: ring.reverse ? 360 : 0
      to: ring.reverse ? 0 : 360
      duration: orb.mode === "thinking" ? ring.speed / 10 : (orb.mode === "working" || orb.poked) ? ring.speed / 5 : ring.speed
    }
    ShapePath {
      strokeColor: orb.tint
      strokeWidth: (orb.mode === "thinking" || orb.mode === "working") ? 1.4 : 1
      fillColor: "transparent"
      strokeStyle: ShapePath.DashLine
      dashPattern: [ring.dashOn, ring.dashOff]
      capStyle: ShapePath.RoundCap
      PathAngleArc {
        centerX: ring.d / 2; centerY: ring.d / 2
        radiusX: ring.d / 2 - 1; radiusY: ring.d / 2 - 1
        startAngle: 0; sweepAngle: 360
      }
    }
  }
  Ring { d: orb.size * 1.8; dashOn: 26; dashOff: 15; speed: 16000 }
  Ring { d: orb.size * 1.4; dashOn: 2; dashOff: 6; speed: 16000; reverse: true }

  // ------------------------------------------------------------ satellites
  // Three white motes orbiting while it thinks.
  Item {
    id: sats
    anchors.centerIn: parent
    width: orb.size * 3.2
    height: width
    opacity: orb.alive && (orb.mode === "thinking" || orb.mode === "working") ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 300 } }
    RotationAnimation on rotation {
      running: orb.alive && (orb.mode === "thinking" || orb.mode === "working")
      loops: Animation.Infinite
      from: 0; to: 360; duration: 1600
    }
    Repeater {
      model: 3
      Rectangle {
        required property int index
        readonly property real r: [1.6, 1.2, 0.9][index] * orb.size / 12
        readonly property real a: [0, Math.PI, -Math.PI / 2][index]
        x: sats.width / 2 + Math.cos(a) * sats.width / 2 - r
        y: sats.height / 2 + Math.sin(a) * sats.width / 2 - r
        width: r * 2; height: r * 2; radius: r
        color: "white"
      }
    }
  }

  // ------------------------------------------------------------------ core
  // White centre falling into the tint. Swells with the level.
  Shape {
    id: core
    anchors.centerIn: parent
    width: orb.size
    height: orb.size
    preferredRendererType: Shape.CurveRenderer
    scale: 1 + orb.level * 0.55
    Behavior on scale { NumberAnimation { duration: 70 } }

    ShapePath {
      strokeWidth: -1
      fillGradient: RadialGradient {
        centerX: orb.size / 2; centerY: orb.size / 2
        focalX: centerX; focalY: centerY
        centerRadius: orb.size / 2
        GradientStop { position: 0.0;  color: "white" }
        GradientStop { position: 0.35; color: Qt.rgba(1, 1, 1, 0.9) }
        GradientStop { position: 0.62; color: Theme.alpha(orb.tint, 0.9) }
        GradientStop { position: 1.0;  color: Theme.alpha(orb.tint, 0.0) }
      }
      PathRectangle { x: 0; y: 0; width: orb.size; height: orb.size }
    }
  }

  // The bright pinhead at the very centre.
  Rectangle {
    anchors.centerIn: parent
    width: orb.size * 0.3
    height: width
    radius: width / 2
    color: "white"
    opacity: orb.mode === "done" ? 0 : 0.95
    Behavior on opacity { NumberAnimation { duration: 200 } }
  }

  // ------------------------------------------------------------------ done
  // A check pops in where the pinhead was.
  Text {
    anchors.centerIn: parent
    text: "✓"
    color: "white"
    font.pixelSize: orb.size * 0.75
    font.bold: true
    opacity: orb.mode === "done" ? 1 : 0
    scale: orb.mode === "done" ? 1 : 0.4
    Behavior on opacity { NumberAnimation { duration: 200 } }
    Behavior on scale { NumberAnimation { duration: 320; easing.type: Easing.OutBack } }
  }
}
