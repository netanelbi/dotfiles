import QtQuick
import Quickshell.Services.Pipewire
import "root:/"

// #pulseaudio (the `pulseaudio#mic` instance) -- waybar's microphone indicator.
// There is no watcher script for this one either, so it runs on Quickshell's
// PipeWire service: property changes, no polling, no `pactl subscribe` child.
//
// config.jsonc  "pulseaudio#mic": { format "{format_source}",
//                                   format-source "",  format-source-muted "󰍭",
//                                   tooltip-format "Mic: {source_desc}",
//                                   on-click "pamixer --default-source -t" }
// style.css     #pulseaudio { color: @mauve; padding: 0 10px }
//
// READ format-source AGAIN: it is the EMPTY STRING. waybar therefore renders
// NOTHING while the microphone is live, and only paints 󰍭 once the default
// source is muted. This widget is a mute indicator, not a mic indicator -- an
// easy detail to get backwards, and getting it backwards would leave a glyph
// sitting in the island that waybar never shows.
//
// COLOUR: style.css only ever gives #pulseaudio @mauve. Its `.muted` -> @overlay0
// rule does NOT fire for a muted microphone -- waybar sets `muted` from the
// SINK and `source-muted` from the source, and `source-muted` is unstyled -- so
// the muted mic glyph is mauve in the running bar, and mauve here. (The one
// case where waybar greys it, speakers muted too, is an artifact of the two
// module instances sharing an id; it is not reproduced.)
BarWidget {
  id: root

  readonly property PwNode source: Pipewire.defaultAudioSource
  readonly property bool muted: source !== null && source.audio !== null && source.audio.muted

  // format-source is "" -- the module exists only in the muted state.
  shown: muted
  // padding: 0 10px, from the shared right-modules rule.
  horizontalPadding: Style.module.paddingH

  // tooltip-format: "Mic: {source_desc}"
  tooltip: source === null ? "" : "Mic: " + (source.description !== "" ? source.description : source.name)

  // on-click was `pamixer --default-source -t`, i.e. toggle the default source's
  // mute. Done through the same PipeWire node the widget already reads instead
  // of shelling out: identical effect, no process spawn, and the icon reacts on
  // the property change rather than on a subprocess round trip.
  onClicked: if (source !== null && source.audio !== null)
    source.audio.muted = !source.audio.muted

  // Quickshell only keeps a node's `audio` block live while something tracks it.
  PwObjectTracker {
    objects: [Pipewire.defaultAudioSource]
  }

  Text {
    id: icon
    // format-source-muted, verbatim.
    text: "󰍭"
    // #pulseaudio { color: @mauve }
    color: Theme.mauve
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    renderType: Text.NativeRendering
  }

  // MOTION. Two layers, both absent from waybar:
  //
  //   entrance -- muting pops the glyph in over BarWidget's width reveal, so
  //               the island opens up for it instead of the neighbours jumping
  //               sideways; unmuting collapses it back out.
  //   breathe  -- while the mic stays muted the glyph breathes, slowly. A muted
  //               microphone is a state you can forget you are in and then talk
  //               into for a minute, so it keeps asking for attention rather
  //               than sitting there like every other icon. style.css already
  //               uses exactly this idea (`#battery.critical { animation: blink }`)
  //               for its one other persistent-hazard state.
  //
  // The period is derived from Style.anim.slow so it still moves with the rest
  // of the bar; it is four times slower because it is an ambient loop, not a
  // state transition, and anything near transition speed reads as a fault light.
  NumberAnimation {
    id: entrance
    target: icon
    property: "scale"
    from: 0.4
    to: 1
    duration: Style.anim.reveal
    easing.type: Style.anim.easingEnter
    easing.overshoot: Style.anim.overshoot
  }

  SequentialAnimation {
    id: breathe
    loops: Animation.Infinite

    NumberAnimation {
      target: icon; property: "opacity"; to: 0.55
      duration: Style.anim.slow * 4; easing.type: Style.anim.easingSmooth
    }
    NumberAnimation {
      target: icon; property: "opacity"; to: 1
      duration: Style.anim.slow * 4; easing.type: Style.anim.easingSmooth
    }
  }

  onShownChanged: {
    if (shown) {
      entrance.restart();
      breathe.restart();
    } else {
      // Stop mid-cycle and hand `opacity` back, so the next mute starts opaque.
      breathe.stop();
      icon.opacity = 1;
    }
  }
}
