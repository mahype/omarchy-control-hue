import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Szene · Farbe · Temperatur for a room, zone or single light. Switching the
// tab only changes the view; nothing is sent until a value is picked, so a
// stray click never ends a running scene.
Column {
  id: modes

  property QtObject bar: null
  property var target: null
  property bool isGroup: true

  signal sceneChosen(string sceneId)
  signal colorChosen(string hex)
  signal mirekChosen(int mirek)

  // UI-only state; reset() when the row collapses or the panel closes.
  property string viewMode: ""
  property bool sceneListOpen: false

  readonly property var strings: Model.strings(Qt.locale().name)
  readonly property var tabs: target ? Model.tabsFor(target, isGroup) : []
  readonly property string shownMode: target ? Model.initialTab(target, isGroup, viewMode) : ""
  readonly property var scenes: target && target.scenes ? target.scenes : []
  readonly property var activeScene: {
    for (var i = 0; i < scenes.length; i++) if (scenes[i].active) return scenes[i]
    return null
  }
  readonly property bool inColor: target !== null && target.mode === "color" && !!target.hex
  readonly property color currentColor: inColor ? target.hex : "#ff0000"

  function reset() {
    viewMode = ""
    sceneListOpen = false
  }

  function hexOf(hue, sat) {
    var c = Qt.hsva(Math.max(0, Math.min(359.9, hue)) / 360, Math.max(0, Math.min(100, sat)) / 100, 1, 1)
    function part(v) { var s = Math.round(v * 255).toString(16); return s.length < 2 ? "0" + s : s }
    return "#" + part(c.r) + part(c.g) + part(c.b)
  }

  visible: tabs.length > 0
  spacing: Style.space(10)

  ButtonGroup {
    visible: modes.tabs.length > 1
    options: modes.tabs.map(function(tab) { return { value: tab, label: modes.strings[tab] } })
    value: modes.shownMode
    focusable: false
    foreground: modes.bar.foreground
    fontFamily: modes.bar.fontFamily
    fontSize: Style.font.bodySmall
    onChanged: function(v) {
      modes.viewMode = v
      modes.sceneListOpen = false
    }
  }

  // ---------- Scene ----------
  Column {
    visible: modes.shownMode === "scene"
    width: parent.width
    spacing: Style.space(4)

    Button {
      width: parent.width
      text: (modes.activeScene ? modes.activeScene.name : modes.strings.chooseScene)
            + "  " + String.fromCodePoint(modes.sceneListOpen ? 0xF0143 : 0xF0140)
      foreground: modes.bar.foreground
      fontFamily: modes.bar.fontFamily
      fontSize: Style.font.bodySmall
      bordered: true
      enabled: modes.scenes.length > 0
      onClicked: modes.sceneListOpen = !modes.sceneListOpen
    }

    HintText {
      bar: modes.bar
      width: parent.width
      visible: modes.scenes.length === 0
      text: modes.strings.noScenes
    }

    // Inline list instead of a dropdown popup: popups are clipped to the
    // panel window.
    ListView {
      id: sceneList
      visible: modes.sceneListOpen
      width: parent.width
      height: Math.min(contentHeight, Style.space(28) * 6)
      clip: true
      interactive: contentHeight > height
      boundsBehavior: Flickable.StopAtBounds
      model: modes.sceneListOpen ? modes.scenes : []

      delegate: Rectangle {
        required property var modelData
        readonly property bool current: modelData.active === true
        width: sceneList.width
        height: Style.space(28)
        radius: Style.cornerRadius
        color: sceneMouse.containsMouse
          ? Qt.rgba(modes.bar.foreground.r, modes.bar.foreground.g, modes.bar.foreground.b, 0.08)
          : "transparent"

        Text {
          textFormat: Text.PlainText
          text: modelData.name
          color: parent.current ? Color.accent : modes.bar.foreground
          font.family: modes.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: parent.current
          elide: Text.ElideRight
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }

        MouseArea {
          id: sceneMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            modes.sceneChosen(modelData.id)
            modes.viewMode = ""
            modes.sceneListOpen = false
          }
        }
      }
    }
  }

  // ---------- Color ----------
  Column {
    visible: modes.shownMode === "color"
    width: parent.width
    spacing: Style.space(10)

    // Swatches spread over the full width.
    Row {
      id: swatchRow
      width: parent.width
      readonly property real swatch: Style.space(22)
      spacing: Model.COLOR_PRESETS.length > 1
        ? Math.max(Style.space(4), (width - swatch * Model.COLOR_PRESETS.length) / (Model.COLOR_PRESETS.length - 1))
        : 0

      Repeater {
        model: Model.COLOR_PRESETS
        Rectangle {
          required property var modelData
          readonly property bool current: modes.inColor
            && Model.hueDistance(modes.currentColor.hsvHue * 360, modelData.h) <= 8
            && Math.abs(modes.currentColor.hsvSaturation * 100 - modelData.s) <= 10
          width: swatchRow.swatch
          height: swatchRow.swatch
          radius: width / 2
          color: Qt.hsva(modelData.h / 360, modelData.s / 100, 1, 1)
          border.width: current ? Math.max(2, Style.space(3)) : 0
          border.color: modes.bar.foreground

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              modes.colorChosen(modes.hexOf(modelData.h, modelData.s))
              modes.viewMode = ""
            }
          }
        }
      }
    }

    // Free color: hue + saturation. Outside color mode the sliders start at
    // full saturation so a hue pick never comes out white.
    Column {
      width: parent.width
      spacing: Style.space(6)

      readonly property real currentHue: modes.inColor && modes.currentColor.hsvHue >= 0 ? modes.currentColor.hsvHue * 360 : 0
      readonly property real currentSat: modes.inColor ? modes.currentColor.hsvSaturation * 100 : 100
      // The slider runs from full color (left) to white (right).
      readonly property real pickedSat: 100 - satSlider.liveValue

      GradientSlider {
        id: hueSlider
        bar: modes.bar
        width: parent.width
        minimum: 0
        maximum: 360
        value: parent.currentHue
        stops: ["#ff0000", "#ffff00", "#00ff00", "#00ffff", "#0000ff", "#ff00ff", "#ff0000"]
        onCommitted: function(v) {
          modes.colorChosen(modes.hexOf(v, parent.pickedSat))
          modes.viewMode = ""
        }
      }

      GradientSlider {
        id: satSlider
        bar: modes.bar
        width: parent.width
        minimum: 0
        maximum: 100
        value: 100 - parent.currentSat
        stops: [Qt.hsva(hueSlider.liveValue / 360, 1, 1, 1), "#ffffff"]
        onCommitted: function(v) {
          modes.colorChosen(modes.hexOf(hueSlider.liveValue, 100 - v))
          modes.viewMode = ""
        }
      }
    }
  }

  // ---------- Color temperature ----------
  Column {
    visible: modes.shownMode === "temperature"
    width: parent.width
    spacing: Style.space(4)

    readonly property var range: modes.target ? Model.kelvinRange(modes.target) : ({ min: 2000, max: 6500 })

    GradientSlider {
      id: ctSlider
      bar: modes.bar
      width: parent.width
      minimum: parent.range.min
      maximum: parent.range.max
      value: modes.target && modes.target.mode === "temperature" && modes.target.mirek
        ? Model.kelvin(modes.target.mirek) : 2700
      stops: ["#ff9b3d", "#ffd3a6", "#fff6ed", "#dfe9ff"]
      onCommitted: function(v) {
        modes.mirekChosen(Model.mirek(v))
        modes.viewMode = ""
      }
    }

    Item {
      width: parent.width
      implicitHeight: ctValue.implicitHeight

      HintText { bar: modes.bar; text: modes.strings.warm; width: implicitWidth; anchors.left: parent.left }
      HintText {
        id: ctValue
        bar: modes.bar
        text: Math.round(ctSlider.liveValue / 100) * 100 + " K"
        width: implicitWidth
        opacity: 1
        anchors.horizontalCenter: parent.horizontalCenter
      }
      HintText { bar: modes.bar; text: modes.strings.cold; width: implicitWidth; anchors.right: parent.right }
    }
  }
}
