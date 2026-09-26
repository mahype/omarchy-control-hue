import QtQuick
import qs.Commons

Text {
  property QtObject bar: null
  textFormat: Text.PlainText
  wrapMode: Text.WordWrap
  color: bar ? bar.foreground : Color.foreground
  opacity: 0.6
  font.family: bar ? bar.fontFamily : Style.font.family
  font.pixelSize: Style.font.bodySmall
}
