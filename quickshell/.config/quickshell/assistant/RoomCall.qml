import QtQuick
import ".."

// Call: the one view that answers "what is Ori doing with my voice right now".
//
//   hero        the orb (the panel's perch for it on this tab), the mode in
//               its own colour, the call clock, and the one button: start or
//               end the call
//   pipeline    the stations an utterance passes, lit as it passes them
//   working on  what the call has Ori doing: jobs running (live clock),
//               workers it started (their state now), the last few done,
//               and what he just did on the side: a plugin turned on/off
//               (briefly) and actions he performed in your apps (`drive`)
//   transcript  the call, after the fact: Ori's lines appear as they are
//               SPOKEN, not as the model writes them (the orb's rule: Ori
//               talks, the screen does not read ahead of it)
Item {
  id: call

  // The panel is open and this tab is showing: the only time anything here
  // animates or ticks.
  property bool live: false
  property real orbLevel: -1
  property bool orbHidden: false
  readonly property bool online: EarsModel.linked
  readonly property string mode: !online ? "offline" : EarsModel.call ? EarsModel.mode : "closed"
  readonly property color hue: RoomLook.modeColor(mode)

  // The hero orb's centre, in this item's coordinates (the panel docks the
  // overlay orb here).
  readonly property point orbCentre: Qt.point(hero.x + orb.x + orb.width / 2, hero.y + orb.y + orb.height / 2)

  // Display clock: one tick a second, only while it has a call clock to show.
  property real nowMs: Date.now()
  Timer {
    interval: 1000
    repeat: true
    running: call.live && (EarsModel.call || EarsModel.running > 0 || work.lastActivity > 0 && call.nowMs - work.lastActivity < work.driveKeep + 2000)
    triggeredOnStart: true
    onTriggered: call.nowMs = Date.now()
  }

  readonly property var lastCall: EarsModel.calls.length > 0 ? EarsModel.calls[0] : null

  // ================================================================= hero
  Item {
    id: hero
    anchors { left: parent.left; right: parent.right; top: parent.top }
    height: 92

    Orb {
      id: orb
      x: 6
      y: 14
      size: 28
      alive: call.live
      breathe: true
      bright: true
      floating: false
      // The level the orb pulses on: the panel hands in the published one
      // (mic while you talk, the speaker while Ori does); alone, the mic.
      level: call.orbLevel >= 0 ? call.orbLevel
           : EarsModel.mode === "hearing" ? Math.max(0, Math.min(1, (EarsModel.level - EarsModel.floor) / 35)) : 0
      mode: RoomLook.orbMode(call.mode)
      opacity: call.online ? 1 : 0.55
      scale: call.orbHidden ? 0 : 1
      Behavior on scale { NumberAnimation { duration: 420; easing.type: Easing.OutBack } }
    }

    Column {
      anchors { left: orb.right; leftMargin: 2; right: action.left; rightMargin: 12
                verticalCenter: orb.verticalCenter; verticalCenterOffset: -2 }
      spacing: 3

      Text {
        width: parent.width
        text: RoomLook.modeWord(call.mode)
        color: call.mode === "closed" ? Theme.subtext1 : call.hue
        elide: Text.ElideRight
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.hero
        font.weight: Font.DemiBold
        renderType: Text.QtRendering
        Behavior on color { ColorAnimation { duration: Style.anim.colorDuration } }
      }
      Text {
        width: parent.width
        text: !call.online ? "The voice daemon isn't running."
          : !EarsModel.call ? "Right Alt opens a call from anywhere."
          : (EarsModel.callSince > 0 ? RoomLook.ago(call.nowMs - EarsModel.callSince) + " in call" : "In call")
            + (EarsModel.youTurns > 0 ? "  ·  " + EarsModel.youTurns + (EarsModel.youTurns === 1 ? " turn" : " turns") : "")
        color: Theme.subtext0
        elide: Text.ElideRight
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.meta
        renderType: Text.QtRendering
      }
    }

    RoomButton {
      id: action
      anchors { right: parent.right; rightMargin: 16; verticalCenter: orb.verticalCenter }
      text: !call.online ? "Start voice" : EarsModel.call ? "End call" : "Start call"
      kind: !call.online || !EarsModel.call ? "primary" : "danger"
      tint: Theme.sapphire
      onClicked: {
        if (!call.online) EarsModel.startDaemon()
        else if (EarsModel.call) EarsModel.closeCall()
        else EarsModel.openCall()
      }
    }
  }

  // ============================================================= pipeline
  // An utterance's path, station by station. Gate is the loudness meter's
  // job below, and the mic/echo stations are always on, so six remain.
  Item {
    id: pipe
    anchors { left: parent.left; right: parent.right; top: hero.bottom; topMargin: 12
              leftMargin: 16; rightMargin: 16 }
    height: 46
    opacity: EarsModel.call ? 1 : 0.45

    readonly property var stops: [
      { k: "vad", label: "Speech" }, { k: "turn", label: "Finished?" },
      { k: "voiceid", label: "You?" }, { k: "stt", label: "Words" },
      { k: "llm", label: "Reply" }, { k: "tts", label: "Voice" }
    ]
    readonly property real step: width / stops.length

    // the line the stations sit on
    Rectangle {
      x: pipe.step / 2
      width: pipe.width - pipe.step
      y: 5
      height: 1
      color: RoomLook.hairline
    }

    Repeater {
      model: pipe.stops
      Item {
        id: stop
        required property var modelData
        required property int index
        readonly property var node: EarsModel.nodes[modelData.k] || null
        readonly property string st: node ? node.status : "idle"
        readonly property color c: st === "active" ? call.hue
          : st === "done" ? Theme.green
          : st === "reject" ? Theme.red
          : st === "wait" ? Theme.yellow
          : Theme.surface2
        x: index * pipe.step
        width: pipe.step
        height: pipe.height

        Rectangle {
          anchors { horizontalCenter: parent.horizontalCenter; top: parent.top }
          width: 11; height: 11; radius: 5.5
          color: stop.st === "idle" ? Theme.base : stop.c
          border.width: stop.st === "idle" ? 1 : 0
          border.color: Theme.surface2
          Behavior on color { ColorAnimation { duration: Style.anim.quick } }
          // the active station's halo
          Rectangle {
            anchors.centerIn: parent
            width: 21; height: 21; radius: 10.5
            color: Theme.transparent
            border.width: 2
            border.color: Theme.alpha(stop.c, 0.35)
            visible: stop.st === "active"
          }
        }
        Text {
          id: stLabel
          anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 17 }
          text: stop.modelData.label
          color: stop.st === "idle" ? Theme.overlay0 : Theme.subtext1
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.small
          renderType: Text.QtRendering
        }
        Text {
          anchors { horizontalCenter: parent.horizontalCenter; top: stLabel.bottom; topMargin: 1 }
          text: stop.node && stop.node.ms !== null && stop.node.ms !== undefined && stop.node.ms > 0
                ? Math.round(stop.node.ms) + " ms"
                : stop.st === "reject" ? "no" : stop.st === "wait" ? "wait" : ""
          color: stop.st === "reject" ? Theme.red : stop.st === "wait" ? Theme.yellow : Theme.overlay0
          font.family: RoomLook.mono
          font.pixelSize: RoomLook.small - 1
          renderType: Text.QtRendering
        }
      }
    }
  }

  // ============================================================ working on
  // What this call has Ori doing in the background: jobs still running with
  // a live clock, workers it started and what they are up to now, and the
  // last few finished jobs, dimmed, with what they came back with.
  Column {
    id: work
    anchors { left: parent.left; right: parent.right; top: pipe.bottom; topMargin: 14
              leftMargin: 16; rightMargin: 16 }
    spacing: 4

    // this call's jobs (the whole session's when the call's start is unknown)
    readonly property var mine: {
      var out = [], t = EarsModel.tasks
      var since = EarsModel.call && EarsModel.callSince > 0 ? EarsModel.callSince - 1000 : 0
      for (var i = 0; i < t.length; i++)
        if (t[i].t0 >= since && t[i].kind !== "end_call") out.push(t[i])
      return out
    }
    readonly property var running: mine.filter(function (x) { return x.status === "start" })
    readonly property var finished: {
      var d = mine.filter(function (x) { return x.status !== "start" && x.kind !== "start_task" && x.kind !== "worker" })
      return d.slice(Math.max(0, d.length - (running.length + workers.length > 2 ? 2 : 4))).reverse()
    }
    // workers this call started, with their state as dito reports it now
    readonly property var workers: {
      var out = [], seen = ({})
      for (var i = 0; i < mine.length; i++) {
        var x = mine[i]
        if (x.kind !== "start_task" || x.status !== "done") continue
        var name = String((x.args || {}).name || "")
        if (name === "" || seen[name]) continue
        seen[name] = true
        var live = null
        for (var j = 0; j < EarsModel.workers.length; j++)
          if (EarsModel.workers[j].name === name) { live = EarsModel.workers[j]; break }
        out.push({ name: name, repo: live ? live.repo : String((x.args || {}).repo || ""),
                   state: live ? live.state : "stopped", subject: live ? live.subject : "" })
      }
      return out
    }
    Component.onCompleted: if (workers.length > 0 || mine.some(function (x) { return x.kind === "start_task" })) EarsModel.refreshWorkers()

    // What he did on the side, recent only: a plugin switch for 20 s, an app
    // action for 90 s (the newest three). A fresh call's reset is not news.
    readonly property int pluginKeep: 20000
    readonly property int driveKeep: 90000
    readonly property real lastActivity: EarsModel.activity.length > 0 ? EarsModel.activity[EarsModel.activity.length - 1].ts : 0
    readonly property var recent: {
      var out = [], a = EarsModel.activity, drives = 0
      for (var i = a.length - 1; i >= 0 && out.length < 4; i--) {
        var x = a[i], age = call.nowMs - x.ts
        if (x.kind === "plugin" && x.by !== "new call" && age < pluginKeep) out.push(x)
        else if (x.kind === "drive" && age < driveKeep && drives < 3) { out.push(x); drives++ }
      }
      return out.reverse()
    }

    function word(k) {
      switch (String(k)) {
      case "think": return "Thinking"
      case "web_search": return "Searching"
      case "web_fetch": return "Reading"
      case "bash": return "Running"
      case "weather": return "Weather"
      case "start_task": return "New worker"
      case "message_task": return "Messaging"
      case "stop_task": return "Stopping"
      case "worker": return "Worker"
      case "set_timer": case "timer": return "Timer"
      case "media": return "Media"
      case "task_status": return "Workers"
      case "recent_calls": return "Past calls"
      default: return k.indexOf("memory") >= 0 ? "Memory" : String(k).replace(/_/g, " ")
      }
    }
    function what(t) {
      var a = t.args || ({})
      switch (String(t.kind)) {
      case "think": return a.question || ""
      case "web_search": case "memory_search": case "search_memory": return a.query || ""
      case "web_fetch": return a.url || ""
      case "bash": return a.command || ""
      case "weather": return a.place || ""
      case "start_task": return (a.name || "") + (a.repo ? "  in " + a.repo : "")
      case "message_task": return (a.worker || "") + (a.text ? ": " + a.text : "")
      case "stop_task": return a.worker || ""
      case "worker": return a.name || ""
      case "set_timer": case "timer": return (a.label || "") + (a.seconds ? "  " + a.seconds + " s" : "")
      }
      var vals = []
      for (var k in a) vals.push(String(a[k]))
      return vals.join(", ")
    }
    function result(t) {
      var s = String(t.summary || "").replace(/^exit 0\n/, "").trim()
      var nl = s.indexOf("\n")
      return nl >= 0 ? s.slice(0, nl) : s
    }

    Item {
      width: parent.width
      height: 22
      Text {
        id: workTitle
        anchors.verticalCenter: parent.verticalCenter
        text: "Working on"
        color: Theme.subtext1
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.meta
        font.weight: Font.DemiBold
        renderType: Text.QtRendering
      }
      Text {
        anchors { left: workTitle.right; leftMargin: 10; baseline: workTitle.baseline }
        text: work.running.length === 0 && work.workers.length === 0 ? (work.recent.length > 0 ? "" : "Nothing running")
            : work.running.length > 0 ? work.running.length + " running" : ""
        color: work.running.length > 0 ? Theme.blue : Theme.overlay0
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.small
        renderType: Text.QtRendering
      }
    }

    // ---- running now
    Repeater {
      model: work.running
      Rectangle {
        required property var modelData
        width: work.width
        height: 30
        radius: 15
        color: Theme.alpha(Theme.blue, 0.10)
        border.width: 1
        border.color: Theme.alpha(Theme.blue, 0.28)
        Rectangle {
          id: pulse
          anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
          width: 7; height: 7; radius: 3.5
          color: Theme.blue
          SequentialAnimation on opacity {
            running: call.live
            loops: Animation.Infinite
            NumberAnimation { from: 1; to: 0.25; duration: 650; easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.25; to: 1; duration: 650; easing.type: Easing.InOutSine }
          }
        }
        Text {
          id: rk
          anchors { left: pulse.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
          text: work.word(modelData.kind)
          color: Theme.blue
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.meta
          font.weight: Font.DemiBold
          renderType: Text.QtRendering
        }
        Text {
          anchors { left: rk.right; leftMargin: 10; right: rAge.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
          text: work.what(modelData).replace(/\s+/g, " ")
          color: Theme.text
          elide: Text.ElideRight
          font.family: modelData.kind === "bash" ? RoomLook.mono : RoomLook.sans
          font.pixelSize: modelData.kind === "bash" ? RoomLook.small : RoomLook.meta
          renderType: Text.QtRendering
        }
        Text {
          id: rAge
          anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
          text: RoomLook.ago(call.nowMs - modelData.t0)
          color: Theme.subtext0
          font.family: RoomLook.mono
          font.pixelSize: RoomLook.small
          renderType: Text.QtRendering
        }
      }
    }

    // ---- workers this call started
    Repeater {
      model: work.workers
      Item {
        required property var modelData
        width: work.width
        height: 28
        Rectangle {
          id: wdot
          anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
          width: 7; height: 7; radius: 3.5
          color: RoomLook.stateColor(modelData.state)
        }
        Text {
          id: wn
          anchors { left: wdot.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
          text: modelData.name
          color: Theme.text
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.meta
          font.weight: Font.DemiBold
          renderType: Text.QtRendering
        }
        Text {
          anchors { left: wn.right; leftMargin: 10; right: ws.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
          text: modelData.subject || modelData.repo
          color: Theme.subtext0
          elide: Text.ElideRight
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.small
          renderType: Text.QtRendering
        }
        Text {
          id: ws
          anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
          text: RoomLook.stateWord(modelData.state)
          color: RoomLook.stateColor(modelData.state)
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.small
          renderType: Text.QtRendering
        }
      }
    }

    // ---- what he just did: plugins switched, actions in your apps
    Repeater {
      model: work.recent
      Item {
        required property var modelData
        readonly property bool drive: modelData.kind === "drive"
        readonly property color c: !modelData.ok && drive ? Theme.red : drive ? RoomLook.drive
                                 : modelData.ok ? Theme.sapphire : Theme.overlay0
        width: work.width
        height: 24
        Text {
          id: am
          anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
          width: 12
          text: parent.drive ? "▸" : parent.modelData.ok ? "+" : "−"
          color: parent.c
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.meta
          renderType: Text.QtRendering
        }
        Text {
          id: ak
          anchors { left: am.right; leftMargin: 7; verticalCenter: parent.verticalCenter }
          text: parent.drive ? "Did" : "Plugin"
          color: parent.c
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.small
          font.weight: Font.DemiBold
          renderType: Text.QtRendering
        }
        Text {
          anchors { left: ak.right; leftMargin: 8; right: aa.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
          text: parent.modelData.text
          color: Theme.text
          elide: Text.ElideRight
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.small + 1
          renderType: Text.QtRendering
        }
        Text {
          id: aa
          anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
          text: RoomLook.ago(Math.max(0, call.nowMs - parent.modelData.ts)) + " ago"
          color: Theme.overlay0
          font.family: RoomLook.mono
          font.pixelSize: RoomLook.small - 1
          renderType: Text.QtRendering
        }
      }
    }

    // ---- done lately, quieter
    Repeater {
      model: work.finished
      Item {
        required property var modelData
        width: work.width
        height: 24
        opacity: 0.72
        Text {
          id: fm
          anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
          width: 12
          text: modelData.status === "error" ? "×" : "✓"
          color: modelData.status === "error" ? Theme.red : Theme.green
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.meta
          renderType: Text.QtRendering
        }
        Text {
          id: fk
          anchors { left: fm.right; leftMargin: 7; verticalCenter: parent.verticalCenter }
          text: work.word(modelData.kind)
          color: Theme.subtext1
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.small
          font.weight: Font.DemiBold
          renderType: Text.QtRendering
        }
        Text {
          anchors { left: fk.right; leftMargin: 8; right: fd.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
          text: (work.result(modelData) || work.what(modelData)).replace(/\s+/g, " ")
          color: Theme.subtext0
          elide: Text.ElideRight
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.small
          renderType: Text.QtRendering
        }
        Text {
          id: fd
          anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
          text: modelData.ms >= 0 ? RoomLook.ms(modelData.ms)
              : modelData.t1 > 0 ? RoomLook.ms(modelData.t1 - modelData.t0) : ""
          color: Theme.overlay0
          font.family: RoomLook.mono
          font.pixelSize: RoomLook.small - 1
          renderType: Text.QtRendering
        }
      }
    }
  }

  // =========================================================== transcript
  Rectangle {
    id: rule
    anchors { left: parent.left; right: parent.right; top: work.bottom; topMargin: 12 }
    height: 1
    color: RoomLook.hairline
  }

  ListView {
    id: list
    anchors { left: parent.left; right: parent.right; top: rule.bottom; bottom: parent.bottom
              leftMargin: 12; rightMargin: 12 }
    clip: true
    spacing: 10
    topMargin: 12
    bottomMargin: 12
    model: EarsModel.entries
    boundsBehavior: Flickable.StopAtBounds
    reuseItems: false

    // Follow the newest line unless you have scrolled up to read.
    property bool follow: true
    onMovementEnded: follow = atYEnd
    onCountChanged: if (follow) Qt.callLater(positionViewAtEnd)
    onContentHeightChanged: if (follow && !moving) Qt.callLater(positionViewAtEnd)
    Component.onCompleted: positionViewAtEnd()

    // Older lines fade out under the strip above rather than being cut.
    Rectangle {
      parent: list
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: 18
      z: 2
      visible: !list.atYBeginning
      gradient: Gradient {
        GradientStop { position: 0; color: Theme.alpha(Theme.base, 0.5) }
        GradientStop { position: 1; color: Theme.alpha(Theme.base, 0) }
      }
    }

    delegate: RoomLine {
      width: list.width
      latest: index === EarsModel.lastOri
      speakingNow: EarsModel.mode === "speaking"
    }
  }

  // Nothing said yet: what this is, and where the last call left off.
  Column {
    anchors { left: list.left; right: list.right; top: rule.bottom; topMargin: 22
              leftMargin: 8; rightMargin: 8 }
    spacing: 8
    visible: EarsModel.entries.count === 0

    Text {
      width: parent.width
      text: EarsModel.call ? "Say something. What you and Ori say lands here."
                           : "Nothing said yet. The conversation shows here once you talk."
      color: Theme.subtext0
      wrapMode: Text.Wrap
      font.family: RoomLook.sans
      font.pixelSize: RoomLook.body
      renderType: Text.QtRendering
    }
    Item { width: 1; height: 6; visible: call.lastCall !== null || EarsModel.summaryPending }
    Text {
      visible: EarsModel.summaryPending
      text: "Last call: summarizing it…"
      color: Theme.subtext1
      font.family: RoomLook.sans
      font.pixelSize: RoomLook.meta
      font.weight: Font.DemiBold
      renderType: Text.QtRendering
    }
    Text {
      visible: call.lastCall !== null && !EarsModel.summaryPending
      text: call.lastCall ? "Last call, " + call.lastCall.when : ""
      color: Theme.subtext1
      font.family: RoomLook.sans
      font.pixelSize: RoomLook.meta
      font.weight: Font.DemiBold
      renderType: Text.QtRendering
    }
    Text {
      visible: call.lastCall !== null && !EarsModel.summaryPending
      width: parent.width
      text: call.lastCall ? call.lastCall.summary : ""
      color: Theme.subtext0
      wrapMode: Text.Wrap
      lineHeight: 1.15
      font.family: RoomLook.sans
      font.pixelSize: RoomLook.meta + 1
      renderType: Text.QtRendering
    }
  }
}
