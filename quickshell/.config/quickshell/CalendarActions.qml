pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// What happens when a calendar link is clicked. A singleton because two
// different surfaces open links -- the popover's event rows and the reminder
// popups -- and the routing must not be written twice.
//
// ------------------------------------------------------------------ routing
// Routed by HOST, not by which surface asked:
//
//   meet.google.com  ->  the user's Google Meet webapp, if it is installed
//   everything else  ->  the default browser
//
// The event page (htmlLink) is a calendar page, not a meeting, so it always
// takes the second path.
Singleton {
  id: root

  // ------------------------------------------------------------ the account
  // THE Google account every opened link is pinned to.
  //
  // The user is signed into more than one Google account in the browser. With
  // no hint Google picks whichever profile it feels like, which for a work
  // event usually means landing on "you do not have access to this".
  //
  // `authuser=<email>`, never the `/u/0/` path form: that index is per browser
  // session and shifts whenever the accounts are signed in in a different
  // order, so it silently starts pointing at a different person.
  //
  // Derived from `gws auth status`, whose JSON carries `user` -- that is the
  // account the events themselves were fetched as, so the link can never
  // disagree with the data on screen. CALENDAR_ACCOUNT is the fallback for
  // when that call fails; leave it unset and the hint is simply omitted --
  // openLink() already returns the bare URL when the account is empty.
  //
  // ONE account, deliberately: the personal calendar is out of scope for now.
  // When it is added, this stops being a shell-wide constant and becomes a
  // per-event field -- CalendarData already knows which calendar each event
  // came from, so the hint would ride along on the event.
  property string account: Quickshell.env("CALENDAR_ACCOUNT") || ""

  Process {
    id: whoami
    command: ["/usr/bin/gws", "auth", "status"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var u = JSON.parse(this.text).user
          if (u && String(u).indexOf("@") > 0) root.account = String(u)
        } catch (e) {
          // Keep the fallback. A missing hint means Google picks a profile,
          // which is exactly the behaviour this replaces -- not worse.
        }
      }
    }
  }

  // Add the account hint without mangling what is already there. htmlLink
  // arrives as `...?eid=...`, so this is usually an `&`; a fragment, if any,
  // has to stay at the END or the hint lands inside it and the URL 404s.
  //
  // Only Google's own properties understand authuser -- a Zoom or Teams link
  // is handed on exactly as it came.
  function withAccount(url) {
    if (root.account === "") return url
    if (!/^https?:\/\/([a-z0-9-]+\.)*google\.com(\/|$)/i.test(url)) return url
    if (/[?&]authuser=/i.test(url)) return url

    var base = url
    var fragment = ""
    var hash = url.indexOf("#")
    if (hash >= 0) {
      base = url.substring(0, hash)
      fragment = url.substring(hash)
    }
    var sep = base.indexOf("?") >= 0 ? "&" : "?"
    return base + sep + "authuser=" + encodeURIComponent(root.account) + fragment
  }

  // ------------------------------------------------------------ the webapp
  // The user runs Google Meet as a PWA rather than as a browser tab, and a
  // meeting opened in a normal tab is not what they want to click into.
  //
  // Their `webapp-install` script wrote ~/.local/share/applications/Google
  // Meet.desktop with `Exec=chromium --app=https://meet.google.com`. That
  // entry cannot be launched WITH a meeting URL -- it carries no %u/%U field
  // code, so it only ever opens the Meet home page -- but it is still the
  // right thing to look for, for two reasons:
  //
  //   * it names the browser, so nothing here hardcodes chromium; whatever
  //     the install script used is what gets launched, and
  //   * its presence is the test for "is the webapp installed at all". This
  //     config is shared with the lenovo, which has neither the PWA nor
  //     chromium. There, meetBrowser is "" and Join falls back to the browser.
  //
  // Matched on the Exec string rather than the entry's name: what matters is
  // that it is an app-mode launcher pointed at Meet, not what it is called.
  // (The other Meet-ish entry on this machine, a Chrome PWA launched by
  // --app-id, is correctly skipped -- it cannot take an arbitrary URL.)
  //
  // DesktopEntries scans LAZILY and finishes asynchronously; reading .values
  // inside this binding both starts the scan and re-runs the search when the
  // model fills. See AppLauncher.qml, which learned the same lesson.
  readonly property string meetBrowser: {
    var apps = DesktopEntries.applications.values
    for (var i = 0; i < apps.length; i++) {
      var ex = String(apps[i].execString || "")
      if (ex.indexOf("--app=") === -1) continue
      if (ex.indexOf("meet.google.com") === -1) continue
      var cmd = apps[i].command
      if (cmd && cmd.length > 0) return String(cmd[0])
    }
    return ""
  }

  readonly property bool meetWebappAvailable: meetBrowser !== ""

  // ---------------------------------------------------------------- opening
  // The default browser, through Qt.
  //
  // NOT xdg-open and NOT `gio open`: on this machine both hang forever and
  // open nothing (neither recognises Hyprland as a desktop). What does work is
  // org.freedesktop.portal.OpenURI -- verified by calling the portal by hand,
  // which opened Zen -- and Qt on Wayland routes openUrlExternally through
  // exactly that portal.
  function open(url) {
    var u = CalendarData.safeUrl(url)
    if (u === "") return
    Qt.openUrlExternally(withAccount(u))
  }

  // Join. Only a real https meet.google.com URL is ever substituted into
  // --app=; a Zoom or Teams link, or a non-video entry point, falls through to
  // the browser. Passed as separate argv elements with no shell anywhere in
  // the chain, so a URL off the network is never parsed by anything but the
  // browser itself.
  function openMeeting(url) {
    var u = CalendarData.safeUrl(url)
    if (u === "") return
    if (root.meetWebappAvailable && /^https:\/\/meet\.google\.com\//i.test(u)) {
      // Pinned too: the webapp's chromium profile has both accounts signed in
      // as well, so a bare meet link there asks which one to join as.
      Quickshell.execDetached([root.meetBrowser, "--app=" + withAccount(u)])
      return
    }
    open(u)
  }
}
