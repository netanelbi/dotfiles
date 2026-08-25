import QtQuick
// Theme/Style are singletons in the config root; a subdirectory does not get
// the root's implicit import, so pull it in explicitly.
import ".."

// Ori's diamond, at a size that has room to move.
//
// The bar's OriDot says the same thing in 14 pixels and says outright what it
// had to give up to fit: "a bar 30px tall has no room for something that
// grows", so it breathes in opacity alone. The panel is the surface where that
// constraint lifts -- so the same glyph is built out of real geometry here: a
// hollow shell that turns, and a core inside it that breathes. Idle it is a
// dormant crystal; working, it is a machine part in motion.
//
// It owns no clock. `phase` is seconds handed down from the panel's single
// FrameAnimation, which only ticks while a turn is running -- so when nothing
// is running, every binding below is frozen rather than merely invisible.
Item {
  id: mark

  property color accent: Theme.sapphire
  // A turn is running: the shell rocks and the core breathes.
  property bool alive: false
  // Seconds, from the panel's frame clock.
  property real phase: 0

  implicitWidth: 18
  implicitHeight: 18

  // 0..1 over one breath. Sine rather than a triangle so it eases at both ends
  // by construction, the way OriDot's InOutQuad pair does.
  readonly property real beat: alive
    ? 0.5 + 0.5 * Math.sin(phase * 2 * Math.PI * 1000 / Style.anim.breath)
    : 0

  // It ROCKS about 45 degrees rather than turning through them. A continuous
  // rotation was the first attempt and it fails at the one job the glyph has:
  // a quarter of the way round a diamond is a square, and Ori signs its own
  // work with a diamond. +-16 degrees keeps the silhouette unmistakable and
  // still moves. On twice the core's period, so the two never beat together and
  // the mark never looks like a mechanism ticking.
  readonly property real spin:
    45 + (alive ? 16 * Math.sin(phase * Math.PI * 1000 / Style.anim.breath) : 0)

  // ------------------------------------------------------------------ shell
  Rectangle {
    id: shell
    anchors.centerIn: parent
    width: mark.width * 0.62
    height: width
    radius: 1
    rotation: mark.spin
    color: Theme.transparent
    border.width: 1.5
    border.color: mark.accent
    opacity: mark.alive ? 1 : 0.7

    Behavior on opacity {
      NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
    }
    Behavior on border.color {
      ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
    }
  }

  // ------------------------------------------------------------------- core
  // Never fully gone, for the reason OriDot's pulse bottoms out at 0.35: a mark
  // that disappears reads as a fault, one that dims reads as breathing.
  Rectangle {
    anchors.centerIn: parent
    width: mark.width * (0.15 + 0.2 * mark.beat)
    height: width
    rotation: mark.spin
    color: mark.accent
    opacity: mark.alive ? 0.5 + 0.5 * mark.beat : 0.35

    Behavior on color {
      ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
    }
  }

  // ------------------------------------------------------------------- ping
  // One ring on the beat an answer lands, the same gesture the bar makes when
  // an answer arrives unread. Here it fires with the panel OPEN, where the bar
  // deliberately stays quiet -- this is the full stop at the end of the turn,
  // not an alert. It costs nothing at rest: the ring has no size until the
  // animation gives it one.
  function ping() { ringAnim.restart() }

  Rectangle {
    id: ring
    anchors.centerIn: parent
    width: 0
    height: width
    radius: width / 2
    color: Theme.transparent
    border.width: 1
    border.color: mark.accent
    opacity: 0
  }

  ParallelAnimation {
    id: ringAnim
    NumberAnimation {
      target: ring; property: "width"; from: mark.width * 0.5; to: mark.width * 2.1
      duration: Style.anim.slow; easing.type: Style.anim.easing
    }
    SequentialAnimation {
      NumberAnimation { target: ring; property: "opacity"; from: 0; to: 0.7; duration: Style.anim.quick }
      NumberAnimation {
        target: ring; property: "opacity"; to: 0
        duration: Style.anim.slow; easing.type: Style.anim.easingSmooth
      }
    }
  }
}
