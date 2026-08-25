import QtQuick
import Quickshell
import Quickshell.Io
import "root:/"

// The tte "decrypt" effect, reimplemented in QML.
//
// This is the one Omarchy's screensaver is known for, and it runs in two
// phases per character:
//
//   1. type      block glyphs (U+2589..) fill the cell in, sweeping left to
//                right across the art
//   2. decrypt   the cell flips through random cipher symbols -- fast at
//                first, then slowing down -- before settling on its real
//                character
//
// Cipher symbols come from the same four ranges tte draws on: ASCII
// punctuation, block elements, box drawing and Latin-1 miscellany.
//
// Rendering: two Text items per row, overlaid, not one Text per character.
// A 38x8 art is ~300 cells, and 300 QML items each rebinding every frame is
// far more expensive than 16 items each rebuilding a 38-character string.
// One row holds only the settled characters, the other only the flipping
// ones, with spaces where the other has content -- in a monospace font they
// interleave exactly, and each gets its own colour for free.
Item {
  id: art

  // Wall clock for the whole effect, in ms.
  property real t: 0

  // Slow float, driven from the window. Applied as centre offsets rather than
  // x/y: the canvas is anchored, and an anchored item ignores x/y outright --
  // which is exactly how an earlier version of this drifted nowhere at all.
  property real driftX: 0
  property real driftY: 0

  // Art, as an array of equal-length rows.
  property var rows: []
  readonly property int cols: rows.length ? rows[0].length : 0

  // --------------------------------------------------------------- timing
  readonly property int colStagger: 26     // per column, sweeping right
  readonly property int rowStagger: 70     // per row, so it cascades
  readonly property int typeMs: 420        // block-glyph fill
  readonly property int fastMs: 1400       // rapid symbol flipping
  readonly property int slowMs: 1700       // flips stretching out
  readonly property int holdMs: 3000       // settled, before it re-encrypts

  // Each cell decrypts for its own length, up to this much longer than the
  // base. tte does the same ("1-15 longer duration units"), and it is what
  // makes characters resolve one at a time instead of sweeping across in a
  // clean diagonal wave.
  readonly property int jitterMs: 1400

  // One pass of the effect, ignoring the settled hold.
  readonly property int passMs:
    colStagger * cols + rowStagger * rows.length
    + typeMs + fastMs + slowMs + jitterMs

  // In, settle, back out, repeat. Running the same pass with time reversed is
  // what makes it read as continuous rather than as a clip restarting: the art
  // scrambles back apart instead of blinking away.
  readonly property int cycleMs: passMs * 2 + holdMs

  readonly property string blocks: "░▒▓█"
  // Built once: rebuilding this per flip would allocate ~300 strings a frame.
  //
  // tte also ciphers with Latin-1 miscellany (U+00AE..U+01C3), and it can,
  // because a terminal forces every glyph into one cell. QML has no such grid:
  // those accented forms render at their natural advance in JetBrainsMono and
  // the art's columns visibly tear apart mid-scramble. Restricted to the three
  // ranges that really are single-width here.
  readonly property string cipher: {
    var s = ""
    // Weighted, not uniform. The art is drawn in solid block glyphs, and at
    // this size a cell is ~36px across -- a thin ASCII symbol leaves it nearly
    // empty, so a uniform palette makes the scramble and the resolved art look
    // like two different materials rather than one morphing into the other.
    // Blocks and box drawing carry most of the weight; ASCII is the sparkle.
    for (var rep = 0; rep < 4; rep++) {
      for (var b = 9600; b <= 9631; b++) s += String.fromCharCode(b)  // blocks
    }
    for (var rep2 = 0; rep2 < 2; rep2++) {
      for (var k = 9472; k <= 9598; k++) s += String.fromCharCode(k)  // box draw
    }
    for (var i = 33; i <= 126; i++) s += String.fromCharCode(i)       // ASCII
    return s
  }

  // Deterministic per (cell, flip): the same cell shows the same sequence on
  // every run, so nothing jitters between frames for the wrong reason.
  function noise(a, b, c) {
    var h = (a * 374761393 + b * 668265263 + c * 2147483647) >>> 0
    h = (h ^ (h >>> 13)) * 1274126177 >>> 0
    return (h ^ (h >>> 16)) >>> 0
  }

  // ---------------------------------------------------------------- state
  property var cipherRows: []
  property var plainRows: []

  function rebuild() {
    if (!art.rows.length) return

    var t = art.t % art.cycleMs
    var cr = []
    var pr = []

    for (var r = 0; r < art.rows.length; r++) {
      var src = art.rows[r]
      var cipherLine = ""
      var plainLine = ""

      for (var c = 0; c < src.length; c++) {
        var ch = src.charAt(c)
        // Spaces are the art's negative space -- scrambling them would fill
        // the bounding box and lose the letterforms entirely.
        if (ch === " ") {
          cipherLine += " "
          plainLine += " "
          continue
        }

        var stagger = c * art.colStagger + r * art.rowStagger
        var slow = art.slowMs + art.noise(r, c, 7717) % art.jitterMs

        var e
        if (t < art.passMs) {
          e = t - stagger                                   // decrypting in
        } else if (t < art.passMs + art.holdMs) {
          e = Number.MAX_VALUE                              // settled
        } else {
          // Time runs backwards through the identical phase machine, so the
          // cell re-scrambles and then un-types. The stagger reverses with it,
          // which peels the art apart from the far edge inwards.
          e = (art.cycleMs - t) - stagger
        }

        if (e < 0) {
          cipherLine += " "
          plainLine += " "
        } else if (e < art.typeMs) {
          // Fill: ░ ▒ ▓ █, one step per quarter of the phase.
          var step = Math.min(3, Math.floor(e / (art.typeMs / 4)))
          cipherLine += art.blocks.charAt(step)
          plainLine += " "
        } else if (e < art.typeMs + art.fastMs + slow) {
          var d = e - art.typeMs
          var flip
          if (d < art.fastMs) {
            flip = Math.floor(d / 28)                     // ~36 flips/sec
          } else {
            // Ease the interval out from 28ms to ~190ms, which is what makes
            // the character look like it is settling rather than stopping.
            var p = (d - art.fastMs) / slow
            var acc = art.fastMs / 28 + (Math.pow(p, 0.45) * slow) / (28 + p * 162)
            flip = Math.floor(acc)
          }
          var idx = art.noise(r, c, flip) % art.cipher.length
          cipherLine += art.cipher.charAt(idx)
          plainLine += " "
        } else {
          cipherLine += " "
          plainLine += ch
        }
      }

      cr.push(cipherLine)
      pr.push(plainLine)
    }

    art.cipherRows = cr
    art.plainRows = pr
  }

  onTChanged: art.rebuild()
  onRowsChanged: art.rebuild()

  // ----------------------------------------------------------------- art
  FileView {
    path: Quickshell.env("HOME") + "/.local/share/screensaver/vivo.txt"
    watchChanges: true
    onFileChanged: this.reload()
    onLoaded: {
      var lines = this.text().replace(/\n+$/, "").split("\n")
      var w = 0
      for (var i = 0; i < lines.length; i++) w = Math.max(w, lines[i].length)
      // Pad to a rectangle: the two overlaid Texts must agree on every column.
      for (var j = 0; j < lines.length; j++)
        while (lines[j].length < w) lines[j] += " "
      art.rows = lines
    }
  }

  // ------------------------------------------------------------- geometry
  // Sized off the real advance width of the font rather than a guessed ratio,
  // so the art fills the same fraction of any monitor.
  FontMetrics {
    id: fm
    font.family: Style.font.family
    font.pixelSize: 100
  }

  readonly property real cellRatio: fm.advanceWidth("█") / 100
  readonly property int fontSize: {
    if (!cols) return 10
    var byWidth = (art.width * 0.72) / (cols * cellRatio)
    var byHeight = (art.height * 0.55) / (rows.length * 1.16)
    return Math.max(6, Math.floor(Math.min(byWidth, byHeight)))
  }

  // Letter groups: runs of columns that carry ink, split on columns that are
  // blank in every row. The art is one string per row, but "floating" has to
  // happen per letter, and a letter is exactly such a run.
  readonly property var groups: {
    if (!art.rows.length) return []
    var n = art.cols
    var out = []
    var start = -1
    for (var c = 0; c < n; c++) {
      var ink = false
      for (var r = 0; r < art.rows.length; r++) {
        if (art.rows[r].charAt(c) !== " ") { ink = true; break }
      }
      if (ink && start < 0) start = c
      if (!ink && start >= 0) { out.push({ start: start, end: c }); start = -1 }
    }
    if (start >= 0) out.push({ start: start, end: n })
    return out
  }

  // Colours. tte finishes on a gradient across the art (its default is a
  // vertical one) and ciphers in a contrasting colour; these are the
  // Catppuccin stand-ins for that. Change these two lines to retheme.
  readonly property color cipherColor: Theme.mauve
  readonly property color topColor: Theme.lavender
  readonly property color bottomColor: Theme.sapphire

  // Real metrics at the real size. One Text per row needs an exact row pitch:
  // the block glyphs have to tile edge to edge, and a guessed line height
  // makes them overlap or gap. fm2 is what the font itself uses.
  FontMetrics {
    id: fm2
    font.family: Style.font.family
    font.pixelSize: art.fontSize
  }
  readonly property real cellH: fm2.height

  // Cell width is measured off a real rendered Text, not asked of
  // FontMetrics. The two disagreed by a factor of three here, which made the
  // canvas far narrower than its contents -- so centring it parked the art
  // well right of centre. Measuring what actually gets drawn cannot drift.
  Text {
    id: metric
    visible: false
    text: "\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588"
    font.family: Style.font.family
    font.pixelSize: art.fontSize
    renderType: Text.NativeRendering
  }
  readonly property real cellW: metric.implicitWidth / 10

  // The art is padded to a rectangle, and its rows carry eight blank leading
  // columns. Centring the padded box therefore parks the word right of centre;
  // centre on the ink instead.
  readonly property int inkStart: groups.length ? groups[0].start : 0
  readonly property int inkEnd: groups.length ? groups[groups.length - 1].end : cols

  Item {
    id: canvas
    anchors.centerIn: parent
    anchors.horizontalCenterOffset: art.driftX
    anchors.verticalCenterOffset: art.driftY
    width: (art.inkEnd - art.inkStart) * art.cellW
    height: art.rows.length * art.cellH

    Repeater {
      model: art.groups

      // One letter. Each drifts on its own pair of sines, on periods that do
      // not divide into each other, so no two letters ever share a beat and
      // the word never snaps back into a rigid block.
      delegate: Item {
        id: letter
        required property int index
        required property var modelData

        // Travel is a fraction of the CELL, not of the font size. Those differ
        // by more than they look: at this art's size the font lands near 40px,
        // so the first attempt at 0.16 of it gave +-6px of travel -- moving,
        // measurably, but far too little for the eye to read as motion.
        //
        // Vertical gets the larger share. The art has a blank row above and
        // below, so there is room to rise and fall, while sideways travel is
        // bounded by the one-column gap between letters.
        // Two sines per axis on periods that do not divide into each other.
        // A single sine per axis traces a straight line back and forth; the
        // second one bends the path into a slow wander that never repeats the
        // same way twice, which is what reads as floating rather than sliding.
        // No phase offsets: sin(0) is 0, so every letter opens exactly where it
        // was laid out and the word is intact on the first frame. Divergence
        // comes from the periods instead, which differ per letter, so they
        // pull apart within a second or two and never resync.
        //
        // Two sines per axis. A single one traces a straight line back and
        // forth; the second bends the path into a wander that does not repeat,
        // which is what reads as floating rather than sliding.
        readonly property real bobX: art.cellW * (
            0.34 * Math.sin(art.t / (640 + letter.index * 95))
          + 0.22 * Math.sin(art.t / (1130 + letter.index * 70)))
        readonly property real bobY: art.cellH * (
            0.36 * Math.sin(art.t / (530 + letter.index * 80))
          + 0.24 * Math.sin(art.t / (970 + letter.index * 60)))

        x: (modelData.start - art.inkStart) * art.cellW + bobX
        y: bobY
        width: (modelData.end - modelData.start) * art.cellW
        height: canvas.height

        Repeater {
          model: art.rows.length

          delegate: Item {
            id: row
            required property int index

            y: Math.round(row.index * art.cellH)
            width: letter.width
            height: art.cellH

            // The resolved character takes its colour from where it sits in
            // the art, which is what turns a flat wordmark into a gradient.
            readonly property color tint: Qt.tint(
              art.topColor,
              Qt.rgba(art.bottomColor.r, art.bottomColor.g, art.bottomColor.b,
                      art.rows.length > 1 ? row.index / (art.rows.length - 1) : 0))

            function slice(src) {
              var line = src[row.index]
              return line === undefined ? "" : line.substring(letter.modelData.start, letter.modelData.end)
            }

            Text {
              text: row.slice(art.cipherRows)
              color: art.cipherColor
              font.family: Style.font.family
              font.pixelSize: art.fontSize
              renderType: Text.NativeRendering
            }

            Text {
              text: row.slice(art.plainRows)
              color: row.tint
              font.family: Style.font.family
              font.pixelSize: art.fontSize
              renderType: Text.NativeRendering
            }
          }
        }
      }
    }
  }
}
