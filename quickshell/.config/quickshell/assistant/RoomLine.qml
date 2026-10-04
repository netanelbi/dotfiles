import QtQuick
import ".."

// One line of the call's transcript (EarsModel.entries).
//
//   you    what you said; dimmed when Ori chose to stay silent
//   ori    what Ori SAID: while it is still speaking, only the lines it has
//          spoken so far. Cut off by you: the unsaid rest is struck through,
//          because Ori keeps only what you heard.
//          A reply nobody asked for is a background result, tagged with the
//          job it reports.
//   note   something the ears decided (ignored a backchannel, not your
//          voice, paused for you) -- small, in the tone's colour
//   rule   call opened / closed
Item {
  id: line

  required property int index
  required property string kind
  required property string text
  required property string said
  required property string cut
  required property string lang
  required property real sim
  required property real turnP
  required property real dur
  required property bool streaming
  required property bool silent
  required property bool interrupted
  required property string source
  required property string tone
  required property string at
  required property string style  // Ori's [tone: ...] for this reply: the voice instruction sent to Qwen
  required property real ms

  property bool latest: false
  property bool speakingNow: false

  readonly property bool isYou: kind === "you"
  readonly property bool isOri: kind === "ori"
  readonly property bool talk: isYou || isOri
  // Ori is still producing this one: show only what has been spoken.
  readonly property bool partial: isOri && latest && (streaming || speakingNow)
  readonly property string oriHtml: {
    if (!isOri) return ""
    var full = partial ? said : text
    if (full === "") return ""
    if (interrupted && cut !== "") {
      var at = text.indexOf(cut)
      if (at >= 0) {
        return RoomLook.esc(text.substring(0, at))
          + "<font color='" + Theme.overlay0 + "'><s>" + RoomLook.esc(text.substring(at)) + "</s></font>"
      }
    }
    return RoomLook.esc(full)
  }

  implicitHeight: talk ? Math.max(gutter.implicitHeight, body.implicitHeight) : (kind === "rule" ? 22 : noteText.implicitHeight + 2)

  // ------------------------------------------------------------------ talk
  Column {
    id: gutter
    visible: line.talk
    x: 4
    width: 46
    spacing: 2
    Text {
      text: line.isYou ? "You" : "Ori"
      color: line.isYou ? Theme.sky : Theme.lavender
      font.family: RoomLook.sans
      font.pixelSize: RoomLook.small + 1
      font.weight: Font.DemiBold
      renderType: Text.QtRendering
    }
    Text {
      text: line.at
      visible: line.at !== ""
      color: Theme.overlay0
      font.family: RoomLook.mono
      font.pixelSize: RoomLook.small - 1
      renderType: Text.QtRendering
    }
  }

  Column {
    id: body
    visible: line.talk
    anchors { left: parent.left; leftMargin: 54; right: parent.right; rightMargin: 4 }
    spacing: 4

    // A background result coming back on its own.
    Rectangle {
      visible: line.isOri && line.source !== ""
      width: srcText.implicitWidth + 16
      height: 20
      radius: 10
      color: Theme.alpha(Theme.teal, 0.14)
      Text {
        id: srcText
        anchors.centerIn: parent
        text: "↳ " + line.source + " result"
        color: Theme.teal
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.small
        renderType: Text.QtRendering
      }
    }

    Text {
      width: parent.width
      visible: !(line.isOri && line.oriHtml === "")
      text: line.isOri ? line.oriHtml : RoomLook.esc(line.text)
      textFormat: Text.StyledText
      wrapMode: Text.Wrap
      color: line.isYou ? (line.silent ? Theme.overlay0 : Theme.text) : Theme.subtext1
      lineHeight: 1.12
      font.family: RoomLook.sans
      font.pixelSize: RoomLook.body
      renderType: Text.QtRendering
    }

    // Ori has the floor but has not said a word yet.
    Row {
      visible: line.isOri && line.oriHtml === ""
      spacing: 5
      height: 18
      Repeater {
        model: 3
        Rectangle {
          required property int index
          anchors.verticalCenter: parent.verticalCenter
          width: 5; height: 5; radius: 2.5
          color: Theme.lavender
          opacity: 0.35 + 0.2 * index
        }
      }
    }

    // What the ears measured, and what became of it.
    Row {
      spacing: 10
      visible: metaA.text !== "" || chip.visible || langChip.visible || styleChip.visible
      Text {
        id: metaA
        anchors.verticalCenter: parent.verticalCenter
        text: line.isYou
          ? [line.sim >= 0 ? "voice " + line.sim.toFixed(2) : "",
             line.turnP >= 0 ? "finished " + line.turnP.toFixed(2) : "",
             line.dur >= 0 ? line.dur.toFixed(1) + " s" : ""].filter(function (x) { return x !== "" }).join("   ")
          : (line.ms > 0 ? "replied in " + (line.ms / 1000).toFixed(2) + " s" : "")
        visible: text !== ""
        color: Theme.overlay0
        font.family: RoomLook.mono
        font.pixelSize: RoomLook.small - 1
        renderType: Text.QtRendering
      }
      Rectangle {
        id: langChip
        visible: line.lang !== "" && line.lang !== "en"
        anchors.verticalCenter: parent.verticalCenter
        width: lc.implicitWidth + 10; height: 16; radius: 4
        color: Theme.alpha(Theme.overlay0, 0.18)
        Text {
          id: lc
          anchors.centerIn: parent
          text: line.lang
          color: Theme.subtext0
          font.family: RoomLook.mono
          font.pixelSize: RoomLook.small - 2
          renderType: Text.QtRendering
        }
      }
      Rectangle {  // the speaking style Ori asked the voice for; hover shows the instruction itself
        id: styleChip
        visible: line.isOri && line.style !== ""
        anchors.verticalCenter: parent.verticalCenter
        width: sc.implicitWidth + 12; height: 18; radius: 9
        color: Theme.alpha(Theme.mauve, styleHover.containsMouse ? 0.24 : 0.14)
        Behavior on width { NumberAnimation { duration: 120 } }
        Text {
          id: sc
          anchors.centerIn: parent
          text: styleHover.containsMouse ? "voice: " + line.style : "♪ tone"
          color: Theme.mauve
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.small - 1
          renderType: Text.QtRendering
        }
        MouseArea { id: styleHover; anchors.fill: parent; hoverEnabled: true }
      }
      Rectangle {
        id: chip
        readonly property string word: line.isYou && line.silent ? "Ori stayed silent"
          : line.isOri && line.interrupted ? "cut off by you" : ""
        visible: word !== ""
        anchors.verticalCenter: parent.verticalCenter
        width: chipText.implicitWidth + 12; height: 18; radius: 9
        color: line.interrupted ? Theme.alpha(Theme.peach, 0.15) : Theme.alpha(Theme.overlay0, 0.16)
        Text {
          id: chipText
          anchors.centerIn: parent
          text: chip.word
          color: line.interrupted ? Theme.peach : Theme.subtext0
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.small - 1
          renderType: Text.QtRendering
        }
      }
    }
  }

  // ------------------------------------------------------------------ note
  Text {
    id: noteText
    visible: line.kind === "note"
    anchors { left: parent.left; leftMargin: 54; right: parent.right; rightMargin: 4 }
    text: (line.tone === "voiceid" || line.tone === "cut" ? "✕  "
         : line.tone === "barge" ? "‖  " : "·  ") + line.text
    color: Theme.alpha(RoomLook.toneColor(line.tone), line.tone === "info" || line.tone === "skip" ? 1 : 0.9)
    wrapMode: Text.Wrap
    font.family: RoomLook.sans
    font.pixelSize: RoomLook.small + 1
    font.italic: line.tone === "ignored" || line.tone === "skip"
    renderType: Text.QtRendering
  }

  // ------------------------------------------------------------------ rule
  Item {
    visible: line.kind === "rule"
    anchors.fill: parent
    Rectangle {
      anchors { left: parent.left; right: ruleText.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
      height: 1; color: RoomLook.hairline
    }
    Text {
      id: ruleText
      anchors.centerIn: parent
      text: line.text + (line.at !== "" ? "  " + line.at : "")
      color: Theme.overlay0
      font.family: RoomLook.sans
      font.pixelSize: RoomLook.small
      renderType: Text.QtRendering
    }
    Rectangle {
      anchors { left: ruleText.right; leftMargin: 10; right: parent.right; verticalCenter: parent.verticalCenter }
      height: 1; color: RoomLook.hairline
    }
  }
}
