import QtQuick
import Quickshell.Io
import Quickshell.Hyprland
import "root:/"

// #language -- waybar's built-in `hyprland/language`. No watcher script exists
// for this one, so it is rebuilt on Quickshell's own Hyprland IPC rather than
// on a subprocess: `activelayout` events, zero polling.
//
// config.jsonc  "hyprland/language": { format "{short}" }
// style.css     #tray,#language,... { color: @text; padding: 0 10px }
//               #language           { color: @peach; font-weight: bold }
// input.lua     kb_layout = "us,il", grp:alt_shift_toggle
//
// {short} IS THE LAYOUT CODE ("us" / "il"), not the description. waybar gets it
// by looking the keymap's description up in the same xkb rules file this widget
// reads -- /usr/share/X11/xkb/rules/evdev.xml maps
// <layout><configItem><name>us</name>...<description>English (US)</description>,
// and Hyprland only ever reports the description. Hardcoding "English (US)" ->
// "us" would silently rot the day a layout is added to input.lua, so the real
// table is parsed once at startup (99 entries) and never touched again.
BarWidget {
  id: root

  // padding: 0 10px, from the shared right-modules rule.
  horizontalPadding: Style.module.paddingH
  // waybar defines no :hover here and the module has no click action;
  // `interactive` stays true purely so the tooltip can be raised.
  hoverHighlight: false

  // The keymap description Hyprland reports, e.g. "English (US)".
  property string description: ""
  // description -> layout code, built from evdev.xml.
  property var layoutCodes: ({})
  // waybar's {short}.
  readonly property string code: {
    if (description === "")
      return "";
    var c = layoutCodes[description];
    // Before evdev.xml has loaded (or for a layout it does not list) fall back
    // to the description's first two letters -- wrong-ish, but never blank.
    return c !== undefined ? c : description.substring(0, 2).toLowerCase();
  }

  // waybar shows the full keymap name on hover.
  tooltip: description

  // ------------------------------------------------------------ xkb table
  FileView {
    path: "/usr/share/X11/xkb/rules/evdev.xml"
    printErrors: false
    onLoaded: {
      var out = {};
      // Top-level <layout> entries only: a <variant>'s configItem has the same
      // shape, but its <name> is the variant code, not the layout code.
      var re = /<layout>\s*<configItem>[\s\S]*?<name>([^<]+)<\/name>[\s\S]*?<description>([^<]+)<\/description>/g;
      var s = text();
      var m;
      while ((m = re.exec(s)) !== null)
        if (out[m[2]] === undefined)
          out[m[2]] = m[1];
      root.layoutCodes = out;
    }
  }

  // ------------------------------------------------------- initial state
  // One shot at startup. Every later change arrives as an event, so this never
  // runs again -- `hyprctl devices` is a query, not a dispatch, so the Lua
  // argument parsing of Hyprland 0.56+ does not apply.
  Process {
    running: true
    command: ["hyprctl", "-j", "devices"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var kbs = JSON.parse(text).keyboards || [];
          var pick = null;
          for (var i = 0; i < kbs.length; i++)
            if (kbs[i].main)
              pick = kbs[i];
          if (pick === null && kbs.length > 0)
            pick = kbs[kbs.length - 1];
          // Do not clobber an activelayout event that beat us to it.
          if (pick !== null && root.description === "")
            root.description = String(pick.active_keymap || "");
        } catch (e) {
          // Malformed output means we simply keep waiting for an event.
        }
      }
    }
  }

  // ------------------------------------------------------------- events
  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (event.name !== "activelayout")
        return;
      // data is `<keyboard name>,<layout description>`, and the description may
      // itself contain commas ("English (US, intl.)"), so split on the FIRST one.
      var i = event.data.indexOf(",");
      if (i >= 0)
        root.description = event.data.substring(i + 1);
    }
  }

  // ------------------------------------------------------------- display
  // `label.text` is not bound to `code` -- the swap animation owns it, so that
  // the old code is carried out before the new one is carried in.
  property string shown_: ""

  Text {
    id: label
    text: root.shown_
    // #language { color: @peach; font-weight: bold }
    color: Theme.peach
    font.family: Style.font.family
    font.pixelSize: Style.font.size
    font.weight: Style.font.boldWeight
    renderType: Text.NativeRendering
  }

  // MOTION. waybar replaces "us" with "il" between two frames and that is the
  // whole event; with alt+shift under your thumb you cannot tell a switch from
  // a mistype. Here the outgoing code shrinks and fades out, the incoming one
  // drops into the slot and settles -- one unmistakable beat, ~300ms end to
  // end, and BarWidget's width Behavior absorbs any change in code width so the
  // rest of the island slides rather than jumps.
  //
  // The vertical travel is kept to 3px on purpose: BarWidget clips to the
  // 18px slot, and anything taller would be sheared off mid-flight.
  SequentialAnimation {
    id: swap

    ParallelAnimation {
      NumberAnimation {
        target: label; property: "opacity"; to: 0
        duration: Style.anim.quick; easing.type: Style.anim.easingSmooth
      }
      NumberAnimation {
        target: label; property: "scale"; to: 0.7
        duration: Style.anim.quick; easing.type: Style.anim.easing
      }
    }
    ScriptAction { script: root.shown_ = root.code }
    PropertyAction { target: label; property: "y"; value: -3 }
    ParallelAnimation {
      NumberAnimation {
        target: label; property: "opacity"; to: 1
        duration: Style.anim.normal; easing.type: Style.anim.easingSmooth
      }
      NumberAnimation {
        target: label; property: "scale"; to: 1
        duration: Style.anim.normal; easing.type: Style.anim.easing
      }
      NumberAnimation {
        target: label; property: "y"; to: 0
        duration: Style.anim.normal; easing.type: Style.anim.easing
      }
    }
  }

  onCodeChanged: {
    if (code === "")
      return;
    // First value of the session: no outgoing code to animate away.
    if (shown_ === "")
      shown_ = code;
    else if (shown_ !== code)
      swap.restart();
  }
}
