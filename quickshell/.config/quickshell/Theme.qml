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
  // Brutal islands are opaque cream/ink blocks, not a 95% wash.
  readonly property color islandBackground: brutal ? base : alpha(base, 0.95)
  // `#workspaces button:hover { background: alpha(@surface1, 0.5) }`
  readonly property color hoverBackground: alpha(surface1, 0.5)
  // Default module foreground (`#tray, #language, ... { color: @text }`)
  readonly property color foreground: text
  // Idle / disabled foreground (`#workspaces button`, `#custom-scratchpad`,
  // `#bluetooth.disabled`, `#custom-network.disconnected`, `#pulseaudio.muted`)
  readonly property color inactive: overlay0
  // `#workspaces button.active` outline + `#custom-windows.workspace` glow
  readonly property color accent: role("accent", mauve)
  readonly property color accentAlt: lavender
  // `#custom-scratchpad.active`, `#custom-stay-awake.active`
  readonly property color attention: yellow
  readonly property color urgent: red

  // `tooltip { background: @base; border: 1px solid @surface0 }`
  // v2: the theme's surface and hairline (paper: ink 1px; tonal: none).
  readonly property color tooltipBackground: data.bar !== undefined ? alpha(base, Math.max(surfaceOpacity, 0.9)) : base
  readonly property color tooltipBorder: brutal ? borderColor : (data.bar !== undefined ? outlineColor : surface0)
  readonly property color tooltipText: text
  readonly property int   tooltipBorderWidth: brutal ? chipBorder : (data.bar !== undefined ? outlineWidth : 1)

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

  // Chrome helpers: a panel/card/popup keeps its own border in catppuccin
  // (`def`), and takes the theme's hard ink outline in brutal.
  // v2 themes take their hairline outline (see panelBorderOr below).
  function frameColor(def) { return brutal ? borderColor : (data.bar !== undefined ? outlineColor : def) }
  function frameWidth(def) { return brutal ? borderWidth : (data.bar !== undefined ? outlineWidth : def) }
  // Chips/buttons/inner boxes: one pixel lighter than the panel outline
  // (the mockup's `calc(var(--bw) - 1px)`). 0 in catppuccin.
  readonly property int chipBorder: brutal ? Math.max(1, borderWidth - 1) : 0
  // Ink block (the mockup's clock): text colour as a fill, base as its text.
  readonly property color inkFill: text
  readonly property color onInk: base

  // Pango colours baked into shell scripts are Catppuccin Mocha hex. Map one
  // to the SAME-named colour of the active theme (identity in catppuccin).
  readonly property var mochaNames: ({
    "#1e1e2e": "base", "#181825": "mantle", "#11111b": "crust", "#cdd6f4": "text",
    "#a6adc8": "subtext0", "#bac2de": "subtext1", "#313244": "surface0", "#45475a": "surface1",
    "#585b70": "surface2", "#6c7086": "overlay0", "#89b4fa": "blue", "#b4befe": "lavender",
    "#74c7ec": "sapphire", "#89dceb": "sky", "#94e2d5": "teal", "#a6e3a1": "green",
    "#f9e2af": "yellow", "#fab387": "peach", "#eba0ac": "maroon", "#f38ba8": "red",
    "#cba6f7": "mauve", "#f5c2e7": "pink", "#f2cdcd": "flamingo", "#f5e0dc": "rosewater"
  })
  function fromMocha(hex) {
    var n = mochaNames[String(hex).toLowerCase()]
    return n === undefined ? hex : lookup(n, hex)
  }

  // ------------------------------------------------ wallpaper weather art
  // The live-weather effects drawn over the PHOTO wallpaper. Only catppuccin
  // shows the photo (brutal themes draw the flat desk instead), so these are
  // fixed art colours, not palette entries.
  readonly property color weatherCloud: "#1e2030"
  readonly property color weatherNight: "#0b0b14"
  readonly property color weatherSnow:  "#e8eefc"
  readonly property color weatherRain:  "#a6c8e8"
  readonly property color weatherFog:   "#c8d3e8"
  readonly property color weatherFlash: "#dce6ff"

  // ---------------------------------------------------------------- desk
  readonly property color deskBackground: desk.background || base
  readonly property color deskGrid: desk.grid || "transparent"
  readonly property bool  deskHasGrid: !!desk.grid
  // photo = catppuccin's live photo wallpaper; image = the theme dir's own
  // picture (desk.image); flat = deskBackground (+ grid). Brutal themes without
  // a mode keep their flat desk.
  readonly property string deskMode: desk.mode || (brutal ? "flat" : "photo")
  readonly property string deskImage: desk.image ? themesDir + "/" + name + "/" + desk.image : ""

  // =========================================================== schema v2
  // Structural tokens for the five themes after catppuccin (see the theme.json
  // blocks roles/surface/shape/bar/font). Every one defaults to what catppuccin
  // draws today, so a theme.json without the block changes nothing.
  //
  // theme.json colours are CSS-ordered `#rrggbbaa`; QML's colour parser reads an
  // 8-digit hex as `#aarrggbb`. ALWAYS go through css() for theme.json values.
  function css(v, fallback) {
    if (v === undefined || v === null || v === "") return fallback
    var s = String(v)
    if (s.length === 9 && s[0] === "#") return "#" + s.substr(7, 2) + s.substr(1, 6)
    return s
  }
  readonly property var roles: data.roles || ({})
  readonly property var surfaceData: data.surface || ({})
  readonly property var barData: data.bar || ({})
  readonly property var clockData: barData.clock || ({})
  function role(k, fallback) { return css(roles[k], fallback) }

  // ---------------------------------------------------------------- roles
  // accent2 is the theme's second voice: paper's ink red, void's coral, neon's
  // cyan. focus marks the focused thing (window, workspace underline, veil edge).
  readonly property color accent2:     role("accent2", lavender)
  readonly property color accentInk:    role("onAccent", base)
  readonly property color focus:       role("focus", mauve)
  readonly property color selection:   role("selection", "#574a82")
  readonly property color selectionInk: role("onSelection", text)
  readonly property color container:   role("container", surface0)
  readonly property color containerInk: role("onContainer", text)
  readonly property color ok:          role("ok", green)
  readonly property color okBackground:   role("okBg", alpha(green, 0.15))
  readonly property color warn:        role("warn", yellow)
  readonly property color warnBackground: role("warnBg", alpha(yellow, 0.15))
  readonly property color err:         role("err", red)
  readonly property color hover:       role("hover", alpha(surface1, 0.5))

  // -------------------------------------------------------------- surface
  // Panel/popup/card fill. opacity < 1 = glass: the compositor blurs what is
  // under it (Hyprland layer rules in the theme's hypr.lua).
  readonly property real  surfaceOpacity: surfaceData.opacity === undefined ? 1.0 : surfaceData.opacity
  readonly property bool  translucent: surfaceOpacity < 1.0
  readonly property bool  surfaceBlur: surfaceData.blur === true
  // `base` at the theme's surface opacity: the one fill every panel should use.
  readonly property color surface: alpha(base, surfaceOpacity)
  readonly property color surfaceRaised: alpha(mantle, Math.min(1, surfaceOpacity + 0.08))

  // ---------------------------------------------------------------- shape
  // Absolute radii (px), NOT multiplied by radiusScale. -1 = "not set", use
  // the widget's own catppuccin radius through r().
  readonly property int radius:       shape.radius === undefined ? -1 : shape.radius
  readonly property int chipRadius:   shape.chipRadius === undefined ? -1 : shape.chipRadius
  readonly property int bubbleRadius: shape.bubbleRadius === undefined ? -1 : shape.bubbleRadius
  function radiusOr(def) { return radius >= 0 ? radius : r(def) }
  function chipRadiusOr(def) { return chipRadius >= 0 ? chipRadius : r(def) }
  function bubbleRadiusOr(def) { return bubbleRadius >= 0 ? bubbleRadius : r(def) }
  // Hairline outlines for non-brutal themes (paper: ink 1px; glass: white 22%;
  // neon: pink 55%). borderWidth above stays the brutal outline width.
  readonly property int   outlineWidth: shape.border === undefined ? 0 : shape.border
  readonly property color outlineColor: css(shape.borderColor, "transparent")
  readonly property color outlineActive: css(shape.borderActive, outlineColor)
  readonly property color outlineSoft: css(shape.borderSoft, surface0)
  readonly property bool  hasOutline: outlineWidth > 0 && outlineColor.a > 0
  // Soft drop shadow (glass, tonal) and coloured glow (neon), for
  // MultiEffect/RectangularShadow. null in theme.json = none.
  readonly property var   softShadowData: shape.softShadow || null
  readonly property bool  hasSoftShadow: softShadowData !== null
  readonly property int   softShadowY: softShadowData ? (softShadowData.y || 0) : 0
  readonly property int   softShadowBlur: softShadowData ? (softShadowData.blur || 0) : 0
  readonly property color softShadowColor: softShadowData ? css(softShadowData.color, "#40000000") : "transparent"
  readonly property var   glowData: shape.glow || null
  readonly property bool  hasGlow: glowData !== null
  readonly property int   glowRadius: glowData ? (glowData.radius || 0) : 0
  readonly property color glowColor: glowData ? css(glowData.color, accent) : "transparent"
  readonly property color glowActiveColor: glowData ? css(glowData.activeColor, glowColor) : "transparent"

  // ------------------------------------------------------------------ bar
  // islands (catppuccin, tonal) | strip: one floating rounded bar (glass,
  // neon) | flat: edge to edge + bottom hairline (paper) | bare: nothing
  // behind the widgets (void).
  readonly property string barMode: barData.mode || "islands"
  readonly property int    barHeight: barData.height || (brutal ? 36 : 30)
  readonly property int    barMargin: barData.margin === undefined ? 2 : barData.margin
  readonly property int    barRadius: barData.radius === undefined ? r(14) : barData.radius
  readonly property color  barBackground: css(barData.background, islandBackground)
  readonly property color  barBorder: css(barData.border, "transparent")
  readonly property color  barHairline: css(barData.hairline, "transparent")
  // pills (catppuccin) | underline (paper) | dots (void)
  readonly property string workspaceStyle: barData.workspaces || "pills"

  // The bar clock. Catppuccin: plain text in the bar face; brutal: ink block.
  readonly property color  clockBackground: css(clockData.bg, brutal ? inkFill : "transparent")
  readonly property color  clockForeground: css(clockData.fg, brutal ? onInk : text)
  readonly property string clockFont: clockData.font || ""
  readonly property int    clockWeight: clockData.weight || 0
  readonly property bool   clockItalic: clockData.italic === true
  readonly property int    clockSize: clockData.size || 0
  readonly property real   clockLetterSpacing: clockData.letterSpacing || 0
  readonly property color  clockGlow: css(clockData.glow, "transparent")
  readonly property bool   clockHasGlow: clockGlow.a > 0

  // ---------------------------------------------------------------- fonts
  readonly property string monoFont: fonts.mono || fonts.bar || "JetBrainsMono Nerd Font"

  // ======================================================== shell chrome (v2)
  // Owned by the bar/popups/launchers side (not Ori). Derived from the schema-v2
  // tokens above; every one reduces to catppuccin's current look when the
  // theme.json has no `bar` block.
  //
  // v2: the theme describes its own structure (bar/shape blocks). Catppuccin
  // does not, and that is what keeps it byte-for-byte as it was.
  readonly property bool v2: data.bar !== undefined
  // Hairline outline on panels/popups/cards: the brutal ink outline, the v2
  // hairline (paper ink, glass white, neon pink), or the widget's own default.
  readonly property int   panelBorderWidth: brutal ? borderWidth : (v2 ? outlineWidth : -1)
  function panelBorderOr(def) { return panelBorderWidth >= 0 ? panelBorderWidth : def }
  function panelBorderColorOr(def) { return brutal ? borderColor : (v2 ? outlineColor : def) }
  // Inner boxes (inputs, rows, chips) inside a panel: the soft hairline.
  function softBorderOr(def) { return v2 ? (outlineWidth > 0 ? outlineSoft : "transparent") : def }
  // The panel fill: `surface` (translucent on glass/neon) in v2, else `def`.
  function surfaceOr(def) { return v2 ? surface : def }
  // A raised inner fill (input box, code block, selected row base).
  readonly property color surfaceInner: v2 ? (translucent ? alpha(text, 0.08) : mantle) : surface0
  // Dim-behind-a-modal. Catppuccin: crust at 45%. A light theme's crust is
  // light, so it darkens with its ink instead.
  readonly property color scrim: dark ? alpha(crust, 0.45) : alpha(text, 0.22)
  // Selection highlight (list rows): v2 selection role, else `def`.
  function selectionOr(def) { return v2 ? selection : def }
  function selectionInkOr(def) { return v2 ? selectionInk : def }
  // Anything drawn with a soft shadow or glow needs this much transparent room
  // around it inside its layer surface (0 = none; catppuccin). The blur is
  // capped so a popup does not carry a 50px invisible frame.
  readonly property int shadowBlurUsed: hasGlow ? Math.min(glowRadius, 24) : (hasSoftShadow ? Math.min(softShadowBlur, 24) : 0)
  readonly property int shadowPad: hasGlow || hasSoftShadow ? shadowBlurUsed + Math.abs(softShadowY) : 0

  // ------------------------------------------------------------ bar chrome
  // Clock pill corner: full round on a pill theme (tonal radius 999).
  readonly property bool barRound: barRadius >= 999
  // Inner horizontal padding of a strip/flat/bare bar (islands have their own).
  readonly property int barEdgePadding: barMode === "flat" ? 6 : (barMode === "bare" ? 4 : 0)
  // Workspace pills: v2 themes FILL the active one (accent, onAccent text);
  // catppuccin outlines it.
  readonly property bool workspaceFilled: v2 && workspaceStyle === "pills"
}
