import QtQuick
import QtQuick.Effects
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
            // "working": the turn keeps running in the session, the capsule
            // just stops watching it.
            unstage.restart()
        }
    }

    // Reminders and scripts: pop up, speak, fade. Speech here is the capsule's
    // own spawn -- same shape speak.ts uses, so the NPU path is identical.
    //
    // A wake arriving while another wake is speaking cannot just re-exec the
    // waker: in 0.3.1 exec() on a running Process SIGTERMs the old child and
    // only starts the new command once that old child's exit lands -- and that
    // same exit fires onExited, which would finish() the capsule before the
    // new utterance ever showed. So the replacement text is queued here and
    // started from that exit instead (waker.onExited).
    property string pendingWake: ""

    function wake(text) {
        if (state === "listening" || state === "transcribing")
            cancel()
        stopSpeech()
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
        // No "done" display -- the card simply fades away slowly from
        // wherever it is. doneTimer only flips the state once the fade
        // has run.
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
        onExited: {
            // The exit of a replaced wake starts the queued utterance instead
            // of finishing the capsule. If the user barged in while it was
            // queued (state moved on), the queued text is simply dropped.
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
                // Speech is only one step of a turn. speakJob clears the
                // moment the utterance ends, but the session usually keeps
                // working after it -- so unless busy has fallen too, this is
                // a return to watching, not an exit.
                if (OriClient.busy)
                    state = "working"
                else
                    finish()
            }
        }
    }

    // State-entry choreography: from hidden the card springs in; between live
    // states a small scale pop makes the morph read as deliberate, not drifted.
    Connections {
        target: voice
        function onStateChanged() {
            if (voice.state === "hidden") {
                card.scale = 0.90
                return
            }
            statePop.restart()
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
        interval: 1000
        onTriggered: state = "hidden"
    }

    // ------------------------------------------------------------- surface
    PanelWindow {
        id: capsule

        // Overlay, not Top: the capsule must sit over the bar and the panel
        // both -- it appears while you are doing something else, so it does
        // not get to be hidden behind them. It takes no keyboard at all; the
        // click path below is the only direct input. Frosted glass comes from
        // Hyprland (layerrule blur on this namespace, machine.lua), which is
        // why the card alpha sits well below 1.
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
        // Input follows the mask, not the surface: without it the whole strip
        // ate clicks even where nothing is drawn.
        implicitHeight: 190
        margins.top: 52
        mask: Region { item: capsule.shown ? cardZone : null }

        readonly property bool shown: voice.state !== "hidden"
        // The state's accent, decided once -- every glow, border, bar and
        // label reads this, so a state change repaints the whole capsule in
        // one move.
        readonly property color accent: {
            if (voice.state === "listening") return Theme.lavender
            if (voice.state === "transcribing") return Theme.mauve
            if (voice.state === "working") return Theme.blue
            if (voice.state === "speaking") return Theme.green
            return Theme.green
        }

        // Live level, for the listening glow: the light answers the voice.
        readonly property real liveLevel:
            voice.levels.length > 0 ? voice.levels[voice.levels.length - 1] : 0
        // How brightly the ambient pool burns, per state. Working is the stage
        // the owner most wants to SEE, so it is the strongest light in the
        // room; listening rides the voice itself. Kept at or below 1: Item
        // opacity clamps, and the numbers below are the honest mix.
        readonly property real glowStrength: {
            if (voice.state === "working") return 1.0
            if (voice.state === "listening") return 0.62 + 0.30 * liveLevel
            if (voice.state === "speaking") return 0.85
            if (voice.state === "transcribing") return 0.72
            return 0.5
        }
        // How far the pool spreads past the card, per state.
        readonly property int glowPad: voice.state === "working" ? 150 : 90

        // Windows have no opacity of their own (the surface is or is not);
        // the fade lives on this stage item, which holds the card.
        Item {
            id: stage
            anchors.fill: parent
            opacity: capsule.shown ? 1 : 0
            visible: opacity > 0.001
            Behavior on opacity {
                NumberAnimation { duration: voice.state === "done" ? 900 : 200; easing.type: Easing.OutCubic }
            }

            // Live tool intent under the card while the session works:
            // the same one-line descriptions the panel rail shows. OriClient
            // empties activeTool between tool calls and on settle, so this is
            // hidden for those stretches -- nothing stale is ever shown.
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 10
                width: Math.min(parent.width - 60, 620)
                text: OriClient.activeTool
                visible: voice.state === "working" && text !== ""
                opacity: 0.75
                color: Theme.text
                font.family: Style.font.family
                font.pixelSize: Style.font.size
                elide: Text.ElideMiddle
                horizontalAlignment: Text.AlignHCenter
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }

            // Ambient glow: a soft radial pool of the state colour behind the
            // card, breathing slowly. This is what makes the capsule read as
            // a light source rather than a sticker. Two layers: the WRAPPER
            // carries the per-state strength (Behaviour-able, so a state change
            // crossfades the light instead of snapping it); the inner rect
            // carries the breath itself.
            Item {
                id: glowWrap
                anchors.centerIn: parent
                width: card.width + capsule.glowPad
                height: voice.state === "working" ? 190 : 150
                opacity: capsule.glowStrength
                Behavior on opacity { NumberAnimation { duration: Style.anim.opacityDuration * 2; easing.type: Easing.OutQuad } }
                Behavior on width { NumberAnimation { duration: Style.anim.slow; easing.type: Easing.OutCubic } }
                Behavior on height { NumberAnimation { duration: Style.anim.slow; easing.type: Easing.OutCubic } }

                Rectangle {
                    id: glow
                    anchors.fill: parent
                    radius: height / 2
                    color: "transparent"
                    // Radial gradient needs a shape; a plain Rectangle cannot.
                    // The gradient rectangle itself is the glow.
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.rgba(capsule.accent.r, capsule.accent.g, capsule.accent.b, 0.30) }
                        GradientStop { position: 0.55; color: Qt.rgba(capsule.accent.r, capsule.accent.g, capsule.accent.b, 0.13) }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                    SequentialAnimation on opacity {
                        running: capsule.shown
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.68; duration: Style.anim.breath / 2; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: Style.anim.breath / 2; easing.type: Easing.InOutSine }
                    }
                }
            }

            // Done: one soft bloom of the accent before the stage fade takes
            // the capsule away -- a last breath of light, not a green flash.
            // Gated on done, so it never runs while hidden.
            Rectangle {
                id: bloom
                anchors.centerIn: parent
                width: card.width + 60
                height: 130
                radius: height / 2
                color: "transparent"
                opacity: 0
                visible: opacity > 0.001
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.rgba(capsule.accent.r, capsule.accent.g, capsule.accent.b, 0.34) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
                SequentialAnimation on opacity {
                    running: voice.state === "done"
                    NumberAnimation { to: 1.0; duration: 260; easing.type: Easing.OutCubic }
                    NumberAnimation { to: 0.0; duration: 640; easing.type: Easing.InQuad }
                }
            }

            MouseArea {
                id: cardZone
                visible: capsule.shown
                anchors.centerIn: parent
                width: card.width
                height: card.height
                onClicked: voice.cancel()

                Rectangle {
                    id: card

                    // Widths are per-state and animated, so the morph IS the
                    // state change. Height and y stay fixed.
                    readonly property int wideWidth: 460
                    readonly property int midWidth: 320
                    readonly property int dotWidth: 210

                    width: {
                        if (voice.state === "listening") return wideWidth
                        if (voice.state === "transcribing") return midWidth
                        if (voice.state === "working") return wideWidth
                        if (voice.state === "speaking") return midWidth
                        return dotWidth
                    }
                    // OutBack on a wide element reads as wobble; the pop
                    // comes from the glow and scale instead.
                    Behavior on width {
                        NumberAnimation { duration: 320; easing.type: Easing.OutCubic }
                    }

                    height: 76
                    radius: height / 2
                    x: (parent.width - width) / 2
                    y: (parent.height - height) / 2

                    // Glass: translucent crust over the compositor blur. A
                    // faint vertical falloff (lighter at the top) buys the
                    // depth a flat fill cannot -- light falls onto glass.
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Theme.alpha(Theme.crust, 0.62) }
                        GradientStop { position: 1.0; color: Theme.alpha(Theme.crust, 0.80) }
                    }
                    border.width: 1
                    border.color: Theme.alpha(capsule.accent, 0.55)
                    Behavior on border.color {
                        ColorAnimation { duration: Style.anim.colorDuration }
                    }

                    // Thinking: the border itself breathes blue, on the shell's
                    // one breath period. A pulse, not a spinner -- the card is
                    // alive while it waits.
                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: "transparent"
                        border.width: 2
                        border.color: Theme.blue
                        visible: voice.state === "working"
                        SequentialAnimation on opacity {
                            running: voice.state === "working"
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.9; duration: Style.anim.breath / 2; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 0.22; duration: Style.anim.breath / 2; easing.type: Easing.InOutSine }
                        }
                    }

                    layer.enabled: true
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        shadowBlur: 0.9
                        shadowVerticalOffset: 10
                        shadowColor: Qt.rgba(0, 0, 0, 0.45)
                        blurMax: 32
                    }

                    // Scale is DRIVEN, not bound: entering from hidden the card
                    // springs up from 0.90 through the pop; every later state
                    // change re-runs the pop, so each morph lands deliberate.
                    scale: 0.90
                    SequentialAnimation {
                        id: statePop
                        NumberAnimation { target: card; property: "scale"; to: 1.035; duration: 130; easing.type: Easing.OutCubic }
                        NumberAnimation { target: card; property: "scale"; to: 1.0; duration: 220; easing.type: Easing.InOutQuad }
                    }

                    // ------------------------------------------------ shine
                    // A soft highlight sweeping the card while something is
                    // alive -- listening or speaking. Cheap, but motion is
                    // what separates "alive" from "notification".
                    Rectangle {
                        id: shine
                        visible: voice.state === "listening" || voice.state === "speaking"
                        width: 120
                        height: parent.height - 20
                        radius: width / 2
                        y: (parent.height - height) / 2
                        x: -width
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: "transparent" }
                            GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.07) }
                            GradientStop { position: 1.0; color: "transparent" }
                        }
                        SequentialAnimation on x {
                            running: shine.visible
                            loops: Animation.Infinite
                            PauseAnimation { duration: 900 }
                            NumberAnimation { to: card.width + 10; duration: 1300; easing.type: Easing.InOutQuad }
                            PauseAnimation { duration: 2400 }
                            NumberAnimation { to: -shine.width; duration: 1 }
                        }
                    }

                    // -------------------------------------------------- ear
                    // Mic glyph wrapped in pulse rings while listening. The
                    // rings breathe on a clock; the glyph itself swells with
                    // the live level, so the icon is a level meter too.
                    Item {
                        id: mic
                        visible: voice.state === "listening"
                        width: 54
                        height: parent.height
                        anchors.left: parent.left
                        anchors.leftMargin: 20
                        anchors.verticalCenter: parent.verticalCenter

                        readonly property real level: {
                            var n = voice.levels.length
                            return n > 0 ? voice.levels[n - 1] : 0
                        }

                        // Rings expand and fade. Three of them, on periods
                        // that never settle into one beat and staggered
                        // entries -- two equal rings read as a metronome,
                        // three offset ones read as ripples.
                        Repeater {
                            model: 3

                            Rectangle {
                                required property int index

                                readonly property real period: [1700, 2150, 2550][index]
                                readonly property real offset: [0, 850, 1550][index]
                                readonly property real reach: [1.9, 2.15, 1.75][index]

                                anchors.centerIn: parent
                                width: 30
                                height: 30
                                radius: 15
                                color: "transparent"
                                border.width: 1.5
                                border.color: Theme.alpha(Theme.lavender, 0.5)
                                scale: 1
                                opacity: 0
                                SequentialAnimation on scale {
                                    loops: Animation.Infinite
                                    running: mic.visible
                                    PauseAnimation { duration: offset }
                                    NumberAnimation { to: reach; duration: period; easing.type: Easing.OutQuad }
                                    NumberAnimation { to: 1.0; duration: 1 }
                                }
                                SequentialAnimation on opacity {
                                    loops: Animation.Infinite
                                    running: mic.visible
                                    PauseAnimation { duration: offset }
                                    NumberAnimation { to: 0.65; duration: period * 0.22; easing.type: Easing.OutQuad }
                                    NumberAnimation { to: 0.0; duration: period * 0.78; easing.type: Easing.InQuad }
                                    NumberAnimation { to: 0.0; duration: 1 }
                                }
                            }
                        }

                        Text {
                            anchors.centerIn: parent
                            text: "󰍭"
                            color: Theme.lavender
                            font.family: Style.font.family
                            font.pixelSize: 22
                            // Scale, not font size: resizing a font re-shapes
                            // the glyph every frame and jitters.
                            scale: 1 + 0.25 * mic.level
                            Behavior on scale { NumberAnimation { duration: 90 } }
                        }
                    }

                    // ------------------------------------------------- stack
                    // The centre column: a small-caps state word on top, the
                    // sound strip (or, in working, the heard sentence) under
                    // it. Bars and text never share a row -- that overlap was
                    // the occlusion bug.
                    Column {
                        anchors.centerIn: parent
                        spacing: 8

                        // Working shows WHAT WAS HEARD as the main line --
                        // a mishear is visible the moment it happens, and the
                        // bars get out of the way entirely.
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: opacity > 0.01
                            opacity: voice.state === "working" ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 180 } }
                            width: card.width - 100
                            text: voice.interim
                            color: Theme.text
                            font.family: Style.font.family
                            font.pixelSize: Style.font.size + 2
                            elide: Text.ElideMiddle
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 7

                            // The thinking pulse: a small orb breathing beside
                            // the word, so working has a heartbeat, not just a
                            // label. The only dot in the capsule -- working
                            // owns it, and it breathes on the shell's one
                            // breath period.
                            Rectangle {
                                visible: voice.state === "working"
                                anchors.verticalCenter: parent.verticalCenter
                                width: 6
                                height: 6
                                radius: 3
                                color: Theme.blue
                                opacity: 0.35
                                SequentialAnimation on opacity {
                                    running: voice.state === "working"
                                    loops: Animation.Infinite
                                    NumberAnimation { to: 1.0; duration: Style.anim.breath / 2; easing.type: Easing.InOutSine }
                                    NumberAnimation { to: 0.35; duration: Style.anim.breath / 2; easing.type: Easing.InOutSine }
                                }
                            }

                            Text {
                                text: {
                                    if (voice.state === "listening") return "LISTENING"
                                    if (voice.state === "transcribing") return "TRANSCRIBING"
                                    if (voice.state === "working") return "THINKING"
                                    if (voice.state === "speaking") return "SPEAKING"
                                    return ""
                                }
                                // The mapping returns "" outside the four live
                                // states, so this shows in working too -- THINKING
                                // sits under the heard sentence in the Column.
                                visible: text !== ""
                                color: capsule.accent
                                opacity: 0.9
                                font.family: Style.font.family
                                font.pixelSize: 10
                                font.letterSpacing: 3
                                font.bold: true
                            }
                        }

                        Row {
                            id: bars
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: opacity > 0.01
                            opacity: (voice.state === "working" || voice.state === "done") ? 0 : 1
                            Behavior on opacity { NumberAnimation { duration: 180 } }
                            spacing: 3
                            bottomPadding: 2

                            property int tick: 0

                            Timer {
                                interval: 80
                                running: voice.state === "speaking" || voice.state === "transcribing"
                                repeat: true
                                onTriggered: bars.tick++
                            }

                            Repeater {
                                model: 36

                                Rectangle {
                                    required property int index

                                    width: 4
                                    radius: 2

                                    // Centre-out gradient: pink core to lavender
                                    // rim when listening, green core when
                                    // speaking. Same geometry, different light.
                                    readonly property real midDist:
                                        Math.abs(index - 17.5) / 17.5
                                    color: {
                                        if (voice.state === "speaking")
                                            return Qt.tint(Theme.green, Qt.rgba(Theme.teal.r, Theme.teal.g, Theme.teal.b, midDist * 0.7))
                                        if (voice.state === "listening")
                                            return Qt.tint(Theme.pink, Qt.rgba(Theme.lavender.r, Theme.lavender.g, Theme.lavender.b, midDist * 0.75))
                                        return Theme.mauve
                                    }

                                    readonly property real liveLevel: {
                                        var from = voice.levels.length - 36
                                        if (voice.state === "listening" && from >= 0)
                                            return voice.levels[from + index]
                                        return 0
                                    }
                                    readonly property real animLevel: {
                                        var t = bars.tick / 5
                                        if (voice.state === "speaking") {
                                            var env = 1 - 0.45 * midDist
                                            // A slow phrase swell over the fast
                                            // shimmer: a few seconds of energy, a
                                            // dip, then on again -- the cadence of
                                            // someone talking, not a steady motor.
                                            var phrase = 0.35 + 0.65 * Math.pow(Math.abs(Math.sin(t / 5.3 + 0.9)), 1.4)
                                            return env * phrase * (0.30 + 0.55 * Math.abs(Math.sin(t + index * 0.7) * Math.sin(t / 2.6 + index)))
                                        }
                                        // Transcribing: one pulse travelling the
                                        // strip, unmistakably "processing".
                                        var w = Math.sin(t - index * 0.42)
                                        return 0.10 + 0.55 * Math.pow(Math.max(0, w), 2)
                                    }
                                    height: 6 + 44 * (voice.state === "listening" ? liveLevel : animLevel)
                                    Behavior on height {
                                        NumberAnimation { duration: 100; easing.type: Easing.OutQuad }
                                    }
                                }
                            }
                        }
                    }

                    // -------------------------------------------------- done
                    // Nothing -- a finish is a slow fade of the whole
                    // capsule, not a green flash.
                }
            }
        }
    }
}
