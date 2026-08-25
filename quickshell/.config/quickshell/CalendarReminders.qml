pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Calendar reminders: a notification a few minutes before an event, with
// Join / Snooze / Dismiss on it.
//
// ------------------------------------------------------- why a real notification
// This raises a REAL notification over D-Bus (notify-send) rather than drawing
// its own card. Quickshell is the notification server, so the reminder goes
// through the same path as everything else and gets, for free:
//
//   * the notification centre and its history,
//   * do-not-disturb (Notifications.qml suppresses non-critical popups while
//     dnd is on -- a reminder must obey that, and would not if it painted its
//     own surface), and
//   * the stack. A separate layer surface at the same top-right corner would
//     have sat ON TOP of a real notification with no way to coordinate, since
//     the notification store is a component in shell.qml, not a singleton.
//
// It is also, literally, indistinguishable from any other notification --
// because it is one. NotificationCard renders the Join/Snooze/Dismiss buttons
// from the actions, in the house style, with no work here.
//
// The cost accepted: `notify-send -A` implies --wait, so one child process is
// alive per reminder ON SCREEN, blocked on D-Bus until the user picks an
// action or the notification expires. That is bounded by popupMs and only ever
// happens while a card is actually showing -- unlike a poller, it costs
// nothing at rest.
//
// ------------------------------------------------------------- how it fires
// ONE Timer for the whole schedule, armed for the NEXT deadline and re-armed
// when it fires or when the event list changes. Nothing polls -- the same
// shape services/Notifications.qml uses for popup expiry, and for the same
// reason: a timer per event, or a tick per minute, is a permanent cost for
// something that happens a handful of times a day.
//
// Events come from CalendarData.upcoming (a rolling 37-hour window), NOT from
// the month grid, which follows whatever month the popover is showing.
//
// ------------------------------------------------------------- when it fires
// Google's own reminder settings, per event:
//   reminders.overrides[] with method "popup"  ->  the LARGEST minutes value,
//        so an event with several overrides warns at the earliest of them and
//        still produces only one notification.
//   reminders.useDefault                       ->  the calendar's own
//        defaultReminders (30 minutes on this account), same rule.
//   neither                                    ->  fallbackLeadMinutes.
// "email" overrides are ignored: this is a popup.
//
// A reminder is only raised in the window [fireAt, start + graceMinutes). The
// tail is deliberate -- if the shell restarts two minutes into a meeting you
// still want telling -- but a meeting that started 40 minutes ago is noise,
// and waking from suspend must not dump a burst of stale cards.
//
// -------------------------------------------------------------- persistence
// THE PART THAT MATTERS. This config hot-reloads on every file change and this
// singleton is rebuilt each time. Without persisted state a reload would
// re-fire a reminder the user dismissed ten minutes ago -- worse than having
// no reminders at all. Every decision is written to
//   $XDG_STATE_HOME/quickshell/calendar-reminders.json
// (state, not config: it does not belong in the dotfiles repo), keyed by event
// id + occurrence start:
//   done[key]   = ms   -- raised or dismissed; never raise again
//   snooze[key] = ms   -- raise again at this time
// An event whose time is MOVED gets a new key and correctly reminds again.
// Entries older than pruneDays are dropped on save.
Singleton {
  id: root

  // ---------------------------------------------------------------- config
  readonly property int fallbackLeadMinutes: 10
  readonly property int snoozeMinutes: 5
  // How long after an event has started a reminder is still worth raising.
  readonly property int graceMinutes: 5
  readonly property int pruneDays: 3
  // How long the popup stays up before the server expires it. Long enough to
  // notice and act on, short enough that it is not camping on the screen --
  // and it bounds the notify-send child's lifetime.
  readonly property int popupMs: 120000
  // How long the "Snoozed until ..." confirmation sits there before it goes.
  // Long enough to read a clock time, short enough that it is not a second
  // notification competing for attention.
  readonly property int confirmMs: 1400

  // ----------------------------------------------------------------- state
  // key -> ms. `done` is permanent, `snooze` is a re-arm time.
  property var done: ({})
  property var snooze: ({})
  property bool stateLoaded: false

  // Reminders currently on screen; one notify-send child each.
  property var active: []

  readonly property string stateDir: {
    var xdg = Quickshell.env("XDG_STATE_HOME")
    var base = (xdg && xdg !== "") ? xdg : Quickshell.env("HOME") + "/.local/state"
    return base + "/quickshell"
  }
  readonly property string statePath: {
    return root.stateDir + "/calendar-reminders.json"
  }

  // `id` alone is not an identity: a recurring series repeats it, and Google
  // only appends the occurrence to the id for some series. Pairing it with the
  // occurrence's own start makes the key unique either way -- and makes a
  // MOVED event a different key, which is what re-arms it.
  function keyOf(ev) {
    return (ev.id === "" ? ev.summary : ev.id) + "@" + ev.startIso
  }

  // ------------------------------------------------------------- lead time
  function leadMinutesFor(ev) {
    var r = ev.reminders
    var best = -1

    function scan(list) {
      if (!list) return
      for (var i = 0; i < list.length; i++) {
        if (list[i].method !== "popup") continue
        var m = Number(list[i].minutes)
        if (!isNaN(m) && m > best) best = m
      }
    }

    if (r && r.overrides && r.overrides.length > 0) scan(r.overrides)
    else if (!r || r.useDefault !== false) scan(CalendarData.defaultReminders)

    return best >= 0 ? best : root.fallbackLeadMinutes
  }

  function fireAtFor(ev) {
    var snoozed = snooze[keyOf(ev)]
    if (snoozed !== undefined) return snoozed
    return ev.start.getTime() - leadMinutesFor(ev) * 60000
  }

  // --------------------------------------------------------------- raising
  function isActive(key) {
    for (var i = 0; i < active.length; i++) if (active[i].key === key) return true
    return false
  }

  function fire(ev) {
    var key = keyOf(ev)
    if (isActive(key)) return

    var mins = Math.round((ev.start.getTime() - Date.now()) / 60000)
    var lead = mins > 1 ? "in " + mins + " minutes"
             : mins === 1 ? "in a minute"
             : mins === 0 ? "now"
             : "started " + (-mins) + " min ago"
    var body = Qt.formatTime(ev.start, "HH:mm") + "–" + Qt.formatTime(ev.end, "HH:mm")
             + "  ·  " + lead

    // Join is offered only when there is something to join.
    var acts = []
    if (ev.meeting !== "") acts.push("join=Join")
    acts.push("snooze=Snooze")
    acts.push("dismiss=Dismiss")

    active = active.concat([{
      key: key,
      meeting: ev.meeting,
      summary: ev.summary,
      body: body,
      actions: acts,
      // Needed by the snooze confirmation, which replaces this same card.
      start: ev.start.getTime()
    }])

    // Marked done AT RAISE TIME, not when it is acted on: if the shell reloads
    // while the card is up, the reminder must not come back.
    markDone(key)
    reschedule()
  }

  // Every argument is its own argv element -- summary and body come off the
  // network and are never parsed by a shell. `--` closes the option list so a
  // title that happens to start with "-" is text, not a flag.
  function commandFor(item) {
    // -p prints the server's notification id on stdout BEFORE any action, so
    // the snooze confirmation can replace this exact card rather than opening
    // a second one next to it.
    var cmd = ["notify-send", "-p", "-a", "Calendar", "-u", "normal",
               "-i", "calendar", "-t", String(root.popupMs)]
    for (var i = 0; i < item.actions.length; i++) cmd.push("-A", item.actions[i])
    cmd.push("--", item.summary, item.body)
    return cmd
  }

  // Snoozing is otherwise a silent action: the card vanishes and there is no
  // way to tell whether the click registered, let alone when it comes back.
  //
  // An ABSOLUTE time, not a duration -- the whole reason to snooze a meeting
  // reminder is to know when the next interruption lands, and "14:35" answers
  // that with no arithmetic. Replaces the card IN PLACE (-r <id>) and carries
  // no actions, so it reads as the same card confirming and then leaving.
  //
  // Dismiss deliberately gets no confirmation: the thing going away IS the
  // feedback. Only snooze has an interesting part that happens later.
  function confirmSnooze(item, notifId, until) {
    var when = Qt.formatDateTime(new Date(until), "HH:mm")
    // A reminder that comes back once the meeting is already running is worth
    // flagging -- the time alone would read as if there were still room.
    var text = (item.start > 0 && until > item.start)
        ? "Snoozed — back at " + when + ", after it starts"
        : "Snoozed until " + when

    // Normal urgency, not low: NotificationCard colours a low-urgency card's
    // border green, and a colour change would read as a different card rather
    // than as this one confirming.
    var cmd = ["notify-send", "-a", "Calendar", "-u", "normal", "-i", "calendar",
               "-t", String(root.confirmMs)]
    if (notifId > 0) cmd = cmd.concat(["-r", String(notifId)])
    cmd.push("--", item.summary, text)
    Quickshell.execDetached(cmd)
  }

  // notify-send prints the chosen action's name and exits; it exits with no
  // output if the notification was closed or expired instead.
  function finished(item, action, notifId) {
    if (action === "join") CalendarActions.openMeeting(item.meeting)
    else if (action === "snooze") confirmSnooze(item, notifId, applySnooze(item.key))
    // "dismiss", a plain close, and an expiry all mean the same thing here:
    // the key is already in `done`, so nothing more is owed.

    // Deferred: this runs from the Process's own onExited, and dropping the
    // item from `active` destroys the Instantiator delegate that owns that
    // Process -- i.e. deletes the object whose signal handler is on the stack.
    Qt.callLater(function () {
      root.active = root.active.filter(function (a) { return a.key !== item.key })
      root.reschedule()
    })
  }

  Instantiator {
    model: root.active

    delegate: Process {
      id: proc
      required property var modelData

      command: root.commandFor(modelData)
      running: true

      // The id arrives immediately (-p) and the action only when the user
      // picks one, so this reads LINE BY LINE rather than collecting the whole
      // stream at exit: the id has to be in hand before the action lands, or
      // the snooze confirmation has nothing to replace.
      property int notifId: 0
      property string action: ""

      stdout: SplitParser {
        onRead: function (line) {
          var s = String(line).trim()
          if (s === "") return
          if (proc.notifId === 0 && /^[0-9]+$/.test(s)) {
            proc.notifId = Number(s)
            return
          }
          proc.action = s
        }
      }

      // No output at all means the notification was closed or expired rather
      // than acted on, which needs no handling: the key is already in `done`.
      onExited: root.finished(proc.modelData, proc.action, proc.notifId)
    }
  }

  // ------------------------------------------------------------- decisions
  // Returns the time it will come back, so the confirmation can name the same
  // instant the scheduler will actually use rather than recomputing it.
  function applySnooze(key) {
    var until = Date.now() + root.snoozeMinutes * 60000
    var s = shallowCopy(snooze)
    s[key] = until
    snooze = s
    // Snoozing takes the key back OUT of `done`, or the re-arm would be
    // filtered straight out again when the timer next comes round.
    var d = shallowCopy(done)
    delete d[key]
    done = d
    save()
    return until
  }

  function markDone(key) {
    var d = shallowCopy(done)
    d[key] = Date.now()
    done = d
    var s = shallowCopy(snooze)
    delete s[key]
    snooze = s
    save()
  }

  function shallowCopy(o) {
    var out = {}
    for (var k in o) out[k] = o[k]
    return out
  }

  // ------------------------------------------------------------ scheduling
  Timer {
    id: tick
    repeat: false
    onTriggered: root.run()
  }

  function run() {
    var now = Date.now()
    var due = nextDue(now)
    // One per pass; fire() re-arms, so a backlog arrives as a short sequence
    // rather than as one wall of cards.
    if (due.event && due.at <= now + 10) {
      fire(due.event)
      return
    }
    reschedule()
  }

  // The soonest event that still deserves a notification, and when it wants one.
  function nextDue(now) {
    var list = CalendarData.upcoming
    var bestEv = null
    var bestAt = -1

    for (var i = 0; i < list.length; i++) {
      var ev = list[i]
      var key = keyOf(ev)
      if (done[key] !== undefined) continue
      if (isActive(key)) continue

      // Past the grace window the meeting is well under way, and a card now
      // would be noise. This is what stops a wake-from-suspend burst.
      if (now > ev.start.getTime() + root.graceMinutes * 60000) continue

      var at = fireAtFor(ev)
      if (bestAt < 0 || at < bestAt) { bestAt = at; bestEv = ev }
    }
    return { event: bestEv, at: bestAt }
  }

  function reschedule() {
    if (!stateLoaded) return
    var now = Date.now()
    var due = nextDue(now)
    if (!due.event) { tick.stop(); return }

    var next = Math.max(due.at, now)
    // Capped at ten minutes so a deadline hours out still re-checks: the wall
    // clock jumps (suspend, NTP) and a single multi-hour interval would sail
    // straight past its target.
    tick.interval = Math.min(Math.max(20, next - now), 600000)
    tick.restart()
  }

  // A new event list means new deadlines: something may have moved, been
  // deleted, or appeared.
  Connections {
    target: CalendarData
    function onUpcomingChanged() { root.reschedule() }
  }

  // ------------------------------------------------------------- the file
  FileView {
    id: stateFile
    path: root.statePath
    printErrors: false
    // Rewritten whole on every decision; a torn write would lose the dismissal
    // record, which is the one thing that must not be lost.
    atomicWrites: true

    onLoaded: {
      try {
        var d = JSON.parse(text())
        root.done = d.done || {}
        root.snooze = d.snooze || {}
      } catch (e) {
        root.done = ({})
        root.snooze = ({})
      }
      root.stateLoaded = true
      root.reschedule()
    }
    // No file on a first run. That is not an error, it is an empty state.
    onLoadFailed: {
      root.stateLoaded = true
      root.reschedule()
    }
  }

  function save() {
    if (!stateLoaded) return
    var cutoff = Date.now() - root.pruneDays * 86400000
    var d = {}
    for (var k in done) if (done[k] >= cutoff) d[k] = done[k]
    var s = {}
    for (var k2 in snooze) if (snooze[k2] >= cutoff) s[k2] = snooze[k2]
    done = d
    snooze = s
    stateFile.setText(JSON.stringify({ version: 1, done: d, snooze: s }))
  }

  // ----------------------------------------------------------------- ipc
  // Every other service in this shell exposes one (notifications, osd, the
  // launchers), and a schedule that only speaks up twice a day is otherwise
  // impossible to inspect. `refresh` is also what to call after editing the
  // calendar elsewhere, rather than waiting out the 15-minute cycle.
  IpcHandler {
    target: "calendar"

    function refresh(): string {
      CalendarData.refreshUpcoming()
      return "refreshing"
    }

    function status(): string {
      var now = Date.now()
      var due = root.nextDue(now)
      var out = "upcoming=" + CalendarData.upcoming.length
              + " active=" + root.active.length
              + " done=" + Object.keys(root.done).length
              + " snoozed=" + Object.keys(root.snooze).length
              // The account links are pinned to, and the browser Join uses --
              // both derived, so worth being able to see when a link opens
              // under the wrong profile.
              + " account=" + CalendarActions.account
              + " meet=" + (CalendarActions.meetBrowser === "" ? "-" : CalendarActions.meetBrowser)
      if (!due.event) return out + " next=none"
      return out + " next=\"" + due.event.summary + "\" at "
           + Qt.formatDateTime(new Date(due.at), "HH:mm:ss")
           + " (in " + Math.round((due.at - now) / 1000) + "s)"
    }

    // Clears the "already reminded" record. For when a reminder was missed and
    // you want it back without waiting for the next occurrence.
    //
    // It re-raises IMMEDIATELY for anything still inside its fire window, which
    // is the point but is easy to be surprised by -- call `refresh` first if
    // the calendar has changed, or the cached list will remind you about events
    // that no longer exist.
    function forget(): string {
      root.done = ({})
      root.snooze = ({})
      root.save()
      root.reschedule()
      return "cleared"
    }
  }

  // ------------------------------------------------------------- refresh
  // The upcoming window is re-read every 15 minutes, matching CalendarData's
  // own cadence, plus once at startup. Nothing polls in between: the schedule
  // is entirely timer-driven off that list.
  Component.onCompleted: {
    // FileView.setText does not create missing parent directories, and
    // ~/.local/state/quickshell does not exist on a fresh machine. Done once
    // at startup rather than lazily on first save, because the save that
    // matters -- the dismissal record -- must not race a mkdir.
    Quickshell.execDetached(["/usr/bin/mkdir", "-p", root.stateDir])
    CalendarData.refreshUpcoming()
  }

  Timer {
    interval: 15 * 60 * 1000
    repeat: true
    running: true
    onTriggered: CalendarData.refreshUpcoming()
  }
}
