import QtQuick
import ".."

// The panel's shared formatting: two number formats, and the one place that
// decides what in an answer is a picture.
//
// Both the activity rail and every settled answer print a duration and a token
// count, and the two must read identically or the eye stops trusting either.
// A QtObject rather than a singleton because nothing outside this directory
// needs them and this repo keeps singletons for things the whole shell shares;
// it holds no state, so an instance per delegate costs nothing.
QtObject {
  id: fmt

  // Milliseconds, at the precision the number deserves: a tool call that took
  // 340ms should say so, a nine-minute turn should not say 578.4s.
  function duration(ms) {
    if (ms <= 0) return ""
    if (ms < 1000) return Math.round(ms) + "ms"
    var s = ms / 1000
    if (s < 60) return (s < 10 ? s.toFixed(1) : Math.round(s)) + "s"
    var m = Math.floor(s / 60)
    return m + "m " + Math.round(s - m * 60) + "s"
  }

  // Token counts, which get long enough to lose their shape at four digits.
  function tokens(n) {
    if (n < 1000) return String(n)
    return (n / 1000).toFixed(n < 10000 ? 1 : 0) + "k"
  }

  // ------------------------------------------------------------------ images
  // Ori shows a picture by WRITING one: `![the wallpaper](/home/me/x.png)` in
  // its answer, and the panel paints the file where the syntax stood. scan()
  // is the half that finds them -- it cuts a stretch of answer into pieces,
  // each either markdown or one image, for split() to order.
  //
  // localImage() is the half that says no, and it is why this lives in a
  // function rather than inline in the delegate. The target of that markdown is
  // a string the MODEL chose. Rendering `![x](https://…)` would make this
  // laptop fetch whatever it named -- an outbound request nobody asked for,
  // from a text box, on the strength of a token prediction. So the rule is
  // absolute and it fails closed: an absolute LOCAL path or nothing.

  // A markdown target, resolved to a url an Image may load, or "" for
  // everything else.
  function localImage(target) {
    var t = String(target || "").trim()
    if (t === "") return ""
    // Markdown's `<...>` form -- how a path with a space in it is written.
    if (t.charAt(0) === "<" && t.charAt(t.length - 1) === ">") t = t.slice(1, -1).trim()

    if (t.indexOf("file://") === 0) t = decodeURIComponent(t.slice(7))
    else if (t.slice(0, 2) === "~/") t = Theme.home + t.slice(1)

    // Absolute or nothing. This one test rejects every scheme (http, data, even
    // a file:// with a host in it, which decodes to `//host/…`), and it rejects
    // relative paths too -- Ori's cwd is not the panel's, so a bare `shot.png`
    // is a guess about a directory rather than a file.
    if (t.charAt(0) !== "/" || t.charAt(1) === "/") return ""
    if (t.indexOf("://") >= 0 || t.indexOf("\n") >= 0) return ""

    // A `#` or a `?` in a filename would otherwise be read as url syntax and
    // the file would come back missing for no visible reason.
    return "file://" + encodeURI(t).replace(/#/g, "%23").replace(/\?/g, "%3F")
  }

  // ------------------------------------------------------------- attachments
  // The other direction: what the USER sent. A user turn carries its
  // attachments in the `images` role, newline-separated -- and not one of those
  // lines is guaranteed to be a path, which is the whole reason this is a
  // function and not a Repeater over `text.split("\n")`:
  //
  //   ask() with a file      the absolute path. A pasted screenshot is a real
  //                          file under $XDG_RUNTIME_DIR/ori, so it can be
  //                          shown, and it is the case that matters.
  //   ask() with a data URI  the words "pasted image". There never was a file.
  //   a resumed transcript   "(attached image/png)", written by rehydrate():
  //                          a session file carries the BYTES, not the path
  //                          they came from, so the picture cannot be found
  //                          again from disk.
  //
  // The last two are not paintable and must not be dropped either -- they are
  // the only thing left saying the question had a picture in it at all. So they
  // come back as labels and the delegate prints them.
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

  // Whether position `i` is in prose rather than inside a ``` block. Counting
  // the fences before it is enough: they alternate open, close, open, so an odd
  // count means the last one is still open. Asked how it shows a picture, Ori
  // answers with the syntax in a code block, and a picture painted from the
  // middle of its own explanation -- leaving half a fence behind it -- is the
  // one bug this feature was always going to have.
  function prose(src, i) {
    return src.slice(0, i).split("```").length % 2 === 1
  }

  // ------------------------------------------------------------------ order
  // The answer, as an ordered run of pieces:
  //
  //   { image: false, text }              a stretch of markdown
  //   { image: true, source, alt }        one picture
  //   { tool: true, calls, n }            one batch of tool calls, where it ran
  //
  // `streaming` is true while the turn is still being written; `calls` is the
  // turn's tool log, each entry carrying the `at` offset PiSession stamps.
  //
  // The batches are why this takes `calls` at all. A turn doing real work is
  // speak, run, speak, run -- and it rendered as one paragraph with a single
  // batch line above it, because the text is one string and the log was a flat
  // list with no position in it. With the offsets, the answer is cut at them
  // and each batch goes back between the text before it and the text after.
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
    if (out.length === 0) out.push({ image: false, text: src })
    return out
  }

  // The image pass, over one stretch of the answer. Split out of split() when
  // the batches arrived: the batches cut the answer first, and each stretch
  // between them is scanned for pictures on its own.
  //
  // Fence counting is therefore per stretch. That is right for every answer
  // that exists -- a ``` block opening before a tool call and closing after it
  // would be half a code block written, a command run, and the other half
  // written; the model emits a fenced block in one run of deltas.
  function scan(out, src, streaming) {
    // Text arrives token by token, so for a frame or two the tail of the answer
    // is a half-typed `![the wallpaper](/home/ne`. It matches nothing, so left
    // alone it would TYPE ITSELF OUT on screen -- the path crawling across the
    // card and then vanishing when the picture replaces it. Cut the dangling
    // fragment instead and the image simply arrives.
    //
    // Only the last one, only while streaming, and only in prose: on a settled
    // answer an unclosed `![` is text someone meant to write, and hiding it
    // would be the one failure worse than showing the markdown -- silence.
    if (streaming) {
      var open = src.lastIndexOf("![")
      if (open >= 0 && src.indexOf(")", open) < 0 && prose(src, open))
        src = src.slice(0, open)
    }

    // Built per call rather than kept as a property: a /g regex carries its
    // lastIndex between uses, and a shared one would skip half the matches on
    // every second delegate.
    var re = /!\[([^\]\n]*)\]\(([^)\n]*)\)/g
    var at = 0, m
    while ((m = re.exec(src)) !== null) {
      if (!prose(src, m.index)) continue
      var url = localImage(m[2])
      if (url === "") continue     // not local: leave the markdown where it is
      push(out, src.slice(at, m.index))
      out.push({ image: true, source: url, alt: m[1] })
      at = m.index + m[0].length
    }
    push(out, src.slice(at))
  }

  // Text between images, minus the blank lines the markdown left behind (the
  // column already spaces the pieces, and a `\n\n` on both sides of a picture
  // spaces it twice) -- and minus its teeth.
  function push(out, text) {
    var t = text.replace(/^\n+|\n+$/g, "")
    // Nothing but space is nothing. It matters now that a batch can sit at the
    // very start of a turn: the empty-answer placeholder is a single SPACE, and
    // left in it drew an empty line of text under the batch line for the whole
    // of the first tool call. split()'s own guard still puts it back when a
    // piece is all the turn has.
    if (t.replace(/\s/g, "") === "") return
    // Everything OUTSIDE the code fences, and nothing inside them: Text renders
    // a fenced block literally and fetches nothing from it, while rewriting one
    // would print a lie in a code example.
    var parts = t.split("```")
    for (var i = 0; i < parts.length; i += 2) parts[i] = defang(parts[i])
    t = parts.join("```")
    if (t !== "") out.push({ image: false, text: t })
  }

  // A rejected image left as literal markdown is NOT harmless, which was
  // measured the hard way: Text renders markdown images itself, so a leftover
  // `![cat](https://…)` sent the panel to example.com during the very test
  // meant to prove it never would, and drew a broken-image hole where the
  // answer should have been. Demoting the `!` leaves the same words on screen
  // as an ordinary link, and a link is not resolved until it is clicked --
  // which nothing in this panel does.
  //
  // Raw `<img src=…>` is worse: Text takes it for an html block and SWALLOWS
  // the rest of the answer behind it -- measured, three paragraphs after one
  // tag rendered as an empty card. Escaped, the tag shows as the text it is and
  // the answer survives.
  //
  // Only a COMPLETE image gets demoted, not every `![`: a lone one is not an
  // image to Text either, and eating its `!` would quietly rewrite a settled
  // answer that just happened to contain the characters.
  function defang(t) {
    return t.replace(/!\[([^\]\n]*)\]\(/g, "[$1](").replace(/<(\/?img)/gi, "&lt;$1")
  }
}
