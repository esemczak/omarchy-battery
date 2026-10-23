import QtQuick
import qs.Commons

// Health-over-time line chart. Fed by Model.chartPoints (x/y in 0..1, y up).
// Colours come from the bar foreground at reduced opacity, like the stock panel.
Item {
  id: root

  property color foreground: "#ffffff"
  property string fontFamily: Style.font.family
  property var chart: ({ points: [], yMin: 75, yMax: 100, floorY: null, warrantyX: null })
  property string rangeLabel: ""
  signal clicked()

  readonly property real pad: Style.space(4)

  onChartChanged: canvas.requestPaint()
  onForegroundChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  function rgba(a) {
    return "rgba(" + Math.round(foreground.r * 255) + "," + Math.round(foreground.g * 255) + "," +
      Math.round(foreground.b * 255) + "," + a + ")"
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var c = root.chart || {}
      var pts = c.points || []
      var p = root.pad
      var w = width - p * 2
      var h = height - p * 2
      if (w <= 0 || h <= 0) return
      function px(x) { return p + x * w }
      function py(y) { return p + (1 - y) * h }

      // Dashed health-floor line.
      if (c.floorY !== null && c.floorY !== undefined) {
        ctx.strokeStyle = root.rgba(0.35)
        ctx.lineWidth = 1
        ctx.setLineDash([4, 4])
        ctx.beginPath()
        ctx.moveTo(px(0), py(c.floorY))
        ctx.lineTo(px(1), py(c.floorY))
        ctx.stroke()
        ctx.setLineDash([])
      }
      // Warranty-end marker.
      if (c.warrantyX !== null && c.warrantyX !== undefined) {
        ctx.strokeStyle = root.rgba(0.45)
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(px(c.warrantyX), p)
        ctx.lineTo(px(c.warrantyX), p + h)
        ctx.stroke()
      }
      if (pts.length === 0) return

      ctx.strokeStyle = root.rgba(0.9)
      ctx.lineWidth = 2
      ctx.lineJoin = "round"
      ctx.beginPath()
      for (var i = 0; i < pts.length; i++) {
        if (i === 0) ctx.moveTo(px(pts[i].x), py(pts[i].y))
        else ctx.lineTo(px(pts[i].x), py(pts[i].y))
      }
      ctx.stroke()

      // Points: the estimated seed is hollow, real samples filled.
      for (var j = 0; j < pts.length; j++) {
        ctx.beginPath()
        ctx.arc(px(pts[j].x), py(pts[j].y), 3, 0, Math.PI * 2)
        if (pts[j].seed) {
          ctx.strokeStyle = root.rgba(0.9)
          ctx.lineWidth = 1.5
          ctx.stroke()
        } else {
          ctx.fillStyle = root.rgba(0.9)
          ctx.fill()
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    text: root.rangeLabel
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    anchors.top: parent.top
    anchors.right: parent.right
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
