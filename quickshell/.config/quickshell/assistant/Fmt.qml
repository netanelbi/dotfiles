import QtQuick

// The panel's two number formats, in one place.
//
// Both the activity rail and every settled answer print a duration and a token
// count, and the two must read identically or the eye stops trusting either.
// A QtObject rather than a singleton because nothing outside this directory
// needs them and this repo keeps singletons for things the whole shell shares;
// it holds no state, so an instance per delegate costs nothing.
QtObject {
  id: fmt

  // Milliseconds, at the precision the number deserves: a tool call that took
  // 340ms should say so, a nine-minute turn should not say 578.4s.
  function duration(ms) {
    if (ms <= 0) return ""
    if (ms < 1000) return Math.round(ms) + "ms"
    var s = ms / 1000
    if (s < 60) return (s < 10 ? s.toFixed(1) : Math.round(s)) + "s"
    var m = Math.floor(s / 60)
    return m + "m " + Math.round(s - m * 60) + "s"
  }

  // Token counts, which get long enough to lose their shape at four digits.
  function tokens(n) {
    if (n < 1000) return String(n)
    return (n / 1000).toFixed(n < 10000 ? 1 : 0) + "k"
  }
}
