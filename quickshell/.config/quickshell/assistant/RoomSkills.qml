import QtQuick
import Quickshell
import ".."

// Skills: Ori's playbooks. Drafts first -- what it learned after a call and wants your OK on
// (Keep makes it a skill from the next call; Drop throws it away) -- then every skill, built-in
// or learned, with how often it was used. Click a row (or Enter) to read it in full; a learned
// skill can be forgotten (the built-in it replaced comes back).
FocusScope {
  id: sk

  property int current: 0
  property string open: ""       // key of the expanded row
  property string openText: ""
  property string confirming: "" // forget asks first

  readonly property var rows: {
    var out = [], i
    var d = EarsModel.skillDrafts
    for (i = 0; i < d.length; i++)
      out.push({ key: "draft:" + d[i].name, draft: true, name: d[i].name, action: d[i].action,
                 line: d[i].why || d[i].description, sub: d[i].description, body: d[i].body, when: d[i].when })
    var s = EarsModel.skills
    for (i = 0; i < s.length; i++)
      out.push({ key: "skill:" + s[i].name, draft: false, name: s[i].name, learned: s[i].learned,
                 line: s[i].description, uses: s[i].uses || 0, last: s[i].last || "" })
    return out
  }
  readonly property var sel: rows.length ? rows[Math.max(0, Math.min(current, rows.length - 1))] : null

  Component.onCompleted: forceActiveFocus()

  function toggle(r) {
    if (!r) return
    if (open === r.key) { open = ""; return }
    open = r.key
    if (r.draft) { openText = r.body; return }
    openText = "…"
    EarsModel.skillText(r.name, function (t) {
      if (sk.open === r.key) sk.openText = t.replace(/^---[\s\S]*?\n---\s*\n/, "").trim()
    })
  }

  Keys.onPressed: function (e) {
    if (e.key === Qt.Key_Down) { current = Math.min(rows.length - 1, current + 1); list.positionViewAtIndex(current, ListView.Contain); e.accepted = true }
    else if (e.key === Qt.Key_Up) { current = Math.max(0, current - 1); list.positionViewAtIndex(current, ListView.Contain); e.accepted = true }
    else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && sel) { toggle(sel); e.accepted = true }
  }

  ListView {
    id: list
    anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
    clip: true
    spacing: 6
    bottomMargin: 12
    model: sk.rows
    boundsBehavior: Flickable.StopAtBounds

    section.property: "draft"
    section.criteria: ViewSection.FullString
    section.delegate: Item {
      required property string section
      width: list.width
      height: 30
      Text {
        anchors { left: parent.left; leftMargin: 6; bottom: parent.bottom; bottomMargin: 6 }
        text: parent.section === "true" ? "Learned after calls, waiting for you" : "Skills"
        color: parent.section === "true" ? Theme.peach : Theme.subtext1
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.meta
        font.weight: Font.DemiBold
        renderType: Text.QtRendering
      }
    }

    delegate: Rectangle {
      id: row
      required property var modelData
      required property int index
      readonly property var r: modelData
      readonly property bool on: index === sk.current
      readonly property bool expanded: sk.open === r.key
      width: list.width
      height: col.implicitHeight + 20
      radius: RoomLook.radius
      color: r.draft ? Theme.alpha(Theme.peach, on ? 0.12 : 0.07)
                     : on ? Theme.alpha(Theme.surface0, 0.55) : hover.containsMouse ? Theme.alpha(Theme.surface0, 0.28) : Theme.transparent
      border.width: on || r.draft ? 1 : 0
      border.color: r.draft ? Theme.alpha(Theme.peach, 0.35) : Theme.alpha(Theme.overlay0, 0.25)

      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        onClicked: { sk.current = row.index; sk.toggle(row.r); sk.forceActiveFocus() }
      }

      Column {
        id: col
        anchors { left: parent.left; right: acts.left; top: parent.top; margins: 10; rightMargin: 10 }
        spacing: 4
        Row {
          spacing: 8
          Text {
            text: row.r.name
            color: Theme.text
            font.family: RoomLook.mono
            font.pixelSize: RoomLook.meta + 1
            font.weight: Font.Medium
            renderType: Text.QtRendering
          }
          Rectangle {
            width: tag.implicitWidth + 12; height: 18; radius: 9
            color: Theme.alpha(row.r.draft ? Theme.peach : row.r.learned ? Theme.accent : Theme.overlay0, 0.15)
            Text {
              id: tag
              anchors.centerIn: parent
              text: row.r.draft ? (row.r.action === "edit" ? "improved" : "new") : row.r.learned ? "learned" : "built-in"
              color: row.r.draft ? Theme.peach : row.r.learned ? Theme.accent : Theme.subtext0
              font.family: RoomLook.sans
              font.pixelSize: RoomLook.small - 1
              renderType: Text.QtRendering
            }
          }
        }
        Text {
          width: parent.width
          text: row.r.line
          color: row.r.draft ? Theme.text : Theme.subtext0
          wrapMode: Text.Wrap
          maximumLineCount: row.expanded ? 6 : 2
          elide: Text.ElideRight
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.meta + 1
          renderType: Text.QtRendering
        }
        Text {
          visible: !row.r.draft && !row.expanded
          text: row.r.uses ? "used " + row.r.uses + "×" + (row.r.last ? ", last " + row.r.last : "") : "not used yet"
          color: Theme.overlay0
          font.family: RoomLook.mono
          font.pixelSize: RoomLook.small - 1
          renderType: Text.QtRendering
        }
        Rectangle {  // the playbook itself
          visible: row.expanded
          width: parent.width
          height: body.implicitHeight + 16
          radius: RoomLook.radius
          color: RoomLook.well
          Text {
            id: body
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
            text: sk.openText
            color: Theme.subtext1
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            font.family: RoomLook.mono
            font.pixelSize: RoomLook.small
            renderType: Text.QtRendering
          }
        }
      }

      Row {
        id: acts
        anchors { right: parent.right; rightMargin: 10; top: parent.top; topMargin: 10 }
        spacing: 6
        RoomButton { visible: row.r.draft; compact: true; text: "Keep"; kind: "good"; tint: Theme.green; onClicked: EarsModel.skillAction("keep", row.r.name) }
        RoomButton { visible: row.r.draft; compact: true; text: "Drop"; onClicked: EarsModel.skillAction("drop", row.r.name) }
        RoomButton {
          visible: !row.r.draft && row.r.learned && (row.on || hover.containsMouse || sk.confirming === row.r.name)
          compact: true
          kind: "danger"
          text: sk.confirming === row.r.name ? "Forget it?" : "Forget"
          onClicked: {
            if (sk.confirming === row.r.name) { EarsModel.skillAction("forget", row.r.name); sk.confirming = "" }
            else sk.confirming = row.r.name
          }
        }
      }
    }
  }

  Text {
    anchors.centerIn: list
    visible: sk.rows.length === 0
    text: EarsModel.skillsLoaded ? "No skills yet." : "Reading Ori's skills…"
    color: Theme.overlay0
    font.family: RoomLook.sans
    font.pixelSize: RoomLook.body
  }
}
