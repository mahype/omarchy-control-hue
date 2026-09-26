// Pure parsing, state and localization helpers. I/O belongs in Service.qml.

var STRINGS = {
  en: {
    title: "Hue", missing: "Required tools are missing",
    missingHint: "The plugin needs curl, openssl and secret-tool, which ship with Omarchy.",
    connecting: "Connecting to the Hue bridge…", unconfigured: "No Hue bridge selected",
    unpaired: "The Hue bridge is not paired yet", unauthorized: "The Hue bridge no longer accepts this computer",
    unreachable: "Hue bridge unreachable", error: "Hue needs attention",
    allOff: "All off", lightsOn: "%1 lights on", oneLightOn: "1 light on", allLightsOff: "All lights off",
    rooms: "ROOMS", zones: "ZONES", plugs: "PLUGS", lights: "Lights", zone: "Zone",
    scene: "Scene", color: "Color", temperature: "Temperature", warm: "warm", cold: "cold",
    noScenes: "This room has no scenes.", brightness: "Brightness",
    connection: "CONNECTION", bridge: "Bridge", findBridge: "Find Hue bridge", searching: "Searching…",
    noBridges: "No Hue bridge found. Enter its IP address instead.", select: "Select",
    manualHost: "IP address", connect: "Connect", pair: "Pair",
    pressLink: "Press the round link button on the Hue bridge now…", secondsLeft: "%1 seconds left", cancel: "Cancel",
    pairHint: "Press Pair, then the round button on top of the bridge within 30 seconds.",
    pairFailed: "The link button was not pressed in time.", forget: "Disconnect bridge",
    unreachableSince: "Unreachable", offline: "offline", commandFailed: "Hue command failed",
    keyboardHint: "Esc close · Tab switch panel", leftClick: "Click: open Hue controls",
    chooseScene: "Choose scene", identify: "Blink", on: "on", off: "off", unreachableShort: "unreachable",
    all: "All lights"
  },
  de: {
    title: "Hue", missing: "Benötigte Programme fehlen",
    missingHint: "Das Plugin braucht curl, openssl und secret-tool, die mit Omarchy geliefert werden.",
    connecting: "Verbinde mit der Hue Bridge…", unconfigured: "Keine Hue Bridge ausgewählt",
    unpaired: "Die Hue Bridge ist noch nicht gekoppelt", unauthorized: "Die Hue Bridge akzeptiert diesen Rechner nicht mehr",
    unreachable: "Hue Bridge nicht erreichbar", error: "Hue braucht Aufmerksamkeit",
    allOff: "Alles aus", lightsOn: "%1 Lampen an", oneLightOn: "1 Lampe an", allLightsOff: "Alle Lampen aus",
    rooms: "RÄUME", zones: "ZONEN", plugs: "STECKDOSEN", lights: "Lampen", zone: "Zone",
    scene: "Szene", color: "Farbe", temperature: "Temperatur", warm: "warm", cold: "kalt",
    noScenes: "Für diesen Raum gibt es keine Szenen.", brightness: "Helligkeit",
    connection: "VERBINDUNG", bridge: "Bridge", findBridge: "Hue Bridge suchen", searching: "Suche läuft…",
    noBridges: "Keine Hue Bridge gefunden. Gib stattdessen ihre IP-Adresse ein.", select: "Auswählen",
    manualHost: "IP-Adresse", connect: "Verbinden", pair: "Koppeln",
    pressLink: "Drück jetzt den runden Link-Button auf der Hue Bridge…", secondsLeft: "Noch %1 Sekunden", cancel: "Abbrechen",
    pairHint: "Klick auf Koppeln und drück dann innerhalb von 30 Sekunden den runden Knopf oben auf der Bridge.",
    pairFailed: "Der Link-Button wurde nicht rechtzeitig gedrückt.", forget: "Bridge trennen",
    unreachableSince: "Nicht erreichbar", offline: "offline", commandFailed: "Hue-Befehl fehlgeschlagen",
    keyboardHint: "Esc schließen · Tab Panel wechseln", leftClick: "Klick: Hue-Steuerung öffnen",
    chooseScene: "Szene wählen", identify: "Blinken lassen", on: "an", off: "aus", unreachableShort: "nicht erreichbar",
    all: "Alle Lampen"
  }
}

// English by default; German when the system locale is German (Qt.locale().name).
function strings(localeName) {
  return String(localeName || "").toLowerCase().indexOf("de") === 0 ? STRINGS.de : STRINGS.en
}

// Scene first, then color, temperature last — in order of how often they are used.
var TABS = ["scene", "color", "temperature"]

// Quick colors for the "Farbe" tab (hue 0–360, sat 0–100), shared with the Nanoleaf plugin.
var COLOR_PRESETS = [
  { h: 0, s: 100 }, { h: 28, s: 100 }, { h: 50, s: 100 }, { h: 120, s: 100 },
  { h: 175, s: 100 }, { h: 225, s: 100 }, { h: 275, s: 100 }, { h: 320, s: 100 }
]

function hueDistance(a, b) {
  var d = Math.abs(Number(a) - Number(b)) % 360
  return d > 180 ? 360 - d : d
}

function parseLine(line) {
  var doc
  try { doc = JSON.parse(String(line || "")) } catch (e) { return null }
  if (!doc || typeof doc !== "object") return null
  if (doc.type !== "state" && doc.type !== "result") return null
  return doc
}

function emptyHome() {
  return { groups: [], lights: [], anyOn: false, lightsOn: 0, homeGroupedLightId: null }
}

function lightById(home, id) {
  var lights = home && home.lights ? home.lights : []
  for (var i = 0; i < lights.length; i++) if (lights[i].id === id) return lights[i]
  return null
}

function lightsOf(home, ids) {
  var out = []
  for (var i = 0; i < (ids || []).length; i++) {
    var light = lightById(home, ids[i])
    if (light) out.push(light)
  }
  return out
}

function groupsOfKind(home, kind) {
  var groups = home && home.groups ? home.groups : []
  return groups.filter(function(group) { return group.kind === kind })
}

function plugs(home) {
  var lights = home && home.lights ? home.lights : []
  return lights.filter(function(light) { return light.plug })
}

// Tabs worth offering for a group or light, in fixed order.
function tabsFor(target, isGroup) {
  var tabs = []
  if (isGroup && target.scenes && target.scenes.length > 0) tabs.push("scene")
  if (target.color) tabs.push("color")
  if (target.temperature) tabs.push("temperature")
  return tabs
}

function initialTab(target, isGroup, chosen) {
  var tabs = tabsFor(target, isGroup)
  if (chosen && tabs.indexOf(chosen) >= 0) return chosen
  if (target.mode && tabs.indexOf(target.mode) >= 0) return target.mode
  return tabs.length > 0 ? tabs[0] : ""
}

// Color temperature: Hue speaks mirek, the slider shows Kelvin (warm left, cold right).
function kelvin(mirek) {
  return Math.round(1000000 / Math.max(1, Number(mirek)))
}

function mirek(kelvinValue) {
  return Math.round(1000000 / Math.max(1, Number(kelvinValue)))
}

function kelvinRange(target) {
  var warmest = Number(target.mirekMax || 500)
  var coldest = Number(target.mirekMin || 153)
  return { min: kelvin(Math.max(warmest, coldest)), max: kelvin(Math.min(warmest, coldest)) }
}

function sceneName(target) {
  var scenes = target && target.scenes ? target.scenes : []
  for (var i = 0; i < scenes.length; i++) if (scenes[i].active) return scenes[i].name
  return ""
}

// "65 % · Entspannen", "aus", "nicht erreichbar" …
function subtitle(target, isGroup, s) {
  if (!target) return ""
  if (!isGroup && target.reachable === false) return s.unreachableShort
  if (!target.on) return s.off
  var parts = []
  if (target.brightness !== null && target.brightness !== undefined && (isGroup ? target.dimming : target.dimming))
    parts.push(Math.round(Number(target.brightness)) + " %")
  var scene = isGroup ? sceneName(target) : ""
  if (scene) parts.push(scene)
  else if (target.mode === "color") parts.push(s.color)
  else if (target.mode === "temperature" && target.mirek) parts.push(Math.round(kelvin(target.mirek) / 100) * 100 + " K")
  return parts.length > 0 ? parts.join(" · ") : s.on
}

function summary(doc, installed, s) {
  if (!installed) return s.missing
  if (!doc) return s.connecting
  switch (doc.state) {
  case "ready":
    var count = doc.home ? Number(doc.home.lightsOn || 0) : 0
    if (count === 0) return s.allLightsOff
    return count === 1 ? s.oneLightOn : s.lightsOn.replace("%1", String(count))
  case "unconfigured": return s.unconfigured
  case "unpaired": return s.unpaired
  case "unauthorized": return s.unauthorized
  case "unreachable": return s.unreachable
  default: return s.error
  }
}

function needsAttention(doc, installed) {
  if (!installed) return true
  return !!doc && ["unreachable", "unauthorized", "error"].indexOf(doc.state) >= 0
}

function needsSetup(doc) {
  return !!doc && ["unconfigured", "unpaired", "unauthorized"].indexOf(doc.state) >= 0
}

function tooltip(doc, installed, error, s) {
  var lines = [s.title + ": " + summary(doc, installed, s)]
  if (error) lines.push(error)
  lines.push(s.leftClick)
  return lines.join("\n")
}

function compactError(text, fallback) {
  var lines = String(text || "").split("\n").map(function(line) { return line.trim() })
    .filter(function(line) { return line !== "" })
  var message = lines.length > 0 ? lines[lines.length - 1] : ""
  if (message.length > 180) message = message.slice(0, 177) + "…"
  return message || fallback
}

function parseJson(text) {
  try { return { ok: true, value: JSON.parse(String(text || "").trim()) } }
  catch (e) { return { ok: false, value: null } }
}

// Optimistic local edits so sliders and switches do not snap back while the
// bridge confirms. The next state line from the helper replaces this copy.
function patchHome(home, kind, id, change) {
  var next = JSON.parse(JSON.stringify(home || emptyHome()))
  function apply(target) {
    if ("on" in change) target.on = change.on
    if ("brightness" in change) {
      target.brightness = change.brightness
      if (!("on" in change)) target.on = change.brightness > 0
    }
    if ("mirek" in change) { target.mirek = change.mirek; target.mode = "temperature"; target.activeSceneId = null }
    if ("color" in change) { target.hex = change.color; target.mode = "color"; target.activeSceneId = null }
  }
  if (kind === "group") {
    for (var i = 0; i < next.groups.length; i++) {
      var group = next.groups[i]
      if (group.groupedLightId !== id) continue
      apply(group)
      var members = (group.lightIds || []).concat("on" in change ? (group.plugIds || []) : [])
      for (var j = 0; j < next.lights.length; j++)
        if (members.indexOf(next.lights[j].id) >= 0) apply(next.lights[j])
    }
  } else if (kind === "light") {
    for (var k = 0; k < next.lights.length; k++) if (next.lights[k].id === id) apply(next.lights[k])
  } else if (kind === "all-off") {
    next.groups.forEach(function(group) { group.on = false })
    next.lights.forEach(function(light) { light.on = false })
  }
  next.lightsOn = next.lights.filter(function(light) { return light.on && !light.plug }).length
  next.anyOn = next.lights.some(function(light) { return light.on })
  return next
}

if (typeof module !== "undefined") module.exports = {
  STRINGS: STRINGS, strings: strings, TABS: TABS, COLOR_PRESETS: COLOR_PRESETS, hueDistance: hueDistance,
  parseLine: parseLine, emptyHome: emptyHome, lightById: lightById, lightsOf: lightsOf,
  groupsOfKind: groupsOfKind, plugs: plugs, tabsFor: tabsFor, initialTab: initialTab,
  kelvin: kelvin, mirek: mirek, kelvinRange: kelvinRange, sceneName: sceneName, subtitle: subtitle,
  summary: summary, needsAttention: needsAttention, needsSetup: needsSetup, tooltip: tooltip,
  compactError: compactError, parseJson: parseJson, patchHome: patchHome
}
