import QtQuick
import ".."

// Slash-command completion, sitting over the transcript above the composer.
//
// Visually this is SessionPicker's sibling and deliberately so -- same mantle
// card, same 2px accent edge on the selected row, same one-line key hint. It
// differs in the one way that matters:
//
//   SessionPicker TAKES the keyboard. It is a mode; you are picking a
//   conversation, not writing one, so it calls forceActiveFocus() and answers
//   Keys.onPressed itself.
//
//   This does NOT. You are still typing a message -- the caret has to stay in
//   the field, the draft has to keep growing, and `/skil` has to remain
//   editable with backspace. So the composer keeps focus and forwards the four
//   keys this cares about through handleKey(); everything else falls through to
//   the field untouched. Taking focus here was the first thing tried and it
//   breaks the moment you type the second character.
//
// -------------------------------------------------------------- what it lists
// ONE list, and this file no longer builds it.
//
// It used to be two, concatenated here: pi's `get_commands` verbatim, plus a
// short list the shell hard-coded for the commands it ran itself (`/model`,
// `/effort`, ...). Those are still two different kinds of command -- pi's slash
// menu does not exist over RPC, so `/compact` is a message type and not a
// prompt -- but which is which is the HOST's knowledge, and every row now
// arrives from it tagged with a `source` of "extension", "prompt", "skill" or
// "panel", already in the order it wants them shown. A command is listed here
// only if something will actually run it, exactly as before; the difference is
// that the panel no longer has an opinion about which ones those are.
//
// --------------------------------------------------------------- and its args
// This used to say flatly that no command takes an enumerable argument, and
// that model ids therefore had nothing to complete against. Half of that is
// still true and half of it is now wrong, so both halves, in order.
//
// Still true of the ENGINE's commands. A skill's argument is free text appended
// after the expanded skill block (`_expandSkillCommand` does
// `args = text.slice(space+1)` and pastes it under the block), so the value
// space is "anything you want to say". There is nothing to offer.
//
// No longer true of the PANEL's two, which is the whole reason they exist here.
// Both have a closed set the engine will name on request:
//
//   /effort   get_available_thinking_levels -> the levels THIS MODEL supports,
//             which is not the seven in the type and not the same list twice:
//             five on deepseek-v4-flash:0731, six on glm-5.2.
//   /model    get_available_models -> ~120 rows, already filtered to providers
//             with configured auth, so every one of them can actually be set.
//
// So completion has two stages. `/mod` completes to `/model `, whose trailing
// space un-arms stage one and arms stage two; `/model gl` then completes to
// `/model ollama/glm-5.2 `, whose trailing space un-arms that in turn and
// leaves the next Enter free to send. Same trailing-space trick both times, and
// it is what makes "type /eff, Enter, l, Enter, Enter" work without a mode.
Rectangle {
  id: root

  property color accent: Theme.mauve
  // The composer's TextEdit. Read for the draft, written to on completion.
  property var entry: null

  // Everything the host reports, extension commands included. That was not
  // always safe and the history is worth keeping: an extension command is
  // intercepted by pi before the agent loop starts, so it settles nothing, and
  // for a while sending one left `busy` stuck true and the composer refusing
  // every later message until the shell was reloaded. This list was filtered to
  // skills to avoid offering that trap. The host now recognises the case and
  // settles the turn itself, putting the extension's own "/llama is available
  // in interactive mode" on the error strip -- so the worst outcome is a
  // command that politely says it does not run here, and hiding a real command
  // is worse than that.
  //
  // Order is the host's, not this file's.
  readonly property var commands: OriClient.commands || []

  // ------------------------------------------------------------------- arming
  readonly property string draft: root.entry ? String(root.entry.text) : ""
  // A slash and no whitespace after it. This is the whole stage-one trigger, and
  // it does three jobs at once: it only fires at the start of the draft, it stops
  // firing the moment an argument begins, and it never fires on a slash inside
  // a sentence or a path.
  readonly property bool naming: /^\/[^\s]*$/.test(root.draft)

  // Stage two: a complete command name, whitespace, and a partial value. The
  // host is the one that decides whether a name HAS values -- commandValues()
  // reads the protocol's own `values` field and answers with an empty list for
  // every command that does not -- so this arms for `/model` and `/effort` and
  // stays shut for the sixteen skills without a name of either being written
  // down here.
  readonly property var argMatch: /^\/([^\s]+)\s+([^\s]*)$/.exec(root.draft)
  readonly property var values: root.argMatch ? OriClient.commandValues(root.argMatch[1]) : []
  readonly property bool arging: root.values.length > 0

  readonly property bool armed: root.naming || root.arging
  // Escape means "stop suggesting", not "forget the draft". Cleared whenever
  // the draft leaves command shape, so deleting back to nothing and typing `/`
  // again brings the list back rather than staying silent for the session.
  property bool dismissed: false
  onArmedChanged: if (!root.armed) root.dismissed = false
  // A stage change is a different list, so a dismissal of the previous one does
  // not carry into it. Without this, escaping the command list and then finishing
  // the name by hand leaves the VALUE list silently suppressed.
  onArgingChanged: root.dismissed = false

  readonly property string query: root.arging ? String(root.argMatch[2]).toLowerCase()
                                : root.naming ? root.draft.slice(1).toLowerCase() : ""
  readonly property var pool: root.arging ? root.values : root.commands

  // Matched on the name with its namespace stripped as well as whole, so `/cave`
  // finds skill:caveman and `/model glm` finds ollama/glm-5.2. Sixteen of
  // seventeen engine commands carry a `skill:` prefix and every model id carries
  // a provider one; making someone type past either would make completion
  // useless for exactly the rows it exists for. Prefix hits sort above substring
  // hits, which is the only ranking these lists need -- a hundred-odd models
  // sounds like a lot until you have typed three letters at it.
  readonly property var matches: {
    var q = root.query
    var pre = [], sub = []
    for (var i = 0; i < root.pool.length; i++) {
      var c = root.pool[i]
      var full = String(c.name).toLowerCase()
      var cut = full.indexOf("skill:") === 0 ? 6 : full.indexOf("/") + 1
      var bare = full.slice(cut)
      if (q === "" || bare.indexOf(q) === 0 || full.indexOf(q) === 0) pre.push(c)
      else if (bare.indexOf(q) >= 0) sub.push(c)
    }
    return pre.concat(sub)
  }

  readonly property bool open: root.armed && !root.dismissed && root.matches.length > 0
  property int current: 0
  // The list is rebuilt on every keystroke, so the selection has to be pulled
  // back into range by the same binding that changes it -- clamping inside the
  // key handler leaves it stale for the frame where the query shrank the list.
  onMatchesChanged: root.current = 0

  // -------------------------------------------------------------------- shell
  // Sized to its contents up to a ceiling, which is safe here and nowhere else:
  // this is inside the card, and the card is a fixed-size layer surface. See
  // CLAUDE.md -- the rule is that the SURFACE must not resize, not that nothing
  // inside it may.
  implicitHeight: Math.min(hint.implicitHeight + 14 + root.matches.length * 26 + 8, 220)

  color: Theme.mantle
  radius: 6
  opacity: root.open ? 1 : 0
  visible: opacity > 0

  Behavior on opacity {
    NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
  }

  // ---------------------------------------------------------------------- api
  function close() { root.dismissed = true }

  function take() {
    var c = root.matches[root.current]
    if (!c || !root.entry) return
    // The trailing space is load-bearing in both stages: it un-arms the one that
    // wrote it. After a name that means stage two takes over; after a value it
    // means nothing is armed at all and the next Enter sends.
    root.entry.text = root.arging ? "/" + root.argMatch[1] + " " + c.name + " "
                                  : "/" + c.name + " "
    root.entry.cursorPosition = root.entry.text.length
  }

  // Returns whether the key was consumed. Called from the composer BEFORE its
  // own switch, so that while this is up Escape dismisses the list instead of
  // closing the panel and Enter completes instead of sending. Every key it does
  // not claim -- and every key at all while the list is shut -- reaches the
  // field exactly as before.
  function handleKey(event) {
    if (!root.open) return false
    switch (event.key) {
    case Qt.Key_Down:
      root.current = Math.min(root.current + 1, root.matches.length - 1)
      return true
    case Qt.Key_Up:
      root.current = Math.max(root.current - 1, 0)
      return true
    case Qt.Key_Tab:
    case Qt.Key_Return:
    case Qt.Key_Enter:
      // Enter completes rather than sends, so a half-typed command is never
      // sent as prose by the same key that would have finished it. The trailing
      // space completion writes un-arms the list, so the next Enter sends --
      // which is what makes "type /tdd, Enter, Enter" work without a mode.
      root.take()
      return true
    case Qt.Key_Escape:
      root.close()
      return true
    }
    return false
  }

  // ------------------------------------------------------------------- header
  Text {
    id: hint
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
    // "↑↓ move" is dropped on a single match, because there is nowhere to move
    // to and a key hint that does nothing teaches the wrong thing. Not a
    // hypothetical: the engine's list is one row deep on this machine right
    // now, so the one-match case is the common one rather than the edge.
    // Says which list is on screen, because in stage two the rows are values
    // and calling them "commands" would be a lie about what Enter is going to
    // do with the one under the cursor.
    text: (root.arging ? "/" + root.argMatch[1] : "commands")
        + (root.matches.length > 1
           ? "  ·  ↑↓ move   ⇥ complete   esc dismiss"
           : "  ·  ⇥ complete   esc dismiss")
    color: Theme.overlay0
    elide: Text.ElideRight
    font.family: Style.font.panelMono
    font.pixelSize: Style.font.panelMeta
    renderType: Text.QtRendering
  }

  ListView {
    id: list
    anchors { left: parent.left; right: parent.right; top: hint.bottom
              bottom: parent.bottom; margins: 4; topMargin: 6 }
    model: root.matches
    clip: true
    // Driven by the keys above; a view that can scroll away from the selection
    // would need a scrollbar to explain itself, and there is no mouse here.
    interactive: false

    currentIndex: root.current
    highlightMoveDuration: 0
    highlightRangeMode: ListView.ApplyRange
    preferredHighlightBegin: 0
    preferredHighlightEnd: height

    delegate: Rectangle {
      required property int index
      required property var modelData

      width: list.width
      height: 26
      radius: 4
      readonly property bool on: index === root.current
      color: on ? Theme.surface1 : "transparent"

      Rectangle {
        width: 2
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom
                  leftMargin: 2; topMargin: 3; bottomMargin: 3 }
        radius: 1
        color: root.accent
        opacity: parent.on ? 1 : 0
      }

      Text {
        id: name
        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
        // A leading slash on a command name and none on a value: `/model` is
        // typed with one and `ollama/glm-5.2` is not, and a row that shows the
        // wrong one teaches the wrong thing about what Enter will insert.
        text: (root.arging ? "" : "/") + String(modelData.name)
        color: parent.on ? Theme.text : Theme.subtext0
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta
        renderType: Text.QtRendering
      }

      // The description is what makes a list of sixteen skill names usable, but
      // they run to full paragraphs -- the raw first line of skill:context7 is
      // 180 characters. One elided line, dimmed, so it reads as a gloss on the
      // name rather than as content competing with it.
      Text {
        anchors { left: name.right; right: parent.right; leftMargin: 10
                  rightMargin: 8; verticalCenter: parent.verticalCenter }
        text: String(modelData.description || "").split("\n")[0]
        color: Theme.overlay0
        elide: Text.ElideRight
        font.family: Style.font.panelMono
        font.pixelSize: Style.font.panelMeta - 2
        renderType: Text.QtRendering
      }
    }
  }
}
