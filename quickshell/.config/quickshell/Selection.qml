pragma Singleton

import QtQuick

// Selection across blocks, for the assistant panel.
//
// The transcript is a column of separate read-only TextEdits -- one per
// paragraph, one for the user's message, one per table -- and Qt has no
// selection that spans more than one of them. A drag died at the edge of the
// block it started in, which made "copy the last three paragraphs" and even
// "copy what I just sent" impossible.
//
// So the mouse is driven from here instead of by each TextEdit on its own.
// Every selectable block registers itself (SelectableArea does it); one press
// sets an anchor, a drag moves a head that may land on ANY registered block,
// and apply() then distributes the selection across the range -- full blocks
// between, partial ends -- and copies what is selected, live, the way a single
// block always did.
//
// What is NOT registered is skipped by construction: a collapsed tool batch is
// a grey tally line drawn with Text, not a TextEdit, so a selection that spans
// past it copies the prose around it and leaves the tally out -- which is what
// "skip the collapsed areas" means, without a special case anywhere.
//
// Order is visual, not structural: blocks are sorted by their mapped y in
// scene coordinates, so a selection reads top-to-bottom whatever delegate the
// blocks happen to live in, and the user's pill participates like any block.
QtObject {
  id: root

  // Every live selectable block: { te: TextEdit, sep: string }. `sep` is how
  // this block joins the NEXT one in a multi-block copy -- list items and
  // table rows join with one newline (they are lines of one list), everything
  // else with a paragraph break.
  property var blocks: []

  // Where the drag started, and where it is now: { te, pos }.
  property var anchor: null
  property var head: null

  // The text of the selection as last applied, so an unchanged frame does not
  // re-queue a copy. Empty on purpose when the selection is empty -- the
  // clipboard keeps the LAST copy; deselecting must not wipe it (Copy.take
  // refuses empty text for the same reason).
  property string lastText: ""

  function register(te, sep) {
    root.blocks.push({ te: te, sep: sep || "\n\n" })
  }

  function unregister(te) {
    for (var i = root.blocks.length - 1; i >= 0; i--)
      if (root.blocks[i].te === te) root.blocks.splice(i, 1)
    // A block that streamed away while selected takes the whole selection
    // with it: positions past it are meaningless and half a selection is
    // worse than none.
    if ((anchor && anchor.te === te) || (head && head.te === te)) clear()
  }

  // Press on a block. Everything old goes first -- a click is also how you
  // dismiss a selection you no longer want.
  function begin(area, x, y) {
    clear()
    var te = area.sel
    var p = area.mapToItem(te, x, y)
    anchor = { te: te, pos: te.positionAt(p.x, p.y) }
    head = anchor
    apply()
  }

  // Drag. The point is mapped to the scene and matched against every
  // registered block, so the head may leave the block it started in -- that
  // is the whole point. Past the edges it clamps to the first/last block.
  function drag(area, x, y) {
    if (!anchor) return
    var sp = area.mapToItem(null, x, y)
    var b = hit(sp.x, sp.y)
    if (!b) return
    var p = b.te.mapFromItem(null, sp.x, sp.y)
    head = { te: b.te, pos: b.te.positionAt(
      Math.max(0, Math.min(p.x, b.te.width)),
      Math.max(0, Math.min(p.y, b.te.height))) }
    apply()
  }

  // Double-click: one word, in one block. TextEdit's own word selection is
  // unreachable from here (the mouse belongs to the area above it), and its
  // word boundaries are not exposed -- so scan the plain text around the
  // position with getText(), which returns rendered text, not the HTML the
  // `text` property carries.
  function wordSelect(area, x, y) {
    var te = area.sel
    var p = area.mapToItem(te, x, y)
    var pos = te.positionAt(p.x, p.y)
    var lo = Math.max(0, pos - 80)
    var s = te.getText(lo, Math.min(te.length, pos + 80))
    var at = pos - lo
    var isWord = function (c) { return /[A-Za-z0-9_\-.\/]/.test(c) }
    var a = at, b = at
    while (a > 0 && isWord(s.charAt(a - 1))) a--
    while (b < s.length && isWord(s.charAt(b))) b++
    if (a === b) { begin(area, x, y); return }   // not on a word: treat as a click
    anchor = { te: te, pos: lo + a }
    head = { te: te, pos: lo + b }
    apply()
  }

  function clear() {
    anchor = null
    head = null
    for (var i = 0; i < root.blocks.length; i++) root.blocks[i].te.deselect()
    root.lastText = ""
  }

  // Registered blocks that can take part right now, in reading order.
  function sorted() {
    var list = []
    for (var i = 0; i < root.blocks.length; i++) {
      var te = root.blocks[i].te
      if (!te.visible || te.height <= 0) continue
      list.push({ te: te, sep: root.blocks[i].sep, y: te.mapToItem(null, 0, 0).y })
    }
    list.sort(function (a, b) { return a.y - b.y })
    return list
  }

  // The block under a scene point, or the nearest one when the point is in a
  // gap -- spacing, a collapsed tally, the space beside the user's pill. The
  // drag clamps into it rather than dying in the whitespace.
  function hit(px, py) {
    var list = sorted()
    var best = null, bd = Infinity
    for (var i = 0; i < list.length; i++) {
      var te = list[i].te
      if (py >= list[i].y && py <= list[i].y + te.height) return list[i]
      var d = py < list[i].y ? list[i].y - py : py - (list[i].y + te.height)
      if (d < bd) { bd = d; best = list[i] }
    }
    return best
  }

  function sanitize(s) {
    // Minus Fmt's invisible wrap guards, so a paste that looks right also
    // RUNS: real hyphens, real spaces, no zero-width anything.
    return String(s).replace(/\u200b/g, "").replace(/\u2011/g, "-").replace(/\u00a0/g, " ")
  }

  // Distribute the anchor..head range across the blocks and copy what is
  // selected. Called on every move; Copy's settle timer turns that stream
  // into one write.
  function apply() {
    if (!anchor || !head) return
    var list = sorted()
    var ai = -1, hi = -1
    for (var i = 0; i < list.length; i++) {
      if (list[i].te === anchor.te) ai = i
      if (list[i].te === head.te) hi = i
    }
    if (ai < 0 || hi < 0) return
    var lo = Math.min(ai, hi), up = Math.max(ai, hi)
    var down = ai <= hi

    for (i = lo; i <= up; i++) {
      var te = list[i].te
      if (lo === up)
        te.select(Math.min(anchor.pos, head.pos), Math.max(anchor.pos, head.pos))
      else if (i === lo)
        te.select(down ? anchor.pos : head.pos, te.length)
      else if (i === up)
        te.select(0, down ? head.pos : anchor.pos)
      else
        te.selectAll()
    }

    var t = "", joiner = ""
    for (i = lo; i <= up; i++) {
      var s = sanitize(list[i].te.selectedText)
      if (s === "") continue
      t += joiner + s
      joiner = list[i].sep
    }
    if (t === root.lastText) return
    root.lastText = t
    if (t !== "") Copy.take(t)
  }
}