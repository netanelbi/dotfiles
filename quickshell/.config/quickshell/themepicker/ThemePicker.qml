import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
// Theme/Style are singletons in the config root; a subdirectory does not get
// the root's implicit import, so pull it in explicitly.
import ".."

// SUPER + T: pick the desktop theme.
//
// Lists Theme.available (refreshed on every open), each row with a preview tile
// drawn in THAT theme's style; the popup itself wears the ACTIVE theme. Apply
// runs `theme-switch <name>`, which re-themes kitty/GTK/Hyprland and writes
// ~/.local/state/theme/current -- Theme watches that file, so the shell follows.
// If theme-switch is missing, the state file is written here instead so at
// least the shell re-themes.
//
// Keys: Up/Down or j/k (and Tab/Shift+Tab), Home/End, Enter applies, Esc closes.
// Mouse: hover selects (after deliberate travel, as in the launchers), click applies.
//
// IPC:  qs ipc call theme toggle | open | close | reload | current | list
Scope {
  id: root

  property bool opened: false
  property int currentIndex: 0
  // name -> parsed theme.json, for the preview tiles only.
  property var details: ({})

  // Hover arming, same rule as LauncherPanel: the card is screen-centred, so
  // the pointer often opens sitting on a row -- hover counts only after 16px
  // of accumulated travel.
  property bool hoverArmed: false
  property point hoverLast
  property bool hoverLastValid: false
  property real hoverTravel: 0

  function hoverMoved(g) {
    if (hoverArmed) return
    if (hoverLastValid) {
      hoverTravel += Math.abs(g.x - hoverLast.x) + Math.abs(g.y - hoverLast.y)
      if (hoverTravel >= 16) hoverArmed = true
    }
    hoverLast = g
    hoverLastValid = true
  }

  function indexOfCurrent() {
    var a = Theme.available
    for (var i = 0; i < a.length; i++) if (a[i].name === Theme.name) return i
    return 0
  }

  function present() {
    if (opened) return
    Theme.refreshAvailable()
    detailProc.running = true
    currentIndex = indexOfCurrent()
    hoverArmed = false
    hoverLastValid = false
    hoverTravel = 0
    win.screen = focusedScreen()
    opened = true
    Qt.callLater(function () { keyScope.forceActiveFocus() })
  }

  function dismiss() {
    opened = false
  }

  function toggle() {
    if (opened) dismiss()
    else present()
  }

  function move(delta) {
    var n = Theme.available.length
    if (n === 0) return
    currentIndex = Math.max(0, Math.min(currentIndex + delta, n - 1))
  }

  // Same monitor lookup as LauncherPanel.focusedScreen.
  function focusedScreen() {
    var focused = Hyprland.focusedMonitor
    if (!focused) return win.screen
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (Hyprland.monitorFor(screens[i]) === focused) return screens[i]
    }
    return win.screen
  }

  // Detached, so a Quickshell hot reload mid-switch cannot kill theme-switch
  // half-applied, and a second apply is never dropped. theme-switch pokes
  // `ipc call theme reload` itself. Without it, the fallback writes the state
  // file and calls back `fallbackApplied`, which logs the warning and reloads.
  // theme-switch validates a theme (Kvantum/qt6ct/KDE scheme present) before it
  // touches anything and refuses on stderr; the picker is already gone by then,
  // so a refusal is raised as a notification instead of vanishing.
  function apply(name) {
    if (!/^[a-z0-9-]+$/.test(name)) return false
    Quickshell.execDetached(["sh", "-c",
      "ts=$(command -v theme-switch || echo \"$HOME/.local/bin/theme-switch\"); " +
      "if [ -x \"$ts\" ]; then " +
      "err=$(\"$ts\" \"$1\" 2>&1 >/dev/null) || " +
      "notify-send -a Theme -i preferences-desktop-theme \"Theme not applied: $1\" \"$err\"; exit; fi; " +
      "mkdir -p \"$HOME/.local/state/theme\" && printf '%s\\n' \"$1\" > \"$HOME/.local/state/theme/current\" && " +
      "exec qs -p \"$HOME/.config/quickshell\" ipc call theme fallbackApplied \"$1\"", "sh", name])
    dismiss()
    return true
  }

  function applyIndex(i) {
    var a = Theme.available
    if (i >= 0 && i < a.length) apply(a[i].name)
  }

  // Every theme.json, parsed, so the preview tiles can use each theme's real
  // desk / base / ink / border instead of guessing from the swatch.
  Process {
    id: detailProc
    command: ["sh", "-c", "for f in \"$1\"/*/theme.json; do cat \"$f\"; printf '\\n@@THEME@@\\n'; done", "sh", Theme.themesDir]
    stdout: StdioCollector {
      onStreamFinished: {
        var out = {}
        text.split("@@THEME@@").forEach(function (chunk) {
          chunk = chunk.trim()
          if (!chunk) return
          try {
            var d = JSON.parse(chunk)
            if (d && d.name) out[d.name] = d
          } catch (e) { }
        })
        root.details = out
      }
    }
  }

  // Theme.available arrives asynchronously after refreshAvailable(); put the
  // selection on the active theme once it lands.
  Connections {
    target: Theme
    function onAvailableChanged() { if (root.opened && !root.hoverArmed) root.currentIndex = root.indexOfCurrent() }
  }

  // --------------------------------------------------------------- window
  PanelWindow {
    id: win

    WlrLayershell.namespace: "quickshell-themepicker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // Full-screen and fixed: the card animates inside the surface, the
    // surface never resizes (CLAUDE.md, "Layer-shell windows must not resize").
    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }

    color: "transparent"

    property real revealed: 0
    visible: root.opened || revealed > 0.001
    Connections {
      target: root
      function onOpenedChanged() { win.revealed = root.opened ? 1 : 0 }
    }

    Behavior on revealed {
      NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
    }

    Rectangle {
      anchors.fill: parent
      color: Theme.scrim
      opacity: win.revealed

      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    FocusScope {
      id: keyScope
      anchors.fill: parent
      focus: true

      Keys.onPressed: function (event) {
        switch (event.key) {
        case Qt.Key_Escape:
          root.dismiss(); break
        case Qt.Key_Return:
        case Qt.Key_Enter:
          root.applyIndex(root.currentIndex); break
        case Qt.Key_Up:
        case Qt.Key_K:
        case Qt.Key_Backtab:
          root.move(-1); break
        case Qt.Key_Down:
        case Qt.Key_J:
        case Qt.Key_Tab:
          root.move(1); break
        case Qt.Key_Home:
          root.currentIndex = 0; break
        case Qt.Key_End:
          root.move(1000); break
        default:
          return
        }
        event.accepted = true
      }

      ThemePickerCard {
        id: card
        anchors.horizontalCenter: parent.horizontalCenter
        y: (parent.height - height) / 2 + 12 * (1 - win.revealed)
        opacity: win.revealed
        scale: 0.96 + 0.04 * win.revealed

        model: Theme.available
        details: root.details
        currentName: Theme.name
        currentIndex: root.currentIndex

        onPointerMoved: function (p) { root.hoverMoved(p) }
        onHovered: function (i) { if (root.hoverArmed) root.currentIndex = i }
        onActivated: function (i) { root.applyIndex(i) }
      }
    }
  }

  // ------------------------------------------------------------------ ipc
  IpcHandler {
    target: "theme"

    function toggle(): string {
      root.toggle()
      return root.opened ? "opened" : "closed"
    }

    function open(): string {
      root.present()
      return "opened"
    }

    function close(): string {
      root.dismiss()
      return "closed"
    }

    // theme-switch pokes this after writing the state file.
    function reload(): string {
      Theme.reload()
      Theme.refreshAvailable()
      return "reloaded"
    }

    function current(): string {
      return Theme.name
    }

    // One line per theme: name, label, dark|light, and `*` on the active one.
    // Answers from the cached list; the refresh it kicks off is async, so a
    // theme added a moment ago shows up on the NEXT call.
    function list(): string {
      Theme.refreshAvailable()
      return Theme.available.map(function (t) {
        return (t.name === Theme.name ? "* " : "  ") + t.name + "\t" + t.label + "\t" + (t.dark ? "dark" : "light")
      }).join("\n")
    }

    // Apply by name, same path as Enter in the popup. Only the name's shape is
    // checked here (the cached list may be stale); theme-switch rejects
    // unknown themes itself.
    function apply(name: string): string {
      if (!/^[a-z0-9-]+$/.test(name)) return "bad theme name: " + name
      root.apply(name)
      return "applying " + name
    }

    // Called by apply()'s fallback when theme-switch is not installed.
    function fallbackApplied(name: string): string {
      console.warn("ThemePicker: theme-switch not found; wrote ~/.local/state/theme/current = " + name + " (shell only)")
      Theme.reload()
      return "reloaded"
    }
  }
}
