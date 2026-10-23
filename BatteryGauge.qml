import QtQuick
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// Battery-shaped gauge: outline + nub, fill at `percent`, a faint band between
// the charge limits, and two draggable limit handles. Dragging clamps live via
// Model.clampHandle; `committed` fires once on release when something changed.
// The wheel is swallowed so it can never commit.
Item {
  id: root

  property real percent: 0
  property int start: 1
  property int end: 100
  property bool charging: false
  property bool editable: true
  // True while a helper call is in flight: handles stay put but can't be grabbed.
  property bool busy: false
  override property var palette: null
  property bool opened: false
  property string fontFamily: Style.font.family
  signal committed(int start, int end)

  property int liveStart: start
  property int liveEnd: end
  property string dragging: ""

  onStartChanged: if (dragging === "") liveStart = start
  onEndChanged: if (dragging === "") liveEnd = end

  // Snap the handles back to the real limits (e.g. after a failed write).
  function resync() {
    if (dragging !== "") return
    liveStart = start
    liveEnd = end
  }

  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  readonly property color cGood: palette ? palette.good : Commons.Color.accent
  readonly property color cHandle: palette ? palette.neutral : Commons.Color.accent
  readonly property color cOutline: palette ? palette.muted : Commons.Color.muted
  readonly property color cText: palette ? palette.text : Commons.Color.foreground

  readonly property real border: Style.space(2)
  readonly property real overhang: Style.space(6)
  readonly property real nubWidth: Style.space(4)
  readonly property real bodyHeight: Style.space(30)
  readonly property real labelHeight: Style.font.caption + Style.space(6)
  readonly property bool interactive: editable && !busy

  implicitHeight: overhang + Style.space(2) + bodyHeight + overhang + labelHeight
    + (caption.visible ? caption.implicitHeight + Style.space(4) : 0)

  // Swallow the wheel over the whole gauge; nothing here reacts to it.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    onWheel: function(wheel) { wheel.accepted = true }
  }

  Rectangle {
    id: body
    x: 0
    y: root.overhang + Style.space(2)
    width: root.width - root.nubWidth - Style.space(2)
    height: root.bodyHeight
    radius: Style.space(6)
    color: root.tint(root.cOutline, 0)
    border.width: root.border
    border.color: root.cOutline

    readonly property real innerX: root.border
    readonly property real innerWidth: width - root.border * 2
    function xFor(pct) { return innerX + innerWidth * Math.max(0, Math.min(100, pct)) / 100 }

    // Safe band between the limits.
    Rectangle {
      x: body.xFor(root.liveStart)
      width: body.xFor(root.liveEnd) - x
      y: root.border
      height: body.height - root.border * 2
      color: root.tint(root.cGood, 0.08)
    }

    // Charge fill.
    Rectangle {
      id: fill
      x: root.border
      y: root.border
      height: body.height - root.border * 2
      width: Math.max(0, body.innerWidth * Math.max(0, Math.min(100, root.percent)) / 100)
      radius: Style.space(3)
      clip: true
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: root.tint(root.cGood, 0.2) }
        GradientStop { position: 1; color: root.tint(root.cGood, 0.47) }
      }
      Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

      // Shimmer sweeping across the fill while charging and open.
      Rectangle {
        id: shimmer
        visible: root.charging && root.opened
        width: Math.max(Style.space(40), fill.width * 0.5)
        height: parent.height
        x: -width
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: root.tint(root.cText, 0) }
          GradientStop { position: 0.5; color: root.tint(root.cText, 0.1) }
          GradientStop { position: 1; color: root.tint(root.cText, 0) }
        }
        NumberAnimation on x {
          running: root.charging && root.opened
          loops: Animation.Infinite
          from: -shimmer.width
          to: fill.width
          duration: 3200
          easing.type: Easing.InOutSine
        }
      }
    }
  }

  // Terminal nub.
  Rectangle {
    x: body.x + body.width - 1
    width: root.nubWidth + 1
    height: body.height / 3
    y: body.y + (body.height - height) / 2
    radius: Style.space(2)
    color: root.cOutline
  }

  Repeater {
    model: ["start", "end"]

    Item {
      id: handle
      required property string modelData
      readonly property string which: modelData
      readonly property int value: which === "start" ? root.liveStart : root.liveEnd
      readonly property bool hot: grab.containsMouse || root.dragging === which
      property real lift: hot && root.interactive ? 2 : 0

      x: body.x + body.xFor(value) - width / 2
      y: body.y - root.overhang - lift
      width: Style.space(18)
      height: root.bodyHeight + root.overhang * 2 + root.labelHeight
      opacity: root.editable ? 1 : 0.4
      z: root.dragging === which ? 2 : 1

      Behavior on lift { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

      Rectangle {
        id: bar
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.space(3)
        height: root.bodyHeight + root.overhang * 2
        radius: width / 2
        color: root.cHandle
      }

      Text {
        anchors.top: bar.bottom
        anchors.topMargin: Style.space(2)
        // Keep the number inside the gauge at the edges.
        x: Math.max(-handle.x, Math.min(root.width - handle.x - implicitWidth, (handle.width - implicitWidth) / 2))
        textFormat: Text.PlainText
        text: handle.value + "%"
        color: root.cHandle
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: handle.hot && root.interactive
      }

      MouseArea {
        id: grab
        anchors.fill: parent
        enabled: root.interactive
        hoverEnabled: true
        preventStealing: true
        cursorShape: Qt.SizeHorCursor
        acceptedButtons: Qt.LeftButton

        function valueAt(mouseX) {
          var p = mapToItem(body, mouseX, 0)
          var pct = (p.x - body.innerX) / body.innerWidth * 100
          return Model.clampHandle(handle.which, pct, root.liveStart, root.liveEnd)
        }

        onPressed: function(mouse) { root.dragging = handle.which }
        onPositionChanged: function(mouse) {
          if (root.dragging !== handle.which) return
          var v = valueAt(mouse.x)
          if (handle.which === "start") root.liveStart = v
          else root.liveEnd = v
        }
        onReleased: function(mouse) {
          root.dragging = ""
          if (root.editable && (root.liveStart !== root.start || root.liveEnd !== root.end))
            root.committed(root.liveStart, root.liveEnd)
        }
        onCanceled: {
          root.dragging = ""
          root.resync()
        }
      }
    }
  }

  Text {
    id: caption
    visible: !root.editable
    anchors.bottom: parent.bottom
    textFormat: Text.PlainText
    text: "Applies in Custom mode"
    color: root.cOutline
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
