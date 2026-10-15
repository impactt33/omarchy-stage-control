import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

// One window on the stage: a live preview that travels from where the
// window really is (progress 0) to its place in the spread (progress 1), with
// the macOS hover outline, its title, and its app icon. Drag it onto a desktop
// in the Spaces bar; click it to go to it; its × (or a middle-click) closes it.
Item {
  id: tile

  required property var modelData       // the window's address
  property var overview: null

  readonly property var service: overview ? overview.service : null
  readonly property var info: overview && overview.tileData ? (overview.tileData[modelData] || null) : null
  readonly property real p: service ? service.progress : 0
  readonly property bool reduceMotion: !!(service && service.settings && service.settings.reduceMotion)
  // With reduced motion the windows wait in their spots on the stage and
  // the whole overlay fades in and out instead.
  readonly property real e: reduceMotion ? 1 : p
  readonly property bool onScreen: !!info && info.onScreen
  readonly property bool hovered: !!overview && overview.hoverAddress === modelData
  readonly property bool selected: !!overview && overview.selectedAddress === modelData
  readonly property bool lit: (hovered || selected) && !!service && service.interactive && !dragging && !dropping && !closingOut
  readonly property bool exiting: !!service && service.exitAddress === modelData
  readonly property bool dragging: !!overview && overview.dragAddress === modelData
  readonly property bool hasContent: capture.hasContent
  // The live preview as rendered here, for the Spaces bar's picture of this
  // desktop (DesktopThumb), so it needn't capture the window again.
  readonly property Item preview: frame.contentLayer
  readonly property var handle: {
    Hyprland.toplevels.values
    return service ? service.toplevelFor(modelData) : null
  }
  // The window's title, live: Hyprland's toplevel follows every retitle on
  // its own, so a new title needn't read all of Hyprland's state again. As
  // in a read of Hyprland's state, a window without a title shows its first.
  // Only while the stage shows: a kept tile (Overview.rebuild()) needn't
  // lay out every new title of a busy terminal while the stage is closed.
  readonly property string title: overview && overview.showsHere && handle
    ? (handle.title || (info ? info.initialTitle : "")) : (info ? info.title : "")

  function lerp(a, b, t) { return a + (b - a) * t }
  function smooth(edge0, edge1, x) {
    var t = Math.max(0, Math.min(1, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
  }

  // Place in the spread. Animates when the layout changes while open (a
  // window closes, the Spaces bar expands), not while opening or closing.
  readonly property bool animateLayout: !!service && service.revealed && !service.tracking && p > 0.99
  property real tx: info ? info.to.x : 0
  property real ty: info ? info.to.y : 0
  property real tw: info ? info.to.w : 1
  property real th: info ? info.to.h : 1
  Behavior on tx { enabled: tile.animateLayout; NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
  Behavior on ty { enabled: tile.animateLayout; NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
  Behavior on tw { enabled: tile.animateLayout; NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
  Behavior on th { enabled: tile.animateLayout; NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

  readonly property var from: info ? info.from : ({ x: 0, y: 0, w: 1, h: 1 })

  // Dragging: follow the pointer, shrinking near the Spaces bar.
  property real dragScale: dragging ? overview.dragShrink : 1
  Behavior on dragScale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

  // After a drop the window flies from where it was let go: into a desktop's
  // thumbnail (fading, until it leaves this desktop), or back to its place.
  property bool dropping: false
  property bool dropFades: false
  property var dropFrom: ({ x: 0, y: 0, w: 1, h: 1 })
  property var dropTo: ({ x: 0, y: 0, w: 1, h: 1 })
  property real dropT: 0
  NumberAnimation {
    id: dropAnimation
    target: tile
    property: "dropT"
    from: 0
    to: 1
    duration: 300
    easing.type: Easing.InOutCubic
    onFinished: if (!tile.dropFades) tile.dropping = false
  }

  function flyTo(rect, fade) {
    dropFrom = { x: x, y: y, w: width, h: height }
    var scale = Math.min(rect.w / Math.max(1, width), rect.h / Math.max(1, height))
    var w = width * scale, h = height * scale
    dropTo = { x: rect.x + (rect.w - w) / 2, y: rect.y + (rect.h - h) / 2, w: w, h: h }
    dropFades = fade === true
    dropping = true
    dropAnimation.restart()
  }

  // A new snapshot means the move landed (the tile goes away) or failed (it
  // comes back to its spot).
  Connections {
    target: tile.service
    function onSnapVersionChanged() {
      if (tile.dropping && !dropAnimation.running) tile.dropping = false
    }
  }

  // Switching desktops on the open stage (Overview, "sliding desktops"):
  // the window slides out with the desktop it's on, or in with the new one.
  // A shift on top of where it is, so the slide leaves its place, its
  // hover zoom and its layout animations alone.
  readonly property bool leaving: !!info && info.leaving === true
  // A window of a desktop beside this one, waiting off the screen's edge
  // while a swipe peeks at it (Overview, "swiping between desktops").
  readonly property bool peek: !!info && info.peek === true
  property real slideX: 0
  // The swipe moves every tile at once (Overview.trackX).
  transform: Translate { x: tile.slideX + (tile.overview ? tile.overview.trackX : 0) }
  NumberAnimation {
    id: slideAnimation
    target: tile
    property: "slideX"
    easing.type: Easing.OutCubic
  }

  function slideTo(target, duration) {
    slideAnimation.stop()
    slideAnimation.from = slideX
    slideAnimation.to = target
    slideAnimation.duration = duration
    slideAnimation.start()
  }

  // Straight to `offset` (a peeking window's place beside the screen),
  // unless it's on its way somewhere.
  function placeAt(offset) {
    if (!slideAnimation.running) slideX = offset
  }

  // Takes on `shift` of the swipe's, which goes back to 0 at the same
  // moment, so the window stays where it is on screen. One on its way
  // somewhere keeps going there.
  function absorbShift(shift) {
    if (!slideAnimation.running) {
      slideX += shift
      return
    }
    var target = slideAnimation.to
    var left = Math.max(60, slideAnimation.duration * (1 - Math.min(1, slideAnimation.currentTime / Math.max(1, slideAnimation.duration))))
    slideAnimation.stop()
    slideX += shift
    slideTo(target, left)
  }

  // In from `offset`, or, for a window already off its place (on its way
  // out, or waiting beside the screen during a swipe), from where it is.
  function slideIn(offset, duration) {
    if (!slideAnimation.running && Math.abs(slideX) < 0.5) slideX = offset
    slideTo(0, duration)
  }

  Component.onCompleted: {
    if (!overview) return
    overview.registerTile(modelData, tile)
    if (peek) placeAt(info.peekSide * overview.pageShift)
    var offset = overview.takeSlideIn(modelData)
    if (offset !== undefined) slideIn(offset, overview.slideDuration)
  }

  // Tiles outlive a closed stage (Overview.rebuild()): the next opening
  // starts them afresh.
  Connections {
    target: tile.overview
    function onShowsHereChanged() {
      if (tile.overview.showsHere) return
      slideAnimation.stop()
      tile.slideX = 0
      dropAnimation.stop()
      tile.dropping = false
      closeTimeout.stop()
      tile.closingOut = false
    }
  }

  x: dropping ? lerp(dropFrom.x, dropTo.x, dropT)
    : dragging ? overview.dragPoint.x - overview.dragGrab.x * tw * dragScale
    : lerp(from.x, tx, e)
  y: dropping ? lerp(dropFrom.y, dropTo.y, dropT)
    : dragging ? overview.dragPoint.y - overview.dragGrab.y * th * dragScale
    : lerp(from.y, ty, e)
  width: dropping ? lerp(dropFrom.w, dropTo.w, dropT) : dragging ? tw * dragScale : lerp(from.w, tw, e)
  height: dropping ? lerp(dropFrom.h, dropTo.h, dropT) : dragging ? th * dragScale : lerp(from.h, th, e)
  // Above the Spaces bar (z 1100) while dragged or flying into a desktop.
  z: dragging || dropping ? 2000 : exiting ? 900 : lit ? 500 : (info ? info.z : 0)
  opacity: (dropping && dropFades ? 1 - dropT * 0.85 : onScreen ? 1 : smooth(0.15, 0.85, p)) * closeFade
  visible: !!info

  // Hover lift, like macOS.
  scale: closingOut ? 0.94 : lit ? 1.025 : 1
  Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

  readonly property real cornerRadius: lerp(overview ? overview.windowRounding : 0, 10, smooth(0, 0.5, e))

  RectangularShadow {
    anchors.fill: frame
    radius: frame.radius
    offset: Qt.vector2d(0, 12 * tile.e)
    blur: 34 * tile.e + (tile.dragging ? 20 : 0)
    spread: -4
    color: Qt.rgba(0, 0, 0, (tile.dragging ? 0.6 : 0.5) * tile.e)
    visible: tile.e > 0.02
  }

  // The window's title bar and border from the screen capture, following the
  // window and fading as it leaves its spot (and returning as it comes back).
  ShaderEffectSource {
    id: decoration
    readonly property var d: tile.service ? tile.service.decor : ({ border: 0, bar: 0 })
    readonly property var at: tile.overview ? tile.overview.ghostRects[tile.modelData] : null
    readonly property bool matches: !!at && !!tile.info && tile.info.ghost === true
      && at.x === tile.from.x && at.y === tile.from.y && at.w === tile.from.w && at.h === tile.from.h
    readonly property real s: tile.width / Math.max(1, tile.from.w)
    readonly property real above: d.border + d.bar
    sourceItem: matches && !tile.dragging && !tile.dropping ? tile.overview.screenCapture : null
    sourceRect: Qt.rect(tile.from.x - d.border, tile.from.y - above, tile.from.w + d.border * 2, tile.from.h + d.border + above)
    x: -d.border * s
    y: -above * s
    width: sourceRect.width * s
    height: sourceRect.height * s
    opacity: 1 - tile.smooth(0, 0.3, tile.p)
    visible: !!sourceItem && opacity > 0.01 && (d.border + d.bar) > 0
    live: false
    hideSource: false
    // A tile outlives the overlay's window (Overview.rebuild()), but a copy
    // that isn't live is taken once per ShaderEffectSource. Take it again
    // when the source comes back for a new opening, and when the new screen
    // capture is in.
    onSourceItemChanged: if (sourceItem) scheduleUpdate()
    Connections {
      target: tile.overview ? tile.overview.screenCapture : null
      function onHasContentChanged() {
        if (decoration.sourceItem && tile.overview.screenCapture.hasContent) decoration.scheduleUpdate()
      }
    }
  }

  // The live preview is rendered at the window's size times the first power
  // of 0.8 at or above the tile's scale: never below the size it shows at,
  // never far above it, and while the tile travels it's rendered at a new size
  // a few times instead of on every frame.
  readonly property real renderScale: {
    var s = info ? width / Math.max(1, info.size.w) : 1
    if (!(s < 1)) return 1
    return Math.max(0.2, Math.pow(0.8, Math.floor(Math.log(s) / Math.log(0.8))))
  }

  Rounded {
    id: frame
    anchors.fill: parent
    radius: tile.cornerRadius
    color: Qt.rgba(0.11, 0.11, 0.13, 1)
    contentWidth: tile.info ? tile.info.size.w * tile.renderScale : width
    contentHeight: tile.info ? tile.info.size.h * tile.renderScale : height

    ScreencopyView {
      id: capture
      anchors.fill: parent
      captureSource: tile.overview && tile.overview.showsHere && tile.handle ? tile.handle.wayland : null
      // Not while the stage opens or closes by itself: Hyprland renders a
      // live capture again on every frame, changed or not, and those frames
      // are the ones with the least time to spare. The window flies with the
      // frame it has and comes alive again when it lands. While the fingers
      // hold the stage, it stays live.
      live: !!tile.overview && tile.overview.showsHere && !(tile.service && tile.service.animating)
    }
  }

  // The macOS selection outline, in the highlight color.
  Rectangle {
    anchors.fill: frame
    anchors.margins: -5
    radius: frame.radius + 5
    color: "transparent"
    border.width: 3
    border.color: tile.overview ? tile.overview.highlight : "#0a84ff"
    opacity: tile.lit ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 140 } }
  }

  // App icon, riding on the bottom edge. It's sized from the window, so its
  // size changes as the window travels. It's rasterized once, at its size in
  // the spread, and scaled on the way: IconImage loads an icon at the size it
  // shows, which rendered it again at every size the animation went through.
  Image {
    id: badge
    readonly property bool wanted: !!tile.overview && tile.overview.showIcons && !tile.overview.grouped && !!tile.info && tile.info.icon !== ""
    readonly property real size: Math.round(Math.max(26, Math.min(44, frame.width * 0.11)))
    readonly property real restSize: tile.info ? Math.round(Math.max(26, Math.min(44, tile.info.to.w * 0.11))) : size
    source: wanted ? tile.info.icon : ""
    sourceSize: Qt.size(restSize, restSize)
    width: size
    height: size
    fillMode: Image.PreserveAspectFit
    anchors.horizontalCenter: frame.horizontalCenter
    anchors.verticalCenter: frame.bottom
    opacity: wanted && !tile.dragging && !tile.dropping ? tile.smooth(0.55, 1, tile.p) : 0
    visible: opacity > 0.01
    asynchronous: true
  }

  // Window title, under the window. Grouped by app, windows sit too close for
  // a title under each, and the group's label names the app, so titles show
  // on hover only.
  Glass {
    id: titlePill
    readonly property string titles: tile.overview ? tile.overview.windowTitles : "hover"
    readonly property bool wanted: !!tile.info && tile.title !== "" && !tile.dragging && !tile.dropping
      && ((titles === "always" && !tile.overview.grouped) || (titles !== "never" && tile.lit))
    anchors.horizontalCenter: frame.horizontalCenter
    anchors.top: frame.bottom
    anchors.topMargin: badge.visible ? badge.size / 2 + 6 : 10
    width: Math.min(Math.max(frame.width, 200), titleText.implicitWidth + 28)
    height: 26
    radius: 13
    style: tile.overview ? tile.overview.glassStyle : "liquid"
    backdrop: tile.overview ? tile.overview.glassBackdrop : null
    backdropIsWindow: true
    opacity: wanted ? tile.smooth(0.7, 1, tile.p) : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: 150 } }

    Text {
      id: titleText
      anchors.centerIn: parent
      width: Math.min(implicitWidth, parent.width - 24)
      text: tile.title
      textFormat: Text.PlainText
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignHCenter
      color: Qt.rgba(1, 1, 1, 0.95)
      font.family: tile.overview ? tile.overview.uiFont : ""
      font.pixelSize: 12
      font.weight: Font.Medium
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: frame
    enabled: !!tile.service && tile.service.interactive && !tile.dropping && !tile.leaving && !tile.peek
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: tile.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor

    property point pressedAt: Qt.point(0, 0)

    onEntered: tile.hoverIn()
    onExited: tile.hoverOut()
    onPressed: function(event) {
      pressedAt = mapToItem(tile.overview.stage, event.x, event.y)
      tile.overview.dragGrab = Qt.point(event.x / Math.max(1, width), event.y / Math.max(1, height))
    }
    onPositionChanged: function(event) {
      if (!pressed || !(event.buttons & Qt.LeftButton)) return
      var at = mapToItem(tile.overview.stage, event.x, event.y)
      if (!tile.dragging && Math.abs(at.x - pressedAt.x) + Math.abs(at.y - pressedAt.y) > 10)
        tile.overview.beginDrag(tile.modelData, at)
      if (tile.dragging) tile.overview.moveDrag(at)
    }
    onReleased: function(event) {
      var at = mapToItem(tile.overview.stage, event.x, event.y)
      if (tile.dragging) {
        tile.overview.endDrag(at)
        return
      }
      if (event.button === Qt.MiddleButton) tile.overview.closeWindow(tile.modelData, "middle")
      else tile.overview.activate(tile.modelData)
    }
    onCanceled: if (tile.dragging) tile.overview.cancelDrag()
  }

  // ---- closing --------------------------------------------------------------------

  function hoverIn() {
    hoverGrace.stop()
    overview.hoverAddress = modelData
  }

  function hoverOut() {
    hoverGrace.restart()
  }

  Timer {
    id: hoverGrace
    interval: 80
    onTriggered: {
      if (!mouse.containsMouse && !closeMouse.containsMouse && tile.overview.hoverAddress === tile.modelData)
        tile.overview.hoverAddress = ""
    }
  }

  // The window fades while its app closes it. An app that asks first (unsaved
  // changes) keeps it open; then the window comes back and its dialog shows up
  // as a window of its own.
  property bool closingOut: false
  property real closeFade: closingOut ? 0.35 : 1
  Behavior on closeFade { NumberAnimation { duration: 180 } }

  function markClosing() {
    closingOut = true
    closeTimeout.restart()
  }

  Timer {
    id: closeTimeout
    interval: 1600
    onTriggered: tile.closingOut = false
  }

  // Close button: top left, where macOS puts it, like the × on desktops.
  Glass {
    id: closeButton
    readonly property bool wanted: !!tile.overview && tile.overview.showCloseButtons && tile.hovered
      && !!tile.service && tile.service.interactive && !tile.dragging && !tile.dropping && !tile.closingOut
    x: -9
    y: -9
    z: 10
    width: 24
    height: 24
    radius: 12
    style: "solid"
    selected: closeMouse.containsMouse
    selectedColor: "#ff5f57"
    selectedStrength: 0.95
    opacity: wanted ? 1 : 0
    visible: opacity > 0.01
    scale: wanted ? 1 : 0.6
    Behavior on opacity { NumberAnimation { duration: 140 } }
    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }

    Text {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -1
      text: "×"
      textFormat: Text.PlainText
      color: closeMouse.containsMouse ? Qt.rgba(0.36, 0.04, 0.02, 1) : "white"
      font.pixelSize: 17
      font.weight: Font.DemiBold
      font.family: tile.overview ? tile.overview.uiFont : ""
    }

    MouseArea {
      id: closeMouse
      anchors.fill: parent
      anchors.margins: -4
      hoverEnabled: true
      enabled: closeButton.wanted
      cursorShape: Qt.PointingHandCursor
      onEntered: tile.hoverIn()
      onExited: tile.hoverOut()
      onClicked: tile.overview.closeWindow(tile.modelData, "button")
    }
  }

  Component.onDestruction: if (overview) overview.unregisterTile(modelData, tile)
}
