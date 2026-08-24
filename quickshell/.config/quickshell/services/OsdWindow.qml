import QtQuick
import Quickshell
import Quickshell.Wayland
import "root:/"

// One OSD surface per output. All the measurements and the reasoning behind
// them live in Osd.qml's header; this file is the drawing.
PanelWindow {
  id: win

  property var modelData: null
  property var controller: null

  screen: modelData

  WlrLayershell.namespace: "quickshell-osd"
  // swayosd sits on layer 3 (overlay) -- above the bar, above fullscreen.
  WlrLayershell.layer: WlrLayer.Overlay
  // An OSD must never push windows around.
  exclusionMode: ExclusionMode.Ignore

  // swayosd is bottom-anchored, horizontally centred, with a bottom margin of
  // screen_h * (1 - top_margin); top_margin defaults to 0.85 and config.toml
  // does not override it. On this 800px-tall output that is 120, which put the
  // surface's bottom edge at y=680 -- confirmed against `hyprctl layers`.
  anchors.bottom: true
  // The window is `travel` px taller than the surface and sits `travel` px
  // lower, so the surface's RESTING position (y = 0) lands on swayosd's exact
  // bottom edge and the slide-in still has somewhere to come from.
  margins.bottom: Math.round((win.screen ? win.screen.height : 0) * 0.15) - travel

  readonly property int surfaceWidth: 343
  readonly property int surfaceHeight: 80
  // The surface slides up into place. The window has to be taller than the
  // surface for that: animating `margins.bottom` would recommit the layer
  // surface every frame, so the travel happens inside a fixed window instead,
  // and the extra strip above is transparent and masked out.
  readonly property int travel: 10

  implicitWidth: surfaceWidth
  implicitHeight: surfaceHeight + travel

  color: "transparent"

  // Click-through: an empty mask means the compositor routes every pointer
  // event to whatever is underneath, so the OSD can cover a window without
  // stealing a click from it.
  mask: Region {}

  readonly property bool showing: controller !== null && controller.open
  // Stay mapped until the fade-out has finished, then unmap so the surface is
  // not sitting in the compositor's overlay layer doing nothing.
  visible: showing || surface.opacity > 0

  Rectangle {
    id: surface

    width: win.surfaceWidth
    height: win.surfaceHeight
    // Rest at the top of the window (swayosd's position); start `travel` px
    // lower and rise into it.
    y: win.showing ? 0 : win.travel
    opacity: win.showing ? 1 : 0

    // style.css `window { background: @base; border-radius: 10px;
    //                     border: 2px solid @mauve }`
    color: Theme.base
    radius: 10
    border.width: 2
    border.color: Theme.mauve

    // MOTION. swayosd maps and unmaps its surface with nothing in between --
    // it appears and vanishes on a frame boundary. Here it rises 10px and
    // fades in, and settles back down on the way out. Both are short and both
    // decelerate: OutCubic, no overshoot, no scale. The point is that the
    // thing arrives from somewhere rather than materialising, not that it
    // announces itself.
    Behavior on y {
      NumberAnimation {
        duration: win.showing ? Style.anim.reveal : Style.anim.normal
        easing.type: Style.anim.easing
      }
    }

    Behavior on opacity {
      NumberAnimation {
        duration: win.showing ? Style.anim.opacityDuration : Style.anim.normal
        easing.type: Style.anim.easingSmooth
      }
    }

    // ------------------------------------------------------------ the icon
    // image { color: @mauve; -gtk-icon-size: 18px }, ink centred on x=48.
    Text {
      id: icon
      x: 26
      width: 36
      height: parent.height
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter

      text: win.controller ? win.controller.glyph : ""
      color: Theme.mauve
      font.family: Style.font.family
      font.pixelSize: 44
      renderType: Text.NativeRendering

      // The glyph only swaps when the reading crosses a ramp step or the OSD
      // changes subject (volume -> brightness while still on screen). A short
      // fade makes that read as a substitution instead of a flicker.
      onTextChanged: if (icon.text !== "") iconFade.restart()

      NumberAnimation {
        id: iconFade
        target: icon
        property: "opacity"
        from: 0.35
        to: 1
        duration: Style.anim.normal
        easing.type: Style.anim.easing
      }
    }

    // ------------------------------------------------------- the progressbar
    // progressbar { min-width: 175 } with a 6px trough; measured 86..261.
    Item {
      id: bar
      x: 86
      width: 176
      height: parent.height

      // Muting drops the whole progressbar -- trough included -- to half
      // strength. That is not a stylesheet rule; it is what the running OSD
      // paints, and sampling the muted fill (117,122,145) against @text over
      // @base pins it at exactly 0.5.
      opacity: win.controller && win.controller.dimmed ? 0.5 : 1

      Behavior on opacity {
        NumberAnimation {
          duration: Style.anim.opacityDuration
          easing.type: Style.anim.easingSmooth
        }
      }

      Rectangle {
        id: trough
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: 6
        radius: 3
        color: Theme.surface0

        Rectangle {
          height: parent.height
          radius: parent.radius
          color: Theme.text
          width: trough.width * Math.max(0, Math.min(100, win.controller ? win.controller.level : 0)) / 100

          // The one place the OSD is genuinely better than swayosd rather than
          // merely smoother: swayosd redraws the fill at its new length, so a
          // held volume key is a staircase. Here the fill glides, and a burst
          // of key repeats reads as one continuous sweep.
          Behavior on width {
            NumberAnimation {
              duration: Style.anim.normal
              easing.type: Style.anim.easing
            }
          }
        }
      }
    }

    // ------------------------------------------------------------ the label
    // label { color: @text; font-size: 12px; font-weight: bold; min-width: 38 },
    // centred in its box -- which is why the running OSD leaves visible space
    // between "45%" and the right padding edge.
    Text {
      x: 273
      width: 38
      height: parent.height
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter

      // config.toml: show_percentage = true. swayosd keeps showing the number
      // while muted (the bar dims, the reading does not disappear).
      text: (win.controller ? win.controller.level : 0) + "%"
      color: Theme.text
      font.family: Style.font.family
      font.pixelSize: 12
      font.weight: Style.font.boldWeight
      renderType: Text.NativeRendering
    }
  }
}
