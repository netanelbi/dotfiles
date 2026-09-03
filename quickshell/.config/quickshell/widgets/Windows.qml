import QtQuick
import Quickshell
import Quickshell.Hyprland
import "root:/"

// Replaces waybar's `custom/windows`.
//
// config.jsonc:
//   { "exec": "~/.local/bin/hypr-windows-watch", "return-type": "json",
//     "format": "{}", "escape": false }   -- no click handlers at all.
//
// hypr-windows-watch stays the source of truth and is NOT reimplemented: it
// already decides whether the list is the visible scratchpad or the active
// workspace, sorts by PID, truncates titles at 25 chars (to 22 + "..."), and
// escapes them. It emits one line of Pango:
//
//   text:    <span foreground='#cba6f7' weight='bold'>Title</span>  │  <span foreground='#6c7086'>Other</span>
//   tooltip: <span foreground='#cba6f7' weight='bold'>▶ Full Title</span>\n<span foreground='#6c7086'>  Other Full Title</span>
//   class:   "workspace" | "scratchpad"
//
// waybar can only paint that markup as one flat label. We have a scene graph,
// so the markup is parsed back into one real item per window -- the two span
// lists are emitted in the same order, so zipping them recovers
// {truncated title, full title, focused} exactly as the script computed it.
// Colours then come from Theme rather than the hexes the script bakes in;
// they resolve to the same Mocha values (#cba6f7 mauve, #f9e2af yellow,
// #6c7086 overlay0), but re-theming style.css re-themes this too.
//
// style.css:
//   #custom-windows            { padding: 0 10px; font-size: 12px }
//   #custom-windows.workspace  { text-shadow: 0 0 8px alpha(@mauve, 0.3) }
//   #custom-windows.scratchpad { text-shadow: 0 0 8px alpha(@yellow, 0.4) }
//
// MOTION + the one thing real items buy that markup cannot: the focus halo is
// a single rounded glow that SLIDES from the old window to the new one and
// resizes to it, the list reflows instead of re-laying out in a single frame,
// a new window scales in, and each title is independently hoverable (its own
// full-title tooltip) and clickable (focus that window). waybar's whole label
// is one inert blob.
//
// OVERFLOW: the left island may not run under the clock. Bar.qml hands this
// widget a `maxListWidth` -- everything up to the centre island minus the two
// pills beside it. When the whole list does not fit, it collapses to ONE
// thing: the focused window's title, named and highlighted, and a "+N" chip
// standing in for the rest. The chip lists every window in a popup -- full
// titles, the focused one marked, click to focus -- and carries the focus
// halo when the focused window is somehow among the hidden ones.
ScriptWidget {
  id: root

  script: "~/.local/bin/hypr-windows-watch"

  // ScriptWidget defaults to `shown: text !== ""`, and BarWidget implements
  // !shown as BOTH `implicitWidth: 0` and `opacity: 0`. That opacity step is
  // the blink: the watcher emits "" for a frame mid-switch, and the widget
  // flashed out and back rather than resizing.
  //
  // A grace timer was the wrong fix -- it just delayed the collapse, so
  // arriving on an empty workspace held a blank box for 250ms and then
  // vanished, which is a worse blink.
  //
  // This widget never collapses. It stays at opacity 1 and lets its WIDTH
  // follow its content: an empty list leaves only horizontal padding, so it
  // takes no visible space anyway, and BarWidget's width Behavior turns every
  // transition -- empty or not -- into one smooth resize with nothing fading.
  shown: true

  // Every title owns its own MouseArea, so the base widget's full-cover
  // MouseArea must stand down. The per-window tooltips replace the single
  // whole-widget one, so BarWidget's tooltip is cleared as well.
  interactive: false
  tooltip: ""

  // `padding: 0 10px`
  horizontalPadding: Style.module.paddingH

  // `.scratchpad` -> yellow, `.workspace` -> mauve; the script picks the class,
  // we pick the token.
  // Which monitor this bar sits on. The watcher (hypr-windows-watch) emits a
  // section PER MONITOR, and each bar reads its own -- with two monitors the
  // globally focused workspace lives on only one of them, and the other bar
  // must not show its titles.
  property var barScreen: null
  readonly property var barMonitor: root.barScreen ? Hyprland.monitorFor(root.barScreen) : null
  readonly property string monitorName: root.barMonitor !== null ? root.barMonitor.name : ""

  // This bar's section of the watcher's payload. Falls back to the top-level
  // fields (which mirror the focused monitor) while the section is missing --
  // an older script, or a monitor name that has not propagated yet.
  readonly property var section: {
    var mons = root.payload !== null ? root.payload.monitors : null
    if (mons && root.monitorName !== "" && mons[root.monitorName] !== undefined
        && mons[root.monitorName] !== null) {
      var s = mons[root.monitorName]
      return { text: s.text || "", tooltip: s.tooltip || "", class: s.class || "" }
    }
    return { text: root.text, tooltip: root.scriptTooltip, class: root.classes.join(",") }
  }

  readonly property bool scratchListed: String(section.class) === "scratchpad"
  readonly property color focusColor: root.scratchListed ? Theme.attention : Theme.accent

  // ------------------------------------------------------------ overflow cap
  // Widest this widget may paint, in fullWidth terms (content + padding).
  // 0 -- the default -- means uncapped; Bar.qml always binds it.
  property real maxListWidth: 0
  // Per-entry visibility, recomputed by computeTrim(). The array is
  // reassigned wholesale so every delegate binding re-evaluates off one
  // change; entries beyond its length are shown (the pre-trim default).
  property var visibleFlags: []
  property int overflowCount: 0

  function isShown(i) {
    return i < visibleFlags.length ? visibleFlags[i] : true
  }
  // The separator owned by entry i: drawn iff some earlier entry survives.
  // Trimmed entries leave holes; the separator must skip over them.
  function shownBefore(i) {
    for (var j = i - 1; j >= 0; j--) if (isShown(j)) return true
    return false
  }

  // ------------------------------------------------------------- parsing
  function unescapePango(s) {
    return String(s)
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, "\"")
      .replace(/&apos;/g, "'")
      .replace(/&amp;/g, "&")   // last, so "&amp;lt;" survives as "&lt;"
  }

  function parseSpans(markup) {
    var out = []
    if (!markup) return out
    var re = /<span([^>]*)>([\s\S]*?)<\/span>/g
    var m
    while ((m = re.exec(markup)) !== null) {
      out.push({ bold: /weight\s*=\s*['"]bold['"]/.test(m[1]), body: m[2] })
    }
    return out
  }

  // Tooltip lines are prefixed "▶ " (focused) or two spaces (not).
  function stripMarker(s) {
    var t = s.charAt(0) === "▶" ? s.substring(1) : s
    return t.replace(/^\s+/, "")
  }

  // In-place sync rather than resetting the model: keeping the delegates alive
  // is what lets colours cross-fade and the halo slide instead of every window
  // being torn down and rebuilt on each Hyprland event.
  function rebuild() {
    var titles = parseSpans(root.section.text)
    var fulls = parseSpans(root.section.tooltip)

    for (var i = 0; i < titles.length; i++) {
      var full = i < fulls.length ? stripMarker(unescapePango(fulls[i].body))
                                  : unescapePango(titles[i].body)
      var rec = {
        title: unescapePango(titles[i].body),
        fullTitle: full,
        isFocused: titles[i].bold
      }
      if (i < winModel.count) winModel.set(i, rec)
      else winModel.append(rec)
    }
    while (winModel.count > titles.length) winModel.remove(winModel.count - 1)

    root.scheduleTrim()
    if (root.overflowOpen) root.measurePopupWidth()
    root.scheduleGlow()
    Qt.callLater(root.relayout)
  }

  onUpdated: root.rebuild()

  // ------------------------------------------------------------ the trim
  // Coalesced through callLater so a burst of model and width changes costs
  // one fit pass, and so the first pass runs after the Repeater has built its
  // delegates -- computeTrim reads widths off the live items.
  property bool _trimQueued: false
  function scheduleTrim() {
    if (root._trimQueued) return
    root._trimQueued = true
    Qt.callLater(function () {
      root._trimQueued = false
      root.computeTrim()
      root.scheduleGlow()
    })
  }

  function computeTrim() {
    var total = winModel.count
    var inner = root.maxListWidth - 2 * root.horizontalPadding
    var flags = []
    if (inner <= 0 || total === 0) {
      for (var i = 0; i < total; i++) flags.push(true)
      root.visibleFlags = flags
      root.overflowCount = 0
      return
    }

    // Natural width of the whole list, measured OFFSCREEN (see `measure`
    // below): hiding a title empties its text, so a delegate cannot be both
    // the thing being hidden and the ruler for the hide. The focused title
    // is measured bold -- it renders bold, so the budget must reserve for
    // that. The separator is one fixed mono string, measured once.
    var sepW = 0
    if (total > 1) {
      measure.font.bold = false
      measure.text = "  │  "
      sepW = measure.implicitWidth
    }
    var natural = 0
    var focused = -1
    for (i = 0; i < total; i++) {
      var e = winModel.get(i)
      measure.font.bold = e.isFocused
      measure.text = e.title
      natural += measure.implicitWidth + (i > 0 ? sepW : 0)
      if (e.isFocused) focused = i
    }
    if (natural <= inner) {
      for (i = 0; i < total; i++) flags.push(true)
      root.visibleFlags = flags
      root.overflowCount = 0
      return
    }

    // Overflow: the list collapses to the focused window's title and the
    // chip -- nothing else. A sprawl of grey titles up to the cap is the
    // state this whole mechanism exists to prevent; what the user wants when
    // space runs out is the window they are ON, named, and a door to the
    // rest.
    if (focused === -1) focused = 0
    for (i = 0; i < total; i++) flags.push(i === focused)
    root.visibleFlags = flags
    root.overflowCount = total - 1
  }
  onMaxListWidthChanged: root.scheduleTrim()
  onOverflowCountChanged: if (root.overflowCount === 0) root.closeOverflowNow()

  ListModel { id: winModel }

  // A Row positioner skips children that are not visible, and BarWidget holds a
  // collapsed module at `visible: false` -- which is this widget's normal path:
  // with no windows the module is hidden, so the first window's delegate is
  // built during a frame in which the whole widget is invisible. forceLayout()
  // re-runs the positioner immediately, which is the documented recovery, and
  // the visibility hook is the one that matters because at rebuild() time the
  // reveal animation has not ticked yet.
  //
  // BOTH positioners get it: `list` is ours, and `container.parent` is
  // BarWidget's own content Row, which was handed `container` during that same
  // hidden frame. Skipping the second call has been seen to leave the module at
  // bare padding width (20px) while its content measured 194px.
  function relayout() {
    list.forceLayout()
    if (container.parent && container.parent.forceLayout) container.parent.forceLayout()
  }
  onVisibleChanged: if (visible) Qt.callLater(root.relayout)

  // -------------------------------------------------------------- clicks
  // Resolved at click time, not at parse time: the script and Quickshell's own
  // toplevel model react to the same Hyprland events with no ordering
  // guarantee, so a cached address can be one event stale.
  // The workspace the script is currently listing: the visible scratchpad when
  // it emitted class "scratchpad", otherwise the focused workspace. Used to
  // scope the lookup, so two windows with the same title on different
  // workspaces cannot be confused for one another. Empty means "unknown", in
  // which case the title match runs unscoped rather than failing.
  readonly property string listedWorkspace: {
    if (root.scratchListed) return "special:magic"
    var ws = Hyprland.focusedWorkspace
    return ws !== null ? ws.name : ""
  }

  function addressFor(title, skip) {
    var vals = Hyprland.toplevels.values
    var seen = 0
    for (var i = 0; i < vals.length; i++) {
      var tl = vals[i]
      if (root.listedWorkspace !== "" && tl.workspace !== null
          && tl.workspace !== undefined && tl.workspace.name !== root.listedWorkspace) continue
      // The script falls back to the window class when the title is empty.
      var name = tl.title
      if (!name || name === "") name = tl.lastIpcObject ? (tl.lastIpcObject["class"] || "") : ""
      if (name === title) {
        if (seen === skip) return tl.address
        seen++
      }
    }
    return ""
  }

  function focusWindow(row) {
    if (row < 0 || row >= winModel.count) return
    var target = winModel.get(row).fullTitle
    var occurrence = 0
    for (var i = 0; i < row; i++) {
      if (winModel.get(i).fullTitle === target) occurrence++
    }
    var addr = root.addressFor(target, occurrence)
    // Hyprland 0.56+ parses the dispatch argument as Lua.
    if (addr !== "") Hyprland.dispatch("hl.dsp.focus({ window = \"address:" + addr + "\" })")
  }

  // ------------------------------------------------------------- tooltip
  // Bar.qml owns the single popup surface; BarWidget exposes barWindow() to
  // reach it. Anchoring to the individual title means the bubble points at the
  // window you are actually hovering, which waybar's one-tooltip-per-module
  // cannot do.
  property var hoverItem: null
  property string hoverText: ""

  Timer {
    id: hoverTimer
    interval: Style.anim.tooltipDelay
    onTriggered: {
      var w = root.barWindow()
      if (w && root.hoverItem) w.showTooltip(root.hoverItem, root.hoverText, false)
    }
  }

  function beginHover(item, text) {
    root.hoverItem = item
    root.hoverText = text
    hoverTimer.restart()
  }

  function endHover(item) {
    hoverTimer.stop()
    var w = root.barWindow()
    if (w) w.hideTooltip(item)
    if (root.hoverItem === item) root.hoverItem = null
  }

  // ---------------------------------------------------------- focus halo
  property bool glowReady: false

  function syncGlow() {
    for (var i = 0; i < repeater.count; i++) {
      var entry = repeater.itemAt(i)
      if (entry && entry.isFocused && entry.listed && entry.labelItem) {
        var pt = entry.labelItem.mapToItem(container, 0, 0)
        glow.x = pt.x - Style.module.indicatorPaddingH
        glow.width = entry.labelItem.width + 2 * Style.module.indicatorPaddingH
        glow.on = true
        if (!root.glowReady) root.glowReady = true
        return
      }
    }
    // The focused window can be one of the trimmed ones. The chip stands in
    // for it -- the halo parks on "+N" so focus stays locatable.
    for (i = 0; i < repeater.count; i++) {
      entry = repeater.itemAt(i)
      if (entry && entry.isFocused && !entry.listed) {
        var ct = chip.mapToItem(container, 0, 0)
        glow.x = ct.x
        glow.width = chip.width
        glow.on = true
        return
      }
    }
    glow.on = false
  }

  function scheduleGlow() { Qt.callLater(root.syncGlow) }

  Item {
    id: container
    implicitWidth: list.implicitWidth
    implicitHeight: Style.bar.slotHeight

    // Stands in for `text-shadow: 0 0 8px alpha(@mauve, 0.3)`: a soft halo in
    // the same colour, behind the focused title, that travels with the focus.
    Rectangle {
      id: glow
      property bool on: false

      height: container.implicitHeight
      radius: Style.module.radius
      color: Theme.alpha(root.focusColor, 0.14)
      opacity: on ? 1 : 0
      visible: opacity > 0.01

      Behavior on x {
        enabled: root.glowReady
        NumberAnimation { duration: Style.anim.normal; easing.type: Style.anim.easing }
      }
      // No Behavior on width: the highlight slides but resizes instantly.
      // Window titles differ wildly in length, so animating width made it
      // visibly stretch across the row on every focus change.
      Behavior on opacity { NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth } }
      Behavior on color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }
    }

    Row {
      id: list
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      // Switching to a workspace replaces this whole list at once, so a
      // scale-pop with overshoot per entry plus a 240ms reflow made the bar
      // visibly fill and empty on every switch. Only the reflow motion is
      // kept: no add fade -- an interrupted add transition once left an
      // entry at partial opacity for good.
      move: Transition {
        NumberAnimation { properties: "x,y"; duration: Style.anim.quick; easing.type: Style.anim.easing }
      }

      Repeater {
        id: repeater
        model: winModel

        onItemAdded: root.scheduleGlow()
        onItemRemoved: root.scheduleGlow()

        delegate: Row {
          id: entry
          required property int index
          required property string title
          required property string fullTitle
          required property bool isFocused

          readonly property Item labelItem: label
          // Whether this entry survived the trim. Drives the wrapper WIDTHS
          // below, never text and never visibility: NativeRendering glyphs
          // go permanently blank after an empty/refill or hide/show cycle
          // (both were seen -- the empty pill next to "+5" was exactly
          // this). A trimmed entry is its wrapper clipped to zero width, the
          // same glyphs still rendered behind the clip.
          readonly property bool listed: root.isShown(entry.index)
          spacing: 0

          onXChanged: if (isFocused) root.scheduleGlow()
          onIsFocusedChanged: root.scheduleGlow()
          Component.onCompleted: root.scheduleGlow()
          Component.onDestruction: root.endHover(label)

          // The script joins windows with "  │  ". Rendering that literal
          // string in the same monospace font keeps the spacing identical to
          // waybar's rather than approximating it with a Row spacing. The
          // separator belongs to the entry AFTER it: collapsed when that
          // entry is trimmed, even though earlier entries are visible --
          // otherwise trimmed runs paint orphaned "│ │ │" before the chip.
          Item {
            clip: true
            width: (entry.listed && root.shownBefore(entry.index)) ? sep.implicitWidth : 0
            height: container.implicitHeight

            Text {
              id: sep
              text: "  │  "
              color: Theme.inactive
              font.family: Style.font.family
              font.pixelSize: Style.font.small
            }
          }

          Item {
            clip: true
            width: entry.listed ? label.implicitWidth : 0
            height: container.implicitHeight

            Text {
              id: label
              text: entry.title
            color: entry.isFocused ? root.focusColor
                                   : (hover.containsMouse ? Theme.foreground : Theme.inactive)
            font.family: Style.font.family
            font.pixelSize: Style.font.small
            font.weight: entry.isFocused ? Style.font.boldWeight : Style.font.normalWeight

            y: hover.containsMouse && !entry.isFocused ? -1 : 0
            scale: hover.pressed ? 0.94 : 1

            Behavior on color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }
            Behavior on y { NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing } }
            Behavior on scale { NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing } }

            onWidthChanged: if (entry.isFocused) root.scheduleGlow()

            MouseArea {
              id: hover
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton
              cursorShape: Qt.PointingHandCursor

              onEntered: root.beginHover(label, entry.fullTitle)
              onExited: root.endHover(label)
              onClicked: root.focusWindow(entry.index)
            }
            }
          }
        }
      }

      // ------------------------------------------------------ overflow chip
      // Stands in for every title that did not fit. Hovering it lists the
      // whole workspace; the focus halo parks here when the focused window is
      // one of the hidden ones. Collapsed by clipping like the titles -- the
      // label's text never empties, so its glyphs never blank.
      Item {
        id: chip
        clip: true
        width: root.overflowCount > 0 ? chipLabel.implicitWidth + 2 * Style.module.indicatorPaddingH : 0
        height: container.implicitHeight

        Text {
          id: chipLabel
          anchors.centerIn: parent
          text: "+" + root.overflowCount
          color: chipMouse.containsMouse || root.overflowOpen ? Theme.foreground : Theme.inactive
          font.family: Style.font.family
          font.pixelSize: Style.font.small

          Behavior on color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }
        }

        MouseArea {
          id: chipMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor

          onEntered: root.openOverflow()
          onExited: root.closeOverflowSoon()
          onClicked: root.openOverflow()
        }
      }
    }
  }

  // -------------------------------------------------------- overflow popup
  // The full list behind the "+N" chip: one window per row, focused marked,
  // click to focus. The same life a tooltip has -- raised on hover, dropped
  // shortly after the pointer leaves -- so it exists only while wanted.
  property bool overflowOpen: false
  property real popupWidth: 240

  function openOverflow() {
    overflowHide.stop()
    root.measurePopupWidth()
    root.overflowOpen = true
  }
  function closeOverflowSoon() { overflowHide.restart() }
  function closeOverflowNow() { overflowHide.stop(); root.overflowOpen = false }

  Timer {
    id: overflowHide
    interval: 200
    onTriggered: root.overflowOpen = false
  }

  // Offscreen twin of the popup rows' Text, sizing the popup to its widest
  // line before it is shown -- an elided Text cannot report its natural width
  // without the width that elides it.
  Text {
    id: measure
    visible: false
    font.family: Style.font.family
    font.pixelSize: Style.font.small
  }

  function measurePopupWidth() {
    var w = 0
    for (var i = 0; i < winModel.count; i++) {
      var e = winModel.get(i)
      measure.text = (e.isFocused ? "▶ " : "  ") + e.fullTitle
      w = Math.max(w, measure.implicitWidth)
    }
    root.popupWidth = Math.min(420, Math.ceil(w) + 24)
  }

  PopupWindow {
    id: overflowPopup

    visible: root.overflowOpen && winModel.count > 0
    color: "transparent"

    implicitWidth: Math.ceil(root.popupWidth)
    implicitHeight: Math.ceil(card.implicitHeight)

    anchor {
      item: chip
      adjustment: PopupAdjustment.Flip
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Left
      rect.x: 0
      rect.y: 2
    }

    Rectangle {
      id: card
      width: root.popupWidth
      implicitHeight: rows.implicitHeight + 10
      color: Theme.tooltipBackground
      border.width: 1
      border.color: Theme.tooltipBorder
      radius: Style.module.radius

      Column {
        id: rows
        x: 5
        y: 5
        width: parent.width - 10

        Repeater {
          model: winModel

          delegate: Item {
            id: rowItem
            required property int index
            required property string fullTitle
            required property bool isFocused

            width: rows.width
            height: rowLabel.implicitHeight + 8

            Rectangle {
              anchors.fill: parent
              radius: 6
              color: Theme.hoverBackground
              opacity: rowMouse.containsMouse ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth } }
            }

            Text {
              id: rowLabel
              anchors {
                left: parent.left; leftMargin: 8
                right: parent.right; rightMargin: 8
                verticalCenter: parent.verticalCenter
              }
              elide: Text.ElideRight
              text: (rowItem.isFocused ? "▶ " : "  ") + rowItem.fullTitle
              color: rowItem.isFocused ? root.focusColor
                                       : (rowMouse.containsMouse ? Theme.foreground : Theme.inactive)
              font.family: Style.font.family
              font.pixelSize: Style.font.small
              font.weight: rowItem.isFocused ? Style.font.boldWeight : Style.font.normalWeight
              // Deliberately NOT NativeRendering: this popup window is
              // hidden and reshown constantly, and NativeRendering glyphs
              // can blank on a window's second showing. The rows are read
              // once, briefly -- the default renderer is fine here.
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor

              onEntered: overflowHide.stop()
              onExited: root.closeOverflowSoon()
              onClicked: {
                root.focusWindow(rowItem.index)
                root.closeOverflowNow()
              }
            }
          }
        }
      }
    }
  }
}
