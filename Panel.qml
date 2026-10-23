import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "esemczak.battery"
  ipcTarget: "omarchy.power"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false
  property var snapshot: null
  property var appState: null
  property var samples: []
  readonly property var settingsObj: Model.settingsFrom(root.settings)
  property real nowMs: Date.now()
  property string range: "3m"
  // null until the first `test -x` finishes; false shows the install hint.
  property var helperPresent: null
  property string actionMessage: ""
  // Last non-empty message, so the feedback line can fade out with its text.
  property string shownMessage: ""
  property var pendingArgs: []

  readonly property string pluginDir: {
    var path = String(Qt.resolvedUrl("bin/battery-read.sh") || "")
    if (path.indexOf("file://") === 0) path = path.substring(7)
    var slash = path.lastIndexOf("/bin/")
    return slash >= 0 ? path.substring(0, slash) : Quickshell.env("HOME") + "/.config/omarchy/plugins/" + Model.PLUGIN_ID
  }
  readonly property string stateDirPath: Model.stateDir(Quickshell.env("HOME"), Quickshell.env("XDG_STATE_HOME"))

  function alertFor(key) {
    var a = appState && appState.alerts ? appState.alerts[key] : null
    if (!a || a.active !== true) return null
    // The stored mode alert can lag the live state by minutes; drop it as soon as the
    // live snapshot + chosen mode no longer match the "mode" condition.
    if (key === "limitIgnored" && a.reason === "mode" && snapshot
        && !Model.limitModeIgnored(snapshot, appState.chosenMode)) return null
    return a
  }
  readonly property var limitAlert: alertFor("limitIgnored")
  readonly property var degradationAlert: alertFor("degradation")
  readonly property bool hasAlert: limitAlert !== null || degradationAlert !== null

  readonly property bool hasModes: !!(snapshot && snapshot.modes && snapshot.modes.length > 0)
  readonly property bool hasLimits: !!(snapshot && snapshot.start !== null && snapshot.end !== null)
  readonly property bool chargingAvailable: !!(snapshot && snapshot.present && (hasModes || hasLimits))
  readonly property bool limitsEditable: !hasModes || (snapshot && snapshot.mode === "Custom")
  readonly property var healthValue: Model.healthPct(snapshot)
  readonly property var wear: Model.wearRate(samples, nowMs)
  readonly property real healthFloor: settingsObj.healthFloor
  readonly property var floorDate: healthValue === null || isNaN(healthValue) ? null
    : Model.projectFloorDate(healthValue, wear.perMonth, healthFloor, nowMs)
  readonly property var chart: Model.chartPoints(samples, range, nowMs,
    { floor: healthFloor, warrantyEnd: settingsObj.warrantyEnd })
  readonly property string rangeLabel: range === "3m" ? "3 months" : (range === "1y" ? "1 year" : "All time")

  function runHelper(args) {
    if (helperProc.running) return
    pendingArgs = args
    helperProc.command = ["pkexec", Model.HELPER_PATH].concat(args)
    helperProc.running = true
  }

  function showMessage(text) {
    actionMessage = text
    if (text !== "") shownMessage = text
    messageTimer.restart()
  }

  function refreshData() {
    nowMs = Date.now()
    if (!snapProc.running) snapProc.running = true
    if (!histProc.running) histProc.running = true
    if (!stateProc.running) stateProc.running = true
    if (!helperCheck.running) helperCheck.running = true
  }

  function commitLimits(start, end) {
    runHelper(["limits", String(Math.round(start)), String(Math.round(end))])
  }

  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false
  readonly property bool showPercentage: setting("showPercentage", false) === true
  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0
  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function batteryIcon() {
    var device = UPower.displayDevice
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.discharging, upowerStates())
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.foreground : Commons.Color.foreground
  }

  // Cute agent-flavored phrases shown in the hero status line, rotated on a
  // timer so the panel feels alive when current is flowing (either direction).
  readonly property var chargingPhrases: [
    "Pumping power",
    "Injecting electrons",
    "Pouring juice",
    "Amassing watts",
    "Hoarding joules",
    "Sucking volts",
    "Topping reserves",
    "Soaking amps",
    "Inhaling kilowatts"
  ]
  readonly property var onBatteryPhrases: [
    "Slurping power",
    "Spending joules",
    "Draining watts",
    "Burning electrons",
    "Sipping juice",
    "Spending coulombs",
    "Bleeding amps",
    "Guzzling volts",
    "Munching reserves"
  ]
  property int phraseIndex: 0

  // Whichever list is "active" given the current power state.
  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  readonly property string heroStatusText: {
    if (fullyCharged) return "Fully charged"
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return modeLabel()
  }

  function refresh() {
    if (!batteryPresent) return

    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
    if (!systemProc.running) systemProc.running = true
    refreshData()
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    // Keep last known good data if a refresh briefly returns nothing — happens
    // around AC plug/unplug events. Avoids the section collapsing mid-transition.
    if (Object.keys(next).length === 0) return
    if (targetName === "battery") batteryInfo = next
    else systemInfo = next
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Same guard as battery: preserve the last known profile list across
    // transient empty payloads so the buttons don't blink out.
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  function setProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]
    actionProc.running = true
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  IpcHandler {
    target: "omarchy.power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
        return
      }

      themePalette.reload()
      refresh()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  ThemePalette { id: themePalette }

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "battery") }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  Process {
    id: snapProc
    command: ["bash", root.pluginDir + "/bin/battery-read.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseSnapshot(text)
        // Keep the last good snapshot if a read comes back empty.
        if (parsed.present || root.snapshot === null) root.snapshot = parsed
      }
    }
  }

  Process {
    id: histProc
    command: ["cat", root.stateDirPath + "/history.jsonl"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.samples = Model.parseHistory(text, Date.now())
    }
  }

  Process {
    id: stateProc
    command: ["cat", root.stateDirPath + "/state.json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = null
        try { parsed = JSON.parse(text) } catch (e) { parsed = null }
        root.appState = parsed && typeof parsed === "object" ? parsed : null
      }
    }
  }

  Process {
    id: helperCheck
    command: ["test", "-x", Model.HELPER_PATH]
    onExited: function(code) { root.helperPresent = code === 0 }
  }

  // The only place the helper runs: always pkexec + the root-owned copy.
  Process {
    id: helperProc
    onExited: function(code) {
      var result = Model.actionResult(code)
      root.showMessage(result.message)
      var args = root.pendingArgs
      if (!result.ok) gauge.resync()
      if (result.ok && args.length === 2 && args[0] === "mode") {
        recordProc.command = ["bash", root.pluginDir + "/bin/state-update.sh", root.stateDirPath,
          JSON.stringify({ chosenMode: String(args[1]) })]
        recordProc.running = true
      } else {
        root.refreshData()
      }
    }
  }

  Process {
    id: recordProc
    onExited: root.refreshData()
  }

  // Read-only state refresh while closed, so the bar's alert mark stays current
  // (including on other monitors' bars). Starts with one read at load.
  Timer {
    interval: 45000
    running: !root.opened
    repeat: true
    triggeredOnStart: true
    // Also re-reads the (cheap, sysfs-only) snapshot so the mode-alert suppression
    // in alertFor() sees the live mode while the panel is closed.
    onTriggered: {
      if (!stateProc.running) stateProc.running = true
      if (!snapProc.running) snapProc.running = true
    }
  }

  Timer { id: messageTimer; interval: 3000; onTriggered: root.actionMessage = "" }

  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  // Rotate the status phrase while the panel is open and we're in a
  // rotating state (charging or on battery). The text swap is wrapped in a
  // fade so the changeover reads as one organism rather than a hard cut.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  // If we leave a rotating state mid-swap, halt the animation and snap back
  // to full opacity so "FULLY CHARGED" is legible immediately rather than
  // appearing dimmed.
  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: (root.showPercentage && !vertical
      ? Math.round(root.batteryFraction * 100) + "% " + root.batteryIcon()
      : root.batteryIcon()) + (root.hasAlert ? " \uDB80\uDC26" : "")
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)
    tooltipText: ""
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Battery"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.batteryInfo.percentage || "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Battery progress bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.batteryFillColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            // Subtle pulse while charging — visible signal that energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Stats ----------
        // Visibility is intentionally only gated by "we've ever loaded data" so
        // the section never collapses mid-transition. fullyCharged is *not* part
        // of the condition: UPower briefly reports FullyCharged on plug-in when
        // the battery sits above the charge-control start threshold, and we
        // refuse to flicker the whole panel for that ~1s window.
        Row {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Battery size"; value: root.batteryInfo.size || "" }
            InfoPair { label: "Charge cycles"; value: root.batteryInfo.cycles || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.chargeThresholdActive ? "Charge limit" : (root.discharging ? "Time left" : "Time to full")
              value: root.chargeThresholdActive ? (root.batteryInfo.threshold || "-") : (root.batteryFlowIdle ? "-" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              label: root.chargeThresholdActive ? "Battery state" : (root.discharging ? "Discharging" : "Charging")
              value: root.chargeThresholdActive ? "Holding" : (root.batteryFull ? "-" : (root.batteryInfo.rate || ""))
            }
          }
        }

        // ---------- Alert banner ----------
        Column {
          visible: root.hasAlert
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: [
              { key: "limitIgnored", alert: root.limitAlert },
              { key: "degradation", alert: root.degradationAlert }
            ].filter(function(e) { return e.alert !== null })

            Rectangle {
              required property var modelData
              width: column.width
              implicitHeight: bannerRow.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.08)

              Row {
                id: bannerRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                Text {
                  id: bannerText
                  textFormat: Text.PlainText
                  text: "\uDB80\uDC26 " + (modelData.alert.text || "")
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - (fixButton.visible ? fixButton.width + parent.spacing : 0)
                }

                Button {
                  id: fixButton
                  visible: modelData.key === "limitIgnored" && modelData.alert.reason === "mode" && root.helperPresent !== false
                  text: "Fix"
                  fontSize: Style.font.bodySmall
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  bordered: true
                  anchors.verticalCenter: parent.verticalCenter
                  onClicked: root.runHelper(["mode", "Custom"])
                }
              }
            }
          }
        }

        // ---------- Charging ----------
        PanelSeparator {
          visible: root.chargingAvailable
          foreground: root.bar.foreground
        }

        Column {
          visible: root.chargingAvailable
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "CHARGING"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Text {
            visible: opacity > 0
            opacity: root.helperPresent === false ? 1 : 0
            width: parent.width
            textFormat: Text.PlainText
            text: "Install the battery helper: run install-helper.sh in the plugin repo"
            wrapMode: Text.WordWrap
            color: themePalette.muted
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
          }

          Column {
            visible: root.helperPresent !== false
            width: parent.width
            spacing: Style.space(10)

            ModeTiles {
              visible: root.hasModes
              width: parent.width
              modes: root.snapshot ? root.snapshot.modes : []
              activeMode: root.snapshot && root.snapshot.mode ? root.snapshot.mode : ""
              palette: themePalette
              opened: root.opened
              enabled: !helperProc.running
              fontFamily: root.bar.fontFamily
              onPicked: function(mode) { root.runHelper(["mode", mode]) }
            }

            BatteryGauge {
              id: gauge
              visible: root.hasLimits
              width: parent.width
              percent: Math.round(root.batteryFraction * 100)
              start: root.snapshot && root.snapshot.start !== null ? root.snapshot.start : 1
              end: root.snapshot && root.snapshot.end !== null ? root.snapshot.end : 100
              charging: root.charging
              editable: root.limitsEditable
              busy: helperProc.running
              palette: themePalette
              opened: root.opened
              fontFamily: root.bar.fontFamily
              onCommitted: function(s, e) { root.commitLimits(s, e) }
            }
          }

          Text {
            visible: opacity > 0
            opacity: root.actionMessage !== "" ? 1 : 0
            textFormat: Text.PlainText
            text: root.shownMessage
            color: themePalette.muted
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
          }
        }

        // ---------- Health ----------
        PanelSeparator {
          visible: root.snapshot !== null && root.snapshot.present
          foreground: root.bar.foreground
        }

        Column {
          visible: root.snapshot !== null && root.snapshot.present
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "HEALTH"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap
            InfoPair { label: "Health"; value: root.healthValue === null || isNaN(root.healthValue) ? "—" : root.healthValue + "%" }
            InfoPair {
              label: "Wear"
              value: root.wear.basis === "none" || root.wear.perMonth === null ? "—"
                : Math.abs(root.wear.perMonth).toFixed(2) + "%/mo" + (root.wear.basis === "estimate" ? " (est.)" : "")
            }
            InfoPair { label: "Reaches " + root.healthFloor + "%"; value: root.floorDate === null ? "—" : Model.formatMonthYear(root.floorDate) }
            InfoPair { label: "Cycles"; value: root.snapshot && root.snapshot.cycles !== null ? String(root.snapshot.cycles) : "—" }
            InfoPair { label: "Temp"; value: root.snapshot && root.snapshot.tempC !== null ? root.snapshot.tempC + "°C" : "—" }
          }

          HealthChart {
            width: parent.width
            height: Style.space(70)
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            chart: root.chart
            rangeLabel: root.rangeLabel
            onClicked: root.range = Model.nextRange(root.range)
          }
        }

        // ---------- Power use ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POWER USE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          PowerUse {
            width: parent.width
            opened: root.opened && root.batteryPresent
            palette: themePalette
            pluginDir: root.pluginDir
            fontFamily: root.bar.fontFamily
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
              : 0

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activeProfile === modelData
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
