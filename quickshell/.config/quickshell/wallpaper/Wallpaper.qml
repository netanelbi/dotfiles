import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower

// Live wallpaper. The photo drifts, the real weather is polled every 15
// minutes, and the desktop reacts to it: rain, snow, fog, storm flashes, a
// cloud wash, and a night dim.
//
// A wallpaper here is a PanelWindow on the BACKGROUND layer, so it is a full
// QML scene rather than a static image -- the thing awww/swww structurally
// cannot do. It also renders continuously, unlike a PNG, so every effect is
// throttled and anything not currently needed is `visible: false` (which stops
// its Timer, not merely its painting).
//
// Preview any state without waiting for the sky:
//   qs -p <config> ipc call wallpaper force rain|snow|fog|storm|clear|cloudy|night|off
Scope {
  id: root

  // ------------------------------------------------------------ weather
  property real   temp: 0
  property string city: ""
  property string desc: ""
  property real   precip: 0
  property real   wind: 0
  property real   cloud: 0
  property bool   isDay: true
  property bool   dataOk: false

  // "" = follow the real weather. Anything else overrides it, for previewing.
  property string forced: ""

  readonly property bool wetReal: dataOk && (precip > 0 || ["Rain", "Drizzle", "Showers", "Thunderstorm"].indexOf(desc) !== -1)
  readonly property bool snowReal: dataOk && (desc === "Snow" || desc === "Snow showers")

  readonly property bool showRain:  forced === "rain"  || forced === "storm" || (forced === "" && wetReal && !snowReal)
  readonly property bool showSnow:  forced === "snow"  || (forced === "" && snowReal)
  readonly property bool showFog:   forced === "fog"   || (forced === "" && dataOk && desc === "Fog")
  readonly property bool showStorm: forced === "storm" || (forced === "" && dataOk && desc === "Thunderstorm")
  readonly property bool showNight: forced === "night" || (forced === "" && dataOk && !isDay)
  // Clear skies leave the photo alone; overcast cools and flattens it.
  readonly property real cloudWash: forced === "clear"  ? 0
                                  : forced === "cloudy" ? 0.28
                                  : (dataOk ? Math.min(0.30, cloud / 100 * 0.30) : 0)

  IpcHandler {
    target: "wallpaper"
    function force(state: string): string {
      var ok = ["rain", "snow", "fog", "storm", "clear", "cloudy", "night", "off", ""]
      if (ok.indexOf(state) === -1) return "unknown state. use: " + ok.join(" ")
      root.forced = (state === "off") ? "" : state
      return root.forced === "" ? "following real weather" : "forced: " + root.forced
    }
    function refresh(): string { weatherProc.running = true; return "refreshing" }
    function status(): string {
      if (!root.dataOk) return "no data"
      return root.city + " " + root.temp + "C " + root.desc
           + " precip=" + root.precip + " wind=" + root.wind + " cloud=" + root.cloud
           + " day=" + (root.isDay ? 1 : 0)
           + (root.forced === "" ? "" : " [FORCED " + root.forced + "]")
    }
  }

  Process {
    id: weatherProc
    command: ["weather-now"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var d = JSON.parse(this.text)
          if (!d.ok) { root.dataOk = false; return }
          root.temp = d.temp; root.city = d.city; root.desc = d.desc
          root.precip = d.precip; root.wind = d.wind || 0; root.cloud = d.cloud || 0
          root.isDay = d.isDay === 1
          root.dataOk = true
        } catch (e) { root.dataOk = false }
      }
    }
  }

  Timer { interval: 15 * 60 * 1000; running: true; repeat: true; onTriggered: weatherProc.running = true }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData

      anchors { top: true; bottom: true; left: true; right: true }
      color: "#11111b"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.exclusionMode: ExclusionMode.Ignore
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region {}                       // never take input; clicks belong to the desktop

      readonly property int fps: UPower.onBattery ? 20 : 40
      // Wind tilts the falling particles. 0 km/h is straight down; the cap
      // stops a gale from making it fall sideways off-screen.
      readonly property real slant: Math.min(0.55, root.wind / 45)

      // ---------------------------------------------------------- photo
      Image {
        id: photo
        anchors.fill: parent
        source: "file:///usr/share/hypr/wall2.png"
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: win.width * 1.12
        smooth: true

        transform: [
          Scale { origin.x: photo.width / 2; origin.y: photo.height / 2; xScale: 1.06; yScale: 1.06 },
          Translate { id: drift }
        ]

        // Ken Burns, ONLY while something is already animating.
        //
        // This ran unconditionally and cost 8.4% CPU forever -- to produce a
        // drift deliberately tuned below the threshold where you notice it.
        // Paying that on battery for an invisible effect is the worst trade in
        // the file. A QML scene with no running animation repaints zero times
        // and costs 0.0% CPU (measured), so calm weather now means a genuinely
        // static wallpaper, exactly like awww.
        SequentialAnimation {
          running: root.showRain || root.showSnow || root.showStorm
          loops: Animation.Infinite
          ParallelAnimation {
            NumberAnimation { target: drift; property: "x"; from: -22; to: 22; duration: 90000; easing.type: Easing.InOutSine }
            NumberAnimation { target: drift; property: "y"; from: 14; to: -14; duration: 120000; easing.type: Easing.InOutSine }
          }
          ParallelAnimation {
            NumberAnimation { target: drift; property: "x"; from: 22; to: -22; duration: 90000; easing.type: Easing.InOutSine }
            NumberAnimation { target: drift; property: "y"; from: -14; to: 14; duration: 120000; easing.type: Easing.InOutSine }
          }
        }
      }

      // ------------------------------------------------------ cloud wash
      // Overcast cools and flattens the photo rather than just dimming it.
      Rectangle {
        anchors.fill: parent
        color: "#1e2030"
        opacity: root.cloudWash
        Behavior on opacity { NumberAnimation { duration: 3000; easing.type: Easing.InOutSine } }
      }

      // ------------------------------------------------------- night dim
      // The bar sits on this wallpaper, so after dark the photo has to give way
      // or light text stops being readable.
      Rectangle {
        anchors.fill: parent
        color: "#0b0b14"
        opacity: root.showNight ? 0.18 : 0
        Behavior on opacity { NumberAnimation { duration: 4000; easing.type: Easing.InOutSine } }
      }

      // -------------------------------------------------- falling things
      // One canvas for rain AND snow: same particle loop, different physics and
      // paint. Two canvases would double the timers for an either/or effect.
      Canvas {
        id: fall
        anchors.fill: parent
        visible: root.showRain || root.showSnow
        opacity: visible ? 1 : 0
        renderStrategy: Canvas.Cooperative
        Behavior on opacity { NumberAnimation { duration: 1500 } }

        readonly property bool snowing: root.showSnow
        property var drops: []
        readonly property int count: snowing
          ? Math.round((width * height) / 26000)     // snow is sparser and slower
          : Math.round((width * height) / 12000)

        function seed() {
          var a = []
          for (var i = 0; i < count; i++) {
            a.push({
              x: Math.random() * width,
              y: Math.random() * height,
              len: snowing ? (1.6 + Math.random() * 2.4) : (8 + Math.random() * 14),
              spd: snowing ? (0.7 + Math.random() * 1.3) : (7 + Math.random() * 11),
              op:  snowing ? (0.25 + Math.random() * 0.5) : (0.15 + Math.random() * 0.35),
              ph:  Math.random() * 6.28                // snow sway phase
            })
          }
          drops = a
        }
        onWidthChanged: seed()
        onHeightChanged: seed()
        onSnowingChanged: seed()
        Component.onCompleted: seed()

        property real t: 0

        onPaint: {
          var ctx = getContext("2d")
          if (!ctx) return
          ctx.reset()
          t += 0.02

          if (snowing) {
            ctx.fillStyle = "#e8eefc"
            for (var i = 0; i < drops.length; i++) {
              var f = drops[i]
              ctx.globalAlpha = f.op
              ctx.beginPath()
              // Snow drifts sideways on a sine rather than falling straight.
              var sx = f.x + Math.sin(t + f.ph) * 14
              ctx.arc(sx, f.y, f.len, 0, 6.2832)
              ctx.fill()
              f.y += f.spd
              if (f.y - f.len > height) { f.y = -f.len; f.x = Math.random() * width }
            }
          } else {
            ctx.strokeStyle = "#a6c8e8"        // cool and desaturated, not neon
            ctx.lineWidth = 1
            for (var j = 0; j < drops.length; j++) {
              var d = drops[j]
              ctx.globalAlpha = d.op
              ctx.beginPath()
              ctx.moveTo(d.x, d.y)
              ctx.lineTo(d.x - d.len * win.slant, d.y + d.len)
              ctx.stroke()
              d.y += d.spd
              d.x -= d.spd * win.slant
              if (d.y > height) { d.y = -d.len; d.x = Math.random() * width }
              else if (d.x < -20) { d.x = width + 10 }
            }
          }
          ctx.globalAlpha = 1
        }

        Timer {
          interval: 1000 / win.fps
          running: fall.visible && win.visible
          repeat: true
          onTriggered: fall.requestPaint()
        }
      }

      // ------------------------------------------------------------- fog
      // Two translucent bands drifting at different speeds -- parallax reads as
      // depth far more cheaply than a particle field would.
      Item {
        anchors.fill: parent
        visible: root.showFog
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 2500 } }

        Repeater {
          model: 2
          Rectangle {
            required property int index
            width: parent.width * 1.6
            height: parent.height * (index === 0 ? 0.42 : 0.30)
            y: parent.height * (index === 0 ? 0.34 : 0.58)
            opacity: index === 0 ? 0.20 : 0.14
            gradient: Gradient {
              orientation: Gradient.Vertical
              GradientStop { position: 0.0; color: "#00c8d3e8" }
              GradientStop { position: 0.5; color: "#ffc8d3e8" }
              GradientStop { position: 1.0; color: "#00c8d3e8" }
            }
            // MUST be gated on visibility. `visible: false` on the parent stops
            // PAINTING, not animating -- these two bands kept running forever
            // and were still costing 6.8% CPU on a clear night, after the Ken
            // Burns drift had already been made conditional. A QML animation
            // runs wherever it is declared unless something stops it.
            NumberAnimation on x {
              running: root.showFog && win.visible
              loops: Animation.Infinite
              from: -parent.width * 0.6; to: 0
              duration: index === 0 ? 42000 : 67000
            }
          }
        }
      }

      // ----------------------------------------------------------- storm
      // A flash is a full-screen white veil at low opacity, fired at irregular
      // intervals. Regular lightning would read as a broken monitor.
      Rectangle {
        id: flash
        anchors.fill: parent
        color: "#dce6ff"
        opacity: 0
        visible: root.showStorm

        SequentialAnimation {
          id: strike
          NumberAnimation { target: flash; property: "opacity"; to: 0.55; duration: 60 }
          NumberAnimation { target: flash; property: "opacity"; to: 0.10; duration: 90 }
          NumberAnimation { target: flash; property: "opacity"; to: 0.38; duration: 70 }
          NumberAnimation { target: flash; property: "opacity"; to: 0;    duration: 700; easing.type: Easing.OutCubic }
        }

        Timer {
          interval: 4000
          running: root.showStorm && win.visible
          repeat: true
          onTriggered: {
            // Only sometimes, and re-randomise the wait, so it never feels timed.
            if (Math.random() < 0.45) strike.restart()
            interval = 3000 + Math.random() * 9000
          }
        }
      }

      // --------------------------------------------------------- readout
      Column {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 46
        spacing: 2
        opacity: root.dataOk ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 800 } }

        Text {
          anchors.right: parent.right
          text: root.dataOk ? Math.round(root.temp) + "°" : ""
          font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 64; font.weight: Font.Light
          color: "#cdd6f4"; opacity: 0.85
        }
        Text {
          anchors.right: parent.right
          text: root.forced === "" ? root.desc : root.desc + "  ·  [" + root.forced + "]"
          font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 17
          color: "#cdd6f4"; opacity: 0.65
        }
        Text {
          anchors.right: parent.right
          text: root.city + (root.wind > 0 ? "   " + Math.round(root.wind) + " km/h" : "")
          font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13
          color: "#a6adc8"; opacity: 0.5
        }
      }
    }
  }
}
