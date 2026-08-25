//@ pragma UseQApplication
// Required for system tray context menus. Quickshell renders a tray item's
// DBusMenu through the Qt platform menu layer, which only exists in
// QApplication mode; without this pragma QsMenuAnchor.open() refuses with
// "quickshell was not started in QApplication mode" and right-click on a
// tray icon silently does nothing.
import Quickshell

import "launchers"
import "screensaver"
import "services"
import "sharepicker"
import "wallpaper"

// Entry point. One bar per connected monitor; Variants keeps that in sync as
// monitors come and go (docking, sunshine-prep's mode switch, lid close).
ShellRoot {
  // Background layer, one per monitor. Live weather with rain/snow/fog/storm
  // states -- and 0% CPU when the weather is calm, because every animation
  // gates on `running:` rather than relying on `visible: false` (which stops
  // painting, not animating).
  Wallpaper { }

  Variants {
    model: Quickshell.screens

    delegate: Bar { }
  }

  // The rofi replacements. Quickshell only instantiates referenced QML, so
  // this line is what constructs the five IpcHandlers (apps/clipboard/calc/
  // emoji/power) that `qs ipc call <target> toggle` talks to.
  Launchers { }

  // Volume / brightness / mute OSD, replacing swayosd-server.
  Osd { }

  // org.freedesktop.Notifications: popups + control center, replacing swaync.
  Notifications { }

  // org.freedesktop.PolicyKit1.AuthenticationAgent. This machine had NO agent
  // at all -- polkitd alone -- so anything asking for root failed silently.
  Polkit { }

  // Fullscreen GPU screensaver on idle, replacing the kitty + tte pair.
  // Built only once hypridle calls `ipc call screensaver start`.
  Screensaver { }

  // The xdg-desktop-portal-hyprland screen-share picker, replacing
  // /usr/bin/hyprland-share-picker's three tabs of text with live thumbnails.
  // Built only when ~/.local/bin/hypr-share-picker asks it to open.
  SharePicker { }
}
