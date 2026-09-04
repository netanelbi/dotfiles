import QtQuick
import ".."

// The panel's shared formatting: two number formats, the one place that decides
// what in an answer is a picture, and the pass that cuts an answer into blocks.
// The activity rail and every settled turn print a duration and a token count,
// and the two must read identically or the eye stops trusting either. A QtObject
// rather than a singleton, and now for a second reason: splitCached() keeps ONE
// streaming turn's settled prefix, so the instance has to belong to the turn
// that owns the text.
QtObject {
  id: fmt

  // Milliseconds at the precision the number deserves: 340ms, not 0.3s, and a
  // nine-minute turn must not say 578.4s.
  function duration(ms) {
    if (ms <= 0) return ""
    if (ms < 1000) return Math.round(ms) + "ms"
    var s = ms / 1000
    if (s < 60) return (s < 10 ? s.toFixed(1) : Math.round(s)) + "s"
    var m = Math.floor(s / 60)
    return m + "m " + Math.round(s - m * 60) + "s"
  }

  function tokens(n) {
    if (n < 1000) return String(n)
    return (n / 1000).toFixed(n < 10000 ? 1 : 0) + "k"
  }

  // ------------------------------------------------------------------ images
  // Ori shows a picture by WRITING one: `![the wallpaper](/home/me/x.png)`, and
  // the panel paints the file where the syntax stood. localImage() is the half
  // that says no, and why this is a function rather than inline in the delegate:
  // that target is a string the MODEL chose, and rendering `![x](https://…)`
  // would make this laptop fetch whatever it named, on the strength of a token
  // prediction. The rule is absolute and fails closed -- an absolute LOCAL path,
  // resolved to a url an Image may load, or "" for everything else.
  function localImage(target) {
    var t = String(target || "").trim()
    if (t === "") return ""
    // Markdown's `<...>` form -- how a path with a space in it is written.
    if (t.charAt(0) === "<" && t.charAt(t.length - 1) === ">") t = t.slice(1, -1).trim()

    if (t.indexOf("file://") === 0) t = decodeURIComponent(t.slice(7))
    else if (t.slice(0, 2) === "~/") t = Theme.home + t.slice(1)

    // Absolute or nothing. One test rejects every scheme (http, data, even a
    // file:// with a host, which decodes to `//host/…`) and relative paths too --
    // Ori's cwd is not the panel's, so a bare `shot.png` is a guess.
    if (t.charAt(0) !== "/" || t.charAt(1) === "/") return ""
    if (t.indexOf("://") >= 0 || t.indexOf("\n") >= 0) return ""

    // A `#` or a `?` in a filename would otherwise read as url syntax, and the
    // file would come back missing for no visible reason.
    return "file://" + encodeURI(t).replace(/#/g, "%23").replace(/\?/g, "%3F")
  }

  // ------------------------------------------------------------- attachments
  // What the USER sent, newline-separated in the `images` role -- and not one of
  // those lines is guaranteed to be a path, which is why this is a function and
  // not a Repeater over `text.split("\n")`. A file gives an absolute path and is
  // paintable; a data URI gives the words "pasted image", and a resumed
  // transcript "(attached image/png)", because a session file carries the BYTES
  // and not the path. Those two are all that says the question had a picture in
  // it, so they come back as labels rather than being dropped.
  function attached(images) {
    var out = []
    var lines = String(images || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line === "") continue
      var url = localImage(line)
      out.push(url !== "" ? { image: true, source: url, label: line }
                          : { image: false, source: "", label: line })
    }
    return out
  }

  // ------------------------------------------------------------------ order
  // The answer, as an ordered run of pieces:
  //
  //   { text }                            one paragraph of markdown
  //   { head: true, text }                one `##` heading, minus its hashes
  //   { bullet: true, mark, depth, text } one list item, minus its marker
  //   { code: true, text }                one fenced block
  //   { image: true, source, alt }        one picture
  //   { tool: true, calls, n }            one batch of tool calls, where it ran
  //
  // `streaming` is true while the turn is still being written; `calls` is the
  // turn's tool log, each entry carrying the `at` offset PiSession stamps. The
  // batches are why this takes `calls`: a working turn is speak, run, speak,
  // run, and without the offsets it rendered as one paragraph under one batch
  // line, because the text is one string and the log was a flat list.
  function split(body, streaming, calls) {
    var src = String(body || "")
    var out = []
    // Only the tail is still being typed; everything before a tool call was
    // finished the moment the call started.
    scan(out, src.slice(tools(out, src, calls || [])), streaming)

    // An answer with no text at all still needs one piece, or the turn has
    // nothing to give it height and the list jumps on the first token.
    if (out.length === 0) out.push({ image: false, text: rich(src) })

    // No `aside` marking any more. Everything up to the last tool call used to
    // be flagged as preamble so the delegate could grey it out and then fold it
    // away; the panel folds nothing now, and prose the agent wrote between two
    // commands is prose, not a footnote to itself.
    return out
  }

  // The tool half of that pass, on its own so splitCached() can replay it: the
  // batches and the prose BETWEEN them, up to the last call. Returns how much of
  // src it consumed -- everything after that offset is the stretch still being
  // written into.
  function tools(out, src, list) {
    var at = 0        // how much of src has been emitted
    var batch = []    // the batch being gathered
    var n = 0         // which batch this is, so the delegate can key its drawer

    for (var i = 0; i < list.length; i++) {
      // Clamped, and monotonic: a restored call with no offset reads as 0, and
      // a run of those must not walk backwards through the answer.
      var stop = Math.max(at, Math.min(src.length, Number(list[i].at) || 0))
      var gap = src.slice(at, stop)
      // ONLY text starts a new batch. Three commands with nothing said between
      // them stay one "Ran 3 commands" line -- that collapse is the point, and
      // whitespace is not something Ori said.
      if (gap.replace(/\s/g, "") !== "") {
        if (batch.length > 0) { out.push({ image: false, tool: true, calls: batch, n: n++ }); batch = [] }
        scan(out, gap, false)
      }
      at = stop
      batch.push(list[i])
    }
    if (batch.length > 0) out.push({ image: false, tool: true, calls: batch, n: n++ })
    return at
  }

  // ------------------------------------------------------- the settled prefix
  // split() again, but only over what has ARRIVED since last time.
  //
  // The binding that calls this re-runs on every delta, and `body` is the whole
  // answer, so the un-cached pass costs the whole answer per token: measured
  // offscreen on Qt 6.11.2's V4 (/tmp/orifmt/bench.qml), streaming one answer in
  // 20-char deltas cost 10ms at 2k chars, 253ms at 10k and 660ms at 20k -- more
  // than four times the total for twice the words, which is the quadratic. Per
  // call at 20k that is 1.15ms of a 16.7ms frame, spent re-deriving text that
  // cannot have changed. Through here the same three answers cost 2ms, 12ms and
  // 54ms, and every piece comes out identical (checked delta by delta against
  // split() over 2.2M deltas of generated markdown).
  //
  // WHAT MAKES A BLOCK FINAL is the whole question, and "before the last blank
  // line" is NOT the answer here: push() gathers plain lines into `buf` and only
  // a heading, a bullet or a table ever flushes it, so a blank line does not end
  // a piece -- it becomes the `<br><br>` inside one. Cutting there would turn
  // one paragraph into two. The boundaries Fmt actually segments on are:
  //
  //   * a heading line, and a bullet line -- both flush buf and emit their own
  //     piece, so push() of what follows starts with an empty buf either way;
  //   * a line that CLOSES a fence with nothing after the backticks -- scan()
  //     splits on ``` and the part that follows begins fresh.
  //
  // and a cut is only taken at the newline that ENDS such a line, so no piece
  // can straddle it. Four things disqualify a cut:
  //
  //   * an odd number of ``` before it -- inside a fence, where a `- ` is not a
  //     bullet and a `## ` is not a heading;
  //   * a `![` ANYWHERE on the line. push() never sees that line: images() runs
  //     first and pulls the `![...](...)` out, so what push() is handed starts
  //     MID-LINE and the line is not a boundary at all. Measured -- `- ![shot]
  //     (/tmp/a.png) the wallpaper` followed by a line of prose came back as two
  //     paragraphs where split() gives one, and it did not heal when the turn
  //     settled, because the cache stays warm. A bullet holding ONLY an image is
  //     equivalent either way; disqualifying the whole class costs nothing real;
  //   * a `![` still waiting for its `)` on an EARLIER line, because the
  //     streaming half-image guard in images() cuts back to the LAST `![` and
  //     would otherwise reach into text this pass has already settled;
  //   * the final line of the body, which is mid-write by definition.
  //
  // The first of those was found by a fuzz over a line grammar that included
  // image-bearing headings and bullets. 2.2M deltas of generated markdown had
  // not found it, because not one of those bodies had an image on a block line:
  // the diversity of the input is what caught it, not the volume.
  //
  // The cache is dropped whenever the row is not simply GROWING. `calls` is
  // compared by identity -- PiSession rebuilds toolLog by assignment, never in
  // place, so a new call, a resume, a steer or a rehydrate all hand over a
  // different array. That is the one thing here that depends on a file this one
  // does not own: a PiSession that ever mutated a logged call IN PLACE, `at`
  // above all, would leave this cache stale with nothing to notice it. The
  // settled text is compared in full as well, so a prefix
  // that was replaced rather than appended to (rehydrate, re-wrap) recomputes
  // instead of being trusted. That compare is a memcmp over the settled prefix,
  // ~1µs at 20k against the ~1ms it guards.
  //
  // What is left is not free and is not meant to look it: every delta still
  // copies the settled piece list and compares the settled text, both linear in
  // the answer. They cost 0.06ms per delta at 20k. And an answer with NO block
  // lines in it at all -- one long run of prose, no heading, no bullet, no fence
  // -- has no boundary to settle on and gains only what the tool calls in it
  // give (measured: 470ms -> 131ms at 20k with three calls, and nothing without
  // them). That is push()'s segmentation, not this cache's: fixing it would mean
  // ending a piece at a blank line, which changes what the panel draws.
  //
  // A BOX that is never reassigned, holding a record that moves. Assigning the
  // record to the property itself is what the obvious version does and it costs
  // exactly what this saves: splitCached() is called from a binding, so the
  // property it reads is captured as a dependency of that binding and the
  // property it writes re-triggers it. Measured on the live panel -- "QML
  // TurnDelegate: Binding loop detected for property pieces", once per token.
  // Nothing notifies on a var property's CONTENTS, so mutating the box is
  // invisible to the binding, which is the point.
  // `calls: null` is the empty state -- splitCached() never has a null list, so
  // no live cache can look empty.
  readonly property var cache: ({ calls: null, at: 0, text: "", pieces: null })

  function splitCached(body, streaming, calls) {
    var src = String(body || "")
    var list = calls || []
    var c = fmt.cache

    // A call whose offset is PAST the end of the body is clamped to the length
    // by tools(), so its cut moves forward as the answer grows -- the one way a
    // piece before the tail can change without the text before it changing.
    // Both paths that write `at` stamp it off the row's own text -- the live one
    // at onActiveToolChanged, and rehydrate() at PiSession.qml:1747, off the
    // text it has folded in so far -- so an offset is always within the row and
    // this is a guard against a malformed log rather than a case in the wild. It
    // costs a walk of a list that is a handful of entries long.
    for (var i = 0; i < list.length; i++) {
      if ((Number(list[i].at) || 0) > src.length) {
        c.calls = null
        return split(body, streaming, list)
      }
    }

    var out, from
    // lastIndexOf(needle, 0) tries position 0 and nothing else: one compare of
    // the settled prefix, no slice allocated.
    if (c.calls === list && src.lastIndexOf(c.text, 0) === 0) {
      out = c.pieces.slice()
      from = c.at
    } else {
      out = []
      from = tools(out, src, list)
      c.calls = null
    }

    var b = settleTo(src, from)
    if (b > from) {
      scan(out, src.slice(from, b), false)
      from = b
    }
    // Rewritten when the settled prefix GREW, and once on the cold pass so the
    // tool batches are not replayed on every delta of the answer after them.
    if (c.calls === null || c.at !== from) {
      c.calls = list
      c.at = from
      c.text = src.slice(0, from)
      c.pieces = out.slice()
    }

    scan(out, src.slice(from), streaming)
    if (out.length === 0) out.push({ image: false, text: rich(src) })
    // A NEW array every time, deliberately: the delegate's Repeater and its `m`
    // bindings are driven off this identity, and handing back the same array
    // would leave a settled piece showing the text it had one delta ago.
    return out
  }

  // The last offset in src that can be cut without changing a single piece --
  // see the block above for what qualifies. Never below `from`, and it walks
  // only what arrived since `from`, so this pass is bounded by the unsettled
  // tail rather than by the answer.
  function settleTo(src, from) {
    var b = from
    var fenced = false   // an odd number of ``` seen since `from`
    var dangling = false // a `![` still waiting for its `)`
    var i = from
    while (i < src.length) {
      var e = src.indexOf("\n", i)
      if (e < 0) break   // the last line is still being typed into
      var line = src.slice(i, e)

      var marks = 0, last = -1, p = line.indexOf("```")
      while (p >= 0) { marks++; last = p; p = line.indexOf("```", p + 3) }
      var inside = marks % 2 === 1 ? !fenced : fenced   // after this line

      if (dangling && line.indexOf(")") >= 0) dangling = false
      var img = line.lastIndexOf("![")
      if (img >= 0) dangling = line.indexOf(")", img) < 0

      // `img < 0`: a line carrying an image is not a boundary even when it is a
      // perfectly good bullet -- images() has already cut it in half by the time
      // push() decides anything. See the block above.
      if (!inside && !dangling && img < 0) {
        if (marks > 0) {
          // A fence closing at the END of its line, exactly. Anything after the
          // backticks -- even one space -- opens the next prose part with it,
          // and push() trims leading NEWLINES only, so that space survives into
          // the piece and a cut here would drop it (measured: ref " <br><br>ta"
          // against a cut "ta").
          if (last + 3 === line.length) b = e + 1
        } else if (!fenced && (headMatch(line) || bulletMatch(line))) {
          b = e + 1
        }
      }
      fenced = inside
      i = e + 1
    }
    return b
  }

  // The two block regexes push() decides with, named so settleTo() can ask the
  // same question and cannot drift from the answer.
  function headMatch(l) { return l.match(/^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$/) }
  function bulletMatch(l) { return l.match(/^(\s*)(?:([-*+])|(\d+)[.)])\s+(.+)$/) }

  // One stretch of the answer, cut into pieces. Fences FIRST, because a fenced
  // block leaves the prose entirely: odd indices are inside a block, even ones
  // are prose. That is why `prose(src, i)` is gone -- every image scan runs over
  // a fence-free stretch by construction, so the question cannot be asked.
  function scan(out, src, streaming) {
    var parts = String(src).split("```")
    for (var i = 0; i < parts.length; i++) {
      if (i % 2 === 1) fence(out, parts[i])
      // Only the very last stretch is still being typed into.
      else images(out, parts[i], streaming && i === parts.length - 1)
    }
  }

  // A fenced block, minus its info string: at 460px a "bash" caption costs a
  // row. Its own piece, because MarkdownText does not wrap one -- inside the
  // prose a long command simply stopped at the card's edge.
  function fence(out, block) {
    var t = String(block).replace(/^[^\n]*\n/, "").replace(/\s+$/, "")
    if (t !== "") out.push({ image: false, code: true, text: zwsp(nobr(t)) })
  }

  // The image pass, over one fence-free stretch.
  function images(out, src, streaming) {
    // Text arrives token by token, so for a frame or two the tail is a half-typed
    // `![the wallpaper](/home/ne`, which matches nothing and would TYPE ITSELF
    // OUT across the card before the picture replaced it. Cut the dangling
    // fragment and the image simply arrives -- only the last one, and only while
    // streaming: on a settled answer an unclosed `![` is text someone wrote.
    if (streaming) {
      var open = src.lastIndexOf("![")
      if (open >= 0 && src.indexOf(")", open) < 0) src = src.slice(0, open)
    }

    // Built per call: a /g regex carries its lastIndex between uses, and a
    // shared one would skip half the matches on every second delegate.
    var re = /!\[([^\]\n]*)\]\(([^)\n]*)\)/g
    var at = 0, m
    while ((m = re.exec(src)) !== null) {
      var url = localImage(m[2])
      if (url === "") continue     // not local: leave the markdown where it is
      push(out, src.slice(at, m.index))
      out.push({ image: true, source: url, alt: m[1] })
      at = m.index + m[0].length
    }
    push(out, src.slice(at))
  }

  // ----------------------------------------------------------------- blocks
  // Text between the pictures, cut into BLOCKS -- the pass that did not exist.
  // Ori's prompt now asks for markdown shape: the answer on line one, a `## `
  // heading per part, a bullet per item, backticks round every path. Hand all of
  // that to one MarkdownText and it comes back at QT's defaults, measured on this
  // card in ../frames/champ-card.png: a heading at twice the body size, louder
  // than the answer it is part of, and a list indented 55px out of 426, which is
  // what wrapped `exec-once` in two. So headings and items leave the markdown
  // here for the delegate to set; the rest stays markdown, since bold, emphasis
  // and inline code have to work inside it.
  function push(out, text) {
    var t = text.replace(/^\n+|\n+$/g, "")
    // Nothing but space is nothing, and a batch can sit at the very start of a
    // turn: the empty-answer placeholder is a single SPACE, and left in it drew
    // a blank line under the batch line for the whole of the first tool call.
    if (t.replace(/\s/g, "") === "") return
    var lines = t.split("\n"), buf = []
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i]
      // A closing run of hashes is optional in markdown and never content.
      var h = headMatch(l)
      var b = bulletMatch(l)
      // A GFM table, before the pipe row is mistaken for a paragraph. A table
      // is only ever the shape the models write: a pipe row, then a separator
      // row, then pipe rows. The separator is what separates a table from a
      // line of prose that happens to open with `|`; without it nothing is
      // claimed and the pipes fall through as the text they are.
      var tr = parseRow(l)
      if (tr !== null && i + 1 < lines.length && isSep(lines[i + 1])) {
        var rows = [tr]
        var from = i
        i += 2            // skip the separator with the loop's next increment
        while (i < lines.length && (tr = parseRow(lines[i])) !== null) {
          rows.push(tr); i++
        }
        i--               // the gather stopped one step short of staying put
        flush(out, buf); buf = []
        // The RAW block rides along, because the renderer that draws it is
        // Qt's markdown engine -- the one that has answered for tables since
        // before this panel existed. Parsing the cells proved to be the easy
        // half; laying them out by hand was where the bugs lived.
        out.push({ image: false, table: true, rows: rows,
                   md: lines.slice(from, i + 1).join("\n") })
        continue
      }
      if (!h && !b) { buf.push(l); continue }
      flush(out, buf); buf = []
      if (h) out.push({ image: false, head: true, text: prep(h[2]) })
      // A numbered list keeps its number -- the order is the content there. Two
      // levels of nesting, then it stops: a third indent in a 426px column buys
      // structure with the words it is structuring.
      else out.push({ image: false, bullet: true, text: prep(b[4]),
                      mark: b[2] ? "\u2022" : b[3] + ".",
                      depth: Math.min(2, Math.floor(b[1].length / 2)) })
    }
    flush(out, buf)
  }

  // One pipe row of a table, as its cells -- or null when the line is not one.
  // Leading pipe required, trailing optional; `\|` is a cell's own pipe char, a
  // distinction the split cannot see, so it hides under a placeholder for the
  // one character that cannot occur in an answer.
  function parseRow(l) {
    var s = String(l).trim()
    if (!/^\|.+.?\|?$/.test(s) || s === "|") return null
    var cells = s.replace(/^\|/, "").replace(/\|$/, "")
                 .replace(/\\\|/g, "\u0001").split("|")
                 .map(function (c) { return c.trim().replace(/\u0001/g, "|") })
    return cells
  }

  // The separator row `|---|:--:|`, true to GFM: dashes and colons, nothing
  // else, in every cell. Alignment is not read -- at 426px of card the cells
  // wrap wherever they must, and left is the only alignment left standing.
  function isSep(l) {
    var cells = parseRow(l)
    if (cells === null || cells.length === 0) return false
    for (var i = 0; i < cells.length; i++)
      if (!/^:?-+:?$/.test(cells[i])) return false
    return true
  }

  // The prose gathered between two blocks, or "" if it was only whitespace.
  function flush(out, buf) {
    var t = buf.join("\n").replace(/^\n+|\n+$/g, "")
    if (t.replace(/\s/g, "") !== "") out.push({ image: false, text: prep(t) })
  }

  // ------------------------------------------------------------- rich text
  // Prose leaves this file as RICH TEXT, not markdown.
  //
  // The reason is a number Qt will not let anyone set. `TextEdit.MarkdownText`
  // renders an inline code span in the fixed-pitch face at the SAME pixel size
  // as the prose around it, and a mono at a proportional face's size optically
  // outweighs it by about a third -- `waybar.service` and
  // `xdg-desktop-portal-hyprland.service` came out the loudest things in their
  // own sentences. The previous fix for that gave up the mono face entirely and
  // painted the word bold yellow in the PROSE font, which solved the size and
  // lost the one signal that says "this is a literal you can type".
  //
  // Owning the pass gets both, and it does not mean owning a markdown renderer:
  // by the time text arrives here it is no longer markdown. Fences, images,
  // headings and list items have ALREADY left (scan / images / push), so what
  // remains in a piece is one paragraph with at most three inline marks in it --
  // `code`, **bold**, *emphasis*. Three regexes over an escaped string.
  //
  // It is also strictly SAFER than what it replaces, which is why defang() is
  // gone rather than kept. The old path injected an html span into a MARKDOWN
  // document, so the prose around it was never escaped and defang() had to name
  // the one tag it feared (`<img`) by hand; anything else the model wrote went
  // straight through Qt's html parser. Here everything is escaped FIRST, so no
  // tag survives to be parsed at all -- and an image the localImage rule
  // rejected stays visible as the literal text someone wrote, instead of being
  // quietly rewritten into a link.
  function prep(t) { return rich(t) }

  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  function rich(src) {
    var codes = []
    // Code spans come out FIRST and go back in LAST, so bold and emphasis
    // cannot reach inside a command: `git commit -m "a *b* c"` keeps its stars.
    // The placeholder is a control character, which cannot occur in an answer
    // and passes through esc() untouched.
    var t = String(src).replace(/`([^`\n]+)`/g, function (m, s) {
      codes.push(s)
      return "\u0001" + (codes.length - 1) + "\u0001"
    })

    t = esc(t)
    // Two stars before one, or `**bold**` matches the emphasis rule twice and
    // comes back as an empty italic wrapped round the word. The emphasis rules
    // want a boundary in front, so a snake_case identifier that escaped the
    // backticks is not silently italicised through its middle.
    // DemiBold, not <b>. Qt's <b> is weight 700 against a body of 400, and at
    // panelBody 19 in Adwaita Sans that is a leap rather than a step -- every
    // model opens every paragraph with `**Something:**`, so a whole answer came
    // back looking like a list of headings. 600 still reads as emphasis and
    // stops shouting.
    t = t.replace(/\*\*([^*\n]+)\*\*/g, "<span style=\"font-weight:600\">$1</span>")
         .replace(/__([^_\n]+)__/g, "<span style=\"font-weight:600\">$1</span>")
         .replace(/(^|[\s(])\*([^*\n]+)\*/g, "$1<i>$2</i>")
         .replace(/(^|[\s(])_([^_\n]+)_(?=[\s.,;:)]|$)/g, "$1<i>$2</i>")
    // A markdown `--` is an em dash and every model writes them. Qt's markdown
    // renderer left them as two hyphens, which at this size reads as a broken
    // word rather than a dash. Code spans are already out of the string, so no
    // flag is at risk.
    t = t.replace(/(\S) -- (?=\S)/g, "$1 — ")
    // Qt's rich text collapses newlines the way html does, so a hard-wrapped
    // answer would come back as one run-on paragraph.
    t = t.replace(/\n{2,}/g, "<br><br>").replace(/\n/g, "<br>")

    t = t.replace(/\u0001(\d+)\u0001/g, function (m, i) {
      return code(codes[Number(i)])
    })
    // Leading. A TextEdit has no lineHeight property the way a Text does, so
    // the one place it can be asked for is the document itself, and a paragraph
    // of technical prose in a narrow column needs the extra quarter-line.
    return "<div style=\"line-height:134%\">" + t + "</div>"
  }

  // One inline code span, at a size and in a face Qt would never have given it.
  //
  // YELLOW, asked for by name after the user saw it: at three pixels down the
  // mono face alone is quiet enough to disappear into the prose, and the colour
  // is what makes a path findable when you are scanning for one.
  //
  // No background. A tinted chip behind each span was tried and rendered:
  // QTextDocument paints an inline background over the whole LINE BOX, so with
  // 134% leading every path becomes a tall block and a bullet list of paths
  // comes back striped.
  function code(s) {
    return "<span style=\"font-family:'" + Style.font.panelMono + "';"
      + "font-size:" + Style.font.panelCode + "px;"
      + "color:" + cssColor(Theme.yellow) + "\">"
      + esc(breakable(s)) + "</span>"
  }

  // ------------------------------------------------------------------ breaks
  // Code has nowhere to break in a narrow column, so Qt breaks it wherever the
  // line ran out -- the user's own screenshot came back with
  // `Text.NativeRendering everywhere, which on a 1.5x-` / `scaled display`, and
  // an identifier cut in half stops being an identifier. Which rule applies is a
  // question of whether the span could ever fit: under 24 characters it always
  // fits a fresh line, so it is HARDENED and word wrap moves the whole span
  // down. Longer, and it has to break somewhere, so it is offered zero-width
  // spaces at its separators.
  function breakable(s) {
    return s.length < 24 ? hard(s) : zwsp(nobr(s))
  }
  // A hyphen is a break Qt takes wherever it finds one: `exec-once` came back as
  // `exec-` / `once`, and a fenced block as `--` / `state=enabled,masked`, a flag
  // cut off its own name. Every hyphen inside code becomes a non-breaking one and
  // the breaks are offered deliberately instead -- by zwsp(), and by the spaces a
  // command already has. hard() goes further and holds a SHORT span whole.
  function nobr(s) { return s.replace(/-/g, "‑") }
  function hard(s) { return nobr(s).replace(/ /g, " ") }

  // A separator with a WORD standing on it, and only when four or more follow:
  // Qt takes the LAST offer that fits, so offering every dot returned
  // `widgets/OriVeil.` / `qml`. The selection handler strips these back out.
  function zwsp(s) { return s.replace(/([^\s-])([./_:@-])(?=\S{4,})/g, "$1$2​") }

  // A QML color as a CSS color string. QML stringifies a color as `#aarrggbb`,
  // which CSS does not read, so it is built as rgba() from the components.
  function cssColor(c) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + ","
      + Math.round(c.b * 255) + "," + c.a + ")"
  }
}
