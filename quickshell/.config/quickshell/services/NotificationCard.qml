import QtQuick
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.Notifications
import "root:/"

// One notification, drawn the way swaync draws one.
//
// This is the QML transcription of swaync's notification row, from
// ~/.dotfiles/swaync/.config/swaync/style.css plus the packaged
// /etc/xdg/swaync/style.css it layers over (cssPriority "user", so every
// user rule wins over the packaged one regardless of GTK specificity):
//
//   .notification        { border-radius: 12px; margin: 6px 12px;
//                          background: @base; border: 2px solid @mauve }
//   .notification.low    { border-color: @green }
//   .notification.critical { border-color: @red }
//   .notification-content { padding: 12px }          (+ 4px from the packaged
//                          .notification-default-action padding)
//   .summary  { color: @text;     font-weight: bold; font-size: 14px }
//   .body     { color: @subtext1; font-size: 13px }
//   .time     { color: @subtext0; font-size: 11px; margin-right: 30px }
//   .image    { border-radius: 8px; margin-right: 12px }   at 64px
//              (config.json "notification-icon-size": 64; the packaged sheet
//               sizes the app-icon badge at icon-size/3)
//   .close-button { background: @surface0; color: @text; border-radius: 6px;
//                   margin: 8px; padding: 2px 8px }
//   .close-button:hover { background: @red; color: @base }
//   .notification-action { border-top: 1px solid @surface0; padding: 8px 16px;
//                          color: @overlay0 }
//   .notification-action:hover  { color: @mauve }
//   .notification-action:active { color: @lavender }
//
// Verified against the running daemon with grim rather than read off the file:
//   - the card is 352px wide inside a 400px window (12px .notification margin
//     + 12px packaged .notification-background padding on each side),
//   - the close button is REVEALED ON HOVER, not always painted,
//   - the popup carries no timestamp; only control-center rows do,
//   - the action buttons keep the packaged GTK button fill, which lands on
//     rgba(255,255,255,0.1) over @base -- three units off @surface0, so
//     @surface0 is what this uses,
//   - a notification with both an image and an app icon draws the image at
//     64px with the app icon as a small badge over its bottom-right corner.
//
// -------------------------------------------------------------------- motion
// swaync fades a row in over `transition-time` (200ms) and that is the whole
// of its animation vocabulary. This card additionally slides in from the right
// -- the direction it came from -- and, on the way out, collapses its own
// height so the stack below closes the gap in the same beat instead of
// snapping up. Nothing scales, nothing overshoots.
Item {
  id: root

  // ------------------------------------------------------------------- api
  // The store entry ({ key, notif, time, code, ... }) this card draws.
  property var entry: null
  readonly property var notif: entry ? entry.notif : null

  property int cardWidth: 352
  // Vertical rhythm between cards: .notification { margin: 6px 12px } on both
  // neighbours. Carried by the card so it collapses along with it.
  property int gap: 12
  // Control-center rows show the relative timestamp; popups do not.
  property bool showTime: false
  // Wall-clock tick from the view, so every visible "5 mins ago" updates off
  // one clock instead of one timer per card.
  property var now: 0
  // Keyboard selection in the control center. swaync marks it with
  // .notification-row:focus { background: @noti-bg-focus }; here the card
  // simply lights its own hover tint.
  property bool selected: false

  // Set by the view when the store marks this entry as leaving.
  property bool leaving: false

  signal defaultActivated()
  signal actionActivated(int index)
  signal closeRequested()
  signal linkActivated(string link)
  // Emitted once the exit animation has finished and the row may be dropped.
  signal finished()

  // ---------------------------------------------------------------- reveal
  property bool shown: false
  property bool closing: false

  readonly property int fullHeight: card.implicitHeight + gap
  // The painted card, without the margin -- the collapsed-group stubs behind
  // it are sized off this.
  readonly property int cardHeight: card.implicitHeight

  width: cardWidth + 2 * 12   // .notification margin: 6px 12px
  height: shown ? fullHeight : 0
  clip: height < fullHeight

  Component.onCompleted: root.shown = true

  onLeavingChanged: {
    if (leaving && !closing) {
      root.closing = true
      root.shown = false
    }
  }

  onHeightChanged: if (closing && height <= 0.01) root.finished()

  Behavior on height {
    NumberAnimation {
      duration: Style.anim.normal
      easing.type: Style.anim.easing
    }
  }

  // ----------------------------------------------------------------- card
  Rectangle {
    id: card

    // .notification margin: 6px 12px, plus the slide: the card comes in from
    // the right, which is the edge it arrived from.
    x: 12 + (root.shown ? 0 : 20)
    y: 6
    width: root.cardWidth
    implicitHeight: content.implicitHeight + actions.implicitHeight

    radius: 12                               // .notification border-radius
    color: Theme.base                        // .notification background
    border.width: 2
    border.color: root.notif
      ? (root.notif.urgency === NotificationUrgency.Critical ? Theme.red
        : root.notif.urgency === NotificationUrgency.Low ? Theme.green
        : Theme.mauve)
      : Theme.mauve

    opacity: root.shown ? 1 : 0

    Behavior on x {
      NumberAnimation { duration: Style.anim.reveal; easing.type: Style.anim.easing }
    }
    Behavior on opacity {
      NumberAnimation { duration: Style.anim.opacityDuration; easing.type: Style.anim.easingSmooth }
    }
    Behavior on border.color {
      ColorAnimation { duration: Style.anim.colorDuration; easing.type: Style.anim.easingSmooth }
    }

    // --------------------------------------------------- default action
    // The packaged sheet's .notification-default-action: the whole
    // summary/body region is one big button that fires the "default" action
    // and tints on hover.
    Rectangle {
      id: content
      width: parent.width
      implicitHeight: contentRow.implicitHeight + 2 * 16
      color: defaultArea.containsMouse || root.selected ? Theme.hoverBackground : Theme.transparent
      topLeftRadius: card.radius - 2
      topRightRadius: card.radius - 2
      bottomLeftRadius: actions.visible ? 0 : card.radius - 2
      bottomRightRadius: actions.visible ? 0 : card.radius - 2

      Behavior on color {
        ColorAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
      }

      MouseArea {
        id: defaultArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        // swaync(1): "Left click ... Activate notification action",
        //            "Middle/Right click notification: Close notification".
        onClicked: function (mouse) {
          if (mouse.button === Qt.LeftButton) root.defaultActivated()
          else root.closeRequested()
        }
      }

      Row {
        id: contentRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 16          // .notification-content 12 + default-action 4
        spacing: iconSlot.visible ? 12 : 0   // .image margin-right

        // -------------------------------------------------------- image
        // config.json "image-visibility": "when-available" -- no slot at all
        // when the notification carries neither an image nor an app icon.
        Item {
          id: iconSlot
          width: 64                  // "notification-icon-size": 64
          height: 64
          visible: root.notif && (root.notif.image !== "" || root.notif.appIcon !== "")

          ClippingRectangle {
            anchors.fill: parent
            radius: 8                // .image border-radius
            color: Theme.transparent

            Image {
              anchors.fill: parent
              // Guarded on the slot rather than on `notif` alone: an empty
              // source would still be a request, and "image://icon/" with no
              // name makes the icon provider log a failed lookup.
              source: !iconSlot.visible ? ""
                : root.notif.image !== "" ? root.notif.image
                : "image://icon/" + root.notif.appIcon
              fillMode: Image.PreserveAspectFit
              sourceSize.width: 128
              sourceSize.height: 128
              asynchronous: true
            }
          }

          // The packaged sheet's .app-icon: drawn only when the primary image
          // is set, at icon-size/3, over the image's corner.
          Image {
            visible: root.notif && root.notif.image !== "" && root.notif.appIcon !== ""
            width: 22                // --notification-app-icon-size: 64/3
            height: 22
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 2
            source: visible ? "image://icon/" + root.notif.appIcon : ""
            sourceSize.width: 44
            sourceSize.height: 44
            asynchronous: true
          }
        }

        // --------------------------------------------------------- text
        Column {
          width: contentRow.width - (iconSlot.visible ? iconSlot.width + contentRow.spacing : 0)
          spacing: 2

          // .summary and .time share a row; .time is right-aligned with a
          // 30px right margin so it clears the close button.
          Item {
            width: parent.width
            height: Math.max(summary.implicitHeight, time.implicitHeight)

            Text {
              id: summary
              anchors.left: parent.left
              anchors.right: root.showTime ? time.left : parent.right
              anchors.rightMargin: root.showTime ? 8 : 0
              text: root.notif ? root.notif.summary : ""
              color: Theme.text
              font.family: Style.font.family
              font.pixelSize: Style.font.size          // .summary 14px
              font.weight: Style.font.boldWeight
              elide: Text.ElideRight
              renderType: Text.NativeRendering
            }

            Text {
              id: time
              visible: root.showTime
              anchors.right: parent.right
              anchors.rightMargin: 30                  // .time margin-right
              anchors.baseline: summary.baseline
              text: root.showTime && root.entry ? root.relativeTime(root.entry.time) : ""
              color: Theme.subtext0
              font.family: Style.font.family
              font.pixelSize: Style.font.size - 3      // .time 11px
              renderType: Text.NativeRendering
            }
          }

          Text {
            width: parent.width
            visible: text !== ""
            text: root.notif ? root.notif.body : ""
            color: Theme.subtext1
            font.family: Style.font.family
            font.pixelSize: Style.font.size - 1        // .body 13px
            wrapMode: Text.WordWrap
            // The server advertises body-markup, so bodies arrive as Pango
            // markup: <b>, <i>, <u> and <a href> all map onto StyledText.
            // Anything else degrades to plain text, which is what GTK does
            // with tags it does not know either.
            textFormat: Text.StyledText
            maximumLineCount: 10
            elide: Text.ElideRight
            renderType: Text.NativeRendering
            onLinkActivated: function (link) { root.linkActivated(link) }
          }
        }
      }

      // ------------------------------------------------------- close
      // Hover-revealed, exactly like swaync's (verified with grim: an
      // unhovered popup has no close affordance at all).
      Rectangle {
        id: closeButton
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 8                             // .close-button margin
        width: closeGlyph.implicitWidth + 16           // padding: 2px 8px
        height: closeGlyph.implicitHeight + 4
        radius: 6                                      // .close-button radius
        opacity: defaultArea.containsMouse || closeArea.containsMouse || actionsHover.hovered ? 1 : 0
        color: closeArea.containsMouse ? Theme.red : Theme.surface0

        Behavior on opacity {
          NumberAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
        }
        Behavior on color {
          ColorAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
        }

        Text {
          id: closeGlyph
          anchors.centerIn: parent
          text: "✕"
          color: closeArea.containsMouse ? Theme.base : Theme.text
          font.family: Style.font.family
          font.pixelSize: Style.font.size - 2
          renderType: Text.NativeRendering

          Behavior on color {
            ColorAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
          }
        }

        MouseArea {
          id: closeArea
          anchors.fill: parent
          enabled: closeButton.opacity > 0.5
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.closeRequested()
        }
      }
    }

    // ----------------------------------------------------- alt actions
    // swaync's action box is a two-per-line flow, not a single row that
    // divides the width. Measured off the running daemon with grim (pixel
    // runs across a 352px card, then the same runs on the wrapped case):
    //
    //   the strip is laid out in cells 6px in from each card edge, so two
    //   cells are 170px wide and a lone cell is 340px; each cell holds its
    //   button with 16px to either side (138px wide when paired, 308px on
    //   its own) and carries its OWN 1px @surface0 top rule -- which is why
    //   a third action wraps onto a second line at the same 138px, left
    //   aligned, with a half-width rule above it rather than a full one.
    //
    //   .notification-action { border-top: 1px solid @surface0; padding: 8px }
    //   puts 8px above and below a 34px button, so a line is 51px tall.
    Item {
      id: actions
      anchors.top: content.bottom
      width: parent.width
      visible: root.actionList.length > 0

      readonly property int cellInset: 6
      readonly property int cellPad: 16
      readonly property int cols: Math.min(2, Math.max(1, root.actionList.length))
      readonly property int lines: Math.ceil(root.actionList.length / cols)
      readonly property int cellWidth: Math.floor((width - 2 * cellInset) / cols)
      readonly property int lineHeight: 34 + 2 * 8 + 1

      implicitHeight: visible ? lines * lineHeight : 0

      HoverHandler { id: actionsHover }

      Column {
        anchors.fill: parent

        Repeater {
          model: actions.lines

          Item {
            id: actionLine
            required property int index

            width: actions.width
            height: actions.lineHeight

            Row {
              anchors.left: parent.left
              anchors.leftMargin: actions.cellInset
              anchors.top: parent.top
              height: parent.height

              Repeater {
                model: root.actionList.slice(actionLine.index * actions.cols,
                                             (actionLine.index + 1) * actions.cols)

                Item {
                  id: actionCell
                  required property var modelData

                  width: actions.cellWidth
                  height: actions.lineHeight

                  // .notification-action { border-top: 1px solid @surface0 }
                  Rectangle {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 1
                    color: Theme.surface0
                  }

                  // The packaged GTK button inside the action row: it lands on
                  // rgba(255,255,255,0.1) over @base, three units off
                  // @surface0.
                  Rectangle {
                    id: actionButton
                    anchors.top: parent.top
                    anchors.topMargin: 9      // the rule owns the first pixel
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: actions.cellWidth - 2 * actions.cellPad
                    height: 34
                    radius: 12
                    color: actionArea.containsMouse ? Theme.surface1 : Theme.surface0

                    Behavior on color {
                      ColorAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
                    }

                    Text {
                      anchors.centerIn: parent
                      width: parent.width - 24
                      text: actionCell.modelData.text
                      color: actionArea.pressed ? Theme.lavender
                        : actionArea.containsMouse ? Theme.mauve : Theme.text
                      horizontalAlignment: Text.AlignHCenter
                      elide: Text.ElideRight
                      font.family: Style.font.family
                      font.pixelSize: Style.font.size
                      font.weight: Style.font.boldWeight
                      renderType: Text.NativeRendering

                      Behavior on color {
                        ColorAnimation { duration: Style.anim.quick; easing.type: Style.anim.easingSmooth }
                      }
                    }

                    MouseArea {
                      id: actionArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.actionActivated(actionCell.modelData.index)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // -------------------------------------------------------------- helpers
  // The buttons swaync paints: every action except "default" (that one is the
  // click-the-body action), plus the synthetic 2FA copy action the store
  // appends when it finds a code in the body. Index -1 marks the copy action.
  readonly property var actionList: {
    var out = []
    if (!notif) return out
    var acts = notif.actions
    for (var i = 0; i < acts.length; i++) {
      if (acts[i].identifier === "default") continue
      out.push({ text: acts[i].text, index: i })
    }
    if (entry && entry.code) out.push({ text: 'COPY "' + entry.code + '"', index: -1 })
    return out
  }

  // config.json "relative-timestamps": true. swaync renders "Now",
  // "2 mins ago", ... -- matched here down to the pluralisation.
  function relativeTime(stamp) {
    var secs = Math.floor(((root.now || Date.now()) - stamp) / 1000)
    if (secs < 60) return "Now"
    var mins = Math.floor(secs / 60)
    if (mins < 60) return mins + (mins === 1 ? " min ago" : " mins ago")
    var hours = Math.floor(mins / 60)
    if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago")
    var days = Math.floor(hours / 24)
    return days + (days === 1 ? " day ago" : " days ago")
  }
}
