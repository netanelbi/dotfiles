pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The control room's picture of the voice daemon (ears, in
// ~/Development/Personal/ori-voice/ears) -- the QML twin of tui.py's `Live`.
//
// It owns NO connection. EarsLink (inside Voice.qml, always alive) reads the
// daemon's SSE stream for the orb and hands every event here through
// ingest(); this file only folds events into state the panel can bind to.
// One stream, two readers: the orb and the panel never disagree about what
// the daemon said, and opening the panel does not open a second socket.
//
// Kept in a singleton rather than in the panel because the panel is built
// lazily and destroyed on close: the transcript of a call has to survive the
// panel being shut while you talk (voice never opens the panel).
//
// Commands go the other way through cmd(): POST /cmd on the same port.
Singleton {
  id: m

  // ------------------------------------------------------------ connection
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  // Overridable for a test feed (the offscreen harness points it at a mock).
  readonly property string portFile: Quickshell.env("ORI_EARS_PORTFILE") || (runtimeDir + "/ori-voice.port")
  readonly property string earsDir: Quickshell.env("HOME") + "/Development/Personal/ori-voice/ears"
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/ori-voice"

  property bool linked: false
  // While false the 15/s meters are not copied in: nothing on screen reads
  // them. The panel sets it while it is open.
  property bool watching: false

  // ----------------------------------------------------------------- state
  property bool call: false
  property bool aec: false
  property bool enrolled: false
  property string model: ""
  property string lang: "en"
  property var tune: ({})
  // The engine's editable settings, what it offers, and who it knows by voice.
  // null until a daemon that publishes them says so: the Settings tab hides
  // what is missing rather than inventing it.
  //   settings  {voices:{en,fr,...}, speed, hebrew, model, thinker_model, worker_provider,
  //              worker_model, resume_minutes, plugins:{name: mode}} -- overrides only
  //   options   {voices:{en:[ids]}, models:[], worker_providers:[],
  //              worker_models:{provider:[]}, plugins:[{name, description, core,
  //              required, mode, default_mode, overridden, active}]}
  //              mode on|auto|off; active = in use right now. Changes apply live
  //              (the engine's restart_needed is always false now; not read).
  //   people    [{name, created, samples:[{n, created, seconds, self_sim}]}]
  property var settings: null
  property var options: null
  property var people: null
  // key -> value sent with `set` and not yet confirmed by a state: shown
  // meanwhile, so a fast run of presses steps from the last one, not the
  // daemon's stale value.
  property var pendingSet: ({})
  // listening | hearing | thinking | speaking | ignored | closed
  property string mode: "closed"
  property real callSince: 0       // ms epoch the open call started, 0 = unknown
  property string banner: ""
  property real bannerProgress: -1
  // A passage to read aloud while a voice is enrolled ("" = none): the panel
  // shows it as a sheet over every tab while the banner lasts.
  property string bannerRead: ""

  // ----------------------------------------------------------------- meter
  property real level: -90
  property real floor: -60
  property real vad: 0
  property real silence: 0
  property real sim: -1            // live voice match, -1 = none
  property real lastSim: -1        // last voice match that was measured
  property var spectrum: []

  // -------------------------------------------------------------- pipeline
  // Station -> { status: idle|active|done|reject|wait, ms, detail }
  readonly property var stations: ["vad", "gate", "turn", "voiceid", "stt", "llm", "tts"]
  property var nodes: ({})
  // Last turn's timing {vad, turn, voiceid, stt, llm, total} and the last 20 totals.
  property var latency: null
  property var totals: []
  // who -> the last usage event (talker, thinker)
  property var usage: ({})

  // ----------------------------------------------------------------- tasks
  // Background jobs the talker started this session, newest last.
  property var tasks: []
  readonly property int running: {
    var n = 0
    for (var i = 0; i < tasks.length; i++) if (tasks[i].status === "start") n++
    return n
  }
  signal taskEvent(var ev)
  signal memoryEvent(var ev)

  // ------------------------------------------------------------ transcript
  // kind: you | ori | note | rule
  //   text      what was said (you) / every chunk Ori produced (ori)
  //   said      the lines Ori actually spoke so far (ori)
  //   cut       the line Ori was cut off in (ori, barge drop)
  //   source    "" for a reply to you, else the task kind it reports (ori)
  //   tone      note colour key: ignored | voiceid | barge | cut | skip | info
  ListModel { id: entriesModel }
  property alias entries: entriesModel
  property int youTurns: 0

  // Every non-meter event, newest last, for the debug log.
  ListModel { id: logModel }
  property alias events: logModel

  // ----------------------------------------------------------- internals
  property var turnIds: ({})
  property bool sawState: false
  property var pendingBg: []
  property int lastOri: -1          // index of the newest ori entry

  function clearSession() {
    entriesModel.clear()
    logModel.clear()
    m.tasks = []
    m.activity = []
    m.nodes = ({})
    m.latency = null
    m.totals = []
    m.usage = ({})
    m.turnIds = ({})
    m.pendingBg = []
    m.lastOri = -1
    m.youTurns = 0
    m.banner = ""
    m.bannerRead = ""
    m.sawState = false
  }

  function disconnected() {
    m.linked = false
    m.call = false
    m.mode = "closed"
    m.banner = ""
    m.bannerRead = ""
  }

  function now() { return Date.now() }

  function clock(ts) {
    var d = new Date(ts || Date.now())
    function p(n) { return n < 10 ? "0" + n : "" + n }
    return p(d.getHours()) + ":" + p(d.getMinutes())
  }

  // -------------------------------------------------------------- ingest
  // history: replayed on connect (?replay=1), not live. Same folding, but it
  // must not stamp "now" onto anything.
  function ingest(ev, history) {
    if (!ev || typeof ev !== "object") return
    m.linked = true
    var t = String(ev.t || "")
    if (t === "meter") { onMeter(ev); return }
    logEvent(ev)
    switch (t) {
    case "state": onState(ev, history); break
    case "stage": onStage(ev); break
    case "turn": onTurn(ev); break
    case "reply": onReply(ev); break
    case "voice": if (!history) onVoice(ev); break
    case "reply_style": entriesModel.setProperty(oriEntry(Number(ev.id), ev.lang), "style", String(ev.style || "")); break
    case "reply_end": onReplyEnd(ev); break
    case "silent": onSilent(ev); break
    case "speak": onSpeak(ev); break
    case "barge": onBarge(ev); break
    case "ignored": onIgnored(ev); break
    case "task": onTask(ev, history); break
    case "skills": if (!history) refreshSkills(); break
    case "bgtask": onBgTask(ev); break
    case "usage": onUsage(ev); break
    case "banner":
      m.banner = ev.text ? String(ev.text) : ""
      m.bannerProgress = ev.progress !== undefined && ev.progress !== null ? Number(ev.progress) : -1
      m.bannerRead = ev.text && ev.read ? String(ev.read) : ""
      break
    case "memory": if (!history) m.memoryEvent(ev); break
    case "plugin": onPlugin(ev, history); break
    case "drive": onDrive(ev, history); break
    }
  }

  // ------------------------------------------------------------ activity
  // What Ori did on the side, newest last: a plugin switching on/off, and an
  // action he performed in an app (`drive`). The Call tab shows the recent
  // ones; the Debug log has them all.
  //   {kind: "plugin"|"drive", text, ts, ok, by}
  property var activity: []
  function addActivity(a) {
    var l = m.activity.slice(); l.push(a)
    if (l.length > 30) l.shift()
    m.activity = l
  }
  function title(name) {
    var s = String(name || "").replace(/_/g, " ")
    return s.charAt(0).toUpperCase() + s.slice(1)
  }
  function onPlugin(ev, history) {
    var on = ev.active === true
    var by = String(ev.by || "")
    addActivity({ kind: "plugin", ts: ev.ts || now(), ok: on, by: by,
                  text: (on ? "turned on " : "turned off ") + title(ev.name)
                        + (by === "settings" ? " (Settings)" : "") })
  }

  // "pressed Ctrl+T in Zen". The engine's own sentence wins when it sends one.
  function keyName(k) {
    return String(k).split("+").map(function (p) {
      var t = p.trim()
      var low = t.toLowerCase()
      var named = ({ ctrl: "Ctrl", control: "Ctrl", alt: "Alt", shift: "Shift", super: "Super", meta: "Super",
                     cmd: "Super", enter: "Enter", "return": "Enter", esc: "Esc", escape: "Esc", tab: "Tab",
                     space: "Space", backspace: "Backspace", "delete": "Delete", up: "↑", down: "↓",
                     left: "←", right: "→", pageup: "PgUp", pagedown: "PgDn", home: "Home", end: "End" })[low]
      return named || (t.length === 1 ? t.toUpperCase() : title(t))
    }).join("+")
  }
  function driveText(ev) {
    var said = ev.say || ev.summary || ev.text_summary || ev.description
    var app = String(ev.app || ev.window || ev["class"] || "")
    var where = app !== "" ? " in " + title(app) : ""
    if (said) return String(said)
    var act = String(ev.action || ev.kind || ev.op || ev.tool || "").toLowerCase()
    var target = String(ev.target || ev.element || ev.label || ev.name || ev.url || "")
    var keys = ev.keys || ev.key || ev.combo
    if (keys !== undefined && keys !== null && (act === "" || act.indexOf("key") >= 0 || act === "press" || act === "hotkey"))
      return "pressed " + (Array.isArray(keys) ? keys.map(keyName).join(", ") : keyName(keys)) + where
    if (act.indexOf("type") >= 0 || act === "write")
      return "typed “" + String(ev.text || target).slice(0, 60) + "”" + where
    if (act.indexOf("click") >= 0) return "clicked " + (target || "at " + (ev.x !== undefined ? ev.x + "," + ev.y : "a spot")) + where
    if (act.indexOf("scroll") >= 0) return "scrolled" + (ev.direction ? " " + ev.direction : "") + where
    if (act === "open" || act === "launch" || act === "navigate" || act === "goto")
      return "opened " + (target || title(app))
    if (act === "focus" || act === "switch") return "switched to " + (target || title(app))
    if (act !== "") return act.replace(/_/g, " ") + (target ? " " + target : "") + where
    return "did something" + where
  }

  // Driving: Ori is working your apps right now. True while the engine says so
  // (state.driving, if it publishes it) or for a few seconds after the last
  // drive event. Esc in the panel posts stop_driving.
  property bool drivingState: false
  property real driveLast: 0
  property string driveLine: ""
  property bool driveRecent: false
  readonly property bool driving: m.drivingState || m.driveRecent
  readonly property int driveHoldMs: 6000
  Timer { id: driveTimer; interval: m.driveHoldMs; onTriggered: m.driveRecent = false }
  function onDrive(ev, history) {
    var ok = !(ev.ok === false || ev.error)
    var text = driveText(ev)
    addActivity({ kind: "drive", ts: ev.ts || now(), ok: ok, by: "", text: text + (ev.error ? "  (" + ev.error + ")" : "") })
    if (history) return
    m.driveLast = now()
    m.driveLine = text
    m.driveRecent = true
    driveTimer.restart()
  }
  function stopDriving() {
    cmd({ cmd: "stop_driving" })
    m.drivingState = false
    m.driveRecent = false
    driveTimer.stop()
  }

  function onMeter(ev) {
    var md = String(ev.mode || "")
    if (md !== "" && md !== m.mode) m.mode = md
    if (md === "closed") { if (m.call) m.call = false }
    else if (md !== "" && !m.call) m.call = true
    if (ev.sim !== undefined && ev.sim !== null) m.lastSim = Number(ev.sim)
    if (!m.watching) return
    m.level = Number(ev.level)
    m.floor = Number(ev.floor)
    m.vad = Number(ev.vad)
    m.silence = Number(ev.silence)
    m.sim = ev.sim === undefined || ev.sim === null ? -1 : Number(ev.sim)
    if (ev.spectrum) m.spectrum = ev.spectrum
  }

  function onState(ev, history) {
    // The first state of a connection is where we came in, not a change: a
    // call already open has an unknown start (the clock then says "In call"),
    // and it gets no "call opened" rule.
    var first = !m.sawState
    m.sawState = true
    if (ev.call !== undefined) {
      var open = ev.call === true
      if (open !== m.call) {
        m.callSince = open && !first ? (ev.ts || now()) : 0
        if (!first && entriesModel.count > 0)
          addEntry({ kind: "rule", text: open ? "call opened" : "call closed", at: clock(ev.ts) })
      }
      m.call = open
      if (!open) m.mode = "closed"
      else if (m.mode === "closed") m.mode = "listening"
    }
    if (ev.aec !== undefined) m.aec = ev.aec === true
    if (ev.enrolled !== undefined) m.enrolled = ev.enrolled === true
    if (ev.model !== undefined) m.model = String(ev.model)
    if (ev.lang !== undefined) m.lang = String(ev.lang)
    if (ev.tune) m.tune = ev.tune
    if (ev.settings !== undefined) { m.settings = ev.settings; m.pendingSet = ({}) }
    if (ev.options !== undefined) m.options = ev.options
    if (ev.people !== undefined) m.people = ev.people
    if (ev.driving !== undefined) m.drivingState = ev.driving === true
    if (m.enrollFor !== "" && m.call) { cmd({ cmd: "enroll", name: m.enrollFor }); m.enrollFor = "" }
  }

  function setNode(k, status, ms, detail) {
    var n = Object.assign({}, m.nodes)
    var cur = n[k] || {}
    n[k] = { status: status,
             ms: ms !== undefined && ms !== null ? ms : (status === "active" ? null : cur.ms),
             detail: detail !== undefined && detail !== null ? String(detail) : (status === "active" ? "" : (cur.detail || "")) }
    m.nodes = n
  }

  function onStage(ev) {
    var k = String(ev.name || ""), st = String(ev.status || "")
    if (m.stations.indexOf(k) < 0) return
    if (st === "start") {
      if (k === "vad") {
        var fresh = ({})
        fresh.gate = { status: "done", ms: null, detail: "loud enough" }
        fresh.vad = { status: "active", ms: null, detail: "" }
        m.nodes = fresh
        return
      }
      if (k === "llm") {
        var n = Object.assign({}, m.nodes)
        delete n.tts
        m.nodes = n
      }
      setNode(k, "active")
    } else if (st === "end") {
      setNode(k, "done", ev.ms, ev.detail)
    } else if (st === "reject") {
      setNode(k, k === "turn" ? "wait" : "reject", ev.ms, ev.detail)
    }
  }

  function addEntry(e) {
    var row = {
      kind: e.kind || "note", rid: e.rid !== undefined ? Number(e.rid) : -1,
      text: e.text || "", said: e.said || "", cut: e.cut || "",
      lang: e.lang || "", sim: e.sim !== undefined && e.sim !== null ? Number(e.sim) : -1,
      turnP: e.turnP !== undefined && e.turnP !== null ? Number(e.turnP) : -1,
      dur: e.dur !== undefined && e.dur !== null ? Number(e.dur) : -1,
      streaming: e.streaming === true, silent: e.silent === true,
      interrupted: e.interrupted === true, held: e.held === true,
      source: e.source || "", tone: e.tone || "", at: e.at || "", style: e.style || "",
      ms: e.ms !== undefined && e.ms !== null ? Number(e.ms) : -1
    }
    entriesModel.append(row)
    if (row.kind === "ori") m.lastOri = entriesModel.count - 1
    // A long day of calls stays bounded.
    if (entriesModel.count > 400) {
      entriesModel.remove(0, 100)
      m.lastOri -= 100
    }
  }

  function findEntry(kind, rid, reach) {
    var lo = Math.max(0, entriesModel.count - (reach || 40))
    for (var i = entriesModel.count - 1; i >= lo; i--) {
      var e = entriesModel.get(i)
      if (e.kind === kind && e.rid === rid) return i
    }
    return -1
  }

  function onTurn(ev) {
    var tid = Number(ev.id)
    var ids = Object.assign({}, m.turnIds); ids[tid] = true; m.turnIds = ids
    m.youTurns++
    addEntry({ kind: "you", rid: tid, text: String(ev.text || ""), lang: ev.lang || "en",
               sim: ev.sim, turnP: ev.turn_p, dur: ev.dur, at: clock(ev.ts) })
  }

  // The Ori entry for a reply id, made on its first chunk. A reply nobody
  // asked for (no turn with that id) is a background result coming back.
  function oriEntry(rid, lang) {
    var i = findEntry("ori", rid)
    if (i >= 0) return i
    var source = ""
    if (!m.turnIds[rid]) {
      if (m.pendingBg.length > 0) {
        var q = m.pendingBg.slice()
        var tid = q.shift()
        m.pendingBg = q
        var task = taskById(tid)
        source = task ? task.kind : "background"
      } else source = "background"
    }
    addEntry({ kind: "ori", rid: rid, lang: lang || "en", streaming: true, source: source })
    return entriesModel.count - 1
  }

  function onReply(ev) {
    var i = oriEntry(Number(ev.id), ev.lang)
    var e = entriesModel.get(i)
    var chunk = String(ev.chunk || "")
    entriesModel.setProperty(i, "text", e.text === "" ? chunk : e.text + " " + chunk)
    if (ev.lang) entriesModel.setProperty(i, "lang", String(ev.lang))
  }

  function onReplyEnd(ev) {
    var i = oriEntry(Number(ev.id), ev.lang)
    entriesModel.setProperty(i, "streaming", false)
    var e = entriesModel.get(i)
    if (e.text === "" && ev.text) entriesModel.setProperty(i, "text", String(ev.text))
    if (ev.event === true && e.source === "") entriesModel.setProperty(i, "source", "background")
    var tm = ev.timing || null
    if (tm && tm.total) {
      m.latency = tm
      entriesModel.setProperty(i, "ms", Number(tm.total))
      var t = m.totals.slice(); t.push(Number(tm.total))
      if (t.length > 20) t.shift()
      m.totals = t
    }
  }

  function onSilent(ev) {
    var i = findEntry("you", Number(ev.id), 20)
    if (i >= 0) { entriesModel.setProperty(i, "silent", true); return }
    if (m.pendingBg.length > 0) { var q = m.pendingBg.slice(); q.shift(); m.pendingBg = q }
    addEntry({ kind: "note", tone: "skip", text: "Ori skipped a background result that no longer mattered" })
  }

  function onSpeak(ev) {
    var i = m.lastOri
    if (i < 0 || i >= entriesModel.count) return
    var e = entriesModel.get(i)
    var line = String(ev.line || "")
    var st = String(ev.status || "")
    if (st === "start") {
      setNode("tts", "active", null, "speaking")
      if (e.said.indexOf(line) < 0)
        entriesModel.setProperty(i, "said", e.said === "" ? line : e.said + " " + line)
    } else if (st === "cut") {
      setNode("tts", "wait", null, "cut off")
      entriesModel.setProperty(i, "cut", line)
    } else if (st === "end") {
      setNode("tts", "done", null, "said it")
    }
  }

  function onBarge(ev) {
    var a = String(ev.action || "")
    var i = m.lastOri
    if (a === "hold") {
      setNode("tts", "wait", null, "paused for you")
      if (i >= 0) entriesModel.setProperty(i, "held", true)
      addEntry({ kind: "note", tone: "barge", text: "You started talking, so Ori paused" })
    } else if (a === "resume") {
      setNode("tts", "active", null, "carries on")
      addEntry({ kind: "note", tone: "info", text: (ev.detail ? String(ev.detail) : "nothing") + ", so Ori carried on" })
    } else if (a === "drop") {
      setNode("tts", "reject", null, "stopped")
      if (i >= 0) entriesModel.setProperty(i, "interrupted", true)
      addEntry({ kind: "note", tone: "cut", text: "You interrupted. Ori stopped and keeps only what you heard" })
    } else if (a === "continue") {
      addEntry({ kind: "note", tone: "info", text: "You weren't done, so Ori kept listening" })
    } else if (a === "yield") {
      addEntry({ kind: "note", tone: "info", text: "Ori paused to deliver a result" })
    }
  }

  function onIgnored(ev) {
    var r = String(ev.reason || ""), d = String(ev.detail || "")
    if (r === "voiceid") addEntry({ kind: "note", tone: "voiceid", text: "Not your voice (" + d + "), ignored" })
    else if (r === "gate") addEntry({ kind: "note", tone: "ignored", text: "Too quiet: " + d })
    else addEntry({ kind: "note", tone: "ignored", text: "“" + d + "” is just a backchannel, ignored" })
  }

  function taskById(id) {
    for (var i = 0; i < m.tasks.length; i++) if (m.tasks[i].id === id) return m.tasks[i]
    return null
  }

  function onTask(ev, history) {
    var id = String(ev.id || "")
    var list = m.tasks.slice()
    var t = null, at = -1
    for (var i = 0; i < list.length; i++) if (list[i].id === id) { t = list[i]; at = i; break }
    if (!t) {
      t = { id: id, kind: String(ev.kind || "task"), status: "start", args: ev.args || ({}),
            summary: "", ms: -1, t0: ev.ts || now(), t1: 0 }
    } else t = Object.assign({}, t)
    t.status = String(ev.status || t.status)
    if (ev.summary) t.summary = String(ev.summary)
    if (ev.ms !== undefined && ev.ms !== null) t.ms = Number(ev.ms)
    if (t.status === "done" || t.status === "error") {
      t.t1 = ev.ts || now()
      if (t.status === "done" && (t.kind === "think" || t.kind === "weather" || ev.kind === "timer")) {
        var q = m.pendingBg.slice(); q.push(id); m.pendingBg = q
      }
    }
    if (at >= 0) list[at] = t; else list.push(t)
    if (list.length > 40) list.shift()
    m.tasks = list
    if (!history) m.taskEvent(ev)
  }

  // ----------------------------------------------------------- background tasks
  // Ori's own background tasks (the engine's tasks plugin): its agentic loop running in a thread,
  // started by a long turn handing off or by the task tool. Fed only by "bgtask" events.
  property var bgtasks: []
  function onBgTask(ev) {
    var list = m.bgtasks.slice(), at = -1
    for (var i = 0; i < list.length; i++) if (list[i].id === ev.id) { at = i; break }
    var t = { id: String(ev.id || ""), state: String(ev.state || "running"), brief: String(ev.brief || ""),
              round: Number(ev.round || 0), origin: String(ev.origin || ""), result: String(ev.result || ""),
              ts: ev.ts || now() }
    if (at >= 0) list[at] = t; else list.push(t)
    if (list.length > 20) list.shift()
    m.bgtasks = list
  }
  function stopTask(id) { cmd({ cmd: "plugin", plugin: "tasks", action: "stop", id: id }) }

  function onUsage(ev) {
    var u = Object.assign({}, m.usage)
    u[String(ev.who || "talker")] = ev
    m.usage = u
  }

  // One line per event for the debug log.
  function summarize(ev) {
    switch (String(ev.t)) {
    case "state": return (ev.call ? "call open" : "call closed") + (ev.model ? "  " + ev.model : "")
                     + (ev.aec !== undefined ? "  aec " + (ev.aec ? "on" : "off") : "")
    case "stage": return ev.name + " " + ev.status + (ev.ms !== undefined && ev.ms !== null ? "  " + ev.ms + " ms" : "")
                     + (ev.detail ? "  " + ev.detail : "")
    case "turn": return "#" + ev.id + "  “" + ev.text + "”" + (ev.sim !== undefined && ev.sim !== null ? "  voice " + Number(ev.sim).toFixed(2) : "")
    case "reply": return "#" + ev.id + "  " + ev.chunk
    case "reply_end": return "#" + ev.id + (ev.timing && ev.timing.total ? "  " + ev.timing.total + " ms" : "") + (ev.event ? "  (event)" : "")
    case "silent": return "#" + ev.id + "  stayed silent"
    case "speak": return ev.status + "  " + ev.line
    case "barge": return ev.action + (ev.detail ? "  " + ev.detail : "")
    case "ignored": return ev.reason + "  " + (ev.detail || "")
    case "task": return ev.kind + " " + ev.status + (ev.summary ? "  " + ev.summary : (ev.args ? "  " + JSON.stringify(ev.args) : ""))
    case "usage": return ev.who + "  " + ev.prompt + " tok  " + Math.round((ev.hit || 0) * 100) + "% cached  " + ev.messages + " msgs"
    case "memory": return ev.action + (ev.summary ? "  " + ev.summary : "") + (ev.hits ? "  " + JSON.stringify(ev.hits) : "")
    case "banner": return ev.text ? String(ev.text) : "(cleared)"
    case "plugin": return ev.name + " " + (ev.active ? "on" : "off") + (ev.by ? "  by " + ev.by : "")
    case "drive": return driveText(ev) + (ev.ok === false || ev.error ? "  FAILED" + (ev.error ? ": " + ev.error : "") : "")
    case "log": return String(ev.text || "").trim()
    }
    var copy = Object.assign({}, ev); delete copy.t; delete copy.ts
    return JSON.stringify(copy)
  }

  function logEvent(ev) {
    logModel.append({ t: String(ev.t || "?"), ts: Number(ev.ts || now()), line: summarize(ev) })
    if (logModel.count > 600) logModel.remove(0, 100)
  }

  // ------------------------------------------------------------- commands
  // POST /cmd, the same dict the terminal UI sends. Fire and forget: the
  // daemon answers by emitting a fresh `state`, which comes back on the stream.
  function cmd(obj) {
    var p = procComp.createObject(m)
    p.command = ["sh", "-c",
      "p=$(cat \"$1\" 2>/dev/null); curl -s -m 3 -X POST -H 'Content-Type: application/json' -d \"$2\" \"http://127.0.0.1:${p:-8770}/cmd\" >/dev/null",
      "sh", m.portFile, JSON.stringify(obj)]
    p.exited.connect(function () { p.destroy() })
    p.running = true
  }
  Component { id: procComp; Process { } }
  function toggleCall() { cmd({ cmd: "toggle" }) }
  function openCall() { cmd({ cmd: "open" }) }
  function closeCall() { cmd({ cmd: "close" }) }
  function calibrate() { cmd({ cmd: "calibrate" }) }
  function enroll() { cmd({ cmd: "enroll" }) }
  function nudge(key, delta) { cmd({ cmd: "tune", key: key, delta: delta }) }
  function restartEngine() { cmd({ cmd: "restart" }) }
  // Without `sample`, the person goes; with it, only that recording.
  function forgetVoice(name, sample) {
    var c = { cmd: "forget_voice", name: name }
    if (sample !== undefined && sample !== null && sample >= 0) c.sample = sample
    cmd(c)
  }
  // Enrollment runs inside a call; a name already known gets another sample. With none open, open one and enroll once
  // the daemon says it is open.
  property string enrollFor: ""
  function enrollPerson(name) {
    if (m.call) cmd({ cmd: "enroll", name: name })
    else { m.enrollFor = name; openCall() }
  }
  // A plugin's mode as shown: a pending `set` first ("default" = its
  // default_mode), else what the engine says.
  function pluginMode(p) {
    var v = m.pendingSet["plugins." + p.name]
    if (v === "default") return String(p.default_mode || "on")
    if (v !== undefined) return String(v)
    return String(p.mode || p.default_mode || "on")
  }
  // A setting by dotted key ("voices.fr", "plugins.media"), pending value first.
  function setting(key) {
    if (m.pendingSet[key] !== undefined) return m.pendingSet[key]
    var v = m.settings
    var parts = String(key).split(".")
    for (var i = 0; i < parts.length; i++) {
      if (v === null || v === undefined || typeof v !== "object") return undefined
      v = v[parts[i]]
    }
    return v
  }
  function set(key, value) {
    var p = Object.assign({}, m.pendingSet); p[key] = value; m.pendingSet = p
    cmd({ cmd: "set", key: key, value: value })
  }
  // Hear a voice before picking it. Plays on its own, outside the call. One preview at a time:
  // each runs as its own process group (setsid) and first kills the previous one, curl /
  // pw-play / kokoro-npu children included, so switching or clicking ▶ again cuts it off at once.
  function runPreview(script, args) {
    var stop = "pf=\"${XDG_RUNTIME_DIR:-/tmp}/ori-voice-preview.pgid\"; "
             + "[ -f \"$pf\" ] && kill -TERM -- -\"$(cat \"$pf\")\" 2>/dev/null; echo $$ > \"$pf\"; "
    Quickshell.execDetached(["setsid", "sh", "-c", stop + script, "sh"].concat(args))
  }
  function stopPreview() { runPreview("", []) }
  function previewVoice(voice, espeak, line, speed) {
    // never while the Qwen NPU server holds the NPU: two NPU users at once is unsafe
    runPreview("ss -ltn | grep -q ':8095 ' && exit 0; exec kokoro-npu say --voice \"$1\" --lang \"$2\" --speed \"$3\" \"$4\"",
               [voice, espeak, String(speed || 1), line])
  }
  // A Qwen3-TTS speaker, streamed as it is generated (like a live line): you hear whether the
  // server keeps up -- gaps mean it is slower than real time right now.
  function previewQwen(voice, line, lang, design) {
    // through ears itself, the same path a call uses (Hebrew read via IPA, a designed voice by its
    // description); one at a time
    cmd({ cmd: "voice_preview", text: line, lang: lang || "en", voice: voice, design: design || "" })
  }


  // ---- a voice by description (the Qwen server designs it once, then caches it) ----
  // tryDesign: POST /design, poll until ready ("designing the voice…"), then say a line in it.
  property string designStatus: ""   // "" | designing | ready | error: <why>
  property string designText: ""
  property string designLang: "en"
  function httpJson(args, cb) {
    var p = skillProc.createObject(m)
    p.cb = cb || null
    p.command = ["curl", "-s", "-m", "10"].concat(args)
    p.running = true
  }
  // the languages the designer knows; Hebrew voices are designed as English ones (like bright)
  readonly property var designLangs: ["en", "fr", "es", "de", "it", "pt", "ru", "zh", "ja", "ko"]
  property string designFor: "en"  // the language the voice is FOR (the sample is said in it)
  // the designed voices the Qwen server keeps (GET /v1/audio/voices, kind "designed")
  property var designedVoices: []
  // what Ori is doing with its voice right now (the voice tool): designing / trial / kept / dropped / failed
  property var oriVoice: ({})
  function onVoice(ev) {
    m.oriVoice = { action: String(ev.action || ""), description: String(ev.description || ""),
                   language: String(ev.language || ""), name: String(ev.name || ""),
                   scope: String(ev.scope || ""), error: String(ev.error || ""), ts: ev.ts || now() }
    if (ev.action === "kept" || ev.action === "dropped" || ev.action === "failed") oriVoiceClear.restart()
  }
  Timer { id: oriVoiceClear; interval: 8000; onTriggered: m.oriVoice = ({}) }
  function refreshDesigned() {
    httpJson(["http://127.0.0.1:8095/v1/audio/voices"], function (j) {
      if (!j || !j.voices) return
      var d = j.voices.filter(function (v) { return v.kind === "designed" })
      d.sort(function (a, b) { return String(b.last_used || b.created).localeCompare(String(a.last_used || a.created)) })
      m.designedVoices = d
    })
  }
  function deleteDesigned(id) {
    httpJson(["-X", "DELETE", "http://127.0.0.1:8095/v1/audio/voices/design/" + id], function () { m.refreshDesigned() })
  }
  // native: the language the voice is designed as a native speaker of; hear: the sample's language
  function tryDesign(desc, native, line, hear) {
    m.designFor = hear || native
    var lang = designLangs.indexOf(native) >= 0 ? native : "en"
    m.designText = desc; m.designLang = lang; m.designStatus = "designing"
    httpJson(["-X", "POST", "-H", "Content-Type: application/json", "http://127.0.0.1:8095/v1/audio/voices/design",
              "-d", JSON.stringify({ voice_description: desc, voice_language: lang })], function (j) {
      if (!j || !j.id) {
        m.designStatus = "error: " + (j && j.error ? (j.error.message || j.error) : "the voice server didn't answer")
        return
      }
      designPoll.vid = j.id; designPoll.line = line; designPoll.tries = 0
      if (j.status === "cached" || j.status === "ready") designPoll.done(); else designPoll.start()
    })
  }
  Timer {
    id: designPoll
    property string vid: ""
    property string line: ""
    property int tries: 0
    interval: 800; repeat: true
    function done() {
      stop(); m.designStatus = "ready"
      m.cmd({ cmd: "voice_preview", text: line, lang: m.designFor, design: m.designText })
      m.refreshDesigned()
    }
    onTriggered: {
      if (++tries > 90) { stop(); m.designStatus = "error: the design took too long"; return }
      m.httpJson(["http://127.0.0.1:8095/v1/audio/voices/design/" + vid], function (j) {
        if (!designPoll.running || !j) return
        if (j.status === "ready" || j.status === "cached") designPoll.done()
        else if (j.status === "error") { designPoll.stop(); m.designStatus = "error: " + (j.error || "design failed") }
      })
    }
  }

  // Start the daemon when it is not running: the same launcher Hyprland
  // autostarts, in its own scope so a shell reload cannot take it down.
  function startDaemon() {
    Quickshell.execDetached(["systemd-run", "--user", "--scope", "--quiet",
                             Quickshell.env("HOME") + "/.local/bin/ori-ears"])
  }

  // ============================================================== on disk
  // Read on demand -- when the panel opens, when a tab that shows it opens,
  // and when an event says it changed (task, memory). Never on a timer.

  // ------------------------------------------------------------- workers
  // `dito worker list --all --json`. "Ori's" = the ids Ori itself started, kept by the
  // engine in ~/.local/state/ori-voice/workers.json -- NOT the whole dito registry,
  // which also holds his and Dito's workers. Stopped/dead entries are left out.
  property var workers: []
  property bool workersLoading: false
  property string workersError: ""
  readonly property int workersActive: {
    var n = 0
    for (var i = 0; i < workers.length; i++) if (workers[i].active) n++
    return n
  }

  function stateRank(s) {
    switch (s) {
    case "needs_input": case "waiting": case "blocked": case "question": return 0
    case "working": case "running": case "busy": return 1
    case "idle": return 2
    case "done": return 3
    default: return 4
    }
  }

  function refreshWorkers() {
    if (workerProc.running) return
    m.workersLoading = true
    workerProc.running = true
  }

  Process {
    id: workerProc
    // line 1: Ori's own ids (JSON array), line 2+: dito's list
    command: ["sh", "-c", "cat \"${ORI_VOICE_STATE:-$HOME/.local/state/ori-voice}/workers.json\" 2>/dev/null || echo '[]'; echo; dito worker list --all --json"]
    stdout: StdioCollector {
      onStreamFinished: {
        m.workersLoading = false
        try {
          var text = this.text
          var nl = text.indexOf("\n")
          var owned = []
          try { owned = JSON.parse(text.slice(0, nl)) } catch (e2) { owned = [] }
          var j = JSON.parse(text.slice(nl + 1))
          var out = []
          function add(list, inRegistry) {
            for (var i = 0; i < (list || []).length; i++) {
              var w = list[i]
              var st = String(w.state || "unknown")
              if (st === "stopped" || st === "dead") continue  // gone: nothing to manage
              var wid = String(w.id || "")
              var mine = owned.some(function (o) { return wid.indexOf(o) === 0 || o.indexOf(wid) === 0 })
              var dir = String(w.dir || w.cwd || "")
              var parts = dir.split("/")
              out.push({ id: String(w.id || ""), name: String(w.name || w.id || "?"),
                         state: String(w.state || "unknown"), subject: String(w.subject || ""),
                         dir: dir, repo: parts[parts.length - 1] || dir,
                         kind: String(w.kind || (inRegistry ? "managed" : "")), main: w.main === true,
                         pinned: w.pinned === true, mine: mine,
                         active: m.stateRank(String(w.state || "")) <= 2 })
            }
          }
          add(j.managed, true)
          add(j.foreign, false)
          out.sort(function (a, b) {
            if (a.mine !== b.mine) return a.mine ? -1 : 1
            if (a.pinned !== b.pinned) return a.pinned ? -1 : 1   // his pins first
            var r = m.stateRank(a.state) - m.stateRank(b.state)
            if (r !== 0) return r
            return a.name.localeCompare(b.name)
          })
          m.workers = out
          m.workersError = ""
        } catch (e) {
          m.workersError = "Could not read the worker list (dito worker list)."
        }
      }
    }
    stderr: StdioCollector { }
  }

  function openWorker(id) {
    Quickshell.execDetached(["kitty", "--title", "worker " + id, "-e", "dito", "worker", "tui", id])
  }
  function stopWorker(id, force) {
    if (stopProc.running) return
    stopProc.target = id
    stopProc.command = ["sh", "-c", "dito worker stop \"$1\" $2 2>&1", "sh", id, force ? "--force" : ""]
    stopProc.running = true
  }
  // What the last stop said, for the Work tab's hint line.
  property string workersNote: ""
  Process {
    id: stopProc
    property string target: ""
    property int code: -1
    property string out: ""
    property int parts: 0
    function report() {
      if (++parts < 2) return
      m.workersNote = code === 0 ? "Stopped " + target
                                 : "Could not stop " + target + ": " + (out || "exit " + code)
      m.refreshWorkers()
    }
    onStarted: { parts = 0; code = -1; out = "" }
    stdout: StdioCollector {
      onStreamFinished: { stopProc.out = String(this.text).replace(/\x1b\[[0-9;]*m/g, "").trim().split("\n")[0].trim(); stopProc.report() }
    }
    onExited: function (exitCode) { stopProc.code = exitCode; stopProc.report() }
  }

  // -------------------------------------------------------------- memory
  // profile.md is a FileView in the Memory tab (it edits it). This is the
  // rest: inbox/*.json, calls/*.json, memory/*.md -- the files memory.py
  // writes, parsed the way memory.py parses them.
  property var inbox: []
  property var calls: []
  property var memories: []
  property bool memoryLoaded: false

  readonly property string memPy: "
import glob, json, os, sys
S = os.path.expanduser('~/.local/state/ori-voice')
def fm(path):
    t = open(path, encoding='utf-8').read()
    head, body = {}, t
    if t.startswith('---'):
        parts = t.split('---', 2)
        if len(parts) == 3:
            _, h, body = parts
            for line in h.splitlines():
                if ':' in line:
                    k, v = line.split(':', 1)
                    head[k.strip()] = v.strip()
    return head, body.strip()
out = {'inbox': [], 'calls': [], 'memories': []}
for p in sorted(glob.glob(S + '/inbox/*.json')):
    try:
        j = json.load(open(p, encoding='utf-8'))
        out['inbox'].append({'id': os.path.basename(p)[:-5], 'name': str(j.get('name', '')),
                             'summary': str(j.get('summary', '')), 'body': str(j.get('body', j.get('summary', '')))})
    except Exception:
        pass
for p in sorted(glob.glob(S + '/calls/*.json'))[-30:][::-1]:
    try:
        j = json.load(open(p, encoding='utf-8'))
        out['calls'].append({'file': os.path.basename(p), 'when': str(j.get('when', '')),
                             'summary': str(j.get('summary', '')), 'topics': [str(x) for x in j.get('topics', [])],
                             'turns': j.get('turns', 0)})
    except Exception:
        pass
for p in sorted(glob.glob(S + '/memory/*.md')):
    try:
        h, b = fm(p)
        out['memories'].append({'file': os.path.basename(p), 'name': h.get('name', os.path.basename(p)[:-3]),
                                'summary': h.get('summary', ''), 'body': b, 'pinned': h.get('pinned', '') == 'true',
                                'modified': h.get('modified', h.get('created', ''))})
    except Exception:
        pass
out['memories'].sort(key=lambda x: x['modified'], reverse=True)
print(json.dumps(out, ensure_ascii=False))
"

  // Accept = exactly memory.py's Memory.write_memory(name, summary, body):
  // a kebab slug for the file name, the same five frontmatter keys, and an
  // existing file keeps its `created`. Then the inbox item is removed, as
  // t_memory_inbox does.
  readonly property string acceptPy: "
import json, os, re, sys, time
S = os.path.expanduser('~/.local/state/ori-voice')
iid = sys.argv[1]
src = os.path.join(S, 'inbox', iid + '.json')
it = json.load(open(src, encoding='utf-8'))
def slug(s):
    return re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')[:60] or 'note'
name = slug(it.get('name', iid))
summary = it.get('summary', '')
body = it.get('body', it.get('summary', ''))
os.makedirs(os.path.join(S, 'memory'), exist_ok=True)
path = os.path.join(S, 'memory', name + '.md')
today = time.strftime('%Y-%m-%d')
created = today
if os.path.exists(path):
    t = open(path, encoding='utf-8').read()
    m = re.search(r'^created:\\s*(.+)$', t, re.M)
    if m:
        created = m.group(1).strip()
open(path, 'w').write(f'---\\nname: {name}\\nsummary: {summary}\\npinned: false\\ncreated: {created}\\nmodified: {today}\\n---\\n{body.strip()}\\n')
os.remove(src)
print(name)
"

  function refreshMemory() {
    if (memProc.running) return
    memProc.running = true
  }

  Process {
    id: memProc
    command: ["python3", "-c", m.memPy]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var j = JSON.parse(this.text)
          m.inbox = j.inbox || []
          m.calls = j.calls || []
          m.memories = j.memories || []
          m.memoryLoaded = true
        } catch (e) { }
      }
    }
  }

  signal memoryNote(string text)

  // ------------------------------------------------------------- skills
  // Ori's playbooks (built-in + learned) and the drafts it wrote after calls, from the engine's
  // skills plugin (POST cmd "plugin"). Refreshed on open and on every "skills" event.
  property var skills: []        // [{name, description, learned, uses, last}]
  property var skillDrafts: []   // [{action: new|edit, name, description, why, body, when}]
  property bool skillsLoaded: false
  function skillsCmd(obj, cb) {
    var p = skillProc.createObject(m)
    p.cb = cb || null
    p.command = ["sh", "-c", "p=$(cat \"$1\" 2>/dev/null); curl -s -m 5 -X POST -H 'Content-Type: application/json' "
                 + "-d \"$2\" \"http://127.0.0.1:${p:-8770}/cmd\"", "sh", m.portFile,
                 JSON.stringify(Object.assign({ cmd: "plugin", plugin: "skills" }, obj))]
    p.running = true
  }
  Component {
    id: skillProc
    Process {
      id: sp
      property var cb: null
      stdout: StdioCollector {
        onStreamFinished: {
          var j = null
          try { j = JSON.parse(this.text) } catch (e) { }
          if (sp.cb) sp.cb(j)
          sp.destroy()
        }
      }
    }
  }
  function refreshSkills() {
    skillsCmd({ action: "list" }, function (j) {
      if (!j || !j.ok) return
      m.skills = j.skills || []
      m.skillDrafts = j.drafts || []
      m.skillsLoaded = true
    })
  }
  function skillAction(action, name) {  // keep | drop | forget
    skillsCmd({ action: action, name: name }, function (j) {
      m.memoryNote(j && j.ok ? ({ keep: "Kept " + name + " (from the next call)", drop: "Dropped " + name,
                                  forget: "Forgot " + name })[action]
                             : "Could not " + action + " " + name)
      m.refreshSkills()
    })
  }
  function skillText(name, cb) { skillsCmd({ action: "show", name: name }, function (j) { cb(j && j.ok ? j.text : "") }) }

  function acceptInbox(id) {
    var p = procComp.createObject(m)
    p.command = ["python3", "-c", m.acceptPy, id]
    p.exited.connect(function (code) {
      p.destroy()
      m.memoryNote(code === 0 ? "Saved to memory" : "Could not save that fact")
      m.refreshMemory()
    })
    p.running = true
  }
  // Delete one memory file (a wrong fact). The engine re-indexes on its next search.
  function forgetMemory(file) {
    if (!file || file.indexOf("/") >= 0) return
    var p = procComp.createObject(m)
    p.command = ["rm", "-f", m.stateDir + "/memory/" + file]
    p.exited.connect(function () { p.destroy(); m.memoryNote("Forgotten"); m.refreshMemory() })
    p.running = true
  }

  function rejectInbox(id) {
    var p = procComp.createObject(m)
    p.command = ["rm", "-f", m.stateDir + "/inbox/" + id + ".json"]
    p.exited.connect(function () { p.destroy(); m.memoryNote("Dropped"); m.refreshMemory() })
    p.running = true
  }

  // A saved call or a recalled memory can change what is on disk.
  onMemoryEvent: function (ev) { m.refreshMemory() }
  onTaskEvent: function (ev) { if (m.watching) m.refreshWorkers() }

  // ------------------------------------------------------------ voices
  // The daemon does not publish its voice table; read it from ears.py.
  property var voices: []
  readonly property string voicesPy: "
import ast, re, sys
t = open(sys.argv[1] + '/ears.py', encoding='utf-8').read()
v = re.search(r'^VOICES\\s*=\\s*(\\{.*?\\})\\s*$', t, re.M | re.S)
n = re.search(r'^LANG_NAMES\\s*=\\s*(\\{.*?\\})\\s*$', t, re.M | re.S)
voices = ast.literal_eval(v.group(1)) if v else {}
names = ast.literal_eval(n.group(1)) if n else {}
import json
print(json.dumps([{'lang': k, 'name': names.get(k, k), 'voice': val[0]} for k, val in voices.items()]))
"
  function refreshVoices() { if (!voiceProc.running) voiceProc.running = true }
  Process {
    id: voiceProc
    command: ["python3", "-c", m.voicesPy, m.earsDir]
    stdout: StdioCollector {
      onStreamFinished: { try { m.voices = JSON.parse(this.text) } catch (e) { } }
    }
  }

  // The tab the panel shows. Here, not on the panel: the panel is rebuilt on
  // every open and would forget.
  property string panelTab: "call"
  // The Settings tab's section, kept for the same reason.
  property string settingsSection: "voice"
}
