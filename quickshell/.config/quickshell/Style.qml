pragma Singleton

import QtQuick
import Quickshell

// Structural tokens: geometry, typography and MOTION.
//
// Geometry and type are lifted 1:1 from waybar's style.css / config.jsonc so
// the two bars are pixel-comparable. The `anim` block is the part waybar has
// no equivalent for -- waybar snaps between states with zero animation, and
// every transition in this shell goes through these tokens so the whole bar
// moves with one voice.
Singleton {
  id: root

  // ------------------------------------------------------------------ bar
  // config.jsonc: height 30, margin-top/left/right 2, spacing 0.
  // style.css:    .modules-* { border-radius: 14px; padding: 4px 12px; margin: 2px 0 }
  readonly property QtObject bar: QtObject {
    readonly property int height: 30
    readonly property int marginTop: 2
    readonly property int marginSide: 2
    // margin: 2px 0 on the module boxes -> the island is 4px shorter than the bar.
    readonly property int islandInset: 2
    readonly property int islandHeight: height - 2 * islandInset
    readonly property int islandRadius: 14
    readonly property int islandPaddingH: 12
    readonly property int islandPaddingV: 4
    // Content height inside an island (islandHeight minus the 4px vertical padding).
    readonly property int slotHeight: islandHeight - 2 * islandPaddingV
    // config.jsonc "spacing": 0 -- modules are separated by their own padding.
    readonly property int islandSpacing: 0
  }

  // --------------------------------------------------------------- module
  // Per-module chrome. style.css gives most right-hand modules `padding: 0 10px`,
  // the scratchpad `padding: 4px 10px; border-radius: 8px; border: 2px solid`,
  // and workspace buttons `padding: 4px 8px; border-radius: 8px`.
  readonly property QtObject module: QtObject {
    readonly property int radius: 8
    readonly property int paddingH: 6
    readonly property int paddingV: 4
    readonly property int borderWidth: 2
    // Compact indicators (tdp, stay-awake, capslock, power profile) use
    // `margin: 0 4px` with no padding.
    readonly property int indicatorMargin: 4
    readonly property int indicatorPaddingH: 4
    readonly property int workspacePaddingH: 8
    readonly property int workspaceSpacing: 4
  }

  // ----------------------------------------------------------------- font
  // style.css's numbers are correct as literals: text-scaling-factor is 1.0
  // on this machine, so GTK paints waybar's `font-size: 14px` at 14px and Qt
  // matches it directly.
  //
  // (A previous version of this comment claimed GTK scaled fonts by 1.1667 and
  // sized everything up accordingly. That factor was not the user's setting --
  // an Omarchy trial had written it into gsettings. It has been reset to 1.0.)
  //
  // The one deliberate deviation: the window-title list reads too small at
  // style.css's literal 12px, so it sits at the base size.
  readonly property QtObject font: QtObject {
    readonly property string family: "JetBrainsMono Nerd Font"
    readonly property int size: 14
    readonly property int small: 14    // #custom-windows; 12 read too small
    readonly property int tiny: 12     // #custom-tdp.active
    // style.css has no 13px anywhere -- both inherit the `*` rule.
    readonly property int workspace: size
    readonly property int tooltip: size
    readonly property int normalWeight: Font.Normal
    readonly property int boldWeight: Font.Bold
  }

  // ----------------------------------------------------------------- motion
  // The one axis where this bar must beat waybar. Rules of thumb:
  //   quick  - a colour or opacity nudge that must feel instant (hover).
  //   normal - a state change the eye should follow (active/inactive swap).
  //   reveal - width/height changes: a module appearing or collapsing.
  //   slow   - whole-bar chrome (startup slide, island resize cascades).
  // Nothing exceeds 320ms: past that the bar feels laggy rather than smooth.
  readonly property QtObject anim: QtObject {
    readonly property int quick: 120
    readonly property int normal: 180
    readonly property int reveal: 240
    readonly property int slow: 320

    // Colour transitions read best slightly slower than geometry.
    readonly property int colorDuration: 200
    readonly property int opacityDuration: 160

    // Decelerating: the default for anything that moves or resizes.
    readonly property int easing: Easing.OutCubic
    // For things that appear from nothing -- a hair of overshoot gives the
    // reveal some life without bouncing.
    readonly property int easingEnter: Easing.OutBack
    readonly property real overshoot: 1.15
    // Symmetric, for values that go back and forth (colour, opacity).
    readonly property int easingSmooth: Easing.InOutQuad

    // Hover delay before a tooltip is raised (waybar's is ~500ms).
    readonly property int tooltipDelay: 400
  }
}
