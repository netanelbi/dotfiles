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
// PiSession.commands, which is get_commands verbatim: { name, description,
// source }. That is NOT the pi TUI's slash menu. `/model`, `/compact`,
// `/ollama-usage` and friends do not exist over RPC -- they are separate
// message types (set_model, compact, ...), and a prompt whose text is "/model"
// is sent to the model as the literal string "/model". Offering them would be
// inventing commands, so what is offered is exactly what the engine says it
// has: 16 skills and 1 extension on this machine.
//
// --------------------------------------------------------------- and its args
// The lead asked whether the argument VALUES are worth completing too -- model
// ids being known to the engine. They are not, and the reason is not effort:
// there is nothing to complete. No command get_commands returns takes an
// enumerable argument. A skill's argument is free text appended after the
// expanded skill block (`_expandSkillCommand` does `args = text.slice(space+1)`
// and pastes it under the block), so the value space is "anything you want to
// say". The one command with a closed value set -- picking a model -- is
// reached through the set_model RPC, not through a slash command, so completing
// `/model <id>` would be completing an argument to a command that does not run.
// If model switching ever wants a UI it belongs on the footer next to the model
// name, not here.
//
// So "ready for the argument" is all this does: completing writes
// "/skill:tdd " with the trailing space, which un-arms the list (see `armed`)
// and leaves the caret where the argument goes. A command used without one
// keeps the stray space, which costs nothing -- pi trims it away.
Rectangle {
  id: root

  property color accent: Theme.mauve
  // The composer's TextEdit. Read for the draft, written to on completion.
  property var entry: null

  // Everything the engine reports, extension commands included. That was not
  // always safe and the history is worth keeping: an extension command is
  // intercepted by pi before the agent loop starts, so it settles nothing, and
  // for a while sending one left `busy` stuck true and the composer refusing
  // every later message until the shell was reloaded. This list was filtered to
  // skills to avoid offering that trap. PiSession now recognises the case (a
  // prompt response preceded by an extension_ui_request) and settles the turn
  // itself, putting the extension's own "/llama is available in interactive
  // mode" on the error strip -- so the worst outcome is now a command that
  // politely says it does not run here, and hiding a real command is worse than
  // that.
  readonly property var commands: PiSession.commands || []

  // ------------------------------------------------------------------- arming
  readonly property string draft: root.entry ? String(root.entry.text) : ""
  // A slash and no whitespace after it. This is the whole trigger rule, and it
  // does three jobs at once: it only fires at the start of the draft, it stops
  // firing the moment an argument begins, and it never fires on a slash inside
  // a sentence or a path.
  readonly property bool armed: /^\/[^\s]*$/.test(root.draft)
  // Escape means "stop suggesting", not "forget the draft". Cleared whenever
  // the draft leaves command shape, so deleting back to nothing and typing `/`
  // again brings the list back rather than staying silent for the session.
  property bool dismissed: false
  onArmedChanged: if (!root.armed) root.dismissed = false

  readonly property string query: root.armed ? root.draft.slice(1).toLowerCase() : ""

  // Matched on the name with `skill:` stripped as well as whole, so `/cave`
  // finds skill:caveman. Sixteen of seventeen commands carry that prefix;
  // making the user type it to get past it would make completion useless for
  // exactly the commands it exists for. Prefix hits sort above substring hits,
  // which is the only ranking a list this short needs.
  readonly property var matches: {
    var q = root.query
    var pre = [], sub = []
    for (var i = 0; i < root.commands.length; i++) {
      var c = root.commands[i]
      var full = String(c.name).toLowerCase()
      var bare = full.indexOf("skill:") === 0 ? full.slice(6) : full
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
    root.entry.text = "/" + c.name + " "
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
    text: root.matches.length > 1
        ? "commands  ·  ↑↓ move   ⇥ complete   esc dismiss"
        : "commands  ·  ⇥ complete   esc dismiss"
    color: Theme.overlay0
    elide: Text.ElideRight
    font.family: Style.font.family
    font.pixelSize: Style.font.panelMeta
    renderType: Text.NativeRendering
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
        text: "/" + String(modelData.name)
        color: parent.on ? Theme.text : Theme.subtext0
        font.family: Style.font.family
        font.pixelSize: Style.font.panelMeta
        renderType: Text.NativeRendering
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
        font.family: Style.font.family
        font.pixelSize: Style.font.panelMeta - 2
        renderType: Text.NativeRendering
      }
    }
  }
}
