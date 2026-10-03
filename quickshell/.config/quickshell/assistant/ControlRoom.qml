import QtQuick
import ".."

// The control room: the voice agent's tabs (everything but Chat, which stays
// the panel's own transcript + composer). Only the current tab exists; each
// one loads what it shows when it opens.
//
// Keyboard: the panel routes Ctrl+1..6 / Ctrl+PgUp/PgDn here via select();
// this scope takes the keyboard while a control tab is showing, and passes
// the keys it does not use to the current tab.
FocusScope {
  id: room

  property string tab: "call"
  // The panel is open (animations and display clocks may run).
  property bool live: false
  // The published orb level, handed to the Call tab's orb.
  property real orbLevel: -1
  // The overlay orb is still flying in: the Call tab's orb waits, then pops.
  property bool orbHidden: false
  // A banner from the daemon (calibrating, enrolling): shown over every tab.
  readonly property string banner: EarsModel.banner
  // A passage to read aloud (enrollment): a sheet over the tab, not a strip.
  readonly property bool reading: EarsModel.bannerRead !== "" && room.banner !== ""
  // The current tab's page (scripts and the offscreen harness poke at it).
  readonly property alias page: pages.item

  // The Call tab's orb centre in this item's coordinates, or null on other tabs.
  readonly property var orbPoint: tab === "call" && pages.item && pages.item.orbCentre !== undefined
    ? Qt.point(pages.x + pages.item.orbCentre.x, pages.y + pages.item.orbCentre.y) : null

  // The daemon's banner: what it needs from you right now.
  Rectangle {
    id: bannerStrip
    anchors { left: parent.left; right: parent.right; top: parent.top
              leftMargin: 12; rightMargin: 12; topMargin: room.banner !== "" && !room.reading ? 10 : 0 }
    height: room.banner !== "" && !room.reading ? bannerText.implicitHeight + 22 : 0
    visible: height > 0
    radius: RoomLook.radius
    color: Theme.alpha(Theme.yellow, 0.12)
    border.width: 1
    border.color: Theme.alpha(Theme.yellow, 0.4)
    clip: true
    Text {
      id: bannerText
      anchors { left: parent.left; right: parent.right; top: parent.top; margins: 11 }
      text: room.banner
      color: Theme.yellow
      wrapMode: Text.Wrap
      font.family: RoomLook.sans
      font.pixelSize: RoomLook.meta + 1
      font.weight: Font.Medium
      renderType: Text.QtRendering
    }
    Rectangle {
      visible: EarsModel.bannerProgress >= 0
      anchors { left: parent.left; bottom: parent.bottom }
      width: parent.width * Math.max(0, Math.min(1, EarsModel.bannerProgress))
      height: 2
      color: Theme.yellow
    }
  }

  Loader {
    id: pages
    anchors { left: parent.left; right: parent.right; top: bannerStrip.bottom; bottom: parent.bottom }
    focus: true
    active: room.visible
    // under the reading sheet, the tab steps back
    opacity: room.reading ? 0 : 1
    Behavior on opacity { NumberAnimation { duration: Style.anim.normal } }
    sourceComponent: room.tab === "work" ? workC
      : room.tab === "memory" ? memoryC
      : room.tab === "debug" ? debugC
      : room.tab === "settings" ? settingsC
      : callC
  }

  Component { id: callC; RoomCall { live: room.live; orbLevel: room.orbLevel; orbHidden: room.orbHidden } }
  Component { id: workC; RoomWork { focus: true } }
  Component { id: memoryC; RoomMemory { focus: true } }
  Component { id: debugC; RoomDebug { focus: true } }
  Component { id: settingsC; RoomSettings { focus: true } }

  // ============================================================ reading
  // Enrollment: the daemon hands a passage to read aloud. Shown over
  // whichever tab is open (the panel is never opened for it), gone the
  // moment the banner clears.
  Rectangle {
    id: sheet
    anchors.fill: parent
    z: 10
    visible: opacity > 0
    opacity: room.reading ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Style.anim.normal } }
    color: Theme.alpha(Theme.base, 0.94)
    // swallow clicks meant for the tab underneath
    MouseArea { anchors.fill: parent; hoverEnabled: true }

    Column {
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                leftMargin: 28; rightMargin: 28; verticalCenterOffset: -20 }
      spacing: 18

      Text {
        width: parent.width
        text: room.banner
        color: Theme.yellow
        wrapMode: Text.Wrap
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.meta + 1
        font.weight: Font.Medium
      }
      Rectangle {
        width: parent.width
        height: 4
        radius: 2
        color: Theme.alpha(Theme.overlay0, 0.2)
        visible: EarsModel.bannerProgress >= 0
        Rectangle {
          width: parent.width * Math.max(0, Math.min(1, EarsModel.bannerProgress))
          height: parent.height
          radius: 2
          color: Theme.yellow
          Behavior on width { NumberAnimation { duration: 250 } }
        }
      }
      Text {
        width: parent.width
        text: EarsModel.bannerRead
        color: Theme.text
        wrapMode: Text.Wrap
        lineHeight: 1.35
        font.family: RoomLook.sans
        font.pixelSize: 22
        font.weight: Font.Medium
      }
      Text {
        width: parent.width
        text: "Read it out loud at your normal pace, the way you talk to Ori."
        color: Theme.overlay0
        wrapMode: Text.Wrap
        font.family: RoomLook.sans
        font.pixelSize: RoomLook.small
      }
    }
  }
}
