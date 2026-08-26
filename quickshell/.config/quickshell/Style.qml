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
  // style.css's numbers are correct as literals: text-scaling-factor is 1.0 on
  // this machine, so GTK paints waybar's `font-size: 14px` at 14px and Qt
  // matches it directly. (An earlier comment claimed a 1.1667 GTK factor; that
  // was an Omarchy trial's gsettings write, since reset.) One deliberate
  // deviation: the window-title list reads too small at 12px.
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

    // ------------------------------------------------------------- panel
    // The sizes above are BAR sizes, for a 30px strip you glance at. The panel
    // is a surface you READ, so it gets its own set, and the reading size can
    // never shove the bar's geometry around.
    //
    // panelFamily is PROPORTIONAL, unlike `family` (a monospace Nerd Font):
    // prose in a 460px card is far more legible in a sans than in a mono that
    // reads like a terminal, and the mono is kept for commands, tool lines and
    // meta readouts, which is where fixed widths belong. Carlito (Calibri
    // metrics) is the compact, well-hinted sans on this machine.
    readonly property string panelFamily: "Carlito"
    // Ori's ANSWER, and the largest thing on this surface. Question, narration
    // and answer were all 17 and the verdict was "too small or not clear".
    readonly property int panelBody: 18
    // A `## ` heading inside an answer: the SAME size as the body, and bold. Qt
    // renders a markdown h2 at roughly twice the body size, which makes a
    // sub-heading shout louder than the answer it is a part of. Weight says
    // "this labels what follows"; size would say "this matters most", and a
    // heading does not.
    readonly property int panelHead: 18
    // Narration, on the screens that show it: what Ori said about a tool call
    // that has its own line already.
    readonly property int panelAside: 15
    // Rails, receipts, tool lines and code: subordinate to the body but still
    // legible, rather than the bar's 12px -- and a monospace looks a size larger
    // than a proportional face at the same pixel size.
    readonly property int panelMeta: 14
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
    // The only durations in this file allowed past the 320ms ceiling, because
    // they are not state changes: they run CONTINUOUSLY while the assistant
    // works, and at bar speeds a continuous loop reads as an alarm.
    //
    // One breath of Ori's heartbeat. OriDot animates it as two 700ms halves; the
    // panel drives the same period off a frame clock, so it needs one number.
    readonly property int breath: 1400
    // One pass of the scan highlight across the panel's activity rail.
    readonly property int scan: 2600
  }


  // ------------------------------------------------------------------- ori
  // The assistant's presence, and its whole budget: ONE cell in the bar, and one
  // panel that only exists while the pointer is on that cell.
  //
  // This block used to size a wash of light across the top of the screen, and
  // the reason it does not is the governing rule of this design -- twelve
  // variants were rejected for one fault, in the user's own words: "they all
  // share the same issue. its on the main windows and it will bother me on other
  // windows." Ambient light on a working screen is a COST. So the cell stays
  // inside the bar's 30px and the ONE surface that covers a window is the hover
  // panel, there because it was asked for and gone when the pointer leaves.
  //
  // Tokens rather than literals because the cell and the panel are two surfaces
  // that must agree on a period, a tint and a rate -- and everything here is
  // deliberately slower than `anim` above. Every other transition in this bar is
  // a REACTION and has to land inside 320ms; this is the one thing on screen
  // that is simply alive whether or not you are looking, and it should move like
  // breathing, not like UI.
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

    // ------------------------------------------------------- the flow gauge
    // Harvested from OriAura, which is deleted: the aura was the screen-edge wash
    // the user rejected, but the FACT it carried is one nothing else here has --
    // whether Ori is MOVING. A tool call streams no deltas, so the character
    // counter freezes for the whole of a `bash sleep 15` on a healthy process;
    // the gap BETWEEN deltas is the missing number. These three turn that gap
    // into a rate, and the rate drives the scan along the keel instead of a pool
    // across the screen.
    //
    // How long a silence is tolerated before the scan slows: under this, ordinary
    // token gaps and the pause either side of a tool result are not a stall.
    readonly property int flowGraceMs: 2000
    // e-folding time of the slowdown past that grace. ~4s of silence puts the
    // scan at a third rate, ~6s puts it on the floor -- which is roughly the
    // point a person starts wondering whether it is still alive.
    readonly property int flowDecayMs: 1800
    // The floor. A tool call that streams nothing still drifts: stopping dead
    // is what a CRASHED shell should look like, and this is a flow gauge, not a
    // hang detector.
    readonly property real driftRate: 0.10

    // The arrival emphasis. Harvested from OriAura's auraFlareMs, unchanged in
    // value and changed completely in scope: it used to flood the whole screen
    // edge, and it now thickens and overshoots one hairline inside the bar. It
    // is still longer than any bar transition, because it is still the one
    // moment the desktop is allowed to announce something.
    readonly property int arrivalMs: 1100

    // The readout's cells, in px. FIXED widths, so the strip is one width for
    // the whole turn: a tool name changing from "bash" to "read" must not make
    // the cell breathe sideways. Sized for JetBrainsMono at `font.tiny`
    // (~7.2px/char).
    //
    // The count and the context cells are GONE from the bar. They were the two
    // that the hover panel now carries better -- and the panel footer already
    // carried the context percentage all along, so the bar was printing it
    // twice. What is left is the one word and how long it has been doing it.
    readonly property int toolWidth: 58     // 8 chars, elided past that
    readonly property int timeWidth: 44     // "9m 38s"
    readonly property int cellGap: 6
    readonly property int cellReadout: toolWidth + timeWidth + cellGap

    // ---------------------------------------------------------- the unhoused
    // The assistant does not live in an island. It floats in the GAP between the
    // centre and right islands, and nothing else in this bar is unhoused, which
    // is what stops it reading as one more status chip beside the battery.
    //
    // zoneWidth is the EXPANDED footprint, reserved PERMANENTLY: the cell
    // animates inside it, so neither island is ever pushed. Measured off the
    // running bar on eDP-1 (1280 logical): the left island ends at 163, the
    // centre spans 520-773, the right spans 1127-1273, so both gaps are ~355px
    // and 148 + 2x24 leaves ~155 clear. The RIGHT gap, not the left: the left
    // holds the window-title list, replaced wholesale on every workspace switch,
    // while the right changes by a character at a time.
    readonly property int zoneWidth: 148
    readonly property int zoneGap: 24
    // The halo wants the island's full height around a 14px glyph, not the 18px
    // content slot every other widget uses.
    readonly property int haloBox: 22
    // Where the keel runs, measured down from the top of the islandHeight box:
    // 3px under the glyph's foot. Unhoused there is no island floor to align
    // to, so the only honest datum is the mark itself.
    readonly property int keelY: 18
    // The open cell's full extent. The +8 is real padding, not slack: without
    // it the rule's right end landed exactly on the last digit of "1m 04s".
    readonly property int cellFull: haloBox + cellGap + cellReadout + 8

    // ------------------------------------------------------------- the veil
    // The hover panel: the ONE surface allowed to cover the user's windows,
    // because they asked for it by name. No card and no edge -- OriArrival's
    // scrim, which IS harvested from the deleted file, scaled up to carry a
    // block of text.
    //
    // FIXED height, forever, like every layer surface in this shell. The
    // content inside it grows and shrinks between working/unread/idle and that
    // costs no configure/ack; the SURFACE is one size (CLAUDE.md).
    readonly property int veilHeight: 320
    // The block's column, and where the pool's centre sits inside the surface.
    // 512 fits a 58-character question at panelMeta without eliding, which is
    // most of them.
    readonly property int veilBlockWidth: 380
    readonly property int veilBlockY: 12
    // The pool's horizontal radius. Wide and soft: the words have to be legible
    // over an arbitrary window and the only way to buy that without drawing a
    // card is a shadow with no edge anywhere. Its VERTICAL radius and its
    // centre are not tokens -- they follow the block's height, so the shadow is
    // only ever as big as what it shades (see OriVeil's poolRy). The surface
    // itself never moves; only the Shape inside it does.
    readonly property int veilPoolRx: 760
    // Opening is slower than any bar transition: this is not a reaction to a
    // click, it is a surface unfolding over someone's work, and it should look
    // deliberate. Closing is quicker -- a thing you have stopped asking for may
    // not take its time (the screensaver argues the same asymmetry).
    readonly property int veilOpenMs: 260
    readonly property int veilCloseMs: 160
    // The pointer crossing from the cell to the veil passes over no gap at all
    // (the veil's y=0 IS the bar's underside), but a boundary pixel still
    // flickers hover on and off. This is how long the surface survives losing
    // the pointer before it is dropped -- short enough that it never feels
    // sticky, long enough that the seam is not a trap.
    readonly property int veilGraceMs: 140
  }
}
