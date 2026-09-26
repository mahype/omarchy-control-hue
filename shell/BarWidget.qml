import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.mahype.omarchy-control-hue"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  readonly property var doc: service ? service.doc : null
  readonly property bool installed: service ? service.installed : true
  readonly property bool anyOn: service && service.ready ? service.home.anyOn === true : false
  readonly property bool attention: Model.needsAttention(doc, installed)
  readonly property var strings: Model.strings(Qt.locale().name)
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onServiceChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: root.moduleName
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    // Opens the panel with one room or zone expanded, e.g. for a keybinding.
    // tab: "scene", "color", "temperature" or "" for the current mode.
    function expand(name: string, tab: string): string {
      if (!panelLoader.item) return "unavailable"
      root.open()
      return panelLoader.item.expandByName(name, tab) ? "ok" : "unknown"
    }
    function allOff(): string {
      return root.service && root.service.allOff() ? "ok" : "unavailable"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-md-lightbulb / nf-md-lightbulb_outline
    text: root.anyOn ? "󰌵" : "󰌶"
    tooltipText: Model.tooltip(root.doc, root.installed, root.service ? root.service.error : "", root.strings)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }

    Rectangle {
      visible: root.attention
      width: Math.max(4, Style.space(5))
      height: width
      radius: width / 2
      color: root.bar ? root.bar.urgent : Color.urgent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(2)
    }
  }
}
