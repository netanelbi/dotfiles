pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Catppuccin Mocha palette, read at runtime from the waybar stylesheet's
// `@define-color` lines. That file is the single source of truth for colour in
// this shell: edit it and both bars re-theme (the FileView watches for changes,
// so no restart).
//
// The hex literals below are FALLBACKS ONLY, for the case where the stylesheet
// cannot be read. They are the only hardcoded colours allowed anywhere in this
// config -- every widget must go through Theme.
Singleton {
  id: root

  readonly property string home: Quickshell.env("HOME")
  // The repo copy is authoritative; the stow symlink is the fallback so the
  // shell still themes correctly if the dotfiles checkout moves.
  readonly property string primaryPath: home + "/.dotfiles/waybar/.config/waybar/style.css"
  readonly property string fallbackPath: home + "/.config/waybar/style.css"

  // name -> "#rrggbb", filled by parse().
  property var palette: ({})
  readonly property bool loaded: Object.keys(palette).length > 0

  function lookup(name, fallback) {
    var v = palette[name]
    return v === undefined ? fallback : v
  }

  function parse(css) {
    var out = {}
    var re = /@define-color\s+([A-Za-z0-9_-]+)\s+(#[0-9a-fA-F]{3,8})\s*;/g
    var m
    while ((m = re.exec(css)) !== null) out[m[1]] = m[2]
    root.palette = out
  }

  FileView {
    id: cssFile
    path: root.primaryPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parse(text())
    onFileChanged: reload()
    onLoadFailed: {
      if (path !== root.fallbackPath) path = root.fallbackPath
      else console.warn("Theme: no waybar style.css found, using built-in Mocha fallbacks")
    }
  }

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
}
