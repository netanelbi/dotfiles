import QtQuick
import "root:/"

// #custom-tdp -- waybar's `custom/tdp`, backed unchanged by
// ~/.local/bin/tdp-watch (inotify on /tmp/tdp-state's parent dir; no polling).
//
// config.jsonc  "custom/tdp": { exec, return-type json }  -- no click actions.
// style.css     #custom-tdp         { padding: 0; margin: 0; color: transparent }
//               #custom-tdp.active  { color: @peach; margin: 0 4px; font-size: 11px }
//
// `color: transparent` is waybar's way of hiding the idle module; the script
// backs that up by emitting {"text":"","class":""} whenever no custom TDP is
// set, which is ScriptWidget's collapse condition. Active it emits
// {"text":"24W","tooltip":"Custom TDP: 24W","class":"active"}.
ScriptWidget {
  id: root

  script: "~/.local/bin/tdp-watch"

  // .active { margin: 0 4px } -- as padding, same 8px footprint (see Capslock).
  horizontalPadding: Style.module.indicatorPaddingH

  // No on-click in config.jsonc, so no hover tint; `interactive` stays true
  // only so the "Custom TDP: NNW" tooltip can be raised.
  hoverHighlight: false

  Text {
    id: watts
    text: root.text
    // #custom-tdp.active { color: @peach }
    color: Theme.peach
    font.family: Style.font.family
    // font-size: 11px -- the one module in the bar that is not 14px.
    font.pixelSize: Style.font.tiny
    renderType: Text.NativeRendering

    // MOTION. The wattage only ever changes because the user just ran `tdp` or
    // cycled a power profile, so the number is worth pointing at: waybar swaps
    // the digits in place with no cue at all, this lifts the new value into the
    // slot and fades it up. Same vocabulary as the clock tick in Bar.qml.
    // `watts.text`, not the bare `text`: an unqualified `text` here binds to
    // QQuickText's injected textChanged(text) parameter, which Qt deprecates.
    onTextChanged: if (watts.text !== "") bump.restart()

    ParallelAnimation {
      id: bump
      NumberAnimation {
        target: watts; property: "y"; from: 3; to: 0
        duration: Style.anim.normal; easing.type: Style.anim.easing
      }
      NumberAnimation {
        target: watts; property: "opacity"; from: 0.3; to: 1
        duration: Style.anim.normal; easing.type: Style.anim.easingSmooth
      }
    }
  }
}
