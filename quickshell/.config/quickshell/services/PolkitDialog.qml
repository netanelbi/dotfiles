import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "root:/"

// The password prompt. Reasoning about the polkit flow itself lives in
// Polkit.qml; this file is the drawing and the keyboard.
//
// Chrome is the launcher card's: @base fill, 12px radius, a 2px accent border,
// an @surface0 field, and the same fade-backdrop / lift-12px entrance. The one
// deliberate difference is that the border is @red while polkit is reporting a
// failure, so a mistyped password is visible from across the room.
//
// -------------------------------------------------- why the window is fullscreen
// A layer surface must wait for a compositor configure/ack round trip before it
// may commit a new size. A window whose implicitHeight follows animating
// content therefore does one round trip PER FRAME -- measured on the
// notification popups, a 180ms entrance took 467ms and arrived in five visible
// lurches. So the surface is the whole output, sized once at map time and never
// again, and the card grows and moves inside it. The card's height does track
// its content (the error line appears and disappears between retries), which is
// free precisely because the surface does not.
PanelWindow {
  id: win

  property var controller: null

  readonly property var flow: controller ? controller.flow : null
  readonly property bool opened: controller !== null && controller.open

  // Only meaningful while a flow exists; guarded everywhere it is read.
  readonly property bool hasError: flow !== null && flow.supplementaryIsError
      && flow.supplementaryMessage !== ""
  readonly property color accent: hasError ? Theme.red : Theme.accent

  WlrLayershell.namespace: "quickshell-polkit"
  WlrLayershell.layer: WlrLayer.Overlay
  // Nothing else may take the keystrokes while a password is being typed.
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  color: "transparent"

  // Follow the focused output, resolved once as the dialog opens. Quickshell
  // indexes screens by Qt screen, so the mapping goes through Hyprland.
  onOpenedChanged: {
    if (opened) {
      win.screen = win.focusedScreen()
      field.text = ""
      Qt.callLater(function () { field.forceActiveFocus() })
    }
    revealed = opened ? 1 : 0
  }

  function focusedScreen() {
    var focused = Hyprland.focusedMonitor
    if (!focused) return win.screen
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (Hyprland.monitorFor(screens[i]) === focused) return screens[i]
    }
    return win.screen
  }

  // Each PAM round clears the field: on a retry the old (wrong) text must not
  // sit there ready to be re-submitted by a reflexive Enter.
  Connections {
    target: win.flow
    ignoreUnknownSignals: true
    function onIsResponseRequiredChanged() {
      if (win.flow && win.flow.isResponseRequired) {
        field.text = ""
        field.forceActiveFocus()
      }
    }
  }

  // The window outlives `opened` by exactly one fade so the card can animate
  // out; `visible: false` would stop the painting, not the animation.
  property real revealed: 0
  visible: opened || revealed > 0.001

  Behavior on revealed {
    NumberAnimation {
      duration: Style.anim.reveal
      easing.type: Style.anim.easing
    }
  }

  // --------------------------------------------------------------- backdrop
  // No click-to-dismiss here, unlike the launchers: a stray click must not
  // cancel a root action the user actually meant to take. Escape is the way out.
  Rectangle {
    anchors.fill: parent
    color: Theme.alpha(Theme.crust, 0.5)
    opacity: win.revealed
  }

  // ------------------------------------------------------------------- card
  FocusScope {
    id: keyScope
    anchors.fill: parent
    focus: true

    Keys.onPressed: function (event) { win.handleKey(event) }

    Item {
      width: 460
      anchors.horizontalCenter: parent.horizontalCenter
      height: card.height

      opacity: win.revealed
      scale: 0.96 + 0.04 * win.revealed
      y: (parent.height - height) / 2 + 12 * (1 - win.revealed)

      Rectangle {
        id: card
        width: parent.width
        implicitHeight: column.implicitHeight + 2 * 20
        height: implicitHeight

        color: Theme.base
        radius: 12
        border.width: 2
        border.color: win.accent

        // The failure recolour reads as the card reacting, not as a repaint.
        Behavior on border.color {
          ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
        }

        // Content height changes as the error line comes and goes. Cheap: the
        // surface is fixed, so this is a plain repaint with no Wayland round trip.
        Behavior on implicitHeight {
          NumberAnimation { duration: Style.anim.normal; easing.type: Style.anim.easing }
        }

        Column {
          id: column
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: 20
          spacing: 12

          // ------------------------------------------------------- heading
          Row {
            width: parent.width
            spacing: 12

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "\u{f033e}"   // nf-md-lock
              color: win.accent
              font.family: Style.font.family
              font.pixelSize: 28
              renderType: Text.NativeRendering

              Behavior on color {
                ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
              }
            }

            Column {
              width: parent.width - 40
              spacing: 2

              Text {
                text: "Authentication Required"
                color: Theme.text
                font.family: Style.font.family
                font.pixelSize: Style.font.size + 2
                font.weight: Style.font.boldWeight
                renderType: Text.NativeRendering
              }

              // Which account the answer authenticates as. On this machine that
              // is always the one user, but a rule granting a group makes it
              // matter, and polkit gives it to us for free.
              Text {
                visible: text !== ""
                text: win.flow && win.flow.selectedIdentity
                    ? win.flow.selectedIdentity.displayName : ""
                color: Theme.subtext0
                font.family: Style.font.family
                font.pixelSize: Style.font.tiny
                renderType: Text.NativeRendering
              }
            }
          }

          // ------------------------------------------------------- message
          // polkit's own wording ("Authentication is required to run ...").
          Text {
            width: parent.width
            text: win.flow ? win.flow.message : ""
            color: Theme.subtext1
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.size
            renderType: Text.NativeRendering
          }

          // The action id is the thing a polkit rule is actually written
          // against, so it is worth showing verbatim rather than prettifying.
          Text {
            width: parent.width
            text: win.flow ? win.flow.actionId : ""
            color: Theme.overlay0
            elide: Text.ElideMiddle
            font.family: Style.font.family
            font.pixelSize: Style.font.tiny
            renderType: Text.NativeRendering
          }

          // --------------------------------------------------------- field
          Rectangle {
            width: parent.width
            height: 44
            radius: 8
            color: Theme.surface0
            border.width: 1
            border.color: field.activeFocus ? win.accent : Theme.surface1

            Behavior on border.color {
              ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
            }

            TextInput {
              id: field
              anchors.fill: parent
              anchors.leftMargin: 12
              anchors.rightMargin: 12
              verticalAlignment: Text.AlignVCenter
              focus: true
              // PAM decides whether its own prompt is a secret. It virtually
              // always is, but a stack can interleave a plain question and
              // echoing it back is then the correct behaviour.
              echoMode: win.flow && win.flow.responseVisible
                  ? TextInput.Normal : TextInput.Password
              // Dead while PAM is checking the previous answer, which is also
              // the window in which a second Enter would otherwise queue a
              // stray empty submission.
              enabled: win.flow !== null && win.flow.isResponseRequired
              color: Theme.text
              selectionColor: win.accent
              selectedTextColor: Theme.base
              selectByMouse: true
              font.family: Style.font.family
              font.pixelSize: Style.font.size
              renderType: Text.NativeRendering
              clip: true

              Keys.onPressed: function (event) { win.handleKey(event) }

              Text {
                anchors.fill: parent
                visible: field.text === ""
                // PAM's own prompt ("Password: "), trimmed of its trailing
                // colon-space so it reads as placeholder text.
                text: win.flow && win.flow.inputPrompt !== ""
                    ? win.flow.inputPrompt.replace(/:\s*$/, "") : "Password"
                color: Theme.overlay0
                font: field.font
                verticalAlignment: Text.AlignVCenter
                renderType: Text.NativeRendering
              }

              cursorDelegate: Rectangle {
                width: 2
                radius: 1
                color: win.accent

                SequentialAnimation on opacity {
                  loops: Animation.Infinite
                  // Gated: an animation left running under a hidden window
                  // still burns frames.
                  running: field.activeFocus && win.visible
                  NumberAnimation { to: 0.25; duration: 520; easing.type: Style.anim.easingSmooth }
                  NumberAnimation { to: 1; duration: 520; easing.type: Style.anim.easingSmooth }
                }
              }
            }
          }

          // --------------------------------------------------- pam feedback
          // "Authentication failure" after a bad password, and whatever else
          // the stack chooses to say. Present only while there is something to
          // say, which is what makes the card grow on a failed try.
          Text {
            width: parent.width
            visible: text !== ""
            text: win.flow ? win.flow.supplementaryMessage : ""
            color: win.hasError ? Theme.red : Theme.subtext0
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.tiny
            renderType: Text.NativeRendering
          }

          // ------------------------------------------------------- buttons
          Item {
            width: parent.width
            height: 36

            Row {
              anchors.right: parent.right
              spacing: 8

              DialogButton {
                label: "Cancel"
                accent: win.accent
                onActivated: win.controller.cancel()
              }

              DialogButton {
                label: "Authenticate"
                primary: true
                accent: win.accent
                enabled: win.flow !== null && win.flow.isResponseRequired
                onActivated: win.submit()
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------------ keys
  function submit() {
    if (controller) controller.submit(field.text)
    // Cleared immediately rather than on the next prompt: the answer has been
    // handed to PAM and there is no reason for it to stay in a text buffer.
    field.text = ""
  }

  function handleKey(event) {
    switch (event.key) {
    case Qt.Key_Escape:
      if (controller) controller.cancel()
      event.accepted = true
      return
    case Qt.Key_Return:
    case Qt.Key_Enter:
      if (flow && flow.isResponseRequired) win.submit()
      event.accepted = true
      return
    }
  }

  // ----------------------------------------------------------------- button
  component DialogButton: Rectangle {
    id: btn

    property string label: ""
    property bool primary: false
    // Inline components do not see the enclosing component's ids, so the
    // accent (which turns red on a failed try) has to be handed in.
    property color accent: Theme.accent

    signal activated()

    width: btnText.implicitWidth + 32
    height: 36
    radius: 8
    // `enabled` is Item's own: setting it also disables the MouseArea below,
    // so the dimmed button is genuinely dead rather than merely dim.
    opacity: btn.enabled ? 1 : 0.45

    color: !btn.primary
        ? (mouse.containsMouse ? Theme.surface1 : Theme.surface0)
        : (mouse.containsMouse ? Theme.accentAlt : btn.accent)

    Behavior on color {
      ColorAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
    }

    Behavior on opacity {
      NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
    }

    Text {
      id: btnText
      anchors.centerIn: parent
      text: btn.label
      color: btn.primary ? Theme.base : Theme.text
      font.family: Style.font.family
      font.pixelSize: Style.font.size
      font.weight: btn.primary ? Style.font.boldWeight : Style.font.normalWeight
      renderType: Text.NativeRendering
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: btn.activated()
    }
  }
}
