import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
// Theme/Style are singletons in the config root; a subdirectory does not get
// the root's implicit import, so pull it in explicitly.
import ".."

// Shared chrome for every launcher overlay. This is the QML transcription of
// the rofi themes in ~/.dotfiles/rofi/.config/rofi/*.rasi -- one window, one
// card, one prompt/entry header, one content region:
//
//   window    { background: @base; border: 2px solid <accent>;
//               border-radius: <cornerRadius>; width: <panelWidth> }
//   inputbar  { background: @surface0; border-radius: <r> <r> 0 0; padding: 12px }
//   prompt    { background: <accent>; text-color: @base; border-radius: 6px }
//   entry     { placeholder-color: @overlay0 }
//
// Every colour comes from Theme, so the launchers re-theme with the bar when
// waybar's style.css changes.
//
// ------------------------------------------------------------------- motion
// rofi pops into existence and snaps its selection. This fades a backdrop in,
// lifts the card from 12px below at 0.96 scale, and animates the list's height
// as the query filters it -- so the panel visibly shrinks around the matches
// instead of leaving eight empty rows.
//
// ----------------------------------------------------------------- keyboard
// Bindings mirror rofi's defaults: Up/Down + Ctrl+K/Ctrl+J + Tab/Shift+Tab to
// move (stopping at either end), PageUp/PageDown by a screenful,
// Home/End to the ends, Enter to accept, Escape to dismiss, and Alt+P for the
// secondary action (rofi's kb-custom-1, which config.rasi already binds).
PanelWindow {
  id: panel

  // ------------------------------------------------------------------ api
  // Prompt pill text, e.g. rofi's `display-drun: "Apps"`.
  property string prompt: ""
  // powermenu.rasi draws its prompt as centred bare text, not a pill.
  property bool promptPill: true
  // The `window { border-color }` of the matching .rasi.
  property color accent: Theme.accent
  property int panelWidth: 500
  property int cornerRadius: 12
  // powermenu.rasi sets `entry { enabled: false }`.
  property bool searchEnabled: true
  property string placeholder: "Search..."
  // The LauncherList this panel drives with the arrow keys, if any.
  property var list: null

  property bool opened: false
  // Hover must not count until the pointer has deliberately moved since the
  // panel opened: the card is screen-centred, so the cursor often opens
  // sitting on a row, and entry alone made the selection jump on launch.
  // A single move event is not enough either -- a palm brush on the touchpad
  // while typing is 2-3px and would still steal the highlight. So hover only
  // arms after hoverArmTravel px of accumulated travel. Rows call
  // hoverMoved() from onPositionChanged with scene coords.
  property bool hoverArmed: false
  readonly property int hoverArmTravel: 16
  property point hoverLast
  property bool hoverLastValid: false
  property real hoverTravel: 0

  function hoverMoved(g) {
    if (hoverArmed) return
    if (!hoverLastValid) {
      hoverLast = g
      hoverLastValid = true
      return
    }
    // Manhatten distance; direction does not matter, intention does.
    hoverTravel += Math.abs(g.x - hoverLast.x) + Math.abs(g.y - hoverLast.y)
    hoverLast = g
    if (hoverTravel >= hoverArmTravel) hoverArmed = true
  }

  default property alias content: body.data
  readonly property alias query: input.text

  // Emitted just before the panel becomes visible -- launchers refresh their
  // model here so the list is never stale.
  signal presented()
  signal accepted()
  signal altAccepted()
  signal dismissed()

  function present() {
    if (opened) return
    input.text = ""
    hoverArmed = false
    hoverLastValid = false
    hoverTravel = 0
    panel.screen = focusedScreen()
    presented()
    opened = true
    Qt.callLater(function () { keyScope.forceActiveFocus() })
  }

  function dismiss() {
    if (!opened) return
    opened = false
    dismissed()
  }

  function toggle() {
    if (opened) dismiss()
    else present()
  }

  // rofi opens on the monitor with focus; Quickshell.screens is indexed by Qt
  // screen, so go through Hyprland's monitor mapping to find the match.
  function focusedScreen() {
    var focused = Hyprland.focusedMonitor
    if (!focused) return panel.screen
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (Hyprland.monitorFor(screens[i]) === focused) return screens[i]
    }
    return panel.screen
  }

  // ------------------------------------------------------- fuzzy matching
  // rofi's default matching is "all tokens must appear"; this adds ranking so
  // a prefix hit outranks a scattered subsequence. Returns -1 for no match.
  function matchScore(haystack, needle) {
    if (!needle) return 0
    if (!haystack) return -1
    var h = String(haystack).toLowerCase()
    var n = String(needle).toLowerCase()

    var idx = h.indexOf(n)
    if (idx === 0) return 1000
    if (idx > 0) return 800 - Math.min(idx, 100) + (h.charAt(idx - 1) === " " ? 60 : 0)

    // Subsequence fallback: every character of the needle, in order.
    var at = 0
    var score = 500
    var streak = 0
    for (var i = 0; i < n.length; i++) {
      var found = h.indexOf(n.charAt(i), at)
      if (found === -1) return -1
      if (found === at) {
        streak++
        score += 3 * streak
      } else {
        streak = 0
        score -= Math.min(found - at, 20)
      }
      at = found + 1
    }
    return Math.max(score, 1)
  }

  // --------------------------------------------------------------- window
  WlrLayershell.namespace: "quickshell-launcher"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  color: "transparent"

  // `revealed` drives every entrance/exit animation. The window outlives
  // `opened` by exactly one fade so the card can animate out.
  property real revealed: 0
  visible: opened || revealed > 0.001
  onOpenedChanged: revealed = opened ? 1 : 0

  Behavior on revealed {
    NumberAnimation {
      duration: Style.anim.reveal
      easing.type: Style.anim.easing
    }
  }

  // ------------------------------------------------------------- backdrop
  // rofi has none; a dim keeps the launcher legible over a busy desktop and
  // gives the entrance something to fade against.
  Rectangle {
    anchors.fill: parent
    color: Theme.alpha(Theme.crust, 0.45)
    opacity: panel.revealed

    MouseArea {
      anchors.fill: parent
      onClicked: panel.dismiss()
    }
  }

  // ----------------------------------------------------------------- card
  FocusScope {
    id: keyScope
    anchors.fill: parent
    focus: true

    Keys.onPressed: function (event) { panel.handleKey(event) }

    Item {
      id: cardHolder
      width: panel.panelWidth
      anchors.horizontalCenter: parent.horizontalCenter
      height: card.height

      opacity: panel.revealed
      scale: 0.96 + 0.04 * panel.revealed
      y: (parent.height - height) / 2 + 12 * (1 - panel.revealed)

      Rectangle {
        id: card
        width: parent.width
        implicitHeight: header.height + body.implicitHeight
        height: implicitHeight

        color: Theme.base
        radius: panel.cornerRadius
        border.width: 2
        border.color: panel.accent
        clip: true

        Behavior on border.color {
          ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
        }

        // ------------------------------------------------------- inputbar
        Rectangle {
          id: header
          width: parent.width
          height: headerRow.implicitHeight + 2 * headerPadding
          readonly property int headerPadding: 12

          color: Theme.surface0
          topLeftRadius: panel.cornerRadius - 2
          topRightRadius: panel.cornerRadius - 2
          bottomLeftRadius: 0
          bottomRightRadius: 0

          Row {
            id: headerRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: header.headerPadding
            anchors.rightMargin: header.headerPadding
            spacing: 12

            // prompt { background: <accent>; text-color: @base; padding: 6px 12px }
            Rectangle {
              id: promptBadge
              visible: panel.prompt !== "" && panel.promptPill
              width: promptLabel.implicitWidth + 24
              height: promptLabel.implicitHeight + 12
              radius: 6
              color: panel.accent
              anchors.verticalCenter: parent.verticalCenter

              Behavior on color {
                ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
              }

              Text {
                id: promptLabel
                anchors.centerIn: parent
                text: panel.prompt
                color: Theme.base
                font.family: Style.font.family
                font.pixelSize: Style.font.small
                font.weight: Style.font.boldWeight
                renderType: Text.NativeRendering
              }
            }

            // powermenu.rasi: bare centred prompt, no entry.
            Text {
              visible: panel.prompt !== "" && !panel.promptPill
              width: headerRow.width
              text: panel.prompt
              color: panel.accent
              horizontalAlignment: Text.AlignHCenter
              font.family: Style.font.family
              font.pixelSize: Style.font.size
              font.weight: Style.font.boldWeight
              renderType: Text.NativeRendering
            }

            Item {
              visible: panel.searchEnabled
              width: headerRow.width - (promptBadge.visible ? promptBadge.width + headerRow.spacing : 0)
              height: input.implicitHeight + 12
              anchors.verticalCenter: parent.verticalCenter

              TextInput {
                id: input
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                enabled: panel.searchEnabled
                // Without this the FocusScope keeps the active focus itself and
                // typing goes nowhere -- only the nav keys would work.
                focus: panel.searchEnabled
                color: Theme.text
                selectionColor: panel.accent
                selectedTextColor: Theme.base
                selectByMouse: true
                font.family: Style.font.family
                font.pixelSize: Style.font.size + 2
                renderType: Text.NativeRendering
                clip: true

                Keys.onPressed: function (event) { panel.handleKey(event) }

                // entry { placeholder-color: @overlay0 }
                Text {
                  anchors.fill: parent
                  visible: input.text === ""
                  text: panel.placeholder
                  color: Theme.overlay0
                  font: input.font
                  verticalAlignment: Text.AlignVCenter
                  renderType: Text.NativeRendering
                }

                // rofi's caret is a static bar. This one breathes, and slides
                // with the text rather than jumping.
                cursorDelegate: Rectangle {
                  width: 2
                  radius: 1
                  color: panel.accent

                  SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    running: input.activeFocus
                    NumberAnimation { to: 0.25; duration: 520; easing.type: Style.anim.easingSmooth }
                    NumberAnimation { to: 1; duration: 520; easing.type: Style.anim.easingSmooth }
                  }
                }
              }
            }
          }
        }

        // ------------------------------------------------------- content
        Column {
          id: body
          anchors.top: header.bottom
          width: parent.width
        }
      }
    }
  }

  // ------------------------------------------------------------ keyboard
  function navigate(delta) {
    if (list) list.move(delta)
  }

  function handleKey(event) {
    var page = list ? Math.max(1, list.rows - 1) : 5

    switch (event.key) {
    case Qt.Key_Escape:
      panel.dismiss()
      event.accepted = true
      return
    case Qt.Key_Return:
    case Qt.Key_Enter:
      panel.accepted()
      event.accepted = true
      return
    case Qt.Key_Up:
      navigate(-1)
      event.accepted = true
      return
    case Qt.Key_Down:
      navigate(1)
      event.accepted = true
      return
    case Qt.Key_PageUp:
      navigate(-page)
      event.accepted = true
      return
    case Qt.Key_PageDown:
      navigate(page)
      event.accepted = true
      return
    case Qt.Key_Home:
      if (list) list.moveTo(0)
      event.accepted = true
      return
    case Qt.Key_End:
      if (list) list.moveTo(list.count - 1)
      event.accepted = true
      return
    case Qt.Key_Tab:
      navigate(1)
      event.accepted = true
      return
    case Qt.Key_Backtab:
      navigate(-1)
      event.accepted = true
      return
    case Qt.Key_J:
      if (event.modifiers & Qt.ControlModifier) {
        navigate(1)
        event.accepted = true
      }
      return
    case Qt.Key_K:
      if (event.modifiers & Qt.ControlModifier) {
        navigate(-1)
        event.accepted = true
      }
      return
    case Qt.Key_P:
      // config.rasi: kb-custom-1 = "Alt+p" -- the clipboard's image preview.
      if (event.modifiers & Qt.AltModifier) {
        panel.altAccepted()
        event.accepted = true
      }
      return
    }
  }
}
