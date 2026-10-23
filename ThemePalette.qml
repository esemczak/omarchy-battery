import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Non-visual: semantic colours from the active theme's colors.toml, falling
// back to the stock Commons.Color palette when the file or a key is missing.
Item {
  id: root
  visible: false

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
  readonly property string path: stateHome + "/omarchy/current/theme/colors.toml"

  property var palette: ({})
  readonly property var semantic: Model.semanticColors(palette, {
    accent: Color.accent, urgent: Color.urgent, foreground: Color.foreground, muted: Color.muted
  })

  readonly property color good: semantic.good
  readonly property color warn: semantic.warn
  readonly property color neutral: semantic.neutral
  readonly property color power: semantic.power
  readonly property color text: semantic.text
  readonly property color muted: semantic.muted

  // A theme swap may replace the directory, so the Panel calls this on open.
  function reload() { file.reload() }

  FileView {
    id: file
    path: root.path
    watchChanges: true
    blockLoading: true
    printErrors: false
    onLoaded: root.palette = Model.parseThemeColors(text())
    onLoadFailed: root.palette = ({})
    onFileChanged: reload()
  }
}
