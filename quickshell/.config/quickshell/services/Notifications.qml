import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import "root:/"

// The notification daemon: org.freedesktop.Notifications, in place of swaync.
//
// This file is the *store*. It owns the DBus server, the notification list,
// the per-notification expiry clock, Do Not Disturb and the control-center
// state; the three view files next to it (NotificationPopups, NotificationCenter,
// NotificationGroup -> NotificationCard) render it and call back into it. One
// mount line in shell.qml constructs the whole thing:
//
//     Notifications { }
//
// ---------------------------------------------------------------- parity
// Every rule below was checked against the running swaync on this machine
// (screenshots of the live popups with grim, `swaync-client -c` for the
// control-center count), not read off the config file, because several of
// swaync's rules are not in the config at all:
//
//   * a client-supplied expire timeout WINS over the config default --
//     `notify-send -t 2000` vanished at 2s under `"timeout": 10`.
//   * timing out and closing are different fates. swaync-client spells it
//     out: "--hide-latest  Hides latest notification. Still shown in Control
//     Center" vs "--close-latest  Closes latest notification". Counted: hiding
//     took the count 7 -> 8, closing left it where it was. So an expired popup
//     keeps its DBus notification alive and merely stops being a popup; only a
//     real close sends NotificationClosed.
//   * transient notifications are never stored -- the count did not move for
//     `notify-send -h boolean:transient:true`.
//   * Do Not Disturb suppresses normal popups but NOT critical ones -- with
//     dnd on, a `-u critical` popup still drew and a normal one did not.
//   * no popups at all while the control center is open; the notification
//     lands directly in the panel list.
//   * newest popup on top, pushing the older ones down.
//   * the 2FA action regex is swaync's own, lifted out of the binary:
//     (?<= |^)(\d{3}(-| )\d{3}|\d{4,8})(?= |$|\.|,)   -- rendered as COPY "…".
//
// config.json is mirrored in the `-- config` block below, key by key.
//
// ----------------------------------------------------------------- motion
// swaync's whole animation vocabulary is `transition-time: 200`, a fade. The
// motion here lives in the views (a card slides in from the edge it came from
// and collapses its own height on the way out, so the stack closes the gap in
// the same beat). The store's part of that contract is to never remove a row
// from under a running animation: close() marks the row as *leaving*, the card
// plays its exit and calls back into dropPopup()/dropHistory(), and only then
// does the DBus notification actually get dismissed.
//
// The one exception is a notification closed by its own sender (or by
// NotificationAction.invoke(), which dismisses non-resident notifications
// itself): that destroys the Notification object immediately, so the row has
// to go immediately too -- a card left animating over a dead QObject would
// spew binding errors. Those rows snap; everything the user does snaps back.
Scope {
  id: root

  // ------------------------------------------------------------- config
  // ~/.dotfiles/swaync/.config/swaync/config.json, one property per key.
  readonly property int popupWidth: 400        // notification-window-width
  readonly property int centerWidth: 400       // control-center-width
  // control-center-width is not what swaync's panel ends up being: it sizes
  // the panel around its list, so the running control center measures 427px
  // wide (border to border, 20px off the right edge) with a 316px card
  // centred in it -- 53px of gutter on each side. Measured off the live panel
  // rather than derived, because no arithmetic on the config gets there.
  readonly property int centerPanelWidth: 427
  readonly property int centerCardWidth: 316
  readonly property int timeoutNormal: 10      // timeout
  readonly property int timeoutLow: 5          // timeout-low
  readonly property int timeoutCritical: 0     // timeout-critical (0 = never)
  readonly property bool hideOnAction: true    // hide-on-action
  readonly property bool hideOnClear: false    // hide-on-clear
  readonly property bool twoFactorAction: true // notification-2fa-action
  readonly property bool inlineReplies: false  // notification-inline-replies
  readonly property string textEmpty: "No Notifications"

  // ------------------------------------------------------------- state
  // Both lists are newest-first. The same entry object is shared between them
  // and `byKey`, so a card's identity survives every rebuild of the arrays.
  property var history: []
  property var popups: []
  // Keys whose card is playing its exit animation. The card is still in the
  // list above until it reports back.
  property var popupLeaving: []
  property var historyLeaving: []

  property bool dnd: false
  property bool centerOpen: false
  // App names whose control-center stack is unfolded.
  property var expandedGroups: []

  // One clock for every relative timestamp on screen, ticking only while the
  // panel that shows them is open.
  property double clockTick: Date.now()

  // key -> entry, including entries mid-exit that are no longer in any list.
  property var byKey: ({})

  readonly property int count: history.length

  // Repeater models. ScriptModel diffs by `key`, so a new arrival is an insert
  // rather than a rebuild: no sibling card restarts its entrance animation.
  readonly property var popupModel: popupScript
  readonly property var groupModel: groupScript

  // App names in first-seen-newest order -- the control center's group order.
  readonly property var groupOrder: {
    var seen = ({})
    var out = []
    for (var i = 0; i < history.length; i++) {
      var app = history[i].app
      if (!seen[app]) {
        seen[app] = true
        out.push(app)
      }
    }
    return out
  }

  ScriptModel {
    id: popupScript
    values: root.popups
    objectProp: "key"
  }

  ScriptModel {
    id: groupScript
    values: root.groupOrder
  }

  // -------------------------------------------------------------- server
  NotificationServer {
    id: server

    // Capabilities swaync advertises. "persistence" is the one that tells
    // clients the notification survives its popup -- which it does, in the
    // control center.
    keepOnReload: true
    persistenceSupported: true
    bodySupported: true
    bodyMarkupSupported: true
    bodyHyperlinksSupported: true
    bodyImagesSupported: true
    imageSupported: true
    actionsSupported: true
    actionIconsSupported: false
    inlineReplySupported: root.inlineReplies

    onNotification: function (notification) {
      notification.tracked = true
      root.ingest(notification)
    }
  }

  // ------------------------------------------------------------- ingest
  function ingest(notification) {
    var entry = root.entryFor(notification)
    var fresh = !entry

    if (fresh) {
      entry = {
        key: "n" + notification.id,
        notif: notification,
        app: notification.appName !== "" ? notification.appName : "Notification",
        time: Date.now(),
        code: root.twoFactorAction ? root.findCode(notification.body) : "",
        deadline: 0,
        closeOnDrop: false
      }
      root.byKey[entry.key] = entry
      // The sender (or invoke()) may close this at any time; when it does the
      // QObject dies, so the row has to leave with it.
      notification.closed.connect(function () { root.forget(entry.key) })
    } else {
      // A replacement (same id) reuses the object: it re-enters the top of
      // both lists with a new timestamp, the way a new notification would.
      entry.time = Date.now()
      entry.code = root.twoFactorAction ? root.findCode(notification.body) : ""
    }

    // "image-visibility" and the rest are the card's business; the store only
    // decides where the notification goes.
    if (!notification.transient) root.pushHistory(entry)

    // A notification carried over a config reload is already old news: it goes
    // back in the panel, it does not pop up again.
    var carried = fresh && notification.lastGeneration

    // TRIAGE. Do Not Disturb used to be the only reason a normal notification
    // was held back, and holding it back was all that happened -- the card
    // never drew and nothing anywhere said one had arrived. Triage.qml widens
    // the test to three signals the desktop already maintains (dnd, a
    // fullscreen window, an idle session) and, more to the point, COUNTS what
    // it holds so the bar can say so.
    //
    // Behaviour for the dnd case is unchanged, including the exemption:
    // `Triage.shouldHold()` covers `root.dnd`, and Critical is excluded here
    // exactly as it was in the expression this replaces. What is new is the
    // other two signals, and `note()`.
    //
    // Not while the centre is open: the user is looking at the list, so there
    // is nothing to catch them up on.
    var held = !carried && !root.centerOpen
      && notification.urgency !== NotificationUrgency.Critical
      && Triage.shouldHold()
    if (held) Triage.note(entry.key)

    var suppressed = root.centerOpen || carried || held

    if (!suppressed) {
      var ms = root.timeoutFor(notification)
      entry.deadline = ms > 0 ? Date.now() + ms : 0
      root.pushPopup(entry)
    }
  }

  // swaync honours the client's expire timeout when it sets one and falls back
  // to the per-urgency config value otherwise.
  //
  // Quickshell hands the wire value through unchanged, so this is the spec's
  // expire_timeout: MILLISECONDS, -1 for "the server decides", 0 for "never".
  // Measured, not assumed: `notify-send -t 3000` arrives here as 3000, and an
  // earlier build that read it as seconds left the popup up for 50 minutes.
  function timeoutFor(notification) {
    var t = notification.expireTimeout
    if (t > 0) return t
    if (t === 0) return 0

    var secs = notification.urgency === NotificationUrgency.Critical ? root.timeoutCritical
      : notification.urgency === NotificationUrgency.Low ? root.timeoutLow
      : root.timeoutNormal
    return secs * 1000
  }

  // swaync's own 2FA pattern, minus the lookbehind (Qt's JS engine has no
  // lookbehind): a 6-digit code written as 3-3, or a bare 4-8 digit run, both
  // standing alone as a word. Markup is stripped first -- bodies arrive as
  // Pango markup because the server advertises body-markup.
  function findCode(body) {
    if (!body) return ""
    var plain = body.replace(/<[^>]*>/g, " ")
    var m = /(?:^|\s)(\d{3}(?:-| )\d{3}|\d{4,8})(?=$|[\s.,])/.exec(plain)
    if (!m) return ""
    // Strip the separator. A code shown as "481-923" must be copied as
    // "481923" -- pasting the dashed form into a 6-box OTP field fails, and
    // that is the entire point of the action. swaync strips it too.
    return m[1].replace(/[^0-9]/g, "")
  }

  // ------------------------------------------------------------- lists
  function pushHistory(entry) {
    root.historyLeaving = root.withoutKey(root.historyLeaving, entry.key)
    root.history = [entry].concat(root.dropKey(root.history, entry.key))
  }

  function pushPopup(entry) {
    root.popupLeaving = root.withoutKey(root.popupLeaving, entry.key)
    root.popups = [entry].concat(root.dropKey(root.popups, entry.key))
    root.reschedule()
  }

  function dropKey(list, key) {
    return list.filter(function (e) { return e.key !== key })
  }

  function withoutKey(keys, key) {
    return keys.filter(function (k) { return k !== key })
  }

  function hasKey(list, key) {
    for (var i = 0; i < list.length; i++) if (list[i].key === key) return true
    return false
  }

  function entryFor(notification) {
    for (var key in root.byKey) if (root.byKey[key].notif === notification) return root.byKey[key]
    return null
  }

  function entriesForApp(app) {
    return root.history.filter(function (e) { return e.app === app })
  }

  // ------------------------------------------------------------- expiry
  // One timer for the whole stack, armed for the next deadline rather than
  // ticking: nothing here polls.
  Timer {
    id: expiry
    repeat: false
    onTriggered: {
      var now = Date.now()
      for (var i = 0; i < root.popups.length; i++) {
        var e = root.popups[i]
        // 10ms of slack so a deadline that lands a hair early is not deferred
        // into a second timer round.
        if (e.deadline > 0 && e.deadline <= now + 10) root.hidePopup(e.key)
      }
      root.reschedule()
    }
  }

  function reschedule() {
    var next = -1
    for (var i = 0; i < root.popups.length; i++) {
      var e = root.popups[i]
      if (e.deadline <= 0 || root.popupLeaving.indexOf(e.key) >= 0) continue
      if (next < 0 || e.deadline < next) next = e.deadline
    }

    if (next < 0) {
      expiry.stop()
      return
    }
    expiry.interval = Math.max(20, next - Date.now())
    expiry.restart()
  }

  // ------------------------------------------------------------ removal
  // "Hide": the popup goes, the notification stays in the control center.
  function hidePopup(key) {
    if (!root.hasKey(root.popups, key)) return
    if (root.popupLeaving.indexOf(key) < 0) root.popupLeaving = root.popupLeaving.concat([key])
    sweep.restart()
  }

  function hideHistory(key) {
    if (!root.hasKey(root.history, key)) return
    if (root.historyLeaving.indexOf(key) < 0) root.historyLeaving = root.historyLeaving.concat([key])
    sweep.restart()
  }

  // A row is normally dropped by its own card, once the exit animation has
  // played. A card that is not on screen never animates -- an unmapped window
  // gets no frames -- so a notification closed while the control center is
  // shut would otherwise sit in `historyLeaving` forever and never reach
  // dismiss(). This is the backstop: well past any exit (the longest is
  // Style.anim.reveal, 240ms), anything still marked as leaving is dropped
  // outright.
  Timer {
    id: sweep
    interval: 600
    repeat: false
    onTriggered: {
      var stale = root.popupLeaving.slice()
      for (var i = 0; i < stale.length; i++) root.dropPopup(stale[i])
      stale = root.historyLeaving.slice()
      for (var j = 0; j < stale.length; j++) root.dropHistory(stale[j])
    }
  }

  // "Close": the notification is gone for good and its sender is told so.
  function close(entry) {
    if (!entry) return
    entry.closeOnDrop = true

    var shown = false
    if (root.hasKey(root.popups, entry.key)) { root.hidePopup(entry.key); shown = true }
    if (root.hasKey(root.history, entry.key)) { root.hideHistory(entry.key); shown = true }
    // Nothing is drawing it, so there is no exit animation to wait for.
    if (!shown) root.finalize(entry.key)
    else root.reschedule()
  }

  // Called by a card once its exit animation has finished.
  function dropPopup(key) {
    root.popups = root.dropKey(root.popups, key)
    root.popupLeaving = root.withoutKey(root.popupLeaving, key)
    root.finalize(key)
    root.reschedule()
  }

  function dropHistory(key) {
    root.history = root.dropKey(root.history, key)
    root.historyLeaving = root.withoutKey(root.historyLeaving, key)
    root.finalize(key)
  }

  // The last view let go of the row: now, and only now, does the DBus side of
  // it end.
  function finalize(key) {
    var entry = root.byKey[key]
    if (!entry) return
    if (root.hasKey(root.popups, key) || root.hasKey(root.history, key)) return

    delete root.byKey[key]
    if (!entry.notif) return
    // Dismissed vs Expired: a popup that simply ran out of time on a transient
    // notification expired; anything the user closed was dismissed.
    if (entry.closeOnDrop) entry.notif.dismiss()
    else entry.notif.expire()
  }

  // The sender closed it (or invoke() did). The QObject is being destroyed, so
  // the row cannot wait for an animation.
  function forget(key) {
    if (!root.byKey[key]) return
    delete root.byKey[key]
    root.popups = root.dropKey(root.popups, key)
    root.history = root.dropKey(root.history, key)
    root.popupLeaving = root.withoutKey(root.popupLeaving, key)
    root.historyLeaving = root.withoutKey(root.historyLeaving, key)
    root.reschedule()
  }

  // ------------------------------------------------------------ actions
  // swaync(1): "Left click notification: Activate notification action". With
  // no default action to fire, the click just closes the row.
  function activateDefault(entry) {
    if (!entry || !entry.notif) return

    var actions = entry.notif.actions
    for (var i = 0; i < actions.length; i++) {
      if (actions[i].identifier === "default") {
        root.runAction(entry, actions[i])
        return
      }
    }
    root.close(entry)
  }

  // index >= 0 indexes notif.actions; -1 is the synthetic 2FA copy action the
  // card appends when the store found a code in the body.
  function invokeAction(entry, index) {
    if (!entry || !entry.notif) return

    if (index === -1) {
      if (entry.code !== "") {
        // `printf %s "$1" | wl-copy`, with the value kept out of the shell's
        // word splitting.
        Quickshell.execDetached(["sh", "-c", "printf %s \"$1\" | wl-copy", "sh", entry.code])
      }
      if (root.hideOnAction) root.closeCenter()
      root.close(entry)
      return
    }

    var actions = entry.notif.actions
    if (index < 0 || index >= actions.length) return
    root.runAction(entry, actions[index])
  }

  // The card's own numbering: the buttons it draws, in the order it draws
  // them (every action except "default", then the copy action). This is what
  // the control center's 1-9 keys address.
  function invokeActionAt(entry, position) {
    if (!entry || !entry.notif) return

    var actions = entry.notif.actions
    var visible = []
    for (var i = 0; i < actions.length; i++) {
      if (actions[i].identifier !== "default") visible.push(i)
    }
    if (entry.code !== "") visible.push(-1)
    if (position < 0 || position >= visible.length) return
    root.invokeAction(entry, visible[position])
  }

  function runAction(entry, action) {
    // Read `resident` before invoking: NotificationAction.invoke() dismisses a
    // non-resident notification itself, which destroys the object.
    var resident = entry.notif.resident

    // "hide-on-action": true
    if (root.hideOnAction) root.closeCenter()

    action.invoke()

    if (resident) return
    // If invoke() did the dismissing, closed() already took the row out of
    // byKey and there is nothing left to do. If it did not, close it here.
    if (root.byKey[entry.key]) root.close(entry)
  }

  function openLink(link) {
    if (!link) return
    Quickshell.execDetached(["xdg-open", link])
  }

  // ------------------------------------------------------------- groups
  function toggleGroup(app) {
    root.expandedGroups = root.expandedGroups.indexOf(app) >= 0
      ? root.withoutKey(root.expandedGroups, app)
      : root.expandedGroups.concat([app])
  }

  function closeGroup(app) {
    var entries = root.entriesForApp(app)
    for (var i = 0; i < entries.length; i++) root.close(entries[i])
    root.expandedGroups = root.withoutKey(root.expandedGroups, app)
  }

  // The rows the control center can walk with the arrow keys: a collapsed
  // stack is one row, an expanded one is all of them.
  function navigableEntries() {
    var out = []
    var groups = root.groupOrder
    for (var i = 0; i < groups.length; i++) {
      var entries = root.entriesForApp(groups[i])
      if (entries.length > 1 && root.expandedGroups.indexOf(groups[i]) < 0) out.push(entries[0])
      else out = out.concat(entries)
    }
    return out
  }

  // ------------------------------------------------------------- panel
  function openCenter() {
    if (root.centerOpen) return
    root.centerOpen = true
    root.clockTick = Date.now()
    // The batch has been seen. This is the ONLY thing that clears it -- not a
    // timeout, and not heads-down ending, because a digest that expired before
    // it was read would be the black hole it exists to close.
    Triage.release()
    // swaync shows no popups while its panel is up; the panel is the list now.
    root.hideAllPopups()
  }

  function closeCenter() {
    if (!root.centerOpen) return
    root.centerOpen = false
    root.expandedGroups = []
  }

  function toggleCenter() {
    if (root.centerOpen) root.closeCenter()
    else root.openCenter()
  }

  function toggleDnd() {
    root.dnd = !root.dnd
    return root.dnd
  }

  // "hide-on-clear": false -- the panel stays up.
  function clearAll() {
    var entries = root.history.slice()
    for (var i = 0; i < entries.length; i++) root.close(entries[i])
    var live = root.popups.slice()
    for (var j = 0; j < live.length; j++) root.close(live[j])
    root.expandedGroups = []
  }

  function hideAllPopups() {
    for (var i = 0; i < root.popups.length; i++) root.hidePopup(root.popups[i].key)
    root.reschedule()
  }

  // Relative timestamps only exist inside the control center, so the clock
  // that drives them only runs while it is open.
  Timer {
    interval: 15000
    repeat: true
    running: root.centerOpen
    onTriggered: root.clockTick = Date.now()
  }

  // --------------------------------------------------------------- views
  NotificationPopups { store: root }
  NotificationCenter { store: root }

  // --------------------------------------------------------------- triage
  // Pushed rather than pulled: Triage is a singleton and this store is a
  // component, so the singleton cannot reach in here -- and it deliberately
  // keeps no notifications of its own, deriving its whole digest from the
  // `history` handed over on this line. One direction, one copy of the truth.
  Component.onCompleted: Triage.store = root

  // ----------------------------------------------------------------- ipc
  // The swaync-client surface, so muscle memory and existing scripts port
  // across one flag at a time:
  //
  //   swaync-client -t            ->  qs ipc call notifications toggle
  //   swaync-client -op / -cp     ->  ... open | close
  //   swaync-client -d / -dn/-df  ->  ... dnd | dndOn | dndOff
  //   swaync-client -c            ->  ... count
  //   swaync-client -C            ->  ... closeAll
  //   swaync-client --close-latest->  ... closeLatest
  //   swaync-client --hide-latest ->  ... hideLatest
  //   swaync-client --hide-all    ->  ... hideAll
  //
  // (~/.local/bin/power-profile-cycle still calls `swaync-client
  // --close-latest`; it needs the second line swapped in when swaync goes.)
  IpcHandler {
    target: "notifications"

    function toggle(): string {
      root.toggleCenter()
      return root.centerOpen ? "opened" : "closed"
    }

    function open(): string {
      root.openCenter()
      return "opened"
    }

    function close(): string {
      root.closeCenter()
      return "closed"
    }

    function dnd(): string {
      return root.toggleDnd() ? "true" : "false"
    }

    function dndOn(): string {
      root.dnd = true
      return "true"
    }

    function dndOff(): string {
      root.dnd = false
      return "false"
    }

    function getDnd(): string {
      return root.dnd ? "true" : "false"
    }

    function count(): string {
      return "" + root.history.length
    }

    function closeAll(): string {
      var n = root.history.length
      root.clearAll()
      // The rows are still playing their exit, so this reports what was closed
      // rather than what is left.
      return "" + n
    }

    function closeLatest(): string {
      var target = root.popups.length > 0 ? root.popups[0]
        : root.history.length > 0 ? root.history[0] : null
      if (target) root.close(target)
      return target ? target.key : "none"
    }

    function hideLatest(): string {
      if (root.popups.length === 0) return "none"
      var key = root.popups[0].key
      root.hidePopup(key)
      root.reschedule()
      return key
    }

    function hideAll(): string {
      root.hideAllPopups()
      return "hidden"
    }

    // ------------------------------------------------------------- triage
    // swaync had no equivalent, so these are not parity -- they are here
    // because Triage is a singleton and a singleton's own IpcHandler is never
    // registered (it has to hang off the object tree; that is why OriIpc.qml
    // exists for PiSession). This handler is already mounted, and triage is
    // notification state, so it belongs on this target rather than in a second
    // mount line in shell.qml.
    //
    //   qs ipc call notifications triage        one line, or "nothing held"
    //   qs ipc call notifications triageDetail  a row per app
    //   qs ipc call notifications triageState   why the batch is open
    function triage(): string {
      return Triage.held === 0 ? "nothing held" : Triage.oneLine
    }

    function triageDetail(): string {
      return Triage.held === 0 ? "nothing held" : Triage.detail
    }

    function triageState(): string {
      return "headsDown=" + (Triage.headsDown ? "true" : "false")
        + " reason=" + (Triage.reason === "" ? "-" : Triage.reason)
        + " immersed=" + (Triage.immersed ? "true" : "false")
        + " away=" + (Triage.away ? "true" : "false")
        + " quiet=" + (Triage.quiet ? "true" : "false")
        + " held=" + Triage.held
    }
  }
}
