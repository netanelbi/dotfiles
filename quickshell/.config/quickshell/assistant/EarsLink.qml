import QtQuick
import Quickshell
import Quickshell.Io

// The orb's link to the ears daemon (~/Development/Personal/ori-voice/ears),
// the hands-free call engine that replaced push-to-talk on right Alt.
//
// Ears publishes Server-Sent Events on 127.0.0.1:<port>/events (port in
// $XDG_RUNTIME_DIR/ori-voice.port, default 8770). This reads them with
// `curl -sN` through a SplitParser -- the daemon pushes, nothing polls.
// When the stream ends (daemon stopped or restarted) curl exits and the link
// reconnects after a short backoff; a rewritten port file reconnects at once.
//
// It speaks Voice.qml's vocabulary (state / level / interim / cancel()) so the
// overlay can take it in place of the PTT exchange: Voice.qml hands the orb to
// this while a call is open (`owns`) and back to the PTT code otherwise.
//
//   call closed / no daemon -> hidden
//   listening, ignored      -> listening, level 0
//   hearing                 -> listening, level = mic over the noise floor
//   thinking                -> thinking (the heard turn shows beside the orb)
//   speaking                -> speaking, level = the speaker (speakLevel)
Scope {
  id: link

  // The speaker's level while Ori talks: Voice.qml's sink-monitor capture,
  // which follows the same kokoro stream ears plays through.
  property real speakLevel: 0

  // ------------------------------------------------------------ published
  // Stream up and at least one event read since it connected.
  property bool linked: false
  property bool call: false
  // The daemon's meter mode: listening|hearing|thinking|speaking|ignored|closed
  property string mode: "closed"
  // Mic level over the noise floor, 0..1 (the same scale ears' own ui.html uses).
  property real micLevel: 0
  // The last turn heard; shown beside the orb while it thinks.
  property string interim: ""

  readonly property bool owns: linked && call
  readonly property string state:
      !owns ? "hidden"
    : mode === "speaking" ? "speaking"
    : mode === "thinking" ? "thinking"
    : mode === "closed" ? "hidden"
    : "listening"
  readonly property real level:
      state === "speaking" ? speakLevel
    : (state === "listening" && mode === "hearing") ? micLevel
    : 0

  // Right-click on the orb ("home: cut whatever it is doing") hangs up.
  function cancel() { run(["close"]) }
  function toggle() { run(["toggle"]) }

  readonly property string callCli: Quickshell.env("HOME") + "/Development/Personal/ori-voice/ears/ori-call"
  function run(args) {
    cli.command = [link.callCli].concat(args)
    cli.exec(cli.command)
  }
  Process { id: cli }

  // ------------------------------------------------------------ stream
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"

  // The control room reads the SAME stream: every event is handed to
  // EarsModel too, so the panel never opens a second connection. The stream
  // is asked for its recent history (?replay=1) so the panel's transcript
  // survives a shell reload; replayed events (stamped before this connection
  // opened) only reach EarsModel -- the orb must not act out a call that is
  // already over.
  property real connectedAt: 0
  property bool fresh: false

  function handle(ev) {
    if (!ev || typeof ev !== "object") return
    if (link.fresh) { link.fresh = false; EarsModel.clearSession() }
    var history = ev.ts !== undefined && Number(ev.ts) < link.connectedAt - 1500
    EarsModel.ingest(ev, history)
    link.linked = true
    backoff.interval = 1000
    if (history) return
    var t = ev.t
    if (t === "meter") {
      var m = String(ev.mode || "")
      if (m !== "") {
        if (m === "hearing" && link.mode !== "hearing") link.interim = ""
        link.mode = m
        if (m === "closed") link.call = false
        else link.call = true
      }
      // ~15/s from the daemon: only a visible change is written, so the orb's
      // bindings re-run on real movement, not on every packet.
      var lvl = Number(ev.level), floor = ev.floor !== undefined ? Number(ev.floor) : -60
      var v = isNaN(lvl) ? 0 : Math.max(0, Math.min(1, (lvl - floor) / 35))
      if (link.mode !== "hearing") v = 0
      if (Math.abs(v - link.micLevel) >= 0.03 || (v === 0 && link.micLevel !== 0))
        link.micLevel = v
    } else if (t === "state") {
      if (ev.call !== undefined) {
        link.call = ev.call === true
        if (!link.call) { link.mode = "closed"; link.interim = ""; link.micLevel = 0 }
      }
    } else if (t === "turn") {
      if (ev.text !== undefined) link.interim = String(ev.text)
    }
  }

  function reset() {
    link.linked = false
    link.call = false
    link.mode = "closed"
    link.micLevel = 0
    link.interim = ""
  }

  Process {
    id: feed
    // The port is read per connection, so a daemon that came back on another
    // port is found on the next attempt.
    command: ["sh", "-c",
      "p=$(cat \"$0\" 2>/dev/null); exec curl -sN --no-buffer \"http://127.0.0.1:${p:-8770}/events?replay=1\"",
      EarsModel.portFile]
    stdout: SplitParser {
      // Split on the SSE event separator; a chunk may still carry stray
      // newlines (measured: each one arrived as "\ndata: {...}"), so every
      // line inside it is looked at.
      splitMarker: "\n\n"
      onRead: function (chunk) {
        var lines = String(chunk).split("\n")
        for (var i = 0; i < lines.length; i++) {
          var s = lines[i].trim()
          if (s.indexOf("data:") !== 0) continue   // blank lines and ": ping"
          try { link.handle(JSON.parse(s.substring(5))) } catch (e) { }
        }
      }
    }
    onExited: {
      link.reset()
      EarsModel.disconnected()
      backoff.restart()
    }
  }

  // Reconnect after the stream ends: 1 s, doubling to 10 s while the daemon is
  // away, back to 1 s as soon as an event arrives. Not a poll -- it only runs
  // after curl has exited.
  Timer {
    id: backoff
    interval: 1000
    onTriggered: {
      link.connect()
      backoff.interval = Math.min(10000, backoff.interval * 2)
    }
  }

  // A (re)started daemon rewrites its port file: reconnect now rather than
  // wait out the backoff.
  FileView {
    path: EarsModel.portFile
    watchChanges: true
    printErrors: false
    onFileChanged: {
      reload()
      if (!link.linked) { backoff.interval = 300; backoff.restart() }
    }
  }

  function connect() {
    link.connectedAt = Date.now()
    link.fresh = true
    feed.exec(feed.command)
  }

  Component.onCompleted: link.connect()

  function describe() {
    return "linked=" + link.linked + " call=" + link.call + " mode=" + link.mode
      + " state=" + link.state + " level=" + link.level.toFixed(2)
      + " running=" + feed.running
  }
}
