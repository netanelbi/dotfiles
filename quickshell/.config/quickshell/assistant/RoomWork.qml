import QtQuick
import Quickshell
import ".."

// Work: Ori's background tasks (live from "bgtask" events), then every Claude Code agent on the
// machine, whoever started it.
//
//   Ori's   the workers Ori itself started (the engine's workers.json)
//   Yours   every other session (a terminal claude, a --bg job, Dito main)
//
// Active first inside each group. Read on open, after a stop, and when a
// task event arrives from the call (EarsModel refreshes on those) -- never on
// a timer.
//
// Keys: up/down select, Enter opens the worker's live session in kitty,
// Ctrl+X stops it (asks first: press Ctrl+X again or click Stop), R reloads.
FocusScope {
  id: work

  property int current: 0
  property string confirming: ""   // id of the worker awaiting a stop confirm

  // Ori's background tasks first (live, from events), then the Claude Code agents
  readonly property var rows: {
    var out = []
    var ts = EarsModel.bgtasks
    for (var i = ts.length - 1; i >= 0; i--) {
      var t = ts[i]
      var live = t.state === "running" || t.state === "waiting" || t.state === "paused"
      if (!live && Date.now() - t.ts > 10 * 60 * 1000) continue  // finished ones linger 10 min
      out.push({ id: t.id, name: t.id + "  " + t.brief, state: t.state === "waiting" ? "needs_input" : t.state,
                 subject: t.result, repo: (t.origin === "handoff" ? "handed off from a long turn" : "started by Ori")
                 + (t.state === "running" ? "  ·  step " + t.round : ""), kind: "", main: false, pinned: false,
                 mine: true, active: live, task: true, group: "tasks" })
    }
    var ws = EarsModel.workers
    for (var j = 0; j < ws.length; j++) out.push(Object.assign({ task: false, group: ws[j].mine ? "ori" : "yours" }, ws[j]))
    return out
  }
  readonly property var sel: rows.length > 0 ? rows[Math.max(0, Math.min(current, rows.length - 1))] : null

  Component.onCompleted: { EarsModel.workersNote = ""; EarsModel.refreshWorkers(); forceActiveFocus() }

  function move(d) {
    if (rows.length === 0) return
    current = Math.max(0, Math.min(rows.length - 1, current + d))
    confirming = ""
    list.positionViewAtIndex(current, ListView.Contain)
  }
  function stop(w) {
    if (!w || w.main) return
    if (confirming === w.id) { if (w.task) EarsModel.stopTask(w.id); else EarsModel.stopWorker(w.id, !w.mine); confirming = "" }
    else confirming = w.id
  }

  Keys.onPressed: function (e) {
    if (e.key === Qt.Key_Down || e.key === Qt.Key_J) { move(1); e.accepted = true }
    else if (e.key === Qt.Key_Up || e.key === Qt.Key_K) { move(-1); e.accepted = true }
    else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && sel && !sel.task) { EarsModel.openWorker(sel.id); e.accepted = true }
    else if (e.key === Qt.Key_X && (e.modifiers & Qt.ControlModifier) && sel) { stop(sel); e.accepted = true }
    else if (e.key === Qt.Key_R && !(e.modifiers & Qt.ControlModifier)) { EarsModel.refreshWorkers(); e.accepted = true }
    else if (e.key === Qt.Key_Escape && confirming !== "") { confirming = ""; e.accepted = true }
  }

  // ---------------------------------------------------------------- summary
  Item {
    id: top
    anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 16; rightMargin: 16 }
    height: 46

    Text {
      id: sumText
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      text: {
        var mine = 0, theirs = 0, act = 0, tasks = 0
        for (var i = 0; i < work.rows.length; i++) {
          if (work.rows[i].task) tasks++
          else if (work.rows[i].mine) mine++; else theirs++
          if (work.rows[i].active) act++
        }
        if (work.rows.length === 0) return EarsModel.workersLoading ? "Looking for agents…" : "No agents found"
        return act + " active  ·  " + (tasks ? tasks + " tasks  ·  " : "") + mine + " Ori's  ·  " + theirs + " yours"
      }
      color: Theme.subtext0
      font.family: RoomLook.sans
      font.pixelSize: RoomLook.meta
      renderType: Text.QtRendering
    }
    RoomButton {
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      compact: true
      text: EarsModel.workersLoading ? "Reloading…" : "Reload"
      onClicked: EarsModel.refreshWorkers()
    }
  }

  Text {
    visible: EarsModel.workersError !== ""
    anchors { left: parent.left; right: parent.right; top: top.bottom; margins: 16 }
    text: EarsModel.workersError
    color: Theme.red
    wrapMode: Text.Wrap
    font.family: RoomLook.sans
    font.pixelSize: RoomLook.meta
  }

  // ------------------------------------------------------------------ list
  ListView {
    id: list
    anchors { left: parent.left; right: parent.right; top: top.bottom; bottom: hints.top
              leftMargin: 10; rightMargin: 10 }
    clip: true
    spacing: 2
    model: work.rows
    boundsBehavior: Flickable.StopAtBounds

    section.property: "group"
    section.criteria: ViewSection.FullString
    section.delegate: Item {
      required property string section
      width: list.width
      height: 34
      Text {
        anchors { left: parent.left; leftMargin: 8; bottom: parent.bottom; bottomMargin: 7 }
        text: parent.section === "tasks" ? "Ori's tasks" : parent.section === "ori" ? "Ori's workers" : "Your sessions"
        color: Theme.subtext1
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
      readonly property var w: modelData
      readonly property bool on: index === work.current
      readonly property bool asking: work.confirming === w.id
      readonly property color sc: RoomLook.stateColor(w.state)
      width: list.width
      height: col.implicitHeight + 20
      radius: RoomLook.radius
      color: on ? Theme.alpha(Theme.surface0, 0.55) : hover.containsMouse ? Theme.alpha(Theme.surface0, 0.28) : Theme.transparent
      border.width: on ? 1 : 0
      border.color: Theme.alpha(Theme.overlay0, 0.25)

      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        onClicked: { work.current = row.index; work.forceActiveFocus() }
        onDoubleClicked: if (!row.w.task) EarsModel.openWorker(row.w.id)
      }

      // state dot
      Rectangle {
        x: 12; y: 15
        width: 9; height: 9; radius: 4.5
        color: row.w.active ? row.sc : Theme.transparent
        border.width: row.w.active ? 0 : 1.5
        border.color: row.sc
      }

      Column {
        id: col
        anchors { left: parent.left; leftMargin: 32; right: acts.left; rightMargin: 10; top: parent.top; topMargin: 9 }
        spacing: 3

        Row {
          spacing: 8
          width: parent.width
          Text {
            id: nm
            width: Math.min(implicitWidth, parent.width - stChip.width - 8)
            text: row.w.name
            color: row.w.active ? Theme.text : Theme.subtext1
            elide: Text.ElideRight
            font.family: RoomLook.sans
            font.pixelSize: RoomLook.title - 1
            font.weight: Font.Medium
            renderType: Text.QtRendering
          }
          Rectangle {
            id: stChip
            anchors.verticalCenter: nm.verticalCenter
            width: stText.implicitWidth + 12; height: 18; radius: 9
            color: Theme.alpha(row.sc, 0.14)
            Text {
              id: stText
              anchors.centerIn: parent
              text: RoomLook.stateWord(row.w.state)
              color: row.sc
              font.family: RoomLook.sans
              font.pixelSize: RoomLook.small - 1
              font.weight: Font.Medium
              renderType: Text.QtRendering
            }
          }
        }
        Text {
          width: parent.width
          text: row.w.repo + (row.w.main ? "  ·  Dito main" : row.w.kind && row.w.kind !== "managed" ? "  ·  " + row.w.kind : "")
                + (row.w.pinned ? "  ·  pinned" : "")
          color: Theme.overlay0
          elide: Text.ElideRight
          font.family: RoomLook.mono
          font.pixelSize: RoomLook.small
          renderType: Text.QtRendering
        }
        Text {
          width: parent.width
          visible: row.w.subject !== ""
          text: row.w.subject
          color: Theme.subtext0
          wrapMode: Text.Wrap
          maximumLineCount: row.on ? 4 : 2
          elide: Text.ElideRight
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.meta
          renderType: Text.QtRendering
        }
      }

      // actions: on the selected row, or under the pointer
      Row {
        id: acts
        anchors { right: parent.right; rightMargin: 10; top: parent.top; topMargin: 10 }
        spacing: 6
        visible: row.on || hover.containsMouse || row.asking
        RoomButton {
          compact: true
          visible: !row.w.task
          text: "Open"
          onClicked: EarsModel.openWorker(row.w.id)
        }
        RoomButton {
          compact: true
          visible: !row.w.main && row.w.active  // nothing to stop once it's done
          kind: "danger"
          text: row.asking ? "Stop it?" : "Stop"
          onClicked: { work.current = row.index; work.stop(row.w) }
        }
      }
    }
  }

  Text {
    anchors.centerIn: list
    visible: work.rows.length === 0 && !EarsModel.workersLoading && EarsModel.workersError === ""
    text: "No tasks or Claude Code agents are running."
    color: Theme.overlay0
    font.family: RoomLook.sans
    font.pixelSize: RoomLook.body
  }

  // ----------------------------------------------------------------- hints
  Text {
    id: hints
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 12; leftMargin: 18 }
    text: work.confirming !== "" ? "Ctrl+X again or click Stop it? to stop. Esc keeps it running."
        : EarsModel.workersNote !== "" ? EarsModel.workersNote
        : "↑↓ select   Enter open in kitty   Ctrl+X stop   R reload"
    color: work.confirming !== "" ? Theme.peach
         : EarsModel.workersNote.indexOf("Could not") === 0 ? Theme.red
         : EarsModel.workersNote !== "" ? Theme.green : Theme.overlay0
    elide: Text.ElideRight
    font.family: RoomLook.sans
    font.pixelSize: RoomLook.small
    renderType: Text.QtRendering
  }
}
