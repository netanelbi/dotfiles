import QtQuick
import Quickshell
import Quickshell.Io

// The engine's own IPC surface, so both new capabilities -- attaching an image
// to a question, and resuming a past conversation -- are drivable with no
// window on screen. That is not a convenience: a panel is not a thing a test
// can read, so anything only reachable through one is untestable.
//
// It is a SEPARATE target from `assistant`, for two reasons. That one is the
// panel's mount point (assistant/Assistant.qml) and is the stable script
// surface -- ask / answer / status -- which nothing here disturbs. And this one
// has to live out here at all: an IpcHandler declared inside the PiSession
// singleton is constructed but never registered (it does not appear in
// `qs ipc show`), because handlers are collected from the reload tree hanging
// off ShellRoot, which a singleton is not part of. Hence a Scope, and one line
// in shell.qml -- the same reason Launchers{} exists.
//
//   qs -p ~/.config/quickshell ipc call ori image "what is this?" /tmp/shot.png
//   qs -p ~/.config/quickshell ipc call ori sessions
//   qs -p ~/.config/quickshell ipc call ori resume 01a03a7c
Scope {
  IpcHandler {
    target: "ori"

    // ask() with attachments. `paths` is newline- or comma-separated, so one
    // call can carry several.
    function image(question: string, paths: string): string {
      var list = String(paths || "").split(/[\n,]/)
      var clean = []
      for (var i = 0; i < list.length; i++)
        if (list[i].trim() !== "") clean.push(list[i].trim())
      if (!PiSession.ask(question, clean))
        return PiSession.busy ? "busy" : "refused"
      return PiSession.imageError !== ""
        ? "asked (" + PiSession.imageError + ")"
        : "asked with " + clean.length + " image(s)"
    }

    // The listing Ctrl+R is a view of, one per line: id, when, message count,
    // and the opening question as the name.
    function sessions(): string {
      var s = PiSession.sessions
      if (s.length === 0) return "(no saved sessions)"
      var out = []
      for (var i = 0; i < s.length; i++) {
        // 13 chars, not 8: these are uuidv7s whose leading bytes are the
        // millisecond clock, so two conversations minutes apart share the
        // first eight and the prefix lookup would be ambiguous.
        out.push(String(s[i].id).substring(0, 13)
               + "  " + Qt.formatDateTime(new Date(s[i].at), "yyyy-MM-dd HH:mm")
               + "  " + String(s[i].count) + " msg"
               + (s[i].id === PiSession.sessionId ? "  *  " : "     ")
               + s[i].label)
      }
      return out.join("\n")
    }

    function sessionsJson(): string {
      return JSON.stringify(PiSession.sessions)
    }

    function resume(id: string): string {
      if (!PiSession.resume(id)) return "error: " + PiSession.error
      return "resuming " + id + (PiSession.warm ? " (warm)" : " (cold start)")
    }

    // What the engine currently is, in one line -- the thing to read after a
    // resume to see whether it landed.
    function state(): string {
      return "warm=" + PiSession.warm
           + " busy=" + PiSession.busy
           + " turns=" + PiSession.turns.count
           + " session=" + (PiSession.sessionId === "" ? "-" : PiSession.sessionId)
           + " tokens=" + PiSession.usageTotal
           + (PiSession.error === "" ? "" : " error=\"" + PiSession.error + "\"")
    }

    // The transcript list's live scroll geometry: what the view thinks the
    // content is, where it sits, and what the delegates themselves occupy.
    // The point of the per-child walk is to catch a LYING contentHeight --
    // the difference between it and the true delegate extent is exactly the
    // blank a scroll can wander into.
    function scroll(): string {
      var l = ScrollProbe.list
      if (!l) return "no transcript registered"
      var out = ["contentY=" + l.contentY.toFixed(1)
        + " height=" + l.height.toFixed(1)
        + " contentHeight=" + l.contentHeight.toFixed(1)
        + " count=" + l.count
        + " stuck=" + l.stuck
        + " yPos=" + l.visibleArea.yPosition.toFixed(3)
        + " hRatio=" + l.visibleArea.heightRatio.toFixed(3)]
      var kids = l.contentItem.children
      // Seeded from the FIRST measured child rather than from 0, because this
      // list is BottomToTop: its delegates sit at NEGATIVE y. Bounds seeded at
      // 0 therefore pin `hi` to at least 0, which overstates the extent by the
      // whole distance from the newest delegate up to the origin -- and an
      // overstated extent understates `ghost`, which is the one number this
      // probe exists to report.
      var lo = NaN, hi = NaN
      for (var i = 0; i < kids.length; i++) {
        var c = kids[i]
        if (!c.height || c.height === undefined) continue
        lo = isNaN(lo) ? c.y : Math.min(lo, c.y)
        hi = isNaN(hi) ? c.y + c.height : Math.max(hi, c.y + c.height)
        out.push("  [" + i + "] y=" + c.y.toFixed(1) + " h=" + c.height.toFixed(1)
          + "  " + String(c.objectName || "").substring(0, 40))
      }
      if (isNaN(lo)) {
        out.push("  extent=none  (no measured delegates)")
        return out.join("\n")
      }
      out.push("  extent=" + (hi - lo).toFixed(1)
        + "  ghost=" + (l.contentHeight - (hi - lo)).toFixed(1))
      return out.join("\n")
    }

    // The turn model as text, which is the only way to see from a script that a
    // resume actually repopulated it.
    function transcript(): string {
      var out = []
      for (var i = 0; i < PiSession.turns.count; i++) {
        var r = PiSession.turns.get(i)
        var line = "[" + i + "] " + r.role + ": " + String(r.text).replace(/\s+/g, " ")
        if (String(r.images) !== "") line += "  {img: " + String(r.images).replace(/\n/g, ", ") + "}"
        out.push(line)
      }
      return out.length === 0 ? "(empty)" : out.join("\n")
    }

    // Kill the child without touching the transcript, which is how "the shell
    // restarted" is reproduced on demand. The next ask() re-attaches to the
    // session file, exactly as it would after an idle kill.
    function restart(): string {
      PiSession.dropChild()
      return "child stopped"
    }
  }
}
