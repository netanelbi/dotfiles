import QtQuick
import Quickshell
import Quickshell.Services.Notifications
import "root:/"

// One app's notifications in the control center.
//
// config.json leaves "notification-grouping" at its default (true), so swaync
// groups control-center rows by app name. A group of one is just the row. A
// group of several collapses into a stack: the newest card on top and the
// others peeking out below it, each inset and offset by 6px -- which is how
// the running daemon draws it (verified with grim: two rounded edges under
// the top Firefox card). Clicking the stack expands it into a header plus
// every row; clicking the header collapses it again.
//
// The group takes only its app name from the model and reads its rows back
// out of the store, so a notification arriving while the panel is open is a
// property change rather than a delegate rebuild -- no card restarts its
// entrance animation because a sibling appeared.
//
// style.css:
//   .notification-group-headers { padding: 8px 12px; color: @text; bold }
//   .notification-group-icon { color: @mauve }
//   .notification-group-close-button { background: @surface0; color: @text;
//                                      border-radius: 6px; padding: 4px 8px }
//   .notification-group-close-button:hover { background: @red; color: @base }
Item {
  id: root

  required property var store
  // The app name; the store keys groups by it.
  required property string appKey
  property string selectedKey: ""
  property var now: 0

  readonly property var entries: store.entriesForApp(appKey)
  readonly property bool multi: entries.length > 1
  readonly property bool expanded: store.expandedGroups.indexOf(appKey) >= 0
  readonly property bool collapsed: multi && !expanded
  // Cards peeking out from under the top one, capped at two like swaync's.
  readonly property int peeks: collapsed ? Math.min(2, entries.length - 1) : 0
  // .control-center padding 12 + .notification-background padding 12 +
  // .notification margin 12, off a panel that is centerWidth - 20 wide.
  readonly property int cardWidth: store.centerWidth - 20 - 2 * 12 - 2 * 12

  readonly property var head: entries.length > 0 ? entries[0] : null
  readonly property string headIcon: {
    if (!head || !head.notif) return ""
    if (head.notif.image !== "") return head.notif.image
    if (head.notif.appIcon !== "") return "image://icon/" + head.notif.appIcon
    return ""
  }

  readonly property color urgencyColor: {
    if (!head || !head.notif) return Theme.mauve
    var u = head.notif.urgency
    return u === NotificationUrgency.Critical ? Theme.red
      : u === NotificationUrgency.Low ? Theme.green : Theme.mauve
  }

  implicitHeight: stack.implicitHeight
  height: implicitHeight
  clip: true

  Behavior on height {
    NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
  }

  Column {
    id: stack
    width: root.width

    // ------------------------------------------------------------ header
    // Only an expanded multi-notification group gets one, which is when the
    // app name and the close-the-whole-group button are worth the room.
    Item {
      id: header
      width: parent.width
      height: root.expanded && root.multi ? 40 : 0
      visible: height > 0
      opacity: root.expanded && root.multi ? 1 : 0

      Behavior on height {
        NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
      }
      Behavior on opacity {
        NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.store.toggleGroup(root.appKey)
      }

      Row {
        anchors.left: parent.left
        anchors.leftMargin: 24         // .notification margin + list padding
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8

        // .notification-group-icon, falling back to a @mauve bell when the
        // app gave us nothing to draw.
        Item {
          width: 24
          height: 24
          anchors.verticalCenter: parent.verticalCenter

          Image {
            anchors.fill: parent
            visible: root.headIcon !== ""
            source: root.headIcon
            fillMode: Image.PreserveAspectFit
            sourceSize.width: 48
            sourceSize.height: 48
            asynchronous: true
          }

          Text {
            anchors.centerIn: parent
            visible: root.headIcon === ""
            text: "󰂚"
            color: Theme.mauve
            font.family: Style.font.family
            font.pixelSize: Style.font.size + 2
            renderType: Text.NativeRendering
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.appKey
          color: Theme.text
          font.family: Style.font.family
          font.pixelSize: Style.font.size
          font.weight: Style.font.boldWeight
          renderType: Text.NativeRendering
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.entries.length
          color: Theme.overlay0
          font.family: Style.font.family
          font.pixelSize: Style.font.size - 1
          renderType: Text.NativeRendering
        }
      }

      // .notification-group-close-button
      Rectangle {
        anchors.right: parent.right
        anchors.rightMargin: 24
        anchors.verticalCenter: parent.verticalCenter
        width: groupCloseLabel.implicitWidth + 16   // padding: 4px 8px
        height: groupCloseLabel.implicitHeight + 8
        radius: 6
        color: groupCloseArea.containsMouse ? Theme.red : Theme.surface0

        Behavior on color {
          ColorAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
        }

        Text {
          id: groupCloseLabel
          anchors.centerIn: parent
          text: "✕"
          color: groupCloseArea.containsMouse ? Theme.base : Theme.text
          font.family: Style.font.family
          font.pixelSize: Style.font.size - 2
          renderType: Text.NativeRendering

          Behavior on color {
            ColorAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
          }
        }

        MouseArea {
          id: groupCloseArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.store.closeGroup(root.appKey)
        }
      }
    }

    // ------------------------------------------------------------- cards
    Repeater {
      model: ScriptModel {
        // A collapsed group shows only its newest row; the ones underneath
        // are drawn as stubs, not as live cards.
        values: root.collapsed ? root.entries.slice(0, 1) : root.entries
        objectProp: "key"
      }

      Item {
        id: holder
        required property var modelData
        required property int index

        width: stack.width
        // The stubs stick out below the top card, so the holder is taller
        // than the card by their overhang.
        height: card.height + (index === 0 ? root.peeks * 6 : 0)

        // Collapsed stack: rounded stubs of the cards underneath, each inset
        // and pushed 6px further down than the last.
        Repeater {
          model: holder.index === 0 ? root.peeks : 0

          Rectangle {
            id: stub
            required property int index

            z: -1 - index
            x: 12 + 6 * (index + 1)
            y: 6 + 6 * (index + 1)
            width: root.cardWidth - 12 * (index + 1)
            height: card.cardHeight
            radius: 12
            color: Theme.base
            border.width: 2
            border.color: root.urgencyColor
            opacity: 1 - 0.25 * index

            Behavior on border.color {
              ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
            }
          }
        }

        NotificationCard {
          id: card

          entry: holder.modelData
          cardWidth: root.cardWidth
          showTime: true                      // control-center rows carry one
          now: root.now
          selected: root.selectedKey === holder.modelData.key
          leaving: root.store.historyLeaving.indexOf(holder.modelData.key) >= 0

          // A collapsed stack is an expander first: swaync opens the group
          // rather than firing the notification's action.
          onDefaultActivated: {
            if (root.collapsed) root.store.toggleGroup(root.appKey)
            else root.store.activateDefault(holder.modelData)
          }
          onActionActivated: index => root.store.invokeAction(holder.modelData, index)
          // Closing the top of a collapsed stack closes the whole group,
          // which is what swaync's persistent group close button does.
          onCloseRequested: {
            if (root.collapsed) root.store.closeGroup(root.appKey)
            else root.store.close(holder.modelData)
          }
          onLinkActivated: link => root.store.openLink(link)
          onFinished: root.store.dropHistory(holder.modelData.key)
        }
      }
    }
  }
}
