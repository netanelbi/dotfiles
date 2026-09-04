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
      var kids = l.contentItem.children
      var out = ["contentY=" + l.contentY.toFixed(1)
        + " height=" + l.height.toFixed(1)
        + " contentHeight=" + l.contentHeight.toFixed(1)
        + " count=" + l.count
        + " stuck=" + l.stuck
        + " yPos=" + l.visibleArea.yPosition.toFixed(3)
        + " hRatio=" + l.visibleArea.heightRatio.toFixed(3),
        "cacheBuffer=" + l.cacheBuffer
        + " children=" + kids.length
        + " avgBuilt=" + (l.count > 0 ? (l.contentHeight / l.count).toFixed(1) : "-"),
        // originY is the REAL floor. clampScrollY assumes it is 0 and clamps to
        // -contentHeight instead, which is only the same thing while nothing has
        // been prepended -- and a BottomToTop list prepends on every append.
        "originY=" + l.originY.toFixed(1)
        + "  realRange=[" + l.originY.toFixed(1) + " .. "
        + (l.originY + l.contentHeight - l.height).toFixed(1) + "]"
        + "  assumedRange=[" + (-l.contentHeight).toFixed(1)
        + " .. " + (-l.height).toFixed(1) + "]"]
      // Seeded from the FIRST measured child rather than from 0, because this
      // list is BottomToTop: its delegates sit at NEGATIVE y. Bounds seeded at
      // 0 therefore pin `hi` to at least 0, which overstates the extent by the
      // whole distance from the newest delegate up to the origin -- and an
      // overstated extent understates `ghost`, which is the one number this
      // probe exists to report.
      var lo = NaN, hi = NaN
      for (var i = 0; i < kids.length; i++) {
        var c = kids[i]
        // Zero-height children are LISTED, not skipped. A delegate that built
        // but measured 0 is exactly the shape of a blank gap, and skipping it
        // hid it from the one report meant to find it.
        if (c.height === undefined) continue
        if (c.height === 0) { out.push("  [" + i + "] y=" + c.y.toFixed(1) + " h=0  ZERO"); continue }
        lo = isNaN(lo) ? c.y : Math.min(lo, c.y)
        hi = isNaN(hi) ? c.y + c.height : Math.max(hi, c.y + c.height)
        out.push("  [" + i + "] y=" + c.y.toFixed(1) + " h=" + c.height.toFixed(1)
          + "  " + String(c.objectName || "").substring(0, 40))
      }
      if (isNaN(lo)) {
        out.push("  extent=none  (no measured delegates)")
        return out.join("\n")
      }
      // The delegate edges, raw. `yPos`/`visibleArea` must NOT be asserted on:
      // it is a CACHED value refreshed by updateVisible(), not computed on
      // read, so in one atomic sample it can be stale against the contentY and
      // originY printed beside it. Measured reporting 0.985 -- exactly
      // 1-hRatio, i.e. "at the end" -- while contentY was 918.6px short of the
      // real end. It fails clean AND dirty, so a check on it gives false passes
      // and false alarms with no way to tell them apart.
      //
      // firstEnd/lastEnd are read straight off the built delegates, so "is the
      // view at the bottom" can be asked without trusting contentHeight,
      // originY or the cache: contentY + height >= lastEnd - slack.
      out.push("  firstY=" + lo.toFixed(1) + "  lastEnd=" + hi.toFixed(1)
        + "  extent=" + (hi - lo).toFixed(1)
        + "  ghost=" + (l.contentHeight - (hi - lo)).toFixed(1))

      // IS THE VIEWPORT ACTUALLY COVERED BY BUILT DELEGATES.
      //
      // This is the check that survives when the others do not. Bounds
      // assertions trust contentHeight and originY; both can be wrong at once,
      // and then a view parked legally still shows blank -- measured, a range
      // ending 936.6px past the last delegate with every bound satisfied. This
      // asks the question in the units the user experiences instead: how much
      // of what you are looking at has nothing drawn in it.
      //
      // Intervals are MERGED first because contentItem.children mixes
      // positioned and pooled items, so they overlap and repeat; summing them
      // naively over-reports coverage.
      //
      // `gap` is the number to judge, not `uncovered`. The list has 12px of
      // spacing between rows, so a viewport spanning several turns is legally
      // uncovered by a few tens of pixels. One CONTIGUOUS run much larger than
      // that is a blank band, which is the bug.
      var iv = []
      for (var j = 0; j < kids.length; j++) {
        var k = kids[j]
        if (!k.height || k.height <= 0) continue
        iv.push([k.y, k.y + k.height])
      }
      iv.sort(function (a, b) { return a[0] - b[0] })
      var merged = []
      for (var m = 0; m < iv.length; m++) {
        if (merged.length > 0 && iv[m][0] <= merged[merged.length - 1][1])
          merged[merged.length - 1][1] = Math.max(merged[merged.length - 1][1], iv[m][1])
        else merged.push([iv[m][0], iv[m][1]])
      }
      var vTop = l.contentY, vBot = l.contentY + l.height
      var covered = 0, biggest = 0, cursor = vTop
      for (var p = 0; p < merged.length; p++) {
        var s = Math.max(merged[p][0], vTop), e = Math.min(merged[p][1], vBot)
        if (e <= s) continue
        if (s > cursor) biggest = Math.max(biggest, s - cursor)
        covered += e - s
        cursor = Math.max(cursor, e)
      }
      if (cursor < vBot) biggest = Math.max(biggest, vBot - cursor)
      out.push("  viewport=[" + vTop.toFixed(1) + " .. " + vBot.toFixed(1) + "]"
        + "  uncovered=" + (l.height - covered).toFixed(1)
        + "  gap=" + biggest.toFixed(1))
      return out.join("\n")
    }

    // TEMPORARY, for the scroll hunt: drive the transcript's own wheel handlers
    // from a script. The reported bug is a MOUSE one, and a mouse is the one
    // input a test cannot supply -- so the notch path is called directly,
    // exactly as the wheel face calls it, and `scroll` is read either side.
    function wheel(notches: string): string {
      var l = ScrollProbe.list
      if (!l) return "no transcript registered"
      l.wheelNotches(Number(notches))
      return "wheeled " + notches
    }

    function wheelPx(dy: string): string {
      var l = ScrollProbe.list
      if (!l) return "no transcript registered"
      l.wheelPixels(Number(dy))
      return "wheeled " + dy + "px"
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
