import QtQuick
import Quickshell
import Quickshell.Wayland
import "root:/"

// One fullscreen screensaver surface. Variants makes one per monitor.
//
// Replaces the old fullscreen-kitty-running-tte screensaver: same idea, but
// drawn by the GPU inside the shell process instead of by a terminal painting
// characters. That drops two processes (kitty, tte) and the `uv tool install
// terminaltexteffects` dependency, which had no home in this repo and would
// have silently failed on the lenovo.
PanelWindow {
  id: win

  signal dismissed()

  // Variants hands each delegate its screen through modelData.
  property var modelData: null
  screen: modelData

  WlrLayershell.namespace: "quickshell-screensaver"
  WlrLayershell.layer: WlrLayer.Overlay
  // Exclusive, so a keypress reaches us rather than whatever is underneath --
  // the whole exit gesture is "any key".
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  // All four edges: the surface is sized once, by the compositor, and never
  // resized. See CLAUDE.md -- a layer surface that changes size waits for a
  // configure/ack round trip per frame.
  anchors { top: true; bottom: true; left: true; right: true }

  color: Theme.crust

  // Deliberately NOT an idle inhibitor. The screensaver runs *because* the
  // session is idle; inhibiting would freeze the very countdown that opens the
  // lock behind it. (The old kitty window rule made exactly that mistake.)

  // Seconds since this surface opened, vsync-locked. FrameAnimation only ticks
  // while running, so closing the screensaver really does stop the work.
  FrameAnimation {
    id: clock
    running: true
  }

  // Master fade. Entrance only -- the exit is instant, because a screensaver
  // that lingers after you touch the keyboard feels broken.
  property real fade: 0
  Component.onCompleted: win.fade = 1
  Behavior on fade {
    NumberAnimation { duration: 900; easing.type: Easing.OutCubic }
  }

  // Backdrop only. Held well down so the decrypt art in front stays legible;
  // at full strength the two effects fight and neither reads.
  ShaderEffect {
    anchors.fill: parent
    opacity: 0.4
    fragmentShader: Qt.resolvedUrl("shaders/rain.frag.qsb")

    // Uniform-block members are matched by property name.
    property real time: clock.elapsedTime
    property vector2d resolution: Qt.vector2d(width, height)
    property real fade: win.fade
    // Hands the shader the art's current position, so its clearing follows.
    property vector2d center: Qt.vector2d(
      0.5 + (width > 0 ? win.driftX / width : 0),
      0.5 + (height > 0 ? win.driftY / height : 0))
  }

  // ------------------------------------------------------------ the art
  // Drifts slowly around the centre. Screensavers move for a reason: a static
  // bright mark parked on a panel for twenty minutes is burn-in.
  // Two slow sines on deliberately unrelated periods, so the path never
  // retraces itself and the art reads as floating rather than as sliding on a
  // track. Amplitudes are a few percent of the screen: enough to see over a
  // minute, not enough to notice moment to moment.
  property real driftX: 0
  property real driftY: 0

  SequentialAnimation on driftX {
    loops: Animation.Infinite
    NumberAnimation { from: -0.03 * win.width; to: 0.03 * win.width; duration: 37000; easing.type: Easing.InOutSine }
    NumberAnimation { from: 0.03 * win.width; to: -0.03 * win.width; duration: 37000; easing.type: Easing.InOutSine }
  }
  SequentialAnimation on driftY {
    loops: Animation.Infinite
    NumberAnimation { from: 0.035 * win.height; to: -0.035 * win.height; duration: 53000; easing.type: Easing.InOutSine }
    NumberAnimation { from: -0.035 * win.height; to: 0.035 * win.height; duration: 53000; easing.type: Easing.InOutSine }
  }

  DecryptArt {
    id: art
    anchors.fill: parent
    opacity: win.fade
    t: clock.elapsedTime * 1000
    driftX: win.driftX
    driftY: win.driftY
  }

  // ------------------------------------------------------------- dismissal
  // A short arm delay, so the keystroke or pointer nudge that happens as the
  // surface maps cannot immediately close what it just opened.
  property bool armed: false
  Timer {
    interval: 500
    running: true
    onTriggered: win.armed = true
  }

  Item {
    anchors.fill: parent
    focus: true
    Keys.onPressed: function (event) {
      event.accepted = true
      if (win.armed) win.dismissed()
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.AllButtons
    // Any real movement counts; reacting to the first positionChanged alone
    // would fire on the pointer merely being under the surface when it maps.
    property point origin: Qt.point(-1, -1)
    onPositionChanged: function (mouse) {
      if (origin.x < 0) {
        origin = Qt.point(mouse.x, mouse.y)
        return
      }
      if (!win.armed) return
      if (Math.abs(mouse.x - origin.x) + Math.abs(mouse.y - origin.y) > 12) win.dismissed()
    }
    onPressed: if (win.armed) win.dismissed()
    onWheel: if (win.armed) win.dismissed()
  }
}
