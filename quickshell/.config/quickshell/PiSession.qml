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
// A warm node process is ~200MB, which is more than this entire shell. So it is
// NOT started with the shell: the first question spawns it, and IDLE_KILL_MS of
// silence kills it again. You pay the 2.0s cold start once per burst of use and
// nothing at all the rest of the day -- the same "nothing exists until asked
// for" rule the launchers and the share picker follow.
//
// ------------------------------------------------------------------- flags
//   -ne  extension DISCOVERY off. Still required, but NOT for the reason this
//        note used to give -- see the measurement in buildCommand(), which is
//        there so the next reader does not keep or delete this flag on a guess
//        the way two of us nearly did.
//   --session PATH  attach to an existing session file, when resuming. Omitted
//        for a fresh conversation; see "sessions" below for why `--no-session`
//        is gone.
//   -e   extensions are opted INTO one path at a time (see `extensions` below).
//        Unlinking ~/.pi/agent/extensions/* would have worked too, but that
//        directory is global: it would change `pi` in every terminal, not here.
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
    "~/Development/Personal/my-pi/extensions/shim-web.ts",

    // /ollama-usage and /ollama-usage-status: how much of the Ollama Cloud
    // session and weekly allowance is spent. Named here rather than found by
    // discovery, which is the whole point of `-ne` plus explicit `-e` -- see
    // buildCommand(). Dropping -ne to get this one would have bought nine
    // others we do not want: four are Anthropic/OpenAI billing readouts for
    // services this machine does not pay for, and the rest are terminal
    // overlays that can only do headless what /llama does, which is decline.
    //
    // It is also the one usage readout that matches the bill: the panel could
    // already offer /usage for an Anthropic subscription nobody here has, and
    // nothing at all for the Ollama Cloud plan that every answer on this
    // machine goes through.
    //
    // Headless safety is CHECKED, not taken from its header. It claims to
    // survive with no TUI -- every ctx access in a try/catch, `hasUI` read
    // through one, because reading it is itself the throwing act. Driven on a
    // real rpc child with our exact flags it registered both commands (1 -> 3),
    // settled two full turns answering "pong" and "still-here", answered a
    // stats probe afterwards, and left stderr empty. That covers both things
    // that could have killed it: the 1.5s post-load timer, which is the same
    // shape as the crash in pi's own openai-codex-usage.ts, and the `turn_end`
    // hook, which fires a network call once per turn and fired twice here.
    "~/Development/Personal/my-pi/extensions/ollama-usage.ts"
  ]

  // Where shim-web sends its searches. The local systemd instance rather than
  // the VPS: it is the same code, it is already running for `ccr`, and it saves
  // a round trip to a datacentre for something the laptop can ask for directly.
  readonly property string shimUrl: "http://127.0.0.1:11435"

  // Kill the child after this much silence. Long enough to cover a
  // back-and-forth, short enough that a stray question does not leave 200MB
  // resident for the rest of the session.
  readonly property int idleKillMs: 10 * 60 * 1000

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

  readonly property bool warm: proc.running

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
  // It exists because the character counter in the bar CANNOT tell working from
  // hung: a tool call streams no deltas, so the count sits frozen for the whole
  // of a `bash sleep 15` while the process is perfectly healthy. The gap
  // BETWEEN deltas is the fact that number is missing, and OriAura drives the
  // travelling pool off it -- full rate while text arrives, decaying to a drift
  // while it does not. A stamp, not a timer: nothing here polls it.
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
    root.lastAppendAt = Date.now()
    root.appended()
  }

  // ------------------------------------------------------------------- api
  // The one place a row is added, so the role set can never diverge between
  // ask(), the streaming turn, and rehydrate().
  function appendTurn(role, text, thinking, tool, pending, images) {
    turnModel.append({ role: role, text: text, thinking: thinking,
                       tool: tool, pending: pending, images: images })
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
    if (msg === "" || root.busy) return false

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
    root.busy = true
    root.settledAtMs = 0
    // A turn opens at full flow, so the first seconds -- before a single token
    // has landed -- read as movement rather than as a stall left over from the
    // previous answer.
    root.lastAppendAt = Date.now()
    appendTurn("user", msg, "", "", false, labels.join("\n"))
    // The assistant's turn exists before a single token arrives, so the view has
    // a row to stream into and the conversation never visibly jumps.
    appendTurn("assistant", "", "", "", true, "")
    root.appended()

    idleTimer.stop()
    // Queued rather than sent, because the child may not exist yet. `flush()`
    // runs either immediately (warm) or from onStarted (cold), so the caller
    // never has to know which case it is.
    pending = msg
    pendingImages = blocks
    if (proc.running) flush()
    else {
      // Cold, with a conversation already on screen: re-attach to the session
      // that conversation came from, so the model is not answering a follow-up
      // to something it has no record of. This is the whole reason --no-session
      // had to go.
      if (root.resumePath === "" && root.sessionFile !== "" && turnModel.count > 2)
        root.resumePath = root.sessionFile
      proc.running = true
    }
    return true
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
    // Forget which file this conversation was, so neither an idle-kill respawn
    // nor a cold start reattaches to it. The row already in the index stays --
    // "start over" clears the screen, it does not delete history.
    root.resumePath = ""
    root.sessionFile = ""
    root.sessionId = ""
    if (proc.running) send({ type: "new_session" })
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
      root.restoreLastSession()
    }
    // No file yet is an empty history, not an error.
    onLoadFailed: {
      root.sessions = []
      root.sessionsLoaded = true
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
    if (root.busy || turnModel.count > 0 || proc.running) return

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
    if (proc.running) send({ type: "switch_session", sessionPath: s.file })
    else proc.running = true   // buildCommand picks up resumePath
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

      // A new question, or an assistant entry with no user entry ahead of it at
      // all (a compaction summary, a resumed fork): open a row either way, so
      // the text is never dropped and never merged into the previous answer.
      if (row < 0) {
        appendTurn("assistant", "", "", "", true, "")
        row = turnModel.count - 1
      }
      var text = turnModel.get(row).text
      var think = turnModel.get(row).thinking
      var ac = m.content || []
      for (var b = 0; b < ac.length; b++) {
        var blk = ac[b]
        if (blk.type === "text") text += blk.text
        else if (blk.type === "thinking") think += (blk.thinking || "")
        else if (blk.type === "toolCall") {
          var list = (log[row] || []).slice()
          list.push({ name: String(blk.name || "tool"),
                      arg: summarizeArgs(blk.arguments), t0: 0, ms: 0 })
          log[row] = list
        }
      }
      turnModel.setProperty(row, "text", text)
      turnModel.setProperty(row, "thinking", think)
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
    proc.write(JSON.stringify(obj) + "\n")
    // Handed back so flush() can remember which response belongs to the
    // question, rather than treating every `prompt` response as the current
    // one.
    return obj.id
  }

  function flush() {
    if (root.pending === "") return
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
        } else root.error = String(d.error || "get_entries failed")
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
        idleTimer.restart()
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
  // ------------------------------------------------------------ why -ne stays
  // The reason recorded here for years was that pi's bundled
  // openai-codex-usage.ts calls assertActive() on a UI that does not exist
  // outside a TTY, throws, and takes the whole run with it. That is NO LONGER
  // TRUE of the installed pi. Loading it deliberately on a headless rpc child --
  // `-ne -e ~/.pi/agent/extensions/openai-codex-usage.ts` -- registered its
  // three commands and answered a question normally, agent_settled and all.
  //
  // -ne stays anyway, because a second reason is live and was never written
  // down. Discovery loads ~/.pi/agent/extensions/pi-web-access, which registers
  // a `web_search` tool, and that collides with the shim-web.ts we load by
  // hand. pi does not warn and carry on -- it refuses to start:
  //
  //   Error: Failed to load extension ".../pi-web-access/index.ts":
  //   Tool "web_search" conflicts with .../my-pi/extensions/shim-web.ts
  //
  // Isolated both ways: no -ne and no -e shim-web starts fine and reports 10
  // commands; no -ne WITH -e shim-web dies before the first frame. So the flag
  // is protecting the deliberate choice of shim-web over pi-web-access that the
  // `extensions` block above argues for -- drop one and you must drop both.
  //
  // Nothing among those 10 is worth adding back by hand. Every one is a TUI
  // affordance: /usage, /usage-status, /codex-usage, /codex-usage-status,
  // /permissions, /bg, /websearch, /search, /tasks, /llama -- overlays, status
  // bars and browser openers, in a 460px panel that has none of those.
  //
  // ------------------------------------------------------- and why no --skill
  // Skills are NOT discovered from this working directory; they need an
  // explicit `--skill <path>`. Measured, same child, same question:
  //
  //   as it stands                      1 command   8138 input tokens
  //   + --skill ~/.claude/skills       30 commands 12736 input tokens
  //
  // So +4,598 input tokens on EVERY turn, stable across three runs, for 29
  // extra commands. (First-token latency is NOT a cost: one run came in at 22s
  // against a 2.5s baseline, but two repeats landed at 2.81s and 4.15s, so that
  // was the model, not the flag.)
  //
  // Not added, and the token count is the smaller half of why. That directory
  // is Claude Code's, not Ori's: those 29 are things like project-backend-dev and
  // beckmann-obgyn, written for an agent with a different toolset, and pointing
  // pi at it would make this panel's command list change whenever a skill is
  // installed for an unrelated tool. If Ori is to have skills, they want a
  // directory of Ori's own -- ~/.config/assistant/skills, next to the prompt
  // files -- and that `--skill` would be small, deliberate and cheap.
  //
  // One honest loose end: an earlier run of this same probe, with these exact
  // flags from this exact cwd, reported 17 commands of which 16 were skills,
  // and the count is not reproducible now -- the identical script re-run gives
  // 1. Something outside this repo changed underneath it. Whatever it was, it
  // is not something this file can rely on, which is the whole argument for
  // naming a directory explicitly rather than hoping discovery finds one.
  function buildCommand() {
    var parts = ["SHIM_URL=" + root.shimUrl, "exec " + root.binary,
                 "--mode rpc", "-ne",
                 "--provider " + root.provider, "--model " + root.model]
    // Quoted: session filenames carry an ISO timestamp with colons in it, which
    // a login shell would otherwise be free to interpret.
    if (root.resumePath !== "") parts.push("--session '" + root.resumePath + "'")
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

    // The child is spawned by ask(), so there is usually exactly one question
    // waiting when it comes up -- or, when resume() spawned it, a transcript to
    // read back out of the session it was started on.
    onStarted: {
      // The context gauge needs a window to divide by, and the window is
      // knowable the moment the child is up -- get_session_stats answers on a
      // child that has never been prompted. Measured against a hand-driven
      // rpc child: the reply landed 0.61s after spawn carrying
      // contextWindow 1048576 with tokens 0, a full 6.8s before the first
      // text_delta of the first answer.
      //
      // Asking only from agent_settled, which is what this used to do, meant
      // the gauge read nothing for the whole of the first answer, and kept
      // reading nothing afterwards if that first turn never settled. Both
      // observed: `window=0 known=false` for the seven seconds an essay
      // streamed, and still `window=0` five minutes after the child was
      // killed mid-turn. Fixing it at the spawn covers every one of those
      // failure paths at once, because the denominator is in hand before any
      // of them can happen.
      //
      // The other candidate was the first message_update carrying `usage`.
      // Rejected on the evidence: those arrive AFTER text has begun
      // streaming, the early ones carry all-zero usage, and none of them
      // carries a window at all -- only the numerator.
      //
      // Not a timer, and not a poll: this is the spawn event, and a spawn is
      // the only moment the window can become knowable without a turn having
      // settled.
      //
      // The resume path is deliberately left out. get_entries already sends
      // its own stats once the transcript has landed, and a stats reply that
      // beat rehydrate() to it would hand recordSession() the resumed
      // session's id alongside the label of the conversation being switched
      // away from.
      if (root.awaitingEntries) root.send({ type: "get_entries" })
      else root.send({ type: "get_session_stats" })
      // The command list, on the same spawn event and for the same reason: it
      // is knowable as soon as the child is up and cannot change without one.
      // Queueing both ahead of the question costs nothing the first token can
      // tell -- see the timing measurement on `commands`.
      root.send({ type: "get_commands" })
      root.flush()
    }

    onExited: function (exitCode) {
      root.pending = ""
      root.pendingImages = []
      root.awaitingEntries = false
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

  function dropChild() {
    idleTimer.stop()
    proc.running = false
  }
}
