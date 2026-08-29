import QtQuick
import ".."

// One tool call, in Claude Code's shape: what it is doing, and under it what it
// actually ran.
//
//   ● restart the shell so the panel reloads
//     └ systemctl --user restart quickshell && qs -p ~/.config/quickshell log
//
// The description is the sentence pi's tool-descriptions extension makes every
// call write; the second line is the literal command, path or pattern
// (PiSession.rawArgs). Both, not one -- an intent with no command is a claim,
// and a command with no intent is a puzzle. The panel used to render
// `$ bash  <description>` and drop the command at the door, which is the half
// the user could not check.
//
// `compact` drops the second line. A batch collapses to a count once it is
// done, so the only rows that earn their command are the one running right now
// and any job still alive in the background.
Item {
  id: line

  // { name, arg, raw, t0, ms, bg } from PiSession.toolLog.
  property var call: null
  // Still running: no duration stamped, so the row counts up and breathes.
  property bool live: false
  property color accent: Theme.accent
  // The panel's frame clock, handed down: a running call counts up on the same
  // tick as the rail and stops dead with it, rather than starting a timer here.
  property real nowMs: 0
  // The panel's one breath, shared, so the live row rises and falls with the
  // spine and the bar dot instead of running a loop of its own.
  property real breath: 1
  // One line only -- no command underneath.
  property bool compact: false
  // Clicked open: the whole command, however many lines it takes. Off by
  // default because two lines is the right budget for a row you are scanning
  // past, and wrong for the one row you stopped on.
  property bool full: false

  readonly property string name: call ? String(call.name || "") : ""
  readonly property string intent: call ? String(call.arg || "") : ""
  readonly property string raw: call ? String(call.raw || "") : ""

  // { pid, log } when the bash tool detached this command instead of waiting
  // for it -- anything still alive at 30s. The call RETURNED, so the protocol
  // considers it over and `ms` is stamped, but the job has not finished: a
  // build with four minutes left would otherwise print `30.0s` and read as
  // done. PiSession reads it off `details.backgrounded` on tool_execution_end.
  readonly property var bg: call && call.bg ? call.bg : null

  // Live means "this is the call in flight". Running means "something is still
  // happening because of this row", which a backgrounded job is without being
  // the current action -- so it keeps the bright colour and NOT the breath: a
  // second thing pulsing would compete with the one line that is actually now.
  readonly property bool running: live || bg !== null

  // The stamped duration once it returns, the clock while it runs. A restored
  // call has t0 0, which means UNKNOWN and not the epoch -- subtracting it from
  // a wall clock is what once rendered `148974714m 11s`.
  readonly property real ms: !call ? 0
    : call.ms > 0 ? call.ms
    : (live && call.t0 > 0) ? Math.max(0, line.nowMs - call.t0) : 0

  readonly property bool hasRaw: !compact && raw !== "" && raw !== intent

  implicitHeight: head.implicitHeight + (hasRaw ? cmd.implicitHeight + 2 : 0)
  height: implicitHeight
  // A backgrounded job breathes too. It is not the current action -- it does
  // not get the bright head text for that -- but it IS still running, and once
  // the turn has settled it is the only thing on the card that is.
  opacity: line.running ? line.breath : 1

  Fmt { id: fmt }

  // The whole row is the target, not a caret: there is one thing to do to a
  // tool row and no reason to make you aim at 8px of it. Only where there is
  // something hidden to reveal, so a row with nothing more to give does not
  // offer a hand cursor and then do nothing.
  MouseArea {
    anchors.fill: parent
    enabled: line.hasRaw
    cursorShape: Qt.PointingHandCursor
    onClicked: line.full = !line.full
  }

  // ------------------------------------------------------------ the intent
  Text {
    id: dot
    x: 0
    width: 13
    // Filled while something is still happening, hollow once it is not --
    // the same distinction the pill's rail makes, in the one glyph a row has.
    text: line.running ? "●" : "○"
    color: line.running ? line.accent : Theme.alpha(line.accent, 0.6)
    font.family: Style.font.panelMono
    font.pixelSize: Style.font.panelMeta
    renderType: Text.QtRendering
  }

  Text {
    id: head
    anchors { left: parent.left; leftMargin: 13; right: cost.left; rightMargin: 8 }
    // The tool's own name only when it wrote no description -- with one, the
    // name is already implied by the command underneath, and "bash" spent in
    // front of every row is a column of noise.
    text: line.intent !== "" ? line.intent : line.name
    color: line.running ? Theme.text : Theme.subtext0
    elide: Text.ElideRight
    maximumLineCount: 1
    font.family: Style.font.panelMono
    font.pixelSize: Style.font.panelMeta
    font.weight: line.running ? Style.font.boldWeight : Style.font.normalWeight
    renderType: Text.QtRendering
  }

  // The cost column, or -- for a job that was handed back rather than finished
  // -- what it was handed back AS. The PID is the useful half: it is the
  // argument `bg_status` takes and the one `kill` takes, so the row is the
  // thing you act on rather than a note that something is out there somewhere.
  // Anchored right, so a number that changes width every frame while the call
  // runs cannot push the sentence beside it around.
  Text {
    id: cost
    anchors { right: parent.right; baseline: head.baseline }
    text: line.bg ? "↳ bg " + line.bg.pid : fmt.duration(line.ms)
    color: line.bg ? line.accent : Theme.overlay0
    font.family: Style.font.panelMono
    font.pixelSize: Style.font.panelMeta
    font.weight: line.bg ? Style.font.boldWeight : Style.font.normalWeight
    renderType: Text.QtRendering
  }

  // ----------------------------------------------------------- the command
  // Hung off the description on an elbow, indented past it, dim. Two lines is
  // the budget: a command long enough to need three is one whose tail no longer
  // identifies it anyway, and this sits inside a card 560px wide.
  Text {
    id: cmd
    anchors { left: parent.left; leftMargin: 20; right: parent.right; rightMargin: 4
              top: head.bottom; topMargin: 2 }
    visible: line.hasRaw
    text: "└ " + line.raw
    color: Theme.overlay0
    wrapMode: Text.WrapAnywhere
    // Two lines while it is one row among many; everything once you ask. A
    // ceiling stays even when open -- a command can be a heredoc, and a card
    // 560px wide is not where you read one of those.
    maximumLineCount: line.full ? 14 : 2
    elide: line.full ? Text.ElideNone : Text.ElideRight
    font.family: Style.font.panelMono
    font.pixelSize: Style.font.panelMeta
    renderType: Text.QtRendering
  }
}
