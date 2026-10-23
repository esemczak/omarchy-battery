import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// POWER USE: measured battery draw, a short draw sparkline, and the top 3
// apps by CPU share (estimated watts on battery, % of CPU on the charger).
// Samples bin/power-sample.sh every 2 s, only while the panel is open. The
// sample window and draw buffer live here for the whole shell session.
Item {
  id: root

  property bool opened: false
  override property var palette: null
  property string pluginDir: ""
  property string fontFamily: Style.font.family

  // Last <= 6 samples (5 deltas, ~10 s) for app shares; ~5 min of draw points.
  property var samples: []
  property var drawBuffer: []

  readonly property var latest: samples.length ? samples[samples.length - 1] : null
  readonly property bool onBattery: latest !== null && typeof latest.drawW === "number"
  readonly property var result: Model.powerRows(Model.appShares(samples), latest, 3)
  readonly property bool showSpark: onBattery && result.mode !== "cpu" && drawBuffer.length >= 2

  readonly property color cText: palette ? palette.text : Commons.Color.foreground
  readonly property color cMuted: palette ? palette.muted : Commons.Color.muted
  readonly property color cPower: palette ? palette.power : Commons.Color.accent
  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function rankColor(i) {
    if (!palette) return Commons.Color.accent
    return i === 0 ? palette.warn : (i === 1 ? palette.neutral : palette.power)
  }

  implicitHeight: column.implicitHeight

  function ingest(text) {
    var s = Model.parsePowerSample(text)
    if (!s) return
    var now = Date.now()
    if (!(s.t > 0)) s.t = now
    // Drop samples from before a close/reopen so shares describe "now".
    var kept = samples.filter(function (p) { return p.t >= s.t - 15000 })
    kept.push(s)
    samples = kept.length > 6 ? kept.slice(kept.length - 6) : kept
    drawBuffer = Model.appendDrawPoint(drawBuffer, s, now)
  }

  // Keep the ListModel in rank order by label so rows move instead of
  // being rebuilt; ListView transitions animate the reorder.
  function syncRows() {
    var rows = result.rows
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      var text = r.unit === "W" ? "~" + Number(r.value).toFixed(1) + " W" : r.value + "%"
      var j = -1
      for (var k = i; k < rowModel.count; k++) if (rowModel.get(k).label === r.label) { j = k; break }
      if (j < 0) rowModel.insert(i, { label: r.label, valueText: text, fraction: r.fraction })
      else {
        if (j !== i) rowModel.move(j, i, 1)
        rowModel.setProperty(i, "valueText", text)
        rowModel.setProperty(i, "fraction", r.fraction)
      }
    }
    while (rowModel.count > rows.length) rowModel.remove(rowModel.count - 1)
  }
  onResultChanged: syncRows()
  onDrawBufferChanged: spark.requestPaint()
  onCPowerChanged: spark.requestPaint()

  ListModel { id: rowModel }

  Process {
    id: proc
    command: ["bash", root.pluginDir + "/bin/power-sample.sh"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.ingest(text) }
  }

  Timer {
    interval: 2000
    running: root.opened && root.pluginDir !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!proc.running) proc.running = true
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(6)

    // Draw now / Plugged in
    Item {
      width: parent.width
      height: Math.max(drawLabel.implicitHeight, drawValue.implicitHeight)

      Text {
        id: drawLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.latest === null ? "Draw now" : (root.onBattery ? "Draw now" : "Plugged in")
        color: root.onBattery || root.latest === null ? root.cText : root.cMuted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        id: drawValue
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.onBattery ? Number(root.latest.drawW).toFixed(1) + " W" : (root.latest === null ? "measuring…" : "")
        color: root.onBattery ? root.cPower : root.cMuted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: root.onBattery
        Behavior on color { ColorAnimation { duration: 250; easing.type: Easing.OutCubic } }
      }
    }

    // Sparkline of the draw; collapses on the charger.
    Item {
      width: parent.width
      height: root.showSpark ? Style.space(26) : 0
      clip: true
      opacity: root.showSpark ? 1 : 0
      Behavior on height { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
      Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

      Canvas {
        id: spark
        width: parent.width
        height: Style.space(26)
        onWidthChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var pts = root.drawBuffer || []
          if (pts.length < 2 || width <= 0) return
          var t0 = pts[0].t, t1 = pts[pts.length - 1].t
          var span = Math.max(1, t1 - t0)
          var lo = Infinity, hi = -Infinity
          for (var i = 0; i < pts.length; i++) { lo = Math.min(lo, pts[i].w); hi = Math.max(hi, pts[i].w) }
          if (hi - lo < 1) { var mid = (hi + lo) / 2; lo = mid - 0.5; hi = mid + 0.5 }
          var pad = 2
          var h = height - pad * 2
          var c = root.cPower
          ctx.strokeStyle = "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + ",0.8)"
          ctx.lineWidth = 1.5
          ctx.lineJoin = "round"
          ctx.beginPath()
          for (var j = 0; j < pts.length; j++) {
            var x = (pts[j].t - t0) / span * width
            var y = pad + (1 - (pts[j].w - lo) / (hi - lo)) * h
            if (j === 0 || pts[j].gapBefore) ctx.moveTo(x, y)
            else ctx.lineTo(x, y)
          }
          ctx.stroke()
        }
      }
    }

    Text {
      visible: root.result.mode === "measuring" && root.latest !== null
      textFormat: Text.PlainText
      text: "measuring…"
      color: root.cMuted
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    ListView {
      id: list
      width: parent.width
      height: contentHeight
      interactive: false
      model: rowModel
      spacing: Style.space(4)

      add: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 250; easing.type: Easing.OutCubic } }
      remove: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 150; easing.type: Easing.OutCubic } }
      move: Transition { NumberAnimation { property: "y"; duration: 250; easing.type: Easing.OutCubic } }
      displaced: Transition { NumberAnimation { property: "y"; duration: 250; easing.type: Easing.OutCubic } }

      delegate: Column {
        id: row
        required property int index
        required property string label
        required property string valueText
        required property real fraction
        readonly property color tone: root.rankColor(index)

        width: list.width
        spacing: Style.space(2)

        // Bars grow in from 0 once the row exists.
        property bool grown: false
        Component.onCompleted: grown = true

        Item {
          width: parent.width
          height: Math.max(nameText.implicitHeight, valText.implicitHeight)
          Text {
            id: nameText
            anchors.left: parent.left
            width: Math.min(implicitWidth, parent.width - valText.implicitWidth - Style.space(8))
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: row.label
            color: root.cText
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            id: valText
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: row.valueText
            color: root.cMuted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Rectangle {
          width: parent.width
          height: Style.space(4)
          radius: height / 2
          color: root.tint(root.cText, 0.08)

          Rectangle {
            height: parent.height
            radius: parent.radius
            width: row.grown ? parent.width * Math.max(0, Math.min(1, row.fraction)) : 0
            color: row.tone
            Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 250; easing.type: Easing.OutCubic } }
          }
        }
      }
    }

    Text {
      visible: root.result.mode !== "measuring"
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: root.result.mode === "watts" ? "Estimated from CPU share of the measured draw"
        : "Plugged in · watts shown on battery"
      color: root.cMuted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
