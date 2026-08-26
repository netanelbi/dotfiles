import QtQuick
import Quickshell
import Quickshell.Io

// Base for every widget backed by one of the user's existing waybar watcher
// scripts (~/.local/bin/hypr-*-watch, tdp-watch, stay-awake-watch,
// gamepad-watch). Those scripts are event-driven, already correct, and are NOT
// to be reimplemented: this runs one as a long-lived child process, parses the
// waybar JSON it prints line by line, and exposes it as properties.
//
//     ScriptWidget {
//       script: "~/.local/bin/tdp-watch"
//       clickCommand: "..."                 // inherited from BarWidget
//       Text {
//         text: parent.text                 // or `html` for pango markup
//         color: parent.hasClass("active") ? Theme.peach : Theme.inactive
//       }
//     }
//
// Contract
//   script          command to run; a leading `~` is expanded to $HOME and the
//                   script is spawned directly (no `sh -lc` wrapper) through the
//                   `pdeathsig` helper, so it dies when quickshell dies even on
//                   SIGKILL. See the Process block below.
//   text            the JSON's "text" field, raw (may contain pango markup).
//   html            `text` converted to Qt rich text -- use this for the two
//                   scripts that emit pango (hypr-windows-watch, hypr-network-watch)
//                   with `textFormat: Text.RichText`.
//   classes         the JSON's "class", always normalised to an array.
//   hasClass(name)  waybar's CSS-class test, i.e. `#custom-x.active`.
//   tooltip         the JSON's "tooltip" (BarWidget shows it); tooltipHtml for markup.
//   alt, percentage the remaining waybar JSON fields, if a script emits them.
//   payload         the whole parsed object, for anything non-standard.
//   updated(data)   emitted on every accepted line.
//   shown           defaults to "the script is emitting something"; override to
//                   change the collapse rule.
//
// The process is restarted if it dies, the way waybar restarts a `custom/*`
// exec, so a script crash is self-healing.
BarWidget {
  id: root

  property string script: ""
  // Extra environment for the child, if a widget needs it.
  property var scriptEnvironment: ({})
  property int restartDelay: 2000

  property string text: ""
  property var classes: []
  property string alt: ""
  property real percentage: 0
  property var payload: ({})
  readonly property bool running: proc.running

  // The script's own tooltip drives BarWidget's tooltip by default.
  property string scriptTooltip: ""
  tooltip: scriptTooltip

  signal updated(var data)

  // Empty text is how these scripts say "nothing to show" (tdp-watch,
  // gamepad-watch and hypr-scratchpad-watch all emit {"text": "", "class": ""}
  // when idle), so it is the natural collapse condition.
  shown: text !== ""

  function hasClass(name) {
    return classes.indexOf(name) !== -1
  }

  // Expand a leading `~` to $HOME. The scripts are spawned directly (not via
  // `sh -lc`), so the tilde must be resolved here.
  function expandHome(s) {
    if (!s) return s
    if (s === "~") return Quickshell.env("HOME")
    if (s.startsWith("~/")) return Quickshell.env("HOME") + s.slice(1)
    return s
  }

  // ---------------------------------------------------------------- pango
  // waybar renders `text` with pango markup; Qt's Text wants HTML. Only the
  // handful of attributes these scripts actually emit are translated
  // (foreground/color, background, weight, size, style) -- everything else is
  // passed through untouched.
  function pangoToHtml(s) {
    if (!s) return ""
    return String(s).replace(/<span([^>]*)>/g, function (whole, attrs) {
      var style = []
      var rest = attrs.replace(/(\w[\w-]*)\s*=\s*'([^']*)'|(\w[\w-]*)\s*=\s*"([^"]*)"/g,
        function (m, k1, v1, k2, v2) {
          var key = (k1 || k2 || "").toLowerCase()
          var value = k1 !== undefined ? v1 : v2
          switch (key) {
          case "foreground":
          case "color":       style.push("color:" + value); return ""
          case "background":
          case "bgcolor":     style.push("background-color:" + value); return ""
          case "weight":      style.push("font-weight:" + value); return ""
          case "size":        style.push("font-size:" + value); return ""
          case "style":       style.push("font-style:" + value); return ""
          case "underline":   style.push("text-decoration:underline"); return ""
          default:            return m
          }
        }).trim()
      return "<span" + (rest ? " " + rest : "") + (style.length ? " style=\"" + style.join(";") + "\"" : "") + ">"
    })
  }

  readonly property string html: pangoToHtml(text)
  readonly property string tooltipHtml: pangoToHtml(scriptTooltip)

  // --------------------------------------------------------------- process
  function ingest(line) {
    var raw = String(line || "").trim()
    if (raw === "") return

    var data
    try {
      data = JSON.parse(raw)
    } catch (e) {
      // A script that prints a bare string still works, exactly as waybar's
      // return-type: "" modules do.
      data = { text: raw }
    }
    if (data === null || typeof data !== "object") data = { text: String(data) }

    root.payload = data
    root.text = data.text === undefined || data.text === null ? "" : String(data.text)
    root.scriptTooltip = data.tooltip === undefined || data.tooltip === null ? "" : String(data.tooltip)
    root.alt = data.alt === undefined || data.alt === null ? "" : String(data.alt)
    root.percentage = Number(data.percentage) || 0

    var cls = data.class
    if (cls === undefined || cls === null || cls === "") root.classes = []
    else if (Array.isArray(cls)) root.classes = cls
    else root.classes = [String(cls)]

    root.updated(data)
  }

  // Spawn the script directly through `pdeathsig` (NOT `sh -lc`). Two reasons:
  //   1. A direct child means the script's parent is quickshell, so pdeathsig's
  //      PR_SET_PDEATHSIG fires when quickshell dies -- even on SIGKILL, which
  //      never signals the child. Under `sh -lc` the script's parent was the sh
  //      wrapper, which stayed alive orphaned when quickshell died, so the
  //      script (and its own child: inotifywait/socat/evtest/gdbus) leaked and
  //      kept its inotify watch / socket forever. That is what exhausted the
  //      inotify slots.
  //   2. `~` is expanded here (expandHome) instead of by sh.
  //   pdeathsig is addressed by absolute path: quickshell's Process PATH does
  //   not include ~/.local/bin (the old `sh -lc` sourced the login profile for
  //   it), so a bare name would fail to resolve.
  Process {
    id: proc
    running: root.script !== ""
    command: [Quickshell.env("HOME") + "/.local/bin/pdeathsig", root.expandHome(root.script)]
    environment: root.scriptEnvironment
    stdout: SplitParser { onRead: function (line) { root.ingest(line) } }
    onExited: function (exitCode, exitStatus) {
      if (root.script !== "") restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: root.restartDelay
    repeat: false
    onTriggered: if (root.script !== "" && !proc.running) proc.running = true
  }

  // Force a fresh run (e.g. after resume, or from IPC).
  function restart() {
    proc.running = false
    restartTimer.restart()
  }
}
