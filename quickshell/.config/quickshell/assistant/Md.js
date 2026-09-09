// Md.js — markdown -> Qt rich-text HTML, tuned for the board palette.
// Pure functions; no QML imports. Port of /tmp/md2html.py.
.pragma library

function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

function inline(s) {
  s = esc(s)
  var codes = []
  s = s.replace(/`([^`]+)`/g, function (m, c) {
    codes.push(c)
    return "\x00" + (codes.length - 1) + "\x01"
  })
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>')
  s = s.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
  s = s.replace(/(^|[^*])\*([^*\s][^*]*)\*(?!\*)/g, "$1<i>$2</i>")
  s = s.replace(/\x00(\d+)\x01/g, function (m, n) {
    return "<code style=\"background-color:#11111b; color:#89dceb; font-family:'Adwaita Mono',monospace; font-size:0.86em\">"
      + esc(codes[Number(n)]) + "</code>"
  })
  return s
}

function toHtml(md) {
  var lines = String(md).split("\n")
  var out = []
  var i = 0
  while (i < lines.length) {
    var ln = lines[i]
    if (/^\s*```/.test(ln)) {
      var block = []
      i++
      while (i < lines.length && !/^\s*```/.test(lines[i])) { block.push(lines[i]); i++ }
      i++
      out.push("<pre style=\"background-color:#11111b; color:#cdd6f4;"
        + " font-family:'Adwaita Mono',monospace; font-size:0.86em; margin:10px 0;"
        + " padding:10px; white-space:pre-wrap\">" + esc(block.join("\n")) + "</pre>")
    } else if (/^\|/.test(ln) && i + 1 < lines.length && /^\|[\s:|-]+\|?\s*$/.test(lines[i + 1])) {
      var rows = []
      while (i < lines.length && /^\|/.test(lines[i])) {
        if (!/^\|[\s:|-]+\|?\s*$/.test(lines[i])) {
          var cells = lines[i].replace(/^\||\|$/g, "").split("|")
          for (var c = 0; c < cells.length; c++) cells[c] = cells[c].trim()
          rows.push(cells)
        }
        i++
      }
      var t = "<table width=\"100%\" style=\"margin:10px 0\">"
      for (var r = 0; r < rows.length; r++) {
        var tag = r === 0 ? "th" : "td"
        var style = r === 0
          ? "background-color:#181825; color:#cdd6f4; padding:5px 8px; text-align:left"
          : "color:#bac2de; padding:5px 8px; text-align:left"
        t += "<tr>"
        for (var k = 0; k < rows[r].length; k++) t += "<" + tag + " style=\"" + style + "\">" + inline(rows[r][k]) + "</" + tag + ">"
        t += "</tr>"
      }
      out.push(t + "</table>")
    } else if (/^#{1,6}\s/.test(ln)) {
      var level = ln.length - ln.replace(/^#+\s/, "").length
      var txt = inline(ln.replace(/^#+\s/, "").trim())
      var size = level === 1 ? 24 : level === 2 ? 20 : level === 3 ? 17 : 15
      out.push("<p style=\"margin:16px 0 7px 0\"><span style=\"font-size:"
        + size + "px; font-weight:600; color:#74c7ec\">" + txt + "</span></p>")
      i++
    } else if (/^\s*[-*]\s/.test(ln)) {
      var items = []
      while (i < lines.length && /^\s*[-*]\s/.test(lines[i])) {
        items.push("<li style=\"margin:0 0 5px 0\">" + inline(lines[i].replace(/^\s*[-*]\s/, "")) + "</li>")
        i++
      }
      out.push("<ul style=\"margin:7px 0 9px 0\">" + items.join("") + "</ul>")
    } else if (/^\s*\d+\.\s/.test(ln)) {
      var oitems = []
      while (i < lines.length && /^\s*\d+\.\s/.test(lines[i])) {
        oitems.push("<li style=\"margin:0 0 5px 0\">" + inline(lines[i].replace(/^\s*\d+\.\s/, "")) + "</li>")
        i++
      }
      out.push("<ol style=\"margin:7px 0 9px 0\">" + oitems.join("") + "</ol>")
    } else if (/^-{3,}\s*$/.test(ln)) {
      out.push("<p style=\"margin:12px 0\"><span style=\"color:#45475a\">―――――――</span></p>")
      i++
    } else if (ln.trim() === "") {
      i++
    } else {
      out.push("<p style=\"margin:0 0 9px 0; line-height:150%\">" + inline(ln) + "</p>")
      i++
    }
  }
  return out.join("")
}