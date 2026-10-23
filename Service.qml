import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "Model.js" as Model

// Background sampler and alert notifier. Keeps history.jsonl and state.json
// current; the panels only read those files. The shell runs exactly one
// instance of this regardless of how many bars exist.
Item {
  id: root

  property var shell: null
  property string omarchyPath: ""

  readonly property string pluginDir: {
    var path = String(Qt.resolvedUrl("bin/battery-read.sh") || "")
    if (path.indexOf("file://") === 0) path = path.substring(7)
    var slash = path.lastIndexOf("/bin/")
    return slash >= 0 ? path.substring(0, slash) : Quickshell.env("HOME") + "/.config/omarchy/plugins/" + Model.PLUGIN_ID
  }
  readonly property string home: Quickshell.env("HOME")
  readonly property string dirPath: Model.stateDir(home, Quickshell.env("XDG_STATE_HOME"))
  readonly property string configPath: home + "/.config/omarchy/shell.json"

  property var settings: Model.settingsFromShellConfig("{}")
  property bool checking: false
  // Bumped when the watchdog kills a check so its late stream callbacks are ignored.
  property int gen: 0
  property bool sampling: false
  property bool samplePending: false
  property var snapshotValue: null
  property var historyText: ""
  property var outgoing: []

  Component.onCompleted: {
    console.info("esemczak.battery service started")
    root.runSample(false)
  }

  // ---- settings ------------------------------------------------------------

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    blockLoading: true
    printErrors: false
    onLoaded: root.settings = Model.settingsFromShellConfig(text())
    onFileChanged: reload()
  }

  // ---- sampling -----------------------------------------------------------

  function runSample(force) {
    if (sampling) {
      // A forced sample must not be lost to a running one.
      if (force) samplePending = true
      return
    }
    sampling = true
    sampleProc.command = force
      ? ["bash", pluginDir + "/bin/history-append.sh", dirPath, "--on-ac-change"]
      : ["bash", pluginDir + "/bin/history-append.sh", dirPath]
    sampleProc.running = true
  }

  Process {
    id: sampleProc
    onExited: function (code) {
      root.sampling = false
      if (root.samplePending) {
        root.samplePending = false
        root.runSample(true)
      }
    }
  }

  Timer {
    interval: 6 * 60 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.runSample(false)
  }

  // ---- alert checks -------------------------------------------------------

  Timer {
    interval: 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.runCheck()
  }

  Connections {
    target: UPower
    function onOnBatteryChanged() {
      // UPower reports its initial value as a change; the script only records
      // a sample when AC state differs from the last real sample.
      root.runSample(true)
      root.runCheck()
    }
  }

  function runCheck() {
    if (checking) return
    checking = true
    snapshotValue = null
    historyText = ""
    watchdog.restart()
    readProc.gen = gen
    readProc.running = true
  }

  function finishCheck() {
    watchdog.stop()
    checking = false
  }

  // A chain step that never finishes must not block every later check.
  Timer {
    id: watchdog
    interval: 45000
    onTriggered: {
      console.warn("esemczak.battery check timed out; resetting")
      readProc.running = false
      historyProc.running = false
      stateReadProc.running = false
      stateWriteProc.running = false
      notifyProc.running = false
      root.gen += 1
      root.outgoing = []
      root.checking = false
    }
  }

  Process {
    id: readProc
    property int gen: -1
    command: ["bash", root.pluginDir + "/bin/battery-read.sh"]
    stdout: StdioCollector {
      id: readOut
      waitForEnd: true
      onStreamFinished: {
        if (readProc.gen !== root.gen || !root.checking) return
        var parsed = null
        try { parsed = JSON.parse(readOut.text) } catch (e) { parsed = null }
        if (!parsed || typeof parsed !== "object") {
          // A failed or killed read is not "battery absent"; don't touch state.
          console.warn("esemczak.battery battery-read gave no JSON")
          root.finishCheck()
          return
        }
        root.snapshotValue = Model.parseSnapshot(readOut.text)
        historyProc.gen = root.gen
        historyProc.running = true
      }
    }
  }

  Process {
    id: historyProc
    property int gen: -1
    command: ["cat", root.dirPath + "/history.jsonl"]
    stdout: StdioCollector {
      id: historyOut
      waitForEnd: true
      onStreamFinished: {
        if (historyProc.gen !== root.gen || !root.checking) return
        root.historyText = historyOut.text
        stateReadProc.gen = root.gen
        stateReadProc.running = true
      }
    }
  }

  Process {
    id: stateReadProc
    property int gen: -1
    command: ["cat", root.dirPath + "/state.json"]
    stdout: StdioCollector {
      id: stateOut
      waitForEnd: true
      onStreamFinished: {
        if (stateReadProc.gen !== root.gen || !root.checking) return
        root.evaluateAndWrite(stateOut.text)
      }
    }
  }

  function evaluateAndWrite(stateText) {
    {
      var prior = null
      try { prior = JSON.parse(stateText) } catch (e) { prior = null }
      var now = Date.now()
      var result
      try {
        result = Model.evaluateAlerts(root.snapshotValue, Model.parseHistory(root.historyText, now), prior, root.settings, now)
      } catch (e) {
        console.warn("esemczak.battery evaluate failed: " + e)
        root.finishCheck()
        return
      }
      root.outgoing = result.notifications || []
      // chosenMode is owned by the panel; never write it from here.
      var patch = { alerts: result.state.alerts, notify: result.state.notify, overcharge: result.state.overcharge }
      stateWriteProc.command = ["bash", root.pluginDir + "/bin/state-update.sh", root.dirPath, JSON.stringify(patch)]
      stateWriteProc.running = true
    }
  }

  Process {
    id: stateWriteProc
    onExited: function (code) {
      if (code !== 0) {
        // Not persisted: sending now could repeat the notification next tick.
        console.warn("esemczak.battery state write failed (" + code + ")")
        root.outgoing = []
        root.finishCheck()
        return
      }
      root.sendNext()
    }
  }

  function sendNext() {
    if (outgoing.length === 0) {
      finishCheck()
      return
    }
    var n = outgoing[0]
    outgoing = outgoing.slice(1)
    notifyProc.command = ["omarchy-notification-send", "-g", "󰂃", "-u", String(n.urgency || "normal"), String(n.title || ""), String(n.body || "")]
    notifyProc.running = true
  }

  Process {
    id: notifyProc
    onExited: function (code) { root.sendNext() }
  }
}
