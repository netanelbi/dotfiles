pragma Singleton

import QtQuick
import Quickshell
import ".."

// The control room's few tokens. Everything is Theme-derived; this file only
// fixes the ROLES, so the six tabs speak one language:
//
//   who owns a sound -- the colour of a mode is the orb's colour for it, so
//   the panel and the creature never disagree: listening sapphire, hearing
//   sky, thinking blue, speaking lavender, ignored yellow, closed grey.
Singleton {
  id: look

  // ------------------------------------------------------------------ type
  readonly property string sans: Style.font.panelFamily
  readonly property string mono: Style.font.panelMono
  readonly property int hero: 26      // the call's state word
  readonly property int title: 16     // a worker's name, a section's lead
  readonly property int body: 15      // transcript and prose
  readonly property int meta: 13      // secondary lines, buttons
  readonly property int small: 12     // numbers under things, hints

  // --------------------------------------------------------------- colour
  function modeColor(mode) {
    switch (String(mode)) {
    case "listening": return Theme.sapphire
    case "hearing": return Theme.sky
    case "thinking": return Theme.blue
    case "speaking": return Theme.lavender
    case "ignored": return Theme.yellow
    case "offline": return Theme.overlay0
    default: return Theme.overlay0
    }
  }
  function modeWord(mode) {
    switch (String(mode)) {
    case "listening": return "Listening"
    case "hearing": return "Hearing you"
    case "thinking": return "Thinking"
    case "speaking": return "Speaking"
    case "ignored": return "Ignoring that"
    case "offline": return "Voice is off"
    default: return "No call"
    }
  }
  // The orb's own vocabulary (Orb.qml) for a daemon mode.
  function orbMode(mode) {
    switch (String(mode)) {
    case "listening": case "hearing": case "ignored": return "listening"
    case "thinking": return "thinking"
    case "speaking": return "speaking"
    default: return "idle"
    }
  }

  // Worker / task state -> colour.
  function stateColor(s) {
    switch (String(s)) {
    case "needs_input": case "waiting": case "blocked": case "question": return Theme.peach
    case "working": case "running": case "busy": case "start": return Theme.blue
    case "idle": return Theme.teal
    case "done": return Theme.green
    case "error": case "failed": return Theme.red
    default: return Theme.overlay0
    }
  }
  function stateWord(s) {
    switch (String(s)) {
    case "needs_input": case "question": return "needs you"
    case "start": return "running"
    default: return String(s)
    }
  }

  // Ori driving your apps (computer use): the one alarm colour in the room.
  readonly property color drive: Theme.red

  // Note tones in the transcript.
  function toneColor(tone) {
    switch (String(tone)) {
    case "voiceid": return Theme.red
    case "cut": return Theme.peach
    case "barge": return Theme.lavender
    case "ignored": return Theme.yellow
    default: return Theme.overlay0
    }
  }

  // Raised surfaces inside the glass card: a little lighter than the card,
  // never a second card (no shadow, no border by default).
  readonly property color well: Theme.brutal ? Theme.mantle : Theme.alpha(Theme.crust, 0.38)
  readonly property color raised: Theme.brutal ? Theme.surface0 : Theme.alpha(Theme.surface0, 0.42)
  readonly property color hairline: Theme.brutal ? Theme.borderColor : Theme.alpha(Theme.overlay0, 0.22)
  readonly property int radius: Theme.r(8)

  function ms(v) {
    if (v === undefined || v === null || v < 0) return "–"
    return v >= 1000 ? (v / 1000).toFixed(2) + " s" : Math.round(v) + " ms"
  }
  function ago(ms) {
    var s = Math.max(0, Math.round(ms / 1000))
    if (s < 60) return s + "s"
    var mn = Math.floor(s / 60)
    if (mn < 60) return mn + "m " + (s % 60 < 10 ? "0" : "") + (s % 60) + "s"
    return Math.floor(mn / 60) + "h " + (mn % 60) + "m"
  }
  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }
}
