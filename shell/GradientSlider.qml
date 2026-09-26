import QtQuick
import qs.Commons

// Slider on a colored gradient track (hue, saturation, color temperature).
// Commits on release, like PanelSlider.
Item {
  id: gs
  property QtObject bar: null
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property var stops: []
  property real liveValue: value
  property bool dragging: false
  signal committed(real value)

  onValueChanged: if (!dragging) liveValue = value

  implicitHeight: Style.space(22)
  readonly property real progress: Math.max(0, Math.min(1, (liveValue - minimum) / Math.max(0.0001, maximum - minimum)))

  Canvas {
    id: gsTrack
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    height: Style.space(8)
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var g = ctx.createLinearGradient(0, 0, width, 0)
      var n = gs.stops.length
      for (var i = 0; i < n; i++) g.addColorStop(n > 1 ? i / (n - 1) : 0, String(gs.stops[i]))
      var r = height / 2
      ctx.beginPath()
      ctx.moveTo(r, 0)
      ctx.arcTo(width, 0, width, height, r)
      ctx.arcTo(width, height, 0, height, r)
      ctx.arcTo(0, height, 0, 0, r)
      ctx.arcTo(0, 0, width, 0, r)
      ctx.closePath()
      ctx.fillStyle = g
      ctx.fill()
    }
    onWidthChanged: requestPaint()
    Connections {
      target: gs
      function onStopsChanged() { gsTrack.requestPaint() }
    }
  }

  Rectangle {
    width: Style.space(16)
    height: width
    radius: width / 2
    color: "transparent"
    border.width: Math.max(2, Style.space(3))
    border.color: gs.bar ? gs.bar.foreground : Color.foreground
    anchors.verticalCenter: gsTrack.verticalCenter
    x: Math.max(0, Math.min(gsTrack.width - width, gsTrack.width * gs.progress - width / 2))
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    function valueAt(x) {
      var p = Math.max(0, Math.min(1, x / Math.max(1, width)))
      return gs.minimum + p * (gs.maximum - gs.minimum)
    }
    onPressed: function(m) { gs.dragging = true; gs.liveValue = valueAt(m.x) }
    onPositionChanged: function(m) { if (gs.dragging) gs.liveValue = valueAt(m.x) }
    onReleased: { gs.dragging = false; gs.committed(gs.liveValue) }
  }
}
