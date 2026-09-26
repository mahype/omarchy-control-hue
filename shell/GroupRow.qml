import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A room or zone. Expanded: brightness · blink, Szene/Farbe/Temperatur, and
// its lamps below a thin separator.
Column {
  id: row

  property QtObject bar: null
  property var service: null
  property var group: null
  property var home: null
  property bool expanded: false
  signal expandToggled()

  // Only one lamp is expanded at a time.
  property string expandedLightId: ""

  readonly property var strings: Model.strings()
  readonly property var lights: group ? Model.lightsOf(home, group.lightIds) : []

  onExpandedChanged: if (!expanded) { modes.reset(); expandedLightId = "" }

  spacing: Style.space(10)

  RowHeader {
    width: parent.width
    bar: row.bar
    name: row.group ? row.group.name : ""
    subtitle: Model.subtitle(row.group, true, row.strings)
    on: row.group ? row.group.on === true : false
    hex: row.group && row.group.hex ? row.group.hex : ""
    expanded: row.expanded
    onExpandToggled: row.expandToggled()
    onSwitchToggled: if (row.service) row.service.setGroup(row.group.groupedLightId, { on: !row.group.on })
  }

  Column {
    visible: row.expanded
    width: parent.width
    spacing: Style.space(10)

    Item {
      width: parent.width
      implicitHeight: Math.max(brightness.implicitHeight, identifyBtn.implicitHeight)

      BrightnessRow {
        id: brightness
        visible: row.group && row.group.dimming
        bar: row.bar
        anchors.left: parent.left
        anchors.right: identifyBtn.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        value: row.group && row.group.on && row.group.brightness !== null ? row.group.brightness : 0
        onCommitted: function(v) { row.service.dimGroup(row.group, v) }
      }

      PanelActionButton {
        id: identifyBtn
        iconText: String.fromCodePoint(0xF0241)  // flash
        tooltipText: row.strings.identify
        foreground: row.bar.foreground
        fontFamily: row.bar.fontFamily
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        onClicked: row.service.identify("group", row.group.groupedLightId)
      }
    }

    LightModes {
      id: modes
      width: parent.width
      bar: row.bar
      target: row.group
      isGroup: true
      onSceneChosen: function(id) { row.service.recallScene(id) }
      onColorChosen: function(hex) { row.service.setGroup(row.group.groupedLightId, { color: hex }) }
      onMirekChosen: function(m) { row.service.setGroup(row.group.groupedLightId, { mirek: m }) }
    }

    // Lamps, indented under the room.
    Column {
      visible: row.lights.length > 1
      width: parent.width
      spacing: Style.space(8)

      PanelSeparator { foreground: row.bar.foreground; opacity: 0.5 }

      HintText { bar: row.bar; width: parent.width; text: row.strings.lights; font.pixelSize: Style.font.caption }

      Repeater {
        model: row.lights
        LightRow {
          required property var modelData
          x: Style.space(12)
          width: parent.width - Style.space(12)
          bar: row.bar
          service: row.service
          light: modelData
          expanded: row.expandedLightId === modelData.id
          onExpandToggled: row.expandedLightId = row.expandedLightId === modelData.id ? "" : modelData.id
        }
      }
    }
  }
}
