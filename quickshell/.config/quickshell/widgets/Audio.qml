import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import "root:/"

// Output volume (waybar's `pulseaudio` module -- the sink one; the `#mic`
// instance lives in the centre group).
//
// waybar parity -----------------------------------------------------------
//   config.jsonc  format         "{icon} {volume}%"
//                 format-muted   "󰖁 muted"
//                 format-icons   default ["󰕿", "󰖀", "󰕾"]
//                 tooltip-format "{desc}"
//                 on-click        kitty --class wiremix-popup -e wiremix -v output
//                 on-click-right  pavucontrol
//                 on-click-middle pamixer -t
//                 on-scroll-up    pamixer -i 5
//                 on-scroll-down  pamixer -d 5
//   style.css     #pulseaudio { color: @mauve; padding: 0 10px }
//                 #pulseaudio.muted { color: @overlay0 }
//
// Volume scale: Pipewire reports 0.5499 where pamixer reports 55, so
// round(volume * 100) is the same integer waybar prints -- verified against
// `pamixer --get-volume` on this machine.
//
// Scroll and mute are applied through Pipewire instead of shelling out to
// pamixer. Same arithmetic (+/-5 points from the displayed percentage, clamped
// to 0..100, exactly what `pamixer -i 5` does), same end state -- but a wheel
// flick no longer forks a process per notch, which is what would make the
// motion below stutter. The two commands that open other programs are run
// verbatim, as waybar does.
//
// Motion ------------------------------------------------------------------
// waybar's label snaps between 󰕿/󰖀/󰕾 and jumps width as the number gains a
// digit. Here the icon pops on every step, mute cross-fades mauve -> overlay0,
// and the label width slides (BarWidget's own Behavior).
BarWidget {
  id: root

  clickCommand: "kitty --class wiremix-popup -e wiremix -v output"
  rightClickCommand: "pavucontrol"

  // waybar always shows this module.
  shown: true

  // Binding a node's volume/mute requires an active tracker; without it
  // Pipewire only reports the node's identity.
  PwObjectTracker { objects: [Pipewire.defaultAudioSink] }

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var sinkAudio: sink ? sink.audio : null
  readonly property bool muted: sinkAudio ? sinkAudio.muted : false
  readonly property int volume: sinkAudio ? Math.round(sinkAudio.volume * 100) : 0

  // waybar's AModule::getIcon: idx = percentage / (100 / icons.size()), with
  // integer division -- 100/3 = 33 -- then clamped to the last icon.
  readonly property var icons: ["󰕿", "󰖀", "󰕾"]
  readonly property string icon: muted ? "󰖁"
      : icons[Math.max(0, Math.min(icons.length - 1, Math.floor(volume / Math.floor(100 / icons.length))))]

  tooltip: sink ? sink.description : ""

  function setVolume(percent) {
    if (!sinkAudio) return
    sinkAudio.volume = Math.max(0, Math.min(100, percent)) / 100
  }

  onScrolledUp: root.setVolume(root.volume + 5)
  onScrolledDown: root.setVolume(root.volume - 5)
  onMiddleClicked: if (root.sinkAudio) root.sinkAudio.muted = !root.sinkAudio.muted

  Text {
    id: glyph
    text: root.icon
    color: root.muted ? Theme.inactive : Theme.mauve
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    renderType: Text.NativeRendering

    Behavior on color {
      ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
    }

    // Every volume step nudges the speaker glyph, so a scroll is felt and not
    // just read.
    Connections {
      target: root
      function onVolumeChanged() { glyphPop.restart() }
      function onMutedChanged() { glyphPop.restart() }
    }

    SequentialAnimation {
      id: glyphPop
      NumberAnimation {
        target: glyph; property: "scale"
        from: 1.22; to: 1
        duration: Style.anim.normal
        easing.type: Style.anim.easing
      }
    }
  }

  Text {
    id: label
    // format-muted is "󰖁 muted"; otherwise "{volume}%".
    text: root.muted ? "muted" : root.volume + "%"
    color: glyph.color
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    renderType: Text.NativeRendering

    Behavior on color {
      ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
    }

    // The number changes far more often than the icon; a 2px lift is enough to
    // register the change without drawing the eye away from the rest of the bar.
    onTextChanged: labelTick.restart()
    SequentialAnimation {
      id: labelTick
      NumberAnimation {
        target: label; property: "y"
        from: 2; to: 0
        duration: Style.anim.quick
        easing.type: Style.anim.easing
      }
    }
  }
}
