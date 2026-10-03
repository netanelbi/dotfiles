import QtQuick
import Quickshell
import Quickshell.Io
import ".."

// Memory: what Ori knows about you, and what it would like to.
//
//   (No inbox: lasting facts are saved after each call; Forget removes a wrong one.)
//   Inbox     (retired) facts Ori noticed in calls and wanted your OK on. Accept wrote
//             a memory file exactly as memory.py does; Reject drops it.
//   Profile   profile.md, always in Ori's context. Edit in place (Ctrl+S
//             saves) or open it in the editor.
//   Calls     the summaries written after each call
//   Facts     the memory files, searchable
//
// Read when the tab opens and whenever the daemon says memory changed.
FocusScope {
  id: mem

  property string view: "facts"
  property string note: ""

  Component.onCompleted: { EarsModel.refreshMemory(); forceActiveFocus() }

  Connections {
    target: EarsModel
    function onMemoryNote(text) { mem.note = text; noteClear.restart() }
  }
  Timer { id: noteClear; interval: 2500; onTriggered: mem.note = "" }

  // "2026-10-02_00-25-1" -> "from the call at 00:25, 2 Oct"
  function fromCall(id) {
    var m = /^(\d{4})-(\d\d)-(\d\d)_(\d\d)-(\d\d)/.exec(String(id))
    if (!m) return id
    var mon = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][Number(m[2]) - 1]
    return "from the call at " + m[4] + ":" + m[5] + ", " + Number(m[3]) + " " + mon
  }

  readonly property var views: [
    { k: "facts", label: "Facts", n: EarsModel.memories.length },
    { k: "profile", label: "Profile", n: -1 },
    { k: "calls", label: "Calls", n: EarsModel.calls.length }
  ]

  Keys.onPressed: function (e) {
    if (e.key === Qt.Key_Left || e.key === Qt.Key_Right) {
      var ks = ["facts", "profile", "calls"]
      var i = ks.indexOf(mem.view) + (e.key === Qt.Key_Right ? 1 : -1)
      mem.view = ks[(i + ks.length) % ks.length]
      e.accepted = true
    } else if (e.key === Qt.Key_Slash) {
      mem.view = "facts"
      Qt.callLater(function () { if (factsLoader.item) factsLoader.item.focusSearch() })
      e.accepted = true
    }
  }

  // -------------------------------------------------------------- sub-nav
  Row {
    id: seg
    anchors { left: parent.left; top: parent.top; leftMargin: 16; topMargin: 12 }
    spacing: 6
    Repeater {
      model: mem.views
      Rectangle {
        required property var modelData
        readonly property bool on: mem.view === modelData.k
        width: segText.implicitWidth + (segN.visible ? segN.implicitWidth + 8 : 0) + 24
        height: 30
        radius: 15
        color: on ? Theme.alpha(Theme.accent, 0.16) : segArea.containsMouse ? Theme.alpha(Theme.surface0, 0.5) : Theme.transparent
        border.width: 1
        border.color: on ? Theme.alpha(Theme.accent, 0.5) : Theme.alpha(Theme.overlay0, 0.25)
        Row {
          anchors.centerIn: parent
          spacing: 8
          Text {
            id: segText
            text: modelData.label
            color: parent.parent.on ? Theme.text : Theme.subtext0
            font.family: RoomLook.sans
            font.pixelSize: RoomLook.meta
            font.weight: parent.parent.on ? Font.DemiBold : Font.Medium
            renderType: Text.QtRendering
          }
          Text {
            id: segN
            visible: modelData.n > 0
            text: String(modelData.n)
            color: modelData.k === "inbox" ? Theme.peach : Theme.overlay0
            font.family: RoomLook.mono
            font.pixelSize: RoomLook.small
            renderType: Text.QtRendering
          }
        }
        MouseArea {
          id: segArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: mem.view = modelData.k
        }
      }
    }
  }

  Text {
    anchors { right: parent.right; rightMargin: 18; verticalCenter: seg.verticalCenter }
    text: mem.note
    color: Theme.green
    font.family: RoomLook.sans
    font.pixelSize: RoomLook.meta
    renderType: Text.QtRendering
  }

  Item {
    id: body
    anchors { left: parent.left; right: parent.right; top: seg.bottom; bottom: parent.bottom; topMargin: 10 }

    // ------------------------------------------------------------- inbox
    ListView {
      id: inboxList
      anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
      visible: mem.view === "inbox"
      clip: true
      spacing: 8
      bottomMargin: 12
      model: EarsModel.inbox
      boundsBehavior: Flickable.StopAtBounds
      header: Text {
        width: inboxList.width
        height: implicitHeight + 10
        leftPadding: 4
        text: EarsModel.inbox.length > 0
          ? "Ori noticed these in your calls. Accept the ones that are true."
          : ""
        color: Theme.subtext0
        wrapMode: Text.Wrap
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.meta
      }
      delegate: Rectangle {
        required property var modelData
        width: inboxList.width
        height: inCol.implicitHeight + 24
        radius: RoomLook.radius
        color: RoomLook.raised
        Column {
          id: inCol
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
          spacing: 5
          Text {
            width: parent.width - 150
            text: modelData.summary || modelData.name
            color: Theme.text
            wrapMode: Text.Wrap
            font.family: RoomLook.sans
            font.pixelSize: RoomLook.body
            font.weight: Font.Medium
            renderType: Text.QtRendering
          }
          Text {
            width: parent.width
            visible: modelData.body !== "" && modelData.body !== modelData.summary
            text: modelData.body
            color: Theme.subtext0
            wrapMode: Text.Wrap
            lineHeight: 1.1
            font.family: RoomLook.sans
            font.pixelSize: RoomLook.meta + 1
            renderType: Text.QtRendering
          }
          Text {
            text: modelData.name + "   ·   " + mem.fromCall(modelData.id)
            color: Theme.overlay0
            font.family: RoomLook.mono
            font.pixelSize: RoomLook.small - 1
            renderType: Text.QtRendering
          }
        }
        Row {
          anchors { right: parent.right; top: parent.top; margins: 10 }
          spacing: 6
          RoomButton { compact: true; text: "Accept"; kind: "good"; tint: Theme.green; onClicked: EarsModel.acceptInbox(modelData.id) }
          RoomButton { compact: true; text: "Reject"; onClicked: EarsModel.rejectInbox(modelData.id) }
        }
      }
      Text {
        anchors.centerIn: parent
        visible: EarsModel.inbox.length === 0
        width: parent.width - 60
        horizontalAlignment: Text.AlignHCenter
        text: "Nothing waiting. After a call, Ori proposes facts worth remembering here."
        color: Theme.overlay0
        wrapMode: Text.Wrap
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.body
      }
    }

    // ----------------------------------------------------------- profile
    Item {
      id: prof
      anchors.fill: parent
      visible: mem.view === "profile"
      property bool dirty: false
      readonly property string path: EarsModel.stateDir + "/profile.md"

      FileView {
        id: profileFile
        path: prof.path
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: if (!prof.dirty) editor.text = profileFile.text()
      }

      function save() {
        profileFile.setText(editor.text)
        prof.dirty = false
        mem.note = "Profile saved"
        noteClear.restart()
      }

      Text {
        id: profHelp
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 16; rightMargin: 16 }
        text: "Always in Ori's context, every call. Keep it short."
        color: Theme.subtext0
        wrapMode: Text.Wrap
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.meta
      }

      Rectangle {
        id: well
        anchors { left: parent.left; right: parent.right; top: profHelp.bottom; bottom: profActs.top
                  leftMargin: 12; rightMargin: 12; topMargin: 10; bottomMargin: 10 }
        radius: RoomLook.radius
        color: RoomLook.well
        border.width: 1
        border.color: editor.activeFocus ? Theme.alpha(Theme.accent, 0.5) : RoomLook.hairline

        Flickable {
          id: edFlick
          anchors { fill: parent; margins: 12 }
          contentWidth: width
          contentHeight: editor.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          TextEdit {
            id: editor
            width: edFlick.width
            color: Theme.text
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            selectionColor: OriLook.selection
            selectedTextColor: OriLook.selectionInk
            font.family: RoomLook.sans
            font.pixelSize: RoomLook.body
            renderType: Text.QtRendering
            onTextChanged: if (activeFocus) prof.dirty = editor.text !== profileFile.text()
            onCursorRectangleChanged: {
              var r = cursorRectangle
              if (r.y < edFlick.contentY) edFlick.contentY = r.y
              else if (r.y + r.height > edFlick.contentY + edFlick.height) edFlick.contentY = r.y + r.height - edFlick.height
            }
            Keys.onPressed: function (e) {
              if (e.key === Qt.Key_S && (e.modifiers & Qt.ControlModifier)) { prof.save(); e.accepted = true }
              else if (e.key === Qt.Key_Escape) { mem.forceActiveFocus(); e.accepted = true }
            }
          }
        }
      }

      Row {
        id: profActs
        anchors { left: parent.left; bottom: parent.bottom; leftMargin: 16; bottomMargin: 14 }
        spacing: 8
        RoomButton { text: "Save"; kind: "primary"; enabled: prof.dirty; onClicked: prof.save() }
        RoomButton {
          text: "Revert"
          visible: prof.dirty
          onClicked: { editor.text = profileFile.text(); prof.dirty = false }
        }
        RoomButton {
          text: "Open in editor"
          onClicked: Quickshell.execDetached(["kitty", "-e", Quickshell.env("EDITOR") || "micro", prof.path])
        }
      }
      Text {
        anchors { right: parent.right; rightMargin: 18; verticalCenter: profActs.verticalCenter }
        text: prof.dirty ? "unsaved  ·  Ctrl+S" : ""
        color: Theme.yellow
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.small
      }
    }

    // ------------------------------------------------------------- calls
    ListView {
      id: callList
      anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
      visible: mem.view === "calls"
      clip: true
      spacing: 14
      bottomMargin: 12
      model: EarsModel.calls
      boundsBehavior: Flickable.StopAtBounds
      delegate: Item {
        required property var modelData
        width: callList.width
        height: cCol.implicitHeight
        Rectangle {
          x: 6; y: 6
          width: 2; height: parent.height - 6
          radius: 1
          color: Theme.alpha(Theme.lavender, 0.35)
        }
        Column {
          id: cCol
          anchors { left: parent.left; right: parent.right; leftMargin: 20; rightMargin: 6 }
          spacing: 5
          Text {
            text: modelData.when + (modelData.turns ? "   ·   " + modelData.turns + (modelData.turns === 1 ? " line" : " lines") : "")
            color: Theme.subtext1
            font.family: RoomLook.sans
            font.pixelSize: RoomLook.meta
            font.weight: Font.DemiBold
            renderType: Text.QtRendering
          }
          Text {
            width: parent.width
            text: modelData.summary
            color: Theme.subtext0
            wrapMode: Text.Wrap
            lineHeight: 1.12
            font.family: RoomLook.sans
            font.pixelSize: RoomLook.meta + 1
            renderType: Text.QtRendering
          }
          Flow {
            width: parent.width
            spacing: 6
            visible: (modelData.topics || []).length > 0
            Repeater {
              model: modelData.topics || []
              Rectangle {
                required property var modelData
                width: tp.implicitWidth + 14; height: 20; radius: 10
                color: Theme.alpha(Theme.overlay0, 0.14)
                Text {
                  id: tp
                  anchors.centerIn: parent
                  text: modelData
                  color: Theme.subtext0
                  font.family: RoomLook.sans
                  font.pixelSize: RoomLook.small - 1
                }
              }
            }
          }
        }
      }
      Text {
        anchors.centerIn: parent
        visible: EarsModel.calls.length === 0
        text: "No calls yet."
        color: Theme.overlay0
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.body
      }
    }

    // ------------------------------------------------------------- facts
    Loader {
      id: factsLoader
      anchors.fill: parent
      active: mem.view === "facts"
      sourceComponent: factsC
    }
    Component {
      id: factsC
      Item {
        function focusSearch() { search.forceActiveFocus() }
        readonly property var hits: {
          var q = search.text.toLowerCase().trim()
          var all = EarsModel.memories
          if (q === "") return all
          var out = []
          for (var i = 0; i < all.length; i++) {
            var f = all[i]
            if ((f.name + " " + f.summary + " " + f.body).toLowerCase().indexOf(q) >= 0) out.push(f)
          }
          return out
        }
        Rectangle {
          id: sbox
          anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 12; rightMargin: 12 }
          height: 34
          radius: 17
          color: RoomLook.well
          border.width: 1
          border.color: search.activeFocus ? Theme.alpha(Theme.accent, 0.5) : RoomLook.hairline
          TextInput {
            id: search
            anchors { fill: parent; leftMargin: 16; rightMargin: 16 }
            verticalAlignment: TextInput.AlignVCenter
            color: Theme.text
            font.family: RoomLook.sans
            font.pixelSize: RoomLook.meta + 1
            selectByMouse: true
            Keys.onEscapePressed: function (e) { if (text !== "") text = ""; else mem.forceActiveFocus() }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: search.text === ""
              text: "Search " + EarsModel.memories.length + " facts"
              color: Theme.overlay0
              font: search.font
            }
          }
        }
        ListView {
          id: factList
          anchors { left: parent.left; right: parent.right; top: sbox.bottom; bottom: parent.bottom
                    leftMargin: 12; rightMargin: 12; topMargin: 10 }
          clip: true
          spacing: 4
          model: parent.hits
          boundsBehavior: Flickable.StopAtBounds
          property int open: -1
          delegate: Rectangle {
            required property var modelData
            required property int index
            readonly property bool expanded: factList.open === index
            width: factList.width
            height: fCol.implicitHeight + 16
            radius: RoomLook.radius
            color: expanded ? RoomLook.raised : fArea.containsMouse ? Theme.alpha(Theme.surface0, 0.3) : Theme.transparent
            Column {
              id: fCol
              z: 1  // above the row's expand area, so Forget gets its own click (text passes through)
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8; leftMargin: 10 }
              spacing: 3
              Text {
                width: parent.width
                text: modelData.summary || modelData.name
                color: Theme.text
                wrapMode: Text.Wrap
                font.family: RoomLook.sans
                font.pixelSize: RoomLook.body - 1
                renderType: Text.QtRendering
              }
              Text {
                text: modelData.name + (modelData.modified ? "   ·   " + modelData.modified : "") + (modelData.pinned ? "   ·   pinned" : "")
                color: Theme.overlay0
                font.family: RoomLook.mono
                font.pixelSize: RoomLook.small - 1
              }
              RoomButton {
                visible: expanded
                compact: true
                text: "Forget"
                onClicked: { factList.open = -1; EarsModel.forgetMemory(modelData.file) }
              }
              Text {
                visible: expanded
                width: parent.width
                text: modelData.body
                color: Theme.subtext0
                wrapMode: Text.Wrap
                topPadding: 4
                font.family: RoomLook.sans
                font.pixelSize: RoomLook.meta + 1
              }
            }
            MouseArea {
              id: fArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: factList.open = expanded ? -1 : index
            }
          }
          Text {
            anchors.centerIn: parent
            visible: factList.count === 0
            width: parent.width - 60
            horizontalAlignment: Text.AlignHCenter
            text: EarsModel.memories.length === 0
              ? "No facts yet. Ori saves lasting ones after calls, or say “remember that…”."
              : "Nothing matches."
            color: Theme.overlay0
            wrapMode: Text.Wrap
            font.family: RoomLook.sans
            font.pixelSize: RoomLook.body
          }
        }
      }
    }
  }
}
