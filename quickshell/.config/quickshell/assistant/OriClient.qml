pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The panel's data source, and NOTHING else.
//
// This replaces PiSession.qml's role as the thing the assistant surfaces bind
// to, but it is a fraction of its size for one reason: it holds no conversation
// logic. It does not know what a steer is, it never parses a pi frame, it never
// reads a config file, and it cannot decide whether a message is a prompt or an
// interruption. It receives HostEvents over a unix socket, applies them to a
// ListModel and a handful of properties, and sends ClientCmds back. Everything
// else is ori-host's.
//
// The contract is ori-host/src/protocol.ts. Two of its design notes shape every
// function below and are worth restating where the code lives:
//
//   * Everything is addressed by a STABLE ID, never by a row index. The old
//     panel keyed five parallel maps on the index into the ListModel and had to
//     re-key all of them whenever a steer inserted a row mid-list. The maps here
//     (`toolsById`, `costById`) are keyed by turn id and survive an insert
//     untouched.
//   * `turn_delta` is an APPEND, not a replacement. It carries only the new
//     characters. Anything else is a `turn_patch`.
//
// Transport is NDJSON over $XDG_RUNTIME_DIR/ori-agent.sock, because that is the
// only push transport Quickshell has: qt6-websockets is not installed and
// DataStreamParser is isCreatable:false, so length-prefixed framing is
// unreachable from QML.
Singleton {
  id: root

  // ------------------------------------------------------------------ state
  // Everything from here to the next rule mirrors protocol.ts one field for one
  // property. They are writable rather than `readonly` because ingest() below
  // is the only writer and a readonly property cannot be assigned at all --
  // nothing outside this file writes them, which is the property that actually
  // matters. (`notice`, `panelOpen` and `unread` are the three deliberate
  // exceptions and are marked where they are declared.)

  // ---- SessionState ----
  // The panel NEVER derives `busy`. There is one authoritative copy and it is
  // this one, set by the host's `state` and `snapshot` events.
  property bool busy: false
  property bool compacting: false
  property string compactPhase: ""
  property bool warm: false

  property string provider: ""
  property string model: ""
  // The PINNED effort. Empty means "provider default".
  property string effort: ""
  // The EFFECTIVE level as pi reports it. It can differ from `effort` because
  // set_thinking_level clamps silently and acks success for every string, so
  // this is the one worth showing.
  property string thinkingLevel: ""
  // Efforts offered for the current model, already filtered host-side.
  property var levels: []

  property string sessionId: ""
  property string sessionFile: ""
  property string sessionName: ""
  property string workdir: ""

  // ---- Usage ----
  property int usageInput: 0
  property int usageOutput: 0
  property int usageTotal: 0
  property int contextWindow: 0
  // True while `usageTotal` is a post-compaction ESTIMATE rather than a
  // measured reading. The host rejects a stale larger figure arriving after it;
  // the panel only has to mark the number as unmeasured.
  property bool usageEstimated: false

  // ---- BgJob[] / SessionEntry[] / ModelChoice[] / SlashCommand[] ----
  // Held as the arrays the protocol sends. The map-shaped views the tray reads
  // are derived below.
  property var bg: []
  property var sessions: []
  property var models: []
  property var commands: []

  // ---- transient strips ----
  // `error` pins the card border to the busy accent; `notice` does not. Writing
  // a success message into `error` was a real bug, which is why the protocol
  // has two events and this file has two properties.
  property string error: ""
  // WRITABLE by the panel: the composer sets it directly for facts only it
  // knows ("no saved conversations yet" when Ctrl+R finds an empty index).
  property string notice: ""

  // ---- panel-owned flags ----
  // Not host state: which surface has the keyboard, and whether the bar's dot
  // is bright. They live on the singleton because the bar cell and the panel
  // are separate windows that have to agree, and the cell is instantiated once
  // per monitor.
  property bool panelOpen: false
  property bool unread: false
  // Right-click on the bar cell pins it shut. Not persisted and not host state:
  // it is a preference about one widget, and the widget is instantiated once
  // per monitor, so the two copies have to agree on it somewhere.
  property bool cellCompact: false

  // Quiet: the host learning which surface has focus is housekeeping, and a
  // panel toggled while the host is restarting must not be reported as a fault.
  onPanelOpenChanged: root.send({ t: "panel", open: root.panelOpen }, true)

  // ------------------------------------------------------------------ turns
  // The conversation, oldest first.
  //
  // ROLES ARE FLAT, AND THAT IS FORCED. A ListModel without dynamicRoles
  // flattens a nested object into a sub-model, so `tools`, `images` and `cost`
  // cannot live in a role -- reading `turn.tools[0].name` back out gives
  // undefined. So the ListModel carries only scalars and the three structured
  // fields live beside it: `images` as the newline-joined path string Fmt
  // already parses, `tools` and `cost` in id-keyed maps.
  //
  // The role is `tid`, not `id`: a ListModel role is injected into the
  // delegate's scope as a context property, and `id` there collides with QML's
  // own object identifier.
  //
  // Every append writes ALL of these, including on assistant rows that have no
  // images and no delivery. A ListModel fixes its role set from the FIRST row
  // inserted -- a role missing there can never be written afterwards, silently.
  ListModel { id: turnModel }
  readonly property alias turns: turnModel

  // turn id -> ToolCall[] (adapted, see toolRow) and turn id -> TurnCost.
  // Reassigned, never mutated in place: Fmt.splitCached compares the calls array
  // by IDENTITY to decide whether its settled prefix is still valid, so a call
  // list changed in place would leave that cache stale with nothing to notice.
  property var toolsById: ({})
  property var costById: ({})

  // turn id -> row index. Deltas arrive at token rate, so the alternative -- a
  // linear scan with a ListModel.get() per row -- would cost the length of the
  // transcript per character.
  property var rowById: ({})

  function reindex() {
    var next = {}
    for (var i = 0; i < turnModel.count; i++) next[turnModel.get(i).tid] = i
    root.rowById = next
  }

  function rowOf(id) {
    if (!id) return -1
    var r = root.rowById[id]
    return (r === undefined || r < 0 || r >= turnModel.count) ? -1 : r
  }

  // One place a row is built, so append and insert cannot drift apart.
  function turnRow(t) {
    return {
      tid: String(t.id || ""),
      role: String(t.role || "assistant"),
      text: String(t.text || ""),
      thinking: String(t.thinking || ""),
      images: root.imageLines(t.images),
      pending: t.pending === true,
      delivery: Number(t.delivery || 0),
      settledAt: Number(t.settledAt || 0)
    }
  }

  // ImageRef[] -> the newline-separated path list Fmt.attached() splits. The
  // protocol deliberately never sends the base64 payload, so a path is all
  // there is and all the thumbnail needs.
  function imageLines(images) {
    var out = []
    var list = images || []
    for (var i = 0; i < list.length; i++) out.push(String(list[i].path || ""))
    return out.join("\n")
  }

  // A ToolCall, adapted to what the transcript's rows already read.
  //
  // `arg` is an alias of `summary` so ToolLine -- which is not being rewritten --
  // finds the intent sentence under the name it uses. `t0`/`ms` are STAMPED
  // HERE off the wall clock, because protocol.ts carries no timing on a
  // ToolCall: `t0` when the call is first seen RUNNING, `ms` when its state
  // leaves "running". They are display-only and nothing is sent back. If
  // ToolCall ever grows real timings, delete both and read them instead.
  //
  // A call that arrives ALREADY FINISHED has no start this panel ever saw --
  // every call in a snapshot of a conversation that was running while parked,
  // and every completed call carried by a turn_add or a turn_patch. Those keep
  // the UNKNOWN pair `t0 = 0` / `ms = 0`, which is the invariant both consumers
  // are written against (TurnDelegate.batchMs and ToolLine.ms both test
  // `t0 > 0` and contribute nothing without it). Stamping Date.now() on them
  // instead charged the turn receipt one elapsed-since-the-snapshot per
  // finished call -- five tools, twenty seconds after a Ctrl+R, read "1m 40s".
  function toolRow(c, prev) {
    var running = String(c.state || "running") === "running"
    var t0 = (prev && prev.t0 > 0) ? prev.t0 : (running ? Date.now() : 0)
    return {
      id: String(c.id || ""),
      name: String(c.name || ""),
      summary: String(c.summary || ""),
      arg: String(c.summary || ""),
      raw: String(c.raw || ""),
      state: String(c.state || "running"),
      result: String(c.result || ""),
      at: Number(c.at || 0),
      t0: t0,
      ms: running ? 0
        : ((prev && prev.ms > 0) ? prev.ms
          : (t0 > 0 ? Math.max(0, Date.now() - t0) : 0)),
      // The protocol has no backgrounded marker on a call; the tray owns "still
      // running". ToolLine reads this and draws nothing when it is null.
      bg: null
    }
  }

  function setTools(turnId, list) {
    var next = {}
    for (var k in root.toolsById) next[k] = root.toolsById[k]
    next[turnId] = list
    root.toolsById = next
  }

  function setCost(turnId, cost) {
    var next = {}
    for (var k in root.costById) next[k] = root.costById[k]
    next[turnId] = cost
    root.costById = next
    // The footer's rate freezes on the last finished turn. There is no live
    // rate in the protocol -- a turn's tokensPerSecond is only knowable once it
    // is over -- so this is the honest number to show. The DURATION is not
    // stamped here beside it; see `turnSeconds`.
    if (cost && Number(cost.tokensPerSecond) > 0)
      root.tokensPerSecond = Number(cost.tokensPerSecond)
  }

  // The three fields that cannot live in a ListModel role, for ONE turn.
  // Reassigns both maps, so it is O(n) in the transcript -- fine for the
  // handful of times a turn is added, wrong in a loop. applySnapshot builds its
  // maps in one pass instead; the cap on restored turns is gone, so a snapshot
  // is the whole conversation and a per-turn copy here would be quadratic.
  function stashTurnExtras(t) {
    var id = String(t.id || "")
    if (t.tools && t.tools.length > 0) root.setTools(id, root.toolRows(t.tools))
    if (t.cost) root.setCost(id, t.cost)
  }

  function toolRows(list) {
    var out = []
    for (var i = 0; i < list.length; i++) out.push(root.toolRow(list[i], null))
    return out
  }

  // ------------------------------------------------------- derived readouts
  // Nothing below decides anything. Each is a presentation shape over a field
  // the host already sent -- a vocabulary, a percentage, a keyed view of an
  // array -- and none of them can disagree with the host about state.

  // WHICH TURN IS THE LIVE SINK, by id rather than by row, so a steer inserting
  // above it cannot move the answer out from under the deltas. The host marks
  // exactly one turn `pending`; this only remembers which.
  property string liveId: ""

  readonly property var liveTurn: {
    var r = root.rowOf(root.liveId)
    return r < 0 ? null : turnModel.get(r)
  }

  readonly property var liveTools:
    root.liveTurn ? (root.toolsById[root.liveTurn.tid] || []) : []

  // "name summary" -- the rail splits it back into the verb and the sentence
  // beside it. Empty once the turn settles, whatever the last call said.
  readonly property string activeTool: {
    if (!root.liveTurn || !root.liveTurn.pending) return ""
    var list = root.liveTools
    for (var i = list.length - 1; i >= 0; i--) {
      if (list[i].state !== "running") continue
      return list[i].summary !== "" ? list[i].name + " " + list[i].summary
                                    : list[i].name
    }
    return ""
  }

  // When the running turn was accepted, for the rail's elapsed readout. The
  // protocol timestamps only the SETTLE (`Turn.settledAt`), so the start is
  // stamped here off the one input that flips exactly twice a turn.
  property double turnStartedAt: 0

  onBusyChanged: {
    if (root.busy) {
      root.turnStartedAt = Date.now()
      root.outputBase = root.usageOutput
      return
    }
    // A SETTLE IS THE HOST SAYING THE TURN IS OVER, and nothing else. `retry`
    // also clears `busy` after five seconds of outage -- the turn died with the
    // process producing it -- and that is a death, not an answer. Emitting it
    // there flashed the bar cell's arrival, latched `unread`, pinged the panel's
    // mark and made the veil read out an answer that never came.
    //
    // The socket is the discriminator, and it is exact: every host-sent `state`
    // is ingested on a live connection, while the watchdog branch runs only
    // after `retry` has already returned early on `sock.connected` -- so it
    // writes `busy` with the socket demonstrably down.
    if (sock.connected) root.settled()
  }

  // The reading `Usage.output` held when this turn opened. protocol.ts does not
  // say whether `output` is per-turn or session-cumulative -- it sits beside a
  // plainly cumulative `total` -- and the panel must be right either way, so it
  // keeps the same baseline the host keeps for TurnCost.output
  // (conversation.ts turnOutput). A cumulative counter only ever grows past the
  // baseline; a per-turn one starts under it. Without this the rail jumped
  // straight to the whole session's output the instant `busy` flipped.
  property int outputBase: 0

  // Output tokens for the turn in flight, zeroed at rest so nothing on screen
  // claims to still be counting. Counts up to the same figure the settled
  // turn's TurnCost.output freezes at, because it is computed the same way.
  readonly property int liveTokens: !root.busy ? 0
    : (root.usageOutput >= root.outputBase ? root.usageOutput - root.outputBase
                                           : root.usageOutput)

  // Frozen on the last settled turn's cost -- see setCost.
  property real tokensPerSecond: 0

  // What the bar cell shows once the count-up stops, DERIVED off the newest
  // assistant turn's cost rather than stamped when one arrives.
  //
  // A turn that ends with no content gets NO TurnCost at all (conversation.ts
  // costFor: `if (!hasContent(t) ...) return undefined`), so nothing would
  // overwrite a stamped figure and the cell went on showing the PREVIOUS
  // turn's duration under this turn's label -- a stale number presented as
  // current. Derived, an absent cost reads as 0, which is the cell's "this
  // turn reported no duration" and renders as nothing.
  //
  // Re-evaluates on the two inputs that can change it: turnModel.count (a turn
  // arrived) and costById (a cost arrived). A row's own roles do not notify,
  // but none of the fields read here are patched on a settled turn.
  readonly property real turnSeconds: {
    for (var i = turnModel.count - 1; i >= 0; i--) {
      var r = turnModel.get(i)
      if (r.role !== "assistant") continue
      var c = root.costById[r.tid]
      return c ? Number(c.seconds || 0) : 0
    }
    return 0
  }

  // When the transcript last GREW, for the bar cell's flow gauge: it turns the
  // silence since the last delta into a rate, so a stalled turn drifts and a
  // streaming one races. Stamped off the signal rather than at each of the
  // three emitters, so nothing that grows the transcript can forget to.
  property double lastAppendAt: 0
  onAppended: root.lastAppendAt = Date.now()

  // The newest `Turn.settledAt` the host has sent. Lifted out of the row for
  // the same reason and in the same way as tokensPerSecond: a ListModel role
  // does not notify, so a binding through turns.get(i).settledAt is evaluated
  // once and never again.
  property double lastSettledAt: 0

  function noteSettled(at) {
    // Newest wins, so a patch for an older turn arriving late cannot rewind it.
    var v = Number(at || 0)
    if (v > root.lastSettledAt) root.lastSettledAt = v
  }

  readonly property bool contextKnown: root.contextWindow > 0 && root.usageTotal > 0
  readonly property real contextFraction:
    root.contextKnown ? Math.min(1, root.usageTotal / root.contextWindow) : 0

  // The EFFECTIVE level when there is one, because that and the pinned level
  // differ exactly when pi clamped silently, and that is the case worth seeing.
  readonly property string effortLabel: root.effort === "" ? ""
    : (root.thinkingLevel !== "" ? root.thinkingLevel : root.effort)

  // pi's universal scale, for a panel whose model has not reported its own.
  readonly property var baseLevels: ["off", "minimal", "low", "medium", "high", "xhigh"]

  // ------------------------------------------------------------- background
  // The tray wants a map keyed by pid and a map of live agent lines keyed by
  // handle; the protocol sends one array. Both views, derived.
  readonly property var bgJobs: {
    var out = {}
    for (var i = 0; i < root.bg.length; i++) out[String(root.bg[i].pid)] = root.bg[i]
    return out
  }

  readonly property var agentActivity: {
    var out = {}
    for (var i = 0; i < root.bg.length; i++) {
      var j = root.bg[i]
      if (j.activity) out[String(j.name || "")] = String(j.activity)
    }
    return out
  }

  // Speech is EXCLUDED. It has a strip of its own, because "you are being
  // spoken to" is a different sentence from "the agent is waiting on something"
  // -- counting it here made the bar show a phantom x1 over an empty tray.
  readonly property int bgCount: {
    var n = 0
    for (var i = 0; i < root.bg.length; i++)
      if (String(root.bg[i].kind) !== "speak") n += 1
    return n
  }

  readonly property var speakJob: {
    for (var i = 0; i < root.bg.length; i++)
      if (String(root.bg[i].kind) === "speak") return root.bg[i]
    return null
  }

  readonly property var bgKindNoun: ({ job: "task", monitor: "monitor", agent: "agent" })
  readonly property var bgKindOrder: ["job", "monitor", "agent"]

  // "2 tasks · 1 monitor". Only the kinds present, in a fixed order, so the
  // line does not reshuffle itself as jobs come and go.
  readonly property string bgSummary: {
    var counts = {}
    for (var i = 0; i < root.bg.length; i++) {
      var kind = String(root.bg[i].kind || "job")
      counts[kind] = (counts[kind] || 0) + 1
    }
    var parts = []
    for (var k = 0; k < root.bgKindOrder.length; k++) {
      var key = root.bgKindOrder[k]
      var n = counts[key] || 0
      if (n === 0) continue
      parts.push(n + " " + root.bgKindNoun[key] + (n === 1 ? "" : "s"))
    }
    return parts.join(" · ")
  }

  // ---------------------------------------------------------------- signals
  signal settled()
  // The newest turn grew. The transcript keeps itself pinned off this rather
  // than polling.
  signal appended()
  // The USER's own message was accepted. A different contract from `appended`:
  // an append landing while they are scrolled up reading is theirs to ignore,
  // but the message they just sent comes with the expectation of watching the
  // answer arrive under it.
  signal asked()
  // wl-paste answers long after the keypress, so an attachment is ANNOUNCED
  // rather than returned. `n` is the marker index the composer inserts as
  // `[Image n]`; deleting that marker is what un-sends the image.
  signal attachedImage(int n, string path)

  // The same two answers for an attachment staged BY PATH, kept apart from the
  // clipboard's because they have different owners. `attachedImage` is what the
  // composer inserts an `[Image n]` marker for; an `ori image` picture belongs
  // to a question the IPC is holding, so routing it there would drop a marker
  // into whatever the user was typing -- and that marker goes dead the instant
  // the IPC sends its own question, because accepting a question clears host
  // staging. The failure is separate for the same reason, and because a caller
  // holding a question needs it: without it its only exit is the timeout, and
  // something reportable in 20ms would sit for the whole deadline.
  signal attachedPath(int n, string path)
  signal attachPathFailed(string why)

  // The ids of attach_path commands still waiting for an answer. The host
  // echoes the id back on `attached`/`attach_failed` (protocol.ts); anything
  // arriving without one is the clipboard's.
  property var pathAttachIds: []
  property int attachSeq: 0

  // Consume an id, answering whether it was ours. Ours is removed, so a reply
  // is routed exactly once.
  function claimPathAttach(id) {
    var key = String(id || "")
    if (key === "") return false
    var at = root.pathAttachIds.indexOf(key)
    if (at < 0) return false
    var next = root.pathAttachIds.slice()
    next.splice(at, 1)
    root.pathAttachIds = next
    return true
  }

  // -------------------------------------------------------------------- api
  // Every one of these is a ClientCmd and nothing more. None of them decides
  // anything -- above all, none of them decides prompt-vs-steer, which is the
  // host's call from its own `busy`.

  // THE ONE PLACE a ClientCmd reaches the socket, so every caller reports a
  // dead one the same way. ask() and command() set `agentDownError` before
  // their own early returns; abort(), resume(), activate(), newChat() and
  // attachClipboard() used to return a bare false, and `ipc call ori resume X`
  // then printed "error: " with nothing after it -- a report that names no
  // fault reads as a bug in the caller. Setting it here means a refusal is
  // never silent, whichever command was refused.
  //
  // `quiet` exempts HOUSEKEEPING frames -- ones the user did not initiate, of
  // which `panel` is the only one that can reach a dead socket. Toggling the
  // panel during a one-second host restart would otherwise paint the error
  // strip instantly and defeat `retry`'s deliberate five-second grace, which
  // exists precisely so a restart is not reported as a failure.
  function send(cmd, quiet) {
    if (!sock.connected) {
      if (quiet !== true) root.error = root.agentDownError
      return false
    }
    sock.write(JSON.stringify(cmd) + "\n")
    return true
  }

  // Returns whether the draft was taken, so the composer knows whether to clear
  // it. A line beginning with "/" is a command; the host owns parsing it,
  // including /model and /effort, which must work with no child running.
  function ask(text, images) {
    var line = String(text || "").trim()
    if (line === "") return false
    if (!sock.connected) { root.error = root.agentDownError; return false }
    // A notice describes the LAST thing that happened, and the panel sets some
    // of them itself -- so nothing on the host's side would ever clear those.
    // Asking again is the moment they stop being true.
    root.notice = ""
    if (line.charAt(0) === "/") return root.command(line)
    if (!root.send({ t: "ask", text: line,
                     images: images || root.takeAttachments(line) })) return false
    root.asked()
    return true
  }

  function command(line) {
    if (!sock.connected) { root.error = root.agentDownError; return false }
    root.notice = ""
    return root.send({ t: "command", line: String(line) })
  }

  function abort() { return root.send({ t: "abort" }) }

  function attachClipboard() { return root.send({ t: "attach_clipboard" }) }

  // The same handshake for an image named by PATH, which is what the `ori
  // image` IPC has instead of a clipboard. The reply is the ordinary
  // `attached`/`attach_failed` pair, so nothing here reads the file, sniffs it
  // or encodes it -- that is the host's, and it is why this is a command rather
  // than a QML function. One path per call.
  //
  // The `id` is what keeps this reply out of the composer -- see attachedPath.
  function attachPath(path) {
    root.attachSeq += 1
    var id = "path-" + root.attachSeq
    if (!root.send({ t: "attach_path", id: id, path: String(path) })) return false
    root.pathAttachIds = root.pathAttachIds.concat([id])
    return true
  }

  // PARK, never stop: the current conversation's pi child keeps running and its
  // turn finishes in the background. The host does the rest.
  function newChat() { return root.send({ t: "new" }) }
  function resume(id) { return root.send({ t: "resume", sessionId: String(id) }) }
  function activate(convId) { return root.send({ t: "activate", convId: String(convId) }) }

  function setPanelOpen(open) { root.panelOpen = open === true }

  // The marker indices still present in the draft. `attached` handed each one
  // out; deleting `[Image 2]` before sending is how you drop that image.
  function takeAttachments(draft) {
    var out = []
    var text = String(draft || "")
    var re = /\[Image (\d+)\]/g
    var m = re.exec(text)
    while (m !== null) {
      out.push(Number(m[1]))
      m = re.exec(text)
    }
    return out
  }

  // Shift+Tab. Only index arithmetic -- the host validates the level, clamps it
  // and reports what it settled on.
  function cycleEffort() {
    var scale = root.levels.length > 0 ? root.levels : root.baseLevels
    var at = scale.indexOf(root.thinkingLevel !== "" ? root.thinkingLevel : root.effort)
    return root.command("/effort " + scale[(at + 1) % scale.length])
  }

  // The closed value set for a command's argument, as rows the completion list
  // can render. `values` is the protocol's own field; a command without one
  // answers with an empty list, which is what un-arms stage two of completion.
  function commandValues(name) {
    var out = []
    for (var i = 0; i < root.commands.length; i++) {
      if (String(root.commands[i].name) !== String(name)) continue
      var vals = root.commands[i].values || []
      for (var j = 0; j < vals.length; j++)
        out.push({ name: String(vals[j]), description: "" })
      return out
    }
    return out
  }

  function lastAssistant() {
    for (var i = turnModel.count - 1; i >= 0; i--)
      if (turnModel.get(i).role === "assistant") return i
    return -1
  }

  // The question the newest answer belongs to, for the hover veil.
  function lastUser() {
    for (var i = turnModel.count - 1; i >= 0; i--)
      if (turnModel.get(i).role === "user") return i
    return -1
  }

  // ----------------------------------------------------------------- ingest
  // One HostEvent. A malformed line is DROPPED rather than thrown: a single
  // torn record must never take down a long-lived connection.
  function ingest(line) {
    var m
    try {
      m = JSON.parse(line)
    } catch (e) {
      console.log("ori: unparseable frame dropped")
      return
    }
    if (!m || !m.t) return

    // Events for a PARKED conversation must not land in the visible transcript.
    // The host re-snapshots on activate, so dropping them is complete.
    //
    // A MISSING `convId` means the active conversation and falls straight
    // through. That is the whole handling `notice`/`error` need: they carry no
    // convId today and are about to, and either way this one test is right.
    if (m.convId !== undefined && m.t !== "snapshot" && m.t !== "hello"
        && m.convId !== root.convId) return

    switch (m.t) {
    case "hello":
      root.awaitingHello = false
      helloWatchdog.stop()
      root.convId = String(m.convId || "")
      root.workdir = String(m.workdir || "")
      if (root.error === root.agentDownError) root.error = ""
      if (root.notice === root.agentLostNotice) root.notice = ""
      return

    case "snapshot":
      root.convId = String(m.convId || "")
      root.applySnapshot(m)
      return

    case "turn_add":
      root.addTurn(m.turn, m.index)
      return

    case "turn_delta":
      root.growTurn(m.turnId, m.field, m.delta)
      return

    case "turn_patch":
      root.patchTurn(m.turnId, m.patch)
      return

    case "turn_drop":
      root.dropTurn(m.turnId)
      return

    case "tool_add":
      root.setTools(String(m.turnId),
                    (root.toolsById[String(m.turnId)] || []).concat([root.toolRow(m.tool, null)]))
      return

    case "tool_patch":
      root.patchTool(String(m.turnId), String(m.toolId), m.patch || ({}))
      return

    case "state":
      root.applyState(m.patch || ({}))
      return

    case "usage":
      root.applyUsage(m.usage || ({}))
      return

    case "bg":
      root.bg = m.jobs || []
      return

    case "sessions":
      root.sessions = m.entries || []
      return

    case "models":
      root.models = m.models || []
      return

    case "commands":
      root.commands = m.commands || []
      return

    case "notice":
      root.notice = String(m.text || "")
      return

    case "error":
      root.error = String(m.text || "")
      return

    case "attached":
      if (root.claimPathAttach(m.id)) {
        root.attachedPath(Number(m.n || 0), String(m.path || ""))
        return
      }
      root.attachedImage(Number(m.n || 0), String(m.path || ""))
      return

    case "attach_failed":
      // A staged-by-path failure is the holder's to report -- it knows how many
      // pictures the question was waiting for and says so -- so it does not
      // also get the composer's wording.
      if (root.claimPathAttach(m.id)) {
        root.attachPathFailed(String(m.why || ""))
        return
      }
      // The NOTICE strip, not the error one. Ctrl+V with no image on the
      // clipboard is an ordinary miss -- nothing is broken and nothing was
      // inserted -- and `error` pins the whole card border to the busy accent.
      root.notice = "no image attached: " + String(m.why || "")
      return

    case "ack":
      // Correlated replies are for callers that sent an `id`. Nothing in this
      // panel does yet -- every command it sends is fire-and-forget and reports
      // through `notice`/`error`. Named so an unhandled-frame log stays honest.
      return
    }
  }

  // Which conversation the panel is showing. From `hello`, and replaced by
  // every `snapshot`.
  property string convId: ""

  // TRUE WHILE THE TRANSCRIPT IS BEING REPLACED, and the reason switching
  // conversations is not a freeze any more.
  //
  // The transcript view binds its `model` to this (AssistantPanel: `model:
  // OriClient.rebuilding ? null : OriClient.turns`), so for the duration of the
  // rebuild there is NO VIEW ATTACHED to the ListModel. That is the whole fix,
  // and it is worth spelling out why, because the loop below looks innocent:
  //
  //   * `turnModel.count` changes once per append, and a ListModel's count is a
  //     notifying property, so every delegate ALREADY BUILT re-evaluates
  //     `row = count - 1 - index` -- synchronously, inside the loop. Each one
  //     then points at a DIFFERENT turn, so `turn` -> `bodyText`/`calls` ->
  //     `pieces` -> Fmt.splitCached all re-derive for a row that is about to
  //     change again on the next append. cacheBuffer keeps every turn
  //     instantiated (AssistantPanel's note says why), so "already built" means
  //     the whole outgoing conversation.
  //   * `clear()` tears those delegates down ONE AT A TIME through the view.
  //
  // Measured offscreen on Qt 6.11.2 (software backend), switching between two
  // real 235-turn transcripts, counters planted in a copy of this file and of
  // the delegate's binding graph:
  //
  //     attached (today)   row re-evals 55,930   splits 702   apply 231ms
  //                        first frame +830ms, in ONE 830ms frame
  //     detached (this)    row re-evals    235   splits 235   apply  15ms
  //                        first frame +37ms, fully built by +665ms over 42 frames
  //
  // So it is not only 15x less blocking work; the build is FRAME-PACED instead
  // of one long stall, which is the difference the user actually feels.
  //
  // No flash of an empty transcript: the flag goes true and false inside this
  // one synchronous function, so no frame is ever rendered while the model is
  // detached.
  property bool rebuilding: false

  // The panel replaces everything it holds. One pass, and both id-keyed maps
  // are assigned ONCE at the end -- see stashTurnExtras for why not per turn.
  function applySnapshot(m) {
    // try/finally, not a plain pair of assignments: a throw anywhere in the
    // rebuild would otherwise leave `rebuilding` true, and the panel would draw
    // an empty transcript for the rest of the session with nothing to say why.
    root.rebuilding = true
    try {
      root.fillTurns(m)
    } finally {
      root.rebuilding = false
    }
    // Usage BEFORE state: applyState can flip `busy`, and the baseline
    // onBusyChanged stamps has to come off THIS conversation's reading rather
    // than the one the panel was showing a moment ago.
    root.applyUsage(m.usage || ({}))
    root.applyState(m.state || ({}))
    // Switching into a conversation that is ALREADY busy never flips `busy`, so
    // nothing stamped a baseline for it and the one still standing belongs to
    // another conversation entirely.
    if (root.busy) root.outputBase = root.usageOutput
    root.bg = m.bg || []
    root.appended()
  }

  // The turn list itself, and nothing else. Split out of applySnapshot so the
  // detached window above covers EXACTLY the model writes and not the state,
  // usage or bg assignments -- those touch bindings the rest of the panel reads
  // and have no business happening while the transcript is unmounted.
  function fillTurns(m) {
    turnModel.clear()
    root.liveId = ""
    var tools = {}
    var costs = {}
    var rate = 0
    // ASSIGNED rather than noteSettled()'d: a snapshot replaces the
    // conversation, so a later stamp belonging to the one being left has to go
    // with it.
    var settled = 0
    var list = m.turns || []
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      var id = String(t.id || "")
      turnModel.append(root.turnRow(t))
      if (t.tools && t.tools.length > 0) tools[id] = root.toolRows(t.tools)
      if (t.cost) {
        costs[id] = t.cost
        if (Number(t.cost.tokensPerSecond) > 0) rate = Number(t.cost.tokensPerSecond)
      }
      if (Number(t.settledAt || 0) > settled) settled = Number(t.settledAt)
      if (t.pending === true) root.liveId = id
    }
    root.toolsById = tools
    root.costById = costs
    root.tokensPerSecond = rate
    root.lastSettledAt = settled
    root.reindex()
  }

  // Appended, or INSERTED where a steer split the seam. An insert moves every
  // row after it, so the index map is rebuilt; the id-keyed maps are untouched,
  // which is the whole point of ids.
  function addTurn(t, index) {
    if (!t) return
    var row = root.turnRow(t)
    if (index === undefined || index === null || index >= turnModel.count) {
      turnModel.append(row)
      root.rowById[row.tid] = turnModel.count - 1
    } else {
      turnModel.insert(Math.max(0, index), row)
      root.reindex()
    }
    root.stashTurnExtras(t)
    root.noteSettled(t.settledAt)
    if (t.pending === true) root.liveId = String(t.id)
    root.appended()
  }

  // APPEND, never replace. `field` is "text" or "thinking"; anything else is a
  // turn_patch and does not come through here.
  function growTurn(turnId, field, delta) {
    var r = root.rowOf(String(turnId))
    if (r < 0) return
    if (field !== "text" && field !== "thinking") return
    var cur = turnModel.get(r)
    // Named rather than indexed by `field`: a ListModel row is a QML model
    // object, not a plain JS one, and reading it by a computed key is not a
    // guarantee worth leaning on in the hot path.
    var was = String((field === "text" ? cur.text : cur.thinking) || "")
    turnModel.setProperty(r, field, was + String(delta || ""))
    root.appended()
  }

  function patchTurn(turnId, patch) {
    var id = String(turnId)
    var r = root.rowOf(id)
    if (r < 0 || !patch) return
    for (var k in patch) {
      switch (k) {
      case "id":
        // The id is the address of everything else about this turn; a host that
        // re-keyed a live row would orphan its tools and its cost.
        break
      case "tools":
        root.setTools(id, root.toolRows(patch.tools || []))
        break
      case "cost":
        root.setCost(id, patch.cost)
        break
      case "images":
        turnModel.setProperty(r, "images", root.imageLines(patch.images))
        break
      case "pending":
        turnModel.setProperty(r, "pending", patch.pending === true)
        if (patch.pending === true) root.liveId = id
        else if (root.liveId === id) root.liveId = ""
        break
      case "role":
      case "text":
      case "thinking":
        turnModel.setProperty(r, k, String(patch[k]))
        break
      case "delivery":
        turnModel.setProperty(r, k, Number(patch[k]))
        break
      case "settledAt":
        turnModel.setProperty(r, k, Number(patch[k]))
        root.noteSettled(patch[k])
        break
      }
    }
  }

  // Only ever an empty row the steer path dropped where it stood.
  function dropTurn(turnId) {
    var id = String(turnId)
    var r = root.rowOf(id)
    if (r < 0) return
    turnModel.remove(r)
    var tools = {}
    for (var k in root.toolsById) if (k !== id) tools[k] = root.toolsById[k]
    root.toolsById = tools
    var costs = {}
    for (var c in root.costById) if (c !== id) costs[c] = root.costById[c]
    root.costById = costs
    if (root.liveId === id) root.liveId = ""
    root.reindex()
  }

  function patchTool(turnId, toolId, patch) {
    var list = root.toolsById[turnId]
    if (!list) return
    var next = []
    for (var i = 0; i < list.length; i++) {
      if (list[i].id !== toolId) { next.push(list[i]); continue }
      var merged = {}
      for (var k in list[i]) merged[k] = list[i][k]
      for (var p in patch) merged[p] = patch[p]
      next.push(root.toolRow(merged, list[i]))
    }
    root.setTools(turnId, next)
  }

  // Partial<SessionState>. Only the keys present are written, so a `state`
  // event carrying one field cannot blank the other eleven.
  function applyState(p) {
    if (p.busy !== undefined) root.busy = p.busy === true
    if (p.compacting !== undefined) root.compacting = p.compacting === true
    if (p.compactPhase !== undefined) root.compactPhase = String(p.compactPhase)
    if (p.warm !== undefined) root.warm = p.warm === true
    if (p.provider !== undefined) root.provider = String(p.provider)
    if (p.model !== undefined) root.model = String(p.model)
    if (p.effort !== undefined) root.effort = String(p.effort)
    if (p.thinkingLevel !== undefined) root.thinkingLevel = String(p.thinkingLevel)
    if (p.levels !== undefined) root.levels = p.levels || []
    if (p.sessionId !== undefined) root.sessionId = String(p.sessionId)
    if (p.sessionFile !== undefined) root.sessionFile = String(p.sessionFile)
    if (p.sessionName !== undefined) root.sessionName = String(p.sessionName)
    if (p.workdir !== undefined) root.workdir = String(p.workdir)
  }

  function applyUsage(u) {
    root.usageInput = Number(u.input || 0)
    root.usageOutput = Number(u.output || 0)
    root.usageTotal = Number(u.total || 0)
    root.contextWindow = Number(u.contextWindow || 0)
    root.usageEstimated = u.estimated === true
  }

  // ----------------------------------------------------------------- socket
  // Quickshell's Socket has NO reconnect of its own: `connected` is a WRITABLE
  // property rather than a method, and on a drop you get exactly one
  // connectionStateChanged and nothing else. So reconnection is a Timer that
  // re-asserts `connected = true` until it takes.
  Socket {
    id: sock
    // $XDG_RUNTIME_DIR, never /tmp -- a lock file this desktop put there once
    // locked root out of it under fs.protected_regular.
    path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/ori-agent.sock"
    connected: true

    // NDJSON. Split on "\n" only: node's readline additionally splits on
    // U+2028/U+2029, both valid inside a JSON string, so it is not
    // protocol-compliant here. SplitParser is.
    parser: SplitParser { onRead: function (line) { root.ingest(line) } }

    onConnectionStateChanged: {
      if (sock.connected) {
        retry.stop()
        root.retries = 0
        root.awaitingHello = true
        // The channel is what makes a shell reload REATTACH rather than start
        // over: the host adopts the conversation already registered under it,
        // with its warm child and its mid-turn buffer.
        root.send({ t: "hello", channel: "panel", version: root.protocolVersion })
        root.send({ t: "panel", open: root.panelOpen })
        helloWatchdog.restart()
        return
      }
      // ori-host is a systemd unit with Restart=on-failure, so a drop is a
      // restart in progress far more often than a machine without one.
      root.warm = false
      root.awaitingHello = false
      helloWatchdog.stop()
      // A DROP MID-TURN USED TO BE INVISIBLE: nothing touched `busy`, so the
      // rail went on saying "thinking" and the spine went on breathing for as
      // long as the host was down. That is the worst failure this panel has --
      // it looks exactly like working. Say it while there is still reason to
      // hope, and let `retry` promote it to an error when there is not.
      if (root.busy) root.notice = root.agentLostNotice
      retry.start()
    }
  }

  readonly property int protocolVersion: 1

  // How many reconnects have gone unanswered on this outage. `retry` owns the
  // promotion to an error because it is the only thing that knows how long the
  // outage has lasted -- onConnectionStateChanged fires once and then never
  // again while the socket stays down.
  property int retries: 0
  // Five seconds. A host restarting under systemd is back inside one or two.
  readonly property int retriesBeforeError: 5

  // Both failures say the same thing, in the same words, so the hello handler
  // can clear the message on recovery without clobbering an unrelated error.
  readonly property string agentDownError:
    "no answer from the agent -- systemctl --user status ori-agent"
  readonly property string agentLostNotice: "lost the agent -- reconnecting"

  Timer {
    id: retry
    interval: 1000
    repeat: true
    onTriggered: {
      // Connected and still mute is helloWatchdog's case; it drops the socket
      // itself, so there is nothing to do here but wait for it.
      if (sock.connected) return
      root.retries += 1
      if (root.retries >= root.retriesBeforeError) {
        if (root.error === "") root.error = root.agentDownError
        // A panel still claiming to think over a host that has been gone for
        // five seconds is lying. The turn died with the process producing it.
        if (root.busy) {
          if (root.notice === root.agentLostNotice) root.notice = ""
          root.busy = false
        }
      }
      sock.connected = true
    }
  }

  // The handshake deadline. ori-host now owns its own listener, so the old
  // failure this was built for -- a systemd .socket accepting a connection with
  // nothing behind it -- is gone by construction. Kept anyway: a host that
  // connects and never answers is indistinguishable from a working one without
  // it, and that silence is unbounded.
  property bool awaitingHello: false

  Timer {
    id: helloWatchdog
    // Covers a process start, not just a reply: the connect may be what starts
    // the host. It does NOT have to cover a pi spawn -- `hello` is the host's
    // own answer and does not wait for a child.
    interval: 8000
    onTriggered: {
      if (!root.awaitingHello) return
      root.awaitingHello = false
      console.log("ori: no hello in " + interval + "ms -- the socket is up with nothing behind it")
      root.error = root.agentDownError
      // Connected but mute IS down, whatever the kernel says. Dropping the
      // socket puts it back under `retry`, which was stopped on connect -- and
      // a reconnect is a clean re-handshake, where re-sending hello down the
      // same socket would risk a second adoption of the same channel if the
      // host were merely slow rather than wedged. Started here as well as in
      // the disconnect branch, so this does not depend on writing `connected`
      // raising the signal that would otherwise start it.
      retry.start()
      sock.connected = false
    }
  }
}
