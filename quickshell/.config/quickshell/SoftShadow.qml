import QtQuick
import QtQuick.Effects

// The soft drop shadow (aurora-glass, tonal) or coloured glow (neon-dusk) for
// `target`: HardShadow's v2 sibling. Paints NOTHING when the theme has neither
// (catppuccin, paper, void), so it is safe to drop in unconditionally.
//
// Same usage as HardShadow -- a SIBLING of the target, declared BEFORE it, in a
// parent that is not a positioner:
//
//     SoftShadow { target: card }
//     Rectangle { id: card; ... }
//
// `active` switches a glow to the theme's active colour (the focused card, the
// active workspace). `glowColor` overrides the colour outright; `shown` gates it;
// `blur` overrides the theme's blur.
//
// It draws OUTSIDE the target by up to Theme.shadowPad, so a layer surface
// hosting one must leave that much transparent room around the target (sized
// once, never animated) or the shadow is cut off with a hard edge.
//
// On a translucent theme (glass, neon) the part of the shadow UNDER the target
// is cut out, the way CSS box-shadow is: otherwise a 62%-opaque card shows its
// own shadow through itself and reads as dirty grey. That costs one layer, so
// opaque themes skip it.
Item {
  id: root
  property Item target: null
  property bool active: false
  property color glowColor: active ? Theme.glowActiveColor : Theme.glowColor
  property bool shown: true
  property real blur: Theme.shadowBlurUsed
  property bool cutout: Theme.translucent

  readonly property real offsetY: Theme.hasGlow ? 0 : Theme.softShadowY
  readonly property real pad: Math.ceil(blur + Math.abs(offsetY))
  readonly property real cornerRadius: target && target.radius !== undefined
                                       ? Math.min(target.radius, Math.min(width, height) / 2) : 0

  visible: shown && (Theme.hasSoftShadow || Theme.hasGlow)
           && target !== null && target.visible && target.opacity > 0.01
  x: target ? target.x : 0
  y: target ? target.y : 0
  width: target ? target.width : 0
  height: target ? target.height : 0
  opacity: target ? target.opacity : 0
  scale: target ? target.scale : 1
  transformOrigin: target ? target.transformOrigin : Item.Center

  Item {
    id: box
    x: -root.pad
    y: -root.pad
    width: root.width + 2 * root.pad
    height: root.height + 2 * root.pad

    layer.enabled: root.cutout && root.visible
    layer.effect: MultiEffect {
      maskEnabled: true
      maskInverted: true
      maskSource: hole
    }

    RectangularShadow {
      x: root.pad
      y: root.pad
      width: root.width
      height: root.height
      radius: root.cornerRadius
      blur: root.blur
      offset.y: root.offsetY
      color: Theme.hasGlow ? root.glowColor : Theme.softShadowColor
    }
  }

  // The target's own footprint, in box coordinates: where the shadow is cut.
  Item {
    id: hole
    visible: false
    x: box.x
    y: box.y
    width: box.width
    height: box.height
    layer.enabled: root.cutout && root.visible
    Rectangle {
      x: root.pad
      y: root.pad
      width: root.width
      height: root.height
      radius: root.cornerRadius
      color: "black"
    }
  }
}
