import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import ".."

// Voice mode: the capsule. A second surface for talking to Ori, held to a
// different contract than the panel -- the panel is something you turn TO and
// read; the capsule is something that happens AROUND you. It appears when you
// start speaking, shows what stage the exchange is in, and goes away.
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
//   ── OriClient.busy / OriClient.speakJob drive the working / speaking states,
//      so the capsule is a pure observer of the session it sent into.
//
// Recorder and transcriber follow the proven ptt script's shapes: pw-record is
// SIGTERMed (it finalises the wav trailer on TERM, hence the 500 ms settle
// before transcribing), taps under 0.3 s are discarded, marathon wavs from a
// stuck recorder are never transcribed.
Scope {
    id: voice

    // ------------------------------------------------------------- state
    // hidden → listening → transcribing → working → speaking → done → hidden.
    // "working" lasts as long as the turn does -- a long tool run keeps the
    // capsule as a small breathing dot, out of the way until there is speech.
    property string state: "hidden"
    // True while the capsule itself spawned the speech (wake), as opposed to
    // relaying the session's speak tool. Barge-in and the exit path tell them
    // apart.
    property bool wakeSpeech: false
    // Live RMS levels, oldest first, newest last -- the waveform feeds off the
    // tail of this. Capped at the bar count so it never grows unbounded.
    property var levels: []
    // What was heard, shown while the turn runs so a mishear is visible
    // immediately (fix: cancel and press again).
    property string interim: ""

    readonly property int barCount: 32
    readonly property string rmsPy: String(Qt.resolvedUrl("voice-rms.py")).replace(/^file:\/\//, "")
    readonly property string wav: "/tmp/ori-voice.wav"

    function start() {
        // Idempotent, like ptt down: a duplicate down while recording is a no-op.
        if (state === "listening")
            return
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
        wakeSpeech = false
        interim = ""
        levels = []
        var i = 0
        var zeros = []
        for (i = 0; i < barCount; i++) zeros.push(0)
        levels = zeros
        state = "listening"
        rms.exec(rms.command)
        recorder.exec(recorder.command)
    }

    function stop() {
        if (state !== "listening")
            return
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
            // "working": the turn keeps running in the session, the capsule
            // just stops watching it.
            unstage.restart()
        }
    }

    // Reminders and scripts: pop up, speak, fade. Speech here is the capsule's
    // own spawn -- same shape speak.ts uses, so the NPU path is identical.
    function wake(text) {
        if (state === "listening" || state === "transcribing")
            cancel()
        stopSpeech()
        wakeSpeech = true
        interim = ""
        state = "speaking"
        waker.command = ["kokoro-npu", "say",
                         "--voice", "bm_lewis", "--lang", "en-us", "--speed", "1", String(text)]
        waker.exec(waker.command)
        return "waking"
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

        // Reminders, scripts, anything: make the capsule speak.
        //   qs ipc call voice wake "meeting in five minutes"
        function wake(text: string): string {
            return voice.wake(text)
        }

        function status(): string {
            return voice.state
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

    // The capsule's own speech (wake only).
    Process {
        id: waker
        onExited: if (wakeSpeech && state === "speaking") finish()
    }

    // Cuts the session's speech for barge-in. pkill, not a pid we own: the
    // speak tool spawned it detached inside the pi child.
    Process {
        id: cutter
        command: ["pkill", "-f", "kokoro-npu say"]
    }

    // ------------------------------------------------------------- session
    Connections {
        target: OriClient
        function onBusyChanged() {
            // busy falling is the turn settling. Speech usually starts before
            // that (the speak tool call is mid-turn), so this is the no-speech
            // exit; the speech exit lives in onSpeakJobChanged.
            if (!OriClient.busy && state === "working")
                finish()
        }
        function onSpeakJobChanged() {
            if (OriClient.speakJob) {
                // Never override an exchange the user is mid-way through --
                // barge-in only flows one way: their press cuts the speech.
                if (state === "working") state = "speaking"
            } else if (state === "speaking" && !wakeSpeech) {
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

    Timer {
        id: doneTimer
        interval: 1400
        onTriggered: state = "hidden"
    }

    // ------------------------------------------------------------- surface
    PanelWindow {
        id: capsule

        // Overlay, not Top: the capsule must sit over the bar and the panel
        // both -- it appears while you are doing something else, so it does
        // not get to be hidden behind them. It takes no keyboard at all; the
        // click path below is the only direct input.
        WlrLayershell.namespace: "quickshell-voice"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        anchors {
            top: true
            left: true
            right: true
        }
        // Full-span surface, card centered inside it -- a layer surface that
        // resizes waits a configure round trip per frame (the slideshow that
        // hit the notification popups), so the surface never changes shape.
        implicitHeight: 160
        // Below the bar: the bar is exclusive, the capsule starts under it.
        margins.top: 52

        readonly property bool shown: voice.state !== "hidden"

        // Windows have no opacity of their own (the surface is or is not);
        // the fade lives on this stage item, which holds the card.
        Item {
            id: stage
            anchors.fill: parent
            opacity: capsule.shown ? 1 : 0
            visible: opacity > 0.001
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        MouseArea {
            id: cardZone
            anchors.centerIn: parent
            width: card.width
            height: card.height
            onClicked: {
                if (voice.state === "listening" || voice.state === "transcribing")
                    voice.cancel()
                else if (voice.state === "speaking")
                    voice.cancel()
                else
                    voice.cancel()
            }

            Rectangle {
                id: card

                // Widths are per-state and animated, so the morph IS the state
                // change -- the capsule breathes wider to listen, shrinks to a
                // dot to wait. Height and y stay fixed; only x and width move.
                readonly property int wideWidth: 420
                readonly property int narrowWidth: 190

                width: {
                    if (voice.state === "listening") return wideWidth
                    if (voice.state === "transcribing") return wideWidth
                    if (voice.state === "speaking") return 240
                    return narrowWidth
                }
                Behavior on width {
                    NumberAnimation { duration: 350; easing.type: Easing.OutBack }
                }

                height: 64
                radius: height / 2
                x: (parent.width - width) / 2
                y: (parent.height - height) / 2

                color: Theme.alpha(Theme.crust, 0.92)
                border.width: 1
                border.color: {
                    if (voice.state === "listening") return Theme.alpha(Theme.lavender, 0.8)
                    if (voice.state === "speaking") return Theme.alpha(Theme.green, 0.7)
                    return Theme.alpha(Theme.mauve, 0.6)
                }
                Behavior on border.color {
                    ColorAnimation { duration: Style.anim.colorDuration }
                }

                scale: voice.state === "hidden" ? 0.92 : 1
                Behavior on scale {
                    NumberAnimation { duration: 220; easing.type: Easing.OutBack }
                }

                // ------------------------------------------------- waveform
                // Listening: the real RMS stream. Every other state animates
                // the same bars from a clock -- the visual grammar ("this
                // strip of light is the sound") stays identical while the
                // source changes.
                Row {
                    id: bars
                    anchors.centerIn: parent
                    spacing: 3

                    property int tick: 0

                    Timer {
                        interval: 90
                        running: voice.state === "speaking" || voice.state === "transcribing"
                        repeat: true
                        onTriggered: bars.tick++
                    }

                    Repeater {
                        model: voice.barCount

                        Rectangle {
                            required property int index

                            width: 4
                            radius: 2
                            color: {
                                if (voice.state === "listening") return Theme.lavender
                                if (voice.state === "speaking") return Theme.green
                                return Theme.mauve
                            }
                            Behavior on color {
                                ColorAnimation { duration: Style.anim.colorDuration }
                            }

                            readonly property real liveLevel: {
                                var from = voice.levels.length - voice.barCount
                                if (voice.state === "listening" && from >= 0)
                                    return voice.levels[from + index]
                                return 0
                            }
                            readonly property real animLevel: {
                                var t = bars.tick / 6 + index * 0.55
                                if (voice.state === "speaking")
                                    return 0.35 + 0.65 * Math.abs(Math.sin(t) * Math.sin(t / 2.3 + 1))
                                if (voice.state === "transcribing")
                                    return 0.15 + 0.2 * Math.abs(Math.sin(t))
                                // working / done: one slow breath, near-flat
                                return 0.12 + 0.06 * Math.sin(t / 3)
                            }
                            height: 6 + 40 * (voice.state === "listening" ? liveLevel : animLevel)
                            Behavior on height {
                                NumberAnimation { duration: 110; easing.type: Easing.OutQuad }
                            }
                        }
                    }
                }

                // -------------------------------------------------- labels
                // What was heard, shown once transcribed and kept while the
                // turn runs -- a mishear is visible the moment it happens.
                Text {
                    anchors.centerIn: parent
                    width: card.width - 48
                    visible: voice.state === "working"
                    text: voice.interim
                    color: Theme.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.size
                    elide: Text.ElideMiddle
                    horizontalAlignment: Text.AlignHCenter
                }

                // State word, for the two states without text of their own.
                Text {
                    anchors.centerIn: parent
                    visible: voice.state === "done"
                    text: "✓"
                    color: Theme.green
                    font.family: Style.font.family
                    font.pixelSize: Style.font.size + 4
                }
            }
        }
        }
    }
}