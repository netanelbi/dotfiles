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

    // ------------------------------------------------------------- ambient
    // The two below are the only durations in this file that are allowed past
    // the 320ms ceiling, because they are not state changes: they are motion
    // that runs CONTINUOUSLY while the assistant is working, and at bar speeds
    // a continuous loop reads as an alarm rather than as something alive.
    //
    // One breath of Ori's heartbeat. OriDot animates it as two 700ms halves;
    // the panel drives the same period off a frame clock, so it needs the
    // period as one number rather than as the pair.
    readonly property int breath: 1400
    // One pass of the scan highlight across the panel's activity rail.
    readonly property int scan: 2600
  }


  // ------------------------------------------------------------------- ori
  // The assistant's AMBIENT presence: the readout in the bar and the light
  // that bleeds out from under it. These are tokens rather than literals for a
  // reason the rest of this file does not have -- the readout and the light are
  // two SEPARATE layer surfaces, and a shared period is the only way two
  // surfaces can breathe on the same beat.
  //
  // Everything here is slower than the `anim` block above, deliberately. Every
  // other transition in this bar is a REACTION to something you did and has to
  // land inside 320ms; this is the one thing on screen that is simply alive
  // whether or not you are looking at it, and it should move like breathing,
  // not like UI.
  readonly property QtObject ori: QtObject {
    // One full inhale + exhale of the glyph. Resting human breath is ~4s; this
    // sits just under it, which reads as concentrating rather than asleep.
    readonly property int breathMs: 2600
    // How far the breath dims the glyph. Never to zero: a mark that vanishes
    // reads as a fault, a mark that dims reads as alive. (Kept from the
    // original heartbeat -- it was the one thing about it that was right.)
    readonly property real dotFloor: 0.4
    // The indeterminate scan under the readout. NOT a multiple of breathMs:
    // two incommensurate periods beat against each other and never settle into
    // one predictable pulse, which is the whole difference between something
    // working and something blinking.
    readonly property int scanMs: 1900

    // The light travelling the screen edge, one full round trip (there AND
    // back -- it ping-pongs on a cosine so there is no jump at the ends).
    readonly property int auraSweepMs: 7800
    // The flare when an answer lands. Longer than any bar transition because
    // it is the one moment the desktop is allowed to announce something.
    readonly property int auraFlareMs: 1100
    // Height of the light surface. FIXED, and never animated -- a layer
    // surface that resizes costs a compositor round trip per frame (CLAUDE.md).
    readonly property int auraHeight: 132
    // Alpha at the seam (the bar's underside), and how far the whole thing is
    // turned down to the steady wash left behind while an answer waits unread.
    readonly property real auraCore: 0.30
    readonly property real auraRest: 0.62
    // The travelling pool is BRIGHTER than the seam it rides on, and the seam
    // is turned down while it travels. If the two are the same strength the
    // result reads as one flat translucent sheet with a bit of unevenness in
    // it -- measured, and it was the first version's whole problem.
    readonly property real auraPoolPeak: 0.46
    readonly property real auraSeamWhileTravelling: 0.5
    // Width of the pool. Wide enough that its falloff is gentler than the
    // screen it crosses; a small blob reads as a bug rather than as light.
    readonly property int auraBlobW: 720
    // ...and its vertical radius, as a fraction of the surface height. Just
    // over 1, so the pool is all but gone by the bottom edge and the surface
    // never shows where it ends.
    readonly property real auraBlobFall: 1.05

    // The readout's cells, in px. FIXED widths, so the strip is one width for
    // the whole turn: a tool name changing from "bash" to "read" must not make
    // the entire centre island breathe sideways. Sized for
    // JetBrainsMono at `font.tiny` (~7.2px/char).
    readonly property int toolWidth: 58     // 8 chars, elided past that
    readonly property int timeWidth: 44     // "9m 38s"
    readonly property int countWidth: 44    // "↓ 9.9k"
    readonly property int ctxWidth: 40      // "12.4%"
    readonly property int cellGap: 6
    // The context cell is absent until pi reports a window size, so the strip
    // has TWO settled widths, not one -- but never changes width mid-turn,
    // which is the property that matters.
    readonly property int readoutWidth: toolWidth + timeWidth + countWidth + 2 * cellGap
    readonly property int readoutWidthCtx: readoutWidth + ctxWidth + cellGap
  }
}
