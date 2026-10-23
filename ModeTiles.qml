import QtQuick
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// Charge-mode tiles: icon + label per supported mode. The active tile breathes
// slowly in its semantic colour (Custom green, Fast red, others accent); a
// switch cross-fades over 250 ms. Props in, `picked` out — the Panel owns the
// helper call.
Item {
  id: root

  property var modes: []
  property string activeMode: ""
  override property var palette: null
  property bool opened: false
  property string fontFamily: Style.font.family
  signal picked(string mode)

  readonly property int count: modes ? modes.length : 0
  readonly property int columns: Math.max(1, Math.min(5, count))
  readonly property real gap: Style.space(5)
  readonly property real tileWidth: (width - gap * (columns - 1)) / columns

  implicitHeight: flow.implicitHeight

  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function toneColor(mode) {
    if (!palette) return Commons.Color.foreground
    return palette[Model.modeTone(mode)]
  }

  // One shared breath (0..1) drives every tile's glow; only while open.
  property real breath: 0
  SequentialAnimation on breath {
    running: root.opened
    loops: Animation.Infinite
    NumberAnimation { from: 0; to: 1; duration: 1350; easing.type: Easing.InOutSine }
    NumberAnimation { from: 1; to: 0; duration: 1350; easing.type: Easing.InOutSine }
  }

  Flow {
    id: flow
    width: parent.width
    spacing: root.gap

    Repeater {
      model: root.modes || []

      Item {
        id: tile
        required property var modelData
        readonly property string mode: String(modelData)
        readonly property bool on: root.activeMode === mode
        readonly property string tone: Model.modeTone(mode)
        readonly property color toneColor: root.toneColor(mode)
        readonly property bool hot: area.containsMouse && root.enabled && !on

        // 0..1, cross-fades the active look in and out.
        property real activeness: on ? 1 : 0
        Behavior on activeness { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

        width: root.tileWidth
        height: label.implicitHeight + icon.implicitHeight + Style.space(14)

        // Soft outer glow; breathes on the active tile only.
        Rectangle {
          anchors.fill: parent
          anchors.margins: -Style.space(2)
          radius: body.radius + Style.space(2)
          color: root.tint(tile.toneColor, 0)
          border.width: Style.space(2)
          border.color: root.tint(tile.toneColor, 0.28)
          opacity: tile.activeness * (0.25 + 0.75 * root.breath)
        }

        Rectangle {
          id: body
          anchors.fill: parent
          radius: Style.space(6)
          color: root.tint(tile.toneColor, 0.08 * tile.activeness + (tile.hot ? 0.05 : 0))
          border.width: 1
          border.color: tile.on ? root.tint(tile.toneColor, 0.7 + 0.3 * root.breath)
            : (tile.tone === "warn" ? root.tint(tile.toneColor, 0.33)
            : root.tint(root.palette ? root.palette.text : Commons.Color.foreground, tile.hot ? 0.3 : 0.14))

          Behavior on color { ColorAnimation { duration: 250; easing.type: Easing.OutCubic } }
        }

        Column {
          anchors.centerIn: parent
          spacing: Style.space(1)

          Text {
            id: icon
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: Model.modeIcon(tile.mode)
            color: tile.on ? tile.toneColor : (tile.tone === "warn" ? tile.toneColor
              : (root.palette ? root.palette.text : Commons.Color.foreground))
            opacity: tile.on || tile.tone === "warn" || tile.hot ? 1 : 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            Behavior on color { ColorAnimation { duration: 250; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
          }

          Text {
            id: label
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, tile.width - Style.space(4))
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: tile.mode
            color: tile.tone === "warn" && !tile.on ? tile.toneColor
              : (root.palette ? root.palette.text : Commons.Color.foreground)
            opacity: tile.on || tile.hot ? 1 : 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            Behavior on color { ColorAnimation { duration: 250; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
          }
        }

        MouseArea {
          id: area
          anchors.fill: parent
          hoverEnabled: true
          enabled: root.enabled
          cursorShape: tile.on ? Qt.ArrowCursor : Qt.PointingHandCursor
          onClicked: if (!tile.on) root.picked(tile.mode)
        }
      }
    }
  }
}
