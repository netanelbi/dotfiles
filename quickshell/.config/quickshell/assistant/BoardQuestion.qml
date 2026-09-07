import QtQuick
import QtQuick.Controls
import ".."

// The board's built-in question card. Not loaded content -- part of the board
// itself, so a script asks with one IPC call and needs no QML of its own:
//
//   qs ipc call board question "Ship it?" "Yes,No,Not yet"
//   qs ipc call board question "What next?" ""          (free-form only)
//
// Every path ends in board.respond(): buttons with their label, the field with
// what was typed, ✕ with "(dismissed)". respond() routes the answer into the
// assistant conversation, so the agent that asked reads the reply as the next
// turn.
Column {
  id: card

  required property var board

  spacing: 14

  Text {
    text: card.board.question
    color: Theme.text
    font.family: Style.font.panelFamily
    font.pixelSize: Style.font.panelBody + 1
    wrapMode: Text.WordWrap
    width: parent.width
  }

  // One row of buttons per option, "Yes / No / Not yet" style.
  Column {
    spacing: 8
    width: parent.width
    visible: card.board.options.length > 0

    Repeater {
      model: card.board.options

      delegate: Rectangle {
        required property string modelData
        required property int index

        width: parent.width
        height: 40
        radius: 8
        color: optArea.containsMouse
          ? Theme.alpha(Theme.sapphire, 0.25)
          : Theme.alpha(Theme.sapphire, 0.12)
        border.width: 1
        border.color: Theme.alpha(Theme.sapphire, 0.4)

        Behavior on color { ColorAnimation { duration: Style.anim.quick } }

        Text {
          anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
          text: modelData
          color: Theme.text
          font.family: Style.font.panelFamily
          font.pixelSize: Style.font.panelBody
        }
        Text {
          anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
          text: "→"
          color: optArea.containsMouse ? Theme.sapphire : Theme.overlay0
          font.family: Style.font.panelMono
          font.pixelSize: Style.font.panelBody
          renderType: Text.QtRendering
        }

        MouseArea {
          id: optArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: card.board.respond(modelData)
        }
      }
    }
  }

  // Free-form, always there -- an option is a guess about what the answer
  // might be; this is the escape hatch from the guess.
  Rectangle {
    width: parent.width
    height: 40
    radius: 8
    color: Theme.alpha(Theme.base, 0.8)
    border.width: 1
    border.color: field.activeFocus ? Theme.sapphire : Theme.alpha(Theme.sapphire, 0.25)

    TextField {
      id: field
      anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
      verticalAlignment: TextInput.AlignVCenter
      placeholderText: "or type an answer…"
      placeholderTextColor: Theme.overlay0
      color: Theme.text
      font.family: Style.font.panelFamily
      font.pixelSize: Style.font.panelBody
      background: null
      focus: true
      // Live readback: the agent can `board read` and see the draft BEFORE it
      // is sent -- the field is a conversation, not just a submit button.
      onTextChanged: card.board.draft = text
      onAccepted: if (text.trim() !== "") card.board.respond(text.trim())
    }
  }

  Text {
    text: "Enter sends · Esc closes"
    color: Theme.overlay0
    font.family: Style.font.panelMono
    font.pixelSize: Style.font.panelMeta - 2
    renderType: Text.QtRendering
  }
}