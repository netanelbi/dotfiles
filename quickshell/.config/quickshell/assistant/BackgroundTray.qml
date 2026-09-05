import QtQuick
import ".."

// What is running with nobody waiting on it -- given a place of its own,
// because it belongs to none of the places that already existed.
//
// A turn's tool rows are the record of one answer. The rail above the composer
// is the state of the turn in flight. A backgrounded command is neither: it
// outlives the turn that started it, it belongs to no answer, and when the
// panel is scrolled back a week nothing about it should move. So it gets a
// strip between the transcript and the rail, present exactly when there is
// something in it.
//
//   ⠿ 2 agents · 1 monitor                                  2m 14s
//
// Collapsed it is one line and a count. Opened it is a row per task: what it
// is, what it was, and how long it has been. Deliberately NOT a live feed of
// its OUTPUT: you handed the work over, and a counter ticking past on screen is
// supervision with extra steps.
//
// An agent row carries one more line, and only while it runs:
//
//   ⠿ 2 agents                                              2m 14s
//     check-algo-harness                                    184213
//       ↳ read the AlgoVsVal scoring code
//
// That is the delegate's own tool `description` -- the one line it wrote for a
// human to read. It is not output and it is not progress: it is the answer to
// "why is this still running", which a name and a clock could never give. It
// comes off OriClient.agentActivity, keyed by the handle in `job.name`.
//
// `kind` is the vocabulary (OriClient.bgKindNoun).
Item {
  id: tray

  property color accent: Theme.accent
  // The panel's frame clock, which runs while anything is in here.
  property real nowMs: 0
  property real breath: 1

  readonly property var ids: {
    var out = []
    for (var k in OriClient.bgJobs)
      // Speech renders in its own strip; this tray is about work the agent
      // is waiting on.
      if (String(OriClient.bgJobs[k].kind) !== "speak") out.push(k)
    out.sort()
    return out
  }

  readonly property int count: ids.length

  property bool open: false

  implicitHeight: count > 0
    ? head.height + (open ? rows.implicitHeight + 4 : 0) : 0
  height: implicitHeight
  clip: true

  Behavior on height {
    NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing }
  }

  Fmt { id: fmt }

  // The oldest thing still running. One number, because a strip that printed a
  // clock per task would be four numbers changing every frame on a card whose
  // point is the conversation.
  readonly property real oldestMs: {
    var t = 0
    for (var k in OriClient.bgJobs) {
      if (String(OriClient.bgJobs[k].kind) === "speak") continue
      var age = tray.nowMs - OriClient.bgJobs[k].since
      if (age > t) t = age
    }
    return Math.max(0, t)
  }

  // ------------------------------------------------------------- the line
  Item {
    id: head
    anchors { left: parent.left; right: parent.right; top: parent.top }
    height: count > 0 ? 24 : 0

    Rectangle {
      anchors.fill: parent
      color: Theme.alpha(Theme.surface0, 0.5)
      radius: 6
    }

    // The mark. Braille-dense rather than a spinner: it says "several things"
    // in one glyph, and it breathes on the panel's clock instead of spinning on
    // one of its own.
    Text {
      id: mark
      anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
      text: "⠿"
      color: tray.accent
      opacity: tray.breath
      font.family: Style.font.panelMono
      font.pixelSize: Style.font.panelMeta
      renderType: Text.QtRendering
    }

    Text {
      anchors { left: mark.right; leftMargin: 8; right: age.left; rightMargin: 8
                verticalCenter: parent.verticalCenter }
      text: OriClient.bgSummary
      color: Theme.subtext0
      elide: Text.ElideRight
      font.family: Style.font.panelMono
      font.pixelSize: Style.font.panelMeta
      font.weight: Style.font.boldWeight
      renderType: Text.QtRendering
    }

    Text {
      id: age
      anchors { right: caret.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
      text: fmt.duration(tray.oldestMs)
      color: Theme.overlay0
      font.family: Style.font.panelMono
      font.pixelSize: Style.font.panelMeta
      renderType: Text.QtRendering
    }

    Text {
      id: caret
      anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
      text: "›"
      color: Theme.overlay0
      rotation: tray.open ? 90 : 0
      transformOrigin: Item.Center
      font.family: Style.font.panelMono
      font.pixelSize: Style.font.panelMeta
      renderType: Text.QtRendering

      Behavior on rotation {
        NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing }
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: tray.open = !tray.open
    }
  }

  // ------------------------------------------------------------- the rows
  Column {
    id: rows
    anchors { left: parent.left; right: parent.right; top: head.bottom
              topMargin: 4; leftMargin: 10; rightMargin: 10 }
    spacing: 4
    visible: tray.open

    Repeater {
      // A count, not the array: `ids` is rebuilt whenever any job changes, and
      // a Repeater handed a fresh array resets every row it has.
      model: tray.open ? tray.ids.length : 0

      delegate: Item {
        id: task
        required property int index
        readonly property var job: OriClient.bgJobs[tray.ids[task.index]] || ({})

        // A delegate's live line, joined by its handle. Empty for a bash job,
        // and empty again the moment the delegate settles -- so the second row
        // below appears only while there is something true to put in it.
        readonly property string activity:
          String(OriClient.agentActivity[task.job.name] || "")

        width: rows.width
        implicitHeight: what.implicitHeight
          + (task.activity !== "" ? doing.implicitHeight + 1 : 0)
        height: implicitHeight

        Text {
          id: what
          anchors { left: parent.left; right: pid.left; rightMargin: 8 }
          // The delegate's handle, the command a job is running, or the kind if
          // there is nothing better.
          text: String(task.job.label || OriClient.bgKindNoun[task.job.kind] || "task")
          color: Theme.subtext0
          elide: Text.ElideRight
          maximumLineCount: 1
          font.family: Style.font.panelMono
          font.pixelSize: Style.font.panelMeta
          renderType: Text.QtRendering
        }

        // What that delegate is doing right now, in its own words. Dimmer and
        // indented, because the handle is the thing you act on and this is the
        // thing you read.
        Text {
          id: doing
          anchors { left: parent.left; leftMargin: 12
                    right: parent.right; top: what.bottom; topMargin: 1 }
          visible: task.activity !== ""
          text: "↳ " + task.activity
          color: Theme.overlay0
          elide: Text.ElideRight
          maximumLineCount: 1
          font.family: Style.font.panelMono
          font.pixelSize: Style.font.panelMeta
          renderType: Text.QtRendering
        }

        // The PID, because it is what `kill` and `bg_status` take -- the row is
        // the thing you act on, not a note that something is out there.
        Text {
          id: pid
          anchors { right: parent.right; baseline: what.baseline }
          text: task.job.pid ? String(task.job.pid) : ""
          color: Theme.overlay0
          font.family: Style.font.panelMono
          font.pixelSize: Style.font.panelMeta
          renderType: Text.QtRendering
        }

      }
    }
  }
}
