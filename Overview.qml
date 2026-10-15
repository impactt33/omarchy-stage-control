import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import "Layout.js" as Layout
import "Model.js" as Model

// The stage on one display: a full-screen layer over everything but the top
// bar (and whatever else Hyprland keeps room for at the screen's edges),
// which stays as it is, live and clickable. At progress 0 the stage looks
// exactly like the desktop (the wallpaper, every window where it is); as
// progress goes to 1 the windows fly into the spread, the wallpaper blurs
// and dims, and the Spaces bar slides out from under the top bar.
PanelWindow {
  id: win

  required property var modelData       // the ShellScreen
  property var service: null

  screen: modelData
  readonly property string screenName: modelData ? modelData.name : ""
  readonly property var snap: service ? service.snap : null
  readonly property var monitor: snap ? Model.monitorByName(snap, screenName) : null
  readonly property bool showsHere: !!service && service.shown && !!monitor
    && (service.mode === "mission" || monitor.focused)
  readonly property real p: service ? service.progress : 0
  readonly property var settings: service && service.settings ? service.settings : ({})
  readonly property bool reduceMotion: settings.reduceMotion === true
  readonly property real e: reduceMotion ? 1 : p
  readonly property bool mission: !!service && service.mode === "mission"
  // Open, and not moving: not opening or closing, nor following the fingers.
  readonly property bool settled: !!service && service.revealed && !service.tracking && !service.closing && p >= 1
  // Up, but waiting for the previews before it shows. Meanwhile the stage is
  // drawn at 1/250 opacity: invisible, since at progress 0 it matches the
  // screen under it, but its layers and textures, the wallpaper's blur and
  // the glass get made now instead of all on the first frame you see. What
  // would be transparent at progress 0 is drawn at half opacity until then,
  // enough for Qt to draw it at all (it skips anything below 1/1000).
  readonly property bool preparing: (!!service && service.shown && !service.revealed) || warming

  readonly property string glassStyle: settings.glass || "liquid"
  readonly property string windowTitles: settings.windowTitles || "hover"
  readonly property bool showIcons: settings.appIcons !== false
  readonly property bool showCloseButtons: settings.closeButtons !== false
  readonly property bool grouped: mission && settings.groupByApp === true
  readonly property color highlight: service ? service.highlight : "#0a84ff"
  readonly property string uiFont: service ? service.uiFont : ""
  readonly property real windowRounding: service ? service.decor.rounding : 0
  readonly property alias stage: stage
  readonly property alias spacesBar: spacesBar
  readonly property alias screenCapture: screenGhost
  readonly property alias glassBackdrop: glassBackdrop

  // The stage is the display's size, whatever size the window has just
  // then (see below).
  readonly property real stageWidth: monitor ? monitor.w : width
  readonly property real stageHeight: monitor ? monitor.h : height

  // The screen's edges the stage leaves uncovered: the room Hyprland keeps
  // for the top bar (and a dock), unless the stage is set to cover the bar.
  // Numbers first, so the edges change only when one of them does, not with
  // every read of Hyprland's state.
  readonly property bool keepBar: settings.keepBar !== false
  readonly property real edgeTop: keepBar && monitor && monitor.reserved ? monitor.reserved.top : 0
  readonly property real edgeLeft: keepBar && monitor && monitor.reserved ? monitor.reserved.left : 0
  readonly property real edgeRight: keepBar && monitor && monitor.reserved ? monitor.reserved.right : 0
  readonly property real edgeBottom: keepBar && monitor && monitor.reserved ? monitor.reserved.bottom : 0
  readonly property var edges: ({ top: edgeTop, left: edgeLeft, right: edgeRight, bottom: edgeBottom })

  // The window stays up while the stage is closed: one made afresh for every
  // opening spent about 100 ms on its first frame, so a swipe's stage
  // appeared only when the fingers were well on their way. Closed, it's a
  // single transparent pixel in the corner that takes no input; opening
  // stretches it over the screen.
  visible: !!service
  color: "transparent"
  anchors {
    top: true
    left: true
    bottom: drawn
    right: drawn
  }
  implicitWidth: 1
  implicitHeight: 1
  // Input only where the stage is: the top bar's clicks go to the bar.
  mask: Region {
    x: win.showsHere ? win.edges.left : 0
    y: win.showsHere ? win.edges.top : 0
    width: win.showsHere ? Math.max(0, win.stageWidth - win.edges.left - win.edges.right) : 0
    height: win.showsHere ? Math.max(0, win.stageHeight - win.edges.top - win.edges.bottom) : 0
  }
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "marcho78-stage-control"
  WlrLayershell.layer: service && service.testMode ? WlrLayer.Background : WlrLayer.Overlay
  WlrLayershell.keyboardFocus: showsHere && !!service && !service.testMode && monitor.focused
    ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  function smooth(edge0, edge1, x) {
    var t = Math.max(0, Math.min(1, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
  }

  // ---- warming up ------------------------------------------------------------------
  //
  // Opening the stage the first time also makes its textures: the
  // wallpaper, its blur, the glass's backdrop. So once the shell has
  // settled, and again when the wallpaper changes, the stage draws itself
  // for a moment while closed, as it does while preparing (unseen, at
  // 1/250 opacity, taking no input), and keeps them for its first opening.
  property bool warming: false
  readonly property bool drawn: showsHere || warming

  function warmUp() {
    if (showsHere || !monitor) return
    warming = true
    warmTimer.restart()
  }

  Timer {
    id: warmTimer
    interval: 250
    onTriggered: win.warming = false
  }

  Component.onCompleted: if (service) service.registerOverview(screenName, win)
  Component.onDestruction: if (service) service.unregisterOverview(screenName, win)

  // ---- model ----------------------------------------------------------------------

  property var tileIds: []
  property var tileData: ({})
  property var groups: []
  property var placed: ({})
  property var windowsByAddress: ({})
  property var desktopIds: []
  property var desktopData: ({})
  property var minimizedIds: []
  property string hoverAddress: ""
  property string selectedAddress: ""
  property bool forceExpanded: false

  function windowFor(address) {
    return windowsByAddress[address] || null
  }

  // The model above as JSON, by property name. A value is handed out only
  // when it changed, so a refresh that finds everything as it was (most of
  // them, since Hyprland's events often change nothing on the stage)
  // re-evaluates no tile's or thumbnail's bindings.
  property var modelJson: ({})
  function setModel(name, value) {
    var json = JSON.stringify(value)
    if (modelJson[name] === json) return
    modelJson[name] = json
    win[name] = value
  }

  readonly property real barSpace: mission ? spacesBar.reservedHeight : 0
  // The bar's size follows the number of desktops, which rebuild() itself
  // sets, so lay out again after the change rather than inside it, and only
  // if the layout didn't already leave room for the new size.
  property real layoutBarSpace: -1
  onBarSpaceChanged: Qt.callLater(relayoutForBar)
  function relayoutForBar() {
    if (barSpace !== layoutBarSpace) rebuild()
  }
  onStageWidthChanged: rebuild()
  onStageHeightChanged: rebuild()
  onShowsHereChanged: {
    // The window stays up between openings, so the keys come back here.
    if (showsHere) Qt.callLater(focusKeys)
    hoverAddress = ""
    selectedAddress = ""
    cancelDrag()
    spacesBar.commitRename()
    spacesBar.cancelDesktopDrag()
    // Where windows were on the last opening's screen capture: not this one's.
    if (!showsHere) ghostRects = ({})
    // A new opening starts on its desktop; it doesn't slide there.
    if (!showsHere) endSlide()
    rebuild()
    // Shown on a stage that is already open (App Exposé on another display
    // turned into the stage): its capture is being taken now.
    if (showsHere && service && service.revealed) takeGhostRects()
  }

  Connections {
    target: win.service
    function onSnapVersionChanged() { win.rebuild() }
    function onModeChanged() { win.rebuild() }
    function onExposeClassChanged() { win.rebuild() }
    function onPinnedVersionChanged() { win.rebuildDesktops() }
    function onSettingsChanged() { win.rebuild() }
  }

  // Only the stage has a Spaces bar. App Exposé hides it, so it keeps no
  // desktops (and their thumbnails capture no windows). While the stage is
  // closed the thumbnails stay, as the tiles do (see rebuild()).
  function rebuildDesktops() {
    if (!service || !service.shown) return
    if (!stageHere() || service.mode !== "mission") {
      setModel("desktopIds", [])
      setModel("desktopData", {})
      return
    }
    var list = service.desktopsFor(screenName)
    var data = {}
    list.forEach(function(desktop) { data[desktop.id] = desktop })
    // The Spaces bar's size follows the number of desktops, and the windows'
    // layout follows the bar's: it gets a new list only when the desktops
    // changed (setModel), so a layout pass can't set off another.
    setModel("desktopIds", list.map(function(desktop) { return desktop.id }))
    setModel("desktopData", data)
  }

  // While the stage is closed, the tiles and thumbnails are kept for the next
  // opening (their captures stop with showsHere), which then updates them
  // instead of building every one of them again. Not while it's up on
  // another display only (App Exposé shows on one): kept tiles here would
  // follow every frame of its animations for nothing.
  //
  // rebuild() and rebuildDesktops() run from change handlers, some of them
  // before the bindings that follow the same change (showsHere, mission,
  // barSpace, the settings above), and a stale one would throw away tiles
  // and thumbnails that should stay. So they read the service directly.
  function stageHere() {
    if (!service || !service.shown || !service.snap) return null
    var shownOn = Model.monitorByName(service.snap, screenName)
    return shownOn && (service.mode === "mission" || shownOn.focused) ? shownOn : null
  }

  function rebuild() {
    if (!service || !service.shown) return
    // The service's own, rather than the bindings of the same names.
    var snap = service.snap
    var monitor = stageHere()
    var settings = service.settings || {}
    if (!monitor) {
      slideFromDesktop = 0
      setModel("tileIds", [])
      setModel("tileData", {})
      setModel("groups", [])
      setModel("placed", {})
      setModel("minimizedIds", [])
      rebuildDesktops()
      return
    }
    var width = monitor.w
    var height = monitor.h
    if (width <= 0 || height <= 0) return
    // The edges left uncovered, as `edges` (read here for the same reason).
    var edge = settings.keepBar !== false && monitor.reserved ? monitor.reserved : { top: 0, left: 0, right: 0, bottom: 0 }
    var byAddress = {}
    snap.windows.forEach(function(w) { byAddress[w.address] = w })
    setModel("windowsByAddress", byAddress)
    // Desktops first: the Spaces bar, which the windows leave room for, is
    // sized by how many there are.
    rebuildDesktops()

    var expose = service.mode === "expose"
    var mission = service.mode === "mission"
    var windows = expose ? Model.appWindows(snap, service.exposeClass) : Model.visibleWindows(snap, monitor)
    var minimized = expose && settings.showMinimized !== false ? Model.minimizedWindows(snap, service.exposeClass) : []

    var side = Math.round(Math.max(40, width * 0.045))
    var bar = mission ? spacesBar.reservedHeight : 0
    layoutBarSpace = bar
    var top = edge.top + (expose ? 96 : bar + 26)
    var bottom = edge.bottom + (minimized.length ? Math.round(height * 0.2) + 40 : 64)
    var area = { x: edge.left + side, y: top, w: Math.max(100, width - edge.left - edge.right - side * 2), h: Math.max(100, height - top - bottom) }

    var items = windows.map(function(w) {
      var home = Model.monitorById(snap, w.monitor) || monitor
      return { id: w.address, x: w.x - home.x, y: w.y - home.y, w: w.w, h: w.h, group: w.cls }
    })
    // Titles shown on every window hang below it, so rows leave them room:
    // WindowTile's 26px pill, under the app icon (at most 44px, half of it
    // below the edge) when icons are on.
    var titleSpace = (settings.windowTitles || "hover") === "always" ? (settings.appIcons !== false ? 22 + 6 : 10) + 26 : 0
    var spreadOptions = { gap: Math.round(Math.max(20, width * 0.022)), maxScale: 0.84,
      groupByApp: mission && settings.groupByApp === true, labelSpace: 46, titleSpace: titleSpace }
    var result = Layout.spread(items, area, spreadOptions)

    var minimizedArea = { x: edge.left + side, y: height - edge.bottom - Math.round(height * 0.2) - 24,
      w: width - edge.left - edge.right - side * 2, h: Math.round(height * 0.2) }
    var minimizedResult = minimized.length
      ? Layout.spread(minimized.map(function(w) { return { id: w.address, x: w.x, y: w.y, w: w.w, h: w.h } }), minimizedArea, { gap: 20, maxScale: 0.3 })
      : { windows: {} }

    var data = {}
    var ids = []
    var rects = {}
    windows.forEach(function(w, index) {
      var to = result.windows[w.address]
      if (!to) return
      var onScreen = w.monitor === monitor.id && (w.pinned || w.workspace === monitor.activeWorkspace
        || (monitor.specialWorkspace !== 0 && w.workspace === monitor.specialWorkspace))
      var from = onScreen ? Model.localRect(w, monitor)
        : { x: to.x + to.w * 0.04, y: to.y + to.h * 0.04 + 30, w: to.w * 0.92, h: to.h * 0.92 }
      var app = service.appFor(w.cls)
      data[w.address] = {
        address: w.address, title: w.title, initialTitle: w.initialTitle, cls: w.cls, icon: app.icon, appName: app.name,
        from: from, to: to, size: { w: w.w, h: w.h }, onScreen: onScreen, minimized: false,
        workspace: w.workspace, z: (w.floating ? 200 : 0) + (windows.length - index)
      }
      ids.push(w.address)
      rects[w.address] = to
    })
    var minIds = []
    minimized.forEach(function(w) {
      var to = minimizedResult.windows[w.address]
      if (!to) return
      var app = service.appFor(w.cls)
      data[w.address] = {
        address: w.address, title: w.title, initialTitle: w.initialTitle, cls: w.cls, icon: app.icon, appName: app.name,
        from: { x: to.x, y: to.y + 60, w: to.w, h: to.h }, to: to, size: { w: w.w, h: w.h },
        onScreen: false, minimized: true, workspace: w.workspace, z: 0
      }
      ids.push(w.address)
      minIds.push(w.address)
      rects[w.address] = to
    })

    // A window's title bar and border can come from the screen capture only
    // if no window above it covers them.
    var d = service.decor
    function decorated(rect) {
      return { x: rect.x - d.border, y: rect.y - d.border - d.bar, w: rect.w + d.border * 2, h: rect.h + d.border * 2 + d.bar }
    }
    function intersects(a, b) {
      return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
    }
    ids.forEach(function(address) {
      var info = data[address]
      if (!info.onScreen) return
      var mine = decorated(info.from)
      info.ghost = !ids.some(function(other) {
        var above = data[other]
        return other !== address && above.onScreen && above.z > info.z && intersects(mine, decorated(above.from))
      })
    })

    // The desktop on screen changed while the stage is open: slide to it.
    // After a swipe, from where the fingers left everything.
    var active = monitor.activeWorkspace
    if (peekTarget !== 0 && active === peekTarget) {
      rebaseAfterSwipe()
      slideFromDesktop = active
    }
    if (mission && slideFromDesktop !== 0 && active !== slideFromDesktop && slideAllowed())
      beginSlide(slideFromDesktop, active, width, data)
    slideFromDesktop = mission ? active : 0
    // Windows still sliding out stay on the stage until they're gone; only
    // where they'll be, not where they are now, so none of them can be
    // picked from the keyboard.
    for (var leavingAddress in leavingData) {
      if (data[leavingAddress]) continue
      data[leavingAddress] = leavingData[leavingAddress]
      ids.push(leavingAddress)
    }
    // The other desktops' windows wait off the screen's edges, a page
    // apart, laid out as they'd be on the stage, for a swipe to bring in
    // (see "swiping between desktops").
    if (peeksReady && mission) {
      var order = service.desktopsFor(screenName).map(function(desktop) { return desktop.id })
      peekOrder = order
      peekAt = Math.max(0, order.indexOf(active))
      var limits = pageLimits()
      var sides = {}
      for (var page = limits.low; page <= limits.high; page++) {
        if (page !== 0 && order[peekAt + page] !== undefined) sides[order[peekAt + page]] = page
      }
      peekDesktops = sides
      for (var peekId in peekDesktops) {
        var peekPage = peekDesktops[peekId]
        var peekWindows = Model.desktopWindows(snap, monitor, Number(peekId))
        var peekResult = Layout.spread(peekWindows.map(function(w) {
          var home = Model.monitorById(snap, w.monitor) || monitor
          return { id: w.address, x: w.x - home.x, y: w.y - home.y, w: w.w, h: w.h, group: w.cls }
        }), area, spreadOptions)
        peekWindows.forEach(function(w, index) {
          var to = peekResult.windows[w.address]
          if (!to || data[w.address]) return
          var app = service.appFor(w.cls)
          data[w.address] = {
            address: w.address, title: w.title, initialTitle: w.initialTitle, cls: w.cls, icon: app.icon, appName: app.name,
            from: to, to: to, size: { w: w.w, h: w.h }, onScreen: false, minimized: false,
            workspace: w.workspace, z: (w.floating ? 200 : 0) + (peekWindows.length - index),
            peek: true, peekPage: peekPage
          }
          ids.push(w.address)
        })
      }
    }

    setModel("groups", result.groups.map(function(group) {
      var app = service.appFor(group.key)
      return { key: group.key, x: group.x, y: group.y, w: group.w, h: group.h, icon: app.icon, name: app.name }
    }))
    setModel("tileData", data)
    setModel("tileIds", ids)
    setModel("placed", rects)
    setModel("minimizedIds", minIds)
    startSlideIns()
    if (selectedAddress && (!data[selectedAddress] || data[selectedAddress].leaving)) selectedAddress = ""
    if (hoverAddress && (!data[hoverAddress] || data[hoverAddress].leaving)) hoverAddress = ""
  }

  // ---- sliding desktops ------------------------------------------------------------
  //
  // Going to another desktop while the stage is open (Ctrl+←/→, Super+3, a
  // swipe, the top bar's workspaces) turns the page, like macOS: the
  // desktop that was on screen slides out to one side, its windows with it,
  // and the new one's windows come in from the other, toward the desktop's
  // place in the Spaces bar. Without this the old windows simply vanished
  // and the new ones appeared in their place.
  //
  // The tiles that leave stay on the stage, out of the keyboard's and the
  // pointer's way, until they're gone (leavingData, merged in by rebuild()).

  // The desktop the stage showed at its last layout; 0 when it isn't up.
  property int slideFromDesktop: 0
  property var leavingData: ({})
  // Tiles still to start sliding in, by address: where they start from.
  property var pendingSlideIns: ({})
  // App names under grouped windows ride in with them.
  property real groupSlideX: 0
  readonly property int baseSlideDuration: Math.round(440 / (service ? service.speedFactor : 1))
  readonly property int slideDuration: baseSlideDuration
  // How far a desktop slides: the screen's width and a gap.
  readonly property real pageShift: stageWidth + 40

  // Only on a stage that is open and still: not while it opens or closes,
  // follows the fingers, or with reduced motion (which fades everything).
  function slideAllowed() {
    return !!service && service.revealed && !service.closing && !service.tracking && service.progress >= 0.99
      && !(service.settings && service.settings.reduceMotion)
  }

  function beginSlide(fromDesktop, toDesktop, distance, newData) {
    // Toward a desktop to the right, everything moves left, and back.
    var order = service.desktopsFor(screenName).map(function(desktop) { return desktop.id })
    var a = order.indexOf(fromDesktop), b = order.indexOf(toDesktop)
    var direction = (a >= 0 && b >= 0 ? b - a : toDesktop - fromDesktop) > 0 ? 1 : -1
    var shift = pageShift

    // Out: every window on the stage that isn't on the new desktop. One
    // already on its way out keeps going where it was going: sent the
    // other way, it would cross the whole screen.
    var leaving = {}
    tileIds.forEach(function(address) {
      var info = tileData[address]
      if (!info || info.minimized || info.peek || newData[address]) return
      if (leavingData[address]) {
        leaving[address] = leavingData[address]
        return
      }
      var copy = JSON.parse(JSON.stringify(info))
      copy.leaving = true
      leaving[address] = copy
      var tile = tileItems[address]
      if (tile) tile.slideTo(-direction * shift, slideDuration)
    })
    // In: the new desktop's windows that weren't on the stage, or were on
    // their way out (switching back mid-slide turns them around).
    var pending = {}
    Object.keys(newData).forEach(function(address) {
      if (tileData[address] && !leavingData[address] && !tileData[address].peek) return
      pending[address] = direction * shift
    })
    // Windows that waited off screen for a swipe come in from the edge, not
    // from as many pages away as their desktop was.
    for (var waiting in pending) {
      var info = tileData[waiting]
      var tile = tileItems[waiting]
      if (info && info.peek && tile) tile.placeAt(direction * shift)
    }
    leavingData = leaving
    pendingSlideIns = pending
    hoverAddress = ""
    selectedAddress = ""
    groupSlideAnimation.stop()
    groupSlideX = direction * shift
    groupSlideAnimation.duration = slideDuration
    groupSlideAnimation.start()
    slideEndTimer.interval = slideDuration + 60
    slideEndTimer.restart()
  }

  // After the new tiles exist: each starts its way in. One coming back
  // from its way out turns around where it is.
  function startSlideIns() {
    for (var address in pendingSlideIns) {
      var tile = tileItems[address]
      if (!tile) continue
      tile.slideIn(pendingSlideIns[address], slideDuration)
      delete pendingSlideIns[address]
    }
  }

  // For a tile made after startSlideIns(): where it starts, if it slides in.
  function takeSlideIn(address) {
    if (pendingSlideIns[address] === undefined) return undefined
    var offset = pendingSlideIns[address]
    delete pendingSlideIns[address]
    return offset
  }

  function endSlide() {
    resetPeek()
    slideFromDesktop = 0
    slideEndTimer.stop()
    groupSlideAnimation.stop()
    groupSlideX = 0
    leavingData = ({})
    pendingSlideIns = ({})
  }

  // ---- swiping between desktops ------------------------------------------------------
  //
  // The desktop swipe on the open stage (Service, "swiping between
  // desktops"). The stage's desktops sit side by side, a page (pageShift)
  // apart, and move together with the fingers: trackX, a shift every tile
  // adds to its own. beginPeek() lays out the desktops beside this one off
  // the screen's edges, and peekTo() more of them as the fingers go on (as
  // far as Hyprland's workspace_swipe_forever lets its own swipe go).
  // endPeek() settles on a desktop, or back on this one, by the rules of
  // Hyprland's swipe, and slides there at once.
  //
  // Hyprland is told to go there only once the stage has: switching, it
  // animates its own workspaces under the stage, which costs frames, and the
  // stage would wait on it. Then the stage takes the new desktop as its own
  // (rebaseAfterSwipe), with nothing moving on screen.

  property bool peeking: false
  // Desktop id: its place, in pages from this desktop (..., -1, 1, 2, ...).
  // Kept by rebuild() once peeksReady.
  property var peekDesktops: ({})
  property var peekOrder: []
  property int peekAt: 0
  property real trackX: 0
  property real peekPages: 0
  // Where the swipe settles, in pages; and the desktop there, once the
  // stage is there and Hyprland is going.
  property int peekTargetPage: 0
  property int peekTarget: 0
  // Anything sliding: the windows' live previews wait meanwhile
  // (WindowTile), as they do while the stage opens.
  readonly property bool moving: peeking || peekAnimation.running || slideEndTimer.running

  // The other desktops' windows are laid out once the stage has opened and
  // settled, off screen with one picture each (WindowTile.peek), so a swipe
  // only has to move them: made as the fingers reached them, they cost the
  // swipe a frame or two each time. They're drawn where they wait, out of
  // sight, rather than hidden: hidden, a window drew its preview for the
  // first time on the first frame of the swipe, which held that frame up.
  property bool peeksReady: false
  Timer {
    interval: 250
    running: win.showsHere && win.mission && win.settled && !win.peeksReady
    onTriggered: {
      win.peeksReady = true
      win.rebuild()
    }
  }

  function beginPeek() {
    if (!mission || !monitor || peekTarget !== 0 || peekAnimation.running || !slideAllowed()) return false
    if (!peeksReady) {
      peeksReady = true
      rebuild()
    }
    if (peekOrder.indexOf(monitor.activeWorkspace) < 0) return false
    peeking = true
    peekPages = 0
    peekTargetPage = 0
    trackX = 0
    hoverAddress = ""
    selectedAddress = ""
    // Each waits a page per desktop away. (Its picture is from when the
    // stage last stood still: new pictures for them all at once, here, cost
    // the swipe its first frame.)
    refreshQueue = []
    for (var address in tileData) {
      var info = tileData[address]
      var tile = tileItems[address]
      if (info.peek && tile) tile.placeAt(info.peekPage * pageShift)
    }
    return true
  }

  // The pages the swipe can reach: to either end, or one either way when
  // Hyprland's own swipe stops at one.
  function pageLimits() {
    var low = -peekAt, high = peekOrder.length - 1 - peekAt
    if (!(service && service.swipeConfig.forever)) {
      low = Math.max(low, -1)
      high = Math.min(high, 1)
    }
    return { low: low, high: high }
  }

  // `pages`: how far the fingers have gone, in desktops, toward the next.
  // Past the last desktop the stage gives a little and holds.
  function peekTo(pages) {
    if (!peeking || peekTarget !== 0 || peekAnimation.running) return
    var limits = pageLimits()
    var shown = pages > limits.high ? limits.high + 0.12 * (1 - 1 / (1 + (pages - limits.high) * 4))
      : pages < limits.low ? limits.low - 0.12 * (1 - 1 / (1 + (limits.low - pages) * 4))
      : pages
    peekPages = shown
    trackX = -shown * pageShift
  }

  // Where the fingers let go (`pages`), their average speed per step toward
  // the next desktop (`speed`), and whether Hyprland called the swipe off.
  // Like Hyprland: from the last desktop passed, fast enough goes on to the
  // next, else past the cancel ratio does, else it stays.
  function endPeek(pages, speed, cancelled) {
    if (!peeking || peekTarget !== 0 || peekAnimation.running) return
    var limits = pageLimits()
    var at = Math.max(limits.low, Math.min(limits.high, pages))
    var passed = at >= 0 ? Math.floor(at) : Math.ceil(at)
    var part = at - passed
    var config = service.swipeConfig
    var page = passed
    if (cancelled) page = 0
    else if (config.minSpeed > 0 && Math.abs(speed) >= config.minSpeed) {
      if (part === 0 || (part > 0) === (speed > 0)) page = passed + (speed > 0 ? 1 : -1)
    } else if (Math.abs(part) > config.cancelRatio) {
      page = passed + (part > 0 ? 1 : -1)
    }
    page = Math.max(limits.low, Math.min(limits.high, page))
    slideToPage(page)
  }

  // Slides to `page`, as long as the part of a page left would take.
  function slideToPage(page) {
    peekTargetPage = page
    peekAnimation.stop()
    peekAnimation.to = -page * pageShift
    peekAnimation.duration = Math.round(baseSlideDuration * Math.max(0.3, Math.min(1, Math.abs(trackX / pageShift + page))))
    peekAnimation.start()
  }

  // Settled. Back here, the desktops beside go; elsewhere, Hyprland goes too.
  function peekSettled() {
    peekPages = -trackX / pageShift
    if (peekTargetPage === 0) {
      stopPeeking()
      trackX = 0
      rebuild()
      refreshPeeks()
      return
    }
    peekTarget = peekOrder[peekAt + peekTargetPage]
    peekGiveUp.restart()
    service.focusDesktop(peekTarget)
  }

  // Hyprland is on the desktop the stage slid to: it becomes the stage's
  // own. Every tile takes the swipe's shift less a page per page gone, and
  // the swipe's shift goes to 0, so nothing moves on screen; the desktops
  // left behind are off screen and simply go.
  function rebaseAfterSwipe() {
    var shift = peekTargetPage * pageShift
    for (var address in tileItems) tileItems[address].shiftBy(-shift)
    trackX += shift
    stopPeeking()
    Qt.callLater(refreshPeeks)
  }

  // New pictures for the waiting windows while the stage stands still, one
  // window every few frames, so the next swipe shows them as they are.
  property var refreshQueue: []
  function refreshPeeks() {
    var queue = []
    for (var address in tileData) if (tileData[address].peek) queue.push(address)
    refreshQueue = queue
  }
  Timer {
    interval: 40
    repeat: true
    running: win.refreshQueue.length > 0 && !win.moving
    onTriggered: {
      var queue = win.refreshQueue.slice()
      var tile = win.tileItems[queue.shift()]
      win.refreshQueue = queue
      if (tile && tile.peek) tile.refreshPreview()
    }
  }

  function stopPeeking() {
    peekGiveUp.stop()
    peeking = false
    peekTarget = 0
    peekTargetPage = 0
  }

  function resetPeek() {
    peekAnimation.stop()
    stopPeeking()
    peeksReady = false
    peekDesktops = ({})
    trackX = 0
    peekPages = 0
  }

  NumberAnimation {
    id: peekAnimation
    target: win
    property: "trackX"
    easing.type: Easing.OutCubic
    onFinished: if (win.peeking) win.peekSettled()
  }

  // Hyprland never went to the desktop (it's gone, say): back home.
  Timer {
    id: peekGiveUp
    interval: 1500
    onTriggered: {
      win.peekTarget = 0
      win.slideToPage(0)
    }
  }

  NumberAnimation {
    id: groupSlideAnimation
    target: win
    property: "groupSlideX"
    to: 0
    easing.type: Easing.OutCubic
  }

  Timer {
    id: slideEndTimer
    onTriggered: {
      win.leavingData = ({})
      win.pendingSlideIns = ({})
      win.rebuild()
    }
  }

  // ---- tiles ------------------------------------------------------------------------

  property var tileItems: ({})

  // Where each on-screen window was when the screen was captured. Its title
  // bar and border only come from the capture while it is still there.
  property var ghostRects: ({})

  function takeGhostRects() {
    var rects = {}
    for (var address in tileData) {
      var info = tileData[address]
      if (info.onScreen) rects[address] = info.from
    }
    ghostRects = rects
  }

  Connections {
    target: win.service
    function onRevealedChanged() { if (win.service.revealed) win.takeGhostRects() }
  }

  // Counts tiles coming and going, so a binding that looks a tile up
  // (tileFor) follows them.
  property int tileRevision: 0

  function registerTile(address, item) {
    tileItems[address] = item
    tileRevision++
  }
  function unregisterTile(address, item) {
    if (tileItems[address] !== item) return
    delete tileItems[address]
    tileRevision++
  }
  function tileFor(address) {
    tileRevision
    return tileItems[address] || null
  }

  // Ready to show once every preview has a frame (the service stops waiting
  // after a moment either way).
  Timer {
    interval: 16
    repeat: true
    running: win.showsHere && !!win.service && !win.service.revealed
    onTriggered: {
      if (!win.snap) return
      for (var i = 0; i < win.tileIds.length; i++) {
        var item = win.tileItems[win.tileIds[i]]
        if (!item || !item.hasContent) return
      }
      if (!screenGhost.hasContent) return
      if (wallpaperImage.status === Image.Loading) return
      win.service.markReady(win.screenName)
    }
  }

  function activate(address) {
    var info = tileData[address]
    if (!info || !service.interactive) return
    if (info.minimized) {
      service.restoreWindow(address, monitor.activeWorkspace)
      service.close({ address: address, noFocus: true })
    } else {
      service.close({ address: address })
    }
  }

  // how: "button" (the ×), "middle" (middle-click) or "key" (Ctrl+W).
  function closeWindow(address, how) {
    if (how === "middle" && settings.middleClickClose === false) return
    if (how === "button" && settings.closeButtons === false) return
    var tile = tileItems[address]
    if (!tile || !service.interactive) return
    tile.markClosing()
    service.closeWindow(address)
  }

  // ---- dragging windows ----------------------------------------------------------------

  property string dragAddress: ""
  property point dragPoint: Qt.point(0, 0)
  property point dragGrab: Qt.point(0.5, 0.5)
  property var dropTarget: null
  readonly property bool dragging: dragAddress !== ""
  // Windows shrink as they near the Spaces bar, like on macOS.
  readonly property real dragShrink: {
    var near = spacesBar.y + spacesBar.height + 170
    return 1 - 0.62 * smooth(0, 1, (near - dragPoint.y) / 170)
  }

  function beginDrag(address, point) {
    if (!mission || tileData[address] && tileData[address].minimized) return
    dragAddress = address
    dragPoint = point
    hoverAddress = ""
    selectedAddress = ""
  }

  function moveDrag(point) {
    dragPoint = point
    dropTarget = spacesBar.targetAt(point)
  }

  function endDrag(point) {
    var address = dragAddress
    var target = spacesBar.targetAt(point)
    var tile = tileItems[address]
    var info = tileData[address]
    var rect = spacesBar.rectFor(target)
    var moves = !!target && !(target.kind === "desktop" && target.id === monitor.activeWorkspace)
    // Start the flight from where the window was let go, before the drag
    // state (which positions it) is cleared.
    if (tile && moves && rect) tile.flyTo(rect, true)
    else if (tile && info) tile.flyTo(info.to, false)
    dragAddress = ""
    dropTarget = null
    if (!moves) return
    if (target.kind === "desktop") service.moveWindowToDesktop(address, target.id, screenName)
    else service.moveWindowToNewDesktop(address, screenName)
  }

  function cancelDrag() {
    var tile = tileItems[dragAddress]
    var info = tileData[dragAddress]
    if (tile && info) tile.flyTo(info.to, false)
    dragAddress = ""
    dropTarget = null
  }

  // ---- keyboard ---------------------------------------------------------------------------

  // The windows the keyboard can pick: those placed on the stage, not ones
  // sliding away or waiting off screen for a swipe.
  function pickable() {
    return tileIds.filter(function(address) { return !!placed[address] })
  }

  function step(direction) {
    var from = selectedAddress || hoverAddress
    if (!from || !placed[from]) {
      var ids = pickable()
      selectedAddress = ids.length ? ids[0] : ""
      return
    }
    var next = Layout.neighbor(placed, from, direction)
    if (next) selectedAddress = next
  }

  function cycle(forward) {
    var ordered = pickable()
    if (ordered.length === 0) return
    ordered.sort(function(a, b) {
      var ra = placed[a], rb = placed[b]
      return Math.abs(ra.y - rb.y) > 20 ? ra.y - rb.y : ra.x - rb.x
    })
    var index = ordered.indexOf(selectedAddress || hoverAddress)
    index = index < 0 ? (forward ? 0 : ordered.length - 1) : (index + (forward ? 1 : -1) + ordered.length) % ordered.length
    selectedAddress = ordered[index]
  }

  // Keys come back here after a desktop's name has been edited.
  function focusKeys() { keys.forceActiveFocus() }

  function handleKey(event) {
    if (!service || !service.shown) return
    var key = event.key
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    event.accepted = true
    if (key === Qt.Key_Escape) service.close({})
    else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space) {
      var target = selectedAddress || hoverAddress
      if (target) activate(target)
      else service.close({})
    } else if (ctrl && key === Qt.Key_W) {
      var closing = selectedAddress || hoverAddress
      if (closing) closeWindow(closing, "key")
    } else if (ctrl && key === Qt.Key_Left) service.stepDesktop(-1)
    else if (ctrl && key === Qt.Key_Right) service.stepDesktop(1)
    else if (key === Qt.Key_Left) step("left")
    else if (key === Qt.Key_Right) step("right")
    else if (key === Qt.Key_Up) step("up")
    else if (key === Qt.Key_Down) step("down")
    else if (key === Qt.Key_Tab) cycle(true)
    else if (key === Qt.Key_Backtab) cycle(false)
    else if (key >= Qt.Key_1 && key <= Qt.Key_9 && mission) {
      var desktop = desktopIds[key - Qt.Key_1]
      if (desktop !== undefined) service.close({ desktop: desktop })
    } else event.accepted = false
  }

  // ---- drawing ------------------------------------------------------------------------------

  // The stage, cut to what it covers: the edges it leaves alone show the
  // screen itself (the top bar), not the stage's wallpaper. Nothing at all
  // is drawn while it's closed.
  Item {
    id: canvas
    x: win.edges.left
    y: win.edges.top
    width: Math.max(0, win.stageWidth - win.edges.left - win.edges.right)
    height: Math.max(0, win.stageHeight - win.edges.top - win.edges.bottom)
    clip: win.edges.left + win.edges.top + win.edges.right + win.edges.bottom > 0
    visible: win.drawn

    Item {
      id: stage
      // The whole display, so everything on the stage is placed in the
      // display's own coordinates.
      x: -win.edges.left
      y: -win.edges.top
      width: win.stageWidth
      height: win.stageHeight
      // Nothing shows until the previews are ready (see `preparing`); then it
      // matches the screen.
      opacity: !win.service ? 0 : win.service.revealed ? (win.reduceMotion ? win.p : 1) : 0.004

      // The wallpaper, blurring and dimming as the stage opens. One pass
      // (shaders/backdrop.frag) draws what used to be three full-screen layers
      // on top of each other, the wallpaper, its blur fading in and the dim,
      // and draws it the same: the frames of the animation cost one pass, not
      // three, and nothing needs caching once the stage has settled.
      Item {
        id: backdrop
        anchors.fill: parent

        readonly property bool blurs: win.settings.background !== "dim"
        readonly property real dim: (win.settings.dim === undefined ? 25 : win.settings.dim) / 100
        readonly property vector4d crop: cropFor(wallpaperImage.implicitWidth, wallpaperImage.implicitHeight, width, height)

        // The part of a pw x ph image that PreserveAspectCrop shows in a
        // w x h item, as QQuickImage works it out: centered, in whole pixels.
        function cropFor(pw, ph, w, h) {
          if (!(pw > 0 && ph > 0 && w > 0 && h > 0)) return Qt.vector4d(0, 0, 1, 1)
          var wscale = w / pw, hscale = h / ph
          if (wscale > hscale) {
            var rows = Math.trunc(hscale / wscale * ph)
            return Qt.vector4d(0, Math.ceil((ph - rows) / 2) / ph, 1, rows / ph)
          }
          var columns = Math.trunc(wscale / hscale * pw)
          return Qt.vector4d(Math.ceil((pw - columns) / 2) / pw, 0, columns / pw, 1)
        }

        // Loaded the way Omarchy's own background loads the same file: off the
        // shell's main thread (so a slow or never-ending file can't stall the
        // shell) and from the shared image cache. Drawn by the pass below.
        Image {
          id: wallpaperImage
          anchors.fill: parent
          visible: false
          source: win.service ? win.service.wallpaperUrl : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
          smooth: true
        }

        // The blur itself never changes, only how much of it shows: rendered
        // once, at half the size (it's a blur), into a layer the pass below
        // fades in.
        MultiEffect {
          id: blurLayer
          anchors.fill: parent
          source: wallpaperImage
          visible: false
          blurEnabled: true
          blurMax: 64
          blur: 1.0
          saturation: 0.25
          autoPaddingEnabled: false
          layer.enabled: true
          layer.smooth: true
          layer.textureSize: Qt.size(Math.max(1, Math.round(width / 2)), Math.max(1, Math.round(height / 2)))
        }

        ShaderEffect {
          anchors.fill: parent
          property var wallpaper: wallpaperImage
          // With the dim background there's no blur to draw (or to render).
          property var blurred: backdrop.blurs ? blurLayer : wallpaperImage
          property vector4d crop: backdrop.crop
          // The blur showed only above 1% (below that it wasn't drawn at all).
          readonly property real blurShown: win.preparing ? 0.5 : win.smooth(0, 0.6, win.e)
          property real blurAmount: backdrop.blurs && blurShown > 0.01 ? blurShown : 0
          property real dim: backdrop.dim * win.e
          fragmentShader: Qt.resolvedUrl("shaders/backdrop.frag.qsb")
        }

        // The backdrop as it is on the open stage, for the Liquid Glass panes
        // (glassBackdrop below). It doesn't follow the animation, so the panes
        // show the stage's own backdrop from their first frame, and nothing has
        // to be taken again when the stage settles.
        ShaderEffect {
          id: settledBackdrop
          anchors.fill: parent
          visible: false
          property var wallpaper: wallpaperImage
          property var blurred: backdrop.blurs ? blurLayer : wallpaperImage
          property vector4d crop: backdrop.crop
          property real blurAmount: backdrop.blurs ? 1 : 0
          property real dim: backdrop.dim
          fragmentShader: Qt.resolvedUrl("shaders/backdrop.frag.qsb")
        }
      }

      // The open stage's backdrop as one texture, for the Liquid Glass panes
      // to refract. Half resolution with mipmaps: the panes read it frosted
      // anyway. It changes only with the wallpaper or the settings, so it's
      // rendered once while the stage prepares, not while it moves.
      ShaderEffectSource {
        id: glassBackdrop
        sourceItem: settledBackdrop
        textureSize: Qt.size(Math.max(1, Math.round(win.stageWidth / 2)), Math.max(1, Math.round(win.stageHeight / 2)))
        live: true
        mipmap: true
        hideSource: false
        visible: false
      }

      // The screen as it was when the overlay appeared. The bar (and anything
      // else Hyprland reserves room for) slides away from it, and each window's
      // title bar and border ride along with the window and fade, so nothing
      // blinks out when the stage takes over the screen.
      ScreencopyView {
        id: screenGhost
        readonly property var reserved: win.monitor ? win.monitor.reserved : null
        readonly property bool wanted: !!reserved && (reserved.top + reserved.bottom + reserved.left + reserved.right) > 0
        readonly property real fade: win.smooth(0, 0.35, win.p)
        anchors.fill: parent
        // One frame per opening: set when the overlay appears, cleared when it goes.
        captureSource: win.showsHere ? win.modelData : null
        live: false
        visible: false
      }

      Repeater {
        // As text, so the strips (each with its own copy of its edge) are made
        // again only when the edges change, not on every read of Hyprland's
        // state, which hands out a new monitor object each time. But once per
        // opening: a copy (live: false) is taken once per ShaderEffectSource,
        // and the overlay's window, with what it took, is new every opening.
        readonly property string strips: JSON.stringify(win.showsHere && screenGhost.wanted && !win.keepBar ? [
          { edge: "top", size: screenGhost.reserved.top },
          { edge: "bottom", size: screenGhost.reserved.bottom },
          { edge: "left", size: screenGhost.reserved.left },
          { edge: "right", size: screenGhost.reserved.right }
        ].filter(function(strip) { return strip.size > 0 }) : [])
        model: JSON.parse(strips)

        delegate: Item {
          id: strip
          required property var modelData
          readonly property bool horizontal: modelData.edge === "top" || modelData.edge === "bottom"
          readonly property real slide: modelData.size * screenGhost.fade
          x: modelData.edge === "right" ? win.stageWidth - modelData.size + slide : modelData.edge === "left" ? -slide : 0
          y: modelData.edge === "bottom" ? win.stageHeight - modelData.size + slide : modelData.edge === "top" ? -slide : 0
          width: horizontal ? win.stageWidth : modelData.size
          height: horizontal ? modelData.size : win.stageHeight
          opacity: 1 - screenGhost.fade
          visible: opacity > 0.01 && screenGhost.hasContent

          // Just this edge of the capture, not a copy of the whole screen.
          ShaderEffectSource {
            anchors.fill: parent
            sourceItem: screenGhost
            sourceRect: Qt.rect(strip.modelData.edge === "right" ? win.stageWidth - strip.modelData.size : 0,
                                strip.modelData.edge === "bottom" ? win.stageHeight - strip.modelData.size : 0,
                                strip.width, strip.height)
            live: false
            hideSource: false
          }
        }
      }

      // Everything else layer-shell draws above the windows (a dock,
      // notifications): shown from the capture, fading out quickly as Mission
      // Control opens and back in as it closes. Drawn over the windows, as they
      // were on screen.
      Repeater {
        // As text, for the same reasons as the strips above.
        readonly property string surfaces: JSON.stringify(win.showsHere && win.monitor && win.service
          ? Model.surfaces(win.service.layers, win.monitor).filter(function(surface) {
            return surface.namespace !== "omarchy-bar"
          }) : [])
        model: JSON.parse(surfaces)

        delegate: ShaderEffectSource {
          required property var modelData
          x: modelData.x
          y: modelData.y
          width: modelData.w
          height: modelData.h
          z: 1050
          sourceItem: screenGhost
          sourceRect: Qt.rect(modelData.x, modelData.y, modelData.w, modelData.h)
          live: false
          hideSource: false
          opacity: 1 - win.smooth(0, 0.22, win.p)
          visible: opacity > 0.01 && screenGhost.hasContent
        }
      }

      // Clicking the background goes back to the desktop.
      MouseArea {
        anchors.fill: parent
        enabled: !!win.service && win.service.interactive
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(event) {
          if (event.button === Qt.RightButton) {
            win.service.close({})
            win.service.openSettings("")
          } else {
            win.service.close({})
          }
        }
      }

      // App names under each group of windows ("Group windows by application").
      Repeater {
        model: win.grouped ? win.groups : []
        delegate: Row {
          required property var modelData
          transform: Translate { x: win.groupSlideX + win.trackX }
          spacing: 8
          x: modelData.x + (modelData.w - width) / 2
          y: modelData.y + modelData.h + 12
          opacity: win.smooth(0.6, 1, win.p)
          visible: opacity > 0.01

          IconImage {
            source: modelData.icon
            implicitSize: 30
            anchors.verticalCenter: parent.verticalCenter
            asynchronous: true
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.name
            textFormat: Text.PlainText
            color: "white"
            font.family: win.uiFont
            font.pixelSize: 14
            font.weight: Font.DemiBold
            style: Text.Raised
            styleColor: Qt.rgba(0, 0, 0, 0.35)
          }
        }
      }

      // App Exposé: the app's name and icon at the top, and a line above the
      // minimized windows.
      Row {
        visible: !!win.service && win.service.mode === "expose" && opacity > 0.01
        anchors.horizontalCenter: parent.horizontalCenter
        y: win.edges.top + 30
        spacing: 10
        opacity: win.smooth(0.4, 1, win.p)
        readonly property var app: win.service && win.service.exposeClass ? win.service.appFor(win.service.exposeClass) : null

        IconImage {
          source: parent.app ? parent.app.icon : ""
          implicitSize: 36
          anchors.verticalCenter: parent.verticalCenter
          asynchronous: true
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: parent.app ? parent.app.name : ""
          textFormat: Text.PlainText
          color: "white"
          font.family: win.uiFont
          font.pixelSize: 20
          font.weight: Font.DemiBold
        }
      }

      Rectangle {
        visible: win.minimizedIds.length > 0 && !!win.service && win.service.mode === "expose"
        x: win.edges.left + Math.round(win.stageWidth * 0.06)
        width: win.stageWidth - win.edges.right - x - Math.round(win.stageWidth * 0.06)
        y: win.stageHeight - win.edges.bottom - Math.round(win.stageHeight * 0.2) - 44
        height: 1
        color: Qt.rgba(1, 1, 1, 0.25)
        opacity: win.smooth(0.5, 1, win.p)
      }

      Repeater {
        model: ScriptModel { values: win.tileIds }
        delegate: WindowTile { overview: win }
      }

      // While a desktop is renamed, a click anywhere but its name keeps the
      // name and does nothing else. The Spaces bar is above this; its desktops
      // and "+" turn their clicks off meanwhile, so theirs land here too.
      MouseArea {
        anchors.fill: parent
        z: 1090
        enabled: spacesBar.renamingDesktop !== 0
        hoverEnabled: enabled
        acceptedButtons: Qt.AllButtons
        onPressed: spacesBar.commitRename()
      }

      SpacesBar {
        id: spacesBar
        overview: win
        visible: win.mission
        z: 1100
      }

      Item {
        id: keys
        focus: true
        Keys.onPressed: function(event) { win.handleKey(event) }
      }
    }
  }
}
