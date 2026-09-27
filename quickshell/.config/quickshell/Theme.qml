pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The desktop theme, read at runtime from ~/.config/theme/<name>/theme.json
// (stow package `theme`). <name> comes from ~/.local/state/theme/current, which
// `theme-switch` writes; both files are watched, so a switch re-themes the
// whole shell live with no restart. No state file = catppuccin-mocha.
//
// The hex literals below are FALLBACKS ONLY (Catppuccin Mocha), for the case
// where the theme cannot be read. They are the only hardcoded colours allowed
// anywhere in this config -- every widget must go through Theme.
//
// Colour names are Catppuccin's for every theme, and each one is INK: legible
// as text on `base`. Pastel fills a brutal theme paints chips with live under
// `fill*`, with `onFill` as the text drawn on them.
Singleton {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string defaultName: "catppuccin-mocha"
  readonly property string statePath: home + "/.local/state/theme/current"
  readonly property string themesDir: home + "/.config/theme"

  // The active theme's name, and the parsed theme.json.
  property string name: defaultName
  property var data: ({})
  readonly property bool loaded: data.palette !== undefined

  readonly property var palette: data.palette || ({})
  readonly property var fillMap: data.fill || ({})
  readonly property var shape: data.shape || ({})
  readonly property var fonts: data.font || ({})
  readonly property var desk: data.desk || ({})
  readonly property string label: data.label || name
  readonly property bool dark: data.dark === undefined ? true : data.dark
  // Structural switch: square corners, hard borders, offset shadows, filled
  // chips. Widgets branch on this where the shape (not just colour) differs.
  readonly property bool brutal: data.brutal === true

  function lookup(name, fallback) {
    var v = palette[name]
    return v === undefined ? fallback : v
  }
  function fill(name, fallback) {
    var v = fillMap[name]
    return v === undefined ? fallback : v
  }

  // Re-read both files (theme-switch also pokes this over IPC, for the case
  // where the state file did not exist when the shell started).
  function reload() { stateFile.reload(); themeFile.reload() }

  // Every theme.json in ~/.config/theme, for the picker: [{name,label,dark,swatch}].
  property var available: []
  function refreshAvailable() { listProc.running = true }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: {
      var n = text().trim()
      root.name = n.length > 0 ? n : root.defaultName
    }
    onFileChanged: reload()
    onLoadFailed: root.name = root.defaultName
  }

  FileView {
    id: themeFile
    path: root.themesDir + "/" + root.name + "/theme.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var d = JSON.parse(text())
        if (d && d.palette) root.data = d
      } catch (e) {
        // A half-written file: keep the current theme, the next change event re-reads it.
        console.warn("Theme: " + path + " is not valid JSON yet: " + e)
      }
    }
    onFileChanged: reload()
    onLoadFailed: {
      console.warn("Theme: cannot read " + path + ", keeping " + (root.data.name || "built-in Mocha fallbacks"))
    }
  }

  Process {
    id: listProc
    command: ["sh", "-c", "for f in \"$1\"/*/theme.json; do cat \"$f\"; printf '\\n@@THEME@@\\n'; done", "sh", root.themesDir]
    stdout: StdioCollector {
      onStreamFinished: {
        var out = []
        text.split("@@THEME@@").forEach(function (chunk) {
          chunk = chunk.trim()
          if (!chunk) return
          try {
            var d = JSON.parse(chunk)
            out.push({ name: d.name, label: d.label || d.name, dark: d.dark !== false,
                       brutal: d.brutal === true, swatch: d.swatch || [] })
          } catch (e) { console.warn("Theme: skipping unparsable theme.json: " + e) }
        })
        out.sort(function (a, b) { return a.name === root.defaultName ? -1 : b.name === root.defaultName ? 1 : a.label.localeCompare(b.label) })
        root.available = out
      }
    }
  }
  Component.onCompleted: refreshAvailable()

  // ------------------------------------------------------------ raw palette
  readonly property color base:      lookup("base",      "#1e1e2e")
  readonly property color mantle:    lookup("mantle",    "#181825")
  readonly property color crust:     lookup("crust",     "#11111b")
  readonly property color text:      lookup("text",      "#cdd6f4")
  readonly property color subtext0:  lookup("subtext0",  "#a6adc8")
  readonly property color subtext1:  lookup("subtext1",  "#bac2de")
  readonly property color surface0:  lookup("surface0",  "#313244")
  readonly property color surface1:  lookup("surface1",  "#45475a")
  readonly property color surface2:  lookup("surface2",  "#585b70")
  readonly property color overlay0:  lookup("overlay0",  "#6c7086")
  readonly property color blue:      lookup("blue",      "#89b4fa")
  readonly property color lavender:  lookup("lavender",  "#b4befe")
  readonly property color sapphire:  lookup("sapphire",  "#74c7ec")
  readonly property color sky:       lookup("sky",       "#89dceb")
  readonly property color teal:      lookup("teal",      "#94e2d5")
  readonly property color green:     lookup("green",     "#a6e3a1")
  readonly property color yellow:    lookup("yellow",    "#f9e2af")
  readonly property color peach:     lookup("peach",     "#fab387")
  readonly property color maroon:    lookup("maroon",    "#eba0ac")
  readonly property color red:       lookup("red",       "#f38ba8")
  readonly property color mauve:     lookup("mauve",     "#cba6f7")
  readonly property color pink:      lookup("pink",      "#f5c2e7")
  readonly property color flamingo:  lookup("flamingo",  "#f2cdcd")
  readonly property color rosewater: lookup("rosewater", "#f5e0dc")

  readonly property color transparent: "transparent"

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // ------------------------------------------------------- semantic tokens
  // Named after the waybar rule they mirror, so parity is checkable by eye
  // against style.css.

  // `.modules-left/.modules-center/.modules-right { background: alpha(@base, 0.95) }`
  readonly property color islandBackground: alpha(base, 0.95)
  // `#workspaces button:hover { background: alpha(@surface1, 0.5) }`
  readonly property color hoverBackground: alpha(surface1, 0.5)
  // Default module foreground (`#tray, #language, ... { color: @text }`)
  readonly property color foreground: text
  // Idle / disabled foreground (`#workspaces button`, `#custom-scratchpad`,
  // `#bluetooth.disabled`, `#custom-network.disconnected`, `#pulseaudio.muted`)
  readonly property color inactive: overlay0
  // `#workspaces button.active` outline + `#custom-windows.workspace` glow
  readonly property color accent: mauve
  readonly property color accentAlt: lavender
  // `#custom-scratchpad.active`, `#custom-stay-awake.active`
  readonly property color attention: yellow
  readonly property color urgent: red

  // `tooltip { background: @base; border: 1px solid @surface0 }`
  readonly property color tooltipBackground: base
  readonly property color tooltipBorder: surface0
  readonly property color tooltipText: text

  // ------------------------------------------------------- fills (brutal chips)
  // Pastel surfaces with `onFill` text on top. For catppuccin they equal the ink
  // colours, so nothing that uses them changes the soft look.
  readonly property color fillYellow: fill("yellow", "#f9e2af")
  readonly property color fillRed:    fill("red",    "#f38ba8")
  readonly property color fillGreen:  fill("green",  "#a6e3a1")
  readonly property color fillBlue:   fill("blue",   "#89b4fa")
  readonly property color fillViolet: fill("violet", "#cba6f7")
  readonly property color onFill:     fill("onFill", "#1e1e2e")

  // --------------------------------------------------------------- shape
  // Outline + hard offset shadow for panels/popups/islands. Catppuccin: 0 / none.
  readonly property int   borderWidth: shape.border === undefined ? 0 : shape.border
  readonly property color borderColor: shape.borderColor || "#11111b"
  readonly property int   shadowX: shape.shadowX || 0
  readonly property int   shadowY: shape.shadowY || 0
  readonly property color shadowColor: shape.shadowColor || "#00000000"
  readonly property bool  hasShadow: shadowX !== 0 || shadowY !== 0
  // Multiply every corner radius by this (Style does it for its own tokens).
  readonly property real  radiusScale: shape.radiusScale === undefined ? 1.0 : shape.radiusScale
  function r(px) { return Math.round(px * radiusScale) }

  // ---------------------------------------------------------------- desk
  readonly property color deskBackground: desk.background || base
  readonly property color deskGrid: desk.grid || "transparent"
  readonly property bool  deskHasGrid: !!desk.grid
}
