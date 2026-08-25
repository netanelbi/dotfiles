import QtQuick
import Quickshell
import Quickshell.Services.Polkit
import "root:/"

// The polkit authentication agent -- the piece that was simply MISSING on this
// machine. `polkitd` was running, but nothing had registered as an agent, so
// `pkexec --disable-internal-agent true` answered "No authentication agent
// found" and every GUI app that wanted root failed silently. There is no
// polkit-gnome / polkit-kde here to fall back on; this file is the agent.
//
// PolkitAgent registers itself on componentComplete at its default object path
// (/org/quickshell/PolkitAgent) for this login session's subject, so there is
// nothing to configure -- but it only exists because shell.qml references it.
//
// ----------------------------------------------------------------- the flow
// `agent.flow` is non-null for the lifetime of one authentication REQUEST, and
// a request can contain several PAM conversation rounds: a wrong password does
// not end it, polkit restarts the session and asks again. So the dialog must
// not treat a failure as a close, and must reset itself for the next round.
// The whole state machine reduces to four AuthFlow properties:
//
//   isResponseRequired  PAM is waiting for input. False while it is checking,
//                       which is exactly when the submit button must be dead.
//   inputPrompt         "Password: " and friends, straight from PAM.
//   responseVisible     PAM says this answer may be echoed. Almost always
//                       false (=> a password), but honour it: a PAM stack can
//                       ask a non-secret question mid-conversation.
//   supplementaryMessage / supplementaryIsError
//                       "Authentication failure" after a bad try, and the
//                       occasional informational line.
//
// The request ends when `isCompleted` goes true, whether it succeeded, was
// cancelled, or ran out of retries.
Scope {
  id: root

  PolkitAgent {
    id: agent

    onAuthenticationRequestStarted: {
      // The impl already picks an identity it can authenticate and cancels the
      // request outright when there is none, so `selectedIdentity` is normally
      // set by the time this fires. Setting it to null is a hard error in the
      // C++ side, hence the length guard.
      if (agent.flow && !agent.flow.selectedIdentity && agent.flow.identities.length > 0)
        agent.flow.selectedIdentity = agent.flow.identities[0]

      root.open = true
    }

    onIsRegisteredChanged: {
      if (!isRegistered)
        console.warn("Polkit: agent registration lost -- pkexec will report no agent")
    }
  }

  readonly property var flow: agent.flow
  // Held separately from `flow !== null` so the dialog can animate out after
  // the flow is gone, and so a completed-but-not-yet-released flow does not
  // keep an inert dialog on screen holding exclusive keyboard focus.
  property bool open: false

  // One request finished (authorised, denied for good, or cancelled). Nothing
  // to report to the user beyond dismissing -- the app that asked gets the
  // answer over D-Bus, and polkit has already shown the failure text in
  // supplementaryMessage during the retries.
  Connections {
    target: root.flow
    ignoreUnknownSignals: true
    function onIsCompletedChanged() {
      if (root.flow && root.flow.isCompleted) root.open = false
    }
  }

  function submit(value) {
    if (flow && flow.isResponseRequired) flow.submit(value)
  }

  function cancel() {
    // Cancelling the request is what makes the caller fail fast instead of
    // hanging; closing the window alone would leave polkitd waiting.
    if (flow && !flow.isCompleted) flow.cancelAuthenticationRequest()
    root.open = false
  }

  // The dialog is modal to the user, not to a monitor: one window, on whatever
  // output has focus when the request arrives.
  PolkitDialog { controller: root }
}
