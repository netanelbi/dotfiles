import QtQuick
import Quickshell.Wayland
import Quickshell.Widgets
// Theme/Style are singletons in the config root; a subdirectory does not get
// the root's implicit import, so pull it in explicitly.
import ".."

// One option in the picker: a live thumbnail with a small label under it.
//
// `source` is whatever ScreencopyView can capture -- a ShellScreen for the
// Screens tab, a Wayland Toplevel for the Windows tab. The two take different
// routes underneath (wlr-screencopy for an output, hyprland-toplevel-export
// for a window) but the item is the same, so this file does not care which.
//
// ------------------------------------------------------------------ design
// The thumbnail IS the interface. The stock picker fails because it makes you
// read "Screen 0 at 1920, 0 (1280x800) (eDP-1)"; reproducing that as small
// previews under big type would fail the same way. So the preview takes every
// pixel the cell can spare and the name sits under it at the smallest size in
// Style, told apart from the title by weight and colour rather than by size.
//
// The preview keeps a 1px bezel in every state. A monitor showing a dark
// wallpaper captures as a near-black rectangle, and without an edge that is
// indistinguishable from a hole in the card -- the bezel is what makes it
// read as a screen that happens to be dark.
Item {
  id: tile

  // A ShellScreen or a Toplevel, or null when the join to a Quickshell
  // toplevel failed -- the tile still has to render, because the handle
  // underneath is shareable either way.
  property var source: null
  property string label: ""
  property string sublabel: ""
  property bool selected: false
  // Set false by the tab Loader so a tab nobody is looking at stops capturing.
  property bool capturing: false

  signal clicked()
  signal doubleClicked()

  // Kept in sync with SharePickerWindow's cell arithmetic, which needs the
  // same numbers to size the card around the grid.
  readonly property int labelHeight: 34
  readonly property int inset: 6
  readonly property int gap: 4

  // Selection has to be unmistakable at a glance across a grid of bright, busy
  // thumbnails, so it is said four times: the cell fills with accent, the bezel
  // becomes an accent ring, the name turns accent, and every OTHER preview
  // dims. The dimming is what actually carries it -- a ring competes with
  // whatever the thumbnail happens to be showing, while a brightness
  // difference across the whole grid does not. It stops at 0.72 because these
  // previews are the interface: dim enough to recede, never so dim that you
  // cannot tell which window you are looking at.
  readonly property real previewDim: selected ? 1.0 : (hover.hovered ? 0.88 : 0.72)

  Rectangle {
    anchors.fill: parent
    radius: Style.module.radius + 2
    color: tile.selected ? Theme.alpha(Theme.accent, 0.22)
                         : (hover.hovered ? Theme.hoverBackground : Theme.transparent)

    Behavior on color { ColorAnimation { duration: Style.anim.colorDuration } }
  }

  Column {
    anchors.fill: parent
    anchors.margins: tile.inset
    spacing: tile.gap

    // ------------------------------------------------------------ thumbnail
    ClippingRectangle {
      id: frame

      width: parent.width
      height: parent.height - tile.labelHeight - parent.spacing

      radius: Style.module.radius
      // surface0, not crust: an unpainted frame should read as a lit panel
      // waiting for content, not as a black hole in the card.
      color: Theme.surface0
      border.width: tile.selected ? Style.module.borderWidth : 1
      border.color: tile.selected ? Theme.accent : Theme.surface2

      Behavior on border.color { ColorAnimation { duration: Style.anim.colorDuration } }

      ScreencopyView {
        id: view

        captureSource: tile.source
        // Applied here rather than to the whole tile so the label keeps its
        // own contrast and stays readable at a glance.
        opacity: hasContent ? tile.previewDim : 0
        // The one line that makes this whole thing worth building. Gated
        // rather than merely hidden -- `visible: false` stops painting, not
        // capturing, and a capture that keeps running is real GPU work.
        live: tile.capturing
        // The pointer is not part of what identifies a window, and a cursor
        // frozen mid-thumbnail just looks like a rendering bug.
        paintCursor: false

        // Letterbox into the frame. sourceSize is 0x0 until the first frame
        // lands, so fall back to the frame's own shape until it does and the
        // tile does not visibly jump when content arrives.
        readonly property real aspect: sourceSize.height > 0
          ? sourceSize.width / sourceSize.height
          : (frame.height > 0 ? frame.width / frame.height : 1.6)

        anchors.centerIn: parent
        width: Math.min(frame.width, frame.height * aspect)
        height: aspect > 0 ? width / aspect : frame.height

        Behavior on opacity {
          NumberAnimation { duration: Style.anim.opacityDuration }
        }
      }

      // Shown until the first frame arrives, and permanently for a window
      // whose toplevel could not be joined. Not an error state -- picking it
      // still works, you just cannot preview it. It names the thing rather
      // than showing a spinner, so an empty frame is still identifiable.
      Text {
        anchors.centerIn: parent
        width: parent.width - 2 * Style.module.paddingH
        visible: !view.hasContent
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: tile.source ? tile.label : "no preview"
        color: Theme.inactive
        font.family: Style.font.family
        font.pixelSize: Style.font.tiny
      }
    }

    // ---------------------------------------------------------------- label
    // Secondary by design: one line of identity, one line of detail, both at
    // Style's smallest size. Anything bigger competes with the preview.
    Item {
      width: parent.width
      height: tile.labelHeight

      Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 2
        anchors.rightMargin: 2

        Text {
          width: parent.width
          text: tile.label
          elide: Text.ElideRight
          color: tile.selected ? Theme.accent : Theme.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.tiny
          font.weight: Style.font.boldWeight

          Behavior on color { ColorAnimation { duration: Style.anim.colorDuration } }
        }

        Text {
          width: parent.width
          visible: tile.sublabel !== ""
          text: tile.sublabel
          elide: Text.ElideRight
          color: Theme.inactive
          font.family: Style.font.family
          font.pixelSize: Style.font.tiny
        }
      }
    }
  }

  HoverHandler { id: hover }

  MouseArea {
    anchors.fill: parent
    // Single click selects (so the keyboard and the mouse agree on what is
    // current), double click confirms -- the same bargain every file manager
    // makes, and it keeps a stray click from starting a screen share.
    onClicked: tile.clicked()
    onDoubleClicked: tile.doubleClicked()
  }
}
