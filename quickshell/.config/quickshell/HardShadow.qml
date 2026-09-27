import QtQuick

// The neo-brutal hard offset shadow for `target`: the block of
// Theme.shadowColor at (+shadowX, +shadowY) behind it, same size. Paints
// NOTHING when the theme has no shadow (catppuccin), so it is safe to drop in
// unconditionally.
//
// Usage: declare it as a SIBLING of the target, BEFORE it, in a parent that is
// NOT a positioner (Row/Column would lay it out):
//
//     HardShadow { target: card }
//     Rectangle { id: card; ... }
//
// x/y/width/height are the shadow slab's own rectangle and default to the
// target's, offset; override them to stretch the slab (OriVeil does). Only the
// part of the slab NOT under the target is painted -- a right strip and a
// bottom strip that do not overlap each other or the card -- so while the
// card fades (opacity is copied from the target) there is no ink slab behind
// the half-transparent card to show through.
//
// A layer-shell surface that hosts one must be sized to include
// Theme.shadowX/shadowY once, up front (never animated).
Item {
  id: shadow
  property Item target: null
  property real offsetX: Theme.shadowX
  property real offsetY: Theme.shadowY
  property color color: Theme.shadowColor

  visible: Theme.hasShadow && target !== null && target.visible && target.opacity > 0.01
  x: target ? target.x + offsetX : 0
  y: target ? target.y + offsetY : 0
  width: target ? target.width : 0
  height: target ? target.height : 0
  opacity: target ? target.opacity : 0
  scale: target ? target.scale : 1
  transformOrigin: target ? target.transformOrigin : Item.Center

  // The target's right and bottom edges in this item's coordinates.
  readonly property real tRight: target ? target.x + target.width - x : 0
  readonly property real tBottom: target ? target.y + target.height - y : 0

  Rectangle {
    // right strip: full slab height, right of the target
    x: Math.max(0, shadow.tRight)
    width: Math.max(0, shadow.width - x)
    height: shadow.height
    color: shadow.color
    antialiasing: false
  }
  Rectangle {
    // bottom strip: below the target, up to where the right strip starts
    y: Math.max(0, shadow.tBottom)
    width: Math.max(0, Math.min(shadow.width, shadow.tRight))
    height: Math.max(0, shadow.height - y)
    color: shadow.color
    antialiasing: false
  }
}
