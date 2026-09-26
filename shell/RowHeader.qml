import QtQuick
import qs.Commons
import qs.Ui

// Collapsed row: color dot · name + subtitle · chevron · switch.
// Clicking anywhere but the switch expands the row.
Item {
  id: header

  property QtObject bar: null
  property string name: ""
  property string subtitle: ""
  property bool on: false
  property string hex: ""
  property bool reachable: true
  property bool expandable: true
  property bool expanded: false
  property bool compact: false
  property string glyph: ""

  signal expandToggled()
  signal switchToggled()

  readonly property real dotSize: compact ? Style.space(20) : Style.space(28)

  implicitHeight: Math.max(nameCol.implicitHeight, rowSwitch.implicitHeight, dotSize)
  opacity: reachable ? 1 : 0.45

  MouseArea {
    anchors.fill: parent
    enabled: header.expandable && header.reachable
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: header.expandToggled()
  }

  // Current light color; hollow while off.
  Rectangle {
    id: dot
    visible: header.glyph === ""
    width: header.dotSize
    height: width
    radius: width / 2
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    // Plain white bulbs report no color; show them as warm white.
    color: header.on ? (header.hex !== "" ? header.hex : "#ffe2bf") : "transparent"
    border.width: header.on ? 0 : Math.max(1, Style.space(2))
    border.color: Qt.rgba(header.bar.foreground.r, header.bar.foreground.g, header.bar.foreground.b, 0.35)
  }

  Text {
    visible: header.glyph !== ""
    width: header.dotSize
    horizontalAlignment: Text.AlignHCenter
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: header.glyph
    color: header.bar.foreground
    opacity: header.on ? 1 : 0.45
    font.family: header.bar.fontFamily
    font.pixelSize: Style.font.title
  }

  Column {
    id: nameCol
    anchors.left: parent.left
    anchors.leftMargin: header.dotSize + Style.space(10)
    anchors.right: chevron.visible ? chevron.left : rowSwitch.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      text: header.name
      color: header.bar.foreground
      font.family: header.bar.fontFamily
      font.pixelSize: header.compact ? Style.font.bodySmall : Style.font.body
      font.bold: !header.compact
      elide: Text.ElideRight
      width: parent.width
    }

    Text {
      textFormat: Text.PlainText
      text: header.subtitle
      visible: text !== ""
      color: header.bar.foreground
      opacity: 0.6
      font.family: header.bar.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      width: parent.width
    }
  }

  Text {
    id: chevron
    visible: header.expandable && header.reachable
    textFormat: Text.PlainText
    text: String.fromCodePoint(header.expanded ? 0xF0143 : 0xF0140)
    color: header.bar.foreground
    opacity: 0.6
    font.family: header.bar.fontFamily
    font.pixelSize: Style.font.body
    anchors.right: rowSwitch.left
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
  }

  ToggleSwitch {
    id: rowSwitch
    checked: header.on
    busy: !header.reachable
    foreground: header.bar.foreground
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    onToggled: header.switchToggled()
  }
}
