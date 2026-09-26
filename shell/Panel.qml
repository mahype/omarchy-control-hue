import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Popup. Holds no light state of its own — everything comes from the
// service; this file only decides what to show and forwards actions.
Panel {
  id: root
  moduleName: "io.github.mahype.omarchy-light-control-hue"
  ipcTarget: moduleName
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root
  readonly property var strings: Model.strings(Qt.locale().name)
  readonly property var doc: service ? service.doc : null
  readonly property var home: service ? service.home : Model.emptyHome()
  readonly property bool ready: service ? service.ready : false
  readonly property bool installed: service ? service.installed : true
  readonly property string connectionState: service ? service.state : ""
  readonly property bool setupBusy: service ? service.setupBusy : false
  readonly property var rooms: Model.groupsOfKind(home, "room")
  readonly property var zones: setting("showZones", true) === true ? Model.groupsOfKind(home, "zone") : []
  readonly property var plugs: setting("showPlugs", true) === true ? Model.plugs(home) : []

  // Only one room, zone or plug is expanded at a time; nothing stays expanded between opens.
  property string expandedId: ""
  property bool showConnection: false

  function toggleExpanded(id) { expandedId = expandedId === id ? "" : id }

  function expandByName(name) {
    var wanted = String(name || "").toLowerCase()
    var groups = home.groups || []
    for (var i = 0; i < groups.length; i++) {
      if (String(groups[i].name).toLowerCase() !== wanted) continue
      expandedId = groups[i].id
      return true
    }
    return false
  }

  function open() {
    controller.show()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    controller.hide()
  }

  onOpenedChanged: if (opened) {
    panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  } else {
    expandedId = ""
    showConnection = false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(820))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: hostField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Header: title · all on/off ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(titleCol.implicitHeight, allSwitch.implicitHeight)

            Column {
              id: titleCol
              anchors.left: parent.left
              anchors.right: allSwitch.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: "Philips Hue"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              HintText {
                bar: root.bar
                width: parent.width
                text: Model.summary(root.doc, root.installed, root.strings)
                font.pixelSize: Style.font.caption
              }
            }

            ToggleSwitch {
              id: allSwitch
              visible: root.ready
              checked: root.home.anyOn === true
              foreground: root.bar.foreground
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: if (root.service) root.home.anyOn ? root.service.allOff() : root.service.allOn()
            }
          }

          // ---------- Feedback ----------
          HintText {
            bar: root.bar
            readonly property bool isError: root.service !== null && root.service.error !== ""
            visible: text !== ""
            width: parent.width
            text: root.service
              ? (root.service.error || root.service.statusMessage || (!root.installed ? root.strings.missingHint : ""))
              : ""
            color: isError ? root.bar.urgent : root.bar.foreground
            opacity: isError ? 1 : 0.6
          }

          // ---------- Rooms ----------
          Column {
            visible: root.ready && root.rooms.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader { text: root.strings.rooms; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

            Repeater {
              model: root.rooms
              Column {
                required property var modelData
                required property int index
                width: parent.width
                spacing: Style.space(10)

                PanelSeparator { visible: index > 0; foreground: root.bar.foreground; opacity: 0.5 }

                GroupRow {
                  width: parent.width
                  bar: root.bar
                  service: root.service
                  group: modelData
                  home: root.home
                  expanded: root.expandedId === modelData.id
                  onExpandToggled: root.toggleExpanded(modelData.id)
                }
              }
            }
          }

          // ---------- Zones ----------
          Column {
            visible: root.ready && root.zones.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.bar.foreground }
            PanelSectionHeader { text: root.strings.zones; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

            Repeater {
              model: root.zones
              Column {
                required property var modelData
                required property int index
                width: parent.width
                spacing: Style.space(10)

                PanelSeparator { visible: index > 0; foreground: root.bar.foreground; opacity: 0.5 }

                GroupRow {
                  width: parent.width
                  bar: root.bar
                  service: root.service
                  group: modelData
                  home: root.home
                  expanded: root.expandedId === modelData.id
                  onExpandToggled: root.toggleExpanded(modelData.id)
                }
              }
            }
          }

          // ---------- Plugs ----------
          Column {
            visible: root.ready && root.plugs.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.bar.foreground }
            PanelSectionHeader { text: root.strings.plugs; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

            Repeater {
              model: root.plugs
              LightRow {
                required property var modelData
                width: parent.width
                bar: root.bar
                service: root.service
                light: modelData
                compact: false
                showRoom: true
              }
            }
          }

          // ---------- Connection / setup ----------
          Column {
            visible: root.installed
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.bar.foreground }

            // Collapsed while everything works; open when setup is needed.
            Item {
              width: parent.width
              implicitHeight: connHeader.implicitHeight

              PanelSectionHeader {
                id: connHeader
                text: root.strings.connection
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                visible: root.ready
                textFormat: Text.PlainText
                text: String.fromCodePoint(root.showConnection ? 0xF0143 : 0xF0140)
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }

              MouseArea {
                anchors.fill: parent
                enabled: root.ready
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.showConnection = !root.showConnection
              }
            }

            Column {
              id: connection
              visible: !root.ready || root.showConnection
              width: parent.width
              spacing: Style.space(8)

              HintText {
                bar: root.bar
                visible: root.doc !== null && !!root.doc.bridge
                width: parent.width
                text: root.doc && root.doc.bridge
                  ? root.strings.bridge + ": " + root.doc.bridge.name + " · " + root.doc.bridge.host : ""
              }

              // Pairing (bridge selected but no valid key).
              HintText {
                bar: root.bar
                visible: ["unpaired", "unauthorized"].indexOf(root.connectionState) >= 0
                width: parent.width
                text: root.strings.pairHint
              }
              Button {
                visible: ["unpaired", "unauthorized"].indexOf(root.connectionState) >= 0
                width: parent.width
                text: root.service && root.service.pairing ? root.strings.pressLink : root.strings.pair
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                enabled: !root.setupBusy
                onClicked: root.service.pair()
              }

              // Choosing a bridge.
              Column {
                visible: ["unconfigured", "unreachable"].indexOf(root.connectionState) >= 0 || root.showConnection
                width: parent.width
                spacing: Style.space(8)

                Button {
                  text: root.strings.findBridge
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  fontSize: Style.font.bodySmall
                  bordered: true
                  enabled: !root.setupBusy
                  onClicked: root.service.discover()
                }

                Repeater {
                  model: root.service ? root.service.bridges : []
                  Item {
                    required property var modelData
                    width: connection.width
                    implicitHeight: selectButton.implicitHeight

                    Text {
                      textFormat: Text.PlainText
                      text: modelData.name + " · " + modelData.host
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                      anchors.left: parent.left
                      anchors.right: selectButton.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Button {
                      id: selectButton
                      anchors.right: parent.right
                      text: root.strings.select
                      foreground: root.bar.foreground
                      fontFamily: root.bar.fontFamily
                      fontSize: Style.font.bodySmall
                      bordered: true
                      enabled: !root.setupBusy
                      onClicked: root.service.useBridge(modelData)
                    }
                  }
                }

                HintText {
                  bar: root.bar
                  visible: root.service !== null && root.service.bridgesLoaded && root.service.bridges.length === 0
                  width: parent.width
                  text: root.strings.noBridges
                }

                Item {
                  width: parent.width
                  implicitHeight: hostField.implicitHeight

                  TextField {
                    id: hostField
                    anchors.left: parent.left
                    anchors.right: connectButton.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    placeholderText: root.strings.manualHost
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlGap
                    verticalPadding: Style.spacing.controlPaddingY
                    onAccepted: connectButton.connect()
                  }

                  Button {
                    id: connectButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.strings.connect
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    fontSize: Style.font.bodySmall
                    bordered: true
                    enabled: !root.setupBusy && hostField.text.trim() !== ""
                    function connect() { if (enabled) root.service.connectHost(hostField.text) }
                    onClicked: connect()
                  }
                }
              }

              Button {
                visible: root.ready
                text: root.strings.forget
                foreground: root.bar.urgent
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                enabled: !root.setupBusy
                onClicked: root.service.forget()
              }
            }
          }
        }
      }
    }
  }
}
