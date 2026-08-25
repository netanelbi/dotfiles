import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// The screen-share picker, replacing /usr/bin/hyprland-share-picker.
//
// The stock picker is three tabs of text: "Screen 0 at 1920, 0 (1280x800)
// (eDP-1)". You pick a string and hope. This one draws a LIVE thumbnail of
// every screen and every shareable window, which is the entire reason it
// exists -- ScreencopyView makes the option show you what it is.
//
// ------------------------------------------------------------------- wiring
//   ~/.config/hypr/xdph.conf
//       screencopy { custom_picker_binary = ~/.local/bin/hypr-share-picker }
//   hypr-share-picker (bash)
//       qs ipc call sharepicker open <fifo> "$XDPH_WINDOW_SHARING_LIST" <0|1>
//       ... then blocks reading <fifo> until this file writes one line.
//
// The script owns the blocking half because an IpcHandler function returns
// immediately -- it cannot wait for a human. The full protocol, including the
// two stdout rules that silently corrupt a selection, is documented in the
// script; this file only produces the body of the line.
//
// ----------------------------------------------------------- window handles
// A window is named back to xdph by `window:<handle>`, where <handle> is the
// low 32 bits of xdph's own wl_proxy pointer for that window's
// wlr-foreign-toplevel handle. That is a pointer inside another process, so
// nothing here can compute it; xdph hands the whole list over in
// XDPH_WINDOW_SHARING_LIST and the script forwards it verbatim. Each record
// also carries the Hyprland window address, which is what lets an opaque
// handle be joined to a Quickshell toplevel we can actually capture.
Scope {
  id: root

  property bool opened: false
  // Where the waiting script is reading. Empty when no request is in flight.
  property string fifoPath: ""
  // xdph passes --allow-token when `allow_token_by_default` is set, which only
  // preselects the checkbox -- the user still decides.
  property bool allowToken: true

  // The list exactly as xdph handed it over, kept raw so the join below can be
  // redone whenever Hyprland's toplevel model changes.
  property string rawWindowList: ""

  // [{ handle: "195620288", cls: "slack", title: "...", toplevel: <Toplevel> }]
  // `toplevel` is the Quickshell.Wayland Toplevel to hand ScreencopyView, or
  // null when the join failed -- the tile then shows a placeholder rather than
  // vanishing, because the handle is still perfectly shareable either way.
  //
  // A binding, not a one-shot parse, because refreshToplevels() is a round trip
  // to Hyprland: reading the model straight after asking for a refresh returns
  // the OLD model. Naming `Hyprland.toplevels.values` here makes the join redo
  // itself when the answer lands -- and again if a window closes while the
  // picker is open.
  readonly property var windowEntries:
    parseWindowList(root.rawWindowList, Hyprland.toplevels.values)

  // ------------------------------------------------------- the window list
  // One record per window, no separator between records:
  //   <handle>[HC>]<class>[HT>]<title>[HE>]<hyprland address>[HA>]
  // Field order and markers are xdph's buildWindowList(); the address is
  // decimal, while Hyprland's IPC reports it as hex.
  // `toplevels` is passed in rather than read from Hyprland directly so that
  // the property binding above has something to depend on.
  function parseWindowList(raw, toplevels) {
    var out = []
    if (!raw) return out

    var records = String(raw).split("[HA>]")
    for (var i = 0; i < records.length; i++) {
      var rec = records[i]
      if (!rec) continue

      var a = rec.indexOf("[HC>]")
      var b = rec.indexOf("[HT>]")
      var c = rec.indexOf("[HE>]")
      if (a < 0 || b < a || c < b) continue

      var handle = rec.substring(0, a)
      // xdph itself skips records whose handle will not parse as a number
      // (std::stoull throws), so a malformed one is dropped rather than
      // offered as a choice that cannot be honoured.
      if (!/^[0-9]+$/.test(handle)) continue

      var address = rec.substring(c + 5)
      out.push({
        handle: handle,
        cls: rec.substring(a + 5, b),
        title: rec.substring(b + 5, c),
        toplevel: toplevelForAddress(address, toplevels)
      })
    }
    return out
  }

  // The join: decimal address from xdph -> hex -> Hyprland toplevel -> its
  // Wayland toplevel, which is what ScreencopyView captures. Hyprland's
  // toplevel-export protocol grabs the window's own buffer, so a window
  // thumbnail shows the window and not whatever is stacked on top of it.
  function toplevelForAddress(decimal, toplevels) {
    if (!/^[0-9]+$/.test(decimal) || !toplevels) return null
    var hex = decimalToHex(decimal)

    for (var i = 0; i < toplevels.length; i++) {
      var addr = String(toplevels[i].address).toLowerCase().replace(/^0x/, "")
      if (addr.replace(/^0+/, "") === hex) return toplevels[i].wayland
    }
    return null
  }

  // Long division on the digit string, because Quickshell's QML engine has no
  // BigInt (it throws ReferenceError, and an IpcHandler function that throws
  // answers the caller with an empty string) and Number is only exact to 2^53.
  // Userspace pointers fit in 53 bits today, so parseInt would work -- until
  // one day it silently would not, and the symptom would be a window whose
  // thumbnail never appears.
  function decimalToHex(decimal) {
    var digits = String(decimal).split("").map(Number)
    var out = ""

    while (digits.length > 0) {
      var next = []
      var carry = 0
      for (var i = 0; i < digits.length; i++) {
        var cur = carry * 10 + digits[i]
        var q = Math.floor(cur / 16)
        carry = cur % 16
        // Suppress leading zeros in the quotient, or the loop never ends.
        if (next.length > 0 || q > 0) next.push(q)
      }
      out = carry.toString(16) + out
      digits = next
    }

    return out === "" ? "0" : out
  }

  // --------------------------------------------------------------- lifetime
  function present(fifo, list, allowTokenDefault) {
    root.fifoPath = fifo
    root.allowToken = allowTokenDefault
    root.rawWindowList = list
    // Hyprland's toplevel model can be a beat behind a window that just
    // mapped. The answer arrives asynchronously; windowEntries re-joins itself
    // when it does.
    Hyprland.refreshToplevels()
    root.opened = true
  }

  // `body` is what goes after the flags separator: screen:<name>,
  // window:<handle>, region (the script runs slurp once we are out of the
  // way), or cancel.
  function finish(body) {
    if (!root.opened) return
    var fifo = root.fifoPath

    root.opened = false
    root.fifoPath = ""
    root.rawWindowList = ""

    if (fifo) reply(fifo, (root.allowToken ? "r" : "") + "/" + body)
  }

  // Detached rather than a Process, because this also has to work from
  // onDestruction, when the object tree holding a Process is being torn down.
  // `timeout` because opening a FIFO for writing blocks until a reader is
  // there: normally the script already is, but if it gave up and left, this
  // would otherwise wait forever.
  function reply(fifo, line) {
    Quickshell.execDetached(["timeout", "5", "sh", "-c",
                             'printf "%s\\n" "$1" > "$2"', "sh", line, fifo])
  }

  // A config reload rebuilds this whole tree, which would strand the script
  // waiting on a FIFO nobody will ever write -- a two-minute stall before its
  // timeout, with no picker on screen to explain it. Hand the request back
  // instead and let it open the stock picker, which is exactly what "the
  // Quickshell picker cannot answer" should mean.
  Component.onDestruction: {
    if (root.fifoPath) reply(root.fifoPath, "/fallback")
  }

  // Nothing exists until a request arrives: no window, and above all no
  // ScreencopyView. A live capture is real GPU work per output per frame, so
  // the closed state has to cost exactly zero rather than merely be invisible.
  LazyLoader {
    active: root.opened

    component: SharePickerWindow { controller: root }
  }

  IpcHandler {
    target: "sharepicker"

    // Answers "ok" or a reason. The script treats anything but "ok" as a
    // fallback to the stock picker, so this is also the cheap up-front check
    // that keeps it from waiting out the full timeout for nothing.
    function open(fifo: string, windowList: string, allowToken: string): string {
      if (root.opened) return "busy"
      if (!fifo) return "no fifo path"
      root.present(fifo, windowList, allowToken !== "0")
      return "ok"
    }

    // Used by the script on its way to the stock picker, so the user is not
    // left looking at two pickers at once.
    function cancel(): string {
      root.finish("cancel")
      return "ok"
    }

    function status(): string {
      return root.opened ? "open" : "closed"
    }
  }
}
