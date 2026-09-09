import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import ".."

// The orb out on the screen: where Ori's body goes while you talk to it.
//
// It leaves the bar's centre pill when you press to talk, floats over the
// windows you are NOT working in, shows what the mic heard beside it, spins
// while the session thinks, pulses while Ori speaks (no text -- Ori talks),
// and flies back into the pill when the turn is done. The panel never opens
// for voice.
//
// Two rules keep it out of the way, both from the user:
//   * it never sits over the FOCUSED window. It picks the biggest other window
//     on the workspace; with nothing else on screen it keeps to the focused
//     window's top-right corner.
//   * it moves away from the pointer. The only input this surface takes is a
//     ring around the orb; the pointer entering it pushes the orb off.
//
// Full-screen surface, fixed size, never resized: everything moves inside it.
PanelWindow {
  id: overlay

  required property var voice

  WlrLayershell.namespace: "quickshell-ori-orb"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore
  color: "transparent"

  anchors { top: true; left: true; bottom: true; right: true }
  // The surface is the whole screen, always. A smaller box that grew and
  // shrank around the orb was tried for CPU: the compositor takes a frame or
  // two to apply a resize, and in those frames the orb drew at the wrong
  // offset -- beside the pill on pop-out, and out from under the pointer
  // mid-drag. The saving was ~1.5% of a core; not worth a creature that
  // slips out of your hand.
  readonly property real winX: 0
  readonly property real winY: 0
  readonly property real lx: ox
  readonly property real ly: oy

  // True for the length of any animated move, so the surface stays full
  // screen until the orb has landed.
  property bool moving: false
  Timer {
    id: settle
    onTriggered: overlay.moving = false
  }

  // Out for a voice exchange, or out because it is FREE, or out because Ori is
  // SPEAKING -- a session's speak tool counts: with the panel closed the mouth
  // in the footer is not visible, and the orb is where the sound gets a body.
  // While the panel is open the orb is docked at the panel's input row instead,
  // so this surface has nothing to draw.
  readonly property bool wantOut: (voice.state !== "hidden" || OriClient.orbFree || OriClient.speaking) && !OriClient.panelOpen
  // Drawn: wanted out, or still flying home.
  property bool shown: false
  visible: shown || stage.opacity > 0.001
  mask: Region { item: overlay.shown ? hoverZone : null }

  // Where it went when it last left this surface: into the panel, or into
  // the pill. It comes back out of the same place.
  property bool inPanel: false

  // Its memory: where it was, and whether it was put there, kept across
  // trips home and across shell reloads.
  PersistentProperties {
    id: mem
    reloadableId: "ori-orb-place"
    property string screenName: ""
    property real x: -1
    property real y: -1
    property bool pinned: false
  }
  function forget() { mem.x = -1; mem.y = -1; mem.pinned = false; mem.screenName = ""; pinned = false }
  function monDebug() {
    var f = Hyprland.focusedMonitor, m = overlay.screen ? Hyprland.monitorFor(overlay.screen) : null
    return (f && f.lastIpcObject ? f.lastIpcObject.name : "?") + "/" + (m && m.lastIpcObject ? m.lastIpcObject.name : "?")
      + (f === m ? "=same" : "=diff") + " pinned=" + pinned
  }
  function memInfo() { return mem.screenName + ":" + Math.round(mem.x) + "," + Math.round(mem.y) + (mem.pinned ? "*" : "") }
  function remember() {
    if (!shown || !wantOut) return
    mem.screenName = overlay.screen ? overlay.screen.name : ""
    mem.x = ox; mem.y = oy; mem.pinned = pinned
  }
  onOxChanged: remember()
  onOyChanged: remember()
  onPinnedChanged: remember()

  function screenNamed(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (screens[i].name === name) return screens[i]
    return null
  }

  // The screen whose monitor has focus, by monitor name.
  function focusedScreen() {
    var focused = Hyprland.focusedMonitor
    if (!focused) return null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var m = Hyprland.monitorFor(screens[i])
      if (m && m.name === focused.name) return screens[i]
    }
    return null
  }

  onWantOutChanged: {
    if (wantOut) {
      hide.stop()
      if (shown) { leave.restart(); return }   // caught mid-flight home: turn around
      if (!shown) {
        // Pop out: from the pill on the monitor with focus (or from the
        // panel's input row as the panel closes), then fly to the spot. The
        // screen is chosen HERE and the pill looked up BY NAME: a screen just
        // assigned is not what the getter returns until the window has moved.
        Hyprland.refreshToplevels()
        pinned = false
        var d = dock()
        if (!inPanel) {
          var fs = focusedScreen()
          if (fs) { overlay.screen = fs; d = dockFor(fs.name) }
        }
        if (inPanel && OriClient.panelDock.screen !== "") {
          var s = screenNamed(OriClient.panelDock.screen)
          if (s) overlay.screen = s
          d = OriClient.panelDock
        }
        inPanel = false
        place(d.x, d.y, 0)
        shown = true
        leave.restart()
      }
    } else {
      // Fly home -- into the panel's input row if that is what took it,
      // else into the pill -- then vanish there. The panel is built lazily on
      // open, so its dock point is read a beat later.
      inPanel = OriClient.panelOpen
      if (inPanel) { goPanel.tries = 0; goPanel.restart() }
      else { var h = dock(); place(h.x, h.y, 700); hide.restart() }
    }
  }
  // Into the panel. The panel is built lazily on open and reports its input
  // row a beat later, so this waits for it (up to ~1s). On the same screen
  // the orb flies into the row; on another screen it simply fades out here
  // while the panel's own orb pops in over there. Never the pill.
  Timer {
    id: goPanel
    interval: 120
    repeat: true
    property int tries: 0
    onTriggered: {
      var mine = overlay.screen ? overlay.screen.name : ""
      var d = OriClient.panelDock
      if (d.screen === "" && ++tries < 8) return
      running = false; tries = 0
      if (d.screen === mine) { OriClient.orbInFlight = true; overlay.place(d.x, d.y, 700) }
      hide.restart()
    }
  }
  Timer {
    id: hide
    interval: 720
    onTriggered: { overlay.shown = false; OriClient.orbInFlight = false }
  }
  // Not a timer: a frame clock. The surface takes a few frames to map after
  // it is shown, and a glide started on a timer had the orb visibly away from
  // the pill by the time the first frame landed. Two drawn frames at the pill,
  // then it leaves.
  FrameAnimation {
    id: leave
    running: false
    property int drawn: 0
    onRunningChanged: if (running) drawn = 0
    onTriggered: {
      drawn++
      if (drawn < 2) return
      running = false
      go()
    }
    function go() {
      var mine = overlay.screen ? overlay.screen.name : ""
      var p
      if (mem.x >= 0 && mem.screenName === mine) {
        // Back to where it was. A spot it was put in stays even over the
        // focused window; a spot it chose itself is re-checked. The spot is
        // read BEFORE the pin is restored: restoring it writes the memory.
        var mx = mem.x, my = mem.y, pinnedThere = mem.pinned
        overlay.pinned = pinnedThere
        p = pinnedThere ? overlay.clamp(mx, my) : overlay.avoidFocus(overlay.clamp(mx, my))
      } else {
        p = overlay.outSpot()
      }
      // A soft start, so it is seen LEAVING the pill rather than already gone.
      overlay.place(p.x, p.y, 900, Easing.InOutCubic)
    }
  }

  // It never moves itself between monitors. It leaves the pill on the screen
  // with focus, and after that only a throw (crossTo) or the pill takes it
  // to another one.

  // A creature keeps off the window you turn to: when focus moves, it moves.
  Connections {
    target: Hyprland
    function onActiveToplevelChanged() {
      if (!overlay.wantOut || !overlay.shown || overlay.pinned) return
      var p = overlay.avoidFocus({ x: overlay.ox, y: overlay.oy })
      if (p.x !== overlay.ox || p.y !== overlay.oy) overlay.place(p.x, p.y, 700)
    }
  }

  // ...and wanders a little while it has nothing to do: a slow, occasional
  // step to somewhere nearby. Half a minute apart, so it costs nothing to
  // speak of, and only while free and idle.
  Timer {
    id: roam
    interval: 9000 + Math.round(Math.random() * 11000)
    running: overlay.shown && OriClient.orbFree && overlay.voice.state === "hidden" && !overlay.pinned
    repeat: true
    onTriggered: {
      // A slow glide somewhere else on the screen -- the whole screen, over
      // time, never onto the focused window. Then a fresh interval.
      var a = Math.random() * Math.PI * 2, r = 140 + Math.random() * 260
      var p = overlay.avoidFocus(overlay.clamp(overlay.ox + Math.cos(a) * r, overlay.oy + Math.sin(a) * r))
      overlay.place(p.x, p.y, 2600)
      roam.interval = 9000 + Math.round(Math.random() * 11000)
    }
  }

  // -------------------------------------------------------------- position
  // The orb's centre, in this surface's px. Animated on every change: the
  // flight from the pill, a drag, the flight back.
  property real ox: 200
  property real oy: 120
  property int moveMs: 700
  // An instant move (ms = 0) bypasses the Behavior entirely: a zero-length
  // animation does not land before the next glide starts, so the glide set
  // off from wherever the orb was last -- the other monitor's pill, once.
  property int moveEase: Easing.OutCubic
  Behavior on ox { enabled: overlay.moveMs > 0; NumberAnimation { id: oxAnim; duration: overlay.moveMs; easing.type: overlay.moveEase } }
  Behavior on oy { enabled: overlay.moveMs > 0; NumberAnimation { id: oyAnim; duration: overlay.moveMs; easing.type: overlay.moveEase } }

  function place(x, y, ms, ease) {
    moveEase = ease === undefined ? Easing.OutCubic : ease
    moveMs = ms
    // An instant move also ends any glide in flight: a Behavior that is
    // merely disabled lets its running animation keep writing the property,
    // which steered a throw sideways.
    if (ms === 0) { oxAnim.stop(); oyAnim.stop() }
    ox = x
    oy = y
    if (ms > 0) { moving = true; settle.interval = ms + 60; settle.restart() }
  }

  function dockFor(name) {
    var d = OriClient.orbDocks[name]
    return d ? d : { x: overlay.sw / 2, y: 17 }
  }
  function dock() { return dockFor(overlay.screen ? overlay.screen.name : "") }

  // The focused monitor's origin, so a window's global `at` becomes local.
  function monitorOrigin() {
    if (!overlay.screen) return { x: 0, y: 0, id: -1 }
    var mon = Hyprland.monitorFor(overlay.screen)
    var o = mon ? mon.lastIpcObject : null
    return { x: o && o.x !== undefined ? o.x : 0, y: o && o.y !== undefined ? o.y : 0,
             id: o && o.id !== undefined ? o.id : -1,
             ws: o && o.activeWorkspace ? o.activeWorkspace.id : -1 }
  }

  function rectOf(tl, origin) {
    var o = tl ? tl.lastIpcObject : null
    if (!o || !o.at || !o.size) return null
    return { x: o.at[0] - origin.x, y: o.at[1] - origin.y, w: o.size[0], h: o.size[1],
             address: o.address, monitor: o.monitor, hidden: o.hidden === true,
             ws: o.workspace ? o.workspace.id : -1 }
  }

  // The focused window, if it is on THIS monitor; a window focused on
  // another screen says nothing about where to be on this one.
  function focusRect() {
    var origin = monitorOrigin()
    var r = rectOf(Hyprland.activeToplevel, origin)
    return r && r.monitor === origin.id ? r : null
  }

  // Where to go when leaving the pill: over the biggest window that is not
  // the focused one, on this monitor and workspace. Otherwise the focused
  // window's top-right corner. Otherwise under the bar, centred.
  function outSpot() {
    var origin = monitorOrigin()
    var focus = focusRect()
    // The workspace showing on THIS monitor, not the focused one elsewhere.
    var ws = origin.ws
    var vals = Hyprland.toplevels.values
    var best = null, bestArea = 0
    for (var i = 0; i < vals.length; i++) {
      var r = rectOf(vals[i], origin)
      if (!r || r.hidden || r.monitor !== origin.id || r.ws !== ws) continue
      if (focus && r.address === focus.address) continue
      var area = r.w * r.h
      if (area > bestArea && r.w > 120 && r.h > 120) { best = r; bestArea = area }
    }
    if (best) return clamp(best.x + best.w / 2, best.y + 70)
    if (focus) return clamp(focus.x + focus.w - 70, focus.y + 70)
    return clamp(overlay.sw / 2, 120)
  }

  // The screen's size, not the surface's: right after it is shown the
  // surface has not been configured yet and reads 0x0, which clamped every
  // spot into the top-left corner.
  readonly property real sw: overlay.screen ? overlay.screen.width : overlay.width
  readonly property real sh: overlay.screen ? overlay.screen.height : overlay.height
  readonly property int pad: 26
  function clamp(x, y) {
    return { x: Math.max(pad, Math.min(overlay.sw - pad, x)),
             y: Math.max(pad, Math.min(overlay.sh - pad, y)) }
  }

  // ------------------------------------------------------------ monitors
  // Which monitor holds a GLOBAL point, from Hyprland's own layout.
  function monitorAt(gx, gy) {
    var vals = Hyprland.monitors.values
    for (var i = 0; i < vals.length; i++) {
      var o = vals[i].lastIpcObject
      if (!o || o.disabled) continue
      var w = o.width / (o.scale || 1), h = o.height / (o.scale || 1)
      if (gx >= o.x && gx < o.x + w && gy >= o.y && gy < o.y + h)
        return { name: o.name, x: o.x, y: o.y, w: w, h: h }
    }
    return null
  }
  // Move this surface to another monitor, keeping the orb at the same
  // GLOBAL point. A surface cannot straddle two outputs, so the crossing is
  // a cut at the edge -- the orb vanishes on one screen and appears at the
  // matching edge of the next.
  function crossTo(m, gx, gy) {
    var scr = screenNamed(m.name)
    if (!scr) return false
    overlay.screen = scr
    place(gx - m.x, gy - m.y, 0)
    return true
  }
  function fling(vx, vy) { throwVx = vx; throwVy = vy; pinned = true; fly.running = true }
  // The focused window is off limits: a spot inside it is pushed out through
  // the nearest edge. When it is the whole screen, its top-right corner.
  function avoidFocus(p) {
    var f = focusRect()
    if (!f) return p
    // A window that IS the screen leaves nowhere to be pushed to; the orb
    // just roams over it.
    if (f.w * f.h > overlay.sw * overlay.sh * 0.8) return p
    var m = 40
    if (p.x < f.x - m || p.x > f.x + f.w + m || p.y < f.y - m || p.y > f.y + f.h + m) return p
    var d = [p.x - (f.x - m), (f.x + f.w + m) - p.x, p.y - (f.y - m), (f.y + f.h + m) - p.y]
    var k = 0
    for (var i = 1; i < 4; i++) if (d[i] < d[k]) k = i
    var q = { x: p.x, y: p.y }
    if (k === 0) q.x = f.x - m
    else if (k === 1) q.x = f.x + f.w + m
    else if (k === 2) q.y = f.y - m
    else q.y = f.y + f.h + m
    var c = clamp(q.x, q.y)
    if (c.x !== q.x || c.y !== q.y) return { x: f.x + f.w - 70, y: f.y + 70 }
    return q
  }

  // Velocity while it is in the air after a throw, px/s.
  property real throwVx: 0
  property real throwVy: 0

  // PINNED: the user put it here by hand. It stays -- no keeping off the
  // focused window, no wandering -- until it next leaves the pill.
  property bool pinned: false

  // The mic while you talk, the speaker while Ori does (Voice captures the
  // sink monitor for as long as kokoro's stream is up).
  readonly property real level: overlay.voice.level

  // What the session is doing, whether or not this exchange started it: a
  // free orb shows a typed turn's work too.
  readonly property bool sessionWorking: OriClient.working
  readonly property string mode:
      overlay.voice.state === "listening" ? "listening"
    : overlay.voice.state === "speaking" ? "speaking"
    : (OriClient.speaking && overlay.voice.state === "hidden") ? "speaking"
    : overlay.voice.state === "done" ? "done"
    : overlay.voice.state === "transcribing" ? "thinking"
    : overlay.sessionWorking ? "working"
    : OriClient.busy ? "thinking"
    : OriClient.error !== "" ? "failed"
    : "idle"
  // The word under it, and the line under that: the tool's verb, then what
  // it is running -- the same sentence the panel's rail shows.
  readonly property string verb:
      overlay.voice.state === "listening" ? "listening"
    : overlay.voice.state === "speaking" ? "speaking"
    : (OriClient.speaking && overlay.voice.state === "hidden") ? "speaking"
    : overlay.voice.state === "done" ? "done"
    : overlay.voice.state === "transcribing" ? "hearing"
    : overlay.sessionWorking ? OriClient.workTool.split(" ")[0]
    : OriClient.busy ? "thinking"
    : OriClient.error !== "" ? "failed"
    : "here"
  readonly property string detail: {
    if (!overlay.sessionWorking) return ""
    var cut = OriClient.workTool.indexOf(" ")
    return cut < 0 ? "" : OriClient.workTool.substring(cut + 1)
  }

  // ----------------------------------------------------------------- paint
  Item {
    id: stage
    anchors.fill: parent
    opacity: overlay.shown ? 1 : 0
    visible: opacity > 0.001
    Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

    // The orb's own handle. Drag it anywhere (that pins it there); right
    // click sends it home. The only input this surface takes.
    MouseArea {
      id: hoverZone
      x: overlay.lx - width / 2
      y: overlay.ly - height / 2
      width: 120
      height: 120
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
      property real gx: 0
      property real gy: 0
      property bool moved: false
      // The hand's speed over the last few samples, for the throw.
      property real vx: 0
      property real vy: 0
      property real lastT: 0
      onPressed: function (mouse) {
        if (mouse.button !== Qt.LeftButton) return
        fly.running = false
        // Grip offset in SCREEN coordinates, so it survives the surface
        // growing from the small box to the full screen mid-drag.
        gx = hoverZone.x + mouse.x + overlay.winX - overlay.ox
        gy = hoverZone.y + mouse.y + overlay.winY - overlay.oy
        moved = false; vx = 0; vy = 0; lastT = Date.now()
      }
      onPositionChanged: function (mouse) {
        if (!pressed) return
        var nx = hoverZone.x + mouse.x + overlay.winX - gx, ny = hoverZone.y + mouse.y + overlay.winY - gy
        // A click is not a drag: nothing moves until the hand has.
        if (!moved && Math.hypot(nx - overlay.ox, ny - overlay.oy) < 6) return
        var now = Date.now(), dt = Math.max(1, now - lastT)
        // Smoothed px/ms; the newest sample weighs most.
        vx = vx * 0.6 + (nx - overlay.ox) / dt * 0.4
        vy = vy * 0.6 + (ny - overlay.oy) / dt * 0.4
        lastT = now
        var p = overlay.clamp(nx, ny)
        overlay.place(p.x, p.y, 0)
        moved = true
      }
      onReleased: function (mouse) {
        if (mouse.button === Qt.RightButton) {
          // Home: cut whatever it is doing and call it back to the pill.
          if (overlay.voice.state !== "hidden") overlay.voice.cancel()
          OriClient.orbFree = false
          return
        }
        if (!moved) return
        overlay.pinned = true
        // A stale sample (the hand stopped before letting go) is not a throw.
        if (Date.now() - lastT > 80) return
        overlay.throwVx = vx * 1000
        overlay.throwVy = vy * 1000
        if (Math.hypot(overlay.throwVx, overlay.throwVy) > 120) fly.running = true
      }
    }

    // The throw: it keeps the hand's speed, slows on air, and bounces a
    // little off the screen's edges. A frame clock that runs only while it
    // is in the air.
    FrameAnimation {
      id: fly
      running: false
      onTriggered: {
        var dt = Math.min(frameTime, 0.05)
        var x = overlay.ox + overlay.throwVx * dt
        var y = overlay.oy + overlay.throwVy * dt
        // Past an edge with a monitor beyond it: cross over and keep flying.
        if (x < 0 || x > overlay.sw || y < 0 || y > overlay.sh) {
          var o = overlay.monitorOrigin()
          var m = overlay.monitorAt(o.x + x, o.y + y)
          if (m && overlay.screen && m.name !== overlay.screen.name) {
            overlay.crossTo(m, o.x + x, o.y + y)
            return
          }
        }
        var lo = overlay.pad, top = overlay.pad, rx = overlay.sw - overlay.pad, by = overlay.sh - overlay.pad
        if (x < lo) { x = lo; overlay.throwVx = -overlay.throwVx * 0.45 }
        if (x > rx) { x = rx; overlay.throwVx = -overlay.throwVx * 0.45 }
        if (y < top) { y = top; overlay.throwVy = -overlay.throwVy * 0.45 }
        if (y > by) { y = by; overlay.throwVy = -overlay.throwVy * 0.45 }
        var drag = Math.pow(0.42, dt)   // ~58% of the speed gone per second: a hard throw crosses a screen
        overlay.throwVx *= drag
        overlay.throwVy *= drag
        overlay.place(x, y, 0)
        if (Math.hypot(overlay.throwVx, overlay.throwVy) < 25) fly.running = false
      }
    }

    Orb {
      id: orb
      x: overlay.lx - width / 2
      y: overlay.ly - height / 2
      size: 34
      alive: overlay.shown
      breathe: true
      floating: true
      mode: overlay.mode
      level: overlay.level
      // Bigger while listening and speaking, calm while it thinks, small
      // on the way home.
      scale: overlay.voice.state === "listening" ? 1.15
           : overlay.voice.state === "speaking" ? 1.1
           : (overlay.voice.state === "done" && !OriClient.orbFree) ? 0.5
           : !overlay.wantOut ? 0.5 : 1
      Behavior on scale { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
    }

    // A small word under the orb: what it is doing. And under that, while a
    // tool runs, what it is running. Each on a soft crust pill: backing beats
    // an outline on a busy wallpaper, and a 9px hairline outline did not read
    // over the beach photos at all.
    Item {
      id: verbTag
      readonly property bool on: overlay.voice.state !== "done" && overlay.verb !== "here"
      width: verbText.implicitWidth + 26
      height: verbText.implicitHeight + 12
      x: overlay.lx - width / 2
      y: overlay.ly + 58
      opacity: on ? 0.95 : 0
      Behavior on opacity { NumberAnimation { duration: 200 } }

      Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Theme.alpha(Theme.base, 0.75)
      }

      Text {
        id: verbText
        anchors.centerIn: parent
        text: "ori · " + overlay.verb
        color: orb.tint
        font.family: Style.font.family
        font.pixelSize: 11
        font.letterSpacing: 2
        font.capitalization: Font.AllUppercase
        style: Text.Raised
        styleColor: Theme.alpha(Theme.crust, 0.9)
      }
    }
    Item {
      id: detailTag
      width: Math.min(detailText.implicitWidth, 320) + 22
      height: detailText.implicitHeight + 10
      x: overlay.lx - width / 2
      y: verbTag.y + verbTag.height + 5
      visible: overlay.detail !== "" && overlay.voice.state !== "done"
      opacity: visible ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 200 } }

      Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Theme.alpha(Theme.base, 0.75)
      }

      Text {
        id: detailText
        anchors.centerIn: parent
        width: Math.min(implicitWidth, 300)
        text: overlay.detail
        color: Theme.subtext0
        elide: Text.ElideMiddle
        horizontalAlignment: Text.AlignHCenter
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.tiny
        style: Text.Raised
        styleColor: Theme.alpha(Theme.crust, 0.9)
      }
    }

    // What the mic heard, beside the orb on whichever side has room. A
    // mishear is visible the moment it happens: cancel and press again.
    Item {
      id: cap
      readonly property bool toRight: overlay.ox < overlay.sw / 2
      readonly property bool on: overlay.voice.interim !== ""
        && (overlay.voice.state === "working" || overlay.voice.state === "transcribing")
      width: Math.min(420, capText.implicitWidth + 40)
      height: capText.implicitHeight + 20
      x: toRight ? overlay.lx + 66 : overlay.lx - 66 - width
      y: overlay.ly - height / 2
      opacity: on ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 250 } }

      // Hairline from the orb to the words.
      Rectangle {
        x: cap.toRight ? -30 : cap.width + 6
        y: cap.height / 2
        width: 24
        height: 1
        color: orb.tint
        opacity: 0.85
      }

      // A uniform soft backing, not a card: the words need to read over
      // whatever window is under them. The old end-fades let the wallpaper
      // bleed through exactly where the eye lands first.
      Rectangle {
        anchors.fill: parent
        radius: 12
        color: Theme.alpha(Theme.base, 0.6)
      }

      Text {
        id: capText
        anchors { left: parent.left; right: parent.right; margins: 14; verticalCenter: parent.verticalCenter }
        text: overlay.voice.interim
        color: Theme.text
        wrapMode: Text.Wrap
        horizontalAlignment: cap.toRight ? Text.AlignLeft : Text.AlignRight
        font.family: Style.font.panelFamily
        font.pixelSize: Style.font.panelBody
        renderType: Text.QtRendering
      }
    }
  }
}
