import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import ".."

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

  // The photo + live weather is the catppuccin wallpaper (Theme.deskMode
  // "photo"). Any other desk -- a theme's own picture ("image") or a flat
  // colour, with or without a grid ("flat") -- runs NOTHING below: no weather
  // poll, no particles, no drift, no fog.
  readonly property bool live: Theme.deskMode === "photo"
  // The name/data pair is briefly mismatched mid-switch; wait for both.
  readonly property bool pictured: Theme.deskMode === "image" && Theme.deskImage !== ""
                                   && Theme.data.name === Theme.name
  // Desk grid pitch, px.
  readonly property int gridStep: 24

  // ------------------------------------------------------------ weather
  property real   temp: 0
  property string city: ""
  property string desc: ""
  property real   precip: 0
  property real   wind: 0
  property real   cloud: 0
  property int    code: 0
  property real   prob: -1             // % chance of rain this 15 min; -1 = unknown
  property bool   isDay: true
  property bool   dataOk: false

  // "" = follow the real weather. Anything else overrides it, for previewing.
  property string forced: ""

  // ---- how hard it is coming down, 0..1
  //
  // Three signals, because each one alone lies:
  //  * the WMO code says what KIND and roughly how strong (slight/moderate/
  //    heavy), but open-meteo's "current" is a model estimate for the grid
  //    square and will say "slight showers" over a dry street;
  //  * precip is mm in the last 15 minutes -- 2 mm in 15 is a downpour;
  //  * prob is the chance of rain in this slot. It scales the result, so a 20%
  //    "showers" is a few drops and a 90% one is the real thing.
  // Anything wet still shows at least a sprinkle (0.12), so it never says
  // rain while the desktop looks dry.
  readonly property var rainByCode: ({
    51: 0.15, 53: 0.25, 55: 0.35, 56: 0.2, 57: 0.35,      // drizzle
    61: 0.3,  63: 0.55, 65: 0.85, 66: 0.35, 67: 0.7,      // rain
    80: 0.3,  81: 0.6,  82: 0.95,                          // showers
    95: 0.7,  96: 0.85, 99: 0.95                           // thunderstorm
  })
  readonly property var snowByCode: ({ 71: 0.3, 73: 0.6, 75: 0.9, 77: 0.3, 85: 0.5, 86: 0.9 })
  readonly property real confidence: prob < 0 ? 1 : 0.45 + 0.55 * prob / 100
  readonly property real rainReal: {
    if (!dataOk) return 0
    var base = Math.max(rainByCode[code] || 0, Math.min(1, precip / 2))
    return base > 0 ? Math.max(0.12, base * confidence) : 0
  }
  readonly property real snowReal: dataOk ? (snowByCode[code] || 0) : 0
  readonly property bool drizzleReal: code >= 51 && code <= 57

  // A forced preview: name -> [rain, drizzle, snow, fog, storm].
  readonly property var presets: ({
    "drizzle":    [0.3,  1, 0,   0,    0],
    "rain-light": [0.18, 0, 0,   0,    0],
    "rain":       [0.5,  0, 0,   0,    0],
    "rain-heavy": [0.95, 0, 0,   0,    0],
    "storm":      [0.85, 0, 0,   0,    1],
    "snow":       [0,    0, 0.5, 0,    0],
    "snow-heavy": [0,    0, 1,   0,    0],
    "fog":        [0,    0, 0,   0.85, 0],
    "clear": [0, 0, 0, 0, 0], "cloudy": [0, 0, 0, 0, 0], "night": [0, 0, 0, 0, 0]
  })
  readonly property var preset: presets[forced] || null

  readonly property real rainAmount: !live ? 0 : preset ? preset[0] : (snowReal > 0 ? 0 : rainReal)
  readonly property bool drizzle:    preset ? preset[1] === 1 : drizzleReal
  readonly property real snowAmount: !live ? 0 : preset ? preset[2] : snowReal
  readonly property real fogAmount:  !live ? 0 : preset ? preset[3]
                                   : (dataOk ? (code === 48 ? 1 : code === 45 ? 0.8 : 0) : 0)

  readonly property bool showRain:  rainAmount > 0
  readonly property bool showSnow:  snowAmount > 0
  readonly property bool showFog:   fogAmount > 0
  readonly property bool showStorm: live && (preset ? preset[4] === 1 : (dataOk && code >= 95))
  readonly property bool showNight: live && (forced === "night" || (forced === "" && dataOk && !isDay))

  // What the corner readout says: the strength we actually draw, not the raw
  // code, so the words and the picture agree.
  readonly property string label: {
    var a = showSnow ? snowAmount : rainAmount
    var k = a < 0.3 ? "light" : a < 0.65 ? "" : "heavy"
    var noun = showStorm ? "Thunderstorm"
             : showSnow ? "snow"
             : showFog && !showRain ? "Fog"
             : !showRain ? (preset ? forced.charAt(0).toUpperCase() + forced.slice(1) : desc)
             : drizzle ? "drizzle"
             : (code >= 80 && code <= 82 && !preset) ? "showers" : "rain"
    if (showStorm || (!showRain && !showSnow)) return noun
    var s = (k === "" ? noun : k + " " + noun)
    return s.charAt(0).toUpperCase() + s.slice(1)
  }

  // Clear skies leave the photo alone; overcast cools and flattens it.
  readonly property real cloudWash: !live ? 0
                                  : forced === "clear"  ? 0
                                  : forced === "cloudy" ? 0.28
                                  : (dataOk ? Math.min(0.30, cloud / 100 * 0.30) : 0)

  IpcHandler {
    target: "wallpaper"
    function force(state: string): string {
      var ok = Object.keys(root.presets).concat(["off", ""])
      if (ok.indexOf(state) === -1) return "unknown state. use: " + ok.join(" ")
      root.forced = (state === "off") ? "" : state
      return root.forced === "" ? "following real weather" : "forced: " + root.forced
    }
    function refresh(): string { weatherProc.running = true; return "refreshing" }
    function status(): string {
      if (!root.dataOk) return "no data"
      return root.city + " " + root.temp + "C " + root.desc
           + " precip=" + root.precip + " wind=" + root.wind + " cloud=" + root.cloud
           + " day=" + (root.isDay ? 1 : 0) + " code=" + root.code + " prob=" + root.prob
           + " -> rain=" + root.rainAmount.toFixed(2) + " snow=" + root.snowAmount.toFixed(2)
           + " fog=" + root.fogAmount.toFixed(2) + (root.showStorm ? " storm" : "")
           + (root.forced === "" ? "" : " [FORCED " + root.forced + "]")
    }
  }

  Process {
    id: weatherProc
    command: ["weather-now"]
    running: root.live
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var d = JSON.parse(this.text)
          if (!d.ok) { root.dataOk = false; return }
          root.temp = d.temp; root.city = d.city; root.desc = d.desc
          root.precip = d.precip; root.wind = d.wind || 0; root.cloud = d.cloud || 0
          root.isDay = d.isDay === 1
          root.code = d.code || 0
          root.prob = (d.prob === undefined || d.prob === null) ? -1 : d.prob
          root.dataOk = true
        } catch (e) { root.dataOk = false }
      }
    }
  }

  Timer { interval: 15 * 60 * 1000; running: root.live; repeat: true; onTriggered: weatherProc.running = true }
  // Switching back to the photo: fetch the sky now rather than in <=15 min.
  onLiveChanged: if (live) weatherProc.running = true

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData

      anchors { top: true; bottom: true; left: true; right: true }
      color: root.live ? Theme.crust : Theme.deskBackground
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.exclusionMode: ExclusionMode.Ignore
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region {}                       // never take input; clicks belong to the desktop

      readonly property int fps: UPower.onBattery ? 20 : 24
      // The one clock for everything that moves continuously (rain, snow, the
      // photo drift). Ticks at `fps`, so the scene -- and Hyprland, which has
      // to recomposite the whole screen for a background that changes --
      // renders 20-24 times a second instead of at vsync. The cost is almost
      // all per frame (a full-screen redraw at an idle GPU clock), not the
      // effects, so this number is the lever.
      property real clock: 0
      Timer {
        interval: 1000 / win.fps
        running: (root.showRain || root.showSnow || root.showStorm || root.showFog) && win.visible
        repeat: true
        onTriggered: win.clock += interval / 1000
      }
      // Wind tilts the falling particles. 0 km/h is straight down; the cap
      // stops a gale from making it fall sideways off-screen.
      readonly property real slant: Math.min(0.55, root.wind / 45)

      // ----------------------------------------------------------- desk
      // Brutal themes: flat desk colour (the window's own fill) plus a grid of
      // 1px lines. Static -- built once per theme switch, never repainted.
      Item {
        anchors.fill: parent
        visible: !root.live && Theme.deskHasGrid

        Repeater {
          model: parent.visible ? Math.ceil(win.width / root.gridStep) : 0
          Rectangle {
            required property int index
            x: index * root.gridStep
            width: 1
            height: win.height
            color: Theme.deskGrid
          }
        }
        Repeater {
          model: parent.visible ? Math.ceil(win.height / root.gridStep) : 0
          Rectangle {
            required property int index
            y: index * root.gridStep
            width: win.width
            height: 1
            color: Theme.deskGrid
          }
        }
      }

      // ------------------------------------------------------ theme image
      // The theme dir's own wallpaper, cover-fit. Two slots cross-fade on a
      // switch: the new picture loads into the hidden slot and fades in over the
      // old one, which is then released. A missing file leaves the window's
      // deskBackground showing.
      property Item front: null
      readonly property string wanted: root.pictured ? "file://" + Theme.deskImage : ""
      function load() {
        var next = win.front === slotA ? slotB : slotA
        if (win.wanted === "") { win.front = null; return }
        if (win.front && win.front.source.toString() === win.wanted) return
        next.source = win.wanted          // becomes front once Ready
      }
      property bool built: false
      onWantedChanged: if (built) load()
      Component.onCompleted: { built = true; load() }

      component DeskImage: Image {
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
        sourceSize.width: win.width
        sourceSize.height: win.height
        opacity: win.front === this ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 450; easing.type: Easing.InOutQuad } }
        onStatusChanged: if (status === Image.Ready && source.toString() === win.wanted) win.front = this
        // Once faded out, let go of the old picture.
        onVisibleChanged: if (!visible && win.front !== this) source = ""
      }
      DeskImage { id: slotA }
      DeskImage { id: slotB }

      // ---------------------------------------------------------- photo
      Image {
        id: photo
        anchors.fill: parent
        visible: root.live
        // Not even loaded under a brutal theme.
        source: root.live ? "file:///usr/share/hypr/wall2.png" : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: win.width * 1.12
        smooth: true

        // Ken Burns, ONLY while something is already animating, and driven by
        // the throttled weather clock below rather than its own animation.
        //
        // It ran unconditionally once and cost 8.4% CPU forever, for a drift
        // tuned below the point where you notice it. Then, as a NumberAnimation
        // gated on the weather, it still forced the whole scene to render at
        // full vsync while it rained -- whatever the rain itself was throttled
        // to. A sine of the clock moves only when the clock ticks.
        transform: [
          Scale { origin.x: photo.width / 2; origin.y: photo.height / 2; xScale: 1.06; yScale: 1.06 },
          Translate {
            x: 22 * Math.sin(win.clock * 2 * Math.PI / 180)
            y: 14 * Math.sin(win.clock * 2 * Math.PI / 240)
          }
        ]
      }

      // ------------------------------------------------------ cloud wash
      // Overcast cools and flattens the photo rather than just dimming it.
      Rectangle {
        anchors.fill: parent
        color: Theme.weatherCloud
        opacity: root.cloudWash
        Behavior on opacity { NumberAnimation { duration: 3000; easing.type: Easing.InOutSine } }
      }

      // ------------------------------------------------------- night dim
      // The bar sits on this wallpaper, so after dark the photo has to give way
      // or light text stops being readable.
      Rectangle {
        anchors.fill: parent
        color: Theme.weatherNight
        opacity: root.showNight ? 0.18 : 0
        Behavior on opacity { NumberAnimation { duration: 4000; easing.type: Easing.InOutSine } }
      }

      // -------------------------------------------------- falling things
      // All the weather is one fragment shader (shaders/weather.frag): rain
      // from drizzle to downpour, snow, fog, and the storm flash lighting the
      // rain. The rain used to be a QML Canvas drawn on the CPU and the fog two
      // sliding gradient bands animated at vsync.
      ShaderEffect {
        anchors.fill: parent
        readonly property bool wanted: root.showRain || root.showSnow || root.showFog
        visible: opacity > 0
        opacity: wanted ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 1500 } }
        fragmentShader: Qt.resolvedUrl("shaders/weather-v4.frag.qsb")

        // Uniform-block members are matched by property name. The amounts are
        // eased so a change of strength fades instead of jumping.
        property real time: win.clock
        property vector2d resolution: Qt.vector2d(width, height)
        property real rain: root.rainAmount
        property real drizzle: root.drizzle ? 1 : 0
        property real snow: root.snowAmount
        property real fog: root.fogAmount
        property real slant: win.slant
        property real flash: lightning.opacity
        property color rainColor: Theme.weatherRain
        property color snowColor: Theme.weatherSnow
        property color fogColor: Theme.weatherFog
        Behavior on rain { NumberAnimation { duration: 4000 } }
        Behavior on snow { NumberAnimation { duration: 4000 } }
        Behavior on fog  { NumberAnimation { duration: 4000 } }
      }

      // ----------------------------------------------------------- storm
      // A flash is a full-screen white veil at low opacity, fired at irregular
      // intervals. Regular lightning would read as a broken monitor.
      Rectangle {
        id: lightning
        anchors.fill: parent
        color: Theme.weatherFlash
        opacity: 0
        visible: root.showStorm

        SequentialAnimation {
          id: strike
          NumberAnimation { target: lightning; property: "opacity"; to: 0.55; duration: 60 }
          NumberAnimation { target: lightning; property: "opacity"; to: 0.10; duration: 90 }
          NumberAnimation { target: lightning; property: "opacity"; to: 0.38; duration: 70 }
          NumberAnimation { target: lightning; property: "opacity"; to: 0;    duration: 700; easing.type: Easing.OutCubic }
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
        visible: root.live
        opacity: root.dataOk ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 800 } }

        Text {
          anchors.right: parent.right
          text: root.dataOk ? Math.round(root.temp) + "°" : ""
          font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 64; font.weight: Font.Light
          color: Theme.text; opacity: 0.85
        }
        Text {
          anchors.right: parent.right
          text: root.label
                + (root.forced === "" && (root.showRain || root.showSnow) && root.prob >= 0 ? "  ·  " + root.prob + "%" : "")
                + (root.forced === "" ? "" : "  ·  [" + root.forced + "]")
          font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 17
          color: Theme.text; opacity: 0.65
        }
        Text {
          anchors.right: parent.right
          text: root.city + (root.wind > 0 ? "   " + Math.round(root.wind) + " km/h" : "")
          font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13
          color: Theme.subtext0; opacity: 0.5
        }
      }
    }
  }
}
