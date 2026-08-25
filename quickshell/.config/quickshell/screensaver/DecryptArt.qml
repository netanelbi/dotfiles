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

  // Art, as an array of equal-length rows.
  property var rows: []
  readonly property int cols: rows.length ? rows[0].length : 0

  // --------------------------------------------------------------- timing
  readonly property int colStagger: 16     // per column, sweeping right
  readonly property int rowStagger: 45     // per row, so it cascades
  readonly property int typeMs: 260        // block-glyph fill
  readonly property int fastMs: 900        // rapid symbol flipping
  readonly property int slowMs: 1100       // flips stretching out
  readonly property int holdMs: 7000       // settled, before it runs again

  // Each cell decrypts for its own length, up to this much longer than the
  // base. tte does the same ("1-15 longer duration units"), and it is what
  // makes characters resolve one at a time instead of sweeping across in a
  // clean diagonal wave.
  readonly property int jitterMs: 1400

  readonly property int cycleMs:
    colStagger * cols + rowStagger * rows.length
    + typeMs + fastMs + slowMs + jitterMs + holdMs

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

        var e = t - (c * art.colStagger + r * art.rowStagger)
        var slow = art.slowMs + art.noise(r, c, 7717) % art.jitterMs

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

  // Two Text items for the WHOLE art, not one per row. Per-row Items had to
  // guess a line height, and any guess that disagrees with the font's own
  // makes the block glyphs overlap or gap instead of tiling. Handing Qt the
  // newlines lets it lay the grid out itself, exactly as a terminal would.
  Item {
    anchors.centerIn: parent
    width: plain.implicitWidth
    height: plain.implicitHeight

    Text {
      text: art.cipherRows.join("\n")
      color: Theme.mauve
      font.family: Style.font.family
      font.pixelSize: art.fontSize
      renderType: Text.NativeRendering
    }

    Text {
      id: plain
      text: art.plainRows.join("\n")
      color: Theme.text
      font.family: Style.font.family
      font.pixelSize: art.fontSize
      renderType: Text.NativeRendering
    }
  }
}
