import QtQuick
import Quickshell
import Quickshell.Io
// Theme/Style are singletons in the config root; a subdirectory does not get
// the root's implicit import, so pull it in explicitly.
import ".."

// Replaces the SUPER + K calculator:
//
//   rofi -show calc -modi calc -plugin-path /usr/lib/rofi \
//        -no-show-match -no-sort -no-history \
//        -calc-command "echo -n '{result}' | wl-copy" \
//        -theme ~/.config/rofi/calc.rasi
//
// rofi-calc is a libqalculate front end, so this shells out to the same
// engine (`qalc -t`) and keeps the same contract: the result updates live as
// you type, and Enter puts it on the clipboard with wl-copy.
//
//   calc.rasi   window 550px, 2px @green border, radius 16
//               prompt  @green pill on @base text
//               entry   placeholder "Type expression..."
//               message @base, 20px padding; textbox @mauve bold, centred
//               listview disabled
//
// IPC:  qs ipc call calc toggle | open | close
Scope {
  id: root

  property var group: null

  property string result: ""
  property bool computing: false

  function evaluate() {
    var expr = panel.query.trim()
    if (expr === "") {
      root.result = ""
      root.computing = false
      qalc.running = false
      return
    }
    root.computing = true
    debounce.restart()
  }

  function copyResult() {
    if (root.result === "") return
    var value = root.result
    panel.dismiss()
    // `echo -n '{result}' | wl-copy`, without letting the value reach the
    // shell's word splitting or option parsing.
    Quickshell.execDetached(["sh", "-c", "printf %s \"$1\" | wl-copy", "sh", value])
  }

  // rofi-calc recomputes on every keystroke; qalc is fast but not free, so
  // coalesce bursts of typing into one run.
  Timer {
    id: debounce
    interval: 90
    onTriggered: {
      qalc.running = false
      // Set imperatively: a binding would rewrite the command mid-run on the
      // next keystroke.
      qalc.command = ["qalc", "-t", "--", panel.query.trim()]
      qalc.running = true
    }
  }

  Process {
    id: qalc
    stdout: StdioCollector {
      onStreamFinished: {
        // qalc folds long results onto several lines; the clipboard wants one.
        var out = String(text).trim().split("\n").join(" ").trim()
        root.result = out
        root.computing = false
      }
    }
  }

  // ---------------------------------------------------------------- panel
  LauncherPanel {
    id: panel

    prompt: "Calc"
    accent: Theme.green            // calc.rasi: border-color @green
    panelWidth: 550
    cornerRadius: 16
    placeholder: "Type expression..."
    // calc.rasi: `listview { enabled: false }` -- nothing to navigate.
    list: null

    onPresented: {
      root.result = ""
      root.computing = false
      if (root.group) root.group.claim(panel)
      // Lazy exchange-rate refresh: fire-and-forget; the script exits
      // immediately unless the cached rates are 24h+ old, so this is at
      // most one fetch per day and nothing at all on days the calculator
      // stays closed. No timer/daemon needed.
      Quickshell.execDetached(["/home/netanel/.local/bin/update-qalculate-rates"])
    }
    onDismissed: {
      if (root.group) root.group.release(panel)
      qalc.running = false
      debounce.stop()
    }
    onAccepted: root.copyResult()
    onQueryChanged: root.evaluate()

    // message { background: @base; padding: 20px }
    Item {
      width: parent.width
      // The box collapses to nothing until there is something to show, so an
      // empty prompt is just the input bar -- then it opens as the result
      // arrives. rofi's box is always the same height.
      height: resultLabel.implicitHeight + 40
      clip: true

      Behavior on height {
        NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
      }

      // textbox { text-color: @mauve; font bold 14; horizontal-align: 0.5 }
      Text {
        id: resultLabel
        anchors.centerIn: parent
        width: parent.width - 40
        text: root.result !== "" ? root.result
          : panel.query.trim() === "" ? "="
          : root.computing ? "…" : "="
        color: root.result !== "" ? Theme.accent : Theme.overlay0
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        font.family: Style.font.family
        font.pixelSize: Style.font.size + 4
        font.weight: Style.font.boldWeight
        renderType: Text.NativeRendering

        Behavior on color {
          ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
        }

        // Each new result lifts into place instead of blinking over the old
        // one -- the difference is very visible while typing a long sum.
        // The offset is animated rather than `y`, which anchors.centerIn owns.
        onTextChanged: settle.restart()
        NumberAnimation {
          id: settle
          target: resultLabel
          property: "anchors.verticalCenterOffset"
          from: 5
          to: 0
          duration: Style.anim.normal
          easing.type: Style.anim.easing
        }
      }
    }

    // A quiet hint, in place of rofi's silent Enter.
    Item {
      width: parent.width
      height: 30

      Text {
        anchors.centerIn: parent
        text: "Enter copies the result"
        color: Theme.overlay0
        opacity: root.result !== "" ? 1 : 0
        font.family: Style.font.family
        font.pixelSize: Style.font.small
        renderType: Text.NativeRendering

        Behavior on opacity {
          NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
        }
      }
    }
  }

  // ------------------------------------------------------------------ ipc
  IpcHandler {
    target: "calc"

    function toggle(): string {
      panel.toggle()
      return panel.opened ? "opened" : "closed"
    }

    function open(): string {
      panel.present()
      return "opened"
    }

    function close(): string {
      panel.dismiss()
      return "closed"
    }
  }
}
