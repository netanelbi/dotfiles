import QtQuick
import Quickshell
// QUALIFIED ON PURPOSE. This file registers the type `PowerProfile` in the
// `widgets` directory, which would shadow UPower's enum of the same name via
// QML's implicit same-directory import. The alias keeps the two apart.
import Quickshell.Services.UPower as UPowerService
import "root:/"

// Power profile indicator (waybar's `power-profiles-daemon` module).
//
// waybar parity -----------------------------------------------------------
//   config.jsonc  format         "{icon}"
//                 format-icons   performance 󰓅, balanced , power-saver 󰌪
//                 tooltip-format "Power profile: {profile}"
//   style.css     #power-profiles-daemon { padding: 0; margin: 0; color: transparent }
//                 #power-profiles-daemon.performance { color: @red;   margin: 0 4px }
//                 #power-profiles-daemon.power-saver { color: @green; margin: 0 4px }
//   So balanced -- the default -- is deliberately INVISIBLE: the glyph is
//   painted transparent and the module carries no margin. Only the two ends of
//   the range show up. This widget collapses to zero width there instead, which
//   is the same end state with the gap animated shut.
//
// CLICK: waybar's own module cycles the profile through power-profiles-daemon
// directly. That is exactly what must not happen here -- on this machine the
// profile is only half the story. ~/.local/bin/power-profile-cycle also applies
// the per-profile ryzenadj TDP, runs fix-cpu-freq to clear the 2 GHz cap, fires
// the OSD notification and clears /tmp/tdp-state so the TDP indicator resets.
// Calling powerprofilesctl (or writing PowerProfiles.profile, which is the same
// D-Bus call) would silently skip all of it.
//
// Motion ------------------------------------------------------------------
// The indicator slides open from zero width when you leave balanced and closes
// again when you come back, and the glyph pops as it changes. waybar just
// repaints.
BarWidget {
  id: root

  readonly property int profile: UPowerService.PowerProfiles.profile
  readonly property bool performance: profile === UPowerService.PowerProfile.Performance
  readonly property bool powerSaver: profile === UPowerService.PowerProfile.PowerSaver

  // `#power-profiles-daemon { color: transparent }` -- balanced shows nothing.
  shown: performance || powerSaver

  // The last profile that had a glyph, held so the indicator keeps showing what
  // you are leaving while it animates shut instead of flipping to the balanced
  // look on the way out.
  property int lastVisibleProfile: UPowerService.PowerProfile.PowerSaver
  onProfileChanged: if (profile !== UPowerService.PowerProfile.Balanced) lastVisibleProfile = profile
  Component.onCompleted: if (profile !== UPowerService.PowerProfile.Balanced) lastVisibleProfile = profile

  // `margin: 0 4px`, `padding: 0` on the visible states.
  horizontalPadding: 0
  sideMargin: Style.module.indicatorMargin

  // NEVER powerprofilesctl: see the note above.
  clickCommand: "~/.local/bin/power-profile-cycle"

  tooltip: "Power profile: " + (performance ? "performance" : (powerSaver ? "power-saver" : "balanced"))

  Text {
    id: glyph
    text: root.lastVisibleProfile === UPowerService.PowerProfile.Performance ? "󰓅" : "󰌪"
    color: root.lastVisibleProfile === UPowerService.PowerProfile.Performance ? Theme.red : Theme.green
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    renderType: Text.NativeRendering

    Behavior on color {
      ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
    }

    onTextChanged: glyphPop.restart()
    SequentialAnimation {
      id: glyphPop
      NumberAnimation {
        target: glyph; property: "scale"
        from: 0.7; to: 1
        duration: Style.anim.normal
        easing.type: Style.anim.easingEnter
        easing.overshoot: Style.anim.overshoot
      }
    }
  }
}
