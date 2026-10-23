import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import QtQuick.Effects
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
  // The first history load picks the initial range (Model.defaultRange); after
  // that, clicks cycle from wherever it is.
  property bool rangeChosen: false
  function cycleRange() {
    rangeChosen = true
    range = Model.nextRange(range)
  }
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
  readonly property var projection: Model.projectionPoint(chart, wear.perMonth, healthFloor, nowMs, range)

  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // ---- Open motion ----
  // `intro` (0..1, OutCubic) drives the percentage count-up and the charge bar
  // growing in. `revealMs` is a plain clock; each section turns it into its own
  // 250 ms OutCubic fade + 4 px rise, 40 ms after the one above it.
  property real intro: 1
  property real revealMs: 10000
  readonly property int revealSteps: 8
  function revealProgress(order) {
    var t = Math.max(0, Math.min(1, (revealMs - order * 40) / 250))
    return 1 - Math.pow(1 - t, 3)
  }
  function revealShift(order) { return Style.space(4) * (1 - revealProgress(order)) }

  NumberAnimation {
    id: introAnim
    target: root; property: "intro"
    from: 0; to: 1; duration: 700; easing.type: Easing.OutCubic
  }
  NumberAnimation {
    id: revealAnim
    target: root; property: "revealMs"
    from: 0; to: root.revealSteps * 40 + 250; duration: root.revealSteps * 40 + 250
  }

  // Gentle background pulse for the Fix button, only while open.
  property real nudge: 0
  SequentialAnimation on nudge {
    running: root.opened && root.limitAlert !== null
    loops: Animation.Infinite
    NumberAnimation { from: 0; to: 1; duration: 1400; easing.type: Easing.InOutSine }
    NumberAnimation { from: 1; to: 0; duration: 1400; easing.type: Easing.InOutSine }
  }

  readonly property var percentValue: {
    var n = parseInt(String(batteryInfo.percentage || ""), 10)
    return isNaN(n) ? null : n
  }
  readonly property string statsLeft: {
    var parts = []
    if (batteryInfo.size) parts.push(batteryInfo.size)
    if (batteryInfo.cycles) parts.push(batteryInfo.cycles + " cycles")
    return parts.join(" · ")
  }
  readonly property string statsRight: {
    if (chargeThresholdActive) return "Holding · limit " + (batteryInfo.threshold || "-")
    if (batteryFlowIdle) return ""
    var parts = []
    if (batteryInfo.time) parts.push(batteryInfo.time + (discharging ? " left" : " to full"))
    if (batteryInfo.rate) parts.push(batteryInfo.rate)
    return parts.join(" · ")
  }
  readonly property string wearValueText: wear.basis === "none" || wear.perMonth === null ? "—"
    : (wear.perMonth < 0 ? "\u2212" : "") + Math.abs(wear.perMonth).toFixed(2)
  readonly property string floorDateText: {
    if (floorDate === null) return "—"
    var s = Model.formatMonthYear(floorDate)
    return s.slice(0, 4) + s.slice(-2)
  }
  readonly property string healthCaption: {
    var parts = []
    if (snapshot && snapshot.cycles !== null) parts.push(snapshot.cycles + " cycles")
    if (snapshot && snapshot.tempC !== null) parts.push(snapshot.tempC + " °C")
    return parts.join(" · ")
  }

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
      introAnim.restart()
      revealAnim.restart()
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
      onStreamFinished: {
        root.samples = Model.parseHistory(text, Date.now())
        if (!root.rangeChosen) {
          root.range = Model.defaultRange(root.samples, Date.now())
          root.rangeChosen = true
        }
      }
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
          opacity: root.revealProgress(0)
          transform: Translate { y: root.revealShift(0) }

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: (root.discharging && root.batteryFraction <= 0.2) ? themePalette.warn : themePalette.good
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercentBox.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Battery"
              color: themePalette.text
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
              color: themePalette.text
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          // Big percentage: counts up on open; a text -> good gradient is masked
          // through the glyphs.
          Item {
            id: heroPercentBox
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: heroPercent.implicitWidth
            height: heroPercent.implicitHeight

            Text {
              id: heroPercent
              anchors.fill: parent
              textFormat: Text.PlainText
              text: root.percentValue === null ? (root.batteryInfo.percentage || "—")
                : Math.round(root.percentValue * root.intro) + "%"
              color: themePalette.text
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
              visible: false
              layer.enabled: true
            }

            Rectangle {
              id: heroPercentFill
              anchors.fill: parent
              visible: false
              layer.enabled: true
              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: themePalette.text }
                GradientStop { position: 1.0; color: themePalette.good }
              }
            }

            MultiEffect {
              anchors.fill: parent
              source: heroPercentFill
              maskEnabled: true
              maskSource: heroPercent
              maskThresholdMin: 0.5
              maskSpreadAtMin: 1.0
            }
          }
        }

        // ---------- Battery progress bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(7)
          opacity: root.revealProgress(1)
          transform: Translate { y: root.revealShift(1) }

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: root.tint(themePalette.text, 0.1)
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction) * root.intro
            visible: width > 0.5
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0.0; color: themePalette.warn }
              GradientStop { position: 0.35; color: themePalette.neutral }
              GradientStop { position: 1.0; color: themePalette.good }
            }

            Behavior on width {
              enabled: !introAnim.running
              NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
            }

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

        // ---------- Stats: one compact line ----------
        // Visibility is intentionally only gated by "we've ever loaded data" so
        // the line never collapses mid-transition. fullyCharged is *not* part
        // of the condition: UPower briefly reports FullyCharged on plug-in when
        // the battery sits above the charge-control start threshold, and we
        // refuse to flicker the whole panel for that ~1s window.
        Item {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          implicitHeight: statsLeftText.implicitHeight
          opacity: root.revealProgress(2)
          transform: Translate { y: root.revealShift(2) }

          InfoLabel {
            id: statsLeftText
            anchors.left: parent.left
            text: root.statsLeft
          }
          InfoLabel {
            anchors.right: parent.right
            text: root.statsRight
          }
        }

        // ---------- Alert banner ----------
        Column {
          visible: root.hasAlert
          width: parent.width
          spacing: Style.space(6)
          opacity: root.revealProgress(3)
          transform: Translate { y: root.revealShift(3) }

          Repeater {
            model: [
              { key: "limitIgnored", alert: root.limitAlert },
              { key: "degradation", alert: root.degradationAlert }
            ].filter(function(e) { return e.alert !== null })

            Rectangle {
              id: banner
              required property var modelData
              width: column.width
              implicitHeight: bannerRow.implicitHeight + Style.space(16)
              radius: Style.space(4)
              color: root.tint(themePalette.warn, 0.08)

              // Slides in (fade + 6 px) when it appears and on every open.
              property real slide: 0
              opacity: slide
              transform: Translate { y: -Style.space(6) * (1 - banner.slide) }
              NumberAnimation {
                id: slideIn
                target: banner; property: "slide"
                from: 0; to: 1; duration: 250; easing.type: Easing.OutCubic
              }
              Component.onCompleted: slideIn.restart()
              Connections {
                target: root
                function onOpenedChanged() { if (root.opened) slideIn.restart() }
              }

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.space(3)
                radius: Style.space(1)
                color: themePalette.warn
              }

              Row {
                id: bannerRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                Text {
                  id: bannerIcon
                  textFormat: Text.PlainText
                  text: "\uDB80\uDC26"
                  color: themePalette.warn
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: bannerText
                  textFormat: Text.PlainText
                  text: banner.modelData.alert.text || ""
                  color: themePalette.text
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - bannerIcon.width - parent.spacing
                    - (fixButton.visible ? fixButton.width + parent.spacing : 0)
                }

                Button {
                  id: fixButton
                  visible: banner.modelData.key === "limitIgnored" && banner.modelData.alert.reason === "mode" && root.helperPresent !== false
                  text: "Fix"
                  fontSize: Style.font.bodySmall
                  foreground: themePalette.warn
                  background: root.tint(themePalette.warn, 0.14 * root.nudge)
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
          opacity: root.revealProgress(4)
        }

        Column {
          visible: root.chargingAvailable
          width: parent.width
          spacing: Style.space(10)
          opacity: root.revealProgress(4)
          transform: Translate { y: root.revealShift(4) }

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
          opacity: root.revealProgress(5)
        }

        Column {
          visible: root.snapshot !== null && root.snapshot.present
          width: parent.width
          spacing: Style.space(8)
          opacity: root.revealProgress(5)
          transform: Translate { y: root.revealShift(5) }

          PanelSectionHeader {
            text: "HEALTH"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: statCards
            width: parent.width
            spacing: Style.space(6)
            readonly property real cardWidth: (width - spacing * 2) / 3

            StatCard {
              value: root.healthValue === null || isNaN(root.healthValue) ? "—" : root.healthValue + "%"
              valueColor: themePalette.neutral
              label: "HEALTH"
            }
            StatCard {
              value: root.wearValueText
              unit: root.wearValueText === "—" ? "" : "%/mo"
              label: root.wear.basis === "estimate" ? "WEAR · EST." : "WEAR"
            }
            StatCard {
              value: root.floorDateText
              valueColor: root.degradationAlert !== null ? themePalette.warn : themePalette.good
              label: "REACHES " + root.healthFloor + "%"
            }
          }

          HealthChart {
            width: parent.width
            height: Style.space(70)
            palette: themePalette
            opened: root.opened && root.batteryPresent
            fontFamily: root.bar.fontFamily
            chart: root.chart
            projection: root.projection
            floorLabel: root.healthFloor + "%"
            onClicked: root.cycleRange()
          }

          Item {
            width: parent.width
            implicitHeight: healthCaptionText.implicitHeight

            Text {
              id: healthCaptionText
              anchors.left: parent.left
              textFormat: Text.PlainText
              text: root.healthCaption
              color: themePalette.text
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              anchors.right: parent.right
              textFormat: Text.PlainText
              text: root.rangeLabel.toLowerCase() + " \u25B8"
              color: themePalette.text
              opacity: rangeArea.containsMouse ? 0.9 : 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

              MouseArea {
                id: rangeArea
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.cycleRange()
              }
            }
          }
        }

        // ---------- Power use ----------
        PanelSeparator {
          foreground: root.bar.foreground
          opacity: root.revealProgress(6)
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          opacity: root.revealProgress(6)
          transform: Translate { y: root.revealShift(6) }

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
          opacity: root.revealProgress(7)
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          opacity: root.revealProgress(7)
          transform: Translate { y: root.revealShift(7) }

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
                id: profileButton
                required property var modelData
                required property int index
                readonly property bool isActive: root.activeProfile === modelData
                property real activeness: isActive ? 1 : 0
                Behavior on activeness { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                width: profileRow.cellWidth
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }

                // Quiet border; the active profile gets an accent border and a
                // light accent tint. Drawn under the label; hover and the
                // keyboard cursor keep the stock highlight on top.
                Rectangle {
                  z: -1
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: root.tint(themePalette.neutral, 0.1 * profileButton.activeness)
                  border.width: 1
                  border.color: Qt.tint(root.tint(themePalette.text, 0.16),
                    root.tint(themePalette.neutral, profileButton.activeness))
                }
              }
            }
          }
        }
      }
    }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: themePalette.text
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  // HEALTH stat card: big value (+ optional small unit) over a small label.
  component StatCard: Rectangle {
    property string value: ""
    property string unit: ""
    property string label: ""
    property color valueColor: themePalette.text

    width: statCards.cardWidth
    implicitHeight: cardColumn.implicitHeight + Style.space(14)
    radius: Style.space(6)
    color: root.tint(themePalette.text, 0.04)

    Column {
      id: cardColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Row {
        width: parent.width
        Text {
          id: cardValue
          textFormat: Text.PlainText
          text: value
          color: valueColor
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          Behavior on color { ColorAnimation { duration: 250; easing.type: Easing.OutCubic } }
        }
        Text {
          visible: unit !== ""
          anchors.baseline: cardValue.baseline
          textFormat: Text.PlainText
          text: unit
          color: valueColor
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: label
        color: themePalette.text
        opacity: 0.6
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 0.6
      }
    }
  }
}
