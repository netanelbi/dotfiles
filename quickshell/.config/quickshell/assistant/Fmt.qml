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
  // its answer, and the panel paints the file where the syntax stood. split()
  // is the half that finds them -- it cuts an answer into an ordered run of
  // pieces, each either a stretch of markdown or one image.
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

  // Whether position `i` is in prose rather than inside a ``` block. Counting
  // the fences before it is enough: they alternate open, close, open, so an odd
  // count means the last one is still open. Asked how it shows a picture, Ori
  // answers with the syntax in a code block, and a picture painted from the
  // middle of its own explanation -- leaving half a fence behind it -- is the
  // one bug this feature was always going to have.
  function prose(src, i) {
    return src.slice(0, i).split("```").length % 2 === 1
  }

  // The answer, as [{ image: false, text }, { image: true, source, alt }, …].
  // `streaming` is true while the turn is still being written.
  function split(body, streaming) {
    var src = String(body || "")

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

    var out = []
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
    // An answer with no text at all still needs one piece, or the turn has
    // nothing to give it height and the list jumps on the first token.
    if (out.length === 0) out.push({ image: false, text: src })
    return out
  }

  // Text between images, minus the blank lines the markdown left behind (the
  // column already spaces the pieces, and a `\n\n` on both sides of a picture
  // spaces it twice) -- and minus its teeth.
  function push(out, text) {
    var t = text.replace(/^\n+|\n+$/g, "")
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
