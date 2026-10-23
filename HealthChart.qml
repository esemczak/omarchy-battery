import QtQuick
import qs.Commons
import qs.Commons as Commons

// Health-over-time line chart. Fed by Model.chartPoints (x/y in 0..1, y up)
// and Model.projectionPoint. On open the line draws itself left to right; the
// latest point then pulses softly while the panel stays open. The estimated
// seed point stays hollow. Clicking anywhere emits `clicked` (range cycle).
Item {
  id: root

  override property var palette: null
  property bool opened: false
  property string fontFamily: Style.font.family
  property var chart: ({ points: [], yMin: 75, yMax: 100, floorY: null, warrantyX: null })
  // {x, y} in chart coordinates, or null for no projection.
  property var projection: null
  property string floorLabel: ""
  signal clicked()

  readonly property real pad: Style.space(4)
  readonly property color cLine: palette ? palette.neutral : Commons.Color.accent
  readonly property color cWarn: palette ? palette.warn : Commons.Color.urgent
  readonly property color cMuted: palette ? palette.muted : Commons.Color.muted
  readonly property color cText: palette ? palette.text : Commons.Color.foreground

  readonly property var points: chart && chart.points ? chart.points : []
  readonly property var latest: points.length ? points[points.length - 1] : null

  function px(x) { return pad + x * (width - pad * 2) }
  function py(y) { return pad + (1 - y) * (height - pad * 2) }
  function rgba(c, a) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")"
  }

  // 0..1 draw-on progress; restarts on every open.
  property real progress: 1
  NumberAnimation {
    id: drawOn
    target: root; property: "progress"
    from: 0; to: 1; duration: 700; easing.type: Easing.OutCubic
  }
  onOpenedChanged: if (opened) drawOn.restart()

  // Soft pulse for the latest point, only while open.
  property real pulse: 0
  SequentialAnimation on pulse {
    running: root.opened
    loops: Animation.Infinite
    NumberAnimation { from: 0; to: 1; duration: 1200; easing.type: Easing.InOutSine }
    NumberAnimation { from: 1; to: 0; duration: 1200; easing.type: Easing.InOutSine }
  }

  onChartChanged: canvas.requestPaint()
  onProjectionChanged: canvas.requestPaint()
  onProgressChanged: canvas.requestPaint()
  onCLineChanged: canvas.requestPaint()
  onCWarnChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var c = root.chart || {}
      var pts = root.points
      var p = root.pad
      var w = width - p * 2
      var h = height - p * 2
      if (w <= 0 || h <= 0) return
      var px = root.px, py = root.py

      // Dashed health-floor line in the warning colour, with its label.
      if (c.floorY !== null && c.floorY !== undefined) {
        ctx.strokeStyle = root.rgba(root.cWarn, 0.7)
        ctx.lineWidth = 1
        ctx.setLineDash([4, 4])
        ctx.beginPath()
        ctx.moveTo(px(0), py(c.floorY))
        ctx.lineTo(px(1), py(c.floorY))
        ctx.stroke()
        ctx.setLineDash([])
      }
      // Warranty-end marker: muted and dashed.
      if (c.warrantyX !== null && c.warrantyX !== undefined) {
        ctx.strokeStyle = root.rgba(root.cMuted, 1)
        ctx.lineWidth = 1
        ctx.setLineDash([2, 3])
        ctx.beginPath()
        ctx.moveTo(px(c.warrantyX), 0)
        ctx.lineTo(px(c.warrantyX), height)
        ctx.stroke()
        ctx.setLineDash([])
      }
      if (pts.length === 0) return

      var x0 = px(pts[0].x)
      var xN = px(pts[pts.length - 1].x)
      var reveal = x0 + (xN - x0) * root.progress

      ctx.save()
      ctx.beginPath()
      ctx.rect(0, 0, reveal + 1, height)
      ctx.clip()

      // Area under the line: accent fading out downward.
      if (pts.length > 1) {
        var grad = ctx.createLinearGradient(0, p, 0, p + h)
        grad.addColorStop(0, root.rgba(root.cLine, 0.35))
        grad.addColorStop(1, root.rgba(root.cLine, 0))
        ctx.fillStyle = grad
        ctx.beginPath()
        ctx.moveTo(px(pts[0].x), p + h)
        for (var a = 0; a < pts.length; a++) ctx.lineTo(px(pts[a].x), py(pts[a].y))
        ctx.lineTo(px(pts[pts.length - 1].x), p + h)
        ctx.closePath()
        ctx.fill()
      }

      ctx.strokeStyle = root.rgba(root.cLine, 1)
      ctx.lineWidth = 2
      ctx.lineJoin = "round"
      ctx.beginPath()
      for (var i = 0; i < pts.length; i++) {
        if (i === 0) ctx.moveTo(px(pts[i].x), py(pts[i].y))
        else ctx.lineTo(px(pts[i].x), py(pts[i].y))
      }
      ctx.stroke()
      ctx.restore()

      // Dashed projection from the latest point, once the line has arrived.
      var last = pts[pts.length - 1]
      if (root.projection && root.progress > 0.8) {
        ctx.globalAlpha = 0.5 * (root.progress - 0.8) / 0.2
        ctx.strokeStyle = root.rgba(root.cLine, 1)
        ctx.lineWidth = 1.5
        ctx.setLineDash([3, 3])
        ctx.beginPath()
        ctx.moveTo(px(last.x), py(last.y))
        ctx.lineTo(px(root.projection.x), py(root.projection.y))
        ctx.stroke()
        ctx.setLineDash([])
        ctx.globalAlpha = 1
      }

      // The estimated seed stays hollow (the latest real point is drawn below).
      for (var j = 0; j < pts.length; j++) {
        if (!pts[j].seed || px(pts[j].x) > reveal + 1) continue
        ctx.beginPath()
        ctx.arc(px(pts[j].x), py(pts[j].y), 3, 0, Math.PI * 2)
        ctx.strokeStyle = root.rgba(root.cLine, 1)
        ctx.lineWidth = 1.5
        ctx.stroke()
      }
    }
  }

  Text {
    visible: root.floorLabel !== "" && root.chart && root.chart.floorY !== null && root.chart.floorY !== undefined
    textFormat: Text.PlainText
    text: root.floorLabel
    color: root.cWarn
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    x: root.pad
    y: visible ? root.py(root.chart.floorY) + Style.space(2) : 0
  }

  Text {
    visible: root.chart && root.chart.warrantyX !== null && root.chart.warrantyX !== undefined
    textFormat: Text.PlainText
    text: "warranty"
    color: root.cText
    opacity: 0.5
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    y: 0
    x: visible ? Math.max(0, root.px(root.chart.warrantyX) - width - Style.space(3)) : 0
  }

  // Latest real point: filled, pulsing softly while open.
  Rectangle {
    readonly property real r: 3.5 + 1.5 * root.pulse
    visible: root.latest !== null && !root.latest.seed
    opacity: Math.max(0, (root.progress - 0.8) / 0.2)
    width: r * 2
    height: r * 2
    radius: r
    color: root.cLine
    x: visible ? root.px(root.latest.x) - r : 0
    y: visible ? root.py(root.latest.y) - r : 0
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
