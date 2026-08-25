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
// The full command set, verified against the bundle -- this list used to be a
// partial one and a reader concluded from it that context usage was
// unobtainable, so it is now complete:
//
//   prompt  steer  abort  follow_up  new_session  switch_session  fork  clone
//   compact  set_model  cycle_model  set_thinking_level  cycle_thinking_level
//   set_auto_compaction  set_auto_retry  set_follow_up_mode  set_steering_mode
//   set_session_name  bash  export_html  abort_bash  abort_retry
//   get_state  get_session_stats  get_messages  get_entries  get_tree
//   get_commands  get_last_assistant_text  get_fork_messages
//   get_available_models  get_available_thinking_levels
//
// Two of those carry live instrumentation, both measured rather than assumed,
// and BOTH are now read -- they are what the panel's token and context readouts
// are made of:
//
//   message_update  .usage -> { input, output, cacheRead, cacheWrite, reasoning,
//                   totalTokens, cost }. Streams DURING a turn, so a running
//                   token count is free -- no extra call.
//   get_session_stats -> { userMessages, assistantMessages, toolCalls, cost,
//                   tokens, contextUsage: { tokens, contextWindow, percent } }.
//                   That percent is the direct equivalent of a coding agent's
//                   "36%" context readout. Asked for once per settled turn,
//                   which is the only moment the answer can have changed.
//
// `prompt` also takes an `images` array, which is the hook for feeding it a
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
//        Skills are deliberately NOT disabled -- they are where `/commands` come
//        from. `get_commands` reports 17 on this machine and 16 of them are
//        skills, so passing -ns to buy a fraction of a second at startup would
//        silently empty the command list.
//   --no-session  no session file on disk. Continuity comes from the process
//        being alive, not from a transcript.
//   -e   extensions are opted INTO one path at a time (see `extensions` below).
//        Unlinking ~/.pi/agent/extensions/* would have worked too, but that
//        directory is global: it would change `pi` in every terminal, not here.
//
// ---------------------------------------------------------------- workspace
// It runs in ~/.dotfiles -- the repo that configures this whole machine,
// including this file. Three things follow, none of them incidental:
//
//   * pi discovers CLAUDE.md from its working directory, so the repo's own
//     documentation is already in context. It knows what stow is doing here
//     without being told.
//   * it can read and change its own source. PiSession.qml is how it runs;
//     assistant/ is how it looks.
//   * ~/.config/assistant/*.md are its own files -- who it is, what this machine
//     does, and what it has learned. memory.md is meant to be written BY it.
//
// Measured cost of running there rather than in a neutral directory: 3157 ->
// 5964 input tokens. That 2.8K is the repo knowledge, out of a 131K window.
//
// The identity is Ori, and it is NOT dito's Vivo. Same laptop, different heads,
// separate memory -- soul.md says so outright so it cannot claim conversations
// it never had.

Singleton {
  id: root

  // ------------------------------------------------------------- settings
  // Everything tunable lives in this block. Changing any of it hot-reloads the
  // shell, which drops the running child; the next question starts a new one, so
  // it costs a cold start and nothing else.
  readonly property string binary: "pi"
  readonly property string provider: "ollama"
  readonly property string model: "deepseek-v4-flash:0731"

  // Where it runs. This is the whole "it manages this machine" decision.
  readonly property string workdir: "~/.dotfiles"

  // Prepended to the system prompt, in order. pi takes a PATH here as well as
  // text -- and it does NOT expand CLAUDE.md's `@file` imports, so every file
  // has to be named. (Point it at a workspace whose CLAUDE.md is nothing but
  // `@` lines and it answers "I'm Claude, an AI coding assistant running inside
  // pi"; that is exactly how this was found.)
  readonly property var promptFiles: [
    "~/.config/assistant/soul.md",
    "~/.config/assistant/laptop.md",
    "~/.config/assistant/memory.md"
  ]

  // Extensions, opted into by path. Empty means none: `-ne` disables discovery
  // and each entry here is loaded back explicitly, which leaves the global set
  // in ~/.pi/agent/extensions/ alone so `pi` in a terminal is unchanged.
  //
  // Two worth knowing before adding any:
  //   openai-codex-usage.ts  CRASHES here -- see the -ne note above. Never add it.
  //   pi-web-access          web search/fetch; the obvious first one to add.
  readonly property var extensions: [
    // web_search / web_fetch. The search runs on the shim (that is where the
    // Brave and Ollama keys live); the fetch runs here, so Ori can read
    // 127.0.0.1 and the LAN, which a VPS cannot. Loading this also makes the
    // shim's own OpenAI search loop stand down -- it skips any client that
    // declares web tools itself -- so there is exactly one searcher.
    //
    // The point of doing it this way round: pi makes the call, so pi emits
    // tool_execution_start, so the panel can SHOW the search. A shim-side loop
    // is invisible to the client by construction.
    "~/Development/Personal/my-pi/extensions/shim-web.ts"
  ]

  // Where shim-web sends its searches. The local systemd instance rather than
  // the VPS: it is the same code, it is already running for `ccr`, and it saves
  // a round trip to a datacentre for something the laptop can ask for directly.
  readonly property string shimUrl: "http://127.0.0.1:11435"

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

  // ------------------------------------------------------------ view state
  // Whether the panel is on screen, and whether an answer landed while it was
  // not. This is UI state living on the engine on purpose: the panel and the bar
  // indicator are two different windows that must agree, and "was anyone looking
  // when this finished" is the question that decides whether an answer gets
  // announced at all. The alternative is a third singleton whose whole job is to
  // hold two booleans.
  property bool panelOpen: false
  property bool unread: false

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
  ListModel {
    id: turnModel
    // The derived views below are keyed by row index, so a cleared transcript
    // has to drop them too -- otherwise turn 0 of the next conversation
    // inherits the tool calls and the cost of turn 0 of the last one. Clearing
    // the transcript also means `new_session`, which empties the context the
    // usage numbers describe, so those go with it.
    onCountChanged: {
      if (count > 0) return
      root.toolLog = ({})
      root.turnCost = ({})
      root.usageInput = 0
      root.usageOutput = 0
      root.usageTotal = 0
      root.outputBase = 0
    }
  }
  readonly property alias turns: turnModel

  // ------------------------------------------------------- derived readouts
  // The panel has to answer four questions at a glance -- what is it doing, for
  // how long, what did it touch, and how much room is left. Two of them fall
  // out of the turn model ingest() already writes; the other two are measured
  // instrumentation the protocol hands over (see `usage` and the stats probe
  // below). They live here rather than in the panel so that the panel and the
  // bar indicator cannot disagree about them, and because a readout that
  // survives the window being closed has to outlive the window.

  // The row currently being written. `count` is notifiable so this re-binds on
  // append, and the row object it hands back notifies on setProperty, so a
  // binding through it follows the stream token by token.
  readonly property var liveTurn: turnModel.count > 0 ? turnModel.get(turnModel.count - 1) : null

  // The tool in flight right now, "" when none. Gated on `pending` so a settled
  // turn cannot report a tool that ingest() has already cleared.
  readonly property string activeTool: liveTurn && liveTurn.pending ? String(liveTurn.tool) : ""

  // ---------------------------------------------------------------- duration
  // Nothing in the protocol timestamps anything, so the clock is ours: when the
  // running turn was accepted, and what every finished turn cost, kept per row
  // so an answer from ten minutes ago still says how long it took and how many
  // tokens it was. `busy` is the only input, and it flips exactly twice a turn.
  property double turnStartedAt: 0
  // row -> { ms, tokens }
  property var turnCost: ({})

  onBusyChanged: {
    if (busy) {
      root.turnStartedAt = Date.now()
      root.outputBase = root.usageOutput
      return
    }
    if (root.turnStartedAt <= 0) return
    var next = {}
    for (var k in root.turnCost) next[k] = root.turnCost[k]
    next[turnModel.count - 1] = { ms: Date.now() - root.turnStartedAt,
                                  tokens: root.turnOutput() }
    root.turnCost = next
  }

  // ------------------------------------------------------------------ tools
  // What each turn touched -- { name, arg, ms } per call, keyed by row and kept
  // AFTER the call ends. ingest() clears `tool` the moment a tool returns,
  // which is right for "what is running now" and useless for "what did it do";
  // this is the record a terminal gets for free from scrollback and a 460px
  // panel has to keep on purpose.
  //
  // Rebuilt by assignment rather than mutated, because a plain `var` only
  // notifies on assignment. Tool calls are seconds apart, so the copy is free.
  property var toolLog: ({})

  onActiveToolChanged: {
    var row = turnModel.count - 1
    if (row < 0) return

    var list = (root.toolLog[row] || []).slice()
    if (root.activeTool !== "") {
      // ingest() joins the tool name and its one summarised argument with a
      // space; split them back apart so the name can be typeset as a name.
      var cut = root.activeTool.indexOf(" ")
      list.push({
        name: cut < 0 ? root.activeTool : root.activeTool.substring(0, cut),
        arg: cut < 0 ? "" : root.activeTool.substring(cut + 1),
        t0: Date.now(),
        ms: 0
      })
    } else if (list.length > 0 && list[list.length - 1].ms === 0) {
      var open = list[list.length - 1]
      list[list.length - 1] = { name: open.name, arg: open.arg, t0: open.t0,
                                ms: Date.now() - open.t0 }
    }

    var next = {}
    for (var k in root.toolLog) next[k] = root.toolLog[k]
    next[row] = list
    root.toolLog = next
  }

  // ---------------------------------------------------------------- context
  // Measured, not estimated. `message_update` carries a usage block that
  // streams during the turn, and `get_session_stats` reports the window the
  // session is filling -- ingest() hands both to the setters below and
  // everything here is derived from them. An earlier version of this file
  // guessed at 4 characters per token against an assumed 131K window; the real
  // numbers were one field away the whole time.
  property int usageInput: 0
  property int usageOutput: 0
  property int usageTotal: 0
  // 0 until a session has reported one. Nothing here invents a default: a
  // percentage of a made-up window is worse than no percentage.
  property int contextWindow: 0

  function applyUsage(u) {
    if (!u) return
    var input = Number(u.input || 0)
    var output = Number(u.output || 0)
    var total = Number(u.totalTokens || (input + output))
    if (total <= 0) return
    root.usageInput = input
    root.usageOutput = output
    root.usageTotal = total
  }

  // The stats response, dug out defensively: the payload has been seen at the
  // top level of the response frame, and a wrapper key would be a silent zero
  // rather than a visible break.
  function applyStats(d) {
    var s = d.stats || d.result || d.data || d
    var cu = s ? s.contextUsage : null
    if (!cu) return
    if (Number(cu.contextWindow) > 0) root.contextWindow = Number(cu.contextWindow)
    if (Number(cu.tokens) > 0) root.usageTotal = Number(cu.tokens)
  }

  // Whether there is a real percentage to show. The panel prints raw tokens
  // until there is, rather than a number it cannot stand behind.
  readonly property bool contextKnown: contextWindow > 0 && usageTotal > 0

  // ------------------------------------------------- names the bar widgets use
  // The panel and the bar were built against this file at the same time and
  // landed on different names for the same four numbers. Aliasing rather than
  // renaming, because both sides are already written and tested against their
  // own spelling; the alternative is editing working code in two places to win
  // an argument about vocabulary.
  readonly property double askedAt: turnStartedAt
  readonly property real turnSeconds: turnStartedAt > 0
    ? Math.max(0, (busy ? Date.now() : (settledAtMs || Date.now())) - turnStartedAt) / 1000
    : 0
  readonly property int tokensTotal: usageTotal
  readonly property real contextPercent: contextKnown ? (usageTotal / contextWindow) * 100 : 0

  // Frozen when a turn ends so `turnSeconds` reports what the turn COST rather
  // than how long ago it happened.
  property double settledAtMs: 0
  readonly property real contextFraction:
    contextKnown ? Math.min(1, usageTotal / contextWindow) : 0

  // Output tokens produced by THIS turn -- the number that moves while you
  // watch it, and the one a coding agent counts on its spinner line.
  //
  // `usage.output` has been seen reset per turn; were it ever cumulative across
  // the session instead, the baseline below turns it into the same number
  // either way (a cumulative counter only ever grows past the baseline, a
  // per-turn one starts under it).
  property int outputBase: 0
  function turnOutput() {
    return root.usageOutput >= root.outputBase
      ? root.usageOutput - root.outputBase : root.usageOutput
  }
  readonly property int liveTokens: {
    root.usageOutput   // re-run as the count streams in
    return busy ? turnOutput() : 0
  }

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
    root.settledAtMs = 0
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
      // The stats probe is bookkeeping, not conversation: read it when it
      // worked and drop it when it did not. It must never abort a turn or
      // paint the transcript red -- that path belongs to the prompt.
      if (d.command === "get_session_stats") {
        if (d.success !== false) root.applyStats(d)
        break
      }
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
      // Usage rides along with the deltas -- and arrives on updates that carry
      // nothing else -- so it is read before the event check below bails out.
      if (d.usage) root.applyUsage(d.usage)
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
      // The one moment the context can have changed, so the one moment worth
      // asking. Event-driven, once per turn -- never on a timer.
      send({ type: "get_session_stats" })
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
    if (root.settledAtMs === 0 || root.busy) root.settledAtMs = Date.now()
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

  // Assembled rather than written inline so the settings block above stays the
  // one place anything is configured. The `cd` comes first because pi reads
  // CLAUDE.md from its working directory.
  function buildCommand() {
    var parts = ["SHIM_URL=" + root.shimUrl, "exec " + root.binary,
                 "--mode rpc", "-ne", "--no-session",
                 "--provider " + root.provider, "--model " + root.model]
    for (var i = 0; i < root.promptFiles.length; i++)
      parts.push("--append-system-prompt " + root.promptFiles[i])
    for (var j = 0; j < root.extensions.length; j++)
      parts.push("-e " + root.extensions[j])
    return "cd " + root.workdir + " && " + parts.join(" ")
  }

  // --------------------------------------------------------------- process
  Process {
    id: proc

    // `sh -lc` for the same reason ScriptWidget uses it: pi lives in ~/.bun/bin,
    // which a login shell puts on PATH and a bare exec does not, and every `~`
    // below needs expanding. `exec` so that sh replaces itself with pi --
    // otherwise stdin belongs to sh and `write()` goes nowhere.
    command: ["sh", "-lc", root.buildCommand()]

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
