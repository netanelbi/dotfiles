import QtQuick
import Quickshell
import Quickshell.Wayland
import "root:/"

// The clock's calendar popover: a month grid plus the selected day's real
// Google Calendar events (CalendarData does the fetching).
//
// ------------------------------------------------------------------ surface
// This is a FULLSCREEN layer surface with a transparent backdrop, not a small
// popup sized to the card -- the same shape as launchers/LauncherPanel.qml.
// Two reasons, in order of importance:
//
//  1. A layer surface must not change size while anything animates. The
//     compositor has to configure/ack every size change before the client may
//     commit, so a surface bound to animating content does one round trip per
//     frame (measured elsewhere in this shell: a 180ms entrance took 467ms and
//     rendered as five visible lurches). A fullscreen window is configured
//     ONCE, at map time, and never again -- the card then slides, fades and
//     grows entirely inside it, at a flat 16ms per frame.
//  2. A popup surface has no way to notice a click on the desktop behind it.
//     The backdrop gives click-outside dismissal for free.
//
// The window is anchored to the screen, so the card is positioned by hand
// under the clock: `anchorItem` is measured in the BAR's window and offset by
// the bar's own margins to get screen coordinates.
PanelWindow {
  id: popup

  // ------------------------------------------------------------------ api
  // The clock widget this popover hangs under, in the bar window.
  property Item anchorItem: null
  // The bar window's own origin on screen, so the anchor measurement can be
  // converted from bar coordinates to screen coordinates.
  property int barOriginX: 0
  // Screen y the card's top edge sits at (below the bar).
  property int cardTop: 0

  property bool opened: false

  function present() {
    if (opened) return
    // Snap the view back to the real today: leaving the popover parked on
    // "March 2027" from last time is never what is wanted.
    var now = new Date()
    popup.viewYear = now.getFullYear()
    popup.viewMonth = now.getMonth()
    popup.selected = new Date(now.getFullYear(), now.getMonth(), now.getDate())
    measure()
    opened = true
    CalendarData.ensure(viewYear, viewMonth, false)
    Qt.callLater(function () { keyScope.forceActiveFocus() })
  }

  function dismiss() {
    if (!opened) return
    opened = false
  }

  function toggle() {
    if (opened) dismiss()
    else present()
  }

  // Opening a link is the end of what the popover was for, so it closes.
  // WHERE the link goes is CalendarActions' business -- the reminder popups
  // open the same links and must route them identically.
  function openUrl(url) {
    CalendarActions.open(url)
    dismiss()
  }

  function openMeeting(url) {
    CalendarActions.openMeeting(url)
    dismiss()
  }

  // Touching the singleton HERE, at load, is what makes Join work on the first
  // click. Quickshell constructs a singleton on first use, and CalendarActions
  // was only used from inside openMeeting() -- so the first Join click both
  // created it AND read meetBrowser, while the DesktopEntries scan behind that
  // binding had only just started and was still asynchronous. meetBrowser was
  // "" for exactly one click, and the meeting opened in the browser instead of
  // the webapp. Reading it at load starts the scan at shell startup; the
  // binding then re-evaluates when the entry list fills, long before anyone
  // can click. (AppLauncher.qml carries the same note about the lazy scan.)
  readonly property bool meetWebapp: CalendarActions.meetWebappAvailable

  // ------------------------------------------------------------- geometry
  readonly property int cardWidth: 344
  readonly property int pad: 14
  // 38, not 34: the 26px day disc plus the 3px selection ring around it reaches
  // y=31, and the event dots have to clear that or a selected day loses them.
  readonly property int cellHeight: 38
  // Exactly four 38px rows plus their spacing. Fixed, so switching between a
  // quiet day and a busy one never resizes the card.
  readonly property int eventsHeight: 158

  // mapToItem is not a binding, so the measurement is redone on open and
  // whenever the clock moves (a neighbouring widget collapsing reflows the
  // centre island, which slides the clock).
  property real anchorCenterX: 0

  function measure() {
    if (!anchorItem) return
    var p = anchorItem.mapToItem(null, 0, 0)
    anchorCenterX = p.x + anchorItem.width / 2 + popup.barOriginX
  }

  Connections {
    target: popup.anchorItem
    ignoreUnknownSignals: true
    function onXChanged() { popup.measure() }
    function onWidthChanged() { popup.measure() }
  }

  // Kept on screen if the clock ever sits near an edge. The bound comes from
  // the WINDOW's own width, not screen.width/devicePixelRatio: ShellScreen
  // reports logical pixels already (1280 on this 1920x1200 @ 1.5 output) while
  // devicePixelRatio reports 2, so dividing shrank the usable width to 640 and
  // pinned the card 145px left of the clock.
  readonly property real cardX: {
    var raw = anchorCenterX - cardWidth / 2
    if (popup.width <= 0) return Math.max(8, raw)
    return Math.max(8, Math.min(raw, popup.width - cardWidth - 8))
  }

  // ---------------------------------------------------------------- window
  WlrLayershell.namespace: "quickshell-calendar"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
  exclusionMode: ExclusionMode.Ignore

  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"

  // `revealed` drives every entrance/exit; the window outlives `opened` by one
  // fade so the card can animate out instead of vanishing.
  property real revealed: 0
  visible: opened || revealed > 0.001
  onOpenedChanged: revealed = opened ? 1 : 0

  Behavior on revealed {
    NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
  }

  // ------------------------------------------------------------- the month
  property int viewYear: 2026
  property int viewMonth: 0                 // 0-based, like JS Date
  property var selected: new Date()

  readonly property var today: clockTick.now

  function shiftMonth(delta) {
    var d = new Date(viewYear, viewMonth + delta, 1)
    viewYear = d.getFullYear()
    viewMonth = d.getMonth()
    CalendarData.ensure(viewYear, viewMonth, false)
  }

  function goToday() {
    var now = new Date()
    viewYear = now.getFullYear()
    viewMonth = now.getMonth()
    selected = new Date(now.getFullYear(), now.getMonth(), now.getDate())
    CalendarData.ensure(viewYear, viewMonth, false)
  }

  function selectOffset(days) {
    var d = new Date(popup.selected.getTime())
    d.setDate(d.getDate() + days)
    popup.selected = d
    if (d.getFullYear() !== viewYear || d.getMonth() !== viewMonth) {
      viewYear = d.getFullYear()
      viewMonth = d.getMonth()
      CalendarData.ensure(viewYear, viewMonth, false)
    }
  }

  // The first cell of the 6x7 grid: back from the 1st to the locale's start of
  // week (Sunday under en_IL). QML's Locale.firstDayOfWeek and JS getDay()
  // both count Sunday as 0, so they can be subtracted directly.
  readonly property var gridStart: {
    var first = new Date(popup.viewYear, popup.viewMonth, 1)
    var shift = (first.getDay() - Qt.locale().firstDayOfWeek + 7) % 7
    return new Date(popup.viewYear, popup.viewMonth, 1 - shift)
  }

  function cellDate(i) {
    var d = new Date(popup.gridStart.getTime())
    d.setDate(d.getDate() + i)
    return d
  }

  function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
  }

  // Only ticks while the popover is on screen -- the bar has its own clock and
  // this one exists purely to move the "today" highlight across midnight.
  Timer {
    id: clockTick
    property var now: new Date()
    interval: 60000
    repeat: true
    running: popup.visible
    onTriggered: now = new Date()
    onRunningChanged: if (running) now = new Date()
  }

  // ------------------------------------------------------- calendar colours
  readonly property var calendarColors: [Theme.mauve, Theme.teal, Theme.peach, Theme.blue, Theme.pink, Theme.green, Theme.sky]
  function calendarColor(i) {
    var n = calendarColors.length
    return calendarColors[(((i || 0) % n) + n) % n]
  }

  // ------------------------------------------------------------- backdrop
  // Undimmed, unlike the launchers: this is a popover hanging off a bar
  // widget, not a modal takeover of the screen. It only exists to catch the
  // click that closes it.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onClicked: popup.dismiss()
  }

  FocusScope {
    id: keyScope
    anchors.fill: parent
    focus: true

    Keys.onPressed: function (event) {
      switch (event.key) {
      case Qt.Key_Escape:                          popup.dismiss();      event.accepted = true; return
      case Qt.Key_Left:                            popup.selectOffset(-1); event.accepted = true; return
      case Qt.Key_Right:                           popup.selectOffset(1);  event.accepted = true; return
      case Qt.Key_Up:                              popup.selectOffset(-7); event.accepted = true; return
      case Qt.Key_Down:                            popup.selectOffset(7);  event.accepted = true; return
      case Qt.Key_PageUp:                          popup.shiftMonth(-1); event.accepted = true; return
      case Qt.Key_PageDown:                        popup.shiftMonth(1);  event.accepted = true; return
      case Qt.Key_Home:                            popup.goToday();      event.accepted = true; return
      case Qt.Key_R:                               CalendarData.ensure(popup.viewYear, popup.viewMonth, true); event.accepted = true; return
      }
    }

    // ------------------------------------------------------------- the card
    Rectangle {
      id: card

      x: popup.cardX
      // Rests at cardTop; starts 10px higher, the way the OSD rises into place
      // -- the motion runs inside the window, never on the surface.
      y: popup.cardTop - 10 * (1 - popup.revealed)
      width: popup.cardWidth
      implicitHeight: body.implicitHeight + 2 * popup.pad
      height: implicitHeight

      opacity: popup.revealed
      scale: 0.97 + 0.03 * popup.revealed
      transformOrigin: Item.Top

      // Only the error strip can change this, and it is inside a fullscreen
      // window, so it costs nothing but a repaint.
      Behavior on height {
        NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
      }

      // Same chrome as the notification cards: radius 12, @base, 2px @mauve.
      color: Theme.base
      radius: 12
      border.width: 2
      border.color: Theme.accent
      clip: true

      Column {
        id: body
        x: popup.pad
        y: popup.pad
        width: parent.width - 2 * popup.pad
        spacing: 0

        // ------------------------------------------------------------ header
        Item {
          width: parent.width
          height: 32

          Text {
            id: monthLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: Qt.formatDate(new Date(popup.viewYear, popup.viewMonth, 1), "MMMM yyyy")
            color: Theme.text
            font.family: Style.font.family
            font.pixelSize: Style.font.size
            font.weight: Style.font.boldWeight
            renderType: Text.NativeRendering

            // A month change should read as a substitution, not a flicker.
            onTextChanged: monthFade.restart()
            NumberAnimation {
              id: monthFade
              target: monthLabel; property: "opacity"
              from: 0.3; to: 1
              duration: Style.anim.normal; easing.type: Style.anim.easing
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            // Only offered when it would do something.
            NavButton {
              glyph: "󰥔"
              size: 26
              shown: popup.viewYear !== popup.today.getFullYear() || popup.viewMonth !== popup.today.getMonth()
              onTriggered: popup.goToday()
            }
            NavButton { glyph: "‹"; onTriggered: popup.shiftMonth(-1) }
            NavButton { glyph: "›"; onTriggered: popup.shiftMonth(1) }
          }
        }

        Item { width: 1; height: 4 }

        // ----------------------------------------------------- weekday names
        Row {
          width: parent.width
          height: 20

          Repeater {
            model: 7
            Text {
              required property int index
              width: body.width / 7
              height: 20
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              // QML's Locale.dayName counts Sunday as 0, matching firstDayOfWeek.
              text: Qt.locale().dayName((Qt.locale().firstDayOfWeek + index) % 7, Locale.ShortFormat)
              color: Theme.overlay0
              font.family: Style.font.family
              font.pixelSize: Style.font.size - 3
              font.weight: Style.font.boldWeight
              renderType: Text.NativeRendering
            }
          }
        }

        // ------------------------------------------------------- month grid
        // Always six rows, so navigating months never changes the card's
        // height and the event list below never shifts under the cursor.
        //
        // The wheel handler is a SIBLING of the Grid, not a child of it. A
        // positioner lays out every visible child it has, and an anchored one
        // makes it give up entirely -- "Cannot specify anchors for items
        // inside Grid. Grid will not function", after which the whole month
        // renders at zero height.
        Item {
          width: parent.width
          height: 6 * popup.cellHeight

          MouseArea {
            anchors.fill: parent
            // Wheel only. The day cells sit above this and take the clicks;
            // they declare no onWheel, so the wheel falls through to here.
            acceptedButtons: Qt.NoButton
            property int accum: 0
            onWheel: function (event) {
              accum += event.angleDelta.y
              while (accum >= 120) { accum -= 120; popup.shiftMonth(-1) }
              while (accum <= -120) { accum += 120; popup.shiftMonth(1) }
            }
          }

        Grid {
          id: grid
          anchors.fill: parent
          columns: 7
          rows: 6

          Repeater {
            model: 42

            Item {
              id: cell
              required property int index

              readonly property var date: popup.cellDate(index)
              readonly property bool inMonth: date.getMonth() === popup.viewMonth
              readonly property bool isToday: popup.sameDay(date, popup.today)
              readonly property bool isSelected: popup.sameDay(date, popup.selected)
              readonly property var events: CalendarData.eventsFor(date)

              width: body.width / 7
              height: popup.cellHeight

              // The day disc. Today is filled; the selection is a ring, so a
              // selected today reads as both at once.
              Rectangle {
                id: disc
                anchors.horizontalCenter: parent.horizontalCenter
                y: 2
                width: 26
                height: 26
                radius: 13
                color: cell.isToday ? Theme.accent
                     : (cellMouse.containsMouse ? Theme.hoverBackground : "transparent")
                border.width: cell.isSelected && !cell.isToday ? 1 : 0
                border.color: Theme.accent

                Behavior on color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }

                // A ring OUTSIDE the disc, for the selected-today case.
                Rectangle {
                  anchors.centerIn: parent
                  width: parent.width + 6
                  height: parent.height + 6
                  radius: width / 2
                  color: "transparent"
                  border.width: 1
                  border.color: Theme.alpha(Theme.accent, 0.6)
                  opacity: cell.isSelected && cell.isToday ? 1 : 0
                  Behavior on opacity { NumberAnimation { duration: Style.anim.opacityDuration } }
                }

                Text {
                  anchors.centerIn: parent
                  text: cell.date.getDate()
                  color: cell.isToday ? Theme.base : (cell.inMonth ? Theme.text : Theme.overlay0)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.size - 2
                  font.weight: cell.isToday || cell.isSelected ? Style.font.boldWeight : Style.font.normalWeight
                  renderType: Text.NativeRendering
                }
              }

              // Up to three dots, one per event, coloured by calendar.
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 2
                spacing: 3

                Repeater {
                  model: Math.min(3, cell.events.length)
                  Rectangle {
                    required property int index
                    width: 4
                    height: 4
                    radius: 2
                    // Always the calendar's colour. The dots sit BELOW the day
                    // disc, on the card background -- painting today's in
                    // Theme.base to contrast with the mauve disc made them
                    // invisible instead.
                    color: popup.calendarColor(cell.events[index].calendar)
                    opacity: cell.inMonth ? 1 : 0.45
                  }
                }
              }

              MouseArea {
                id: cellMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  popup.selected = cell.date
                  // Clicking a trailing/leading cell walks to that month, the
                  // way the day cells in Google Calendar's mini-month do.
                  if (!cell.inMonth) {
                    popup.viewYear = cell.date.getFullYear()
                    popup.viewMonth = cell.date.getMonth()
                    CalendarData.ensure(popup.viewYear, popup.viewMonth, false)
                  }
                }
              }
            }
          }
        }
        }

        Item { width: 1; height: 8 }

        Rectangle { width: parent.width; height: 1; color: Theme.surface0 }

        // ----------------------------------------------------- error strip
        // Shown ABOVE the events rather than instead of them: a failed refresh
        // still leaves the last good month on screen.
        Item {
          width: parent.width
          height: CalendarData.state === "error" ? errorRow.implicitHeight + 14 : 0
          clip: true
          opacity: CalendarData.state === "error" ? 1 : 0

          Behavior on height { NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing } }
          Behavior on opacity { NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth } }

          Row {
            id: errorRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 6
            spacing: 6

            Text {
              text: "󰀪"
              color: Theme.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.size - 2
              renderType: Text.NativeRendering
            }

            Text {
              width: errorRow.width - 24 - retry.width
              text: CalendarData.errorText === "" ? "Calendar unavailable" : CalendarData.errorText
              color: Theme.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.size - 3
              wrapMode: Text.WordWrap
              renderType: Text.NativeRendering
            }

            Text {
              id: retry
              text: "retry"
              color: retryMouse.containsMouse ? Theme.text : Theme.overlay0
              font.family: Style.font.family
              font.pixelSize: Style.font.size - 3
              font.underline: retryMouse.containsMouse
              renderType: Text.NativeRendering

              MouseArea {
                id: retryMouse
                anchors.fill: parent
                anchors.margins: -4
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: CalendarData.retry()
              }
            }
          }
        }

        // ----------------------------------------------------- day heading
        Item {
          width: parent.width
          height: 30

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: popup.sameDay(popup.selected, popup.today)
                ? "Today · " + Qt.formatDate(popup.selected, "d MMM")
                : Qt.formatDate(popup.selected, "dddd d MMM")
            color: Theme.subtext0
            font.family: Style.font.family
            font.pixelSize: Style.font.size - 3
            font.weight: Style.font.boldWeight
            renderType: Text.NativeRendering
          }

          // A quiet, non-blocking spinner: the bar keeps working while gws is
          // out on the network, and this is the only sign that it is.
          Text {
            id: spinner
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "●"
            color: Theme.accent
            font.family: Style.font.family
            font.pixelSize: 8
            renderType: Text.NativeRendering
            opacity: 0

            // `visible: false` stops painting, NOT animating -- the animation
            // has to be gated on `running` or it burns a frame timer while the
            // popover is shut.
            SequentialAnimation {
              running: CalendarData.loading && popup.visible
              loops: Animation.Infinite
              alwaysRunToEnd: false
              onStopped: spinner.opacity = 0
              NumberAnimation { target: spinner; property: "opacity"; to: 1; duration: 420; easing.type: Style.anim.easingSmooth }
              NumberAnimation { target: spinner; property: "opacity"; to: 0.15; duration: 420; easing.type: Style.anim.easingSmooth }
            }
          }
        }

        // ------------------------------------------------------ event list
        Item {
          width: parent.width
          height: popup.eventsHeight

          readonly property var dayEvents: CalendarData.eventsFor(popup.selected)

          ListView {
            id: eventList
            anchors.fill: parent
            model: parent.dayEvents
            clip: true
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds
            // A day's events are replaced wholesale when the selection moves;
            // fading them in beats having them pop.
            add: Transition {
              NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Style.anim.opacityDuration }
            }

            // A row is: colour bar | time column | title (+ place) | Join.
            // The time lives in its OWN left column rather than under the
            // title, so a day's schedule can be read straight down the times
            // without parsing each row -- which is how every calendar day view
            // is laid out, and the reason the title stays on one line.
            delegate: Item {
              id: row
              required property var modelData
              width: eventList.width
              height: 38

              // htmlLink is present on every event this account returns, but
              // an event without one must not look pressable.
              readonly property bool openable: modelData.link !== ""
              readonly property bool joinable: modelData.meeting !== ""
              // Only a real place is worth a second line; a bare Meet/Zoom URL
              // pasted into `location` duplicates the Join button.
              readonly property string place: {
                var w = modelData.location
                if (w === "" || w.indexOf("http") === 0) return ""
                return w
              }

              Rectangle {
                anchors.fill: parent
                anchors.rightMargin: 2
                radius: 6
                // joinMouse too: it sits above rowMouse and swallows the
                // hover, which otherwise left the row looking inert exactly
                // while the cursor was on its button.
                color: rowMouse.containsMouse || joinMouse.containsMouse ? Theme.hoverBackground : "transparent"
                Behavior on color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: row.openable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (row.openable) popup.openUrl(row.modelData.link)
              }

              Rectangle {
                id: bullet
                x: 4
                anchors.verticalCenter: parent.verticalCenter
                width: 3
                height: 24
                radius: 1.5
                color: popup.calendarColor(row.modelData.calendar)
              }

              // ------------------------------------------------ time column
              Item {
                id: timeCol
                anchors.left: bullet.right
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 44
                height: parent.height

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width
                  spacing: 0

                  Text {
                    width: parent.width
                    text: row.modelData.allDay ? "all-day" : Qt.formatTime(row.modelData.start, "HH:mm")
                    color: row.modelData.allDay ? Theme.overlay0 : Theme.subtext1
                    font.family: Style.font.family
                    font.pixelSize: row.modelData.allDay ? Style.font.size - 4 : Style.font.size - 3
                    renderType: Text.NativeRendering
                  }

                  // The end time only earns a line on a timed event.
                  Text {
                    width: parent.width
                    visible: !row.modelData.allDay
                    text: Qt.formatTime(row.modelData.end, "HH:mm")
                    color: Theme.overlay0
                    font.family: Style.font.family
                    font.pixelSize: Style.font.size - 4
                    renderType: Text.NativeRendering
                  }
                }
              }

              // ----------------------------------------------------- title
              Column {
                anchors.left: timeCol.right
                anchors.leftMargin: 8
                anchors.right: parent.right
                // Reserve room for the Join pill only on rows that have one,
                // so a row without a meeting gets the full width for its title.
                anchors.rightMargin: row.joinable ? joinPill.width + 12 : 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                  width: parent.width
                  text: row.modelData.summary
                  color: Theme.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.size - 2
                  elide: Text.ElideRight
                  renderType: Text.NativeRendering
                }

                Text {
                  width: parent.width
                  visible: row.place !== ""
                  text: row.place
                  color: Theme.overlay0
                  font.family: Style.font.family
                  font.pixelSize: Style.font.size - 4
                  elide: Text.ElideRight
                  renderType: Text.NativeRendering
                }
              }

              // ------------------------------------------------------ Join
              // Always visible on a row that has a meeting -- a hover-only
              // button is not discoverable when the popover is the only place
              // the link appears. It brightens on hover instead.
              Rectangle {
                id: joinPill
                visible: row.joinable
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                width: joinLabel.implicitWidth + 14
                height: 20
                radius: 6
                color: joinMouse.containsMouse ? Theme.accent : Theme.alpha(Theme.accent, 0.16)
                scale: joinMouse.pressed ? 0.92 : 1

                Behavior on color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }
                Behavior on scale { NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing } }

                Text {
                  id: joinLabel
                  anchors.centerIn: parent
                  text: "Join"
                  color: joinMouse.containsMouse ? Theme.base : Theme.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.size - 4
                  font.weight: Style.font.boldWeight
                  renderType: Text.NativeRendering
                  Behavior on color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }
                }

                // Declared after rowMouse, so it sits above it and takes the
                // press -- clicking Join must not also open the event page.
                MouseArea {
                  id: joinMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: popup.openMeeting(row.modelData.meeting)
                }
              }
            }
          }

          // Overflow hint. Four rows fit; a busier day scrolls, and without
          // this there is nothing on screen to say so.
          Rectangle {
            anchors.right: parent.right
            anchors.rightMargin: 1
            width: 2
            radius: 1
            color: Theme.surface2
            visible: eventList.contentHeight > eventList.height
            y: eventList.contentHeight <= 0 ? 0
             : eventList.visibleArea.yPosition * parent.height
            height: eventList.contentHeight <= 0 ? 0
                  : Math.max(16, eventList.visibleArea.heightRatio * parent.height)
          }

          // Empty / first-load placeholder. `hasData` distinguishes "nothing
          // on this day" from "nothing fetched yet", which look identical
          // otherwise.
          Text {
            anchors.centerIn: parent
            visible: eventList.count === 0
            text: CalendarData.loading && !CalendarData.hasData ? "Loading events…"
                : (CalendarData.state === "error" && !CalendarData.hasData ? "No events to show"
                : "Nothing scheduled")
            color: Theme.overlay0
            font.family: Style.font.family
            font.pixelSize: Style.font.size - 3
            renderType: Text.NativeRendering
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ nav button
  component NavButton: Item {
    id: nav
    property string glyph: ""
    property int size: 24
    property bool shown: true
    signal triggered()

    width: shown ? size : 0
    height: size
    opacity: shown ? 1 : 0
    visible: opacity > 0.01
    clip: true

    Behavior on width { NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing } }
    Behavior on opacity { NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth } }

    Rectangle {
      anchors.fill: parent
      radius: 6
      color: navMouse.containsMouse ? Theme.hoverBackground : "transparent"
      scale: navMouse.pressed ? 0.9 : 1
      Behavior on color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }
      Behavior on scale { NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easing } }
    }

    Text {
      anchors.centerIn: parent
      text: nav.glyph
      color: navMouse.containsMouse ? Theme.text : Theme.subtext0
      font.family: Style.font.family
      font.pixelSize: Style.font.size
      renderType: Text.NativeRendering
      Behavior on color { ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth } }
    }

    MouseArea {
      id: navMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: nav.triggered()
    }
  }
}
