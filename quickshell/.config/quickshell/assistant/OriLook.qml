pragma Singleton

import QtQuick
import Quickshell
import ".."

// How Ori's surfaces (panel, transcript, composer, orb, bar cell, veil) wear the
// active theme. Everything here is DERIVED: Theme owns the colours, this only
// decides which of them Ori uses where, so the panel, the orb and the bar cell
// agree without each file re-deriving the same branch.
//
// Catppuccin (no schema-v2 blocks in its theme.json) takes every value this
// file had inline before it existed, so it draws exactly as it always did.
// The v2 themes read theme.json's optional `ori` block:
//
//   question     accent | well | underline   your message: an accent-filled
//                bubble (glass, tonal, neon), a well-coloured one (void), or
//                no fill and an ink underline, set in italic (paper)
//   answer       bubble | rule | plain   the answer: a well bubble with a soft
//                hairline, a 2px accent2 rule down its left (paper), or bare
//                text (void)
//   well         the inner fill (answer bubble, composer, code block); the
//                prototype's --surface2, which is NOT the palette's surface2
//   emphasis     the colour of **bold** in an answer (absent = text colour)
//   inputRadius  the composer's corner (999 = a full pill; absent = bubble)
Singleton {
  id: look

  readonly property bool v2: Theme.v2
  readonly property var ori: Theme.data.ori || ({})

  // ---------------------------------------------------------------- voice
  // The colour of "Ori is working on it" (spines, rails, the busy card edge)
  // and of the orb at rest. Catppuccin: sapphire and mauve. v2: the theme's
  // second voice, which is what the prototype paints the orb in.
  readonly property color busy: v2 ? Theme.accent2 : Theme.sapphire
  readonly property color idle: v2 ? Theme.accent2 : Theme.mauve

  // ------------------------------------------------------------------ card
  readonly property color cardFill: Theme.brutal ? Theme.base
    : v2 ? Theme.surface : Theme.alpha(Theme.base, 0.6)
  readonly property int cardRadius: Theme.radiusOr(12)
  readonly property int cardBorderWidth: Theme.brutal ? Theme.borderWidth
    : v2 ? Theme.outlineWidth : 1
  // Catppuccin lights the whole edge in the state colour. v2 keeps its own
  // hairline and switches to the active hairline (neon: cyan) while busy; an
  // error still says so in red.
  function cardBorder(stateColour, active, failed) {
    if (Theme.brutal) return Theme.borderColor
    if (!v2) return Theme.alpha(stateColour, active ? 0.9 : 0.5)
    if (failed) return Theme.err
    return active ? Theme.outlineActive : Theme.outlineColor
  }
  // The soft light / glow round the card. Not under a translucent card with
  // a plain drop shadow: RectangularShadow fills its interior too, and that
  // shows through the glass as a grey cast.
  readonly property bool cardShadow: v2 && (Theme.hasGlow || (Theme.hasSoftShadow && !Theme.translucent))
  // Transparent room the surface keeps round the card for that shadow.
  readonly property int cardRoom: Math.max(8, cardShadow ? Theme.shadowPad : 0)

  // A rule inside the card (under the header, over the footer). Catppuccin
  // draws its own faint accent line; v2 takes its hairline, or its soft one
  // where it has no outline (void), or nothing at all (tonal).
  readonly property color rule: Theme.hasOutline ? Theme.outlineColor : Theme.outlineSoft
  readonly property int ruleWidth: rule.a > 0 ? 1 : 0

  // ------------------------------------------------------------------ well
  readonly property color well: Theme.css(ori.well, Theme.surfaceInner)
  readonly property color wellBorder: Theme.outlineWidth > 0 ? Theme.outlineSoft : Theme.transparent
  readonly property int wellBorderWidth: wellBorder.a > 0 ? 1 : 0
  // A code block. Inside a bubble answer it would vanish into the well it
  // sits on, so an opaque well (tonal) steps one surface down; a translucent
  // one (glass, neon) just stacks.
  readonly property color codeFill: answerBubble && well.a >= 1 ? Theme.surface1 : well

  // -------------------------------------------------------------- question
  readonly property string question: v2 ? (ori.question || "accent") : ""
  readonly property bool questionFilled: question === "accent" || question === "well"
  readonly property bool questionUnderlined: question === "underline"
  readonly property color questionFill: question === "accent" ? Theme.accent
    : question === "well" ? well : Theme.transparent
  readonly property color questionText: question === "accent" ? Theme.accentInk : Theme.text
  // The small "YOU" over it: onAccent at a lower weight on an accent bubble,
  // else the theme's second voice.
  readonly property color questionLabel: question === "accent" ? Theme.alpha(Theme.accentInk, 0.65)
    : Theme.accent2
  readonly property int bubbleRadius: Theme.bubbleRadiusOr(10)

  // ---------------------------------------------------------------- answer
  readonly property string answer: v2 ? (ori.answer || "bubble") : ""
  readonly property bool answerBubble: answer === "bubble"
  // Catppuccin's spine is always there; paper's rule is its accent2; plain
  // (void) shows the spine only while the answer is being written.
  readonly property color spineSettled: answer === "rule" ? Theme.accent2 : Theme.surface1
  readonly property bool spineAtRest: answer === "" || answer === "rule"

  // ---------------------------------------------------------------- inline
  // **bold** in an answer. Empty = keep the text colour (catppuccin).
  readonly property color emphasis: Theme.css(ori.emphasis, Theme.transparent)
  readonly property bool hasEmphasis: v2 && emphasis.a > 0

  // --------------------------------------------------------------- composer
  function inputRadius(h) {
    if (!v2) return Theme.r(12)
    var r = ori.inputRadius === undefined ? bubbleRadius : ori.inputRadius
    return Math.min(r, 32, h / 2)
  }

  // ------------------------------------------------------------- selection
  // Text selection. Catppuccin: sapphire with base text, as before.
  readonly property color selection: v2 ? Theme.selection : Theme.sapphire
  readonly property color selectionInk: v2 ? Theme.selectionInk : Theme.base
  // A picked row in the pickers (sessions, agents, slash commands).
  // Catppuccin: surface1 under the row's ordinary text colours. Brutal: a
  // yellow chip in ink. v2: the theme's selection, and every text on the row
  // switches to selectionInk (paper's is black with page-coloured text).
  readonly property color rowOnFill: Theme.brutal ? Theme.fillYellow : v2 ? Theme.selection : Theme.surface1
  readonly property bool rowInverts: Theme.brutal || v2
  readonly property color rowOnInk: Theme.brutal ? Theme.onFill : Theme.selectionInk
}
