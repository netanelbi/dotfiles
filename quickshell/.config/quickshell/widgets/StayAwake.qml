import QtQuick
import "root:/"

// #custom-stay-awake -- waybar's `custom/stay-awake`, backed unchanged by
// ~/.local/bin/stay-awake-watch (gdbus monitor on logind's BlockInhibited; no
// polling), the companion of SUPER+SHIFT+L / ~/.local/bin/stay-awake.
//
// config.jsonc  "custom/stay-awake": { exec, return-type json, escape false,
//                                      on-click "~/.local/bin/stay-awake toggle" }
// style.css     #custom-stay-awake         { padding: 0; margin: 0; color: transparent }
//               #custom-stay-awake.active  { color: @yellow; margin: 0 4px }
//
// Held: {"text":"󰅶","tooltip":"Stay awake ON\nLid close will not suspend\n
// Click to turn off","class":"active"}. Released: {"text":"","tooltip":"","class":""}
// -> ScriptWidget collapses, which is waybar's `color: transparent` idle state.
//
// NOTE the widget deliberately drives the SCRIPT, not Quickshell.Wayland's
// _IdleInhibitor: this toggle is a logind `handle-lid-switch` BLOCK inhibitor
// (a transient systemd unit), not a Wayland idle inhibitor. A zwp_idle_inhibit
// object would suppress hypridle's lock and dpms-off instead -- the exact
// mistake stay-awake's own header warns about.
ScriptWidget {
  id: root

  script: "~/.local/bin/stay-awake-watch"
  // on-click, verbatim from config.jsonc.
  clickCommand: "~/.local/bin/stay-awake toggle"

  // .active { margin: 0 4px } -- as padding, same 8px footprint (see Capslock),
  // and it gives the hover pill something to hug.
  horizontalPadding: Style.module.indicatorPaddingH

  Text {
    id: cup
    text: root.text
    // #custom-stay-awake.active { color: @yellow } -- Theme.attention names
    // exactly this rule.
    color: Theme.attention
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    renderType: Text.NativeRendering
  }

  // MOTION. Taking the inhibitor is a deliberate act (a keybind or a click), so
  // the cup earns an entrance: it pops in behind BarWidget's width reveal, and
  // shrinks away when the inhibitor is dropped. waybar's version blinks into
  // and out of existence with nothing in between.
  NumberAnimation {
    id: brew
    target: cup
    property: "scale"
    from: 0.4
    to: 1
    duration: Style.anim.reveal
    easing.type: Style.anim.easingEnter
    easing.overshoot: Style.anim.overshoot
  }

  onShownChanged: if (shown) brew.restart()
}
