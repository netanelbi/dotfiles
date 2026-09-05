import QtQuick
import "root:/"
import "../assistant"

// The held batch, in the bar's own strip. Triage's only visible surface.
//
// ------------------------------------------------------------------- why here
// Because there was nowhere else, and because there was no door.
//
// swaync had a waybar module and this shell dropped it in the port: the control
// centre survived (services/NotificationCenter.qml, arrow keys, groups, Clear
// All and all) but nothing opens it. No bar module, and -- checked against
// hyprland.lua, which binds eleven other `qs ipc call` targets -- no keybind
// either. So the notification history has been reachable only from a terminal
// since the port. A batch nobody can look at is not triage, it is a deeper hole
// than the one it was dug to fill, so the module that counts the batch is also
// the way in.
//
// ------------------------------------------------------------ what it costs
// Nothing at rest, in the literal sense: `shown` is false whenever there is no
// batch and dnd is off, and BarWidget collapses an unshown widget to zero width
// and `visible: false`. It appears when there is something to say and it goes
// away when there is not -- the same contract Capslock, Tdp and StayAwake keep,
// which is why the right island does not read as a dashboard.
//
// It draws inside Style.bar.slotHeight, in an island the compositor has already
// reserved. Nothing here can reach a window, which is the rule this whole
// design is built on.
//
// ------------------------------------------------------------ what it says
//   glyph   a bell, or a struck bell while do-not-disturb is on. The struck
//           bell is worth its own state: dnd today is INVISIBLE -- you can
//           leave it on for a day and the only evidence is silence, which
//           looks exactly like a quiet day.
//   count   the held total. The digest itself is in the tooltip, because a
//           per-app breakdown in the bar would be the dashboard this island
//           spent every other module avoiding.
//
// The tooltip is the payoff -- fourteen popups, read back as four lines, when
// and only when the pointer asks for them. It is Bar.qml's single shared popup
// on a 400ms hover, not a surface this file owns.
BarWidget {
  id: root

  // Two reasons to exist, and dnd on its own is one of them: a struck bell
  // with no count is the shell finally admitting it is holding the phone.
  shown: Triage.held > 0 || Triage.quiet

  // Same 8px footprint the other indicators take (see Capslock).
  horizontalPadding: Style.module.indicatorPaddingH
  spacing: 4

  // Held is the state that wants you; dnd alone is a state you chose. Yellow
  // is what this bar already means by "on, and you should know" -- it is
  // stay-awake's colour and capslock's. A batch is not urgent and must not
  // take @red, which in this island means a dying battery.
  readonly property color tint: Triage.held > 0 ? Theme.attention : Theme.inactive

  Text {
    id: bell
    // nf-md-bell / nf-md-bell_off. The Material Design range, which is where
    // this bar already keeps its glyphs -- Scratchpad's 󰝖 and Capslock's 󰪛 are
    // the same family, and the Font Awesome bell next door is a lighter,
    // narrower drawing that would not sit with them.
    text: Triage.quiet ? "󰂛" : "󰂚"
    color: root.tint
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    renderType: Text.NativeRendering

    Behavior on color {
      ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
    }
  }

  Text {
    text: Triage.held > 0 ? String(Triage.held) : ""
    visible: text !== ""
    color: root.tint
    font.family: Style.font.family
    font.pixelSize: Style.font.tiny
    font.weight: Style.font.boldWeight
    renderType: Text.NativeRendering

    Behavior on color {
      ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
    }
  }

  // ------------------------------------------------------------------ motion
  // StayAwake's entrance, and for its reason: the module appears because
  // something happened, so it arrives rather than blinking into place behind
  // BarWidget's width reveal. Once it is up the count changes by a character
  // and nothing moves -- a bell that bounced on every arrival would be the
  // interruption this feature exists to remove, drawn 30px higher.
  NumberAnimation {
    id: ring
    target: bell
    property: "scale"
    from: 0.4
    to: 1
    duration: Style.anim.reveal
    easing.type: Style.anim.easingEnter
    easing.overshoot: Style.anim.overshoot
  }

  onShownChanged: if (shown) ring.restart()

  // ----------------------------------------------------------------- tooltip
  tooltip: {
    var out = []
    if (Triage.held > 0) {
      out.push(Triage.oneLine)
      if (Triage.reason !== "") out.push("held while " + Triage.reason)
      out.push("")
      out.push(Triage.detail)
      out.push("")
      out.push("click  the notification centre")
      // Written down only when it is actually on offer, so the line is never a
      // gesture that does nothing.
      if (Triage.worthAsking) out.push("right-click  ask Ori what needs you")
    } else {
      out.push("do not disturb")
      out.push("nothing held yet")
    }
    if (root.askNote !== "") {
      out.push("")
      out.push(root.askNote)
    }
    return out.join("\n")
  }

  // ------------------------------------------------------------------- input
  // Opening the centre is what marks the batch as seen -- Notifications.qml
  // calls Triage.release() from openCenter(), so the count clears because the
  // list was actually shown, not because this widget was clicked.
  onClicked: if (Triage.store) Triage.store.toggleCenter()

  // The one place a model is offered, and it is a deliberate gesture on a
  // widget you are already pointing at. See Triage.qml's "when Ori is worth
  // asking" for why this is not automatic -- briefly: ori-agent has one
  // conversation and no side channel, the allowance is finite and on screen,
  // and grouping by app cannot hallucinate.
  //
  // Nothing opens. The question goes in as an ordinary turn and the answer
  // arrives the way every answer does: the mark in the gap fills and waits.
  property string askNote: ""

  onRightClicked: {
    if (!Triage.worthAsking) return
    var q = Triage.askPrompt()
    if (q === "") return
    // ask() refuses when the agent is unreachable, and a gesture that silently
    // does nothing is indistinguishable from a dead widget. The refusal is
    // written into the tooltip the pointer is already on rather than raised
    // anywhere. A turn already running is NOT a refusal any more -- the host
    // takes that as a steer.
    root.askNote = OriClient.ask(q) ? "asked Ori — the mark will fill"
      : (OriClient.error !== "" ? OriClient.error : "Ori did not take that")
    clearNote.restart()
  }

  Timer {
    id: clearNote
    interval: 6000
    onTriggered: root.askNote = ""
  }
}
