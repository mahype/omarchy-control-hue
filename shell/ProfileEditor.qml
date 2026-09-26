import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Profiles.js" as Profiles

// Creates or edits a profile: name, lights (by room) and shortcut slot.
// Saving stores the current state of the chosen lights.
Column {
  id: editor

  property QtObject bar: null
  property var service: null
  property var home: null
  // The profile being edited; null for a new one.
  property var profile: null
  signal closed()

  readonly property var strings: Model.strings(Qt.locale().name)
  readonly property var profiles: service ? service.profiles : []
  readonly property var sections: Model.lightsByRoom(home, strings.otherLights)
  readonly property bool typing: nameField.activeFocus
  readonly property var slotOwner: Profiles.slotOwner(profiles, slot, profile ? profile.id : "")
  readonly property int selectedCount: Object.keys(selected).length
  readonly property bool canSave: nameField.text.trim() !== "" && selectedCount > 0

  property int slot: 0
  property var selected: ({})
  property var openRooms: ({})
  property bool recapture: false

  function reset() {
    nameField.text = profile ? profile.name : ""
    slot = profile ? profile.slot : Profiles.freeSlot(profiles, "")
    var chosen = {}
    if (profile) profile.lights.forEach(function(entry) { chosen[entry.id] = true })
    else (home && home.lights || []).forEach(function(light) { if (light.on) chosen[light.id] = true })
    selected = chosen
    openRooms = {}
    recapture = false
  }

  function setLights(ids, on) {
    var next = Object.assign({}, selected)
    ids.forEach(function(id) { if (on) next[id] = true; else delete next[id] })
    selected = next
  }

  function sectionState(section) {
    var count = section.lights.filter(function(light) { return editor.selected[light.id] }).length
    return count === 0 ? "none" : (count === section.lights.length ? "all" : "some")
  }

  function checkGlyph(state) {
    // checkbox-marked / checkbox-intermediate / checkbox-blank-outline
    return String.fromCodePoint(state === "all" ? 0xF0132 : (state === "some" ? 0xF0856 : 0xF0131))
  }

  function save() {
    if (!canSave || !service) return
    var ok = service.saveProfile({
      id: profile ? profile.id : "",
      name: nameField.text,
      slot: slot,
      lightIds: Object.keys(selected),
      recapture: recapture
    })
    if (ok) closed()
  }

  Component.onCompleted: reset()
  onProfileChanged: reset()

  spacing: Style.space(10)

  Text {
    textFormat: Text.PlainText
    text: editor.profile ? editor.strings.editProfile : editor.strings.saveProfile
    color: editor.bar.foreground
    font.family: editor.bar.fontFamily
    font.pixelSize: Style.font.body
    font.bold: true
    width: parent.width
    elide: Text.ElideRight
  }

  HintText {
    bar: editor.bar
    visible: !editor.profile
    width: parent.width
    text: editor.strings.profileHint
    font.pixelSize: Style.font.caption
  }

  TextField {
    id: nameField
    width: parent.width
    placeholderText: editor.strings.profileName
    font.family: editor.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
    foreground: editor.bar.foreground
    horizontalPadding: Style.spacing.controlGap
    verticalPadding: Style.spacing.controlPaddingY
    maximumLength: 60
    onAccepted: editor.save()
  }

  // ---------- Lights ----------
  HintText { bar: editor.bar; width: parent.width; text: editor.strings.profileLights; font.pixelSize: Style.font.caption }

  Column {
    width: parent.width
    spacing: Style.space(4)

    Repeater {
      model: editor.sections
      Column {
        id: section
        required property var modelData
        readonly property string checkState: editor.sectionState(modelData)
        readonly property bool open: editor.openRooms[modelData.id] === true
        width: parent.width
        spacing: Style.space(2)

        Item {
          width: parent.width
          implicitHeight: Style.space(26)

          // Checkbox and name toggle all lights of the room.
          Text {
            id: roomCheck
            textFormat: Text.PlainText
            text: editor.checkGlyph(section.checkState)
            color: editor.bar.foreground
            font.family: editor.bar.fontFamily
            font.pixelSize: Style.font.title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            textFormat: Text.PlainText
            text: section.modelData.name
            color: editor.bar.foreground
            font.family: editor.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
            anchors.left: roomCheck.right
            anchors.leftMargin: Style.space(8)
            anchors.right: roomChevron.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
          }

          MouseArea {
            anchors.left: parent.left
            anchors.right: roomChevron.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            cursorShape: Qt.PointingHandCursor
            onClicked: editor.setLights(section.modelData.lights.map(function(l) { return l.id }), section.checkState !== "all")
          }

          // The chevron shows the single lights.
          Text {
            id: roomChevron
            textFormat: Text.PlainText
            text: (section.modelData.lights.length > 1 ? section.modelData.lights.length + "  " : "")
              + String.fromCodePoint(section.open ? 0xF0143 : 0xF0140)
            color: editor.bar.foreground
            opacity: 0.6
            font.family: editor.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                var next = Object.assign({}, editor.openRooms)
                next[section.modelData.id] = !section.open
                editor.openRooms = next
              }
            }
          }
        }

        Repeater {
          model: section.open ? section.modelData.lights : []
          Item {
            required property var modelData
            readonly property bool checked: editor.selected[modelData.id] === true
            x: Style.space(20)
            width: section.width - Style.space(20)
            implicitHeight: Style.space(24)

            Text {
              id: lightCheck
              textFormat: Text.PlainText
              text: editor.checkGlyph(parent.checked ? "all" : "none")
              color: editor.bar.foreground
              font.family: editor.bar.fontFamily
              font.pixelSize: Style.font.body
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: modelData.name + (modelData.plug ? "  " + String.fromCodePoint(0xF06A5) : "")
              color: editor.bar.foreground
              opacity: modelData.reachable === false ? 0.45 : 1
              font.family: editor.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              anchors.left: lightCheck.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: editor.setLights([modelData.id], !parent.checked)
            }
          }
        }
      }
    }
  }

  // ---------- Shortcut ----------
  HintText { bar: editor.bar; width: parent.width; text: editor.strings.shortcut; font.pixelSize: Style.font.caption }

  Row {
    id: slotRow
    width: parent.width
    spacing: Style.space(3)
    readonly property real cell: (width - spacing * Profiles.SLOTS.length) / (Profiles.SLOTS.length + 1)

    Repeater {
      model: [0].concat(Profiles.SLOTS)
      Button {
        required property int modelData
        width: slotRow.cell
        text: modelData === 0 ? "–" : String(modelData)
        tooltipText: modelData === 0 ? editor.strings.noShortcut : Profiles.shortcutLabel(modelData)
        selected: editor.slot === modelData
        bordered: true
        foreground: editor.bar.foreground
        fontFamily: editor.bar.fontFamily
        fontSize: Style.font.bodySmall
        horizontalPadding: 0
        // Keys used by another profile stay available but look taken.
        opacity: modelData !== 0 && !selected && Profiles.slotOwner(editor.profiles, modelData, editor.profile ? editor.profile.id : "") ? 0.5 : 1
        onClicked: editor.slot = modelData
      }
    }
  }

  HintText {
    bar: editor.bar
    width: parent.width
    text: (editor.slot ? Profiles.shortcutLabel(editor.slot) : editor.strings.noShortcut)
      + (editor.slotOwner ? " · " + editor.strings.shortcutMoves.replace("%1", editor.slotOwner.name) : "")
    font.pixelSize: Style.font.caption
  }

  Toggle {
    visible: editor.profile !== null
    width: parent.width
    label: editor.strings.recapture
    description: editor.strings.recaptureHint
    checked: editor.recapture
    foreground: editor.bar.foreground
    fontFamily: editor.bar.fontFamily
    titleSize: Style.font.bodySmall
    onClicked: editor.recapture = !editor.recapture
  }

  // ---------- Actions ----------
  Item {
    width: parent.width
    implicitHeight: saveButton.implicitHeight

    Button {
      visible: editor.profile !== null
      anchors.left: parent.left
      text: editor.strings.delete
      foreground: editor.bar.urgent
      fontFamily: editor.bar.fontFamily
      fontSize: Style.font.bodySmall
      bordered: true
      onClicked: if (editor.service && editor.service.deleteProfile(editor.profile.id)) editor.closed()
    }

    Button {
      anchors.right: saveButton.left
      anchors.rightMargin: Style.space(6)
      text: editor.strings.cancel
      foreground: editor.bar.foreground
      fontFamily: editor.bar.fontFamily
      fontSize: Style.font.bodySmall
      onClicked: editor.closed()
    }

    Button {
      id: saveButton
      anchors.right: parent.right
      text: editor.strings.save
      foreground: editor.bar.foreground
      fontFamily: editor.bar.fontFamily
      fontSize: Style.font.bodySmall
      bordered: true
      enabled: editor.canSave
      onClicked: editor.save()
    }
  }
}
