import QtQuick
import Quickshell
import ".."

// Settings: what the voice engine is and does, in five sections.
//
//   Voice      Ori's voice per language (hear one with Space/▶), and speed
//   Brain      the talker, the thinker, and what workers run on
//   People     the voices Ori knows, each with its samples; enroll more
//   Behaviour  the engine itself, how long a call can be resumed, and each
//              plugin's mode: On / Auto (optional ones: on demand) / Off
//   Tuning     the thresholds the ears decide by, and room calibration
//
// Every change is a POST /cmd (`set`, `tune`, `enroll`, `forget_voice`); the
// daemon answers with a fresh `state`, so what is shown is what the daemon
// uses. A `set` shows its value at once and is replaced by the daemon's.
// What the daemon does not publish yet is left out, not invented.
//
// Keys: [ ] (or PgUp/PgDn) switch section, up/down pick a row, left/right (or
// -/+) change it, Enter opens a list / steps a plugin's mode / adds a sample,
// Space plays a voice, Delete removes a person or sample (press again to
// confirm) or puts a plugin back to its default, Esc backs out.
FocusScope {
  id: set

  property int current: 0
  // the row whose option list is open ("" = none)
  property string openKey: ""
  // what Delete would remove: "name" or "name#n"; "" = nothing armed
  property string armed: ""
  // inside a person row: -1 the person, else a sample index
  property int sub: -1

  readonly property string section: EarsModel.settingsSection
  readonly property var st: EarsModel.settings
  readonly property var opt: EarsModel.options || ({})
  readonly property var tn: EarsModel.tune || ({})
  readonly property bool hasSettings: st !== null && st !== undefined && typeof st === "object"

  readonly property var langNames: ({ en: "English", fr: "French", es: "Spanish", it: "Italian", pt: "Portuguese", he: "Hebrew",
                                      hi: "Hindi", ja: "Japanese", zh: "Chinese" })
  readonly property var hello: ({ he: "שלום, אני אורי.", en: "Hi, I'm Ori.", fr: "Bonjour, je suis Ori.", es: "Hola, soy Ori.",
                                  it: "Ciao, sono Ori.", pt: "Oi, eu sou a Ori.", hi: "Namaste, main Ori hoon.",
                                  ja: "Konnichiwa, Ori desu.", zh: "Ni hao, wo shi Ori.",
                                  he: "שלום, אני אורי. במה אוכל לעזור?" })
  function paceFor(lang) {
    var sp = EarsModel.setting("speed") || 1
    return lang === "he" ? sp * (EarsModel.setting("hebrew_speed") || 1) : sp
  }
  function espeak(lang, voice) {
    if (lang === "en") return String(voice).charAt(0) === "b" ? "en-gb" : "en-us"
    return ({ fr: "fr-fr", es: "es", it: "it", pt: "pt-br", hi: "hi", ja: "ja", zh: "cmn" })[lang] || lang
  }
  // af_heart -> Heart; the prefix says accent and sex, worth keeping only for English
  function voiceName(id) {
    var s = String(id || "")
    var u = s.indexOf("_")
    if (u === 2) s = s.slice(3)  // a kokoro id: the prefix is accent + sex
    return s.split("_").map(function (w) { return w.charAt(0).toUpperCase() + w.slice(1) }).join(" ")
  }
  function voiceHint(id) {
    var s = String(id || "")
    if (s.indexOf("he_") === 0) return "Hebrew-tuned"
    if (s.length < 3 || s.charAt(2) !== "_") return ""
    var sex = s.charAt(1) === "f" ? "female" : s.charAt(1) === "m" ? "male" : ""
    var acc = s.charAt(0) === "a" ? "US " : s.charAt(0) === "b" ? "UK " : ""
    return acc + sex
  }

  // ------------------------------------------------------------ sections
  readonly property var sections: {
    var out = [{ k: "voice", label: "Voice" }]
    if (hasSettings && EarsModel.setting("tts") === "qwen")
      out.push({ k: "voices", label: "Voices", n: Object.keys(EarsModel.setting("voice_library") || ({})).length })
    if (hasSettings) out.push({ k: "brain", label: "Brain" })
    out.push({ k: "people", label: "People", n: EarsModel.people ? EarsModel.people.length : -1 })
    out.push({ k: "behaviour", label: "Behaviour" })
    out.push({ k: "tuning", label: "Tuning" })
    return out
  }
  function go(k) {
    EarsModel.settingsSection = k
    set.current = 0; set.openKey = ""; set.armed = ""; set.sub = -1
    flick.contentY = 0
    if (k === "voices") EarsModel.refreshDesigned()
  }
  function stepSection(d) {
    var ks = sections.map(function (s) { return s.k })
    var i = ks.indexOf(section)
    go(ks[((i < 0 ? 0 : i) + d + ks.length) % ks.length])
  }
  Component.onCompleted: {
    EarsModel.refreshVoices()
    if (sections.map(function (s) { return s.k }).indexOf(section) < 0) go("voice")
    forceActiveFocus()
  }

  // ---------------------------------------------------------------- rows
  // t: choice | num | tune | plugin | person | enroll
  readonly property var tuneGroups: [
    { title: "Hearing you", rows: [
      { k: "gate", label: "Loudness gate", help: "Quieter sounds are ignored", step: 2, unit: " dB", dp: 0 },
      { k: "vad", label: "Speech confidence", help: "How sure it must be that a sound is speech", step: 0.05, unit: "", dp: 2 },
      { k: "pause", label: "Pause", help: "Silence before it asks whether you finished", step: 0.05, unit: " s", dp: 2 },
      { k: "turn", label: "Finished?", help: "How sure it must be that you finished", step: 0.05, unit: "", dp: 2 },
      { k: "max_wait", label: "Longest wait", help: "Replies anyway after this much silence", step: 0.25, unit: " s", dp: 2 }
    ] },
    { title: "Your voice", rows: [
      { k: "id", label: "Voice match", help: "Needed for a turn to count as you", step: 0.05, unit: "", dp: 2 },
      { k: "id_barge", label: "Match to interrupt", help: "Needed to cut Ori off mid-sentence", step: 0.05, unit: "", dp: 2 }
    ] },
    { title: "Interrupting", rows: [
      { k: "barge_db", label: "Gate while Ori talks", help: "The gate drops this much so you can cut in", step: 1, unit: " dB", dp: 0 },
      { k: "hold", label: "Grace", help: "Waits this long when unsure you finished", step: 0.1, unit: " s", dp: 2 },
      { k: "sure", label: "Sure enough", help: "Above this, no grace: reply at once", step: 0.05, unit: "", dp: 2 }
    ] },
    { title: "Tools", rows: [
      { k: "inline_s", label: "Wait for a tool", help: "Slower tools finish in the background", step: 0.1, unit: " s", dp: 1 }
    ] }
  ]

  readonly property var rows: {
    var out = [], i, k
    var s = set.section
    if (s === "voice") {
      var ov = set.opt.voices || ({})
      var engine = EarsModel.setting("tts") || "kokoro"
      if (set.hasSettings && set.st.tts !== undefined)
        out.push({ t: "choice", key: "tts", label: "Voice engine", help: engine === "qwen"
                     ? "Qwen3-TTS: one voice for every language, Hebrew included"
                     : "Kokoro: a voice per language",
                   opts: set.opt.tts_engines || ["kokoro", "qwen"] })
      if (engine.indexOf("qwen") === 0 && set.hasSettings && set.st.qwen_voice !== undefined) {
        out.push({ t: "choice", voice: true, qwen: true, key: "qwen_voice", lang: "all",
                   label: "Ori's voice", opts: set.opt.qwen_voices || [] })
        // a language may speak with its own Qwen voice (fr -> fr_paris, a native French one);
        // "–" = Ori's voice above, "default" clears an override
        var ql = set.st.voices ? Object.keys(set.st.voices) : []
        for (i = 0; i < ql.length; i++)
          out.push({ t: "choice", voice: true, qwen: true, key: "qwen_voices." + ql[i], lang: ql[i],
                     label: set.langNames[ql[i]] || ql[i], opts: ["default"].concat(set.opt.qwen_voices || []) })
      } else if (set.hasSettings && set.st.voices) {
        var langs = Object.keys(set.st.voices)
        for (i = 0; i < langs.length; i++) {
          k = langs[i]
          out.push({ t: "choice", voice: true, key: "voices." + k, lang: k,
                     label: set.langNames[k] || k, opts: ov[k] || [] })
        }
      } else {
        // An older daemon: the table in ears.py, read-only but playable.
        for (i = 0; i < EarsModel.voices.length; i++) {
          var v = EarsModel.voices[i]
          out.push({ t: "choice", voice: true, key: "", fixed: v.voice, lang: v.lang, label: v.name, opts: [] })
        }
      }
      if (set.hasSettings && set.st.speed !== undefined)
        out.push({ t: "num", key: "speed", label: "Speed", help: "How fast Ori talks, in every language",
                   step: 0.05, min: 0.5, max: 2, dp: 2, unit: "×" })
      if (set.hasSettings && set.st.hebrew_speed !== undefined)
        out.push({ t: "num", key: "hebrew_speed", label: "Hebrew pace", help: "× Speed on Hebrew lines (he_heart already reads slower)",
                   step: 0.05, min: 0.5, max: 2, dp: 2, unit: "×" })
      if (set.hasSettings && set.st.hebrew !== undefined)
        out.push({ t: "choice", toggle: true, key: "hebrew", label: "Hear Hebrew",
                   help: "A second speech model for Hebrew turns (~1 GB RAM)", opts: [false, true] })
    } else if (s === "voices") {
      // design a voice by description, and manage the ones the server keeps
      out.push({ t: "design", key: "design" })
      var lib = EarsModel.setting("voice_library") || ({})
      for (k in lib) out.push({ t: "designed", key: "d:" + k, name: k, d: lib[k] })
    } else if (s === "brain") {
      var models = set.opt.models || []
      if (set.st.model !== undefined)
        out.push({ t: "choice", key: "model", label: "Talker", help: "Answers you; fast matters most", opts: models })
      if (set.st.thinker_model !== undefined)
        out.push({ t: "choice", key: "thinker_model", label: "Thinker", help: "Takes the questions that need a real think", opts: models })
      if (set.st.task_model !== undefined)
        out.push({ t: "choice", key: "task_model", label: "Task model", help: "Runs background tasks while Ori keeps talking", opts: models })
      if (set.st.task_effort !== undefined)
        out.push({ t: "choice", key: "task_effort", label: "Task thinking", help: "How hard background tasks think",
                   opts: set.opt.efforts || ["low", "medium", "high"] })
      if (set.st.worker_provider !== undefined)
        out.push({ t: "choice", key: "worker_provider", label: "Workers run on", help: "Where coding workers get their model",
                   opts: set.opt.worker_providers || [] })
      if (set.st.worker_model !== undefined) {
        var wm = set.opt.worker_models || ({})
        out.push({ t: "choice", key: "worker_model", label: "Worker model", help: "What new workers start with",
                   opts: wm[EarsModel.setting("worker_provider")] || [] })
      }
    } else if (s === "people") {
      var ppl = EarsModel.people || []
      for (i = 0; i < ppl.length; i++) out.push({ t: "person", p: ppl[i], key: "person:" + ppl[i].name })
      if (EarsModel.people) out.push({ t: "enroll", key: "enroll" })
    } else if (s === "behaviour") {
      if (set.hasSettings && set.st.resume_minutes !== undefined)
        out.push({ t: "num", key: "resume_minutes", label: "Pick up where we left off",
                   help: "A call within this many minutes continues the last one", step: 1, min: 0, max: 240, dp: 0, unit: " min" })
      // Core first, then optional; the engine's order inside each.
      var pl = set.opt.plugins || []
      var groups = [{ title: "Core plugins", core: true }, { title: "Optional plugins", core: false }]
      for (var gi = 0; gi < groups.length; gi++) {
        var first = true
        for (i = 0; i < pl.length; i++) {
          if ((pl[i].core !== false) !== groups[gi].core) continue
          out.push({ t: "plugin", key: "plugins." + pl[i].name, p: pl[i],
                     label: pl[i].name.charAt(0).toUpperCase() + pl[i].name.slice(1).replace(/_/g, " "),
                     help: pl[i].description || "", group: first ? groups[gi].title : "" })
          first = false
        }
      }
    } else if (s === "tuning") {
      for (var g = 0; g < set.tuneGroups.length; g++)
        for (var r = 0; r < set.tuneGroups[g].rows.length; r++) {
          var tr = Object.assign({ t: "tune", group: r === 0 ? set.tuneGroups[g].title : "" }, set.tuneGroups[g].rows[r])
          tr.key = "tune." + tr.k
          out.push(tr)
        }
    }
    return out
  }
  onRowsChanged: if (current >= rows.length) current = Math.max(0, rows.length - 1)
  onCurrentChanged: { set.armed = ""; set.sub = -1; Qt.callLater(set.reveal) }

  function value(row) {
    if (row.t === "tune") return set.tn[row.k]
    if (row.t === "plugin") return EarsModel.pluginMode(row.p)
    if (row.fixed !== undefined) return row.fixed
    return EarsModel.setting(row.key)
  }
  function change(row, d) {
    if (!row || !EarsModel.linked) return
    if (row.t === "tune") {
      if (set.tn[row.k] !== undefined) EarsModel.nudge(row.k, Math.round(row.step * d * 1000) / 1000)
    } else if (row.t === "num") {
      var v = Number(value(row))
      if (isNaN(v)) return
      var n = Math.round((v + row.step * d) / row.step) * row.step
      n = Math.max(row.min, Math.min(row.max, n))
      EarsModel.set(row.key, Number(n.toFixed(row.dp)))
    } else if (row.t === "choice") {
      if (!row.key || row.opts.length === 0) return
      var i = row.opts.indexOf(value(row))
      var next = row.opts[((i < 0 ? 0 : i + d) + row.opts.length) % row.opts.length]
      if (next !== value(row)) EarsModel.set(row.key, next)
    } else if (row.t === "plugin") {
      var ms = set.modesOf(row.p)
      if (ms.length < 2) return
      var at = ms.indexOf(value(row))
      var nx = Math.max(0, Math.min(ms.length - 1, (at < 0 ? 0 : at) + d))
      if (ms[nx] !== value(row)) set.setMode(row.p, ms[nx])
    } else if (row.t === "person") {
      var ns = (row.p.samples || []).length
      set.sub = Math.max(-1, Math.min(ns - 1, set.sub + d))
      set.armed = ""
    }
  }
  // The modes a plugin can be put in: none for a required one (always on),
  // on/off for core (auto = on there), on/auto/off for an optional one.
  function modesOf(p) {
    if (!p || p.required === true) return []
    return p.core === false ? ["on", "auto", "off"] : ["on", "off"]
  }
  // Picking the default mode drops the override rather than pinning it.
  function setMode(p, mode) {
    if (!EarsModel.linked) return
    EarsModel.set("plugins." + p.name, mode === p.default_mode ? "default" : mode)
  }
  function modeWord(mode) { return ({ on: "On", auto: "Auto", off: "Off" })[mode] || String(mode) }
  function preview(row) {
    var v = value(row)
    if (!v) return
    if (row.qwen) {  // the row's own language (Hebrew needs IPA routing: the English line instead)
      var qv = v === "default" || !v ? EarsModel.setting("qwen_voice") : v
      EarsModel.previewQwen(qv, set.hello[row.lang] || set.hello.en, row.lang === "all" ? "en" : row.lang, ""); return
    }
    EarsModel.previewVoice(v, espeak(row.lang, v), set.hello[row.lang] || set.hello.en, set.paceFor(row.lang))
  }
  // Delete: arm, then confirm.
  function remove(row) {
    if (row && row.t === "plugin") { if (EarsModel.pluginMode(row.p) !== row.p.default_mode) set.setMode(row.p, row.p.default_mode); return }
    if (!row || row.t !== "person") return
    var smp = row.p.samples || []
    var target = set.sub >= 0 && set.sub < smp.length ? row.p.name + "#" + smp[set.sub].n : row.p.name
    if (set.armed === target) {
      if (set.sub >= 0 && set.sub < smp.length) EarsModel.forgetVoice(row.p.name, smp[set.sub].n)
      else EarsModel.forgetVoice(row.p.name)
      set.armed = ""; set.sub = -1
    } else set.armed = target
  }
  function activate(row) {
    if (!row) return
    if (row.t === "choice" && row.toggle) set.change(row, 1)  // on/off: a press flips it, no list
    else if (row.t === "choice") { if (row.opts.length > 0) set.openKey = set.openKey === row.key ? "" : row.key }
    else if (row.t === "plugin") {
      // Enter steps round: On -> Auto -> Off -> On
      var ms = set.modesOf(row.p)
      if (ms.length > 1) set.setMode(row.p, ms[(ms.indexOf(value(row)) + 1) % ms.length])
    }
    else if (row.t === "person") { if (set.armed !== "") remove(row); else EarsModel.enrollPerson(row.p.name) }
    else if (row.t === "enroll") rowsRep.itemAt(set.current).focusName()
  }
  function reveal() {
    var it = rowsRep.itemAt(set.current)
    if (!it) return
    var y = it.mapToItem(col, 0, 0).y
    if (y < flick.contentY) flick.contentY = Math.max(0, y - 30)
    else if (y + it.height > flick.contentY + flick.height) flick.contentY = y + it.height - flick.height + 12
  }

  Keys.onPressed: function (e) {
    var row = set.rows[set.current]
    if (e.key === Qt.Key_BracketRight || e.key === Qt.Key_PageDown) { set.stepSection(1); e.accepted = true }
    else if (e.key === Qt.Key_BracketLeft || e.key === Qt.Key_PageUp) { set.stepSection(-1); e.accepted = true }
    else if (e.key === Qt.Key_Down || e.key === Qt.Key_J) { set.current = Math.min(set.rows.length - 1, set.current + 1); e.accepted = true }
    else if (e.key === Qt.Key_Up || e.key === Qt.Key_K) { set.current = Math.max(0, set.current - 1); e.accepted = true }
    else if (e.key === Qt.Key_Right || e.key === Qt.Key_Plus || e.key === Qt.Key_Equal) { set.change(row, 1); e.accepted = true }
    else if (e.key === Qt.Key_Left || e.key === Qt.Key_Minus) { set.change(row, -1); e.accepted = true }
    else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { set.activate(row); e.accepted = true }
    else if (e.key === Qt.Key_Space && row && row.voice) { set.preview(row); e.accepted = true }
    else if (e.key === Qt.Key_Delete || e.key === Qt.Key_Backspace) { set.remove(row); e.accepted = true }
    else if (e.key === Qt.Key_Escape && (set.openKey !== "" || set.armed !== "")) { set.openKey = ""; set.armed = ""; e.accepted = true }
  }

  // -------------------------------------------------------------- sub-nav
  Row {
    id: seg
    anchors { left: parent.left; top: parent.top; leftMargin: 16; topMargin: 12 }
    spacing: 6
    Repeater {
      model: set.sections
      Rectangle {
        id: pill
        required property var modelData
        readonly property bool on: set.section === modelData.k
        width: segText.implicitWidth + (segN.visible ? segN.implicitWidth + 7 : 0) + 22
        height: 30
        radius: 15
        color: on ? Theme.alpha(Theme.accent, 0.16) : segArea.containsMouse ? Theme.alpha(Theme.surface0, 0.5) : Theme.transparent
        border.width: 1
        border.color: on ? Theme.alpha(Theme.accent, 0.5) : Theme.alpha(Theme.overlay0, 0.25)
        Row {
          anchors.centerIn: parent
          spacing: 7
          Text {
            id: segText
            text: pill.modelData.label
            color: pill.on ? Theme.text : Theme.subtext0
            font.family: RoomLook.sans
            font.pixelSize: RoomLook.meta
            font.weight: pill.on ? Font.DemiBold : Font.Medium
            renderType: Text.QtRendering
          }
          Text {
            id: segN
            visible: pill.modelData.n !== undefined && pill.modelData.n > 0
            text: String(pill.modelData.n)
            color: Theme.overlay0
            font.family: RoomLook.mono
            font.pixelSize: RoomLook.small
            renderType: Text.QtRendering
          }
        }
        MouseArea {
          id: segArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: { set.go(pill.modelData.k); set.forceActiveFocus() }
        }
      }
    }
  }

  Flickable {
    id: flick
    anchors { left: parent.left; right: parent.right; top: seg.bottom; bottom: parent.bottom; topMargin: 8 }
    contentHeight: col.implicitHeight + 24
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: col
      x: 16
      y: 4
      width: flick.width - 32
      spacing: 0

      // ---------------------------------------------- section lead blocks
      // Behaviour: the engine itself.
      Column {
        visible: set.section === "behaviour"
        width: parent.width
        spacing: 8
        bottomPadding: 14
        Grid {
          columns: 2
          columnSpacing: 18
          rowSpacing: 6
          topPadding: 4
          Text { text: "Engine"; color: Theme.overlay0; font.family: RoomLook.sans; font.pixelSize: RoomLook.meta }
          Text {
            text: !EarsModel.linked ? "not running" : EarsModel.call ? "in a call" : "ready, no call"
            color: !EarsModel.linked ? Theme.red : EarsModel.call ? Theme.sapphire : Theme.text
            font.family: RoomLook.sans; font.pixelSize: RoomLook.meta
          }
          Text { text: "Echo cancelling"; color: Theme.overlay0; font.family: RoomLook.sans; font.pixelSize: RoomLook.meta }
          Text {
            text: EarsModel.aec ? "on" : EarsModel.call ? "off" : "on during calls"
            color: EarsModel.aec ? Theme.green : Theme.subtext0
            font.family: RoomLook.sans; font.pixelSize: RoomLook.meta
          }
          Text { visible: !set.hasSettings; text: "Talker"; color: Theme.overlay0; font.family: RoomLook.sans; font.pixelSize: RoomLook.meta }
          Text { visible: !set.hasSettings; text: EarsModel.model || "–"; color: Theme.text; font.family: RoomLook.mono; font.pixelSize: RoomLook.meta }
        }
        Row {
          spacing: 8
          RoomButton {
            text: EarsModel.linked ? (EarsModel.call ? "End call" : "Start call") : "Start voice"
            kind: EarsModel.linked && EarsModel.call ? "danger" : "primary"
            tint: Theme.sapphire
            onClicked: EarsModel.linked ? EarsModel.toggleCall() : EarsModel.startDaemon()
          }
          RoomButton {
            visible: EarsModel.linked && set.hasSettings
            text: "Restart engine"
            onClicked: EarsModel.restartEngine()
          }
        }
      }

      // Tuning: calibration first, it sets several of the numbers below.
      Item {
        visible: set.section === "tuning"
        width: parent.width
        height: visible ? calRow.height + 16 : 0
        RoomButton {
          id: calRow
          y: 2
          text: "Calibrate room"
          enabled: EarsModel.linked && EarsModel.call
          onClicked: EarsModel.calibrate()
        }
        Text {
          anchors { left: calRow.right; leftMargin: 12; right: parent.right; verticalCenter: calRow.verticalCenter }
          text: EarsModel.call ? "Measures the room's noise for 5 seconds. Stay quiet; a TV on is fine."
                               : "Open a call to calibrate: it listens to the room for 5 seconds."
          color: Theme.overlay0
          wrapMode: Text.Wrap
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.small
        }
      }

      // People, on a daemon that does not list them yet.
      Column {
        visible: set.section === "people" && !EarsModel.people
        width: parent.width
        spacing: 10
        topPadding: 4
        Text {
          text: EarsModel.enrolled ? "Your voice is enrolled." : "No voice enrolled yet, so anyone's voice counts as you."
          color: EarsModel.enrolled ? Theme.green : Theme.yellow
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.meta + 1
        }
        RoomButton { text: "Enroll my voice"; enabled: EarsModel.linked && EarsModel.call; onClicked: EarsModel.enroll() }
        Text {
          width: parent.width
          text: "Enrolling learns a voice from about 20 seconds of talking, during a call."
          color: Theme.overlay0
          wrapMode: Text.Wrap
          font.family: RoomLook.sans
          font.pixelSize: RoomLook.small
        }
      }

      // ------------------------------------------------------------- rows
      Repeater {
        id: rowsRep
        model: set.rows
        delegate: Item {
          id: rw
          required property var modelData
          required property int index
          readonly property var r: modelData
          readonly property bool on: set.current === index
          readonly property var v: set.value(r)
          readonly property bool listOpen: set.openKey !== "" && set.openKey === r.key
          readonly property bool usable: EarsModel.linked && (r.t !== "choice" || (r.key !== "" && r.opts.length > 0))
          readonly property bool hasHelp: r.help !== undefined && r.help !== ""
          // plugin rows
          readonly property bool pActive: r.t === "plugin" && r.p.active === true
          readonly property bool pChanged: r.t === "plugin" && v !== r.p.default_mode
          readonly property string pStateWord: r.t !== "plugin" ? ""
            : pActive ? "active now"
            : v === "auto" ? "when needed"
            : v === "off" ? "off" : "not running"
          readonly property color pStateColor: pActive ? Theme.green : v === "off" ? Theme.overlay0 : Theme.subtext0
          function focusName() { nameIn.forceActiveFocus() }

          width: col.width
          height: groupHead.height + box.height + 2

          Text {
            id: groupHead
            width: parent.width
            height: rw.r.group ? implicitHeight + (rw.index > 0 ? 16 : 4) : 0
            visible: !!rw.r.group
            verticalAlignment: Text.AlignBottom
            bottomPadding: 6
            text: rw.r.group || ""
            color: Theme.subtext1
            font.family: RoomLook.sans
            font.pixelSize: RoomLook.meta
            font.weight: Font.DemiBold
          }

          Rectangle {
            id: box
            anchors.top: groupHead.bottom
            width: parent.width
            height: body.height + (opts.visible ? opts.height + 10 : 0)
                    + (samples.visible ? samples.height + 8 : 0)
            radius: RoomLook.radius
            color: rw.on ? Theme.alpha(Theme.surface0, 0.5) : Theme.transparent
            border.width: rw.on && set.activeFocus ? 1 : 0
            border.color: Theme.alpha(Theme.accent, 0.35)

            MouseArea { anchors.fill: parent; onClicked: { set.current = rw.index; set.forceActiveFocus() } }

            Item {
              id: body
              width: parent.width
              height: rw.r.t === "design" ? 104 : rw.r.t === "designed" ? 100 : rw.r.t === "enroll" ? 52 : rw.hasHelp || rw.r.t === "person" ? 48 : 38

              // ------------------------------------------------ the label
              Row {
                id: lead
                anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                spacing: 8
                visible: rw.r.t !== "enroll" && rw.r.t !== "design" && rw.r.t !== "designed"
                Rectangle {
                  visible: rw.r.voice === true
                  anchors.verticalCenter: parent.verticalCenter
                  width: 26; height: 18; radius: 5
                  color: Theme.alpha(Theme.overlay0, 0.14)
                  Text {
                    anchors.centerIn: parent
                    text: rw.r.lang || ""
                    color: Theme.subtext0
                    font.family: RoomLook.mono
                    font.pixelSize: RoomLook.small - 1
                  }
                }
                // a plugin: lit while it is in use right now
                Rectangle {
                  visible: rw.r.t === "plugin"
                  anchors.verticalCenter: parent.verticalCenter
                  width: 8; height: 8; radius: 4
                  color: rw.pActive ? Theme.green : Theme.transparent
                  border.width: rw.pActive ? 0 : 1
                  border.color: Theme.alpha(Theme.overlay0, 0.6)
                  Behavior on color { ColorAnimation { duration: Style.anim.quick } }
                }
                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 2
                  width: Math.max(0, ctl.x - lead.x - 12 - (rw.r.voice === true ? 34 : 0) - (rw.r.t === "plugin" ? 16 : 0))
                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: rw.r.t === "plugin" ? Text.StyledText : Text.PlainText
                    text: rw.r.t === "person" ? rw.r.p.name
                        : rw.r.t === "plugin" ? RoomLook.esc(rw.r.label) + "&nbsp;&nbsp;<font color=\"" + rw.pStateColor + "\" size=\"2\">"
                                                + rw.pStateWord + "</font>"
                        : (rw.r.label || "")
                    color: Theme.text
                    font.family: RoomLook.sans
                    font.pixelSize: RoomLook.body - 1
                    font.weight: rw.r.t === "person" ? Font.DemiBold : Font.Normal
                  }
                  Text {
                    width: parent.width
                    visible: text !== ""
                    elide: Text.ElideRight
                    text: rw.r.t === "person" ? peopleMeta(rw.r.p) : (rw.r.help || "")
                    color: Theme.overlay0
                    font.family: RoomLook.sans
                    font.pixelSize: RoomLook.small
                    function peopleMeta(p) {
                      var n = (p.samples || []).length
                      return n + (n === 1 ? " sample" : " samples") + ", since " + set.day(p.created)
                    }
                  }
                }
              }

              // --------------------------------------------- the control
              Row {
                id: ctl
                anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                spacing: 6
                visible: rw.r.t !== "enroll" && rw.r.t !== "design" && rw.r.t !== "designed"

                // choice: ‹ value ›, the value opens the list
                RoomButton {
                  visible: rw.r.t === "choice" || rw.r.t === "num" || rw.r.t === "tune"
                  compact: true; width: 30
                  text: rw.r.t === "choice" ? "‹" : "−"
                  enabled: rw.usable && rw.v !== undefined
                  activeFocusOnTab: false
                  onClicked: { set.current = rw.index; set.change(rw.r, -1) }
                }
                Rectangle {
                  visible: rw.r.t === "choice"
                  anchors.verticalCenter: parent.verticalCenter
                  width: rw.r.voice ? 132 : 188
                  height: 26
                  radius: 13
                  color: rw.listOpen ? Theme.alpha(Theme.accent, 0.14) : valArea.containsMouse && rw.usable ? Theme.alpha(Theme.surface1, 0.5) : Theme.transparent
                  border.width: 1
                  border.color: rw.listOpen ? Theme.alpha(Theme.accent, 0.45) : Theme.alpha(Theme.overlay0, 0.25)
                  Row {
                    anchors.centerIn: parent
                    spacing: 6
                    width: Math.min(implicitWidth, parent.width - 16)
                    Text {
                      id: valT
                      text: rw.v === undefined ? "–" : rw.r.voice ? set.voiceName(rw.v) : rw.r.toggle ? (rw.v ? "on" : "off") : String(rw.v)
                      color: Theme.text
                      elide: Text.ElideRight
                      width: Math.min(implicitWidth, parent.parent.width - 16 - (hintT.visible ? hintT.implicitWidth + 6 : 0))
                      font.family: rw.r.voice ? RoomLook.sans : RoomLook.mono
                      font.pixelSize: rw.r.voice ? RoomLook.meta + 1 : RoomLook.small + 1
                      font.weight: rw.r.voice ? Font.Medium : Font.Normal
                    }
                    Text {
                      id: hintT
                      visible: rw.r.voice === true && (rw.r.lang === "en" || rw.r.lang === "he") && rw.v !== undefined
                      anchors.baseline: valT.baseline
                      text: set.voiceHint(rw.v)
                      color: Theme.overlay0
                      font.family: RoomLook.sans
                      font.pixelSize: RoomLook.small - 1
                    }
                  }
                  MouseArea {
                    id: valArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: rw.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: { set.current = rw.index; set.activate(rw.r); set.forceActiveFocus() }
                  }
                }
                // num / tune: the value
                Text {
                  visible: rw.r.t === "num" || rw.r.t === "tune"
                  anchors.verticalCenter: parent.verticalCenter
                  width: 72
                  horizontalAlignment: Text.AlignHCenter
                  text: rw.v === undefined ? "–" : Number(rw.v).toFixed(rw.r.dp) + rw.r.unit
                  color: rw.v === undefined ? Theme.overlay0 : Theme.text
                  font.family: RoomLook.mono
                  font.pixelSize: RoomLook.meta + 1
                }
                RoomButton {
                  visible: rw.r.t === "choice" || rw.r.t === "num" || rw.r.t === "tune"
                  compact: true; width: 30
                  text: rw.r.t === "choice" ? "›" : "+"
                  enabled: rw.usable && rw.v !== undefined
                  activeFocusOnTab: false
                  onClicked: { set.current = rw.index; set.change(rw.r, 1) }
                }
                // a voice can be heard first
                RoomButton {
                  visible: rw.r.voice === true
                  compact: true; width: 30
                  text: "▶"
                  tint: Theme.lavender
                  enabled: rw.v !== undefined
                  activeFocusOnTab: false
                  onClicked: { set.current = rw.index; set.preview(rw.r) }
                }
                // plugin: default / changed + reset, then the mode
                Text {
                  visible: rw.r.t === "plugin" && !rw.pChanged && rw.r.p.required !== true
                  anchors.verticalCenter: parent.verticalCenter
                  text: "default"
                  color: Theme.overlay0
                  font.family: RoomLook.sans
                  font.pixelSize: RoomLook.small - 1
                }
                Rectangle {
                  id: resetChip
                  visible: rw.r.t === "plugin" && rw.pChanged
                  anchors.verticalCenter: parent.verticalCenter
                  width: resetT.implicitWidth + 16
                  height: 22
                  radius: 11
                  color: resetArea.containsMouse ? Theme.alpha(Theme.peach, 0.18) : Theme.alpha(Theme.peach, 0.08)
                  border.width: 1
                  border.color: Theme.alpha(Theme.peach, 0.4)
                  Text {
                    id: resetT
                    anchors.centerIn: parent
                    text: "changed  ↺ " + set.modeWord(rw.r.t === "plugin" ? rw.r.p.default_mode : "")
                    color: Theme.peach
                    font.family: RoomLook.sans
                    font.pixelSize: RoomLook.small - 1
                  }
                  MouseArea {
                    id: resetArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { set.current = rw.index; set.setMode(rw.r.p, rw.r.p.default_mode); set.forceActiveFocus() }
                  }
                }
                // required: always on, locked
                Rectangle {
                  visible: rw.r.t === "plugin" && rw.r.p.required === true
                  anchors.verticalCenter: parent.verticalCenter
                  width: lockRow.implicitWidth + 18
                  height: 26
                  radius: 13
                  color: Theme.alpha(Theme.overlay0, 0.08)
                  border.width: 1
                  border.color: Theme.alpha(Theme.overlay0, 0.2)
                  Row {
                    id: lockRow
                    anchors.centerIn: parent
                    spacing: 6
                    Text { text: "🔒"; color: Theme.overlay0; font.pixelSize: RoomLook.small - 2; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: "Always on"; color: Theme.subtext0; font.family: RoomLook.sans; font.pixelSize: RoomLook.small }
                  }
                }
                // the segmented control: On | Auto | Off (Auto only for optional)
                Rectangle {
                  id: segCtl
                  visible: rw.r.t === "plugin" && rw.r.p.required !== true
                  anchors.verticalCenter: parent.verticalCenter
                  readonly property var modes: rw.r.t === "plugin" ? set.modesOf(rw.r.p) : []
                  width: modes.length * 50 + 4
                  height: 26
                  radius: 13
                  color: Theme.alpha(Theme.crust, 0.35)
                  border.width: 1
                  border.color: Theme.alpha(Theme.overlay0, 0.25)
                  opacity: EarsModel.linked ? 1 : 0.5
                  Row {
                    anchors.centerIn: parent
                    Repeater {
                      model: segCtl.modes
                      Rectangle {
                        id: segBtn
                        required property string modelData
                        readonly property bool picked: rw.v === modelData
                        readonly property color hue: modelData === "on" ? Theme.green : modelData === "auto" ? Theme.sapphire : Theme.overlay0
                        width: 50
                        height: 22
                        radius: 11
                        color: picked ? Theme.alpha(hue, 0.22) : segBtnArea.containsMouse ? Theme.alpha(Theme.surface1, 0.5) : Theme.transparent
                        border.width: picked ? 1 : 0
                        border.color: Theme.alpha(hue, 0.6)
                        Behavior on color { ColorAnimation { duration: Style.anim.quick } }
                        Text {
                          anchors.centerIn: parent
                          text: set.modeWord(segBtn.modelData)
                          color: segBtn.picked ? Theme.text : Theme.overlay0
                          font.family: RoomLook.sans
                          font.pixelSize: RoomLook.small
                          font.weight: segBtn.picked ? Font.DemiBold : Font.Normal
                        }
                        MouseArea {
                          id: segBtnArea
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            set.current = rw.index
                            if (!segBtn.picked) set.setMode(rw.r.p, segBtn.modelData)
                            set.forceActiveFocus()
                          }
                        }
                      }
                    }
                  }
                }
                // person
                RoomButton {
                  visible: rw.r.t === "person"
                  compact: true
                  text: "Add a sample"
                  enabled: EarsModel.linked
                  activeFocusOnTab: false
                  onClicked: { set.current = rw.index; EarsModel.enrollPerson(rw.r.p.name) }
                }
                RoomButton {
                  visible: rw.r.t === "person"
                  compact: true
                  kind: "danger"
                  readonly property bool armedHere: rw.r.t === "person" && set.armed === rw.r.p.name
                  text: armedHere ? "Remove " + rw.r.p.name + "?" : "Remove"
                  enabled: EarsModel.linked
                  activeFocusOnTab: false
                  onClicked: { set.current = rw.index; set.sub = -1; set.remove(rw.r) }
                }
              }

              // ---------------------------------------------- design row: a voice by description
              Column {
                id: designRow
                visible: rw.r.t === "design"
                anchors { left: parent.left; leftMargin: 10; right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                spacing: 8
                readonly property string lang: set.forLang
                Row {
                  width: parent.width
                  spacing: 8
                  Rectangle {  // which language this voice is FOR (the designer's own language is handled inside)
                    width: 74; height: 32; radius: 16
                    color: Theme.alpha(Theme.overlay0, 0.16)
                    Text { anchors.centerIn: parent; text: "for " + designRow.lang + " ▾"; color: Theme.subtext0; font.family: RoomLook.mono; font.pixelSize: RoomLook.small }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: set.designLi = (set.designLi + 1) % set.designLangsFor.length }
                  }
                  Rectangle {
                    width: parent.width - 82
                    height: 32
                    radius: 16
                    color: Theme.alpha(Theme.crust, 0.35)
                    border.width: 1
                    border.color: descIn.activeFocus ? Theme.alpha(Theme.accent, 0.6) : Theme.alpha(Theme.overlay0, 0.3)
                    TextInput {
                      id: descIn
                      anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                      verticalAlignment: TextInput.AlignVCenter
                      color: Theme.text
                      clip: true
                      font.family: RoomLook.sans
                      font.pixelSize: RoomLook.meta + 1
                      selectByMouse: true
                      maximumLength: 300
                      onAccepted: tryBtn.clicked()
                      Keys.onEscapePressed: function (e) { set.forceActiveFocus() }
                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: descIn.text === ""
                        text: designRow.lang === "he" ? "Describe it in English: an Israeli woman in her thirties, warm, calm…"
                            : "Describe it in English: a warm woman in her thirties, a native " + (set.langNames[designRow.lang] || "English") + " speaker…"
                        color: Theme.overlay0
                        font: descIn.font
                        elide: Text.ElideRight
                        width: descIn.width
                      }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.IBeamCursor; onClicked: { set.current = rw.index; descIn.forceActiveFocus() } }
                  }
                }
                Row {
                  spacing: 6
                  RoomButton {
                    id: tryBtn
                    compact: true; kind: "primary"; tint: Theme.sapphire
                    text: EarsModel.designStatus === "designing" ? "Designing…" : "▶ Try"
                    enabled: descIn.text.trim().length >= 10 && EarsModel.designStatus !== "designing"
                    onClicked: if (enabled) EarsModel.tryDesign(descIn.text.trim(), designRow.lang,
                                                                 set.hello[designRow.lang] || set.hello.en)
                  }
                  Rectangle {
                    width: 150; height: 28; radius: 14
                    color: Theme.alpha(Theme.crust, 0.35)
                    border.width: 1
                    border.color: nameIn2.activeFocus ? Theme.alpha(Theme.accent, 0.6) : Theme.alpha(Theme.overlay0, 0.3)
                    TextInput {
                      id: nameIn2
                      anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                      verticalAlignment: TextInput.AlignVCenter
                      color: Theme.text
                      clip: true
                      font.family: RoomLook.mono
                      font.pixelSize: RoomLook.small + 1
                      maximumLength: 24
                      validator: RegularExpressionValidator { regularExpression: /[A-Za-z0-9_-]*/ }
                      onAccepted: saveBtn.clicked()
                      Keys.onEscapePressed: function (e) { set.forceActiveFocus() }
                      Text { anchors.verticalCenter: parent.verticalCenter; visible: nameIn2.text === ""; text: "name it"; color: Theme.overlay0; font: nameIn2.font }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.IBeamCursor; onClicked: nameIn2.forceActiveFocus() }
                  }
                  RoomButton {
                    id: saveBtn
                    compact: true; kind: "good"; tint: Theme.green; text: "Save"
                    enabled: descIn.text.trim().length >= 10 && nameIn2.text.length >= 2
                    onClicked: {
                      if (!enabled) return
                      EarsModel.set("voice_library." + nameIn2.text.toLowerCase(),
                                    { description: descIn.text.trim(), language: set.nativeOf(designRow.lang) })
                      EarsModel.designStatus = "saved: pick \"" + nameIn2.text.toLowerCase() + "\" on the Voice tab"
                      nameIn2.text = ""; descIn.text = ""
                    }
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    leftPadding: 6
                    text: EarsModel.designStatus === "designing" ? "designing the voice… (about 10 s the first time)"
                        : EarsModel.designStatus === "ready" ? "playing it"
                        : EarsModel.designStatus.indexOf("saved") === 0 ? EarsModel.designStatus
                        : EarsModel.designStatus.indexOf("error") === 0 ? EarsModel.designStatus : ""
                    color: EarsModel.designStatus.indexOf("error") === 0 ? Theme.red
                         : EarsModel.designStatus.indexOf("saved") === 0 ? Theme.green : Theme.overlay0
                    font.family: RoomLook.sans
                    font.pixelSize: RoomLook.small
                  }
                }
              }

              // ---------------------------------------------- a designed voice on the server
              Column {
                visible: rw.r.t === "designed"
                anchors { left: parent.left; leftMargin: 12; right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                spacing: 6
                Row {
                  spacing: 10
                  Text { text: rw.r.name || ""; color: Theme.text; font.family: RoomLook.mono; font.pixelSize: RoomLook.meta + 1; font.weight: Font.Medium }
                  Text {
                    readonly property string used: rw.r.name ? set.inUse(rw.r.name) : ""
                    text: used !== "" ? "in use: " + used : "not in use"
                    color: used !== "" ? Theme.green : Theme.overlay0
                    font.family: RoomLook.sans; font.pixelSize: RoomLook.small
                  }
                }
                Text {
                  width: parent.width
                  text: rw.r.d ? rw.r.d.description + "   ·   native " + (rw.r.d.language || "en") : ""
                  color: Theme.subtext0
                  wrapMode: Text.Wrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                  font.family: RoomLook.sans
                  font.pixelSize: RoomLook.meta
                }
                Row {
                  spacing: 6
                  RoomButton { compact: true; text: "▶ " + set.forLang
                    onClicked: EarsModel.previewQwen(rw.r.name, set.hello[set.forLang] || set.hello.en, set.forLang, "") }
                  RoomButton { compact: true; kind: "danger"; text: set.armed === rw.r.key ? "Delete it?" : "Delete"
                    onClicked: {
                      if (set.armed !== rw.r.key) { set.armed = rw.r.key; return }
                      set.armed = ""
                      // a voice in use goes back to bright where it was picked
                      var qv = EarsModel.setting("qwen_voices") || ({})
                      for (var l in qv) if (qv[l] === rw.r.name) EarsModel.set("qwen_voices." + l, "default")
                      if (EarsModel.setting("qwen_voice") === rw.r.name) EarsModel.set("qwen_voice", "bright")
                      EarsModel.set("voice_library." + rw.r.name, null)
                    } }
                }
              }

              // ---------------------------------------------- enroll row
              Row {
                visible: rw.r.t === "enroll"
                anchors { left: parent.left; leftMargin: 10; right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                spacing: 8
                Rectangle {
                  width: parent.width - enrollBtn.width - 8
                  height: 32
                  radius: 16
                  color: Theme.alpha(Theme.crust, 0.35)
                  border.width: 1
                  border.color: nameIn.activeFocus ? Theme.alpha(Theme.accent, 0.6) : Theme.alpha(Theme.overlay0, 0.3)
                  TextInput {
                    id: nameIn
                    anchors { fill: parent; leftMargin: 14; rightMargin: 14 }
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.text
                    font.family: RoomLook.sans
                    font.pixelSize: RoomLook.meta + 1
                    selectByMouse: true
                    maximumLength: 40
                    onAccepted: enrollBtn.clicked()
                    Keys.onEscapePressed: function (e) { if (text !== "") text = ""; else set.forceActiveFocus() }
                    Keys.onUpPressed: { set.current = Math.max(0, rw.index - 1); set.forceActiveFocus() }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: nameIn.text === ""
                      text: "Someone new: their name"
                      color: Theme.overlay0
                      font: nameIn.font
                    }
                  }
                  MouseArea { anchors.fill: parent; cursorShape: Qt.IBeamCursor; onClicked: { set.current = rw.index; nameIn.forceActiveFocus() } }
                }
                RoomButton {
                  id: enrollBtn
                  anchors.verticalCenter: parent.verticalCenter
                  kind: "primary"
                  tint: Theme.sapphire
                  text: EarsModel.call ? "Enroll" : "Open call and enroll"
                  enabled: EarsModel.linked && nameIn.text.trim() !== ""
                  onClicked: {
                    if (!enabled) return
                    EarsModel.enrollPerson(nameIn.text.trim())
                    nameIn.text = ""
                    set.forceActiveFocus()
                  }
                }
              }
            }

            // ----------------------------------------- a person's samples
            Flow {
              id: samples
              visible: rw.r.t === "person" && (rw.r.p.samples || []).length > 0
              anchors { left: parent.left; right: parent.right; top: body.bottom; leftMargin: 10; rightMargin: 10 }
              spacing: 6
              Repeater {
                model: rw.r.t === "person" ? (rw.r.p.samples || []) : []
                Rectangle {
                  id: chip
                  required property var modelData
                  required property int index
                  readonly property string tag: rw.r.p.name + "#" + modelData.n
                  readonly property bool armedHere: set.armed === tag
                  readonly property bool cursor: rw.on && set.sub === index
                  width: chipRow.implicitWidth + 18
                  height: 24
                  radius: 12
                  color: armedHere ? Theme.alpha(Theme.red, 0.16) : cursor ? Theme.alpha(Theme.accent, 0.14) : Theme.alpha(Theme.overlay0, 0.10)
                  border.width: 1
                  border.color: armedHere ? Theme.alpha(Theme.red, 0.6) : cursor ? Theme.alpha(Theme.accent, 0.5) : Theme.alpha(Theme.overlay0, 0.2)
                  Row {
                    id: chipRow
                    anchors.centerIn: parent
                    spacing: 6
                    Text {
                      text: chip.armedHere ? "Remove this sample?" : set.day(chip.modelData.created)
                      color: chip.armedHere ? Theme.red : Theme.subtext1
                      font.family: RoomLook.sans
                      font.pixelSize: RoomLook.small
                    }
                    Text {
                      visible: !chip.armedHere
                      text: Math.round(Number(chip.modelData.seconds || 0)) + " s"
                        + (chip.modelData.self_sim !== undefined && chip.modelData.self_sim !== null
                           ? "  " + Number(chip.modelData.self_sim).toFixed(2) : "")
                      color: chip.modelData.self_sim !== undefined && chip.modelData.self_sim !== null
                             && chip.modelData.self_sim < 0.6 ? Theme.yellow : Theme.overlay0
                      font.family: RoomLook.mono
                      font.pixelSize: RoomLook.small - 1
                    }
                    Text {
                      text: "×"
                      color: xArea.containsMouse || chip.armedHere ? Theme.red : Theme.overlay0
                      font.family: RoomLook.sans
                      font.pixelSize: RoomLook.meta
                      MouseArea {
                        id: xArea
                        anchors { fill: parent; margins: -5 }
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { set.current = rw.index; set.sub = chip.index; set.remove(rw.r); set.forceActiveFocus() }
                      }
                    }
                  }
                }
              }
            }

            // ------------------------------------------- the option list
            Flow {
              id: opts
              visible: rw.listOpen
              anchors { left: parent.left; right: parent.right; top: body.bottom; leftMargin: 10; rightMargin: 10 }
              spacing: 6
              Repeater {
                model: rw.listOpen ? rw.r.opts : []
                Rectangle {
                  id: oc
                  required property var modelData
                  readonly property bool picked: modelData === rw.v
                  width: ocText.implicitWidth + 20
                  height: 26
                  radius: 13
                  color: picked ? Theme.alpha(Theme.accent, 0.18) : ocArea.containsMouse ? Theme.alpha(Theme.surface1, 0.55) : Theme.alpha(Theme.overlay0, 0.08)
                  border.width: 1
                  border.color: picked ? Theme.alpha(Theme.accent, 0.55) : Theme.alpha(Theme.overlay0, 0.18)
                  Text {
                    id: ocText
                    anchors.centerIn: parent
                    text: rw.r.voice ? set.voiceName(oc.modelData) + (rw.r.lang === "en" ? " " + set.voiceHint(oc.modelData).split(" ")[0] : "")
                                     : String(oc.modelData)
                    color: oc.picked ? Theme.text : Theme.subtext0
                    font.family: rw.r.voice ? RoomLook.sans : RoomLook.mono
                    font.pixelSize: RoomLook.small + (rw.r.voice ? 1 : 0)
                  }
                  MouseArea {
                    id: ocArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      set.current = rw.index
                      if (!oc.picked) EarsModel.set(rw.r.key, oc.modelData)
                      if (rw.r.voice) set.previewWith(rw.r, oc.modelData)
                      set.forceActiveFocus()
                    }
                  }
                }
              }
            }
          }
        }
      }

      // ------------------------------------------------- section footers
      Text {
        width: parent.width
        topPadding: 12
        visible: text !== ""
        text: set.section === "voice"
              ? (!set.hasSettings ? "These are the voices in ears.py. Pick them here once the engine publishes its settings."
                 : String(EarsModel.setting("tts")).indexOf("qwen") === 0
                   ? "Ori answers in the language you speak, always in this voice (Hebrew is read through IPA). ▶ or Space plays it."
                   : "Ori answers in the language you speak, in that language's voice. ▶ or Space plays it.")
            : set.section === "voices"
              ? "Describe a voice, ▶ Try it (about 10 s the first time, then instant), name it and Save. Saved voices are picked on the Voice tab like any other, for every language or one. \"for\" is the language you'll mostly use it in."
            : set.section === "people" && EarsModel.people
              ? "Enrolling takes about 20 seconds of talking. More samples (another room, a morning voice) help Ori know someone anywhere."
            : set.section === "brain" ? "Changes apply from the next reply."
            : set.section === "behaviour" && set.opt.plugins && set.opt.plugins.length
              ? "On: always there. Auto: Ori turns it on himself when he needs it, for the rest of that call. Off: never. ● = in use right now. Changes apply from Ori's next reply; Delete puts a plugin back to its default."
            : ""
        color: Theme.overlay0
        wrapMode: Text.Wrap
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.small
      }
      Text {
        width: parent.width
        topPadding: 12
        visible: set.section === "behaviour" && !(set.opt.plugins && set.opt.plugins.length) && !set.hasSettings
        text: "This engine does not publish its settings yet."
        color: Theme.overlay0
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.small
      }
    }
  }

  // the description in use for a language row ("all" = Ori's voice), or ""
  readonly property var designLangsFor: ["he", "en", "fr", "es", "de", "it", "pt"]
  property int designLi: 0
  readonly property string forLang: designLangsFor[designLi]  // which language a designed voice is FOR
  function inUse(name) {  // where a library voice is picked: "every language", "Hebrew", ...
    var out = [], qv = EarsModel.setting("qwen_voices") || ({})
    if (EarsModel.setting("qwen_voice") === name) out.push("every language")
    for (var k in qv) if (qv[k] === name) out.push(set.langNames[k] || k)
    return out.join(", ")
  }
  readonly property var designerLangs: ["en", "fr", "es", "de", "it", "pt", "ru", "zh", "ja", "ko"]
  function nativeOf(lang) { return designerLangs.indexOf(lang) >= 0 ? lang : "en" }  // Hebrew voices: en
  function previewWith(row, voice) {
    if (row.qwen) {  // the row's own language (Hebrew needs IPA routing: the English line instead)
      var qv = voice === "default" || !voice ? EarsModel.setting("qwen_voice") : voice
      EarsModel.previewQwen(qv, set.hello[row.lang] || set.hello.en, row.lang === "all" ? "en" : row.lang, ""); return
    }
    EarsModel.previewVoice(voice, espeak(row.lang, voice), set.hello[row.lang] || set.hello.en, set.paceFor(row.lang))
  }
  function day(iso) {
    var d = new Date(iso)
    if (isNaN(d.getTime())) return "–"
    var mon = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.getMonth()]
    return d.getDate() + " " + mon
  }
}
