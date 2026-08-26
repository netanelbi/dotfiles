pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Wayland

// Notification triage: hold the popups while you are heads-down, count what
// arrived, and have one line ready for when you look up.
//
// This file is POLICY ONLY. It stores no notifications, renders nothing, and
// owns no surface. services/Notifications.qml remains the store and the server;
// it asks this singleton one question per arrival (`shouldHold`) and reports
// the answer back (`note`). Everything below is derived from the store's own
// `history`, so the two can never disagree about what exists.
//
// ------------------------------------------------------------- the problem
// The shell has exactly two settings today, and both of them are bad on a
// working afternoon:
//
//   dnd off  every Slack ping draws a card over whatever you are doing.
//   dnd on   the cards stop and NOTHING says so. The count in the centre
//            moves, and the centre has no bar module and no keybind, so the
//            count is not on screen anywhere. Silence is indistinguishable
//            from nothing having happened.
//
// The second one is the worse failure, and it is the one nobody notices,
// because a black hole looks exactly like a quiet afternoon.
//
// ------------------------------------------------------------- heads-down
// Three signals, all of them already maintained by this process or by the
// compositor for their own reasons. NONE of them is a mode the user has to
// remember to turn on, which was the whole requirement:
//
//   IMMERSED  a fullscreen window is focused. A call, a game, a presentation,
//             a full-screen editor. ToplevelManager reports it over
//             wlr-foreign-toplevel; verified by toggling fullscreen on a live
//             window and watching the property flip both ways.
//   AWAY      ext-idle-notify-v1 says nobody has touched the machine for
//             `awayAfter`. Not "heads-down" so much as "not there" -- but the
//             behaviour wanted is identical, and coming back to the desk is
//             the single most reliable "look up" moment there is.
//   QUIET     Do Not Disturb. Already existed, already suppressed popups. What
//             is new is that it now COUNTS, which is the difference between a
//             switch and a black hole.
//
// All three are property bindings on APIs already linked into this process.
// Nothing polls, nothing spawns, and at rest this file costs one idle-notify
// object and two bindings (CLAUDE.md: event-based design is CRITICAL).
//
// ---------------------------------------------------- what is NOT heads-down
// An active screencast was the fourth candidate and it is deliberately absent.
// It is the case with the highest stakes -- a Slack DM drawn over a shared
// screen is a leak, not an interruption -- but tracking it means holding an
// xdg-desktop-portal ScreenCast session over D-Bus and knowing when it ENDS,
// and sharepicker/ only sees a cast begin. That is a lot of new machinery for
// a case that is already covered in practice: the window you share from is
// nearly always the fullscreen one. If it is ever wanted, SharePicker.qml is
// the hook, and this is the file that would grow a fourth `readonly property
// bool`.
//
// ------------------------------------------------------------- the carve-out
// CRITICAL urgency is NEVER held. The spec has a priority field, the store
// already honours it under dnd, and triage honours it identically -- a failing
// build and a dying battery go through all three signals untouched. Triage
// that swallows the one notification that mattered is worse than no triage.
//
// ------------------------------------------------- and where it comes back out
// Nowhere, by itself. Nothing here draws, fires, speaks or expires. The batch
// sits in `digest` until something ASKS for it: widgets/Inbox.qml puts the
// count in the bar's own strip and the detail in the shared tooltip, both of
// which the user pulls. That is the rule this desktop is built on, in their
// words -- "its on the main windows and it will bother me on other windows" --
// and a digest that announced itself would be the same fault wearing a
// different hat.
Singleton {
  id: root

  // ---------------------------------------------------------------- config
  // How long without input counts as away. Deliberately hypridle's own
  // screensaver timeout (hypridle.conf `timeout 150`), so the batch opens on
  // the same beat the screen gives up on you rather than at some second number
  // nothing else on this desktop uses.
  readonly property int awayAfter: 150

  // Below this, right-click does not offer to ask Ori. See `askPrompt`.
  readonly property int askFloor: 5
  // The most notifications handed to the model in one question, and the
  // longest each line may be. A chat app in a loop must not be able to spend
  // the whole context window on itself.
  readonly property int askMax: 40
  readonly property int askLineMax: 160

  // ----------------------------------------------------------------- store
  // services/Notifications.qml hands itself over on construction. Null in a
  // preview harness that mounts the bar without the store, and every read
  // below tolerates that.
  property var store: null

  // ------------------------------------------------------------ heads-down
  IdleMonitor {
    id: presence
    enabled: true
    // SECONDS, measured: an IdleMonitor with `timeout: 3` reported isIdle
    // three seconds in, not three milliseconds in.
    timeout: root.awayAfter
    // An idle inhibitor is a video playing or `stay-awake` held. Both mean the
    // user decided the machine is doing something on their behalf, which is
    // not the same as them having walked away from it.
    respectInhibitors: true
  }

  readonly property var focused: ToplevelManager.activeToplevel
  // Bound, never read once: activeToplevel is null for the first frames after
  // start and populates asynchronously (measured -- a Component.onCompleted
  // read of it returns null on a desktop with windows already open).
  readonly property bool immersed: root.focused !== null && root.focused.fullscreen
  readonly property bool away: presence.isIdle
  readonly property bool quiet: root.store !== null && root.store.dnd

  readonly property bool headsDown: root.immersed || root.away || root.quiet

  // Which of them is answering, for the tooltip. Ordered by how much the user
  // is likely to care: a switch they threw beats a state they fell into.
  readonly property string reason: root.quiet ? "do not disturb"
    : root.immersed ? "fullscreen"
    : root.away ? "away"
    : ""

  // ------------------------------------------------------------- the batch
  // Keys, not entries. The entry objects belong to the store and it rebuilds
  // its arrays constantly; holding references here would be a second copy of
  // the truth, and a stale one the first time a notification is closed from
  // the centre. A key is a name, and a name that no longer resolves is simply
  // dropped.
  property var heldKeys: []

  // Asked once per arrival by the store. No side effects: `note()` is the
  // half that records.
  function shouldHold() {
    return root.headsDown
  }

  function note(key) {
    if (root.heldKeys.indexOf(key) >= 0) return
    root.heldKeys = root.heldKeys.concat([key])
  }

  // The batch has been seen. Called when the centre opens -- which is the only
  // gesture that actually shows the user what the count was counting.
  function release() {
    if (root.heldKeys.length === 0) return
    root.heldKeys = []
  }

  // A held notification that is closed (from the centre, by its sender, or by
  // Clear All) leaves the store's history, and its key here is then a name for
  // nothing. Pruned on the store's own signal rather than on a timer.
  Connections {
    target: root.store
    ignoreUnknownSignals: true
    function onHistoryChanged() { root.prune() }
  }

  function prune() {
    if (root.heldKeys.length === 0 || !root.store) return
    var live = ({})
    var h = root.store.history
    for (var i = 0; i < h.length; i++) live[h[i].key] = true
    var kept = root.heldKeys.filter(function (k) { return live[k] === true })
    // Reassigned only when it actually shrank: `heldKeys` drives `digest`,
    // which drives the bar module's text, and rewriting it on every unrelated
    // history change would re-evaluate all three for nothing.
    if (kept.length !== root.heldKeys.length) root.heldKeys = kept
  }

  // ------------------------------------------------------------- the digest
  // Derived, every time, from the store's history filtered to the held keys.
  // History is newest-first, so the first hit for an app IS that app's latest
  // -- no sort, no timestamps compared.
  //
  //   [{ app: "Slack", count: 6, latest: "Dana: are you around?" }, ...]
  //
  // in first-seen-newest app order, which is the order the control centre
  // already stacks its groups in.
  readonly property var digest: {
    var keys = root.heldKeys
    if (keys.length === 0 || !root.store) return []

    var want = ({})
    for (var i = 0; i < keys.length; i++) want[keys[i]] = true

    var order = []
    var byApp = ({})
    var h = root.store.history
    for (var j = 0; j < h.length; j++) {
      var e = h[j]
      if (want[e.key] !== true) continue
      var g = byApp[e.app]
      if (!g) {
        g = { app: e.app, count: 0, latest: root.lineFor(e) }
        byApp[e.app] = g
        order.push(g)
      }
      g.count++
    }
    return order
  }

  readonly property int held: {
    var n = 0
    var d = root.digest
    for (var i = 0; i < d.length; i++) n += d[i].count
    return n
  }

  // BOTH halves, joined. Measured against real traffic on this machine rather
  // than assumed: a chat app puts the SENDER in `summary` and the message in
  // `body`, so a summary-only line reads "Slack -- Dana" and has thrown away
  // the only part that says whether Dana needs anything. A mail client puts
  // the count in `summary` and the account in `body`, and that pair is exactly
  // as useful together.
  //
  // Truncated, because the tooltip is a glance and one app with a long body
  // must not set the width of the whole list.
  //
  // Markup is stripped for the same reason the store strips it before hunting
  // a 2FA code: the server advertises body-markup, so bodies arrive as Pango
  // and a raw one would put `<b>` in the bar's tooltip.
  readonly property int lineMax: 72

  function lineFor(entry) {
    if (!entry || !entry.notif) return ""
    var n = entry.notif
    var s = root.plain(n.summary)
    var b = root.plain(n.body)
    var line = s === "" ? b : (b === "" ? s : s + " — " + b)
    return line.length > root.lineMax ? line.slice(0, root.lineMax - 1) + "…" : line
  }

  function plain(s) {
    return String(s || "").replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim()
  }

  // ----------------------------------------------------------- the one line
  // What the whole feature is for: fourteen popups, read back as one line.
  //
  //     11 held · Slack 6, Zen 3, Thunderbird 2
  readonly property string oneLine: {
    if (root.held === 0) return ""
    var d = root.digest
    var parts = []
    for (var i = 0; i < d.length; i++) parts.push(d[i].app + " " + d[i].count)
    return root.held + " held · " + parts.join(", ")
  }

  // The tooltip's version: one row per app, with the newest thing that app
  // said. This is the "instead of fourteen popups" surface, and it is a
  // tooltip -- Bar.qml's single shared popup, raised on a 400ms hover and
  // owned by the bar -- rather than anything new over a window.
  //
  // ONE LINE PER APP, not an app heading with its message indented under it:
  // that shared tooltip centres its text (Bar.qml sets AlignHCenter on the
  // one Text it draws), and a hanging indent centred on the page reads as
  // ragged rather than as a list.
  readonly property string detail: {
    if (root.held === 0) return ""
    var d = root.digest
    var lines = []
    for (var i = 0; i < d.length; i++) {
      var g = d[i]
      var head = g.app + (g.count > 1 ? " ×" + g.count : "")
      lines.push(g.latest === "" ? head : head + " — " + g.latest)
    }
    return lines.join("\n")
  }

  // ----------------------------------------------- when Ori is worth asking
  // NEVER automatically, and the reasons are not close.
  //
  //   THE TRANSCRIPT IS NOT A SCRATCHPAD. ori-agent is a single-child,
  //   single-conversation broker: every `prompt` frame goes into the ONE
  //   conversation the user is having. An automatic summary would append two
  //   turns to their transcript, be refused outright whenever they were
  //   mid-question (`ask()` returns false while busy), set `unread` and fill
  //   the bar's mark as though they had asked something, and spend context in
  //   the window whose percentage the panel footer displays. There is no side
  //   channel to do it quietly in, and adding one would mean a second ~200MB
  //   node process woken up to say "three messages from Dana".
  //
  //   THE ALLOWANCE IS FINITE AND VISIBLE. Usage.qml reads
  //   ollama.com/api/usage, where `usage` is a FRACTION of a weekly plan. A
  //   summary per batch is a background process quietly spending a number the
  //   user can watch going down. An assistant that eats its own allowance on
  //   chores is worse than one that stays quiet.
  //
  //   THE ANSWER IS ALREADY STRUCTURED, AND COUNTING CANNOT BE WRONG. A
  //   notification arrives with an app name, a summary and an urgency. "Slack
  //   6, Zen 3" is a `for` loop, it is instant, it is free, and it is never
  //   a hallucination. A model asked to compress the same six lines returns a
  //   paragraph that is HARDER to scan than the list it replaced.
  //
  // So the loop does the triage and the model is offered, once, as a gesture:
  // right-click the module. It goes through the ordinary `PiSession.ask()`, so
  // it is a normal turn in their own conversation, visibly costing what it
  // costs -- and the answer arrives the way every answer does, by the mark in
  // the bar filling, with nothing opening over anyone's work.
  //
  // Offered only past `askFloor`, because under half a dozen notifications the
  // tooltip is already faster to read than a model is to answer.
  readonly property bool worthAsking: root.held >= root.askFloor

  function askPrompt() {
    var keys = root.heldKeys
    if (keys.length === 0 || !root.store) return ""

    var want = ({})
    for (var i = 0; i < keys.length; i++) want[keys[i]] = true

    var lines = []
    var h = root.store.history
    // Oldest first: the batch reads as it happened, which is how anyone would
    // recount it. History is newest-first, so this walks it backwards.
    for (var j = h.length - 1; j >= 0 && lines.length < root.askMax; j--) {
      var e = h[j]
      if (want[e.key] !== true) continue
      var line = e.app + " — " + root.lineFor(e)
      if (line.length > root.askLineMax) line = line.slice(0, root.askLineMax - 1) + "…"
      lines.push(line)
    }
    if (lines.length === 0) return ""

    return "These desktop notifications arrived while I was heads-down ("
      + root.reason + "). Tell me in two or three lines what actually needs me "
      + "and what can wait. If none of it needs me, say that in one line.\n\n"
      + lines.join("\n")
  }
}
