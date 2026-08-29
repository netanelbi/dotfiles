pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The assistant's face. The engine is `pi --mode rpc`, and it is NOT a child
// of this shell -- it lives behind a unix socket, under a systemd user
// service. This file is the client.
//
// ------------------------------------------------------- why it is not a child
// It used to be one, and the reason it stopped is the one failure this design
// cannot survive. Editing any QML file hot-reloads the shell, and a hot reload
// takes every Process child with it. Measured on the live shell, one line
// changed in Style.qml:
//
//   before:  warm=true   turns=4   tokens=15007
//   after:   warm=false  turns=4   tokens=0
//
// Nothing crashed and the transcript came back, because it is restored off
// pi's own session file. What did not come back was the warm process and the
// turn in flight -- so an assistant whose whole job is maintaining this laptop
// killed itself mid-sentence every time it edited the shell it lives in.
//
// So the process moved out. `~/.local/bin/ori-agent` owns it now, started by
// `ori-agent.socket` on the first connect, and everything about SPAWNING it
// went with it: the working directory, the -ne argument, the extension list,
// the system prompt files, the warm/idle tradeoff and the idle kill. Read that
// file for any of those; this one no longer decides them.
//
// What stayed here is the conversation. The frames below are pi's own, the
// broker forwards them verbatim in both directions, and the protocol notes in
// this header describe the same wire they always did. Only the pipe changed.
//
// -------------------------------------------------------------- and the cost
// A reload now costs the panel and nothing else. The socket reconnects, the
// transcript is re-read from the live agent with get_entries, and the answer
// still being written is replayed out of the broker's buffer -- see reattach()
// and the RECONNECT section of ori-agent, where the three measurements that
// design rests on are recorded.
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
// `prompt` also takes an `images` array. Verified against the bundle and end to
// end against a real screenshot, because the shape is not guessable:
//
//   {"type":"prompt","message":"what is this error?",
//    "images":[{"type":"image","mimeType":"image/png","data":"<raw base64>"}]}
//
// Each element is a CONTENT BLOCK, not a path and not a data: URI -- the RPC
// layer does `userContent.push(...images)` straight into the user message, and
// the image normaliser downstream does `Buffer.from(block.data,"base64")`. A
// `data:image/png;base64,` prefix would therefore be decoded as image bytes and
// the picture would arrive corrupt rather than rejected. `steer` and `follow_up`
// take the same array in the same shape.
//
// The model is TEXT-ONLY (deepseek-v4-flash), and this still works, because it
// is reached through ollama-shim: the shim's mutateOpenAI() walks the outgoing
// message content, hands every image block to a vision model via describeImage()
// and substitutes a text description in place. So the image never reaches
// deepseek at all -- what reaches it is a paragraph that begins "[ollama-shim:
// an image in this message was replaced with text...]". Ori says so in its
// answers, which is honest and worth leaving alone.
//
// One correction to the folklore: the shim doing that work is NOT the local one
// on 127.0.0.1:11435. `~/.pi/agent/models.json` points the `ollama` provider at
// https://ollama.ncym.uk/v1, which is the same shim on the VPS; the local
// instance is only what SHIM_URL below gives to shim-web for searches. Both
// describe images identically, so nothing here depends on which -- but a reader
// looking for the description in `journalctl --user -u ollama-shim` will not
// find it unless models.json is repointed.
//
// ------------------------------------------------------------- warm vs idle
// Unchanged as a tradeoff, and no longer this file's to enforce. A warm node
// process is ~200MB, which is more than this entire shell, so it is NOT
// started at login: the first question spawns it and ten minutes of silence
// kills it again. The clock moved to the broker along with the process -- see
// WHO OWNS THE IDLE KILL in ori-agent for why a timer living in the panel
// meant the panel's lifetime decided the agent's.
//
// ------------------------------------------------------------------- flags
// The command line is built in ori-agent's build_command(), which is where the
// arguments for `-ne`, the extension list and the absence of `--skill` are now
// recorded. The four values this panel switches at RUNTIME are the only ones
// it still sends -- provider, model, thinking level and session path -- as a
// `__config` frame the broker applies to the next spawn. See sendConfig().
//
//   --session PATH  attach to an existing session file, when resuming. Omitted
//        for a fresh conversation; see "sessions" below for why `--no-session`
//        is gone.
//
// ---------------------------------------------------------------- sessions
// This file used to pass `--no-session`, and the comment above it said
// continuity comes from the process being alive. That was true and it was also
// the bug: the process is killed after ten minutes of silence, so a transcript
// the panel was still showing described a conversation pi had already
// forgotten. Ask a follow-up and Ori answers as a stranger.
//
// So `--no-session` is gone. The justification, in full, because the tradeoff
// is real:
//
//   * Writing a session file costs NOTHING in context. Context grows because a
//     conversation is long, not because it is on disk -- a fresh spawn starts a
//     fresh session file with an empty history either way. The only moment
//     persistence costs tokens is when you deliberately RESUME a long
//     conversation, which is an explicit act with a visible message count next
//     to it in the list.
//   * pi's auto-compaction is on (`autoCompactionEnabled: true`, measured via
//     get_state) and the window here is 1,048,576 tokens. A turn of Ori's costs
//     ~10K. Compaction is a distant concern, not a running one.
//   * What it buys: the idle kill stops being amnesia. ask() re-attaches a cold
//     child to the session the visible transcript came from, so the screen and
//     the model agree again.
//   * What it costs: one .jsonl per conversation under
//     ~/.pi/agent/sessions/--home-netanel-.dotfiles--/, shared with whatever
//     `pi` writes when run from a terminal in this repo.
//
// Resuming, verified by hand rather than assumed:
//
//   --session PATH   at spawn. Takes a path, or an id / id-prefix that pi
//                    resolves against the cwd's session directory. `--resume`
//                    and `-r` are NOT this: they are booleans that open the
//                    interactive picker, which does not exist here. `--continue`
//                    is also unusable -- it takes the most recent session in the
//                    cwd, which would silently hijack a terminal pi session in
//                    this same repo.
//   switch_session   {"type":"switch_session","sessionPath":"/abs/path.jsonl"}
//                    on a RUNNING child. Works even on a child that was started
//                    with --no-session, and genuinely reloads the context: the
//                    proof run asked for a code word given to a different
//                    process and got it back.
//   get_entries      the transcript, as the session's own append-only entry
//                    list -- `{entries:[...], leafId}`. Entry types seen:
//                    model_change, thinking_level_change, and `message`, whose
//                    `.message` is a normal {role, content:[blocks]}. That is
//                    what rehydrate() below walks.
//
// There is NO list-sessions command in the RPC protocol, and no directory
// listing in QML. So the list is an index this file keeps itself, in
// $XDG_STATE_HOME/quickshell/ori-sessions.json, written at the one moment
// everything needed is known: the get_session_stats response that already
// arrives once per settled turn carries `sessionFile`, `sessionId` and
// `totalMessages`, and the first user turn is sitting in turnModel. Nothing
// polls, nothing shells out, and the list is readable while the process is
// cold. It lists Ori's conversations only, which is the point -- the session
// directory is shared with coding runs of `pi` in this repo and those are not
// what Ctrl+R is for.
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
  // What is left after the process moved out: the things that describe a
  // CONVERSATION. Everything that described a process -- the binary, the
  // extensions, the system prompt files, the shim URL, the idle timeout -- is
  // in ori-agent now, because that is what spawns it.
  //
  // Changing any of this hot-reloads the shell, and that is now free: the
  // reload rebuilds this client, reconnects, and picks up whatever the agent
  // was doing.
  //
  // Provider and model are the DEFAULTS and also the live values -- `/model`
  // writes them (see "panel commands" below) and buildCommand() reads them, so a
  // switch survives the idle kill instead of dying with the child that heard it.
  // The literals here are what a machine with no ori-model.json starts on; a
  // saved choice overrides them, which is the price of the command existing and
  // is why the pair is stored together and validated before it is written.
  //
  // The thinking level is deliberately NOT here. Nothing is passed for it unless
  // someone asks -- see `effort` below.
  property string provider: "ollama"
  property string model: "deepseek-v4-flash:0731"

  // Where it runs -- the whole "it manages this machine" decision, and the
  // broker's to make now. REPORTED by it in `__welcome` rather than written
  // twice: the panel shows this string in its footer, and a panel naming a
  // directory the agent is not in is worse than a panel that is briefly blank.
  // The literal is what is shown before the first welcome lands.
  property string workdir: "~/.dotfiles"

  // The session index (see "sessions" above). Same XDG rule the reminder state
  // file follows, so both land in the same place on any machine.
  readonly property string stateDir: {
    var xdg = Quickshell.env("XDG_STATE_HOME")
    return ((xdg && xdg !== "") ? xdg : Quickshell.env("HOME") + "/.local/state") + "/quickshell"
  }
  readonly property string sessionIndexPath: stateDir + "/ori-sessions.json"
  // How many conversations to keep offering. Old rows are dropped from the
  // index, never from disk -- deleting someone's transcripts is not this file's
  // business.
  readonly property int maxSessions: 40

  // ------------------------------------------------------- restore on start
  // A shell reload should not cost the conversation. On start the newest
  // session is put back on screen AND armed as the next cold spawn's
  // `--session`, so the first follow-up reaches a model that still remembers
  // it rather than a stranger looking at someone else's transcript.
  //
  // No pi process is started to do this. The file pi writes is JSONL of
  // exactly the entries `get_entries` returns, so the transcript is read
  // straight off disk: restoring a conversation costs a file read, not 200MB
  // of node sitting resident from login until you happen to ask something.
  readonly property bool restoreOnStart: true
  // Past this, a restart is a new day rather than a reload, and last week's
  // conversation reappearing is a surprise rather than a continuation. The
  // session stays in the list either way -- this only decides what is on
  // screen before you have asked for anything.
  readonly property int restoreMaxAgeMs: 12 * 60 * 60 * 1000
  // Transcripts here reach ~9MB. The read and the per-line JSON.parse both run
  // on the UI thread, so only the TAIL goes back on screen: enough to see
  // where you were, bounded so a long conversation cannot stall the shell at
  // startup. pi's own context is not truncated by this -- that arrives whole,
  // from `--session`.
  readonly property int restoreMaxEntries: 120

  // Refuse to encode an image bigger than this. pi downscales anything large
  // itself, but the base64 pass below runs on the UI thread, so a 40MB file
  // would be a visible freeze rather than a slow answer.
  readonly property int maxImageBytes: 12 * 1024 * 1024

  // ------------------------------------------------------------------ state
  // `busy` is the one the UI keys off: true from the moment a question is
  // accepted until the agent settles.
  property bool busy: false
  // Set when pi refuses a command or the child dies; cleared on the next ask.
  property string error: ""

  // Whether a pi child exists behind the socket. Reported by the broker --
  // `__welcome` on connect, then `__pi_started` / `__pi_exited` -- rather than
  // derived from anything here, because nothing here can see it any more.
  property bool warm: false
  // Whether the socket is up. Separate from `warm`: the broker can be running
  // with no child (the ordinary idle state), and the child can be running with
  // this panel disconnected (the whole point).
  readonly property bool connected: sock.connected

  // ---------------------------------------------------------------- session
  // The file pi is writing right now, and its id -- both reported by
  // get_session_stats, which already runs once per settled turn. Empty until
  // the first turn of a conversation has settled.
  property string sessionFile: ""
  property string sessionId: ""
  // What the NEXT cold spawn should attach to, "" for a fresh conversation.
  // Set by resume(), and by ask() when a transcript is on screen but the child
  // has been idle-killed out from under it.
  property string resumePath: ""
  // True between asking for a transcript and getting it, so the get_entries
  // response can be told apart from any other.
  property bool awaitingEntries: false

  // Past conversations, newest first: { id, file, label, at, count }. Read from
  // the index file at startup and rewritten by recordSession(); the panel binds
  // to it directly.
  property var sessions: []

  // ------------------------------------------------------------ view state
  // Whether the panel is on screen, and whether an answer landed while it was
  // not. This is UI state living on the engine on purpose: the panel and the bar
  // indicator are two different windows that must agree, and "was anyone looking
  // when this finished" is the question that decides whether an answer gets
  // announced at all. The alternative is a third singleton whose whole job is to
  // hold two booleans.
  property bool panelOpen: false
  property bool unread: false
  // Whether the bar cell is pinned COMPACT -- glyph only, never opening into
  // the verb-and-elapsed readout however busy Ori gets. Right-click on the cell
  // toggles it.
  //
  // Here for the same reason the two above are: the cell is instantiated once
  // PER MONITOR, and a preference the user set on one screen that did not apply
  // on the other would be a bug nobody could describe. Deliberately NOT
  // persisted to disk -- it is a "leave me alone for now" gesture, not a
  // setting, and a shell reload is a reasonable place for it to lapse.
  property bool cellCompact: false

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
  //   images    newline-separated source paths attached to a user turn, "" when
  //             none. A ListModel fixes its roles from the FIRST row inserted,
  //             so this is written on every append (see appendTurn) rather than
  //             only on the rows that have one -- otherwise the role would not
  //             exist and every later write to it would be dropped silently.
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
  // What each turn touched -- { name, arg, t0, ms, at } per call, keyed by row
  // and kept AFTER the call ends. ingest() clears `tool` the moment a tool
  // returns, which is right for "what is running now" and useless for "what did
  // it do"; this is the record a terminal gets for free from scrollback and a
  // 460px panel has to keep on purpose.
  //
  // `at` is WHERE, and it is the field the panel was missing. A turn that does
  // real work is speak, run, speak, run -- but every delta goes through grow()
  // onto one string, and a flat call list has no idea which part of that string
  // it ran between. So the transcript rendered as a single welded paragraph
  // (`...write and test it first.The child got TERM...`) with one batch line
  // over the top of all of it. Stamping the answer's LENGTH at the moment a
  // call starts is enough for Fmt.split to cut the text there and put the batch
  // back where it happened.
  //
  // A marker written into the text would have been the easier change and is
  // wrong: this panel renders markdown the MODEL wrote, so any sentinel is a
  // string Ori can emit. An offset cannot be typed.
  //
  // Rebuilt by assignment rather than mutated, because a plain `var` only
  // notifies on assignment. Tool calls are seconds apart, so the copy is free.
  property var toolLog: ({})

  // Handed from tool_execution_end to onActiveToolChanged, which run one after
  // the other: { pid, log } when the call being closed was backgrounded rather
  // than finished, null otherwise. Cleared as it is consumed, so it can never
  // leak onto the next call.
  property var closingBg: null

  // The literal argument of the call in flight, handed from
  // tool_execution_start to onActiveToolChanged the same way `closingBg` is
  // handed the other direction. A property rather than a third field welded
  // into the `tool` role's string: that string is split on its first space to
  // recover the name, and a command contains spaces of its own.
  property string activeToolRaw: ""

  // ------------------------------------------------------ background jobs
  // What is still running with nobody waiting on it. A backgrounded command
  // outlives the turn that started it -- that is the whole point -- so it
  // cannot be tracked by anything scoped to a turn, and the panel had no way
  // to say "something is still out there" once the answer settled.
  //
  // pid -> { pid, since }. Added when the bash tool hands one back, removed
  // when the extension's completion message arrives. Event-driven both ways:
  // nothing here polls a process table.
  // id -> { id, pid, kind, label, name, since }
  //
  // `kind` is the field this is built around rather than bolted onto, because
  // the tray that shows these has to say WHAT is running and not merely how
  // much: "2 tasks · 1 monitor" is a different sentence to "3 things". All
  // three kinds occur.
  //
  //   job      a command the bash tool backgrounded and walked away from
  //   monitor  the same, but with a live filter on its output -- it is not
  //            going to finish on its own and you are watching it
  //   agent    a delegate that outlived the turn that started it. The only
  //            kind with a `name`, and so the only one whose row can be joined
  //            to agentActivity and say what it is doing.
  property var bgJobs: ({})
  readonly property int bgCount: Object.keys(root.bgJobs).length

  readonly property var bgKindNoun: ({ job: "task", monitor: "monitor", agent: "agent" })
  readonly property var bgKindOrder: ["job", "monitor", "agent"]

  // { job: n, monitor: n, agent: n } -- recomputed off bgJobs, which is
  // reassigned rather than mutated, so this follows it.
  readonly property var bgKinds: {
    var out = { job: 0, monitor: 0, agent: 0 }
    for (var k in root.bgJobs) {
      var kind = String(root.bgJobs[k].kind || "job")
      if (out[kind] === undefined) out[kind] = 0
      out[kind] += 1
    }
    return out
  }

  // "2 tasks · 1 monitor". Only the kinds that exist, in a fixed order, so the
  // line does not reshuffle itself as jobs come and go.
  readonly property string bgSummary: {
    var parts = []
    for (var i = 0; i < root.bgKindOrder.length; i++) {
      var kind = root.bgKindOrder[i]
      var n = root.bgKinds[kind] || 0
      if (n === 0) continue
      var noun = root.bgKindNoun[kind]
      parts.push(n + " " + noun + (n === 1 ? "" : "s"))
    }
    return parts.join(" · ")
  }

  // handle -> the one line the delegate wrote about what it is doing now.
  // Empty for everything that is not an agent, and empty again the moment an
  // agent finishes: the subagent extension clears the field with the status,
  // so a settled row cannot keep claiming it is reading a file.
  property var agentActivity: ({})

  function addBgJob(pid, kind, label, name) {
    if (!pid) return
    var next = {}
    for (var k in root.bgJobs) next[k] = root.bgJobs[k]
    next[String(pid)] = { id: String(pid), pid: pid,
                          kind: String(kind || "job"),
                          label: String(label || ""),
                          // The delegate's handle, and the ONLY field that
                          // joins this row to agentActivity. A tray row is
                          // written once and never updated -- what moves is the
                          // registry the panel reads, keyed by this.
                          name: String(name || ""),
                          since: Date.now() }
    root.bgJobs = next
  }

  function dropBgJob(pid) {
    if (!pid || root.bgJobs[String(pid)] === undefined) return
    var next = {}
    for (var j in root.bgJobs) if (j !== String(pid)) next[j] = root.bgJobs[j]
    root.bgJobs = next
  }

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
        ms: 0,
        // The answer as it stands RIGHT NOW, which is everything Ori said
        // before reaching for this tool. Read off the same row the log is
        // keyed by, so the two can never describe different turns.
        at: String(turnModel.get(row).text).length,
        // What it actually ran, beside what it said it was doing.
        raw: root.activeToolRaw
      })
      root.activeToolRaw = ""
    } else if (list.length > 0 && list[list.length - 1].ms === 0) {
      var open = list[list.length - 1]
      list[list.length - 1] = { name: open.name, arg: open.arg, raw: open.raw,
                                t0: open.t0,
                                ms: Date.now() - open.t0, at: open.at,
                                // null for an ordinary call; { pid, log } for
                                // one the bash tool detached and left running.
                                bg: root.closingBg }
      root.closingBg = null
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
    if (!s) return
    // The same response carries which file this conversation is, which is the
    // only place that fact is available without an extra round trip -- so the
    // session index is written from here rather than from a probe of its own.
    if (s.sessionFile) {
      root.sessionFile = String(s.sessionFile)
      root.sessionId = String(s.sessionId || "")
      root.recordSession(Number(s.totalMessages || 0))
    }
    var cu = s.contextUsage
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

  // Wall clock of the last piece of text Ori actually produced -- stamped by
  // `grow()`, which is the one choke point every text/thinking delta goes
  // through, and reset by `ask()` so a turn opens at full flow.
  //
  // It exists because a character counter CANNOT tell working from hung: a tool
  // call streams no deltas, so the count sits frozen for the whole of a
  // `bash sleep 15` while the process is perfectly healthy. The gap BETWEEN
  // deltas is the fact that number is missing, and OriCell drives the scan
  // travelling its keel off it -- full rate while text arrives, decaying to a
  // drift while it does not. A stamp, not a timer: nothing here polls it.
  property double lastAppendAt: 0
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

  // The same number after the turn settles, which liveTokens deliberately zeroes
  // so nothing on screen claims to still be counting. The footer's tok/s needs
  // the finished figure to freeze on, and `outputBase` is not moved again until
  // the next ask(), so turnOutput() still holds it.
  readonly property int lastTurnTokens: {
    root.usageOutput
    return busy ? 0 : turnOutput()
  }

  function lastAssistant() {
    for (var i = turnModel.count - 1; i >= 0; i--) {
      if (turnModel.get(i).role === "assistant") return i
    }
    return -1
  }

  // The mirror of the above, and it exists because the hover panel opens with
  // the QUESTION. After four minutes away, "bash rg -n implicitHeight" means
  // nothing on its own; with the line you typed above it, it means everything.
  // Nothing else in this shell had a reason to look backwards for a user turn.
  function lastUser() {
    for (var i = turnModel.count - 1; i >= 0; i--) {
      if (turnModel.get(i).role === "user") return i
    }
    return -1
  }

  // Milliseconds this turn spent actually GENERATING, which is not the same as
  // how long the turn took. A turn that ran `bash sleep 9` and then wrote fifty
  // tokens took ten seconds and generated for one; dividing by the wall clock
  // reports 5 tok/s for a model doing 50, and every tool-using turn reads as a
  // slow model. So the gaps are summed rather than the span: each delta adds the
  // time since the delta before it, and a gap longer than the cap is a tool call
  // or a stall, not generation, so it is not counted.
  //
  // 2s: the widest gap actually observed between deltas mid-answer here is well
  // under a second, and the narrowest tool call is comfortably over two.
  readonly property int genGapCapMs: 2000
  property double genMs: 0

  function grow(field, delta) {
    // The first thing back after a question is the receipt for that question.
    root.markRead()

    // A TURN THE PANEL DID NOT OPEN.
    //
    // Every turn used to start here, so a row was always waiting: ask() appends
    // the question and an empty assistant row, and the deltas stream into it.
    // That stopped being true the moment the agent could be woken by something
    // other than the user. The bash tool backgrounds a long command and wakes
    // the agent when it finishes (sendMessage with triggerTurn), and the first
    // delta of THAT turn arrived with no pending row -- so lastAssistant()
    // handed back the answer that had already settled, and the new turn was
    // appended to the end of its last sentence:
    //
    //   ...ticking away in the background as PID 305128.BACKGROUNDED — done, exit 0.
    //
    // One reply welded to the tail of another, with no break and no receipt of
    // its own. Opening a row when there is no pending one is the whole fix, and
    // it is general: any turn the agent starts by itself lands correctly now,
    // not just this one.
    var i = lastAssistant()
    if (i < 0 || !turnModel.get(i).pending) {
      appendTurn("assistant", "", "", "", true, "")
      i = turnModel.count - 1
      // The agent is demonstrably working -- it is mid-sentence. Nothing else
      // is going to set this, because nothing here asked it a question.
      root.busy = true
      root.turnStartedAt = Date.now()
      root.appended()
    }
    turnModel.setProperty(i, field, turnModel.get(i)[field] + delta)
    var now = Date.now()
    if (root.lastAppendAt > 0) {
      var gap = now - root.lastAppendAt
      if (gap > 0 && gap < root.genGapCapMs) root.genMs += gap
    }
    root.lastAppendAt = now
    root.appended()
  }

  // Output tokens per second over generation time only. Zero until there is
  // enough of a sample to mean anything -- the first delta of a turn has no
  // predecessor to measure against, so an early reading is noise.
  readonly property real tokensPerSecond: {
    root.usageOutput
    root.genMs
    var toks = root.busy ? turnOutput() : root.lastTurnTokens
    return (root.genMs > 400 && toks > 0) ? toks / (root.genMs / 1000) : 0
  }

  // ------------------------------------------------------------------- api
  // The one place a row is added, so the role set can never diverge between
  // ask(), the streaming turn, and rehydrate().
  function appendTurn(role, text, thinking, tool, pending, images) {
    // `sent` is written on EVERY row, assistant rows included, for the reason
    // the `images` note above gives: a ListModel fixes its roles from the first
    // row inserted, and a role missing there can never be written afterwards.
    // 2 is the resting value -- see `sentState` in TurnDelegate; the two paths
    // that actually have something to report (ask/steer) knock it down to 0
    // straight after appending.
    turnModel.append({ role: role, text: text, thinking: thinking,
                       tool: tool, pending: pending, images: images, sent: 2 })
  }

  // ----------------------------------------------------- delivery receipts
  // Where the newest question got to: 0 queued, 1 on the wire, 2 the agent has
  // acted since. Nothing in the protocol acknowledges a message by id, so 2 is
  // INFERRED -- the first token or tool call after a question went out is the
  // agent demonstrably working on it, which is the fact the tick is claiming.
  // That is a weaker guarantee than a real read receipt and a stronger one than
  // the alternative, which was to show nothing at all and let a 7-second cold
  // spawn look like a message that had vanished.
  property bool awaitingRead: false

  function markSent(state) {
    for (var i = turnModel.count - 1; i >= 0; i--) {
      if (turnModel.get(i).role !== "user") continue
      if (Number(turnModel.get(i).sent) < state) turnModel.setProperty(i, "sent", state)
      return
    }
  }

  // Called from the two places that prove the agent is working on it. Gated on
  // a flag rather than scanning the model, because grow() runs per token.
  function markRead() {
    if (!root.awaitingRead) return
    root.awaitingRead = false
    markSent(2)
  }

  // Returns whether the question was ACCEPTED. The composer keys its "clear the
  // draft" on this: a message typed while a turn is still running is refused,
  // and silently wiping the field in that case loses what you wrote.
  //
  // `images` is optional and unchanged callers are unaffected: a plain
  // ask("...") is exactly what it was. When given, it is a list of things to
  // attach, each of which may be an absolute path, a file:// url, a data: URI,
  // or an already-built {mimeType,data} block -- whichever the caller happens
  // to have. Anything that cannot be read is reported and the question still
  // goes, because losing the question to a bad screenshot is the worse failure.
  function ask(text, images) {
    var msg = String(text || "").trim()
    if (msg === "") return false

    // The panel's own commands, taken before anything else touches the draft.
    // They are not conversation: nothing is appended, no child is spawned for
    // them, and `busy` never moves -- so `/effort low` on a cold panel costs a
    // property write and a small file, not 200MB of node. True is returned so
    // the composer still clears the field, which is what makes it feel like a
    // command rather than a message that failed to send.
    if (root.runPanelCommand(msg)) return true

    // Nothing to send it to. Refused rather than queued: a question queued
    // here would be sent on reconnect, minutes later and out of the context
    // it was asked in, and there is no honest way to show that on screen.
    // Returning false keeps the draft, so nothing typed is lost -- and the
    // socket is systemd-activated, so this window is a broker restart wide.
    // (Panel commands are deliberately above this: /model and /effort are
    // local state and work with no agent at all.)
    if (!sock.connected) {
      root.error = "the agent socket is down -- systemctl --user status ori-agent"
      return false
    }

    // Past the refusal, so a staging area the composer handed over is now
    // spent -- the ones whose marker survived are already in `images`, and the
    // ones whose marker was deleted are meant to be dropped, because the draft
    // that could still have named them is about to be cleared too. This is the
    // half of takeAttachments() that had to move here to survive a refusal.
    if (root.attachmentsStaged) {
      root.attachments = []
      root.attachmentsStaged = false
    }

    var blocks = []
    var labels = []
    // Cleared here rather than per attachment, so that with several of them a
    // failure on the first is not erased by a success on the second.
    root.imageError = ""
    var srcs = (images === undefined || images === null) ? []
             : (Array.isArray(images) ? images : [images])
    for (var i = 0; i < srcs.length; i++) {
      var b = root.imageBlock(srcs[i])
      if (b) { blocks.push(b); labels.push(b.source) }
    }

    root.error = root.imageError

    // Steer: pi's native mid-stream redirect. The turn in flight is not killed
    // -- the message is queued and delivered after the current tool call,
    // before the next LLM call -- so the assistant turn keeps streaming,
    // redirected. The question is appended to the transcript so it is visible
    // on screen.
    if (root.busy) {
      var imgs = []
      for (var j = 0; j < blocks.length; j++) {
        var bb = blocks[j]
        imgs.push({ type: "image", mimeType: bb.mimeType, data: bb.data })
      }
      var steer = { type: "steer", message: msg }
      if (imgs.length > 0) steer.images = imgs
      send(steer)

      // The stream always writes to lastAssistant(), so the ROW ORDER is the
      // whole problem here. Appending only the question put it BELOW the row
      // the redirected answer then streamed into -- the reply appeared above
      // the message it was replying to, and the message it answered sat at the
      // bottom of the panel with nothing under it.
      //
      // So the turn in flight is closed where it stands, the question goes
      // after it, and a fresh assistant row opens for what comes back. Three
      // appends, no insert: toolLog is keyed by row index, and inserting would
      // shift every call already logged onto the wrong turn. A pre-steer row
      // with no text is not wasted -- its tool calls are still logged against
      // it, so it settles into the receipt for the work you interrupted.
      var cur = lastAssistant()
      if (cur >= 0) {
        turnModel.setProperty(cur, "pending", false)
        turnModel.setProperty(cur, "tool", "")
      }
      appendTurn("user", msg, "", "", false, labels.join("\n"))
      // Already on the wire -- but pi holds a steer until the tool call in
      // flight returns and only then delivers it, so "sent" is the whole truth
      // and "read" is not yet. This is the case the ticks exist for: the gap
      // between pressing enter and the agent turning round is seconds long and
      // used to look like nothing happening.
      markSent(1)
      root.awaitingRead = true
      appendTurn("assistant", "", "", "", true, "")
      root.appended()
      return true
    }

    root.startTurn(msg, blocks, labels)
    return true
  }

  // Open a turn: the user's question, an empty assistant row to stream into,
  // and the question queued for the agent. Shared by ask() and the steer path,
  // which defers here until the aborted turn settles.
  function startTurn(msg, blocks, labels) {
    root.busy = true
    root.settledAtMs = 0
    // A turn opens at full flow, so the first seconds -- before a single token
    // has landed -- read as movement rather than as a stall left over from the
    // previous answer.
    root.genMs = 0
    root.lastAppendAt = Date.now()
    appendTurn("user", msg, "", "", false, labels.join("\n"))
    // Queued, not sent. On a cold panel the child does not exist yet and this
    // sits in `pending` until flush() runs from onPiStarted -- measured 6-7s
    // out. The pill says so instead of pretending.
    markSent(0)
    root.awaitingRead = true
    // The assistant's turn exists before a single token arrives, so the view has
    // a row to stream into and the conversation never visibly jumps.
    appendTurn("assistant", "", "", "", true, "")
    root.appended()

    // Queued rather than sent, because the child may not exist yet. `flush()`
    // runs either immediately (warm) or from onPiStarted (cold), so the caller
    // never has to know which case it is.
    pending = msg
    pendingImages = blocks
    // Cold, with a conversation already on screen: re-attach to the session
    // that conversation came from, so the model is not answering a follow-up
    // to something it has no record of. This is the whole reason --no-session
    // had to go. Decided BEFORE sendConfig, because it is one of the four
    // values that config carries.
    if (!root.warm && root.resumePath === "" && root.sessionFile !== ""
        && turnModel.count > 2)
      root.resumePath = root.sessionFile
    root.sendConfig()
    if (root.warm) flush()
    else control({ type: "__spawn" })
  }

  // -------------------------------------------------------------- clipboard
  // Pasting an image. Wayland has no "give me the clipboard as bytes" call in
  // QML, so this asks wl-paste -- which is how anything on this desktop reads
  // the clipboard, and is already a dependency of the clipboard history.
  //
  // The image is written to a FILE and the path is what gets attached, rather
  // than being carried around as base64 in the panel. Two reasons: the path is
  // what imageBlock() already takes, and a path is something the model can be
  // handed to a tool later, which a blob in a text field never can be.
  //
  // The marker put in the draft is Claude Code's, deliberately: `[Image 1]`
  // stands in for the picture so the field stays a text field, and the numbers
  // are how the two halves stay matched when you delete one.
  property var attachments: []      // { n, path }
  property int attachSeq: 0
  // Announced so the composer can insert the marker at the cursor. The path is
  // carried on the signal so nothing has to go looking for it.
  signal attachedImage(int n, string path)
  signal attachFailed(string why)

  Process {
    id: pasteProc
    // Ask for the offered types first: wl-paste with no image on the clipboard
    // writes the TEXT to the file, and a text file called .png would only fail
    // later, at sniffMime, with a confusing message.
    command: ["sh", "-c",
      "t=$(wl-paste --list-types 2>/dev/null | grep -m1 '^image/'); " +
      "[ -n \"$t\" ] || exit 3; " +
      "d=\"${XDG_RUNTIME_DIR:-/tmp}/ori\"; mkdir -p \"$d\" || exit 4; " +
      "f=\"$d/paste-$(date +%s%N).${t#image/}\"; " +
      "wl-paste --type \"$t\" > \"$f\" 2>/dev/null && [ -s \"$f\" ] && printf %s \"$f\""]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(this.text || "").trim()
        if (path === "") return
        var n = ++root.attachSeq
        var next = root.attachments.slice()
        next.push({ n: n, path: path })
        root.attachments = next
        root.attachedImage(n, path)
      }
    }
    onExited: function (code) {
      // 3 is "nothing image-shaped on the clipboard", which is an ordinary
      // Ctrl+V of text and must stay silent -- the field pastes it itself.
      if (code === 3 || code === 0) return
      root.attachFailed("could not read the clipboard image")
    }
  }

  // Returns nothing useful: whether there was an image is only known once
  // wl-paste has answered, and the composer learns it from attachedImage().
  function pasteImage() {
    if (pasteProc.running) return
    pasteProc.running = true
  }

  // Called by the composer on send, with the markers still present in the
  // draft, so an attachment whose `[Image n]` was deleted is dropped instead of
  // being sent invisibly.
  //
  // It deliberately does NOT empty `attachments` itself, though it used to.
  // The composer calls it INSIDE the ask -- ask(text, takeAttachments(text)) --
  // so the argument is evaluated first, and ask() refuses a question typed
  // while a turn is still running. The composer keeps the draft when that
  // happens, precisely so nothing you typed is lost; clearing here threw the
  // picture away behind a `[Image 1]` that was still sitting in that kept
  // draft, and sending again then quietly sent no picture at all. So the rows
  // are spent by ask(), at the one moment the question is known to have been
  // accepted.
  //
  // The flag is what keeps that spend to the composer's send. Clearing on ANY
  // accepted question was tried first and is wrong: `ori image` asks with paths
  // of its own and would throw away a paste that was staged in the panel and
  // not yet sent. (Found the hard way -- it ate the attachment out of this
  // path's own test.)
  property bool attachmentsStaged: false

  function takeAttachments(draft) {
    root.attachmentsStaged = true
    var paths = []
    for (var i = 0; i < root.attachments.length; i++) {
      var a = root.attachments[i]
      if (String(draft).indexOf("[Image " + a.n + "]") >= 0) paths.push(a.path)
    }
    return paths
  }

  function clearAttachments() { root.attachments = [] }

  // ------------------------------------------------------------------ images
  // Set by imageBlock(), read once by ask(). Kept as its own property rather
  // than written straight to `error` so a failure survives ask()'s own reset.
  property string imageError: ""

  readonly property string b64alphabet:
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

  // Base64 by hand, over the bytes. `Qt.btoa` is NOT usable here: it takes a
  // QString and encodes its UTF-8, so every byte above 0x7F would come out as
  // two, and the image would arrive silently corrupt rather than rejected.
  function base64(bytes) {
    var A = root.b64alphabet, out = "", n = bytes.length, i = 0
    for (; i + 2 < n; i += 3) {
      var v = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]
      out += A[(v >> 18) & 63] + A[(v >> 12) & 63] + A[(v >> 6) & 63] + A[v & 63]
    }
    if (n - i === 1) {
      out += A[bytes[i] >> 2] + A[(bytes[i] << 4) & 63] + "=="
    } else if (n - i === 2) {
      var b0 = bytes[i], b1 = bytes[i + 1]
      out += A[b0 >> 2] + A[((b0 << 4) | (b1 >> 4)) & 63] + A[(b1 << 2) & 63] + "="
    }
    return out
  }

  // From the magic bytes, not from the extension: a screenshot tool's output is
  // whatever the tool felt like, and the shim keys its describer on this.
  function sniffMime(b) {
    if (b.length > 8 && b[0] === 0x89 && b[1] === 0x50) return "image/png"
    if (b.length > 3 && b[0] === 0xFF && b[1] === 0xD8) return "image/jpeg"
    if (b.length > 6 && b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return "image/gif"
    if (b.length > 12 && b[0] === 0x52 && b[8] === 0x57 && b[9] === 0x45) return "image/webp"
    return ""
  }

  // One attachment -> one content block in pi's wire shape, plus a `source`
  // for the transcript. Null (and a message on `imageError`) if it cannot be read.
  function imageBlock(src) {
    if (src && typeof src === "object" && src.data)
      return { type: "image", mimeType: String(src.mimeType || "image/png"),
               data: String(src.data), source: String(src.source || "attachment") }

    var p = String(src || "").trim()
    if (p === "") return null

    // A data: URI has to be taken apart, not passed through: pi decodes `data`
    // as raw base64.
    if (p.indexOf("data:") === 0) {
      var comma = p.indexOf(",")
      var semi = p.indexOf(";")
      if (comma < 0 || semi < 0 || p.indexOf(";base64,") < 0) {
        root.imageError = "unsupported data URI"
        return null
      }
      return { type: "image", mimeType: p.substring(5, semi),
               data: p.substring(comma + 1), source: "pasted image" }
    }

    if (p.indexOf("file://") === 0) p = p.substring(7)
    // Cleared FIRST, then set. blockLoading alone is not enough: a FileView
    // asked for a new path can hand back the bytes it already held, and it does
    // so silently -- the transcript row carried the RIGHT path
    // (paste-1787813158822066810.png, 875917 bytes) while the block on the wire
    // carried the 17KB image from the send before it, so the panel showed one
    // picture and the model answered about another. Emptying the path first
    // means there is no previous content to return.
    imageFile.path = ""
    imageFile.path = p
    var buf = imageFile.data()
    if (!buf || buf.byteLength === undefined || buf.byteLength === 0) {
      root.imageError = "cannot read image: " + p
      return null
    }
    if (buf.byteLength > root.maxImageBytes) {
      root.imageError = "image too large (" + Math.round(buf.byteLength / 1048576) + "MB): " + p
      return null
    }
    var bytes = new Uint8Array(buf)
    var mime = root.sniffMime(bytes)
    if (mime === "") {
      root.imageError = "not an image: " + p
      return null
    }
    return { type: "image", mimeType: mime, data: root.base64(bytes), source: p }
  }

  // Read synchronously: an attachment is wanted for the question being sent
  // right now, so there is nothing useful to do while an async read lands.
  FileView {
    id: imageFile
    blockLoading: true
    printErrors: false
  }

  // Abort, then VERIFY. pi's documented abort path (agent_end -> agent_settled
  // within 10ms) is what normally happens, and `busy = false` here matches it
  // closely enough that the composer unlocks immediately. But the path pi
  // cannot take is the one this exists for: an abort arriving while a tool
  // call is wedged -- a backgrounded command holding the pipe, a fetch with no
  // timeout -- never settles, because pi's turn cannot end until the tool
  // returns. pi stays busy on its side while the panel already thinks it is
  // idle, and the next question is then rejected by pi's own guard:
  //
  //   Agent is already processing. Specify streamingBehavior ('steer' or
  //   'followUp') to queue the message.
  //
  // -- which lands on the error strip and the message goes nowhere. That was
  // the "ctrl+c worked, the next message is stuck" report, and it is why the
  // optimistic clear is not trusted blindly: `aborting` arms a watchdog, and
  // any settle (settleTurn) or an exit (onPiExited) disarms it. If neither
  // comes, pi is wedged past persuasion and the watchdog kills the child.
  // The next ask cold-spawns and reattaches to the session, so the cost is
  // the lost half of the aborted turn, which ctrl+c had already written off.
  property bool aborting: false

  Timer {
    id: abortWatchdog
    interval: 4000
    onTriggered: {
      if (!root.aborting) return
      root.aborting = false
      console.log("abort did not settle in " + interval + "ms -- the turn is wedged on a tool call; killing pi")
      control({ type: "__kill" })
    }
  }

  function abort() {
    if (!root.warm) return
    send({ type: "abort" })
    root.busy = false
    root.aborting = root.warm
    abortWatchdog.restart()
  }

  // Drop the conversation without dropping the process -- the cheap "start
  // over" that keeps the 1.2s warm latency. `new_session` clears pi's own
  // context so the model forgets it too, not just the screen.
  function newChat() {
    if (root.busy) abort()
    turnModel.clear()
    root.error = ""
    // Forget which file this conversation was, so neither an idle-kill respawn
    // nor a cold start reattaches to it. The row already in the index stays --
    // "start over" clears the screen, it does not delete history.
    root.resumePath = ""
    root.sessionFile = ""
    root.sessionId = ""
    if (root.warm) send({ type: "new_session" })
  }

  // ---------------------------------------------------------------- resume
  // The index file. Ours alone, so nothing watches it for changes: what is in
  // `sessions` after startup is what this file last wrote.
  FileView {
    id: indexFile
    path: root.sessionIndexPath
    preload: true
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try {
        var d = JSON.parse(text())
        root.sessions = (d && d.sessions) ? d.sessions : []
      } catch (e) {
        root.sessions = []
      }
      root.sessionsLoaded = true
      // Not restoreLastSession() directly: the broker may be mid-answer, and
      // only bootStep() knows -- see the boot block at the bottom.
      root.bootStep()
    }
    // No file yet is an empty history, not an error.
    onLoadFailed: {
      root.sessions = []
      root.sessionsLoaded = true
      root.bootStep()
    }
  }

  // Nothing is written back before the read has landed: a write from a turn
  // that settled first would replace the whole history with one row.
  property bool sessionsLoaded: false

  // Reads the newest session's transcript at startup. Deliberately NOT
  // `preload`: the path is unknown until the index above has loaded.
  FileView {
    id: restoreFile
    printErrors: false
    onLoaded: {
      root.rehydrateFromJsonl(text())
      // Release the buffer -- nothing watches this file, and holding a whole
      // transcript in memory for the rest of the session is the cost this
      // feature was supposed to avoid.
      Qt.callLater(function () { restoreFile.path = "" })
    }
    // Unreadable or deleted: the transcript is gone, but resumePath is already
    // armed, so asking still lands in the right conversation.
    onLoadFailed: Qt.callLater(function () { restoreFile.path = "" })
  }

  // Called once, when the index has loaded.
  function restoreLastSession() {
    if (!root.restoreOnStart) return
    if (root.sessions.length === 0) return
    // Reading the index is asynchronous, so a fast question can beat it. What
    // is already on screen wins.
    //
    // `warm` used to be a third condition here, back when it read
    // proc.running, because then it could only mean "ask() spawned a child
    // before the index landed". It cannot mean that any more: the agent
    // outlives the panel now, so a shell that has JUST started routinely finds
    // one already warm, and keeping the guard skipped the restore in exactly
    // the case it exists for -- measured, turns=0 against a live agent holding
    // the conversation. The two remaining conditions are about THIS panel, and
    // they are the ones that were ever meant.
    if (root.busy || turnModel.count > 0) return

    var s = root.sessions[0]
    if (!s || !s.file || s.file === "") return
    if (Date.now() - (s.at || 0) > root.restoreMaxAgeMs) return

    // Armed before the read, and left armed even if the read fails: pi's memory
    // of the conversation is the half that matters, and that comes from the
    // path, not from what is on screen.
    root.resumePath = s.file
    root.sessionFile = s.file
    root.sessionId = s.id
    restoreFile.path = s.file
  }

  // The session file is JSONL of the same entries `get_entries` returns, so its
  // tail can go straight into rehydrate() -- which already tolerates starting
  // mid-conversation, because an assistant entry with no user entry ahead of it
  // opens its own row.
  function rehydrateFromJsonl(body) {
    if (root.busy || turnModel.count > 0) return
    var lines = String(body || "").split("\n")
    var entries = []
    for (var i = Math.max(0, lines.length - root.restoreMaxEntries); i < lines.length; i++) {
      var s = lines[i]
      // A torn final line is normal: pi appends to this file, and it may have
      // been mid-write when the shell went down.
      if (s === "" || s.charAt(0) !== "{") continue
      try { entries.push(JSON.parse(s)) } catch (e) { }
    }
    if (entries.length > 0) rehydrate(entries)
  }

  // How a conversation is named in the list: its opening question. Nothing
  // asks pi for a title -- that would be a whole extra turn to name something
  // the first line already names.
  function sessionLabel() {
    for (var i = 0; i < turnModel.count; i++) {
      var r = turnModel.get(i)
      if (r.role !== "user") continue
      var t = String(r.text).replace(/\s+/g, " ").trim()
      return t.length > 90 ? t.substring(0, 90) + "…" : t
    }
    return ""
  }

  // Called from applyStats, i.e. once per settled turn. Upserts by id and
  // re-sorts newest first.
  // A write here can fail on a machine so fresh that $XDG_STATE_HOME/quickshell
  // does not exist yet -- FileView.setText does not create parent directories.
  // That fixes itself on the next settled turn, once whichever component makes
  // that directory has made it, so it is not worth a second mkdir of our own.
  function recordSession(count) {
    if (!root.sessionsLoaded) return
    if (root.sessionId === "" || root.sessionFile === "") return
    var label = root.sessionLabel()
    // A session with nothing asked in it is not worth offering.
    if (label === "") return

    var next = []
    for (var i = 0; i < root.sessions.length; i++)
      if (root.sessions[i].id !== root.sessionId) next.push(root.sessions[i])
    next.unshift({ id: root.sessionId, file: root.sessionFile,
                   label: label, at: Date.now(), count: count })
    if (next.length > root.maxSessions) next = next.slice(0, root.maxSessions)
    root.sessions = next
    indexFile.setText(JSON.stringify({ version: 1, sessions: next }))
  }

  // Accepts a full id or any unambiguous prefix of one, so a script can pass
  // the short form the listing prints.
  function sessionById(id) {
    var key = String(id || "")
    if (key === "") return null
    for (var i = 0; i < root.sessions.length; i++)
      if (root.sessions[i].id === key) return root.sessions[i]
    for (var j = 0; j < root.sessions.length; j++)
      if (root.sessions[j].id.indexOf(key) === 0) return root.sessions[j]
    return null
  }

  // Put a past conversation back: pi's context AND the transcript on screen,
  // in that order. Returns whether it started; the transcript arrives later,
  // when get_entries answers.
  function resume(id) {
    var s = root.sessionById(id)
    if (!s) { root.error = "no such session: " + id; return false }
    if (root.busy) abort()

    root.error = ""
    root.resumePath = s.file
    root.awaitingEntries = true
    if (root.warm) send({ type: "switch_session", sessionPath: s.file })
    else { root.sendConfig(); control({ type: "__spawn" }) }   // the spawn picks up resumePath
    return true
  }

  // Turn a session's entry list back into turn model rows. The mapping is not
  // one-to-one: pi records a tool loop as several assistant messages with
  // toolResults between them, whereas ingest() builds exactly ONE assistant row
  // per question. So consecutive assistant/toolResult entries are folded into
  // the row opened by the user entry before them, which is what makes a resumed
  // transcript look like the live one instead of a protocol dump.
  function rehydrate(entries) {
    turnModel.clear()
    var log = {}
    // The assistant row currently being filled, or -1 for "the next assistant
    // entry starts a new one". Tracked here rather than by searching the model
    // for the last assistant row: several turns in a row leave older assistant
    // rows in place, and a search finds the wrong one and welds three separate
    // answers into a single paragraph.
    var row = -1

    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (e.type !== "message" || !e.message) continue
      var m = e.message
      if (m.role === "user") {
        var ut = "", uimg = []
        var uc = m.content
        if (typeof uc === "string") ut = uc
        else for (var a = 0; a < (uc || []).length; a++) {
          if (uc[a].type === "text") ut += uc[a].text
          else if (uc[a].type === "image") uimg.push("(attached " + (uc[a].mimeType || "image") + ")")
        }
        appendTurn("user", ut, "", "", false, uimg.join("\n"))
        row = -1
        continue
      }
      if (m.role !== "assistant") continue   // toolResult: the call is enough

      // A new question, an assistant entry with no user entry ahead of it at
      // all (a compaction summary, a resumed fork), or an answer that simply
      // follows another answer: open a row, so the text is never dropped and
      // never merged into the previous one.
      //
      // "Follows another answer" is the case this got wrong. Consecutive
      // assistant entries were folded together unconditionally, on the grounds
      // that a tool loop records itself as several of them. True -- but so does
      // a session file two clients appended to, and so does any transcript
      // whose user entries did not survive. The result was one answer welded to
      // the front of the next: `HOLDThought a bit, checked the machine:`, which
      // is two questions, two answers, and one row.
      //
      // Only a tool loop may continue a row, and a tool loop is exactly an
      // assistant entry that ENDED asking for a tool. Anything else starts
      // fresh.
      if (row < 0) {
        appendTurn("assistant", "", "", "", true, "")
        row = turnModel.count - 1
      }
      var text = turnModel.get(row).text
      var think = turnModel.get(row).thinking
      var ac = m.content || []
      var calledTool = false
      for (var b = 0; b < ac.length; b++) {
        var blk = ac[b]
        if (blk.type === "text") text += blk.text
        else if (blk.type === "thinking") think += (blk.thinking || "")
        else if (blk.type === "toolCall") {
          var list = (log[row] || []).slice()
          // A session file records what a tool was asked to do and not when, so
          // t0/ms stay 0 and the batch says nothing about duration. It DOES
          // record where: the entries are in the order they happened and the
          // text blocks either side of this one are already folded into `text`,
          // so its current length is the same offset the live path stamps. That
          // is what makes a restored turn fold exactly like a live one, which
          // is the property this whole function exists to preserve.
          list.push({ name: String(blk.name || "tool"),
                      arg: summarizeArgs(blk.arguments),
                      raw: rawArgs(blk.arguments), t0: 0, ms: 0,
                      at: text.length })
          log[row] = list
          calledTool = true
        }
      }
      turnModel.setProperty(row, "text", text)
      turnModel.setProperty(row, "thinking", think)
      // Left open only while the model is still in a tool loop.
      if (!calledTool) row = -1
    }

    // Nothing is in flight in a transcript read off disk.
    for (var c = 0; c < turnModel.count; c++) {
      turnModel.setProperty(c, "pending", false)
      turnModel.setProperty(c, "tool", "")
    }
    root.toolLog = log
    root.busy = false
    root.settledAtMs = 0
    root.turnStartedAt = 0
    // `appended` (pin the view to the bottom) but deliberately NOT `settled`:
    // the bar treats that signal as "an answer just arrived" and speaks the
    // first line of it. A conversation you asked to reopen has not arrived.
    root.appended()
  }

  // --------------------------------------------------------------- commands
  // The `/command` list the composer completes against. 17 on this machine, of
  // which 16 are skills and one is an extension. Shape, read off a hand-driven
  // rpc child rather than guessed:
  //
  //   {"command":"get_commands","success":true,"data":{"commands":[
  //     {"name":"llama","description":"Manage llama.cpp router models",
  //      "source":"extension","sourceInfo":{...}},
  //     {"name":"skill:caveman","description":"...","source":"skill",
  //      "sourceInfo":{"path":"...","baseDir":"..."}}, ...]}}
  //
  // `source` is "extension" | "prompt" | "skill" -- the server concatenates the
  // registered extension commands, the session's prompt templates, and the
  // loaded skills. The name is used verbatim after the slash, colon included:
  // `/skill:caveman`. (No "prompt" rows here; this machine has no prompt
  // templates.)
  property var commands: []
  readonly property string commandIndexPath: stateDir + "/ori-commands.json"

  // Cached to disk for the same reason `sessions` is: the list only exists on a
  // RUNNING child, and no child exists until the first question spawns one. An
  // uncached list is therefore empty for exactly the window in which someone
  // first types `/`, which is the window the completion popup is for.
  //
  // One correction to the reasoning this was asked for on, since it changes
  // what the cache is worth: the idle kill does NOT take the list away again.
  // `commands` lives on this singleton, not on the child, so once a spawn has
  // filled it, it stays filled for the rest of the shell's life. The gap the
  // cache closes is shell-start to first spawn, and only that one.
  //
  // Staleness is cheap and self-correcting. The list changes when a skill file
  // is added or removed -- i.e. rarely -- and every cold spawn overwrites it
  // from the live answer. A stale row costs one completion offering a command
  // pi no longer has.
  //
  // Asking for it costs nothing the question can feel. Measured, spawn to
  // first text_delta: 2.57s with the prompt sent alone, 2.62s with
  // get_session_stats and get_commands queued ahead of it. Both are local
  // lookups on a child that is booting anyway.
  FileView {
    id: commandsFile
    path: root.commandIndexPath
    preload: true
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try {
        var d = JSON.parse(text())
        root.commands = (d && d.commands) ? d.commands : []
      } catch (e) {
        root.commands = []
      }
    }
    // No file yet is an empty list, not an error: the next cold spawn writes one.
    onLoadFailed: root.commands = []
  }

  // From ingest(), on the get_commands response -- once per cold spawn. Written
  // every time rather than diffed first: one small file per spawn is well under
  // what the session index already writes per settled turn.
  function applyCommands(d) {
    var list = ((d.data || {}).commands) || []
    // A child that answered with nothing is not a reason to throw away a cache
    // that works.
    if (list.length === 0) return
    root.commands = list
    commandsFile.setText(JSON.stringify({ version: 1, commands: list }))
  }


  // --------------------------------------------------- panel commands
  // `/model` and `/effort`, which the completion list offers alongside the
  // engine's own commands and which never reach the model as text.
  //
  // They have to be OURS. Everything get_commands returns is a slash command pi
  // itself expands; these two are not commands at all over rpc, they are
  // separate message types, so a `prompt` whose text is "/model glm-5.2" is sent
  // to the model as that literal string and answered as a question about itself.
  // ask() therefore hands every draft to runPanelCommand() first, and a draft it
  // claims is never queued.
  //
  //   -> {"type":"set_model","provider":"ollama","modelId":"glm-5.2"}
  //   <- {"id":8,"type":"response","command":"set_model","success":true,
  //       "data":{ ...the whole Model: id, name, provider, baseUrl, reasoning,
  //                contextWindow, maxTokens, cost... }}
  //   <- {"id":7,"type":"response","command":"set_model","success":false,
  //       "error":"Model not found: ollama/nope-9000"}
  //
  //   -> {"type":"set_thinking_level","level":"low"}
  //   <- {"id":1,"type":"response","command":"set_thinking_level","success":true}
  //
  // --------------------------------------------- why the ack cannot be trusted
  // set_thinking_level answers success:true for EVERY string. It does not
  // validate; it clamps, silently, and the ack is identical in all three cases.
  // Measured against a real child on deepseek-v4-flash:0731, get_state read back
  // after each:
  //
  //   "low"     -> low        (supported)
  //   "max"     -> high       (clamped to the model's ceiling)
  //   "banana"  -> off        (clamped to nothing at all)
  //
  // So the ack is dropped and the level is read from elsewhere. Two sources,
  // both push, neither a poll:
  //
  //   thinking_level_changed   an EVENT, emitted on every real change --
  //                            ours, and the one set_model makes on its own.
  //                            It is not in rpc-types.d.ts; it is in the
  //                            stream. {"type":"thinking_level_changed",
  //                            "level":"high"}. It does NOT fire when the level
  //                            did not move, which is exactly the clamp-to-
  //                            current case, so it cannot be the only source.
  //   get_state                asked for at spawn and after either setter. The
  //                            authoritative reading, and the one that makes a
  //                            silent clamp visible in the footer.
  //
  // ------------------------------------------------- what the levels actually are
  // Not the seven in the ThinkingLevel type ("off" through "max").
  // get_available_thinking_levels asks the CURRENT MODEL what it supports, and
  // two models on the same provider disagree:
  //
  //   ollama/deepseek-v4-flash:0731  off minimal low medium high
  //   ollama/glm-5.2                 off minimal low medium high xhigh
  //
  // which is why the list is queried per spawn and re-queried after every
  // set_model, rather than hardcoded from the type. Offering "xhigh" on deepseek
  // would be offering a value that clamps to "high" without saying so, and
  // hardcoding deepseek's five would hide a level glm-5.2 really has.
  //
  // ------------------------------------------------------- where models come from
  // get_available_models, not ~/.pi/agent/models.json. models.json holds only
  // the providers defined by hand on this machine (flm, ncym, ollama,
  // llama-local); the live answer is ~120 models across eight providers, because
  // pi composes its built-in catalogues on top. More to the point, that list is
  // already filtered to providers with configured auth --
  // `available = all.filter(m => configuredProviders.has(m.provider))` -- so
  // every row in it is a model set_model will actually accept. A list read off
  // models.json would offer four providers and hide the other four.
  //
  // "~120" and not a number, deliberately: the filter runs off a live auth check
  // per provider, and two spawns twenty minutes apart answered 122 and then 116.
  // Nothing here treats the count as stable, and the cache is overwritten from
  // whatever the newest spawn saw.
  //
  // ------------------------------------------------------------- and persistence
  // A set_model on a live child dies with that child, and the child is killed
  // after idleKillMs of silence. So the RPC is the SECOND half of every command;
  // the first is writing the choice onto this singleton, where buildCommand()
  // reads it. The next cold spawn is then born on the chosen model.
  //
  // That works because the CLI flags beat the session file, which is not obvious
  // and was proved rather than assumed. createAgentSession() restores the model
  // and level recorded in a resumed transcript only `if (!model)` and
  // `if (thinkingLevel === undefined)` -- i.e. only when no flag was given.
  // Driven against a hand-built session carrying model_change anthropic/
  // claude-haiku-4-5 and thinking_level_change minimal:
  //
  //   --session X --provider ollama --model deepseek-v4-flash:0731 --thinking low
  //        -> ollama/deepseek-v4-flash:0731, low
  //   --session X  (no model flags)
  //        -> anthropic/claude-haiku-4-5, minimal
  //
  // The flags win, every time. Resuming a conversation therefore cannot drag the
  // model back to whatever it was answered on before.
  //
  // One trap, recorded because it is silent: `--provider P --model ID` where ID
  // is not in P's catalogue does NOT fail. pi warns on stderr -- which is not
  // read here -- and starts anyway on a fabricated "custom model id" pointed at
  // P's baseUrl. So a stale persisted id gives a panel that looks fine and fails
  // at the first question. Nothing is ever written here that did not come out of
  // get_available_models, which is the only defence available.
  property var availableModels: []
  property var thinkingLevels: []

  // ------------------------------------------------- which of those are usable
  // get_available_models is filtered by pi to providers with CONFIGURED AUTH,
  // and that phrase does not mean what it sounds like. It means a credential
  // exists somewhere. It does not mean the credential works. Every one of the
  // five providers it returns was sent a real one-word question, and the answers
  // are not what the list implies:
  //
  //   ollama         7 models   answered "OK"     inline apiKey in models.json
  //   huggingface   67 models   answered "OK"     HF_TOKEN in the login env
  //   anthropic     13 models   EMPTY + error     OAuth, refresh token expired
  //   google        22 models   EMPTY + error     GEMINI_API_KEY is set, and is
  //                                               rejected as API_KEY_INVALID
  //   openai-codex   7 models   EMPTY + error     OAuth, expired 104 days ago
  //
  // All four OAuth records in ~/.pi/agent/auth.json are expired -- anthropic by
  // 45 days, openai-codex by 104, the two google ones by ~180 -- and refreshing
  // does not rescue them:
  //
  //   "stopReason":"error","errorMessage":"OAuth refresh failed for anthropic:
  //    ... body={\"error\":\"invalid_grant\",
  //    \"error_description\":\"Refresh token expired\"}"
  //
  // So 42 of 116 rows are proven dead, and picking one is one keypress from a
  // panel that answers nothing.
  //
  // ---------------------------------------------- why not a credential check
  // Because it does not work, and google is the counter-example. The obvious
  // rule is "usable if it has a key" -- read the inline apiKey, read pi's own
  // provider-to-env-var map (pi-ai's env-api-keys.js: google -> GEMINI_API_KEY,
  // huggingface -> HF_TOKEN), check the OAuth expiry. Do all three and google
  // PASSES, because GEMINI_API_KEY really is set and pi really does use it. What
  // came back was:
  //
  //   "code":400, "message":"API key not valid. Please pass a valid API key.",
  //   "status":"INVALID_ARGUMENT", "reason":"API_KEY_INVALID"
  //
  // A key being PRESENT is not a key being GOOD, and nothing short of spending a
  // request tells them apart. Probing baseUrls answers the wrong question for
  // the same reason: four of the five are remote APIs, and a reachable
  // api.anthropic.com says nothing about the dead credential behind it.
  //
  // What is left is curation -- and pi already has the user's, in two places.
  //
  // ------------------------------------------------------- settings.json first
  // `enabledModels` in ~/.pi/agent/settings.json is the list the user prunes by
  // hand; it currently holds seven `ollama/...` entries. pi feeds it straight
  // into the scoped-model set:
  //
  //   main.js:634   const modelPatterns =
  //                   parsed.models ?? settingsManager.getEnabledModels()
  //
  // i.e. it is exactly `--models`, the set Ctrl+P cycles. So it is not an
  // incidental config key, it is the answer to "which models do I want offered".
  //
  // Worth being explicit, because it is easy to assume otherwise: pruning it
  // changes NOTHING about what this panel is handed. get_available_models
  // reports 116 across five providers with `enabledModels` at seven, measured
  // after the prune. The two lists are unrelated inside pi -- one is the auth
  // snapshot, the other is the cycling scope -- and intersecting them is work pi
  // does not do for us and the RPC will not do either. There is no command that
  // returns the scoped set, so the file is read here.
  //
  // Entries are PATTERNS. pi resolves them with globs and `:thinking` suffixes;
  // this matches an exact `provider/id` and a trailing `*`, which covers what
  // the file holds and degrades to "no match" rather than to a wrong match.
  //
  // ------------------------------------------------------- models.json second
  // Only when `enabledModels` is absent. Then a provider is offered if
  // models.json declares it -- the file where this laptop's endpoints and
  // inline keys are written by hand -- or if it is the one Ori is running on,
  // which is usable by demonstration.
  //
  // Both routes give the same seven today. They differ in what they would do
  // next: enabling `huggingface/...` in settings.json brings its 67 working
  // models back with no change here, which is the escape hatch this needs, and
  // it lives in the file the user is already editing rather than in this one.
  //
  // The one honest hole: models.json may declare a LOCAL endpoint -- it held flm
  // on 127.0.0.1:52625 and llama-local on :8080 earlier today, both since
  // removed by hand. A local provider nothing is listening on would be declared,
  // offered, and would move Ori onto a dead port. Nothing checks that, because
  // checking means a TCP probe and there is no such provider here to justify
  // one. If they come back, this is the place.
  property var enabledModels: []
  property var declaredProviders: []

  // pi's own config, read directly. That IS coupling to another program's file
  // format, and it is worth being uneasy about -- but the protocol cannot answer
  // this question, and these are two stable top-level keys. If either shape ever
  // changes the filter finds nothing and usableModels falls back to the
  // unfiltered list rather than to an empty one.
  //
  // Both are watched rather than read once. They are edited by hand -- one lost
  // three providers and the other ten models during the session this was written
  // in -- and a completion list that is only right after a shell reload is one
  // that is quietly wrong in between.
  FileView {
    id: piSettingsFile
    path: Quickshell.env("HOME") + "/.pi/agent/settings.json"
    preload: true
    printErrors: false
    watchChanges: true
    onFileChanged: piSettingsFile.reload()
    onLoaded: {
      try {
        var d = JSON.parse(text()) || {}
        root.enabledModels = d.enabledModels || []
      } catch (e) {
        root.enabledModels = []
      }
    }
    onLoadFailed: root.enabledModels = []
  }

  // What every running delegate is doing, read off the subagent extension's own
  // registry.
  //
  // The extension is a different process, and the tray row for an agent is
  // written once when the call returns -- there is no event that says "this
  // delegate is now doing X", and adding one would mean a message appended to
  // the session for every tool call every delegate makes. The registry already
  // exists on disk, already carries the line, and is already rewritten on each
  // of those calls. So the panel watches the file instead: no protocol change,
  // no session noise, and still not a poll.
  FileView {
    id: subagentRegistry
    path: Quickshell.env("HOME") + "/.pi/agent/subagents/registry.json"
    preload: true
    printErrors: false
    watchChanges: true
    onFileChanged: subagentRegistry.reload()
    onLoaded: {
      try {
        var d = JSON.parse(text()) || {}
        var out = {}
        for (var k in d) {
          // Only a live one. A record keeps its handle for a day after it
          // finishes so it can be resumed, and none of those belong on a strip
          // that says what is running.
          if (d[k] && d[k].status === "running" && d[k].activity)
            out[k] = String(d[k].activity)
        }
        root.agentActivity = out
      } catch (e) {
        root.agentActivity = ({})
      }
    }
    // No file yet is the normal state -- nothing has been delegated. It is not
    // an error, and it is not distinguishable from an empty one.
    onLoadFailed: root.agentActivity = ({})
  }

  FileView {
    id: piModelsFile
    path: Quickshell.env("HOME") + "/.pi/agent/models.json"
    preload: true
    printErrors: false
    watchChanges: true
    onFileChanged: piModelsFile.reload()
    onLoaded: {
      try {
        var d = JSON.parse(text()) || {}
        var ps = []
        for (var k in (d.providers || {})) ps.push(k)
        root.declaredProviders = ps
      } catch (e) {
        root.declaredProviders = []
      }
    }
    onLoadFailed: root.declaredProviders = []
  }

  function modelEnabled(key) {
    for (var i = 0; i < root.enabledModels.length; i++) {
      var pat = String(root.enabledModels[i])
      if (pat === key) return true
      if (pat.charAt(pat.length - 1) === "*"
          && key.indexOf(pat.slice(0, -1)) === 0) return true
    }
    return false
  }

  // What `/model` OFFERS. Note it is not what `/model` ACCEPTS -- chooseModel()
  // validates against the full list, so naming a hidden model in full still
  // works. That asymmetry is deliberate: completion must not hand anyone a dead
  // provider, and typing `anthropic/claude-haiku-4-5` out by hand is not
  // something done by accident.
  readonly property var usableModels: {
    var out = []
    var scoped = root.enabledModels.length > 0
    for (var i = 0; i < root.availableModels.length; i++) {
      var m = root.availableModels[i]
      var key = m.provider + "/" + m.id
      // The model Ori is ON is always offered, however it got there. A picker
      // that cannot show the current selection is a picker with a hole in it.
      var keep = (m.provider === root.provider && m.id === root.model)
        || (scoped ? root.modelEnabled(key)
                   : root.declaredProviders.indexOf(m.provider) >= 0)
      if (keep) out.push(m)
    }
    // A filter that matched nothing is a broken filter, not an empty machine --
    // if either file moves or changes shape, offering everything is a far better
    // failure than offering a command with no values at all.
    return out.length > 0 ? out : root.availableModels
  }

  // Which model `thinkingLevels` was asked about, "provider/id". A level list
  // outlives the model it describes otherwise, and the cache below is read back
  // on a later day.
  property string levelsFor: ""
  // The EFFECTIVE level, as last reported by the child; "" until one has run.
  // Display only -- it is deliberately not what buildCommand passes.
  property string thinkingLevel: ""
  // The level the USER pinned with /effort, "" for "let pi choose". Only this
  // reaches the command line and the file below. The distinction matters: seeding
  // --thinking from whatever get_state happened to report would freeze pi's own
  // default the first time the panel was opened, and quietly override it forever
  // after.
  property string effort: ""
  // What the footer shows for the level, and "" for "show nothing at all".
  //
  // Gated on a PIN rather than on knowing a level, and the gate is a layout
  // decision as much as an honesty one. That strip is 460px carrying a plan
  // readout and a context readout already; a level beside the model costs the
  // model about 60px, which is enough to elide `deepseek-v4-flash:0731` down to
  // `deepseek-v4-...`. Paying that for a level nobody chose -- get_state reports
  // one on every spawn -- would make every panel worse for a command most
  // sessions never use. Paying it after someone types `/effort` is a trade they
  // just asked for.
  //
  // What it then shows is the EFFECTIVE level and not the pinned one, because
  // those differ exactly when set_thinking_level clamped silently, and that is
  // the case worth being able to see.
  readonly property string effortLabel: root.effort === "" ? ""
      : (root.thinkingLevel !== "" ? root.thinkingLevel : root.effort)

  // One file for both jobs: the choice, and the two lists it is validated
  // against. They are kept together because they are read at the same moment --
  // someone types `/` before any child has ever run -- and because the choice is
  // only meaningful next to the list it came from. Same argument the command
  // cache makes, and the same self-correcting staleness: every cold spawn
  // overwrites the lists from the live answer.
  readonly property string modelStatePath: stateDir + "/ori-model.json"

  FileView {
    id: modelFile
    path: root.modelStatePath
    preload: true
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try {
        var d = JSON.parse(text()) || {}
        // Only a COMPLETE pair is restored. Half of it -- a provider with no id
        // -- would build `--provider anthropic --model deepseek-...`, which is
        // the fabricated-custom-model trap above rather than an error.
        if (d.provider && d.modelId) { root.provider = String(d.provider); root.model = String(d.modelId) }
        root.effort = String(d.effort || "")
        root.availableModels = d.models || []
        root.thinkingLevels = d.levels || []
        root.levelsFor = String(d.levelsFor || "")
      } catch (e) {
        // A corrupt file is not a reason to refuse to start: the settings block
        // above is a working default and the next spawn rewrites this.
      }
    }
    onLoadFailed: { /* no file yet; the first spawn writes one */ }
  }

  function saveModelState() {
    modelFile.setText(JSON.stringify({
      version: 1,
      provider: root.provider, modelId: root.model, effort: root.effort,
      levelsFor: root.levelsFor, levels: root.thinkingLevels,
      models: root.availableModels
    }))
  }

  // Trimmed to the three fields anything here reads. The live answer is 45KB of
  // baseUrls, per-token costs and window sizes; this is ~10KB, and it is parsed
  // on the UI thread at shell start.
  function applyModels(d) {
    var list = ((d.data || {}).models) || []
    if (list.length === 0) return
    var out = []
    for (var i = 0; i < list.length; i++)
      out.push({ provider: String(list[i].provider), id: String(list[i].id),
                 name: String(list[i].name || list[i].id) })
    root.availableModels = out
    root.saveModelState()
  }

  // Levels the ENDPOINT has told us it does not accept, learned the only way
  // there is: by being refused. pi's own list is universal --
  // off/minimal/low/medium/high/xhigh/max, straight out of the bundle -- and it
  // describes what pi can ask for, not what a given provider will take.
  //
  // Ollama Cloud answered `/effort minimal` with, verbatim:
  //
  //   400 invalid reasoning value: 'minimal'
  //   (must be "high", "medium", "low", "max", or "none")
  //
  // so two of pi's seven are dead here. Seeded from that measurement rather
  // than left empty, because the first person to find each one out pays a
  // failed turn for it, and one of them has already been paid.
  property var rejectedLevels: ["minimal", "xhigh"]

  function applyLevels(d) {
    var list = ((d.data || {}).levels) || []
    if (list.length === 0) return
    var keep = []
    for (var i = 0; i < list.length; i++)
      if (root.rejectedLevels.indexOf(String(list[i])) < 0) keep.push(list[i])
    root.thinkingLevels = keep
    root.levelsFor = root.provider + "/" + root.model
    root.saveModelState()
  }

  // A pinned level that the endpoint refuses is worse than no level at all: it
  // is written into buildCommand() as `--thinking <level>`, so it poisons every
  // future child and every turn 400s until someone notices. Unpin it, remember
  // it, and say so.
  function rejectLevel(level, why) {
    var bad = String(level || "")
    if (bad !== "" && root.rejectedLevels.indexOf(bad) < 0) {
      var next = root.rejectedLevels.slice()
      next.push(bad)
      root.rejectedLevels = next
    }
    var keep = []
    for (var i = 0; i < root.thinkingLevels.length; i++)
      if (root.thinkingLevels[i] !== bad) keep.push(root.thinkingLevels[i])
    root.thinkingLevels = keep
    if (root.effort === bad) root.effort = ""
    root.error = "'" + bad + "' is not a thinking level this endpoint accepts"
    root.saveModelState()
  }

  // get_state, which is asked for at spawn and after either setter. This is the
  // one reading that cannot be wrong -- see the clamping note above.
  function applyState(d) {
    var s = d.data || {}
    if (s.model && s.model.id) {
      root.provider = String(s.model.provider)
      root.model = String(s.model.id)
    }
    root.thinkingLevel = String(s.thinkingLevel || "")
    root.saveModelState()
  }

  // The rows the completion list merges in beside get_commands'. Same shape it
  // already renders -- { name, description } -- with a `source` of "panel" so a
  // reader of either file can tell where a row came from.
  readonly property var panelCommands: [
    { name: "model", source: "panel",
      description: "switch model  ·  " + root.usableModels.length + " usable" },
    { name: "effort", source: "panel",
      description: "thinking level  ·  " + (root.thinkingLevels.join(" ") || "unknown until Ori has run once") }
  ]

  // The values each takes, for the completion list's second stage. This is the
  // case CommandBar's own comment said did not exist -- an argument with a
  // closed, knowable set -- and both of these have one.
  function commandValues(name) {
    var out = []
    if (name === "effort") {
      for (var i = 0; i < root.thinkingLevels.length; i++)
        out.push({ name: String(root.thinkingLevels[i]), description: "" })
      return out
    }
    if (name === "model") {
      for (var j = 0; j < root.usableModels.length; j++) {
        var m = root.usableModels[j]
        out.push({ name: m.provider + "/" + m.id, description: String(m.name) })
      }
      return out
    }
    return out
  }

  // Called by ask() before anything else. Returns true when the draft was a
  // panel command -- INCLUDING when it was a bad one, because a rejected
  // `/model nope` must land on the error strip and not in the conversation.
  function runPanelCommand(text) {
    var m = /^\/(model|effort)(?:\s+([\s\S]*))?$/.exec(String(text || "").trim())
    if (!m) return false
    var arg = String(m[2] || "").trim()
    if (m[1] === "effort") root.setEffort(arg)
    else root.chooseModel(arg)
    return true
  }

  function setEffort(level) {
    // Nothing has ever run, so there is no list to check against and pi would
    // clamp an unknown level to "off" without a word. Say so instead.
    if (root.thinkingLevels.length === 0) {
      root.error = "/effort: no level list yet -- ask Ori something once first"
      return
    }
    if (level === "" || root.thinkingLevels.indexOf(level) < 0) {
      root.error = "/effort " + root.thinkingLevels.join(" | ")
      return
    }
    root.error = ""
    root.effort = level
    // Shown immediately, so a cold panel is not silent for the ten minutes
    // before the next question spawns a child that can confirm it. get_state
    // corrects this at that spawn if pi disagrees.
    root.thinkingLevel = level
    root.saveModelState()
    if (root.warm) send({ type: "set_thinking_level", level: level })
  }

  // Accepts "provider/id" -- what the completion writes and what set_model
  // needs -- and a bare id, because a bare id is what the footer shows, and
  // making someone retype a prefix the panel never showed them is a trap.
  function chooseModel(spec) {
    if (root.availableModels.length === 0) {
      root.error = "/model: no model list yet -- ask Ori something once first"
      return
    }
    if (spec === "") { root.error = "/model <provider>/<id>"; return }

    var hit = null, bare = []
    for (var i = 0; i < root.availableModels.length; i++) {
      var m = root.availableModels[i]
      if (m.provider + "/" + m.id === spec) { hit = m; break }
      if (m.id === spec) bare.push(m)
    }
    if (!hit && bare.length === 1) hit = bare[0]
    if (!hit) {
      root.error = bare.length > 1
        ? "/model: \"" + spec + "\" is on " + bare.length + " providers -- name one"
        : "/model: no such model \"" + spec + "\""
      return
    }

    root.error = ""
    // On a WARM child nothing is written here. The state moves when pi says it
    // moved, in the set_model response.
    //
    // Writing it now and rolling back on failure was the first shape and it is
    // worse in two ways. The obvious one: between the write and the rejection
    // the footer names a model the child is not on. The less obvious one: that
    // window is not short. set_model awaits checkAuth() before it validates
    // anything, which on an OAuth provider is a network round trip -- and the
    // response ordering measurement above came out of exactly this call
    // overtaking nothing while a get_state queued behind it answered first.
    if (root.warm) {
      send({ type: "set_model", provider: hit.provider, modelId: hit.id })
      return
    }
    // Cold: there is no child to disagree, so the choice is the truth. It
    // reaches pi as the next spawn's --provider/--model.
    root.applyModelChoice(hit.provider, hit.id)
  }

  // The state half of a model switch, shared by the cold path above and the
  // set_model response.
  //
  // The level and its list both belonged to the model being left. pi drops the
  // level too on a switch -- setModel() re-derives it from the per-model
  // override, then the global default -- and was watched doing it: deepseek at
  // "off" became claude-haiku-4-5 at "high", unasked. Keeping a stale pin here
  // would fight that for no reason and show a level the child does not have.
  function applyModelChoice(provider, id) {
    root.provider = String(provider)
    root.model = String(id)
    root.effort = ""
    root.thinkingLevel = ""
    root.thinkingLevels = []
    root.levelsFor = ""
    root.saveModelState()
  }

  // --------------------------------------------------------------- protocol
  property string pending: ""
  property var pendingImages: []
  property int nextId: 1

  // The id of the `prompt` frame we are still waiting on a response for, and
  // whatever an extension said while it was in flight. Both exist only for the
  // inline-command case in ingest() below; flush() resets them per question.
  property int promptId: 0
  property string extensionNotice: ""

  function send(obj) {
    obj.id = root.nextId++
    // The protocol is line-delimited, so the trailing newline is the frame
    // terminator, not cosmetic.
    //
    // Dropped rather than queued when there is nothing to write to. Every
    // caller of this is either a probe the next spawn will re-issue or a
    // setter whose state is already persisted, so a lost frame corrects
    // itself; ask() is the one exception and it refuses up front instead.
    if (sock.connected) sock.write(JSON.stringify(obj) + "\n")
    // Handed back so flush() can remember which response belongs to the
    // question, rather than treating every `prompt` response as the current
    // one.
    return obj.id
  }

  function flush() {
    if (root.pending === "") return
    // Leaving here IS the send, so this is where the first tick is earned.
    markSent(1)
    var msg = { type: "prompt", message: root.pending }
    // Omitted entirely when there are none: an empty array is a different
    // message from no field, and there is no reason to send one.
    if (root.pendingImages.length > 0) {
      var imgs = []
      for (var i = 0; i < root.pendingImages.length; i++) {
        var b = root.pendingImages[i]
        // `source` is ours, for the transcript. pi is sent the block only.
        imgs.push({ type: "image", mimeType: b.mimeType, data: b.data })
      }
      msg.images = imgs
    }
    // Cleared before the question rather than after the last one, so a notice
    // left over from a previous turn can never settle this one early.
    root.extensionNotice = ""
    root.promptId = send(msg)
    root.pending = ""
    root.pendingImages = []
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
    // ---------------------------------------------------- the broker's own
    // Four frames that are not pi's. They are prefixed so that a reader of
    // either end can tell at a glance which frames crossed a process boundary
    // that pi knows nothing about, and so that a future pi event can never
    // collide with one.
    case "__welcome":
      root.onWelcome(d)
      break
    case "__pi_started":
      root.onPiStarted()
      break
    case "__pi_exited":
      root.onPiExited(Number(d.code))
      break
    case "__prompt": {
      // The first line of a replayed turn: the question that opened it.
      // Normally redundant, because reattach() has already put that question
      // on screen out of get_entries -- see the note there on pi appending the
      // user message to the session early. Kept only as the fallback for the
      // case where it is the sole copy: a get_entries that failed, or an agent
      // with no session file at all.
      //
      // The guard has to be "is a turn already open", not "is the last row a
      // user row". Getting that wrong is not subtle and it is not theoretical:
      // by the time the replay lands, openReplayTurn() has appended the
      // ASSISTANT row, so a role check on the last row sees "assistant", adds
      // the pair again, and the reload turns one exchange into two. Measured,
      // turns=4 for a single question.
      var last = turnModel.count > 0 ? turnModel.get(turnModel.count - 1) : null
      if (last && (last.pending || last.role === "user")) break
      appendTurn("user", String(d.message || ""), "", "", false,
                 Number(d.images) > 0 ? "(" + d.images + " attached)" : "")
      appendTurn("assistant", "", "", "", true, "")
      root.busy = true
      root.appended()
      break
    }

    // Not in rpc-types.d.ts, but emitted by the real binary on every level that
    // actually moves -- including the one set_model changes on its own, which is
    // the only warning the footer gets that a model switch took the level with
    // it. It stays silent when the level did not move, so it is a supplement to
    // get_state and not a replacement for it.
    case "thinking_level_changed":
      root.thinkingLevel = String(d.level || "")
      root.saveModelState()
      break
    case "response":
      // The stats probe is bookkeeping, not conversation: read it when it
      // worked and drop it when it did not. It must never abort a turn or
      // paint the transcript red -- that path belongs to the prompt.
      if (d.command === "get_session_stats") {
        if (d.success !== false) root.applyStats(d)
        break
      }
      // Bookkeeping too, and dropped just as quietly when it fails: a child
      // that cannot list its commands is not a reason to break a question.
      if (d.command === "get_commands") {
        if (d.success !== false) root.applyCommands(d)
        break
      }
      // The three readings /model and /effort are built on. Bookkeeping like
      // the two above, and dropped as quietly when they fail.
      if (d.command === "get_available_models") {
        if (d.success !== false) root.applyModels(d)
        break
      }
      if (d.command === "get_available_thinking_levels") {
        if (d.success !== false) root.applyLevels(d)
        break
      }
      if (d.command === "get_state") {
        if (d.success !== false) root.applyState(d)
        break
      }
      // A real failure, unlike the setter below: pi checked the id against its
      // own catalogue and did not find it. It belongs on the error strip.
      if (d.command === "set_model") {
        if (d.success === false) { root.error = String(d.error || "set_model failed"); break }
        var picked = d.data || {}
        if (picked.id) root.applyModelChoice(picked.provider, picked.id)
        // Both stale the instant the model changed: the level list is per model,
        // and set_model re-derives the level itself without telling anyone.
        // Chained off the RESPONSE rather than sent alongside the setter,
        // because responses do not arrive in order -- set_model awaits an auth
        // check, and a get_state queued behind it was observed answering first,
        // with the OLD model in it.
        send({ type: "get_available_thinking_levels" })
        send({ type: "get_state" })
        break
      }
      // Deliberately not read. It says success:true for every string it was
      // ever given, clamped ones included -- see the measurement in the panel
      // commands block. get_state is the only honest answer to "what is it now".
      if (d.command === "set_thinking_level") {
        send({ type: "get_state" })
        break
      }
      // The transcript is asked for only after the switch is ACKED -- entries
      // read any earlier are the session being switched away from.
      if (d.command === "switch_session") {
        if (d.success !== false && root.awaitingEntries) send({ type: "get_entries" })
        else if (d.success === false) { root.awaitingEntries = false; root.error = String(d.error || "switch failed") }
        break
      }
      if (d.command === "get_entries") {
        root.awaitingEntries = false
        if (d.success !== false) {
          root.rehydrate(((d.data || {}).entries) || [])
          // The usage readouts describe a context that has just been replaced
          // wholesale, so re-read them. Driven by the resume, not by a clock.
          send({ type: "get_session_stats" })
          // Reattaching, not resuming: the last entry is the question being
          // answered right now, so open the row its answer belongs in and let
          // the broker deliver what it has. Strictly after rehydrate, which
          // clears the model -- an assistant row opened before it would be the
          // first casualty.
          if (root.replayPending) root.openReplayTurn()
        } else {
          root.error = String(d.error || "get_entries failed")
          root.replayPending = false
        }
        break
      }
      // A question an extension command answered inline, which the agent loop
      // therefore never ran for. pi's session does
      //
      //   if (text.startsWith("/") && await this._tryExecuteExtensionCommand(text))
      //     { preflightResult(true); return }
      //
      // so the handler runs, the loop does not, and the response still says
      // success. Measured against the real binary: `/llama` emits exactly two
      // frames and then silence, for good.
      //
      //   4.08 <- {"type":"extension_ui_request",...,"method":"notify",
      //            "message":"/llama is available in interactive mode"}
      //   4.11 <- {"id":2,"type":"response","command":"prompt","success":true}
      //
      // ask() has already set `busy` and stopped the idle timer by then, and
      // only agent_settled undoes either -- so the composer refused every
      // later message and the child was never killed. A shell reload was the
      // only way out.
      //
      // The obvious rule, "a successful prompt response with no agent_start
      // yet means no loop is coming", is WRONG, and that is the crux here. In
      // a healthy turn the response LEADS agent_start; measured at 20ms on two
      // separate runs, 6.08 -> 6.10 and 24.14 -> 24.16. That rule would settle
      // every good question 20ms after it was asked.
      //
      // What separates the two is that the extension_ui_request arrives BEFORE
      // the response instead of after it. Nothing else can: an extension whose
      // command runs in this mode has no other way to say anything, because
      // the UI it is asking for is not here. Matching on the id as well keeps
      // it to the question actually in flight.
      if (d.command === "prompt" && d.success !== false
          && d.id === root.promptId && root.extensionNotice !== "") {
        root.promptId = 0
        root.extensionNotice = ""
        root.busy = false
        settleTurn()
        break
      }
      // Only a FAILED response matters: success is just an ack that the prompt
      // was accepted, and the real work arrives as the events below.
      if (d.success === false) {
        var msg = String(d.error || "rejected")
        root.busy = false
        // A prompt rejected with "already processing" right after a ctrl+c is
        // the wedged turn still holding pi: the watchdog's timer has not run
        // out yet, but the outcome is already known. Escalate now rather than
        // leaving the user to read a guard message for a turn they killed.
        if (root.aborting && msg.indexOf("already processing") !== -1) {
          root.aborting = false
          abortWatchdog.stop()
          console.log("prompt rejected while aborting -- killing the wedged turn")
          control({ type: "__kill" })
          root.error = "the aborted turn was wedged on a tool call and has been killed; send that again"
          break
        }
        settleTurn()
        // A pinned thinking level the endpoint refuses would otherwise fail
        // EVERY turn from here on, because it is baked into buildCommand(). The
        // upstream names the offender in the message, so take it at its word,
        // unpin it and drop it from the list -- one failed turn instead of all
        // of them.
        var bad = msg.match(/invalid reasoning value:\s*'([^']+)'/)
        if (bad) { root.rejectLevel(bad[1], msg); break }
        root.error = msg
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
      // A turn that reaches for a tool before saying a word is still the agent
      // acting on the question, so this counts as picking it up too.
      root.markRead()
      // Written BEFORE the row, because writing the row is what fires
      // onActiveToolChanged, and that is where the call is pushed onto the log.
      root.activeToolRaw = rawArgs(d.args)
      setTurn("tool", String(d.toolName || "tool") + " " + summarizeArgs(d.args))
      break

    case "tool_execution_end": {
      // A tool that RETURNED is not necessarily a job that FINISHED. The bash
      // tool auto-backgrounds anything still alive at its timeout: it resolves
      // immediately with a PID and a log file, so from the protocol's point of
      // view the call is over while the command is still running. Drawn as an
      // ordinary settled call that would be a lie -- `5.0s` next to a build
      // with four minutes to go.
      //
      // `result` is the tool's own return value and reaches us verbatim:
      // toJsonEvent() passes every event but message_update straight through,
      // so `details.backgrounded` is exactly what the extension set. Stashed
      // rather than applied here because the call is closed by
      // onActiveToolChanged, which fires off `tool` going empty on the next
      // line -- so this is the last moment the detail exists to be read.
      var det = d.result && d.result.details ? d.result.details : null
      root.closingBg = (det && det.backgrounded)
        ? { pid: Number(det.pid) || 0, log: String(det.logFile || "") } : null
      if (root.closingBg)
        root.addBgJob(root.closingBg.pid,
                      // The tool says what kind of thing it handed back when
                      // it knows -- a subagent reports "agent". Only bash has
                      // to be inferred, and there the tell is whether it was
                      // given an alarm to watch for.
                      det.kind ? String(det.kind)
                               : det.watching ? "monitor" : "job",
                      // The intent first, the command only if there was none.
                      // A tray row answers "what is running and why", and a
                      // shell one-liner elided at 40 characters answers
                      // neither.
                      String(det.label || det.command || ""),
                      String(det.name || ""))
      setTurn("tool", "")
      break
    }

    case "extension_ui_request":
      // An extension asking for a UI that does not exist outside a TTY. The
      // one that reaches us in practice is the notify a slash command sends
      // when it will not run in this mode, and it is the ONLY account the user
      // gets of a question that produced no answer -- so it goes on `error`
      // rather than vanishing. On `error` and not into the assistant's turn
      // text, because this is not the model talking: the model was never
      // asked. ask() clears `error` per question, so it does not outlive the
      // turn it explains.
      if (!d.message) break
      root.extensionNotice = String(d.message)
      root.error = root.extensionNotice
      break

    // The failure a dead provider actually produces, which is none of the
    // shapes this file already watches for. There is no `response
    // success:false` and no error event: the turn starts, runs, settles
    // normally, and the answer is simply EMPTY, with the reason buried in the
    // assistant message pi has just finished writing.
    //
    //   {"type":"message_end","message":{...,"stopReason":"error",
    //    "errorMessage":"OAuth refresh failed for anthropic: ...
    //    Refresh token expired ..."}}
    //
    // Without this the panel shows a blank answer and says nothing about why.
    // That was survivable while the model was fixed in the settings block; it is
    // not survivable now that `/model` can move it, so this is read.
    //
    // Only the first clause is kept. pi's message here carries the URL, the
    // response body and a JS stack, which is a paragraph on a strip sized for a
    // line -- and the first clause is the half that says what went wrong.
    case "message_end": {
      // The other end of a background job. The bash tool announces a finished
      // one as a CUSTOM message (customType bg_process_done), which pi appends
      // to the session and emits here like any other -- so this is the event
      // that clears the badge, and nothing has to poll a process table to
      // notice.
      var bd = d.message ? d.message.details : null
      if (d.message && d.message.customType === "bg_process_done") {
        if (bd && bd.pid) root.dropBgJob(Number(bd.pid))
        break
      }
      if (d.message && d.message.stopReason === "error") {
        var why = String(d.message.errorMessage || "the model returned an error")
        root.error = why.split(";")[0].split("\n")[0]
      }
      break
    }

    case "agent_settled":
      root.busy = false
      settleTurn()
      root.settled()
      // The one moment the context can have changed, so the one moment worth
      // asking. Event-driven, once per turn -- never on a timer.
      send({ type: "get_session_stats" })
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
    // Any settle is proof the abort went through the ordinary path; the
    // watchdog has nothing left to guard against.
    root.aborting = false
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
    // A description the agent wrote for this call beats any mechanical
    // summary -- that is the whole point of tools that carry one.
    var v = args.description || args.command || args.file_path || args.path || args.pattern || args.query || ""
    v = String(v).split("\n")[0]
    return v.length > 70 ? v.substring(0, 70) + "…" : v
  }

  // The other half. summarizeArgs() answers "what is it doing"; this answers
  // "what did it actually run" -- the command, the path, the pattern -- and it
  // never falls back to the description, because a row that prints the same
  // sentence twice is worse than a row that prints it once.
  //
  // Both are kept because the panel now shows both: the intent on one line and
  // the literal call under it, which is the shape the user asked for after
  // seeing Claude Code do it. Before this, `description` simply WON and the
  // command was thrown away at the door -- there was no second field to render
  // even if the delegate had wanted one.
  //
  // Not truncated. A command is wrapped and line-capped by the delegate that
  // draws it, which knows how much room it has; cutting it to 70 characters
  // here would elide the half that says which file.
  function rawArgs(args) {
    if (!args || typeof args !== "object") return ""
    var v = args.command || args.file_path || args.path || args.pattern || args.query || ""
    return String(v).replace(/\s+$/, "")
  }

  // --------------------------------------------------------------- transport
  // The four values the panel switches at runtime, handed to the broker so the
  // NEXT spawn is born on them. This is what makes `/model` and `/effort`
  // outlive the child that heard them -- the same job buildCommand() used to do
  // by reading these properties directly, done over a wire instead.
  //
  // Sent on every ask rather than only on change: it is one small line against
  // a question that costs seconds, and a broker that restarted since the last
  // change would otherwise spawn on stale defaults. The broker holds it and
  // acts on it only at spawn time, so sending it mid-turn is harmless.
  //
  // The argument that the CLI flags beat a resumed session file's own recorded
  // model still holds and is unchanged by the move -- see "and persistence"
  // above. The flags are simply assembled one process further out.
  function sendConfig() {
    control({ type: "__config",
              provider: root.provider, model: root.model,
              effort: root.effort, session: root.resumePath })
  }

  // A control frame. No `id`: the broker answers these itself and never
  // forwards them, so an id would be a number nothing ever echoes back.
  function control(obj) {
    if (!sock.connected) return
    sock.write(JSON.stringify(obj) + "\n")
  }

  Socket {
    id: sock
    // $XDG_RUNTIME_DIR, not /tmp -- a lock file this desktop put in /tmp once
    // locked root out of it under fs.protected_regular, and the runtime dir is
    // where the rest of the shell's state already lives.
    //
    // Nothing is started from here. The path is a systemd .socket, listening
    // from login, and connecting to it is what starts ori-agent.service. So
    // this connect cannot lose a race with a daemon coming up: the socket
    // exists before anything is behind it, and systemd holds the connection
    // until there is.
    path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/ori-agent.sock"
    connected: true

    // Line-delimited JSON, exactly as it was on the child's stdout -- Socket
    // inherits DataStream, so this is the same SplitParser that used to read
    // the pipe, reading the socket instead. That is the whole of the change at
    // this layer.
    parser: SplitParser { onRead: function (line) { root.ingest(line) } }

    onConnectionStateChanged: {
      if (sock.connected) {
        retry.stop()
        // Ask what the world looks like BEFORE assuming anything about it.
        // Everything the boot path does hangs off the answer -- see onWelcome.
        root.control({ type: "__hello" })
        return
      }
      // The broker is a systemd unit with Restart=on-failure, so a drop is a
      // restart in progress far more often than it is a machine without one.
      // Reconnecting is what makes the panel pick the agent back up by itself.
      root.warm = false
      retry.start()
    }
  }

  Timer {
    id: retry
    interval: 1000
    repeat: true
    onTriggered: if (!sock.connected) sock.connected = true
  }

  // --------------------------------------------------------------- boot
  // Two things have to land before the panel knows what to put on screen: the
  // session index (what conversations exist) and the broker's welcome (whether
  // one of them is being answered RIGHT NOW). They arrive in either order --
  // one is a file read, the other a socket round trip -- so whichever is second
  // makes the decision, and `booted` makes it once.
  //
  // The order matters because the two answers are mutually exclusive. A disk
  // restore mid-turn would put the transcript back MINUS the answer being
  // written, and then the replay would stream that answer into a row nothing
  // had opened. So a busy broker takes the screen and the disk restore is
  // skipped entirely; reattach() rebuilds the same transcript from the live
  // agent, which is strictly better because it is the agent's own copy.
  property bool welcomed: false
  property bool booted: false

  function onWelcome(d) {
    root.warm = !!d.warm
    if (d.workdir) root.workdir = String(d.workdir)
    root.welcomed = true

    // THE BROKER CAME BACK WITH NOTHING RUNNING, AND WE THINK SOMETHING IS.
    //
    // That combination has exactly one cause: the turn this panel was watching
    // died with the process that was serving it. The way it happens in practice
    // is Ori restarting its own unit from its own bash tool -- `systemctl
    // --user restart ori-agent` kills the broker, and pi is in the broker's
    // cgroup, so pi goes with it. The tool call never returns, no
    // tool_execution_end and no agent_settled is ever sent, and the socket just
    // drops.
    //
    // Reconnecting was already handled; being WEDGED was not. `busy` stayed
    // true forever: the rail spun, the spine breathed, ask() refused every
    // message ("a turn is running"), and the only way out was a shell reload.
    // The panel had all the evidence it needed -- a fresh broker saying it is
    // idle -- and was not reading it.
    //
    // onPiExited() cannot cover this, because there is no exit event to hear:
    // the thing that would have sent it is the thing that died.
    if (!d.busy && root.busy) {
      root.busy = false
      root.awaitingRead = false
      root.aborting = false
      abortWatchdog.stop()
      root.pending = ""
      root.pendingImages = []
      if (root.error === "")
        root.error = "the agent restarted mid-turn -- that answer is gone, ask again"
      settleTurn()
    }

    // A reconnect while a turn is in flight is the case this whole rewrite is
    // for, and it is not only a boot case: the broker restarting mid-answer
    // lands here too, and wants the same treatment.
    if (d.busy) {
      root.booted = true
      root.reattach()
      return
    }
    root.bootStep()
  }

  function bootStep() {
    if (root.booted || !root.welcomed || !root.sessionsLoaded) return
    root.booted = true
    root.restoreLastSession()
  }

  // ------------------------------------------------------------- reattach
  // Pick up a turn already in flight. The transcript comes from the AGENT, not
  // from disk, because pi has not written the answer yet -- and the reason
  // this works at all is that get_entries is answerable mid-turn. Measured
  // against a real child 4.5s into an answer: it replied in band, returned
  // history ending at the unanswered question, and the turn settled normally
  // afterwards.
  //
  // That is also why the broker's own record of the question is ignored on
  // this path. pi appends the USER message to the session early -- observed
  // going 5 -> 6 entries while the answer streamed -- so get_entries already
  // has it, and replaying it too would show it twice. The buffer supplies only
  // the half that does not exist anywhere else yet: the answer so far.
  property bool replayPending: false

  function reattach() {
    root.awaitingEntries = true
    root.replayPending = true
    send({ type: "get_entries" })
  }

  // Called from the get_entries response, once rehydrate() has put the
  // transcript back. rehydrate() ends every row settled, which is right for a
  // conversation read off disk and wrong here by exactly one row.
  function openReplayTurn() {
    root.replayPending = false
    appendTurn("assistant", "", "", "", true, "")
    root.error = ""
    // Restarts the turn clock, so the duration readout measures from the
    // reattach rather than from the question. Nothing in the protocol
    // timestamps a turn and the broker does not stamp its buffer, so the
    // honest options were a wrong number or none; a number that undercounts a
    // turn you reloaded through is the smaller lie.
    root.busy = true
    root.lastAppendAt = Date.now()
    root.appended()
    // Released here and not a moment earlier. Everything the broker held while
    // this handshake ran now arrives in order, into the row just opened.
    control({ type: "__replay" })
  }

  // ------------------------------------------------------- spawn / lifecycle
  // What Process.onStarted used to do, driven by the broker's event instead.
  // The body is unchanged, and so is its argument: all five of these are
  // knowable the moment a child is up, none can change without a spawn, and
  // they were measured landing 0.62-0.79s after spawn against a first token
  // 6.8s out.
  function onPiStarted() {
    root.warm = true
    if (root.awaitingEntries) root.send({ type: "get_entries" })
    else root.send({ type: "get_session_stats" })
    root.send({ type: "get_commands" })
    root.send({ type: "get_state" })
    root.send({ type: "get_available_thinking_levels" })
    root.send({ type: "get_available_models" })
    root.flush()
  }

  function onPiExited(code) {
    // The jobs were children of the process that just died, so they are not
    // running any more either. Anything else leaves a badge on screen counting
    // processes that no longer exist.
    root.bgJobs = ({})
    root.aborting = false
    abortWatchdog.stop()
    root.warm = false
    root.pending = ""
    root.pendingImages = []
    root.awaitingEntries = false
    root.replayPending = false
    // An exit while busy is a crash or the idle kill misfiring, not a normal
    // end: say so rather than leaving the panel spinning forever on an answer
    // that will never come.
    if (root.busy) {
      root.busy = false
      if (root.error === "") root.error = "pi exited (" + code + ")"
      settleTurn()
    }
  }

  // Drop the child and reclaim the ~200MB now, rather than waiting out the
  // broker's idle clock. The broker stays up -- it is the socket.
  function dropChild() {
    control({ type: "__kill" })
  }
}
