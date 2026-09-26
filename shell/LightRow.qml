import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A single lamp or plug. Lamps expand to brightness · blink · color controls.
Column {
  id: row

  property QtObject bar: null
  property var service: null
  property var light: null
  property bool expanded: false
  property bool compact: true
  property bool showRoom: false
  signal expandToggled()

  readonly property var strings: Model.strings()
  readonly property bool expandable: light !== null && !light.plug && light.reachable !== false
    && (light.dimming || light.color || light.temperature)

  onExpandedChanged: if (!expanded) modes.reset()

  spacing: Style.space(10)

  RowHeader {
    width: parent.width
    bar: row.bar
    compact: row.compact
    name: row.light ? row.light.name + (row.showRoom && row.light.roomName ? " · " + row.light.roomName : "") : ""
    subtitle: row.light && !row.light.plug ? Model.subtitle(row.light, false, row.strings)
      : (row.light && row.light.reachable === false ? row.strings.unreachableShort : "")
    on: row.light ? row.light.on === true : false
    hex: row.light && row.light.hex ? row.light.hex : ""
    reachable: row.light ? row.light.reachable !== false : false
    glyph: row.light && row.light.plug ? String.fromCodePoint(0xF06A5) : ""  // power-plug
    expandable: row.expandable
    expanded: row.expanded
    onExpandToggled: row.expandToggled()
    onSwitchToggled: if (row.service) row.service.setLight(row.light.id, { on: !row.light.on })
  }

  Column {
    visible: row.expanded && row.expandable
    width: parent.width
    spacing: Style.space(10)

    Item {
      width: parent.width
      implicitHeight: Math.max(brightness.implicitHeight, identifyBtn.implicitHeight)

      BrightnessRow {
        id: brightness
        visible: row.light && row.light.dimming
        bar: row.bar
        anchors.left: parent.left
        anchors.right: identifyBtn.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        value: row.light && row.light.on && row.light.brightness !== null ? row.light.brightness : 0
        onCommitted: function(v) { row.service.setLight(row.light.id, { brightness: v }) }
      }

      PanelActionButton {
        id: identifyBtn
        iconText: String.fromCodePoint(0xF0241)  // flash
        tooltipText: row.strings.identify
        foreground: row.bar.foreground
        fontFamily: row.bar.fontFamily
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        onClicked: row.service.identify("light", row.light.id)
      }
    }

    LightModes {
      id: modes
      width: parent.width
      bar: row.bar
      target: row.light
      isGroup: false
      onColorChosen: function(hex) { row.service.setLight(row.light.id, { color: hex }) }
      onMirekChosen: function(m) { row.service.setLight(row.light.id, { mirek: m }) }
    }
  }
}
