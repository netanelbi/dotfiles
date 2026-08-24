import QtQuick
import "root:/"

// Replaces waybar's `custom/scratchpad`.
//
// config.jsonc:
//   { "exec": "~/.local/bin/hypr-scratchpad-watch", "return-type": "json",
//     "on-click": "~/.local/bin/hypr-scratchpad-toggle",
//     "tooltip-format": "Scratchpad windows\nClick to toggle" }
//
// hypr-scratchpad-watch emits exactly three shapes, and nothing else:
//   count 0             -> {"text": "",       "class": ""}        (module hidden)
//   count N, hidden     -> {"text": "󰝖 N", "class": ""}
//   count N, on screen  -> {"text": "󰝖 N", "class": "active"}
// It never emits a tooltip, so waybar falls back to `tooltip-format`; that
// static string is reproduced below rather than taken from the script.
//
// style.css:
//   #custom-scratchpad        { color: @overlay0; padding: 4px 10px;
//                               border-radius: 8px; border: 2px solid transparent }
//   #custom-scratchpad.active { color: @yellow; font-weight: bold;
//                               border: 2px solid @yellow }
// The inactive border is `2px solid transparent`, not `none` -- the box never
// changes size when it activates, so the border width here is constant too.
//
// MOTION: waybar snaps grey->gold. Here the border and the glyph cross-fade,
// the module slides open from zero width when the first window is stashed
// (BarWidget's reveal), and the counter rolls when the count changes.
ScriptWidget {
  id: root

  script: "~/.local/bin/hypr-scratchpad-watch"
  clickCommand: "~/.local/bin/hypr-scratchpad-toggle"
  tooltip: "Scratchpad windows\nClick to toggle"

  readonly property bool active: hasClass("active")

  // `padding: 4px 10px` + the 2px border, matching the workspace pills beside it.
  horizontalPadding: Style.module.paddingH
  implicitHeight: Style.bar.islandHeight - 4
  radius: Style.module.radius
  borderWidth: Style.module.borderWidth
  borderColor: active ? Theme.attention : Theme.transparent
  // The pill itself is never filled -- only its outline carries the state.
  backgroundColor: Theme.transparent
  hoverHighlight: true

  readonly property color glyphColor: active ? Theme.attention : Theme.inactive

  // An empty scratchpad is `shown: false`, so BarWidget holds this widget at
  // `visible: false` -- and a Row positioner skips children that are not
  // visible. Both Texts below are built during exactly such a frame, and
  // without this the module has been seen to slide open into a blank 20px gap
  // the first time a window is stashed. forceLayout() re-runs the layout;
  // `glyph.parent` is BarWidget's own content Row.
  onVisibleChanged: if (visible) Qt.callLater(root.relayout)
  function relayout() {
    if (glyph.parent && glyph.parent.forceLayout) glyph.parent.forceLayout()
  }

  // If the format ever loses its space, `icon` falls back to the whole string
  // so nothing is lost.
  readonly property string icon: {
    var i = root.text.indexOf(" ")
    return i === -1 ? root.text : root.text.substring(0, i)
  }
  readonly property string count: {
    var i = root.text.indexOf(" ")
    return i === -1 ? "" : root.text.substring(i + 1)
  }

  // The script emits one string, "󰝖 3"; splitting it into two items is what
  // lets the digits animate on their own. The gap must then be exactly the
  // space that was split out, or the module sits a pixel or two off waybar's.
  FontMetrics {
    id: metrics
    font.family: Style.font.family
    font.pixelSize: Style.font.size
  }

  spacing: Math.round(metrics.advanceWidth(" "))

  Text {
    id: glyph
    text: root.icon
    color: root.glyphColor
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    font.weight: root.active ? Style.font.boldWeight : Style.font.normalWeight
    renderType: Text.NativeRendering

    Behavior on color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }

    // A stashed/restored window nudges the glyph, so the change is felt even
    // when the digits are at the edge of vision.
    Connections {
      target: root
      function onCountChanged() { nudge.restart() }
    }
    SequentialAnimation {
      id: nudge
      NumberAnimation { target: glyph; property: "scale"; to: 1.18; duration: Style.anim.quick; easing.type: Style.anim.easing }
      NumberAnimation { target: glyph; property: "scale"; to: 1; duration: Style.anim.normal; easing.type: Style.anim.easingEnter; easing.overshoot: Style.anim.overshoot }
    }
  }

  Text {
    id: counter
    text: root.count
    visible: text !== ""
    color: root.glyphColor
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    font.weight: root.active ? Style.font.boldWeight : Style.font.normalWeight
    renderType: Text.NativeRendering

    Behavior on color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }

    // The digits roll up into place rather than swapping in a single frame.
    onTextChanged: roll.restart()
    SequentialAnimation {
      id: roll
      NumberAnimation { target: counter; property: "y"; from: 5; to: 0; duration: Style.anim.normal; easing.type: Style.anim.easing }
    }
  }
}
