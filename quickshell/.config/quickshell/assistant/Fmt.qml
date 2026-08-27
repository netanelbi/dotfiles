import QtQuick
import ".."

// The panel's shared formatting: two number formats, the one place that decides
// what in an answer is a picture, and the pass that cuts an answer into blocks.
// The activity rail and every settled turn print a duration and a token count,
// and the two must read identically or the eye stops trusting either. A QtObject
// rather than a singleton; it holds no state, so an instance per delegate is
// free.
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
  // Every piece up to and including the last tool call also carries `aside`.
  // That run is WORK: Ori saying what it is about to do, and then doing it.
  //
  // `streaming` is true while the turn is still being written; `calls` is the
  // turn's tool log, each entry carrying the `at` offset PiSession stamps. The
  // batches are why this takes `calls`: a working turn is speak, run, speak,
  // run, and without the offsets it rendered as one paragraph under one batch
  // line, because the text is one string and the log was a flat list.
  function split(body, streaming, calls) {
    var src = String(body || "")
    var list = calls || []
    var out = []
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

    // Only the tail is still being typed; everything before a tool call was
    // finished the moment the call started.
    scan(out, src.slice(at), streaming)

    // An answer with no text at all still needs one piece, or the turn has
    // nothing to give it height and the list jumps on the first token.
    if (out.length === 0) out.push({ image: false, text: rich(src) })

    // Which of this is work and which is the answer: in an agentic turn the
    // answer is the last thing said, so everything up to and including the final
    // tool call is preamble. Marked here because a delegate knows nothing about
    // the piece after it.
    var last = -1
    for (var j = 0; j < out.length; j++) if (out[j].tool) last = j
    for (var k = 0; k <= last; k++) out[k].aside = true
    return out
  }

  // Where the answer starts, so the delegate can roll everything before it into
  // one line. The whole length while a turn is still all work.
  function answerAt(list) {
    for (var i = 0; i < list.length; i++) if (!list[i].aside) return i
    return list.length
  }

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
      var h = l.match(/^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$/)
      var b = l.match(/^(\s*)(?:([-*+])|(\d+)[.)])\s+(.+)$/)
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
    t = t.replace(/\*\*([^*\n]+)\*\*/g, "<b>$1</b>")
         .replace(/__([^_\n]+)__/g, "<b>$1</b>")
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
