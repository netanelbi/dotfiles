import QtQuick
import Quickshell
import Quickshell.Io
import ".."

// Debug: the session as the daemon logged it.
//
//   context   what the talker was sent last time, and how much of it the
//             provider's prefix cache reused (cheap and fast when high)
//   mic       the room's spectrum and the four meters vs their thresholds
//   last turn where the time went, stage by stage, and the last 20 totals
//   log       every event of this session (the same lines the daemon writes
//             to logs/*.jsonl), filterable by type. With the daemon away,
//             the newest log on disk can be loaded instead.
FocusScope {
  id: dbg

  property string filter: "all"
  readonly property color hue: RoomLook.modeColor(EarsModel.call ? EarsModel.mode : "closed")
  readonly property var filters: [
    { k: "all", label: "All" }, { k: "turn", label: "Turns" }, { k: "reply", label: "Replies" },
    { k: "stage", label: "Stages" }, { k: "task", label: "Tasks" }, { k: "barge", label: "Barge" },
    { k: "ignored", label: "Ignored" }, { k: "plugin", label: "Plugins" }, { k: "usage", label: "Usage" }, { k: "log", label: "Log" }
  ]
  function matches(t) {
    if (filter === "all") return true
    if (filter === "reply") return t === "reply" || t === "reply_end" || t === "speak" || t === "silent"
    if (filter === "plugin") return t === "plugin" || t === "drive"
    if (filter === "log") return t === "log" || t === "banner" || t === "state" || t === "memory"
    return t === filter
  }
  function tagColor(t) {
    switch (t) {
    case "turn": return Theme.sky
    case "reply": case "reply_end": case "speak": return Theme.lavender
    case "silent": return Theme.overlay0
    case "stage": return Theme.blue
    case "task": return Theme.teal
    case "barge": return Theme.peach
    case "ignored": return Theme.yellow
    case "usage": return Theme.green
    case "memory": return Theme.pink
    case "state": return Theme.mauve
    case "plugin": return Theme.sapphire
    case "drive": return RoomLook.drive
    default: return Theme.overlay0
    }
  }

  Component.onCompleted: forceActiveFocus()
  Keys.onPressed: function (e) {
    var ks = dbg.filters.map(function (f) { return f.k })
    if (e.key === Qt.Key_Left || e.key === Qt.Key_Right) {
      var i = ks.indexOf(dbg.filter) + (e.key === Qt.Key_Right ? 1 : -1)
      dbg.filter = ks[(i + ks.length) % ks.length]
      e.accepted = true
    } else if (e.key === Qt.Key_End) { log.positionViewAtEnd(); log.follow = true; e.accepted = true }
  }

  // ============================================================= context
  Item {
    id: ctx
    anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 16; rightMargin: 16; topMargin: 12 }
    height: u ? 82 : 20
    readonly property var u: EarsModel.usage.talker || null
    readonly property var th: EarsModel.usage.thinker || null
    function k(n) { return n >= 1000 ? (n / 1000).toFixed(1) + "k" : String(n) }

    Text {
      id: ctxTitle
      text: "Talker context"
      color: Theme.subtext1
      font.family: RoomLook.sans
      font.pixelSize: RoomLook.meta
      font.weight: Font.DemiBold
    }
    Text {
      anchors { left: ctxTitle.right; leftMargin: 10; baseline: ctxTitle.baseline }
      text: ctx.u ? ctx.k(ctx.u.prompt) + " tokens  ·  " + ctx.u.messages + " messages" : "nothing sent yet"
      color: Theme.subtext0
      font.family: RoomLook.mono
      font.pixelSize: RoomLook.small
    }
    // cache gauge
    Rectangle {
      id: gauge
      anchors { left: parent.left; right: hitText.left; rightMargin: 12; top: ctxTitle.bottom; topMargin: 10 }
      visible: ctx.u !== null
      height: 8
      radius: 4
      color: Theme.alpha(Theme.surface1, 0.55)
      Rectangle {
        width: ctx.u ? parent.width * Math.max(0, Math.min(1, ctx.u.hit)) : 0
        height: parent.height
        radius: 4
        color: ctx.u && ctx.u.hit >= 0.5 ? Theme.green : Theme.yellow
      }
    }
    Text {
      id: hitText
      anchors { right: parent.right; verticalCenter: gauge.verticalCenter }
      visible: ctx.u !== null
      text: ctx.u ? Math.round(ctx.u.hit * 100) + "% cached" : "–"
      color: Theme.text
      font.family: RoomLook.mono
      font.pixelSize: RoomLook.small
    }
    Text {
      id: sessLine
      anchors { left: parent.left; right: parent.right; top: gauge.bottom; topMargin: 8 }
      text: ctx.u ? "this session  " + Math.round((ctx.u.total_hit || 0) * 100) + "% cached   "
                    + ctx.k(ctx.u.total_prompt || 0) + " in   " + ctx.k(ctx.u.total_completion || 0) + " out   "
                    + (ctx.u.calls || 0) + " requests" : ""
      color: Theme.overlay0
      elide: Text.ElideRight
      font.family: RoomLook.mono
      font.pixelSize: RoomLook.small - 1
    }
    Text {
      anchors { left: parent.left; right: parent.right; top: sessLine.bottom; topMargin: 3 }
      visible: ctx.u !== null
      text: ctx.th ? "thinker       " + ctx.k(ctx.th.prompt) + " tokens   " + Math.round(ctx.th.hit * 100) + "% cached"
                   : "thinker       not called yet"
      color: Theme.overlay0
      elide: Text.ElideRight
      font.family: RoomLook.mono
      font.pixelSize: RoomLook.small - 1
    }
  }

  // =========================================================== microphone
  // The room, as the mic hears it: forty bands in the colour of whoever owns
  // the sound (flat when nothing is open), then the four meters the ears
  // decide by, each against its threshold.
  Row {
    id: spec
    anchors { left: parent.left; right: parent.right; top: ctx.bottom
              leftMargin: 16; rightMargin: 16; topMargin: 14 }
    height: 32
    spacing: 3
    opacity: EarsModel.call ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Style.anim.slow } }
    Repeater {
      model: 40
      Rectangle {
        required property int index
        readonly property real v: {
          var s = EarsModel.spectrum
          if (!s || s.length === 0) return 0
          var x = s[Math.min(s.length - 1, Math.floor(index * s.length / 40))]
          return Math.max(0, Math.min(1, (x + 90) / 70))
        }
        anchors.bottom: parent.bottom
        width: (spec.width - 39 * spec.spacing) / 40
        height: Math.max(2, v * spec.height)
        radius: Math.min(width / 2, 2)
        color: Theme.alpha(dbg.hue, 0.22 + 0.55 * v)
      }
    }
  }

  Grid {
    id: meters
    anchors { left: parent.left; right: parent.right; top: spec.bottom; topMargin: 10
              leftMargin: 16; rightMargin: 16 }
    columns: 2
    columnSpacing: 22
    rowSpacing: 6
    opacity: EarsModel.call ? 1 : 0.45
    readonly property real cw: (width - columnSpacing) / 2
    readonly property var tn: EarsModel.tune || ({})

    RoomMeter {
      width: meters.cw
      label: "Loudness"
      lo: -80; hi: -10
      value: EarsModel.level
      mark: meters.tn.gate !== undefined ? meters.tn.gate : -50
      floorMark: EarsModel.floor
      known: EarsModel.call
      readout: Math.round(EarsModel.level) + " dB"
      onColor: Theme.green
    }
    RoomMeter {
      width: meters.cw
      label: "Speech"
      value: EarsModel.vad
      mark: meters.tn.vad !== undefined ? meters.tn.vad : 0.5
      known: EarsModel.call
      readout: EarsModel.vad.toFixed(2)
      onColor: Theme.sky
    }
    RoomMeter {
      width: meters.cw
      label: "Pause"
      hi: meters.tn.max_wait !== undefined ? meters.tn.max_wait : 2
      value: EarsModel.silence
      mark: meters.tn.pause !== undefined ? meters.tn.pause : 0.2
      known: EarsModel.call
      readout: EarsModel.silence.toFixed(2) + " s"
      onColor: Theme.lavender
      offColor: Theme.sapphire
    }
    RoomMeter {
      width: meters.cw
      label: EarsModel.linked && !EarsModel.enrolled ? "Your voice (not enrolled)" : "Your voice"
      value: EarsModel.lastSim
      mark: meters.tn.id !== undefined ? meters.tn.id : 0.45
      known: EarsModel.enrolled && EarsModel.lastSim >= 0
      readout: EarsModel.lastSim.toFixed(2)
      onColor: Theme.green
      offColor: Theme.red
    }
  }

  // =========================================================== last turn
  Item {
    id: turn
    anchors { left: parent.left; right: parent.right; top: meters.bottom; leftMargin: 16; rightMargin: 16; topMargin: 14 }
    height: tm ? 76 : 20
    readonly property var tm: EarsModel.latency
    readonly property var parts: [
      { k: "vad", label: "speech", c: Theme.blue }, { k: "turn", label: "turn", c: Theme.sapphire },
      { k: "voiceid", label: "id", c: Theme.teal }, { k: "stt", label: "text", c: Theme.green },
      { k: "llm", label: "reply", c: Theme.lavender }
    ]

    Text {
      id: turnTitle
      text: "Last turn"
      color: Theme.subtext1
      font.family: RoomLook.sans
      font.pixelSize: RoomLook.meta
      font.weight: Font.DemiBold
    }
    Text {
      anchors { left: turnTitle.right; leftMargin: 10; baseline: turnTitle.baseline }
      readonly property var tt: EarsModel.totals
      text: turn.tm ? "your last word to Ori's first:  " + (turn.tm.total / 1000).toFixed(2) + " s"
                      + (tt.length > 1 ? "   median " + (tt.slice().sort(function (a, b) { return a - b })[Math.floor(tt.length / 2)] / 1000).toFixed(2) + " s" : "")
                    : "talk to Ori to see where the time goes"
      color: Theme.subtext0
      font.family: RoomLook.mono
      font.pixelSize: RoomLook.small
    }
    Row {
      id: tbar
      anchors { left: parent.left; right: spark.left; rightMargin: 16; top: turnTitle.bottom; topMargin: 10 }
      height: 10
      spacing: 1
      readonly property real total: turn.tm ? Math.max(1, turn.tm.total) : 1
      Repeater {
        model: turn.tm ? turn.parts : []
        Rectangle {
          required property var modelData
          width: Math.max(Number(turn.tm[modelData.k] || 0) > 0 ? 2 : 0, (tbar.width - 5) * Number(turn.tm[modelData.k] || 0) / tbar.total)
          height: tbar.height
          radius: 2
          color: modelData.c
        }
      }
    }
    Flow {
      anchors { left: parent.left; right: spark.left; rightMargin: 16; top: tbar.bottom; topMargin: 8 }
      spacing: 10
      Repeater {
        model: turn.tm ? turn.parts : []
        Row {
          required property var modelData
          spacing: 5
          Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 7; height: 7; radius: 2; color: modelData.c }
          Text {
            text: modelData.label + " " + Number(turn.tm[modelData.k] || 0)
            color: Theme.subtext0
            font.family: RoomLook.mono
            font.pixelSize: RoomLook.small - 1
          }
        }
      }
    }
    // the last 20 totals
    Item {
      id: spark
      anchors { right: parent.right; top: turnTitle.bottom; topMargin: 6 }
      visible: turn.tm !== null
      width: 106
      height: 40
      readonly property var t: EarsModel.totals
      readonly property real mx: Math.max.apply(null, t.concat([1500]))
      Row {
        anchors.bottom: parent.bottom
        spacing: 2
        Repeater {
          model: spark.t
          Rectangle {
            required property var modelData
            anchors.bottom: parent.bottom
            width: Math.floor((spark.width - 38) / 20)
            height: Math.max(2, 30 * modelData / spark.mx)
            radius: 1
            color: modelData < 1200 ? Theme.green : modelData < 2000 ? Theme.yellow : Theme.peach
          }
        }
      }
      Text {
        anchors { right: parent.right; top: parent.bottom; topMargin: 2 }
        text: spark.t.length > 0 ? "last " + spark.t.length : ""
        color: Theme.overlay0
        font.family: RoomLook.mono
        font.pixelSize: RoomLook.small - 2
      }
    }
  }

  // ============================================================ filters
  Flow {
    id: chips
    anchors { left: parent.left; right: parent.right; top: turn.bottom; leftMargin: 14; rightMargin: 14; topMargin: 14 }
    spacing: 5
    Repeater {
      model: dbg.filters
      Rectangle {
        required property var modelData
        readonly property bool on: dbg.filter === modelData.k
        width: fl.implicitWidth + 18
        height: 24
        radius: 12
        color: on ? Theme.alpha(Theme.accent, 0.18) : fa.containsMouse ? Theme.alpha(Theme.surface0, 0.5) : Theme.transparent
        border.width: 1
        border.color: on ? Theme.alpha(Theme.accent, 0.5) : Theme.alpha(Theme.overlay0, 0.22)
        Text {
          id: fl
          anchors.centerIn: parent
          text: modelData.label
          color: parent.on ? Theme.text : Theme.subtext0
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.small
        }
        MouseArea { id: fa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: dbg.filter = modelData.k }
      }
    }
  }

  Rectangle {
    id: logRule
    anchors { left: parent.left; right: parent.right; top: chips.bottom; topMargin: 10 }
    height: 1
    color: RoomLook.hairline
  }

  // ================================================================= log
  ListView {
    id: log
    anchors { left: parent.left; right: parent.right; top: logRule.bottom; bottom: foot.top; leftMargin: 10; rightMargin: 10 }
    clip: true
    model: EarsModel.events
    boundsBehavior: Flickable.StopAtBounds
    topMargin: 6
    property bool follow: true
    onMovementEnded: follow = atYEnd
    onCountChanged: if (follow) Qt.callLater(positionViewAtEnd)
    Component.onCompleted: positionViewAtEnd()
    delegate: Item {
      required property string t
      required property real ts
      required property string line
      readonly property bool shown: dbg.matches(t)
      width: log.width
      height: shown ? Math.max(20, lineText.implicitHeight + 6) : 0
      visible: shown
      Text {
        id: tsText
        x: 6; y: 3
        text: {
          var d = new Date(ts)
          function p(n) { return n < 10 ? "0" + n : "" + n }
          return p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds())
        }
        color: Theme.overlay0
        font.family: RoomLook.mono
        font.pixelSize: RoomLook.small - 1
      }
      Text {
        id: tag
        x: 72; y: 3
        width: 70
        text: t
        color: dbg.tagColor(t)
        elide: Text.ElideRight
        font.family: RoomLook.mono
        font.pixelSize: RoomLook.small - 1
      }
      Text {
        id: lineText
        anchors { left: parent.left; leftMargin: 146; right: parent.right; rightMargin: 6 }
        y: 2
        text: line
        color: Theme.subtext1
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.small
      }
    }
  }

  Text {
    anchors.centerIn: log
    visible: EarsModel.events.count === 0
    text: EarsModel.linked ? "No events yet." : "The voice daemon isn't connected."
    color: Theme.overlay0
    font.family: RoomLook.sans
    font.pixelSize: RoomLook.body
  }

  // ============================================================== footer
  Item {
    id: foot
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 14; rightMargin: 14 }
    height: 46
    Process {
      id: newest
      command: ["sh", "-c", "ls -t \"$1\"/logs/*.jsonl 2>/dev/null | head -1", "sh", EarsModel.stateDir]
      Component.onCompleted: running = true
      stdout: StdioCollector { onStreamFinished: logPath.text = String(this.text).trim() }
    }
    Process {
      id: loadOld
      command: ["sh", "-c", "tail -n 500 \"$1\"", "sh", logPath.text]
      stdout: SplitParser {
        onRead: function (l) { try { EarsModel.ingest(JSON.parse(l), true) } catch (e) { } }
      }
    }
    RoomButton {
      id: openBtn
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      compact: true
      text: "Open log"
      enabled: logPath.text !== ""
      onClicked: Quickshell.execDetached(["kitty", "-e", "sh", "-c", "less +F \"$1\"", "sh", logPath.text])
    }
    RoomButton {
      id: loadBtn
      anchors { left: openBtn.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
      compact: true
      visible: !EarsModel.linked && logPath.text !== ""
      text: "Load last session"
      onClicked: { EarsModel.clearSession(); loadOld.running = true }
    }
    Text {
      id: logPath
      anchors { left: (loadBtn.visible ? loadBtn : openBtn).right; leftMargin: 12; right: parent.right; verticalCenter: parent.verticalCenter }
      color: Theme.overlay0
      elide: Text.ElideLeft
      font.family: RoomLook.mono
      font.pixelSize: RoomLook.small - 1
    }
  }
}
