pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "assistant"

// How much of the Ollama Cloud allowance is spent.
//
// Every answer on this machine goes through that plan, and until now nothing on
// screen said how much of it was left -- the panel could show how full the
// CONTEXT was, which is a different thing that refills every `new_session`.
//
// ------------------------------------------------------- why not the extension
// pi has an ollama-usage extension and it was loaded here once (68a0cbf reverted
// it). It works, and it displays NOTHING in this panel: its output goes through
// `ui.setWidget`, which is pi's terminal UI, and there is no terminal here. Its
// value is as a WORKED EXAMPLE of the response, and the parsing decisions below
// are taken from it rather than re-derived.
//
// The one that matters: `usage` is a FRACTION of the allowance (0.011 = 1.1%),
// not a percentage and not a token count. That was verified there against
// request_count moving while usage stayed under 0.02, and again here -- 418
// weekly requests at usage 0.007.
//
// ----------------------------------------------------------------- the payload
// GET https://ollama.com/api/usage, bearer token. Undocumented but stable:
//
//   { "activity": { "cost": "0.00000", "period": {...}, "models": [] },
//     "limits": { "session": { "usage": 0.01,  "models": [{name, request_count}] },
//                 "weekly":  { "usage": 0.007, "models": [...] } } }
//
// `activity` is billed spend and is all zeroes on this plan -- nothing here reads
// it. Only `limits` is a live constraint, so only `limits` is parsed.
Singleton {
  id: root

  // The origin rather than the ollama.ncym.uk proxy that models.json points pi
  // at. Both were measured returning the identical body in 0.70s, so the proxy
  // buys a hop for nothing here: it fronts INFERENCE, and this is an account
  // readout that belongs to the account.
  readonly property string base: "https://ollama.com/api/usage"

  // Long enough that a burst of short turns is one request, short enough that
  // the number is never stale by the time you look at it. Same figure the
  // extension settled on. A local constant rather than a Style token because it
  // is not a duration anything on screen moves at -- Copy.qml's `settleMs` is
  // the precedent for a singleton owning its own timing.
  readonly property int throttleMs: 60 * 1000

  // QML's XMLHttpRequest has NO `timeout`. Measured: `typeof xhr.timeout` is
  // undefined, assigning it silently creates a plain JS property, `ontimeout`
  // never fires, and a request to an unroutable address was still open 20s
  // later with the handler never called. So the watchdog below is not
  // belt-and-braces, it is the only thing that ends a hung request. `abort()`
  // does resolve it -- verified: readyState 4, status 0, in the same tick.
  readonly property int watchdogMs: 8 * 1000

  // ----------------------------------------------------------------- readouts
  // null until a fetch has succeeded. Deliberately NOT 0: "we have not been
  // told" and "none of the allowance is spent" are different facts and a footer
  // that renders them the same way is lying about the second one.
  property var sessionUsage: null
  property var weeklyUsage: null

  // Last failure, "" when the last fetch worked. Kept for a caller that wants
  // to explain the dash; the footer itself does not print it, because a strip
  // you read while doing something else is not the place to shout about a
  // readout that is optional by construction.
  property string error: ""

  readonly property bool known: sessionUsage !== null || weeklyUsage !== null

  // -1 when unknown, for the same reason as above -- a consumer that reads
  // these without checking `known` gets a value it cannot mistake for zero.
  readonly property real sessionPercent: sessionUsage === null ? -1 : sessionUsage * 100
  readonly property real weeklyPercent: weeklyUsage === null ? -1 : weeklyUsage * 100

  // ---------------------------------------------------- one line, one number
  // The footer is a 24px strip already carrying the model name and the context
  // percentage. Both windows do not fit: at panelMeta in JetBrainsMono the
  // model is ~170px and the context cell ~125px of a 460px card, which leaves
  // room for one short cell, not two.
  //
  // So it shows the window NEARER ITS LIMIT, tagged with which one that is.
  // The two are fractions of their own separate allowances, which makes them
  // directly comparable as "how close am I to being stopped" -- the larger
  // fraction is the one that stops you first, and the other one is by
  // definition not the constraint yet. A tag of one character is what keeps
  // that from being a number with no referent.
  //
  // Session and weekly are genuinely different windows: the session limit is a
  // short rolling one that refills on its own, the weekly one does not come
  // back until the week rolls. Showing only the weekly would hide the limit
  // that actually interrupts a conversation; showing only the session would
  // hide the one that ends the day. Showing whichever is worse hides neither.
  readonly property real worstFraction:
    Math.max(sessionUsage === null ? -1 : sessionUsage,
             weeklyUsage === null ? -1 : weeklyUsage)
  readonly property string worstTag:
    (sessionUsage !== null && sessionUsage >= (weeklyUsage === null ? -1 : weeklyUsage))
      ? "s" : "w"

  // "s 1.0%" when known, "usage —" when not. Two different SHAPES, not two
  // different numbers -- an em dash cannot be misread as 0.0% at a glance the
  // way "0%" can, and the word survives to say what the dash is about.
  readonly property string label: known ? (worstTag + " " + pct(worstFraction)) : "usage —"

  // Dim until it matters, then the context gauge's own two colours at the same
  // two thresholds -- this cell sits directly under that gauge and there is no
  // reason for the panel to have two vocabularies for "getting full". Below
  // 70% it stays overlay0 like the rest of the strip: an ambient readout that
  // is coloured while everything is fine is just a light that is always on.
  readonly property color tint: !known ? Theme.overlay0
    : worstFraction < 0.7 ? Theme.overlay0
    : worstFraction < 0.9 ? Theme.yellow : Theme.red

  // A fraction as a percentage. Under a tenth of a percent "0.0%" reads as
  // broken and "<0.1%" reads as fine; the extension's call, kept.
  function pct(f) {
    if (f === null || f === undefined || f < 0) return "—"
    var p = f * 100
    if (p > 0 && p < 0.1) return "<0.1%"
    return (p < 10 ? p.toFixed(1) : Math.round(p)) + "%"
  }

  // --------------------------------------------------------------- the token
  // Two sources carry the same key. `Quickshell.env` is tried first because it
  // is the one the panel is PROVEN to reach: the running shell's /proc environ
  // has OLLAMA_API_KEY in it (Hyprland inherits it from the fish login that
  // sources conf.d/secrets.fish), and reading it costs no file IO and no async
  // round trip, so the first fetch can go out on the event that asked for it.
  //
  // The extension preferred pi's model registry and treated the env var as the
  // fallback. That order is right inside pi and wrong here: this shell is not
  // pi, has no registry, and must not depend on having been started from a
  // login shell at all. Hence the file below as the fallback -- it is where pi
  // itself reads the key from, so the two cannot disagree about which key is
  // current.
  property string key: Quickshell.env("OLLAMA_API_KEY") || ""

  // Loaded lazily: only when the env var is missing, or when the key it gave us
  // is REJECTED. A rotated key lands in models.json immediately and in this
  // process's environment only after a re-login, so a 401 on the env key is
  // exactly the case where the file is the newer of the two. Without this a
  // stale environment leaves the readout dead until the next logout.
  property bool keyFileTried: false
  function loadKeyFile() {
    if (keyFileTried) return
    keyFileTried = true
    keyFile.path = Quickshell.env("HOME") + "/.pi/agent/models.json"
  }

  FileView {
    id: keyFile
    path: ""
    printErrors: false
    onLoaded: {
      try {
        var k = JSON.parse(text()).providers.ollama.apiKey
        if (k) { root.key = String(k); root.fetch() }
      } catch (e) {
        root.error = "no key"
      }
    }
    onLoadFailed: root.error = "no key"
  }

  // ----------------------------------------------------------------- fetching
  // No polling (CLAUDE.md is explicit and calls it CRITICAL). The number moves
  // for exactly one reason -- a turn was spent against the plan -- and the panel
  // already announces that. So:
  //
  //   settled()          a turn just finished, so the number just changed.
  //   panelOpen -> true  the only place this is rendered just became visible;
  //                      it is also the moment a stale number is about to be
  //                      read, and the first moment anyone can care.
  //
  // The extension also hooked `session_switch`. Not carried over, and not by
  // omission: `limits.session` is OLLAMA's rolling rate-limit window, not pi's
  // conversation. Switching or forking a pi session changes nothing about it,
  // so hooking it would be a request that cannot change the answer.
  //
  // A cold start never waits on the network because nothing here runs at
  // construction: the shell can sit for hours with the panel shut and make zero
  // requests. The first one goes out when the panel is first opened, and it is
  // async -- the footer paints its dash immediately and swaps in the number when
  // it lands.
  property double lastFetch: 0
  property var inFlight: null
  property bool aborting: false

  function refresh(force) {
    if (!force && lastFetch > 0 && Date.now() - lastFetch < throttleMs) return
    // settled() can land while the panel-open fetch is still open.
    if (inFlight) return
    if (key === "") { loadKeyFile(); return }
    fetch()
  }

  function fetch() {
    if (inFlight || key === "") return
    var xhr = new XMLHttpRequest()
    root.inFlight = xhr
    root.aborting = false

    xhr.onreadystatechange = function () {
      // `status` THROWS "Invalid state" before DONE -- reading it at readyState
      // 1 is what produced the only error this file ever logged. Never touch it
      // outside this guard.
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      watchdog.stop()
      root.inFlight = null

      if (root.aborting) { root.error = "timed out"; return }

      // 0 is a connection that never happened (no DNS, no route). Named
      // separately from an HTTP error so the two are not one indistinguishable
      // "it broke".
      if (xhr.status === 0) { root.error = "offline"; return }
      if (xhr.status === 401) {
        root.error = "key rejected"
        // The env key is stale, or wrong. models.json is the newer of the two.
        if (!root.keyFileTried) root.loadKeyFile()
        return
      }
      if (xhr.status !== 200) { root.error = "HTTP " + xhr.status; return }

      try {
        var lim = JSON.parse(xhr.responseText).limits
        // Read through, not destructured: a plan that reports only one of the
        // two windows must leave the other unknown rather than take the whole
        // parse down with it.
        root.sessionUsage = lim && lim.session && typeof lim.session.usage === "number"
          ? lim.session.usage : null
        root.weeklyUsage = lim && lim.weekly && typeof lim.weekly.usage === "number"
          ? lim.weekly.usage : null
        root.error = root.known ? "" : "no limits"
        root.lastFetch = Date.now()
      } catch (e) {
        // A usage readout is never worth breaking anything else over. The last
        // good numbers stay on screen; only `error` moves.
        root.error = "bad response"
      }
    }

    xhr.open("GET", root.base)
    xhr.setRequestHeader("Authorization", "Bearer " + root.key)
    xhr.send()
    watchdog.restart()
  }

  // The only Timer in this file, and it is a watchdog on a request that has
  // already been sent, not a clock -- it exists solely because QML's XHR cannot
  // time itself out (see watchdogMs).
  Timer {
    id: watchdog
    interval: root.watchdogMs
    onTriggered: {
      if (!root.inFlight) return
      root.aborting = true
      root.inFlight.abort()
    }
  }

  Connections {
    target: OriClient
    function onSettled() { root.refresh(false) }
    function onPanelOpenChanged() { if (OriClient.panelOpen) root.refresh(false) }
  }

  // The open EVENT is not enough on its own, and this is not belt-and-braces.
  // A singleton is constructed on first reference, and the only thing that
  // references this one is the footer -- which does not exist until the panel
  // opens. So on the first open the sequence is: panelOpen goes true, the panel
  // builds, the footer reads Usage.label, and only THEN does this file exist to
  // hear about a change that is already over. Rendered exactly that way: a live
  // panel showing "usage —" with the network untouched.
  //
  // This is still not a fetch at startup -- it only fires if the panel is
  // already up at the moment this is built, which is precisely the case the
  // Connections above cannot see.
  Component.onCompleted: if (OriClient.panelOpen) refresh(false)
}
