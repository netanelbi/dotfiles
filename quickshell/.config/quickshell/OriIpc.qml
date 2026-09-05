import QtQuick
import Quickshell
import Quickshell.Io
import "assistant"

// The client's own IPC surface, so resuming a past conversation and reading
// back what the panel holds are drivable with no window on screen. That is not
// a convenience: a panel is not a thing a test can read, so anything only
// reachable through one is untestable.
//
// It is a SEPARATE target from `assistant`, for two reasons. That one is the
// panel's mount point (assistant/Assistant.qml) and is the stable script
// surface -- ask / answer / status -- which nothing here disturbs. And this one
// has to live out here at all: an IpcHandler declared inside the OriClient
// singleton is constructed but never registered (it does not appear in
// `qs ipc show`), because handlers are collected from the reload tree hanging
// off ShellRoot, which a singleton is not part of. Hence a Scope, and one line
// in shell.qml -- the same reason Launchers{} exists.
//
//   qs -p ~/.config/quickshell ipc call ori sessions
//   qs -p ~/.config/quickshell ipc call ori resume 01a03a7c
Scope {
  IpcHandler {
    target: "ori"

    // NO `image` FUNCTION any more, and it is not an oversight. It used to hand
    // ask() a list of file paths. The protocol's `ask.images` is a list of
    // MARKER INDICES handed out by an `attached` event, and the only thing that
    // produces one is `attach_clipboard`, which captures from the Wayland
    // clipboard -- there is no attach-by-path command in ClientCmd at all.
    // Passing paths would send indices the host cannot resolve. Adding the
    // capability is a host change; faking it here is exactly the local
    // state-keeping this rewrite removed.

    // The listing Ctrl+R is a view of, one per line: id, when, turn count, and
    // the opening question as the name.
    function sessions(): string {
      var s = OriClient.sessions
      if (s.length === 0) return "(no saved sessions)"
      var out = []
      for (var i = 0; i < s.length; i++) {
        // 13 chars, not 8: these are uuidv7s whose leading bytes are the
        // millisecond clock, so two conversations minutes apart share the
        // first eight and the prefix lookup would be ambiguous.
        out.push(String(s[i].id).substring(0, 13)
               + "  " + Qt.formatDateTime(new Date(s[i].at), "yyyy-MM-dd HH:mm")
               + "  " + String(s[i].turns) + " msg"
               + (s[i].id === OriClient.sessionId ? "  *  " : "     ")
               + s[i].label)
      }
      return out.join("\n")
    }

    function sessionsJson(): string {
      return JSON.stringify(OriClient.sessions)
    }

    // The command goes out and the host answers with a snapshot; there is
    // nothing synchronous to report but whether the socket took it. Read
    // `state` afterwards to see where it landed.
    function resume(id: string): string {
      if (!OriClient.resume(id)) return "error: " + OriClient.error
      return "resuming " + id
    }

    // What the client currently holds, in one line -- the thing to read after a
    // resume to see whether it landed.
    function state(): string {
      return "warm=" + OriClient.warm
           + " busy=" + OriClient.busy
           + " turns=" + OriClient.turns.count
           + " session=" + (OriClient.sessionId === "" ? "-" : OriClient.sessionId)
           + " tokens=" + OriClient.usageTotal
           + (OriClient.error === "" ? "" : " error=\"" + OriClient.error + "\"")
    }

    // The transcript list's live scroll geometry: what the view thinks the
    // content is, where it sits, and what the delegates themselves occupy.
    // The point of the per-child walk is to catch a LYING contentHeight --
    // the difference between it and the true delegate extent is exactly the
    // blank a scroll can wander into.
    function scroll(): string {
      var l = ScrollProbe.list
      if (!l) return "no transcript registered"
      // itemAtIndex(), NOT contentItem.children.
      //
      // `children` mixes POSITIONED delegates with POOLED ones the view is
      // holding for reuse, and a pooled item keeps whatever `y` it last had.
      // That contamination is not theoretical and it fooled this probe's own
      // consumers: `lastEnd` came back as +2686.7 while the newest turn ended
      // at -18.0 in every other sample, and one read reported height=-137.0.
      // Two reviewers were ALSO fooled by it earlier tonight, inferring originY
      // off the same array and reporting a divergence that did not exist.
      //
      // itemAtIndex(i) returns the delegate for a model index or null when it
      // has not been created, so the walk sees exactly the live ones. It is
      // O(count) per call; this is a diagnostic and count is in the hundreds.
      var kids = []
      for (var q = 0; q < l.count; q++) {
        var it = l.itemAtIndex(q)
        if (it) kids.push(it)
      }
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
      // `newestEnd` is index 0 SPECIFICALLY -- under BottomToTop that is the
      // newest turn, and it is the only honest ceiling reference.
      //
      // `lastEnd` is a MAX over every built delegate, and delegates can
      // OVERLAP: caught live with 187/187 built, index 2 measuring
      // y=-1597.8 h=1731.5 end=+133.7 while index 0 ended at 0.0 -- an
      // overgrown row reaching 133.7px past the newest turn. Aiming the view
      // at `lastEnd` would therefore park it past the end of the conversation.
      // Same failure as taking originY off contentItem.children: a max over
      // items that may overlap is not the extent of anything.
      var newest = l.itemAtIndex(0)
      var newestEnd = newest ? (newest.y + newest.height) : NaN

      // Overlap is worth reporting on its own -- two rows drawn on top of each
      // other is a layout bug, and it also makes `gap` read high at rest for a
      // reason that has nothing to do with scrolling.
      var spans = []
      for (var si = 0; si < kids.length; si++)
        if (kids[si].height > 0) spans.push([kids[si].y, kids[si].y + kids[si].height])
      spans.sort(function (a, b) { return a[0] - b[0] })
      var overlap = 0
      for (var oi = 1; oi < spans.length; oi++)
        if (spans[oi][0] < spans[oi - 1][1])
          overlap += spans[oi - 1][1] - spans[oi][0]

      out.push("  firstY=" + lo.toFixed(1)
        + "  newestEnd=" + (isNaN(newestEnd) ? "n/a" : newestEnd.toFixed(1))
        + "  lastEnd=" + hi.toFixed(1)
        + (hi - newestEnd > 1 ? " (OVERSHOOTS newest by "
            + (hi - newestEnd).toFixed(1) + ")" : "")
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
        + "  gap=" + biggest.toFixed(1)
        + "  overlap=" + overlap.toFixed(1))
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
      for (var i = 0; i < OriClient.turns.count; i++) {
        var r = OriClient.turns.get(i)
        // Text is CAPPED. A settled transcript here reaches 122 rows of
        // multi-thousand-character answers, and the whole reply crossed what
        // the IPC will carry -- `ori transcript` failed with
        // `QLocalSocket::PeerClosedError` while `state` and `sessions` on the
        // same target still answered, which is what "the response is too big"
        // looks like from the outside. This function exists to show SHAPE --
        // which row holds what, in what order -- and shape survives truncation.
        // Read the full text from the session file if you need it.
        var body = String(r.text).replace(/\s+/g, " ")
        if (body.length > 160) body = body.substring(0, 160) + "…(" + body.length + " chars)"
        var line = "[" + i + "] " + r.role + ": " + body
        if (String(r.images) !== "") line += "  {img: " + String(r.images).replace(/\n/g, ", ") + "}"
        // The TOOL CALLS, because a row can be entirely made of them and
        // printing `text` alone then reads as an empty row that the panel is
        // in fact drawing as a ToolLine. That misreading was passed on as a
        // bug report once already: an interrupted turn holding a `sleep 9`
        // call showed here as `[33] assistant:` and nothing else, and the
        // "stray empty band" it was taken for did not exist on screen.
        // Keyed by the turn's own id, never by the row: the map survives a
        // steer inserting a turn above it, and this loop's `i` would not.
        var calls = OriClient.toolsById[r.tid] || []
        if (calls.length > 0) {
          var names = []
          for (var c = 0; c < calls.length; c++)
            names.push(String(calls[c].name)
              + (calls[c].state === "running" ? " running"
                                              : " " + Math.round(calls[c].ms) + "ms"))
          line += "  {tools: " + names.join(", ") + "}"
        }
        var cost = OriClient.costById[r.tid]
        if (cost) line += "  {cost: " + cost.seconds.toFixed(1) + "s/" + cost.output + "tok}"
        if (r.pending) line += "  {pending}"
        // Only NOW is a row genuinely empty -- no text, no calls, nothing.
        if (String(r.text) === "" && calls.length === 0) line += "  (EMPTY ROW)"
        out.push(line)
      }
      return out.length === 0 ? "(empty)" : out.join("\n")
    }

    // Kill the child without touching the transcript, which is how "the shell
    // restarted" is reproduced on demand. The next ask() re-attaches to the
    // session file, exactly as it would after an idle kill.
    //
    // The panel command line, not a call of its own: /restart is one of the
    // commands the host parses and it must work with no child running, so the
    // client has nothing to add by having a second way in.
    function restart(): string {
      return OriClient.command("/restart") ? "child stopped" : "error: " + OriClient.error
    }
  }
}
