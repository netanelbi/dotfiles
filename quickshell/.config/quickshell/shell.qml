//@ pragma UseQApplication
// Required for system tray context menus. Quickshell renders a tray item's
// DBusMenu through the Qt platform menu layer, which only exists in
// QApplication mode; without this pragma QsMenuAnchor.open() refuses with
// "quickshell was not started in QApplication mode" and right-click on a
// tray icon silently does nothing.
import Quickshell

import "launchers"

// Entry point. One bar per connected monitor; Variants keeps that in sync as
// monitors come and go (docking, sunshine-prep's mode switch, lid close).
ShellRoot {
  Variants {
    model: Quickshell.screens

    delegate: Bar { }
  }

  // The rofi replacements. Quickshell only instantiates referenced QML, so
  // this line is what constructs the five IpcHandlers (apps/clipboard/calc/
  // emoji/power) that `qs ipc call <target> toggle` talks to.
  Launchers { }
}
