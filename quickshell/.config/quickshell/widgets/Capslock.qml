import QtQuick
import "root:/"

// #custom-capslock -- waybar's `custom/capslock`, backed unchanged by
// ~/.local/bin/hypr-capslock-watch (evtest on the LED_CAPSL event; no polling).
//
// config.jsonc  "custom/capslock": { exec, return-type json, tooltip true }
//               -- no on-click of any kind.
// style.css     #custom-capslock     { padding: 0; margin: 0 }
//               #custom-capslock.on  { color: @red; font-weight: bold; margin: 0 4px }
//
// The script emits {"text":"󰪛","class":"on","tooltip":"Caps Lock ON"} while the
// LED is lit and {"text":"","class":"off",...} otherwise, so ScriptWidget's
// default collapse rule (text === "") IS waybar's off state: waybar paints the
// module away, this one animates its width to zero on the way out.
ScriptWidget {
  id: root

  script: "~/.local/bin/hypr-capslock-watch"

  // style.css gives the lit state `margin: 0 4px`. Rendered as padding instead
  // of an outer gap: identical 8px footprint, and the box stays centred on the
  // glyph. The unlit state has margin 0, which falls out of the collapse.
  horizontalPadding: Style.module.indicatorPaddingH

  // waybar defines no :hover for this module and it has no click action -- but
  // BarWidget's MouseArea must stay ENABLED or the "Caps Lock ON" tooltip never
  // fires, so `interactive` stays true and only the hover tint is dropped.
  hoverHighlight: false

  Text {
    id: glyph
    text: root.text
    // #custom-capslock.on { color: @red } -- Theme.urgent is that red.
    color: Theme.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    // font-weight: bold
    font.weight: Style.font.boldWeight
    renderType: Text.NativeRendering
  }

  // MOTION. Caps Lock coming on is the one genuinely startling state in this
  // group, and waybar just makes the glyph exist. Here it snaps in with a
  // single restrained overshoot on top of BarWidget's width reveal, so the eye
  // is caught once and then left alone -- no looping blink to live with.
  NumberAnimation {
    id: alert
    target: glyph
    property: "scale"
    from: 0.5
    to: 1
    duration: Style.anim.reveal
    easing.type: Style.anim.easingEnter
    easing.overshoot: Style.anim.overshoot
  }

  onShownChanged: if (shown) alert.restart()
}
