pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Google Calendar events, read through the user's already-authenticated `gws`
// CLI. One shared instance for the whole shell: Bar.qml is instantiated once
// per monitor, so a per-bar fetcher would run `gws` twice on a docked setup.
//
// ------------------------------------------------------------------ the CLI
//   /usr/bin/gws calendar calendarList list --params '{"minAccessRole":"reader"}'
//   /usr/bin/gws calendar events list --params '{"calendarId":..., "timeMin":...,
//                                                "timeMax":..., "singleEvents":true,
//                                                "orderBy":"startTime","maxResults":250}'
//
// `gws` is invoked by ABSOLUTE PATH. `gwsw`/`gwsp` are fish functions that
// swap the profile by pointing at a different config dir; they do not exist
// outside an interactive fish, and going through `sh -lc gws` would find the
// binary but is one more thing to go wrong. Plain `gws` == the work profile,
// which is the default config dir, so the bare binary is already the right
// account.
//
// `gws` prints "Using keyring backend: keyring" on STDERR before every call --
// stdout is clean JSON, so stdout is parsed and stderr is kept only to quote
// back in the error state.
//
// ------------------------------------------------------------- fetch policy
// NEVER polled. Events are fetched:
//   * when a popover opens on a month that is not already cached, and
//   * every 15 minutes, and only once a popover has been opened at all --
//     a user who never clicks the clock never causes a network call.
// One month's worth of grid (the month +/- a week, so the leading and
// trailing cells of the 6x7 grid are populated too) per fetch.
//
// Calendars are fetched ONE AT A TIME through a single Process, not in
// parallel. Two `gws` runs take ~1.1s total and serialising them means there
// is never more than one child process alive, which is the same discipline the
// rest of this shell keeps.
Singleton {
  id: root

  // ------------------------------------------------------------------ state
  // "idle" | "loading" | "ok" | "error". `ok` and `error` both mean a fetch
  // finished; `events` may still hold the previous good result in `error`,
  // which is deliberate -- the popover shows stale data with a warning strip
  // rather than an empty panel.
  property string state: "idle"
  property string errorText: ""

  // "YYYY-MM-DD" -> [event]. Replaced wholesale on each successful fetch.
  property var eventsByDay: ({})
  // The month `eventsByDay` was built for, as "YYYY-M". Empty until a fetch
  // lands, so a failed first fetch does not look cached.
  property string loadedKey: ""
  property bool hasData: loadedKey !== ""

  readonly property bool loading: state === "loading"

  // ------------------------------------------------------------------- api
  function monthKey(year, month0) { return year + "-" + month0 }

  // Local YYYY-MM-DD. Built by hand rather than through toISOString(), which
  // would shift a date near midnight into the previous/next day in UTC.
  function dayKey(d) {
    var m = d.getMonth() + 1
    var day = d.getDate()
    return d.getFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (day < 10 ? "0" : "") + day
  }

  function eventsFor(d) {
    var list = eventsByDay[dayKey(d)]
    return list === undefined ? [] : list
  }

  // Called by the popover: on open, on month navigation, and on retry.
  function ensure(year, month0, force) {
    everOpened = true
    var key = monthKey(year, month0)
    if (!force && key === loadedKey && state !== "error") return
    if (busy) {
      // Coalesce: a fast click through several months must not launch a fetch
      // per month. The last month asked for wins when the current run lands.
      wantedYear = year
      wantedMonth = month0
      wantPending = true
      return
    }
    beginFetch(year, month0)
  }

  function retry() {
    beginFetch(pendingYear, pendingMonth)
  }

  // --------------------------------------------------------------- internals
  property bool everOpened: false
  property bool busy: false

  property int pendingYear: 0
  property int pendingMonth: 0
  property bool wantPending: false
  property int wantedYear: 0
  property int wantedMonth: 0

  // Calendar ids discovered once and reused; the set changes about never, and
  // re-listing them on every month flip would double the process count.
  property var calendarIds: []
  // Queue for the in-flight fetch, plus the events accumulated so far.
  property var queue: []
  property var accum: []
  property string rangeMin: ""
  property string rangeMax: ""

  function beginFetch(year, month0) {
    startRun("grid", year, month0)
  }

  // ------------------------------------------------------------- upcoming
  // A SECOND, independent window of events: everything timed between an hour
  // ago and 36 hours out. CalendarReminders schedules from this.
  //
  // It cannot schedule from eventsByDay, which holds whichever month the
  // popover is looking at -- navigate to December and today's meetings drop
  // out of the cache, and the reminders would go with them. Same process
  // queue, same calendar list, different destination.
  property var upcoming: []
  // The calendar's own default reminder settings, which is what an event's
  // `reminders: { useDefault: true }` refers to. It rides along on the
  // events.list response, so honouring it costs no extra call.
  property var defaultReminders: []
  property bool wantUpcoming: false

  function refreshUpcoming() {
    if (busy) { wantUpcoming = true; return }
    startRun("upcoming", pendingYear, pendingMonth)
  }

  // ---------------------------------------------------------------- runs
  // One in-flight run at a time, in one of two modes. Serialising them keeps
  // the single Process honest: a grid fetch and an upcoming fetch never share
  // the queue, they take turns.
  property string mode: "grid"

  function startRun(runMode, year, month0) {
    busy = true
    mode = runMode
    state = "loading"
    errorText = ""

    var from, to
    if (runMode === "upcoming") {
      wantUpcoming = false
      // An hour back, so an event that started while the shell was down is
      // still visible to the staleness rule rather than silently missing.
      from = new Date(Date.now() - 3600000)
      to = new Date(Date.now() + 36 * 3600000)
    } else {
      wantPending = false
      pendingYear = year
      pendingMonth = month0
      // A week of slack on each side covers the leading/trailing cells of the
      // 6x7 grid and makes the UTC/local boundary a non-issue.
      from = new Date(year, month0, 1)
      from.setDate(from.getDate() - 7)
      to = new Date(year, month0 + 1, 1)
      to.setDate(to.getDate() + 7)
    }
    rangeMin = from.toISOString()
    rangeMax = to.toISOString()

    if (calendarIds.length === 0) {
      listProc.running = true
      watchdog.restart()
    } else {
      startEvents()
    }
  }

  function startEvents() {
    queue = calendarIds.slice()
    accum = []
    nextCalendar()
  }

  function nextCalendar() {
    if (queue.length === 0) {
      commit()
      return
    }
    var id = queue[0]
    queue = queue.slice(1)
    eventsProc.out = ""
    eventsProc.err = ""
    eventsProc.command = ["/usr/bin/gws", "calendar", "events", "list", "--params",
      JSON.stringify({
        calendarId: id,
        timeMin: rangeMin,
        timeMax: rangeMax,
        singleEvents: true,
        orderBy: "startTime",
        maxResults: 250
      })]
    eventsProc.running = true
    watchdog.restart()
  }

  function fail(message) {
    watchdog.stop()
    listProc.running = false
    eventsProc.running = false
    busy = false
    errorText = message
    state = "error"
    afterFetch()
  }

  // Whichever kind of run was asked for while this one was in flight goes
  // next. The grid wins when both are waiting -- someone is looking at it.
  function afterFetch() {
    if (wantPending) {
      wantPending = false
      beginFetch(wantedYear, wantedMonth)
      return
    }
    if (wantUpcoming) {
      wantUpcoming = false
      startRun("upcoming", pendingYear, pendingMonth)
    }
  }

  // ------------------------------------------------------------- calendars
  function ingestCalendars(text) {
    var data = JSON.parse(text)
    var items = data.items || []
    var ids = []
    for (var i = 0; i < items.length; i++) {
      var c = items[i]
      // `selected` is Google Calendar's own left-hand-side checkbox. Honouring
      // it means the popover shows exactly the calendars the web UI shows.
      if (c.selected === false) continue
      ids.push(c.id)
    }
    calendarIds = ids
  }

  // ---------------------------------------------------------------- events
  // "2026-08-25" -> a LOCAL midnight Date. `new Date("2026-08-25")` parses as
  // UTC midnight, which lands on the 24th anywhere west of Greenwich.
  function parseDateOnly(s) {
    var p = String(s).split("-")
    return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
  }

  // Everything below reaches an exec call eventually, and it is remote data.
  // Only these schemes are ever handed to xdg-open; anything else -- javascript:,
  // file:, a mailto:, a bare string -- becomes "" and the UI then offers no
  // action at all rather than a button that does something unexpected.
  function safeUrl(u) {
    var s = String(u === undefined || u === null ? "" : u)
    if (/^https?:\/\//i.test(s)) return s
    // The two desktop conferencing schemes Google actually emits as entry points.
    if (/^(zoommtg|msteams):\/\//i.test(s)) return s
    return ""
  }

  // conferenceData.entryPoints[] is the current field and carries video/phone/
  // more variants; hangoutLink is the legacy Meet-only one. Prefer the video
  // entry point, fall back to hangoutLink. Verified against this account: Meet
  // events carry BOTH, so either alone would work, but a Zoom event added by
  // someone else would only have conferenceData.
  function meetingUrl(e) {
    var points = e.conferenceData && e.conferenceData.entryPoints ? e.conferenceData.entryPoints : []
    for (var i = 0; i < points.length; i++) {
      if (points[i].entryPointType !== "video") continue
      var u = safeUrl(points[i].uri)
      if (u !== "") return u
    }
    return safeUrl(e.hangoutLink)
  }

  function normalise(items, calendarIndex) {
    var out = []
    for (var i = 0; i < items.length; i++) {
      var e = items[i]
      if (e.status === "cancelled") continue

      // Google auto-creates a "working location" entry -- "Home", "Office" --
      // as an all-day item on most weekdays. The user never scheduled it, and
      // it pushes the real events down the list. Filtered by eventType, NOT by
      // the title: a meeting someone genuinely named "Home" must still show.
      //
      // outOfOffice and focusTime are kept. Both are blocks the user put on
      // the calendar deliberately, and both are worth seeing on the day.
      if (e.eventType === "workingLocation") continue

      var allDay = e.start && e.start.date !== undefined
      var start, end
      if (allDay) {
        start = parseDateOnly(e.start.date)
        // Google's all-day `end.date` is EXCLUSIVE: a single-day event on the
        // 25th ends on the 26th.
        end = e.end && e.end.date ? parseDateOnly(e.end.date) : new Date(start.getTime() + 86400000)
      } else {
        if (!e.start || !e.start.dateTime) continue
        start = new Date(e.start.dateTime)
        end = e.end && e.end.dateTime ? new Date(e.end.dateTime) : new Date(start.getTime() + 3600000)
      }

      out.push({
        summary: e.summary ? String(e.summary) : "(no title)",
        location: e.location ? String(e.location) : "",
        allDay: allDay,
        start: start,
        end: end,
        calendar: calendarIndex,
        // The event's page in Google Calendar. Present on every event this
        // account returns, but sanitised anyway -- an empty string means the
        // row is simply not clickable.
        link: safeUrl(e.htmlLink),
        meeting: meetingUrl(e),
        // For CalendarReminders. `id` alone is not a stable identity: a
        // recurring event repeats it for every occurrence (Google appends the
        // occurrence to the id for some series but not all), so the reminder
        // key pairs it with the occurrence's own start time.
        id: e.id ? String(e.id) : "",
        startIso: allDay ? String(e.start.date) : String(e.start.dateTime),
        // { useDefault: true } or { overrides: [{method, minutes}] }.
        reminders: e.reminders || null
      })
    }
    return out
  }

  function commit() {
    watchdog.stop()

    if (mode === "upcoming") {
      commitUpcoming()
      return
    }

    var byDay = {}
    function push(key, ev) {
      if (byDay[key] === undefined) byDay[key] = []
      byDay[key].push(ev)
    }

    for (var i = 0; i < accum.length; i++) {
      var ev = accum[i]
      if (ev.allDay) {
        // A multi-day event has to appear on every day it covers, not only on
        // the day it starts.
        var cursor = new Date(ev.start.getTime())
        var guard = 0
        while (cursor < ev.end && guard < 400) {
          push(dayKey(cursor), ev)
          cursor.setDate(cursor.getDate() + 1)
          guard++
        }
      } else {
        push(dayKey(ev.start), ev)
      }
    }

    // All-day first, then timed by start -- the order Google Calendar uses.
    for (var key in byDay) {
      byDay[key].sort(function (a, b) {
        if (a.allDay !== b.allDay) return a.allDay ? -1 : 1
        if (a.allDay) return a.summary.localeCompare(b.summary)
        return a.start.getTime() - b.start.getTime()
      })
    }

    eventsByDay = byDay
    loadedKey = monthKey(pendingYear, pendingMonth)
    state = "ok"
    errorText = ""
    busy = false
    afterFetch()
  }

  // An upcoming run must NOT touch eventsByDay or loadedKey -- it covers a
  // rolling 37-hour window, not the month the popover is showing, and marking
  // that month loaded would leave the grid displaying two days of events.
  function commitUpcoming() {
    var out = []
    for (var i = 0; i < accum.length; i++) {
      // All-day entries have no time to remind about.
      if (!accum[i].allDay) out.push(accum[i])
    }
    out.sort(function (a, b) { return a.start.getTime() - b.start.getTime() })

    upcoming = out
    state = "ok"
    errorText = ""
    busy = false
    afterFetch()
  }

  // -------------------------------------------------------------- processes
  Process {
    id: listProc
    command: ["/usr/bin/gws", "calendar", "calendarList", "list", "--params", '{"minAccessRole":"reader"}']

    property string out: ""
    property string err: ""

    stdout: StdioCollector { onStreamFinished: listProc.out = String(this.text) }
    stderr: StdioCollector { onStreamFinished: listProc.err = String(this.text) }

    onExited: function (exitCode) {
      var text = listProc.out
      var err = listProc.err
      listProc.out = ""
      listProc.err = ""
      if (!root.busy) return

      if (exitCode !== 0) {
        root.fail(root.firstLine(err) || ("gws calendarList exited " + exitCode))
        return
      }
      try {
        root.ingestCalendars(text)
      } catch (e) {
        root.fail("Could not read the calendar list")
        return
      }
      if (root.calendarIds.length === 0) {
        root.fail("No calendars are selected in Google Calendar")
        return
      }
      root.startEvents()
    }
  }

  Process {
    id: eventsProc

    property string out: ""
    property string err: ""

    stdout: StdioCollector { onStreamFinished: eventsProc.out = String(this.text) }
    stderr: StdioCollector { onStreamFinished: eventsProc.err = String(this.text) }

    onExited: function (exitCode) {
      var text = eventsProc.out
      var err = eventsProc.err
      eventsProc.out = ""
      eventsProc.err = ""
      if (!root.busy) return

      if (exitCode !== 0) {
        root.fail(root.firstLine(err) || ("gws events exited " + exitCode))
        return
      }
      try {
        var data = JSON.parse(text)
        // What `reminders: { useDefault: true }` on an event refers to. It
        // rides along on this same response, so honouring the calendar's
        // default costs no extra call. The primary calendar is fetched first,
        // and its default is the one that matters.
        if (data.defaultReminders && root.defaultReminders.length === 0) {
          root.defaultReminders = data.defaultReminders
        }
        // The calendar this batch belongs to is the one just shifted off the
        // queue, i.e. the last id consumed.
        var index = root.calendarIds.length - root.queue.length - 1
        root.accum = root.accum.concat(root.normalise(data.items || [], index))
      } catch (e) {
        root.fail("Could not read the event list")
        return
      }
      root.nextCalendar()
    }
  }

  // gws reports failures over several stderr lines and the first one is the
  // useful part; the keyring notice it always prints is not an error.
  function firstLine(s) {
    var lines = String(s || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i].trim()
      if (l === "" || l.indexOf("Using keyring backend") === 0) continue
      return l.length > 120 ? l.substring(0, 117) + "..." : l
    }
    return ""
  }

  // A network that is up but not answering would otherwise leave the popover
  // on "Loading..." forever.
  Timer {
    id: watchdog
    interval: 20000
    onTriggered: root.fail("gws did not answer in time")
  }

  Timer {
    interval: 15 * 60 * 1000
    repeat: true
    // Only after the user has actually opened the popover once.
    running: root.everOpened
    onTriggered: root.ensure(root.pendingYear, root.pendingMonth, true)
  }
}
