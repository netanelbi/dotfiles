import QtQuick
import "root:/"

// #custom-gamepads -- waybar's `custom/gamepads`, backed unchanged by
// ~/.local/bin/gamepad-watch (udev power_supply uevents + BlueZ Battery1
// PropertiesChanged, funnelled through one FIFO; no polling).
//
// config.jsonc  "custom/gamepads": { exec, return-type json, format "{}",
//                                    escape false, tooltip true,
//                                    on-click-right "~/.local/bin/gamepad-disconnect" }
// style.css     #custom-gamepads         { padding: 0; margin: 0 }
//               #custom-gamepads.active  { margin: 0 6px }
//
// The script emits PANGO markup -- one
// `<span foreground='#rrggbb' weight='bold'>󰊴 62%</span>` per connected pad,
// coloured from that pad's own lightbar RGB -- which is why config.jsonc sets
// `escape: false`. ScriptWidget.html translates those spans to Qt rich text
// (foreground -> color, weight -> font-weight), so the per-pad colours survive.
// Nothing here re-derives a colour: the hex comes from the pad's LEDs.
//
// Idle it emits {"text":"","class":""} -> ScriptWidget collapses the module.
ScriptWidget {
  id: root

  script: "~/.local/bin/gamepad-watch"
  // on-click-right, verbatim from config.jsonc. There is no on-click.
  rightClickCommand: "~/.local/bin/gamepad-disconnect"

  // .active { margin: 0 6px } -- the one module in this group that is 6, not 4.
  // Rendered as padding for the same reason as the rest (identical footprint).
  horizontalPadding: 6

  Text {
    id: pads
    // `html`, not `text`: the payload is pango markup.
    text: root.html
    textFormat: Text.RichText
    // #custom-gamepads sets no colour of its own, so the module inherits the
    // bar's default foreground; every span then overrides it per pad.
    color: Theme.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    renderType: Text.NativeRendering

    // MOTION. Rich text carries its colours inline, so a Behavior cannot tween
    // them -- instead every re-emit (a pad connecting, a battery step, a
    // lightbar colour change) cross-fades the whole strip back up from dim.
    // Combined with BarWidget's width reveal, a pad connecting slides its
    // neighbours aside and fades in rather than teleporting into the island.
    // `pads.text`, not the bare `text`: an unqualified `text` here binds to
    // QQuickText's injected textChanged(text) parameter, which Qt deprecates.
    onTextChanged: if (pads.text !== "") refresh.restart()

    NumberAnimation {
      id: refresh
      target: pads
      property: "opacity"
      from: 0.25
      to: 1
      duration: Style.anim.normal
      easing.type: Style.anim.easingSmooth
    }
  }
}
