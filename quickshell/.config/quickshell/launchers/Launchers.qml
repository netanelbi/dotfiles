import Quickshell

// The launcher group: everything that used to be a rofi invocation.
//
// Quickshell only instantiates QML that something references, and singletons
// are lazy, so a launcher that nothing constructs has no IpcHandler and
// therefore no way to be summoned. Hence one aggregate: shell.qml adds two
// lines and all five overlays exist.
//
//     import "launchers"
//     ...
//     Launchers { }
//
// Hyprland binds (hyprland.lua) then become, in place of the rofi commands:
//
//     hl.bind(mainMod .. " + D",      hl.dsp.exec_cmd("qs ipc call apps toggle"))
//     hl.bind(mainMod .. " + V",      hl.dsp.exec_cmd("qs ipc call clipboard toggle"))
//     hl.bind(mainMod .. " + K",      hl.dsp.exec_cmd("qs ipc call calc toggle"))
//     hl.bind("XF86Bluetooth",        hl.dsp.exec_cmd("qs ipc call emoji toggle"))
//     hl.bind(mainMod .. " + Escape", hl.dsp.exec_cmd("qs ipc call power toggle"))
//     hl.bind(mainMod .. " + A",      hl.dsp.exec_cmd("qs ipc call assistant toggle"))
//
// `toggle` reproduces the old `pkill -x rofi || <launcher>` shape: pressing
// the same key again closes the overlay.
Scope {
  id: group

  // Only one launcher may hold the exclusive keyboard focus at a time, so
  // opening one closes whichever was up. rofi got this for free by being a
  // single process.
  property var openPanel: null

  function claim(panel) {
    if (openPanel && openPanel !== panel) openPanel.dismiss()
    openPanel = panel
  }

  function release(panel) {
    if (openPanel === panel) openPanel = null
  }

  AppLauncher { group: group }
  Clipboard   { group: group }
  Calc        { group: group }
  Emoji       { group: group }
  PowerMenu   { group: group }
  // Not a rofi replacement -- rofi never did this. Same chrome and same group,
  // so it inherits the one-overlay-at-a-time rule for free.
  Assistant   { group: group }
}
