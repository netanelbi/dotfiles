import QtQuick
import Quickshell
import "root:/"

// Network status, backed by the user's own watcher script.
//
// WHY A SCRIPT AND NOT Quickshell.Networking: this machine's wifi is managed by
// IWD. Quickshell 0.3.1's Networking module speaks only to NetworkManager (the
// binary contains exactly one bus name, org.freedesktop.NetworkManager), so it
// sees nothing here. hypr-network-watch is netlink + `iw`, already correct, and
// already knows about band, generation and signal.
//
// waybar parity -----------------------------------------------------------
//   config.jsonc  "custom/network": exec ~/.local/bin/hypr-network-watch,
//                 return-type json, escape false (i.e. pango markup),
//                 on-click       kitty --class impala-popup -e impala
//                 on-click-right nm-connection-editor
//   style.css     #custom-network { color: @teal; min-width: 20px }
//                 #custom-network.disconnected { color: @overlay0 }
//                 (.wifi-6/.wifi-5/.wifi-4 are vestigial: the script has emitted
//                  its colours as inline pango since it grew band/generation
//                  support, and now only ever sets class "", "disconnected" or
//                  "ethernet". Those three rules never match anything.)
//
// The script emits one or two spans:
//   wifi          <span color='#a6e3a1'>󰤨</span><span color='#74c7ec'>₆</span>
//   ethernet      <span color='#94e2d5'>󰈀</span>
//   disconnected  <span color='#6c7086'>󰤭</span>
// so the signal glyph carries the green/yellow ladder and the subscript carries
// the generation colour (mauve 7, sapphire 6, teal 5, overlay0 4/unknown).
//
// Motion ------------------------------------------------------------------
// Rendering the markup as rich text (ScriptWidget.html) would be the two-line
// version, but Qt cannot animate a colour that lives inside a rich-text run:
// every signal change would snap, exactly like waybar. So the two spans are
// parsed out and driven into two fixed Text items whose colour is a real
// property -- the ladder cross-fades, the generation slot slides open and shut,
// and a glyph change pops. Same glyphs, same colours, same order.
ScriptWidget {
  id: root

  script: "~/.local/bin/hypr-network-watch"

  clickCommand: "kitty --class impala-popup -e impala"
  rightClickCommand: "nm-connection-editor"

  // waybar renders the two spans as one uninterrupted label.
  spacing: 0

  // #custom-network { min-width: 20px } -- the content box, so add the padding.
  // style.css's `padding: 0 10px` rule lists `#network` -- waybar's BUILT-IN
  // network module. This bar uses `custom/network`, whose CSS id is
  // `#custom-network`, so that rule never matched it. The only rule that does
  // is:  #custom-network { color: @teal; min-width: 20px; }
  // i.e. NO horizontal padding at all, and a 20px TOTAL min-width (not
  // content+padding). Copying the 10px padding off the dead rule made the
  // widget 43px against waybar's 22.
  horizontalPadding: 0
  minWidth: 20

  readonly property bool disconnected: hasClass("disconnected")

  // -------------------------------------------------------------- markup
  // One entry per <span>, in order: { color, glyph }.
  function parseSegments(markup) {
    var out = []
    var re = /<span\s+color='(#[0-9a-fA-F]{3,8})'>([^<]*)<\/span>/g
    var match
    while ((match = re.exec(markup)) !== null) out.push({ color: match[1], glyph: match[2] })
    return out
  }

  readonly property var segments: parseSegments(text)

  // The colours come from the script at runtime -- they are the exact bytes
  // waybar renders, not literals typed into this file. If the markup ever stops
  // matching (a script rewrite), fall back to the plain text and the stylesheet
  // colour rather than showing nothing.
  readonly property bool parsed: segments.length > 0
  readonly property string primaryGlyph: parsed ? segments[0].glyph : text.replace(/<[^>]*>/g, "")
  readonly property color primaryColor: parsed ? segments[0].color
                                               : (disconnected ? Theme.inactive : Theme.teal)
  readonly property bool hasSecondary: segments.length > 1
  readonly property string secondaryGlyph: hasSecondary ? segments[1].glyph : ""
  readonly property color secondaryColor: hasSecondary ? segments[1].color : Theme.inactive

  // Hold the last subscript and its colour so neither blanks out mid-collapse.
  property string lastSecondaryGlyph: ""
  property color lastSecondaryColor: Theme.inactive
  onSecondaryGlyphChanged: if (secondaryGlyph !== "") lastSecondaryGlyph = secondaryGlyph
  onSecondaryColorChanged: if (hasSecondary) lastSecondaryColor = secondaryColor

  Text {
    id: signalGlyph
    text: root.primaryGlyph
    color: root.primaryColor
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    renderType: Text.NativeRendering

    // The signal ladder (green <-> yellow <-> overlay0) cross-fades.
    Behavior on color {
      ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
    }

    // 󰤟 -> 󰤢 -> 󰤥 -> 󰤨 is a shape change, not a colour change; pop it.
    onTextChanged: signalPop.restart()
    SequentialAnimation {
      id: signalPop
      NumberAnimation {
        target: signalGlyph; property: "scale"
        from: 0.78; to: 1
        duration: Style.anim.normal
        easing.type: Style.anim.easingEnter
        easing.overshoot: Style.anim.overshoot
      }
    }
  }

  // The generation subscript. Absent on ethernet and when disconnected, so it
  // collapses rather than disappearing.
  Item {
    id: generationSlot
    implicitWidth: root.hasSecondary ? generationLabel.implicitWidth : 0
    implicitHeight: generationLabel.implicitHeight
    clip: true
    opacity: root.hasSecondary ? 1 : 0

    Behavior on implicitWidth {
      NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
    }
    Behavior on opacity {
      NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
    }

    Text {
      id: generationLabel
      anchors.verticalCenter: parent.verticalCenter
      text: root.lastSecondaryGlyph
      color: root.lastSecondaryColor
      font.family: Style.font.family
      font.pixelSize: Style.font.size
      renderType: Text.NativeRendering

      Behavior on color {
        ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
      }
    }
  }
}
