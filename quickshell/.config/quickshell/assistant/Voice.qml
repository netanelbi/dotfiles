import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import ".."

// Voice mode. Talking to Ori is the orb, not a panel: the spirit docked in the
// bar's centre pill pops out when you hold the key, hears you, thinks, speaks,
// and flies back. The transcript panel never opens for voice. What is heard is
// shown beside the orb for a moment; what Ori answers is spoken, not written.
// (The panel keeps every turn regardless, for later.)
//
//   qs ipc call voice start        hold-to-talk: keybind on PRESS
//   qs ipc call voice stop         keybind on RELEASE -- transcribe, send
//   qs ipc call voice cancel       discard whatever is in flight
//   qs ipc call voice wake "text"  reminders etc: pop up and speak
//
// The loop:
//
//   hold ── pw-record writes a wav, voice-rms.py streams live RMS levels
//   release ── whisper-npu (moonshine-v2-medium, CPU, ~0.5 s) transcribes
//   ── OriClient.ask("[voice] " + text) -- the MARKER is the whole contract:
//      the session sees the message came by voice and decides itself when to
//      speak. Nothing here forces speech; speak.ts owns the one-utterance lock.
//   ── OriClient.busy drives working; OriClient.oriTalking (the kokoro stream
//      in PipeWire, see OriClient) drives speaking -- so the orb follows the
//      sound itself, not pi's follow-up queue.
//
// This file owns the exchange and its processes. The orb itself is drawn by
// OrbOverlay (out on the screen), OrbDock (in the bar) and the panel's input
// row, all reading the state published on OriClient.
//
// Recorder and transcriber follow the proven ptt script's shapes: pw-record is
// SIGTERMed (it finalises the wav trailer on TERM, hence the 500 ms settle
// before transcribing), taps under 0.3 s are discarded, marathon wavs from a
// stuck recorder are never transcribed.
Scope {
    id: voice

    // ------------------------------------------------------------- state
    // hidden → listening → transcribing → working → speaking → done → hidden.
    // "working" lasts as long as the turn does; speaking comes and goes inside
    // it as often as Ori talks (react first, work, then say the answer).
    property string state: "hidden"
    // True while the orb itself spawned the speech (wake), as opposed to
    // relaying the session's speak tool. Barge-in and the exit path tell them
    // apart.
    property bool wakeSpeech: false
    // Live RMS levels, oldest first, newest last. Capped so it never grows
    // unbounded.
    property var levels: []
    readonly property real liveLevel: levels.length > 0 ? levels[levels.length - 1] : 0
    // What was heard, shown while the turn runs so a mishear is visible
    // immediately (fix: cancel and press again).
    property string interim: ""

    readonly property int barCount: 32
    readonly property string rmsPy: String(Qt.resolvedUrl("voice-rms.py")).replace(/^file:\/\//, "")
    readonly property string wav: "/tmp/ori-voice.wav"

    // The level the orb pulses on: the mic while you talk, the SPEAKER while
    // Ori does. Playback is captured from the sink's monitor for exactly as
    // long as kokoro's stream exists (see playRec), so the pulse is the real
    // waveform of the voice, not a rhythm made up to look like one.
    property var playLevels: []
    readonly property real playLevel: playLevels.length > 0 ? playLevels[playLevels.length - 1] : 0
    readonly property real level:
        // Speaking is speaking, whoever started it: the capsule's own exchange
        // (state === "speaking") or the session's speak tool (oriTalking, which
        // is just the kokoro stream on the sink). Without the second arm a
        // session-spoken reply pops the orb out flat -- right colour, no life.
        (state === "speaking" || (state === "hidden" && OriClient.oriTalking)) ? playLevel
      : liveLevel

    // Published for the other two perches (bar dock, panel input row).
    Binding { target: OriClient; property: "voiceState"; value: voice.state }
    Binding { target: OriClient; property: "voiceLevel"; value: voice.level }
    Binding { target: OriClient; property: "voiceInterim"; value: voice.interim }

    // The orb leaves the pill on whichever monitor has focus -- the same rule
    // the panel and the launchers use. Only re-targeted while hidden.
    function focusedScreen() {
        var focused = Hyprland.focusedMonitor
        var screens = Quickshell.screens
        if (focused) {
            for (var i = 0; i < screens.length; i++) {
                var m = Hyprland.monitorFor(screens[i])
                if (m && m.name === focused.name) return screens[i]
            }
        }
        return screens.length > 0 ? screens[0] : null
    }

    function start() {
        // Idempotent, like ptt down: a duplicate down while recording is a no-op.
        if (state === "listening") {
            // Mid-grace re-press: keep the recording, cancel the stop.
            if (grace.running) { grace.stop(); return }
            return
        }
        // Barge-in: pressing to talk cuts off whatever is playing, speech
        // included. The speak tool clears its lock on child exit, so SIGTERM
        // here leaves it consistent.
        if (state === "speaking")
            stopSpeech()
        if (state === "working" || state === "transcribing") {
            // A second press mid-turn means "new question", not "cancel the
            // turn" -- the session keeps running, its speech is simply cut.
            stopSpeech()
        }
        // Leaving the pill: out on the monitor with focus. Already out (free):
        // it stays on whatever screen it is on -- it never moves itself.
        if (state === "hidden" && !OriClient.orbFree) {
            var s = focusedScreen()
            if (s) overlay.screen = s
        }
        wakeSpeech = false
        interim = ""
        var zeros = []
        for (var i = 0; i < barCount; i++) zeros.push(0)
        levels = zeros
        state = "listening"
        rms.exec(rms.command)
        recorder.exec(recorder.command)
    }

    function stop() {
        if (state !== "listening")
            return
        // Grace: keep recording a beat after release so the tail of the
        // last word is not clipped. A re-press inside the window cancels
        // the stop and recording just continues.
        grace.restart()
    }

    Timer {
        id: grace
        interval: 300
        onTriggered: voice.reallyStop()
    }

    function reallyStop() {
        // Levels first: the tail keeps printing until its own children die.
        rms.signal(15)
        recorder.signal(15)
        settle.restart() // 500 ms: let pw-record finalise the wav trailer
    }

    function cancel() {
        if (state === "hidden")
            return
        if (state === "listening" || state === "transcribing") {
            stopRecording()
            unstage.restart()
        } else if (state === "speaking") {
            stopSpeech()
            unstage.restart()
        } else {
            // "working": the turn keeps running in the session, the orb
            // just stops watching it.
            unstage.restart()
        }
    }

    // Reminders and scripts: pop up, speak, fly home. Speech here is the orb's
    // own spawn -- same shape speak.ts uses, so the NPU path is identical.
    //
    // A wake arriving while another wake is speaking cannot just re-exec the
    // waker: in 0.3.1 exec() on a running Process SIGTERMs the old child and
    // only starts the new command once that old child's exit lands -- and that
    // same exit fires onExited, which would finish() before the new utterance
    // ever showed. So the replacement text is queued here and started from
    // that exit instead (waker.onExited).
    property string pendingWake: ""

    function wake(text) {
        if (state === "listening" || state === "transcribing")
            cancel()
        if (state === "hidden" && !OriClient.orbFree) {
            var s = focusedScreen()
            if (s) overlay.screen = s
        }
        // Cut the SESSION's speech only if it is actually playing. The cut is
        // a pkill on the kokoro command line, which would take the wake's own
        // child with it if it landed a beat late -- so when a cut is needed,
        // the new utterance waits for it (wakeAfterCut).
        var cut = state === "speaking" && !wakeSpeech && OriClient.oriTalking
        if (cut) stopSpeech()
        wakeSpeech = true
        interim = ""
        state = "speaking"
        if (waker.running) {
            pendingWake = String(text)
            return "waking"
        }
        pendingWake = ""
        waker.command = ["kokoro-npu", "say",
                         "--voice", "bm_lewis", "--lang", "en-us", "--speed", "1", String(text)]
        if (cut) wakeAfterCut.restart()
        else waker.exec(waker.command)
        return "waking"
    }

    Timer {
        id: wakeAfterCut
        interval: 200
        onTriggered: if (wakeSpeech && state === "speaking") waker.exec(waker.command)
    }

    function stopSpeech() {
        if (wakeSpeech && waker.running) {
            waker.signal(15)
            return
        }
        // The session's speech runs inside the pi child; speak.ts's registry
        // clears on the child's exit event, so a SIGTERM here is exactly its
        // own interrupt path.
        if (!wakeSpeech)
            cutter.exec(cutter.command)
    }

    function stopRecording() {
        rms.signal(15)
        recorder.signal(15)
    }

    function transcribe() {
        state = "transcribing"
        whisper.command = ["whisper-npu", "transcribe", wav,
                           "--model", "moonshine-v2-medium", "--no-daemon"]
        whisper.exec(whisper.command)
    }

    function finish() {
        // The check pops, then the orb flies home (OrbOverlay times the
        // flight off this state); doneTimer flips to hidden once it has landed.
        state = "done"
        doneTimer.restart()
    }

    // ------------------------------------------------------------- ipc
    IpcHandler {
        target: "voice"

        function start(): string {
            voice.start()
            return voice.state
        }

        function stop(): string {
            voice.stop()
            return voice.state
        }

        function cancel(): string {
            voice.cancel()
            return "cancelled"
        }

        // Reminders, scripts, anything: make the orb speak.
        //   qs ipc call voice wake "meeting in five minutes"
        function wake(text: string): string {
            return voice.wake(text)
        }

        function status(): string {
            return voice.state
        }

        // Build marker, to tell a stale engine from a fresh one.
        function version(): string { return "orb-2" }

        // Let it out, or call it home: on | off | toggle.
        //   qs ipc call voice free toggle
        function free(mode: string): string {
            var m = String(mode)
            OriClient.orbFree = m === "on" ? true : m === "off" ? false : !OriClient.orbFree
            return OriClient.orbFree ? "free" : "docked"
        }

        // Throw it from a script, px/s: qs ipc call voice fling 1500 0
        function fling(vx: string, vy: string): string {
            if (!overlay.shown) return "not out"
            overlay.fling(parseFloat(vx), parseFloat(vy))
            return "flung"
        }

        // Drop the remembered spot; the next time out it picks one itself.
        function forget(): string {
            overlay.forget()
            return "forgot"
        }

        // Where the orb is and whether Ori's voice is on the speaker.
        function orb(): string {
            return voice.state + " talking=" + OriClient.oriTalking + " speaking=" + OriClient.speaking
                + " at=" + Math.round(overlay.ox) + "," + Math.round(overlay.oy)
                + " level=" + voice.level.toFixed(2) + " shown=" + overlay.shown
                + " mem=" + overlay.memInfo()
                + " mon=" + overlay.monDebug() + " play=" + voice.playLevels.length
                + " screen=" + (overlay.screen ? overlay.screen.name : "none")
                + " panelDock=" + OriClient.panelDock.screen + ":" + Math.round(OriClient.panelDock.x) + "," + Math.round(OriClient.panelDock.y)
        }
    }

    // ------------------------------------------------------------- processes
    // The recorder owns the wav (ptt's exact shape: file output, SIGTERM to
    // finalise). Raw stdout would avoid the header math but orphans pw-record
    // when a pipeline shell dies -- killing the recorder PID is the proven path.
    Process {
        id: recorder
        command: ["pw-record", "--rate", "16000", "--channels", "1", "--format", "s16", voice.wav]
    }

    // Live loudness: `tail -f` blocks on inotify until new bytes land, so this
    // is event-driven end to end -- no polling anywhere.
    Process {
        id: rms
        command: ["python3", voice.rmsPy, voice.wav]
        stdout: SplitParser {
            onRead: function (line) {
                var v = parseFloat(String(line))
                if (isNaN(v) || voice.state !== "listening")
                    return
                var next = voice.levels.concat([v])
                if (next.length > voice.barCount) next = next.slice(next.length - voice.barCount)
                voice.levels = next
            }
        }
    }

    Process {
        id: whisper
        property string text: ""
        stdout: SplitParser {
            onRead: function (line) { whisper.text += line }
        }
        onExited: {
            var said = text.trim()
            text = ""
            // A stuck recorder makes marathon wavs; a tap makes empty ones.
            // Both are dropped here, after ffprobe judged the wav itself.
            if (duration <= 60 && duration >= 0.3 && said !== "") {
                interim = said
                state = "working"
                OriClient.ask("[voice] " + said)
            } else {
                unstage.restart()
            }
        }
    }

    // Duration of the last recording, in seconds. The wav is s16le mono 16 kHz,
    // so the size alone answers -- ffprobe for the same reason ptt does: it is
    // already proven against pw-record's trailers.
    property real duration: 0
    Process {
        id: probe
        stdout: SplitParser {
            onRead: function (line) {
                var d = parseFloat(String(line))
                voice.duration = isNaN(d) ? 0 : d
            }
        }
        onExited: transcribe()
    }

    // The orb's own speech (wake only).
    Process {
        id: waker
        onExited: {
            // The exit of a replaced wake starts the queued utterance instead
            // of finishing. If the user barged in while it was queued (state
            // moved on), the queued text is simply dropped.
            if (pendingWake !== "") {
                var t = pendingWake
                pendingWake = ""
                if (wakeSpeech && state === "speaking")
                    wake(t)
                return
            }
            if (wakeSpeech && state === "speaking") finish()
        }
    }

    // Cuts the session's speech for barge-in. pkill, not a pid we own: the
    // speak tool spawned it detached inside the pi child.
    Process {
        id: cutter
        command: ["pkill", "-f", "kokoro-npu say"]
    }

    // ------------------------------------------------------------- playback
    // What Ori sounds like, as a level: pw-record on the default sink's
    // monitor, tailed by the same RMS script the mic uses. Both run only while
    // kokoro's stream is up; the wav is wiped first so the tail never replays
    // the previous utterance. SIGTERM lands on pw-record itself (exec).
    readonly property string playWav: "/tmp/ori-play.wav"
    Process {
        id: playRec
        command: ["sh", "-c", "rm -f \"$0\"; exec pw-record -P '{ stream.capture.sink = true }' --rate 16000 --channels 1 --format s16 \"$0\"", voice.playWav]
    }
    Process {
        id: playRms
        command: ["python3", voice.rmsPy, voice.playWav]
        stdout: SplitParser {
            onRead: function (line) {
                var v = parseFloat(String(line))
                if (isNaN(v)) return
                var next = voice.playLevels.concat([v])
                if (next.length > voice.barCount) next = next.slice(next.length - voice.barCount)
                voice.playLevels = next
            }
        }
    }
    Connections {
        target: OriClient
        function onOriTalkingChanged() {
            if (OriClient.oriTalking) {
                voice.playLevels = []
                playRec.exec(playRec.command)
                playRms.exec(playRms.command)
            } else {
                playRms.signal(15)
                playRec.signal(15)
                voice.playLevels = []
            }
        }
    }

    // ------------------------------------------------------------- session
    Connections {
        target: OriClient
        // Let out from anywhere (the dock click, the keybind, ipc): it leaves
        // from the pill on the monitor that has focus.
        function onBusyChanged() {
            // busy falling is the turn settling. Speech usually ends before
            // that; this is the no-speech exit. The speech exit is below.
            if (!OriClient.busy && state === "working")
                finish()
        }
        // The SOUND, not the job list: PipeWire announces kokoro's stream the
        // moment it opens and the moment it closes. The speak row in the panel
        // reads the same flag, so both agree to the frame.
        function onSpeakingChanged() {
            if (OriClient.speaking) {
                // Never override an exchange the user is mid-way through --
                // barge-in only flows one way: their press cuts the speech.
                if (state === "working") state = "speaking"
            } else if (state === "speaking" && !wakeSpeech) {
                // Speech is only one step of a turn: unless busy has fallen
                // too, this is a return to watching, not an exit.
                if (OriClient.busy)
                    state = "working"
                else
                    finish()
            }
        }
    }

    // ------------------------------------------------------------- timers
    Timer {
        id: settle
        interval: 500
        onTriggered: {
            probe.command = ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                             "-of", "csv=p=0", voice.wav]
            probe.exec(probe.command)
        }
    }

    Timer {
        id: unstage
        interval: 250
        onTriggered: state = "hidden"
    }

    // The check pops, then it lingers a moment before flying home -- an orb
    // that bolts the instant the last word lands reads as fleeing.
    Timer {
        id: doneTimer
        interval: 2600
        onTriggered: state = "hidden"
    }

    // ------------------------------------------------------------- surface
    OrbOverlay {
        id: overlay
        voice: voice
    }
}
