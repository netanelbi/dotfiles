import QtQuick
// Theme/Style are singletons in the config root; a subdirectory does not get
// the root's implicit import, so pull it in explicitly.
import ".."

// Ori's bolt, at a size that has room to move.
//
// The bar's cell says the same thing in 14 pixels. The panel is the surface
// where that constraint lifts: the bolt ROCKS about 45 degrees and breathes in
// scale while a turn runs. Idle it is a dormant spark; working, it is charge
// in motion.
//
// It owns no clock. `phase` is seconds handed down from the panel's single
// FrameAnimation, which only ticks while a turn is running -- so when nothing
// is running, every binding below is frozen rather than merely invisible.
//
// Text presentation (U+FE0E) on purpose: the colour-emoji form would ignore
// `accent` entirely, and the accent is how the panel marks state.
Item {
  id: mark

  property color accent: Theme.sapphire
  // A turn is running: the bolt rocks and breathes.
  property bool alive: false
  // Seconds, from the panel's frame clock.
  property real phase: 0

  implicitWidth: 18
  implicitHeight: 18

  // 0..1 over one breath. Sine rather than a triangle so it eases at both ends
  // by construction.
  readonly property real beat: alive
    ? 0.5 + 0.5 * Math.sin(phase * 2 * Math.PI * 1000 / Style.ori.breathMs)
    : 0

  // It ROCKS a little while working, around UPRIGHT -- a bolt tipped 45
  // degrees reads as lying down, which the diamond never did. +-10 degrees on
  // twice the breath period, so rock and breathe never beat together.
  readonly property real spin:
    alive ? 10 * Math.sin(phase * Math.PI * 1000 / Style.ori.breathMs) : 0

  // ------------------------------------------------------------------- bolt
  Text {
    anchors.centerIn: parent
    text: "\u26A1\uFE0E"
    color: mark.accent
    opacity: mark.alive ? 1 : 0.7
    rotation: mark.spin
    font.family: Style.font.family
    font.pixelSize: mark.width * 0.95
    // Breathing in SCALE, not disappearance: a mark that winks out reads as a
    // fault, one that swells reads as breathing.
    scale: 0.92 + 0.10 * mark.beat

    Behavior on opacity {
      NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
    }
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
