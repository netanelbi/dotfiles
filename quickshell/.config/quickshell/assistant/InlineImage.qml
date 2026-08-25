import QtQuick
import ".."

// One picture inside an answer.
//
// Ori writes `![alt](/home/netanel/Pictures/x.png)` and this is what stands
// where that syntax was. It is the only thing in this shell that paints a file
// the MODEL picked, so two of its properties are structural rather than
// stylistic:
//
//   * it never fetches. The path was vetted by Fmt.localImage() before it got
//     here -- absolute, local, no scheme -- and this component has no way to
//     reach anything else.
//   * it is BOUNDED. The card is 460px wide and its transcript ~740px tall on
//     this screen, so an unbounded screenshot IS the scrollback: the answer
//     that explains the picture ends up off screen above it, and scrolling
//     back through a conversation means scrolling through wallpaper. The cap
//     is 240px -- a third of the transcript, and exactly what a 16:9 grab of
//     this laptop's screen comes to at the column's 426px width. So the
//     ordinary case is shown whole, edge to edge, and it is portraits and
//     posters that get scaled down to fit.
//
// A file that will not load degrades to WORDS, never to a broken-image box and
// never to a hole: the alt text says what it was meant to be and the path says
// which file failed, which is the only way to tell a typo from a deleted file.
Item {
  id: shot

  property string source: ""
  property string alt: ""

  // See above. Not a Style token: it is a fact about this card's proportions,
  // not a value the rest of the shell shares.
  readonly property int maxHeight: 240

  readonly property bool ready: pic.status === Image.Ready && pic.paintedHeight > 0

  implicitHeight: ready ? Math.ceil(pic.paintedHeight) : failed.implicitHeight
  height: implicitHeight

  Image {
    id: pic
    // The image is given a bounding box and paints top-left inside it, so
    // `paintedHeight` is the real height of what is on screen and the item
    // above can be exactly that tall. Aspect ratio is PreserveAspectFit's job.
    //
    // The box never exceeds the file's own size, because PreserveAspectFit
    // scales UP as happily as down: a 64px icon stretched across the full
    // column is a blurry lie about what the file is. Small pictures stay small.
    width: Math.min(shot.width, pic.sourceSize.width || shot.width)
    height: Math.min(shot.maxHeight, pic.sourceSize.height || shot.maxHeight)
    fillMode: Image.PreserveAspectFit
    horizontalAlignment: Image.AlignLeft
    verticalAlignment: Image.AlignTop
    visible: shot.ready
    source: shot.source

    // Left synchronous (the default) on purpose. The answer is re-split on
    // every token, which rebuilds these pieces, so this Image is created and
    // destroyed once per token while text still streams past it. A synchronous
    // load off Qt's pixmap cache is a same-frame hit; an asynchronous one would
    // start each of those rebuilds from an empty frame, which is precisely the
    // flicker this is meant to avoid.
  }

  // The frame. A dark screenshot on a dark card has no edge of its own, and
  // without one the picture reads as part of the panel rather than as
  // something in the answer.
  Rectangle {
    anchors.fill: pic
    anchors.bottomMargin: pic.height - Math.ceil(pic.paintedHeight)
    anchors.rightMargin: pic.width - Math.ceil(pic.paintedWidth)
    visible: shot.ready
    color: Theme.transparent
    border.width: 1
    border.color: Theme.surface1
  }

  Text {
    id: failed
    anchors { left: parent.left; right: parent.right }
    visible: !shot.ready
    // Both halves, because they answer different questions: the alt says what
    // Ori meant to show, the path says what to go and look at.
    text: (shot.alt !== "" ? shot.alt + " — " : "")
      + decodeURI(String(shot.source).replace("file://", ""))
    color: Theme.overlay0
    font.italic: true
    wrapMode: Text.WrapAnywhere
    maximumLineCount: 2
    elide: Text.ElideRight
    font.family: Style.font.family
    font.pixelSize: Style.font.panelMeta
    renderType: Text.NativeRendering
  }
}
