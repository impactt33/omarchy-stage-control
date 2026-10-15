import QtQuick
import QtQuick.Effects
import qs.Commons

// A Liquid Glass pane. Given the layer behind it (`backdrop`: a texture of
// the whole window with `backdropIsWindow`, else one that covers
// `backdropSpace`), it refracts that layer: frosted, bent inward at the rim
// like a thick lens, with a specular rim lit from the top left
// (shaders/glass.frag). Without a backdrop, with the "solid" style, or if the
// shader can't load, it draws a flat translucent pane with the same rim.
// Content goes inside, as children.
//
// style: "liquid" (clear glass), "frosted" (more blur and tint), "solid", or
// "theme": no lens, rim or border, but the blurred backdrop under the Omarchy
// theme's own tint, the one its popups use (shell.toml's [popups]), with the
// menu's highlight ([menu]) on hover: frosted panes like the theme's bar and
// menus.
Item {
  id: glass

  property real radius: height / 2
  property string style: "liquid"
  property bool dark: true
  property bool shadow: true
  property bool hovered: false
  property bool pressed: false
  property bool selected: false
  property color selectedColor: "#0a84ff"
  // How much of selectedColor fills a selected pane (a solid selection is
  // 0.78; a tint that keeps the glass is around 0.25).
  property real selectedStrength: 0.78
  property color outlineColor: "transparent"
  property real outlineWidth: 0
  property Item backdrop: null
  property Item backdropSpace: null
  // The backdrop covers the whole window (the stage's does). The shader then
  // finds the pane in it from the pane's own transform, so nothing has to
  // follow the pane around on every frame.
  property bool backdropIsWindow: false

  readonly property bool themed: style === "theme"
  readonly property bool refracting: style !== "solid" && !!backdrop && (backdropIsWindow || !!backdropSpace)
    && lens.status !== ShaderEffect.Error

  default property alias content: inner.data

  RectangularShadow {
    anchors.fill: parent
    radius: glass.radius
    offset: Qt.vector2d(0, 4)
    blur: 18
    spread: -2
    color: Qt.rgba(0, 0, 0, glass.style === "solid" || glass.themed ? 0.35 : 0.24)
    visible: glass.shadow && glass.opacity > 0
  }

  ShaderEffect {
    id: lens
    anchors.fill: parent
    visible: glass.refracting

    property var backdrop: glass.backdrop
    property size itemSize: Qt.size(width, height)
    property real radius: glass.radius
    // The theme's panes only blur: no bending rim and no light on it.
    property real bevel: glass.themed ? 0.001 : Math.max(4, Math.min(width, height) * 0.34)
    property real refraction: glass.themed ? 0 : glass.style === "liquid" ? Math.min(12, Math.min(width, height) * 0.24) : 4
    property real frost: glass.style === "liquid" ? 1.6 : 3.2
    property real rim: glass.themed ? 0 : glass.style === "liquid" ? 1.0 : 0.7
    property real flip: 0
    property real windowSpace: glass.backdropIsWindow ? 1 : 0
    property vector4d area: Qt.vector4d(0, 0, 1, 1)
    property vector4d tint: glass.themed
      ? Qt.vector4d(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, Color.popups.background.a)
      : glass.dark
      ? Qt.vector4d(0.05, 0.05, 0.07, glass.style === "liquid" ? 0.32 : 0.46)
      : Qt.vector4d(1, 1, 1, glass.style === "liquid" ? 0.30 : 0.50)
    property vector4d fill: glass.selected ? Qt.vector4d(glass.selectedColor.r, glass.selectedColor.g, glass.selectedColor.b, glass.selectedStrength)
      : glass.pressed ? Qt.vector4d(0, 0, 0, 0.16)
      : glass.hovered ? (glass.themed
        ? Qt.vector4d(Color.menu.selectedBackground.r, Color.menu.selectedBackground.g, Color.menu.selectedBackground.b, Color.menu.selectedBackground.a)
        : Qt.vector4d(1, 1, 1, 0.12))
      : Qt.vector4d(0, 0, 0, 0)

    fragmentShader: Qt.resolvedUrl("shaders/glass.frag.qsb")
  }

  // Where the pane sits over a backdrop that isn't the whole window (the
  // settings window's preview). Worked out again when the pane, its parent
  // or that backdrop moves or changes size, not on every frame: a
  // FrameAnimation did that, waking the shell on every frame for as long as
  // the settings window was open. Panes over the whole window (the stage's)
  // listen to none of it, as they move on every frame of an animation.
  // Not before the pane is complete: reading `refracting` while it's still
  // being built would evaluate `backdrop` before its binding can resolve.
  property bool built: false
  function placeArea() {
    if (built && refracting && !backdropIsWindow) updateArea()
  }
  onRefractingChanged: placeArea()
  Component.onCompleted: {
    built = true
    placeArea()
  }
  Connections {
    target: glass.backdropIsWindow ? null : glass
    function onXChanged() { glass.placeArea() }
    function onYChanged() { glass.placeArea() }
    function onWidthChanged() { glass.placeArea() }
    function onHeightChanged() { glass.placeArea() }
  }
  Connections {
    target: glass.backdropIsWindow ? null : glass.parent
    ignoreUnknownSignals: true
    function onXChanged() { glass.placeArea() }
    function onYChanged() { glass.placeArea() }
  }
  Connections {
    target: glass.backdropIsWindow ? null : glass.backdropSpace
    ignoreUnknownSignals: true
    function onWidthChanged() { glass.placeArea() }
    function onHeightChanged() { glass.placeArea() }
  }

  function updateArea() {
    if (!backdropSpace) return
    var a = glass.mapToItem(backdropSpace, 0, 0)
    var b = glass.mapToItem(backdropSpace, glass.width, glass.height)
    var w = Math.max(1, backdropSpace.width)
    var h = Math.max(1, backdropSpace.height)
    var next = Qt.vector4d(a.x / w, a.y / h, (b.x - a.x) / w, (b.y - a.y) / h)
    var now = lens.area
    if (Math.abs(next.x - now.x) + Math.abs(next.y - now.y) + Math.abs(next.z - now.z) + Math.abs(next.w - now.w) > 0.00001)
      lens.area = next
  }

  // The theme's pane when there is no backdrop to blur: its tint alone.
  Item {
    anchors.fill: parent
    visible: glass.themed && !glass.refracting

    Rectangle {
      anchors.fill: parent
      radius: glass.radius
      color: glass.selected ? Qt.rgba(glass.selectedColor.r, glass.selectedColor.g, glass.selectedColor.b, glass.selectedStrength)
        : Color.popups.background
    }
    Rectangle {
      anchors.fill: parent
      radius: glass.radius
      color: glass.pressed ? Qt.rgba(0, 0, 0, 0.16) : Color.menu.selectedBackground
      visible: glass.pressed || (glass.hovered && !glass.selected)
    }
  }

  // The drawn pane, for when there is nothing to refract.
  Item {
    id: drawn
    anchors.fill: parent
    visible: !glass.refracting && !glass.themed

    readonly property real bodyAlpha: glass.style === "solid" ? 0.92 : glass.style === "frosted" ? 0.30 : 0.18
    readonly property color baseColor: glass.dark ? Qt.rgba(0.14, 0.14, 0.16, 1) : Qt.rgba(0.97, 0.97, 0.98, 1)
    readonly property real lift: glass.pressed ? -0.04 : glass.hovered ? 0.06 : 0

    Rectangle {
      anchors.fill: parent
      radius: glass.radius
      gradient: Gradient {
        GradientStop {
          position: 0
          color: glass.selected ? Qt.rgba(glass.selectedColor.r, glass.selectedColor.g, glass.selectedColor.b, Math.min(1, glass.selectedStrength + 0.07))
            : glass.dark ? Qt.rgba(0.27, 0.27, 0.30, Math.min(1, drawn.bodyAlpha + drawn.lift))
            : Qt.rgba(1, 1, 1, Math.min(1, drawn.bodyAlpha + 0.30 + drawn.lift))
        }
        GradientStop {
          position: 1
          color: glass.selected ? Qt.rgba(glass.selectedColor.r, glass.selectedColor.g, glass.selectedColor.b, glass.selectedStrength)
            : Qt.rgba(drawn.baseColor.r, drawn.baseColor.g, drawn.baseColor.b,
                      Math.min(1, drawn.bodyAlpha + 0.06 + drawn.lift))
        }
      }
    }

    // Rim: a hairline, brighter across the top half.
    Rectangle {
      anchors.fill: parent
      radius: glass.radius
      color: "transparent"
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, glass.style === "solid" ? 0.10 : 0.16)
    }
    Item {
      anchors.left: parent.left
      anchors.right: parent.right
      height: Math.max(glass.radius, parent.height * 0.5)
      clip: true
      Rectangle {
        width: glass.width
        height: glass.height
        radius: glass.radius
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, glass.style === "solid" ? 0.18 : 0.34)
      }
    }
  }

  // Selection ring, drawn over the glass.
  Rectangle {
    anchors.fill: parent
    radius: glass.radius
    color: "transparent"
    border.width: glass.outlineWidth
    border.color: glass.outlineColor
    // The theme's panes have no borders, a selected one included.
    visible: glass.outlineWidth > 0 && !glass.themed
  }

  Item {
    id: inner
    anchors.fill: parent
  }
}
