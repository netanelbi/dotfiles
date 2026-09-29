pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// System vitals for the bar's Vitals chip: per-core CPU load, CPU temp, and --
// only while someone is looking at the popup -- GPU and memory.
//
// One instance for every bar, so two monitors do not sample twice.
//
// ----------------------------------------------------------------- the cost
// Two clocks:
//   1000ms - per-core ticks + CPU temp  (always: the chip shows them)
//   2000ms - GPU busy + RAM             (always: the chip shows RAM, GPU when busy)
//   2000ms - clock, watts, VRAM, GTT    (only while `detail` > 0)
// Reads go through FileView.reload(), which re-reads the file IN PROCESS. A
// shelling-out collector costs ~8ms per spawn -- more than the whole rest of
// this. Do not replace these with a Process.
Singleton {
  id: root

  // Popups that want the GPU/memory figures raise this while open and lower it
  // on close. A count, not a bool, so two monitors' popups cannot fight.
  property int detail: 0

  // ----------------------------------------------------------------- state
  property bool   ready: false
  property string gpuDev: ""
  property string amdgpuHm: ""
  property string k10tempHm: ""

  property int    coreCount: 0
  property var    coreLoad: []
  property real   cpuAvg: 0
  property real   cpuPeak: 0
  property int    cpuTemp: 0

  property real   ramUsed: 0
  property real   ramTotal: 0
  property real   vramUsed: 0
  property real   vramTotal: 0
  property real   gttUsed: 0
  property real   gttTotal: 0

  property int    gpuBusy: 0
  property int    gpuClock: 0
  property real   gpuWatts: 0

  // Whether the chip should show the GPU / temp segment. Hysteresis, so a
  // load hovering at the threshold does not make the chip twitch: GPU shows at
  // 25% and hides only after 8s under 10%; CPU temp shows at 70° and hides under 67°.
  property bool   gpuActive: false
  property bool   tempActive: false
  property real   gpuCalmSince: 0
  readonly property real ramFrac: ramTotal > 0 ? ramUsed / ramTotal : 0

  property var    prevTot: []
  property var    prevIdle: []

  // ------------------------------------------------------- path resolution
  // card0/card1 is not stable across boots, and the hwmon index moves with it.
  // Resolve both once at startup rather than hardcoding what is true today.
  Process {
    running: true
    command: ["sh", "-c",
      'd=$(dirname "$(ls /sys/class/drm/card*/device/gpu_busy_percent 2>/dev/null | head -1)"); ' +
      'echo "gpu:$d"; ' +
      'for h in /sys/class/hwmon/hwmon*; do n=$(cat "$h/name" 2>/dev/null); ' +
      'case "$n" in amdgpu) echo "amdgpu:$h" ;; k10temp) echo "k10temp:$h" ;; esac; done']
    stdout: StdioCollector {
      onStreamFinished: {
        const lines = this.text.split("\n")
        for (let i = 0; i < lines.length; i++) {
          const p = lines[i].split(":")
          if (p[0] === "gpu" && p[1]) root.gpuDev = p[1]
          else if (p[0] === "amdgpu" && p[1]) root.amdgpuHm = p[1]
          else if (p[0] === "k10temp" && p[1]) root.k10tempHm = p[1]
        }
        root.ready = true
        root.sampleCpu()
        root.sampleLight()
        if (root.detail > 0) root.sampleDetail()
      }
    }
  }

  FileView { id: fStat; path: "/proc/stat";  blockLoading: true; printErrors: false }
  FileView { id: fTemp; path: root.k10tempHm ? root.k10tempHm + "/temp1_input" : ""; blockLoading: true; printErrors: false }
  FileView { id: fMem;  path: "/proc/meminfo"; blockLoading: true; printErrors: false }
  FileView { id: fBusy; path: root.gpuDev ? root.gpuDev + "/gpu_busy_percent" : ""; blockLoading: true; printErrors: false }
  FileView { id: fSclk; path: root.gpuDev ? root.gpuDev + "/pp_dpm_sclk" : ""; blockLoading: true; printErrors: false }
  FileView { id: fVU;   path: root.gpuDev ? root.gpuDev + "/mem_info_vram_used" : ""; blockLoading: true; printErrors: false }
  FileView { id: fVT;   path: root.gpuDev ? root.gpuDev + "/mem_info_vram_total" : ""; blockLoading: true; printErrors: false }
  FileView { id: fGU;   path: root.gpuDev ? root.gpuDev + "/mem_info_gtt_used" : ""; blockLoading: true; printErrors: false }
  FileView { id: fGT;   path: root.gpuDev ? root.gpuDev + "/mem_info_gtt_total" : ""; blockLoading: true; printErrors: false }
  FileView { id: fPow;  path: root.amdgpuHm ? root.amdgpuHm + "/power1_average" : ""; blockLoading: true; printErrors: false }

  // ------------------------------------------------------------- sampling
  function sampleCpu() {
    fStat.reload(); fTemp.reload()
    // per-core load needs two samples of cumulative ticks, so the previous
    // read is kept and differenced here.
    const out = []
    const nt = [], ni = []
    const lines = fStat.text().split("\n")
    for (let k = 0; k < lines.length; k++) {
      const p = lines[k].split(/\s+/)
      if (!p[0] || p[0].length < 4 || p[0].slice(0, 3) !== "cpu") continue
      const idx = Number(p[0].slice(3))
      if (isNaN(idx)) continue
      let total = 0
      for (let j = 1; j <= 8; j++) total += Number(p[j] || 0)
      const idle = Number(p[4] || 0) + Number(p[5] || 0)
      nt[idx] = total; ni[idx] = idle
      let v = 0
      if (root.prevTot[idx] !== undefined && total > root.prevTot[idx])
        v = (1 - (idle - root.prevIdle[idx]) / (total - root.prevTot[idx])) * 100
      out.push(Math.max(0, Math.min(100, v)))
    }
    root.prevTot = nt
    root.prevIdle = ni
    if (out.length > 0) {
      let sum = 0, peak = 0
      for (let i = 0; i < out.length; i++) { sum += out[i]; peak = Math.max(peak, out[i]) }
      root.coreLoad = out
      root.coreCount = out.length
      root.cpuAvg = sum / out.length
      root.cpuPeak = peak
    }
    root.cpuTemp = Math.round((Number(fTemp.text()) || 0) / 1000)
    if (root.cpuTemp >= 70) root.tempActive = true
    else if (root.cpuTemp < 67) root.tempActive = false
  }

  function sampleLight() {
    fMem.reload(); fBusy.reload()
    const g = ({})
    const ml = fMem.text().split("\n")
    for (let i = 0; i < ml.length; i++) {
      const p = ml[i].split(/\s+/)
      if (p[0] && p[1]) g[p[0].replace(":", "")] = Number(p[1])
    }
    if (g["MemTotal"]) {
      root.ramTotal = g["MemTotal"] / 1048576
      root.ramUsed = (g["MemTotal"] - g["MemAvailable"]) / 1048576
    }
    root.gpuBusy = Number(fBusy.text()) || 0


    const now = Date.now()
    if (root.gpuBusy >= 25) { root.gpuActive = true; root.gpuCalmSince = 0 }
    else if (root.gpuBusy < 10) {
      if (root.gpuCalmSince === 0) root.gpuCalmSince = now
      else if (now - root.gpuCalmSince >= 8000) root.gpuActive = false
    }
  }

  function sampleDetail() {
    fSclk.reload(); fVU.reload(); fVT.reload(); fGU.reload(); fGT.reload(); fPow.reload()
    root.vramUsed = (Number(fVU.text()) || 0) / 1048576
    root.vramTotal = (Number(fVT.text()) || 0) / 1048576
    root.gttUsed = (Number(fGU.text()) || 0) / 1073741824
    root.gttTotal = (Number(fGT.text()) || 0) / 1073741824
    root.gpuWatts = (Number(fPow.text()) || 0) / 1e6
    const cl = fSclk.text().split("\n")
    for (let i = 0; i < cl.length; i++) {
      if (cl[i].indexOf("*") !== -1) {
        const mm = cl[i].match(/(\d+)\s*Mhz/i)
        if (mm) root.gpuClock = Number(mm[1])
      }
    }
  }

  // A popup opening should not show zeros for two seconds.
  onDetailChanged: if (detail > 0 && ready) { sampleLight(); sampleDetail() }

  Timer { interval: 1000; running: root.ready; repeat: true; onTriggered: root.sampleCpu() }
  Timer { interval: 2000; running: root.ready; repeat: true; onTriggered: root.sampleLight() }
  Timer { interval: 2000; running: root.ready && root.detail > 0; repeat: true; onTriggered: root.sampleDetail() }
}
