import QtQuick
import ".."

// The control room's tab strip, under the header. Ctrl+1..6 switch (the
// panel's key handler calls select()); a click does too. Each tab carries the
// one number worth knowing before you open it: a live dot while a call is
// open, how many workers are active, how many facts wait in the inbox.
Item {
  id: tabs

  property string current: "call"
  property bool chatBusy: false
  signal picked(string key)

  readonly property var model: [
    { key: "call", label: "Call" },
    { key: "work", label: "Work" },
    { key: "memory", label: "Memory" },
    { key: "debug", label: "Debug" },
    { key: "settings", label: "Settings" },
    { key: "chat", label: "Chat" }
  ]
  readonly property var keys: ["call", "work", "memory", "debug", "settings", "chat"]

  function badge(key) {
    switch (key) {
    case "work": return EarsModel.workersActive > 0 ? String(EarsModel.workersActive) : ""
    case "memory": return ""
    }
    return ""
  }
  function dot(key) {
    if (key === "call") return EarsModel.call ? RoomLook.modeColor(EarsModel.mode) : Theme.transparent
    if (key === "chat") return tabs.chatBusy ? Theme.sapphire : Theme.transparent
    return Theme.transparent
  }

  implicitHeight: 38

  Row {
    id: row
    anchors { left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom
              leftMargin: 8; rightMargin: 8 }

    Repeater {
      model: tabs.model
      delegate: Item {
        id: tab
        required property var modelData
        required property int index
        readonly property bool on: tabs.current === modelData.key
        width: row.width / tabs.model.length
        height: row.height

        Row {
          anchors.centerIn: parent
          anchors.verticalCenterOffset: -1
          spacing: 6

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 7; height: 7; radius: 3.5
            color: tabs.dot(tab.modelData.key)
            visible: color.a > 0
          }
          Text {
            id: word
            anchors.verticalCenter: parent.verticalCenter
            text: tab.modelData.label
            color: tab.on ? Theme.text : (hit.containsMouse ? Theme.subtext1 : Theme.overlay0)
            font.family: RoomLook.sans
            font.pixelSize: RoomLook.meta + 1
            font.weight: tab.on ? Font.DemiBold : Font.Medium
            renderType: Text.QtRendering
            Behavior on color { ColorAnimation { duration: Style.anim.quick } }
          }
          Rectangle {
            readonly property string n: tabs.badge(tab.modelData.key)
            anchors.verticalCenter: parent.verticalCenter
            visible: n !== ""
            width: Math.max(18, num.implicitWidth + 10)
            height: 18
            radius: 9
            color: tab.modelData.key === "memory" ? Theme.alpha(Theme.peach, 0.18) : Theme.alpha(Theme.blue, 0.16)
            Text {
              id: num
              anchors.centerIn: parent
              text: parent.n
              color: tab.modelData.key === "memory" ? Theme.peach : Theme.blue
              font.family: RoomLook.mono
              font.pixelSize: RoomLook.small - 1
              renderType: Text.QtRendering
            }
          }
        }

        // The current tab's underline sits ON the strip's hairline.
        Rectangle {
          anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter }
          width: tab.on ? Math.min(parent.width - 16, 44) : 0
          height: 2
          radius: 1
          color: tab.modelData.key === "call" && EarsModel.call ? RoomLook.modeColor(EarsModel.mode) : Theme.accent
          Behavior on width { NumberAnimation { duration: Style.anim.normal; easing.type: Style.anim.easing } }
        }

        MouseArea {
          id: hit
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: tabs.picked(tab.modelData.key)
        }
      }
    }
  }

  Rectangle {
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: 1
    color: RoomLook.hairline
  }
}
