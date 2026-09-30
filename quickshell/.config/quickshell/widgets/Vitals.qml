import QtQuick
import Quickshell
import Quickshell.Services.UPower
import "root:/"

// Vitals -- a per-thread CPU spectrum and the CPU temperature, with a hover
// popup for GPU and memory. Data comes from the SysStats singleton.
//
// One bar per thread rather than a single percentage, because a single number
// hides the thing you actually want to know: whether ONE core is pinned (a bad
// build step) or all of them are (llama-server).
//
// RAM is always shown, in GB. GPU and temp earn a slot only when they are busy
// (SysStats.gpuActive / tempActive, both with hysteresis).
//
// Width changes ONLY when a segment comes or goes -- every number sits in a
// slot sized once from TextMetrics, so a chip ticking every second never
// shoves its neighbours around.
//
// Bars are STEPPED. A Behavior on 24 rectangles repainting the bar every frame
// is not worth the smoothness at a 1s sample.
BarWidget {
  id: root

  spacing: 6
  hoverHighlight: true

  // Theme accent while calm, peach when busy, red when pinned -- the same three
  // steps the temperature uses, so the chip reads as one thing.
  function heat(v) {
    return v >= 90 ? Theme.red : v >= 60 ? Theme.peach : Theme.accent
  }
  function tempColor(t) {
    return t >= 90 ? Theme.red : t >= 80 ? Theme.peach : Theme.subtext0
  }

  // ------------------------------------------------------------ the chip
  Item {
    id: spec
    readonly property real pitch: 2
    width: pitch * Math.max(1, SysStats.coreCount) - 1
    height: 14

    Repeater {
      model: SysStats.coreCount

      Rectangle {
        required property int index
        readonly property real load: SysStats.coreLoad[index] || 0
        x: index * spec.pitch
        width: 1
        height: Math.max(1, Math.round(spec.height * load / 100))
        anchors.bottom: parent.bottom
        color: root.heat(load)
        opacity: load < 5 ? 0.45 : 1
      }
    }
  }

  TextMetrics { id: pctMetrics; font: temp.font; text: "100%" }

  // A GPU / NPU / RAM segment: icon + an optional number, sliding open when it becomes active.
  component Segment: Item {
    id: seg
    property bool active: false
    property string icon: ""
    property real value: 0          // 0..100
    property string label: Math.round(value) + "%"
    property color tint: Theme.accent

    height: 16
    width: active ? segRow.implicitWidth : 0
    opacity: active ? 1 : 0
    visible: width > 0.5
    clip: true
    Behavior on width { NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing } }
    Behavior on opacity { NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth } }

    Row {
      id: segRow
      anchors.verticalCenter: parent.verticalCenter
      spacing: 3
      leftPadding: 4
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: seg.icon
        color: seg.tint
        font.family: Style.font.family
        font.pixelSize: Style.font.tiny + 1
        renderType: Text.NativeRendering
      }
      Text {
        visible: seg.label !== ""
        anchors.verticalCenter: parent.verticalCenter
        width: pctMetrics.width
        horizontalAlignment: Text.AlignRight
        text: seg.label
        color: seg.tint
        font.family: Style.font.family
        font.pixelSize: Style.font.tiny
        renderType: Text.NativeRendering
      }
    }
  }

  Segment {
    active: SysStats.gpuActive
    icon: "󰢮"
    value: SysStats.gpuBusy
    tint: root.heat(SysStats.gpuBusy)
  }

  // NPU: on/off only -- the driver exposes no busy %, just whether it is awake.
  Segment {
    active: SysStats.npuActive
    icon: "󰧑"
    label: ""
    tint: Theme.accent
  }

  Segment {
    // Always on -- RAM is the one figure worth a glance at any time.
    active: SysStats.ramTotal > 0
    icon: "󰍛"
    label: SysStats.ramUsed.toFixed(0) + "G"
    tint: SysStats.ramFrac >= 0.93 ? Theme.red : SysStats.ramFrac >= 0.85 ? Theme.peach : Theme.accent
  }

  // Last, after RAM. Temp only when it is worth reading: in at 70°, out under 67° (SysStats).
  Item {
    readonly property bool active: SysStats.tempActive
    height: 16
    // +4: the same lead-in gap the segments carry as leftPadding.
    width: active ? tempMetrics.width + 4 : 0
    opacity: active ? 1 : 0
    visible: width > 0.5
    clip: true
    Behavior on width { NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing } }
    Behavior on opacity { NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth } }

    Text {
      id: temp
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: SysStats.cpuTemp + "°"
      color: root.tempColor(SysStats.cpuTemp)
      font.family: Style.font.family
      font.pixelSize: Style.font.tiny
      renderType: Text.NativeRendering

      TextMetrics { id: tempMetrics; font: temp.font; text: "00°" }
    }
  }

  // ------------------------------------------------------------ open/close
  // Hover raises it, leaving drops it shortly after (same life as the Windows
  // overflow popup). A click pins it open until the next click.
  property bool popupOpen: false
  property bool pinned: false

  onHoveredChanged: {
    if (hovered) { hideTimer.stop(); popupOpen = true }
    else if (!pinned) hideTimer.restart()
  }
  onClicked: {
    pinned = !pinned
    popupOpen = pinned || hovered
  }

  Timer { id: hideTimer; interval: 200; onTriggered: if (!root.pinned) root.popupOpen = false }

  // Only pay for GPU/memory reads while the popup is up.
  onPopupOpenChanged: SysStats.detail += popupOpen ? 1 : -1
  Component.onDestruction: if (popupOpen) SysStats.detail -= 1

  // ----------------------------------------------------------------- popup
  PopupWindow {
    id: popup

    visible: root.popupOpen
    color: "transparent"

    readonly property int pad: Theme.shadowPad
    readonly property int cardW: 340
    implicitWidth: cardW + Theme.shadowX + 2 * pad
    implicitHeight: Math.ceil(card.height) + Theme.shadowY + 2 * pad

    anchor {
      item: root
      adjustment: PopupAdjustment.Slide
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.x: Math.round(root.width / 2 - popup.cardW / 2) - popup.pad
      rect.y: root.height + 8 - popup.pad
    }

    HardShadow { target: card }
    SoftShadow { target: card }

    Rectangle {
      id: card
      x: popup.pad
      y: popup.pad
      width: popup.cardW
      height: body.implicitHeight + 24
      color: Theme.tooltipBackground
      border.width: Theme.tooltipBorderWidth
      border.color: Theme.tooltipBorder
      radius: Theme.chipRadius >= 0 ? Theme.chipRadius : Style.module.radius

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onEntered: hideTimer.stop()
        onExited: if (!root.pinned) hideTimer.restart()
      }

      // Deliberately NOT NativeRendering in here: the popup is hidden and
      // reshown constantly, and NativeRendering glyphs can blank on a
      // window's second showing (see Windows.qml).
      Column {
        id: body
        x: 14
        y: 12
        width: parent.width - 28
        spacing: 8

        // ----------------------------------------------------------- cpu
        Row {
          width: parent.width
          Text {
            width: 44
            text: "CPU"
            color: Theme.accent
            font.family: Style.font.family; font.pixelSize: Style.font.tiny
            font.weight: Style.font.boldWeight
          }
          Text {
            text: Math.round(SysStats.cpuAvg) + "%  ·  peak " + Math.round(SysStats.cpuPeak)
                + "%  ·  " + SysStats.cpuTemp + "°C  ·  " + SysStats.cpuGhz.toFixed(1) + " GHz"
            color: Theme.foreground
            font.family: Style.font.family; font.pixelSize: Style.font.tiny
          }
        }

        Item {
          id: bigSpec
          width: parent.width
          height: 34
          readonly property real pitch: width / Math.max(1, SysStats.coreCount)

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width; height: 1
            color: Theme.surface1
          }
          Repeater {
            model: SysStats.coreCount
            Rectangle {
              required property int index
              readonly property real load: SysStats.coreLoad[index] || 0
              x: index * bigSpec.pitch
              width: Math.max(2, bigSpec.pitch - 3)
              height: Math.max(1, Math.round(bigSpec.height * load / 100))
              anchors.bottom: parent.bottom
              radius: 1.5
              color: root.heat(load)
            }
          }
        }

        // What the clock is ALLOWED to do right now. "capped" only when the
        // policy max is below the silicon's boost ceiling -- on battery the
        // firmware pins it at 2.0 GHz, which was invisible before this line.
        Row {
          leftPadding: 44
          Text {
            text: SysStats.cpuMin.toFixed(1) + " – " + SysStats.cpuMax.toFixed(1) + " GHz"
            color: Theme.subtext0
            font.family: Style.font.family; font.pixelSize: Style.font.tiny
          }
          Text {
            visible: SysStats.cpuCapped
            text: "  ·  capped (max " + SysStats.cpuHwMax.toFixed(1) + ")"
            color: Theme.peach
            font.family: Style.font.family; font.pixelSize: Style.font.tiny
          }
        }

        // ----------------------------------------------------------- gpu
        Row {
          width: parent.width
          topPadding: 2
          Text {
            width: 44
            text: "GPU"
            color: Theme.accent
            font.family: Style.font.family; font.pixelSize: Style.font.tiny
            font.weight: Style.font.boldWeight
          }
          Text {
            text: SysStats.gpuBusy + "%  ·  " + SysStats.gpuClock + " MHz  ·  "
                + SysStats.gpuWatts.toFixed(0) + " W"
            color: Theme.foreground
            font.family: Style.font.family; font.pixelSize: Style.font.tiny
          }
        }

        // ----------------------------------------------------------- ram
        // One bar, because on this APU GTT *is* system RAM: the darker slice
        // is the part of "used" that the GPU is holding.
        Row {
          width: parent.width
          topPadding: 2
          Text {
            width: 44
            text: "RAM"
            color: Theme.accent
            font.family: Style.font.family; font.pixelSize: Style.font.tiny
            font.weight: Style.font.boldWeight
          }
          Text {
            text: SysStats.ramUsed.toFixed(1) + " / " + SysStats.ramTotal.toFixed(0) + " GB"
            color: Theme.foreground
            font.family: Style.font.family; font.pixelSize: Style.font.tiny
          }
        }

        Rectangle {
          id: ramTrack
          width: parent.width
          height: 6
          radius: 3
          color: Theme.surface0
          clip: true

          readonly property real frac: SysStats.ramTotal > 0 ? Math.min(1, SysStats.ramUsed / SysStats.ramTotal) : 0
          readonly property real gttFrac: SysStats.ramTotal > 0
              ? Math.min(frac, SysStats.gttUsed / SysStats.ramTotal) : 0

          Rectangle {
            width: ramTrack.width * ramTrack.frac
            height: parent.height
            radius: 3
            color: ramTrack.frac >= 0.9 ? Theme.red : ramTrack.frac >= 0.75 ? Theme.peach : Theme.accent
          }
          // gtt slice, drawn at the right end of the used part
          Rectangle {
            x: ramTrack.width * (ramTrack.frac - ramTrack.gttFrac)
            width: ramTrack.width * ramTrack.gttFrac
            height: parent.height
            color: Theme.accent2
            opacity: 0.55
          }
        }

        Row {
          spacing: 14
          Row {
            spacing: 5
            Rectangle {
              width: 8; height: 8; radius: 2
              anchors.verticalCenter: parent.verticalCenter
              color: Theme.accent2; opacity: 0.55
            }
            Text {
              text: "gtt " + SysStats.gttUsed.toFixed(1) + " / " + SysStats.gttTotal.toFixed(0) + " GB"
              color: Theme.subtext0
              font.family: Style.font.family; font.pixelSize: Style.font.tiny
            }
          }
          Text {
            text: "vram " + SysStats.vramUsed.toFixed(0) + " / " + SysStats.vramTotal.toFixed(0) + " MB"
            color: Theme.subtext0
            font.family: Style.font.family; font.pixelSize: Style.font.tiny
          }
        }

        // ------------------------------------------------------- battery
        // Only off the charger. UPower reports 0.016 W and a 169-day
        // estimate while plugged, which is noise.
        Row {
          visible: UPower.onBattery
          width: parent.width
          topPadding: 2
          Text {
            width: 44
            text: "BAT"
            color: Theme.accent
            font.family: Style.font.family; font.pixelSize: Style.font.tiny
            font.weight: Style.font.boldWeight
          }
          Text {
            text: Math.round(UPower.displayDevice.percentage * 100) + "%  ·  "
                + UPower.displayDevice.changeRate.toFixed(0) + " W  ·  "
                + root.fmtTime(UPower.displayDevice.timeToEmpty)
            color: Theme.foreground
            font.family: Style.font.family; font.pixelSize: Style.font.tiny
          }
        }
      }
    }
  }

  function fmtTime(sec) {
    if (!sec || sec <= 0) return "--"
    const h = Math.floor(sec / 3600)
    const m = Math.round((sec % 3600) / 60)
    return h + "h" + (m < 10 ? "0" : "") + m
  }
}
