import QtQuick
import qs.Commons
import qs.Ui

// Sun · slider · percent. Commits on release.
Item {
  id: bRow
  property QtObject bar: null
  property real value: 0
  signal committed(real value)

  implicitHeight: slider.implicitHeight
  opacity: enabled ? 1 : 0.4

  Text {
    id: sunIcon
    textFormat: Text.PlainText
    text: String.fromCodePoint(0xF00DF)  // brightness-6
    color: bRow.bar.foreground
    font.family: bRow.bar.fontFamily
    font.pixelSize: Style.font.body
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
  }

  PanelSlider {
    id: slider
    bar: bRow.bar
    minimum: 1
    maximum: 100
    step: 10
    integer: true
    value: bRow.value
    anchors.left: sunIcon.right
    anchors.leftMargin: Style.space(10)
    anchors.right: pct.left
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    onReleased: function(v) { bRow.committed(v) }
  }

  Text {
    id: pct
    textFormat: Text.PlainText
    text: Math.round(slider.liveValue) + " %"
    color: bRow.bar.foreground
    font.family: bRow.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
    horizontalAlignment: Text.AlignRight
    width: Style.space(40)
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
  }
}
