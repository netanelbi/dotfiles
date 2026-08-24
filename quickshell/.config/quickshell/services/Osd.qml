import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
// `root:/` is the config directory -- the same form widgets/*.qml use. Theme
// and Style are singletons there; OsdWindow is a plain sibling in this folder
// and resolves implicitly.
import "root:/"

// The on-screen display -- replaces swayosd-server / swayosd-client.
//
// Reference, measured live off the running swayosd 0.3.2 on this machine
// (`hyprctl layers` for geometry, `grim` + pixel probe for colour), NOT read
// off the stylesheet alone. That distinction matters: swayosd/style.css carries
// `window.volume`/`window.brightness` rules that recolour the border and the
// progress fill blue/yellow, and swayosd 0.3.2 NEVER SETS THOSE CLASSES. The
// running OSD is mauve-bordered with a @text fill for volume AND for
// brightness. Parity here means matching what is on screen, so those two
// stylesheet blocks are deliberately not reproduced.
//
// Measured, in logical pixels on a 1280x800 (1920x1200 @ scale 1.5) output:
//
//   surface            343 x 80, layer 3 (overlay), horizontally centred
//   vertical position  bottom edge at y=680, i.e. bottom margin 120 =
//                      screen_h * (1 - top_margin), top_margin defaulting to 0.85
//   window             background @base, border 2px @mauve, border-radius 10px
//                      (style.css `window {}`, confirmed unmodified on screen)
//   icon               @mauve, ink centred on x=48
//   progressbar        x 86..261 (176 wide -- style.css min-width 175), 6px tall,
//                      trough @surface0, fill @text
//   muted              the whole progressbar drops to 50% opacity: the sampled
//                      fill (117,122,145) is exactly 0.5*@text over 0.5*@base,
//                      and the trough (39,40,57) is 0.5*@surface0 over @base.
//                      The icon stays full-strength @mauve.
//   label              @text, bold, min-width 38, centred in its box, which
//                      leaves the visible trailing gap after "45%"
//   timeout            1000 ms (swayosd's default; config.toml sets no duration)
//   steps              volume +/-5 points, brightness +/-5% of max -- both
//                      verified by driving swayosd-client and reading back
//                      `pamixer --get-volume` / `brightnessctl -m`
//   config.toml        show_percentage = true  -> the percentage label exists
//                      max_volume = 100        -> raise clamps at 100
//
// Icons are Nerd Font glyphs rather than the freedesktop icon-theme names
// swayosd asks GTK for. Same subjects (speaker ramp, muted speaker, sun, muted
// mic), same @mauve, and it keeps the OSD in the same typeface as the bar --
// which is what style.css's `* { font-family: JetBrainsMono Nerd Font }` was
// reaching for anyway.
//
// IPC -- the swayosd-client verbs, so hyprland.lua's binds map across 1:1:
//
//   qs ipc call osd outputVolume raise|lower|mute-toggle|mute|unmute|<n>|+<n>|-<n>
//   qs ipc call osd inputVolume  <same>
//   qs ipc call osd brightness   raise|lower|<n>|+<n>|-<n>
//
//   hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("qs ipc call osd brightness raise"),   { repeating = true })
//   hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("qs ipc call osd brightness lower"),   { repeating = true })
//   hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("qs ipc call osd outputVolume raise"), { repeating = true })
//   hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd("qs ipc call osd outputVolume lower"), { repeating = true })
//   hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("qs ipc call osd outputVolume mute-toggle"))
//   hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("qs ipc call osd inputVolume mute-toggle"))
//
// (This file does not edit hyprland.lua. Until those lines are swapped in, the
// keys still go to swayosd-client and the Quickshell OSD is reached over IPC or
// by any volume change PipeWire reports -- see `armed` below.)
Scope {
  id: root

  // ----------------------------------------------------------------- state
  // "volume" | "brightness" | "mic" -- which reading is on screen.
  property string kind: "volume"
  property int level: 0
  // Muted: progressbar at half strength, icon unchanged.
  property bool dimmed: false
  property string glyph: ""
  property bool open: false

  readonly property int volumeStep: 5
  readonly property int brightnessStep: 5
  // config.toml: max_volume = 100
  readonly property int maxVolume: 100
  readonly property int timeout: 1000

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  // ------------------------------------------------------------- pipewire
  PwObjectTracker {
    objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource]
  }

  readonly property PwNode sink: Pipewire.defaultAudioSink
  readonly property var sinkAudio: sink && sink.audio ? sink.audio : null
  readonly property int sinkVolume: sinkAudio ? Math.round(sinkAudio.volume * 100) : 0
  readonly property bool sinkMuted: sinkAudio ? sinkAudio.muted : false

  readonly property PwNode source: Pipewire.defaultAudioSource
  readonly property var sourceAudio: source && source.audio ? source.audio : null
  readonly property int sourceVolume: sourceAudio ? Math.round(sourceAudio.volume * 100) : 0
  readonly property bool sourceMuted: sourceAudio ? sourceAudio.muted : false

  // swayosd only ever pops on an explicit client call. This shell also opens
  // the OSD for a volume change from ANY source -- a scroll on the bar's own
  // audio widget, wiremix, a browser, a Bluetooth headset's own buttons.
  //
  // `armed` is what keeps that from firing on noise. PipeWire hands over a
  // node's volume a beat after the node itself, so an unguarded binding shows
  // an OSD at login and again every time the default sink is replaced (dock,
  // headset connect). The guard disarms on any sink/source identity change and
  // re-arms once the new node's values have settled.
  property bool armed: false

  Timer {
    id: armTimer
    interval: 600
    onTriggered: root.armed = true
  }

  function disarm() {
    root.armed = false
    armTimer.restart()
  }

  Component.onCompleted: armTimer.restart()

  onSinkChanged: disarm()
  onSourceChanged: disarm()

  onSinkVolumeChanged: if (armed) present("volume")
  onSinkMutedChanged: if (armed) present("volume")
  // Source *volume* deliberately does not trigger: an app nudging mic gain is
  // not something swayosd surfaces, and it would fire while recording. Mute is
  // a state you must be told about, so it does.
  onSourceMutedChanged: if (armed) present("mic")

  // ----------------------------------------------------------- brightness
  // swayosd ships a setuid/polkit helper for this. There is no sudo on this
  // machine and none is needed: /sys/class/backlight/amdgpu_bl1/brightness is
  // 0664 root:video and the user is in `video`, so plain brightnessctl writes
  // it directly (verified: `brightnessctl set 5%-` moved the panel).
  //
  // The DISPLAYED level is read off the device, never off a cache of our own
  // writes. swayosd's helper re-reads sysfs on every step, so it cannot show a
  // level that something else moved behind its back -- `brightnessctl` from a
  // shell, or the swayosd-client binds that still own the keys until
  // hyprland.lua is repointed. A FileView on the backlight's `brightness`
  // attribute buys the same guarantee: kernfs raises inotify on writes to it,
  // measured on this panel at ~2 ms from write to reload. As a side effect
  // brightness now pops the OSD for a change from any source, which is what
  // volume already does and what swayosd does for neither.
  property string brightnessPath: ""
  property int brightnessMax: 0
  property int brightnessPercent: -1
  readonly property bool brightnessAvailable: brightnessPercent >= 0
  // Steps issued but not yet acknowledged by the device. While this is non-zero
  // (or a write is in flight) the displayed value is the optimistic one, so a
  // held key moves the bar at key-repeat rate instead of at process-spawn rate.
  property int pendingStep: 0

  FileView {
    id: brightnessFile
    path: root.brightnessPath
    watchChanges: path !== ""
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.ingestRaw(text())
  }

  // Raw sysfs value -> percent. Skipped while our own steps are in flight,
  // where the optimistic reading is the truer one; kernfs also notifies twice
  // per write, hence the no-change early out.
  function ingestRaw(raw) {
    if (brightnessMax <= 0) return
    var v = parseInt(String(raw).trim())
    if (isNaN(v)) return
    if (pendingStep !== 0 || brightnessProc.running) return
    var pct = clamp(Math.round(v * 100 / brightnessMax), 0, 100)
    if (pct === brightnessPercent) return
    var first = brightnessPercent < 0
    brightnessPercent = pct
    // The very first read is the startup sync, not an event to announce.
    if (!first && armed) present("brightness")
  }

  function stepBrightness(delta) {
    if (!brightnessAvailable) return false
    brightnessPercent = clamp(brightnessPercent + delta, 0, 100)
    pendingStep += delta
    pumpBrightness()
    present("brightness")
    return true
  }

  function setBrightness(percent) {
    if (!brightnessAvailable) return false
    var target = clamp(Math.round(percent), 0, 100)
    return stepBrightness(target - brightnessPercent)
  }

  function pumpBrightness() {
    if (brightnessProc.running || pendingStep === 0) return
    var d = pendingStep
    pendingStep = 0
    brightnessProc.command = ["brightnessctl", "-m", "set",
                              d > 0 ? d + "%+" : (-d) + "%-"]
    brightnessProc.running = true
  }

  // `brightnessctl -m` prints "device,class,value,NN%,max" on one line, for a
  // bare query and for a set alike. Only the device identity and its raw scale
  // are taken from it -- the level itself comes from the FileView above.
  function ingestDevice(text) {
    var f = String(text).trim().split("\n")[0].split(",")
    if (f.length < 5) return
    var max = parseInt(f[4])
    if (isNaN(max) || max <= 0) return
    root.brightnessMax = max
    root.brightnessPath = "/sys/class/" + f[1] + "/" + f[0] + "/brightness"
  }

  Process {
    id: brightnessProc
    // One shot at startup to learn which device brightnessctl drives; after
    // that the same process object carries the set commands.
    running: true
    command: ["brightnessctl", "-m"]
    stdout: StdioCollector { onStreamFinished: root.ingestDevice(text) }
    onExited: function (code) {
      if (code !== 0 && root.brightnessPath === "")
        console.warn("Osd: brightnessctl failed (" + code + "); brightness OSD disabled")
      root.pumpBrightness()
      // Our own write's inotify hit arrived while `running` was still true and
      // was skipped, so re-read once the burst has drained to land back on the
      // device's own number.
      if (root.pendingStep === 0) brightnessFile.reload()
    }
  }

  // ------------------------------------------------------------- audio ops
  function applyVolume(audio, action, isSink) {
    if (!audio) return "no device"
    var current = Math.round(audio.volume * 100)
    if (action === "mute-toggle") audio.muted = !audio.muted
    else if (action === "mute") audio.muted = true
    else if (action === "unmute") audio.muted = false
    else if (action === "raise") audio.volume = clamp(current + volumeStep, 0, maxVolume) / 100
    else if (action === "lower") audio.volume = clamp(current - volumeStep, 0, maxVolume) / 100
    else {
      // swayosd-client also takes a bare number or a signed delta.
      var n = parseInt(action)
      if (isNaN(n)) return "bad action: " + action
      var target = (action[0] === "+" || action[0] === "-") ? current + n : n
      audio.volume = clamp(target, 0, maxVolume) / 100
    }
    // A volume/mute write lands on the bindings above, which present() the OSD
    // themselves -- but only while armed, and an explicit request must show
    // regardless. Presenting here too is idempotent: it is the same kind, and
    // present() only restarts the timer.
    present(isSink ? "volume" : "mic")
    return "ok"
  }

  // ------------------------------------------------------------- presenting
  function present(which) {
    root.kind = which
    if (which === "volume") {
      root.level = sinkVolume
      root.dimmed = sinkMuted
      root.glyph = sinkMuted ? "󰖁"
          : ["󰕿", "󰖀", "󰕾"][clamp(Math.floor(sinkVolume / 33), 0, 2)]
    } else if (which === "mic") {
      root.level = sourceVolume
      root.dimmed = sourceMuted
      root.glyph = sourceMuted ? "󰍭" : "󰍬"
    } else {
      root.level = Math.max(0, brightnessPercent)
      root.dimmed = false
      // display-brightness-symbolic, which swayosd uses at every level.
      root.glyph = "󰃠"
    }
    root.open = true
    hideTimer.restart()
  }

  Timer {
    id: hideTimer
    interval: root.timeout
    onTriggered: root.open = false
  }

  // ------------------------------------------------------------------- ipc
  IpcHandler {
    target: "osd"

    // raise | lower | mute-toggle | mute | unmute | <n> | +<n> | -<n>
    function outputVolume(action: string): string {
      return root.applyVolume(root.sinkAudio, action === "" ? "raise" : action, true)
    }

    function inputVolume(action: string): string {
      return root.applyVolume(root.sourceAudio, action === "" ? "raise" : action, false)
    }

    // raise | lower | <n> | +<n> | -<n>
    function brightness(action: string): string {
      if (!root.brightnessAvailable) return "brightness unavailable"
      var a = action === "" ? "raise" : action
      if (a === "raise") return root.stepBrightness(root.brightnessStep) ? "ok" : "failed"
      if (a === "lower") return root.stepBrightness(-root.brightnessStep) ? "ok" : "failed"
      var n = parseInt(a)
      if (isNaN(n)) return "bad action: " + a
      var ok = (a[0] === "+" || a[0] === "-") ? root.stepBrightness(n) : root.setBrightness(n)
      return ok ? "ok" : "failed"
    }

    // Current reading, for scripting/debug.
    function status(): string {
      return root.kind + " " + root.level + (root.dimmed ? " muted" : "")
    }
  }

  // ---------------------------------------------------------------- surface
  // swayosd renders on every output, so this does too.
  Variants {
    model: Quickshell.screens
    delegate: OsdWindow { controller: root }
  }
}
