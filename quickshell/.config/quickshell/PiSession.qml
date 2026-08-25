pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The assistant's engine: one long-lived `pi --mode rpc` child, shared by the
// whole shell.
//
// ------------------------------------------------------------------ why rpc
// `pi -p "question"` works and costs 2.0s. The same question through a process
// that is ALREADY running costs 1.2s, because 0.34s of that was node booting
// and the rest was a cold agent. `--mode rpc` is what makes the process
// reusable: line-delimited JSON in on stdin, a line-delimited event stream out
// on stdout, one session held open across questions.
//
//   -> {"id":1,"type":"prompt","message":"..."}
//   <- {"id":1,"type":"response","command":"prompt","success":true}
//   <- {"type":"agent_start"}
//   <- {"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"50"}}
//   <- {"type":"agent_settled"}
//
// Other commands the protocol accepts, for when this grows: steer, abort,
// follow_up, new_session, set_model, compact, get_last_assistant_text. `prompt`
// also takes an `images` array, which is the hook for feeding it a
// ScreencopyView grab of the focused window later.
//
// ------------------------------------------------------------- warm vs idle
// A warm node process is ~200MB, which is more than this entire shell. So it is
// NOT started with the shell: the first question spawns it, and IDLE_KILL_MS of
// silence kills it again. You pay the 2.0s cold start once per burst of use and
// nothing at all the rest of the day -- the same "nothing exists until asked
// for" rule the launchers and the share picker follow.
//
// ------------------------------------------------------------------- flags
//   -ne  extensions OFF. NOT optional: ~/.pi/agent/extensions/openai-codex-usage.ts
//        calls assertActive() on a UI that does not exist outside a TTY, throws,
//        and takes the whole run with it. Every non-interactive pi run needs this.
//   -ns  skills off -- nothing here uses them, and they cost startup.
//   --no-session  no session file on disk. Continuity comes from the process
//        being alive, not from a transcript; a restart is meant to be a clean slate.
//   --append-system-prompt  takes a FILE PATH as well as text. soul.md is dito's
//        personality file, so the panel answers as Vivo rather than as a generic
//        coding assistant. (dito's own CLAUDE.md pulls in soul/user/tools/pc with
//        `@file` imports -- pi does NOT expand those, which is why the file is
//        named here directly. Verified: without this line it answers "I'm Claude,
//        an AI coding assistant running inside pi".)
//        user.md is deliberately NOT appended: it tells the assistant its primary
//        interface is Telegram and that replies go there, which is true of dito's
//        main session and wrong for a panel on the screen in front of you.
Singleton {
  id: root

  readonly property string binary: "pi"
  readonly property string provider: "ollama"
  readonly property string model: "deepseek-v4-flash:0731"
  readonly property string soulFile: "~/.dito/soul.md"

  // Kill the child after this much silence. Long enough to cover a
  // back-and-forth, short enough that a stray question does not leave 200MB
  // resident for the rest of the session.
  readonly property int idleKillMs: 10 * 60 * 1000

  // ------------------------------------------------------------------ state
  // `busy` is the one the UI keys off: true from the moment a question is
  // accepted until the agent settles.
  property bool busy: false
  // Set when pi refuses a command or the child dies; cleared on the next ask.
  property string error: ""

  readonly property bool warm: proc.running

  signal settled()
  // Emitted whenever the newest turn grows, so the view can keep itself pinned
  // to the bottom without polling.
  signal appended()

  // ----------------------------------------------------------------- turns
  // The conversation, oldest first -- the panel is a view of THIS, not of a
  // pair of "last question / last answer" strings. Keeping it here rather than
  // in the panel is what lets the window be closed and reopened mid-answer with
  // the transcript intact, and what makes the process's own session and the
  // thing on screen the same conversation.
  //
  //   role      "user" | "assistant"
  //   text      the message; for an assistant turn it grows token by token
  //   thinking  streamed reasoning, kept SEPARATE from text so the view can
  //             show it while the answer is empty and drop it afterwards
  //   tool      the tool call in flight on this turn, "" when none
  //   pending   true while this turn is still being written
  ListModel { id: turnModel }
  readonly property alias turns: turnModel

  function lastAssistant() {
    for (var i = turnModel.count - 1; i >= 0; i--) {
      if (turnModel.get(i).role === "assistant") return i
    }
    return -1
  }

  function grow(field, delta) {
    var i = lastAssistant()
    if (i < 0) return
    turnModel.setProperty(i, field, turnModel.get(i)[field] + delta)
    root.appended()
  }

  // ------------------------------------------------------------------- api
  // Returns whether the question was ACCEPTED. The composer keys its "clear the
  // draft" on this: a message typed while a turn is still running is refused,
  // and silently wiping the field in that case loses what you wrote.
  function ask(text) {
    var msg = String(text || "").trim()
    if (msg === "" || root.busy) return false

    root.error = ""
    root.busy = true
    turnModel.append({ role: "user", text: msg, thinking: "", tool: "", pending: false })
    // The assistant's turn exists before a single token arrives, so the view has
    // a row to stream into and the conversation never visibly jumps.
    turnModel.append({ role: "assistant", text: "", thinking: "", tool: "", pending: true })
    root.appended()

    idleTimer.stop()
    // Queued rather than sent, because the child may not exist yet. `flush()`
    // runs either immediately (warm) or from onStarted (cold), so the caller
    // never has to know which case it is.
    pending = msg
    if (proc.running) flush()
    else proc.running = true
    return true
  }

  function abort() {
    if (!proc.running) return
    send({ type: "abort" })
    root.busy = false
    idleTimer.restart()
  }

  // Drop the conversation without dropping the process -- the cheap "start
  // over" that keeps the 1.2s warm latency. `new_session` clears pi's own
  // context so the model forgets it too, not just the screen.
  function newChat() {
    if (root.busy) abort()
    turnModel.clear()
    root.error = ""
    if (proc.running) send({ type: "new_session" })
  }

  // --------------------------------------------------------------- protocol
  property string pending: ""
  property int nextId: 1

  function send(obj) {
    obj.id = root.nextId++
    // The protocol is line-delimited, so the trailing newline is the frame
    // terminator, not cosmetic.
    proc.write(JSON.stringify(obj) + "\n")
  }

  function flush() {
    if (root.pending === "") return
    send({ type: "prompt", message: root.pending })
    root.pending = ""
  }

  function ingest(line) {
    var raw = String(line || "").trim()
    if (raw === "") return

    var d
    try {
      d = JSON.parse(raw)
    } catch (e) {
      // pi writes human-readable startup noise to stderr, not stdout, so a
      // non-JSON line here means the protocol broke. Surfacing it is better
      // than a panel that silently never answers.
      root.error = raw
      return
    }

    switch (d.type) {
    case "response":
      // Only a FAILED response matters: success is just an ack that the prompt
      // was accepted, and the real work arrives as the events below.
      if (d.success === false) {
        root.error = String(d.error || "rejected")
        root.busy = false
        settleTurn()
        idleTimer.restart()
      }
      break

    case "message_update": {
      var e = d.assistantMessageEvent
      if (!e) break
      // Reasoning and answer are SEPARATE delta streams (thinking_delta /
      // text_delta, each with its own _start and _end). Keeping them apart is
      // what lets the panel show the thinking as a loading state and then
      // replace it with the answer, instead of running the two together.
      if (e.type === "thinking_delta") root.grow("thinking", String(e.delta || ""))
      else if (e.type === "text_delta") root.grow("text", String(e.delta || ""))
      break
    }

    case "tool_execution_start":
      setTurn("tool", String(d.toolName || "tool") + " " + summarizeArgs(d.args))
      break

    case "tool_execution_end":
      setTurn("tool", "")
      break

    case "agent_settled":
      root.busy = false
      settleTurn()
      root.settled()
      idleTimer.restart()
      break
    }
  }

  function setTurn(field, value) {
    var i = lastAssistant()
    if (i >= 0) turnModel.setProperty(i, field, value)
  }

  // Close out the open turn: no tool in flight, no longer growing. The thinking
  // text is kept rather than cleared -- it is the record of how the answer was
  // reached, and the view decides whether to show it.
  function settleTurn() {
    var i = lastAssistant()
    if (i < 0) return
    turnModel.setProperty(i, "tool", "")
    turnModel.setProperty(i, "pending", false)
    root.appended()
  }

  // One line of "what is it actually doing", from whichever argument carries
  // the meaning for that tool. Truncated: this sits on a single row.
  function summarizeArgs(args) {
    if (!args || typeof args !== "object") return ""
    var v = args.command || args.file_path || args.path || args.pattern || args.query || ""
    v = String(v).split("\n")[0]
    return v.length > 70 ? v.substring(0, 70) + "…" : v
  }

  // --------------------------------------------------------------- process
  Process {
    id: proc

    // `sh -lc` for the same reason ScriptWidget uses it: pi lives in
    // ~/.bun/bin, which a login shell puts on PATH and a bare exec does not,
    // and `~` in the soul path needs expanding. `exec` so that sh replaces
    // itself with pi -- otherwise stdin belongs to sh and `write()` goes
    // nowhere.
    command: ["sh", "-lc",
      "exec " + root.binary + " --mode rpc -ne -ns --no-session"
        + " --provider " + root.provider
        + " --model " + root.model
        + " --append-system-prompt " + root.soulFile]

    stdinEnabled: true
    stdout: SplitParser { onRead: function (line) { root.ingest(line) } }

    // The child is spawned by ask(), so there is always exactly one question
    // waiting when it comes up.
    onStarted: root.flush()

    onExited: function (exitCode) {
      root.pending = ""
      idleTimer.stop()
      // An exit while busy is a crash, not the idle timer: say so rather than
      // leaving the panel spinning forever on an answer that will never come.
      if (root.busy) {
        root.busy = false
        if (root.error === "") root.error = "pi exited (" + exitCode + ")"
        settleTurn()
      }
    }
  }

  Timer {
    id: idleTimer
    interval: root.idleKillMs
    repeat: false
    onTriggered: proc.running = false
  }
}
