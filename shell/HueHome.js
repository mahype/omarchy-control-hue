// Hue home model: keeps the raw CLIP v2 resources, applies event-stream
// batches and derives the rooms, zones, scenes and lights the panel renders.
// Also the color math (CIE xy, mirek, RGB). Pure functions, no I/O.

var CHANGED = "changed"
var NEEDS_RESYNC = "resync"
var UNCHANGED = "unchanged"

// How far a light may drift from a scene's stored value before the scene no
// longer counts as active (the bridge keeps reporting it active regardless).
var XY_TOLERANCE = 0.03
var MIREK_TOLERANCE = 10

// ---- colors ------------------------------------------------------------------
// sRGB <-> CIE xy following Signify's conversion guidance (Wide RGB D65).
// Gamut clamping is left to the bridge.

function parseHex(value) {
  var match = String(value || "").trim().match(/^#?([0-9a-fA-F]{6})$/)
  if (!match) return null
  var digits = match[1]
  return [0, 2, 4].map(function(i) { return parseInt(digits.slice(i, i + 2), 16) })
}

function toLinear(v) { return v > 0.04045 ? Math.pow((v + 0.055) / 1.055, 2.4) : v / 12.92 }
function toGamma(v) { return v <= 0.0031308 ? 12.92 * v : 1.055 * Math.pow(v, 1 / 2.4) - 0.055 }
function round4(v) { return Math.round(v * 10000) / 10000 }
function round1(v) { return Math.round(Number(v) * 10) / 10 }

function hex(rgb) {
  return "#" + rgb.map(function(c) {
    var s = Math.max(0, Math.min(255, Math.round(c))).toString(16)
    return s.length < 2 ? "0" + s : s
  }).join("")
}

function rgbToXy(rgb) {
  var r = toLinear(rgb[0] / 255), g = toLinear(rgb[1] / 255), b = toLinear(rgb[2] / 255)
  var x = r * 0.664511 + g * 0.154324 + b * 0.162028
  var y = r * 0.283881 + g * 0.668433 + b * 0.047685
  var z = r * 0.000088 + g * 0.072310 + b * 0.986039
  var total = x + y + z
  // Black has no chromaticity; use the D65 white point.
  if (total <= 1e-12) return { x: 0.3127, y: 0.3290 }
  return { x: round4(x / total), y: round4(y / total) }
}

// Full-brightness display color for an xy value.
function xyToHex(x, y) {
  if (!(y > 1e-12)) return "#ffffff"
  var bigX = x / y, bigZ = (1 - x - y) / y
  var linear = [
    bigX * 1.656492 - 0.354851 - bigZ * 0.255038,
    -bigX * 0.707196 + 1.655397 + bigZ * 0.036152,
    bigX * 0.051713 - 0.121364 + bigZ * 1.011530
  ].map(function(c) { return Math.max(0, c) })
  var peak = Math.max.apply(null, linear)
  if (peak > 1) linear = linear.map(function(c) { return c / peak })
  return hex(linear.map(function(c) { return Math.min(1, Math.max(0, toGamma(c))) * 255 }))
}

// Approximate display color for a color temperature in mirek
// (Tanner Helland's blackbody approximation, in Kelvin / 100).
function mirekToHex(mirek) {
  var k = 1000000 / Math.max(1, Number(mirek)) / 100
  var r = k <= 66 ? 255 : 329.698727446 * Math.pow(k - 60, -0.1332047592)
  var g = k <= 66 ? 99.4708025861 * Math.log(k) - 161.1195681661 : 288.1221695283 * Math.pow(k - 60, -0.0755148492)
  var b = k >= 66 ? 255 : (k <= 19 ? 0 : 138.5177312231 * Math.log(k - 10) - 305.0447927307)
  return hex([r, g, b])
}

// ---- requests ------------------------------------------------------------------

function clampBrightness(value) {
  var n = Number(value)
  if (!isFinite(n)) return null
  return Math.max(0, Math.min(100, n))
}

// CLIP v2 body for a light or grouped light. change: { on, brightness, mirek, color }.
// Brightness above zero, a temperature or a color switch the light on unless
// `on` says otherwise. Returns null when there is nothing valid to send.
function stateBody(change) {
  change = change || {}
  var body = {}
  var turnOn = typeof change.on === "boolean" ? change.on : null
  if (change.brightness !== undefined && change.brightness !== null) {
    var brightness = clampBrightness(change.brightness)
    if (brightness === null) return null
    body.dimming = { brightness: brightness }
    if (turnOn === null) turnOn = brightness > 0
  }
  if (change.mirek !== undefined && change.mirek !== null) {
    var mirek = Math.round(Number(change.mirek))
    if (!isFinite(mirek)) return null
    body.color_temperature = { mirek: Math.max(153, Math.min(500, mirek)) }
    if (turnOn === null) turnOn = true
  }
  if (change.color !== undefined && change.color !== null) {
    var rgb = parseHex(change.color)
    if (!rgb) return null
    body.color = { xy: rgbToXy(rgb) }
    if (turnOn === null) turnOn = true
  }
  if (turnOn !== null) body.on = { on: turnOn }
  return Object.keys(body).length > 0 ? body : null
}

// ---- resource cache -------------------------------------------------------------

function get(value, path) {
  for (var i = 0; i < path.length; i++) {
    if (!value || typeof value !== "object" || !(path[i] in value)) return undefined
    value = value[path[i]]
  }
  return value
}

function merge(target, patch) {
  Object.keys(patch).forEach(function(key) {
    var value = patch[key]
    if (value && typeof value === "object" && !Array.isArray(value)
        && target[key] && typeof target[key] === "object" && !Array.isArray(target[key])) merge(target[key], value)
    else target[key] = value
  })
}

function createCache() { return { resources: {} } }

function replace(cache, resources) {
  var next = {}
  ;(resources || []).forEach(function(resource) {
    if (resource && resource.id) next[resource.id] = resource
  })
  cache.resources = next
  return cache
}

// Applies one event-stream batch in place.
function apply(cache, batch) {
  var result = UNCHANGED
  for (var i = 0; i < (batch || []).length; i++) {
    var event = batch[i]
    if (!event || !Array.isArray(event.data)) continue
    // Added or removed resources: a full reload is the simplest correct response.
    if (event.type === "add" || event.type === "delete") return NEEDS_RESYNC
    if (event.type !== "update") continue
    event.data.forEach(function(partial) {
      var existing = partial && cache.resources[partial.id]
      if (!existing) return
      merge(existing, partial)
      result = CHANGED
    })
  }
  return result
}

// Parses one `data:` payload of the event stream; null when it is not a batch.
function parseEventData(text) {
  try {
    var batch = JSON.parse(String(text || ""))
    return Array.isArray(batch) ? batch : null
  } catch (e) {
    return null
  }
}

function ofType(cache, type) {
  var out = []
  Object.keys(cache.resources).forEach(function(id) {
    if (cache.resources[id].type === type) out.push(cache.resources[id])
  })
  return out
}

function refs(resource, key, type) {
  return ((resource && resource[key]) || []).filter(function(ref) {
    return ref && ref.rtype === type && ref.rid
  }).map(function(ref) { return ref.rid })
}

// Names typed in the Hue app sometimes carry stray spaces.
function clean(name) { return String(name || "").trim() }

function device(cache, light) { return cache.resources[get(light, ["owner", "rid"])] }

function isPlug(cache, light) {
  var archetypes = [get(device(cache, light), ["product_data", "product_archetype"]), get(light, ["metadata", "archetype"])]
  return archetypes.some(function(a) { return String(a || "").indexOf("plug") >= 0 }) || !("dimming" in light)
}

function reachable(cache, light) {
  var dev = device(cache, light)
  if (!dev) return true
  var ids = refs(dev, "services", "zigbee_connectivity")
  for (var i = 0; i < ids.length; i++) {
    var status = get(cache.resources[ids[i]], ["status"])
    if (status) return status === "connected"
  }
  return true
}

function buildLight(cache, light) {
  var color = "color" in light
  var temperature = "color_temperature" in light
  var mirek = get(light, ["color_temperature", "mirek"])
  var mirekValid = !!get(light, ["color_temperature", "mirek_valid"])
  var mode = temperature && mirekValid && mirek !== undefined && mirek !== null ? "temperature" : (color ? "color" : "none")
  var shown = null
  if (mode === "temperature") shown = mirekToHex(mirek)
  else if (mode === "color") {
    var x = get(light, ["color", "xy", "x"]), y = get(light, ["color", "xy", "y"])
    if (x !== undefined && y !== undefined) shown = xyToHex(x, y)
  }
  var brightness = get(light, ["dimming", "brightness"])
  var deviceName = get(device(cache, light), ["metadata", "name"])
  return {
    id: light.id,
    name: clean(deviceName || get(light, ["metadata", "name"]) || "Hue"),
    on: !!get(light, ["on", "on"]),
    reachable: reachable(cache, light),
    plug: isPlug(cache, light),
    dimming: "dimming" in light,
    brightness: brightness !== undefined && brightness !== null ? round1(brightness) : null,
    color: color,
    temperature: temperature,
    mirek: mirek === undefined ? null : mirek,
    mirekMin: get(light, ["color_temperature", "mirek_schema", "mirek_minimum"]) || null,
    mirekMax: get(light, ["color_temperature", "mirek_schema", "mirek_maximum"]) || null,
    mode: mode,
    hex: shown,
    roomId: null,
    roomName: null
  }
}

// Light IDs of a room (children are devices) or zone (children are usually lights).
function memberLights(cache, group) {
  var ids = []
  ;(group.children || []).forEach(function(child) {
    if (!child || !child.rid) return
    if (child.rtype === "light") ids.push(child.rid)
    else if (child.rtype === "device" && cache.resources[child.rid])
      ids = ids.concat(refs(cache.resources[child.rid], "services", "light"))
  })
  return ids.filter(function(id, index) { return ids.indexOf(id) === index })
}

// Whether the lights still show what the scene set. The bridge keeps a scene
// "active" after a color or temperature change, so the stored actions are
// compared with the lights. Brightness is ignored: recalling at another
// brightness keeps the scene.
function sceneMatches(cache, scene) {
  var actions = scene.actions || []
  for (var i = 0; i < actions.length; i++) {
    var light = cache.resources[get(actions[i], ["target", "rid"])]
    var action = actions[i].action || {}
    if (!light) continue
    var lightOn = !!get(light, ["on", "on"])
    var wantedOn = get(action, ["on", "on"])
    if (typeof wantedOn === "boolean" && wantedOn !== lightOn) return false
    if (!lightOn) continue
    var mirekValid = !!get(light, ["color_temperature", "mirek_valid"])
    var wantedXy = get(action, ["color", "xy"])
    if (wantedXy) {
      var x = get(light, ["color", "xy", "x"]), y = get(light, ["color", "xy", "y"])
      if (mirekValid || x === undefined || y === undefined) return false
      if (Math.abs(x - (wantedXy.x || 0)) > XY_TOLERANCE || Math.abs(y - (wantedXy.y || 0)) > XY_TOLERANCE) return false
    }
    var wantedMirek = get(action, ["color_temperature", "mirek"])
    if (wantedMirek !== undefined && wantedMirek !== null) {
      var mirek = get(light, ["color_temperature", "mirek"])
      if (!mirekValid || mirek === undefined || mirek === null || Math.abs(mirek - wantedMirek) > MIREK_TOLERANCE) return false
    }
  }
  return true
}

function sceneActive(cache, scene) {
  var status = get(scene, ["status", "active"]) || "inactive"
  if (status === "inactive") return false
  // Dynamic scenes keep changing colors on purpose; trust the bridge there.
  return status === "dynamic_palette" || sceneMatches(cache, scene)
}

function byName(a, b) { return a.name.toLowerCase().localeCompare(b.name.toLowerCase()) }

function buildGroup(cache, group, kind, lights, scenes) {
  var groupedId = refs(group, "services", "grouped_light")[0]
  var grouped = groupedId ? cache.resources[groupedId] : null
  var members = memberLights(cache, group).map(function(id) { return lights[id] }).filter(Boolean)
  var plugs = members.filter(function(l) { return l.plug })
  var bulbs = members.filter(function(l) { return !l.plug })
  var own = scenes.filter(function(s) { return s.owner === group.id }).map(function(s) { return s.scene }).sort(byName)
  var active = own.filter(function(s) { return s.active })[0]
  var lit = bulbs.filter(function(l) { return l.on })
  var litColor = lit.filter(function(l) { return l.mode === "color" })[0]
  var litTemperature = lit.filter(function(l) { return l.mode === "temperature" })[0]
  var mode = active ? "scene" : (litColor ? "color" : (litTemperature ? "temperature" : "scene"))
  var shown = litColor || litTemperature
  var brightness = null
  if (lit.length > 0) {
    var levels = lit.map(function(l) { return l.brightness }).filter(function(v) { return v !== null })
    if (levels.length > 0) brightness = round1(levels.reduce(function(a, b) { return a + b }, 0) / levels.length)
  } else {
    var level = get(grouped, ["dimming", "brightness"])
    if (level !== undefined && level !== null) brightness = round1(level)
  }
  var tunable = bulbs.filter(function(l) { return l.temperature })
  var mins = tunable.map(function(l) { return l.mirekMin }).filter(function(v) { return v !== null })
  var maxs = tunable.map(function(l) { return l.mirekMax }).filter(function(v) { return v !== null })
  return {
    id: group.id,
    kind: kind,
    name: clean(get(group, ["metadata", "name"]) || "Hue"),
    archetype: get(group, ["metadata", "archetype"]) || "other",
    groupedLightId: grouped ? grouped.id : null,
    on: bulbs.length > 0 ? bulbs.some(function(l) { return l.on }) : !!get(grouped, ["on", "on"]),
    brightness: brightness,
    lightIds: bulbs.map(function(l) { return l.id }),
    plugIds: plugs.map(function(l) { return l.id }),
    scenes: own,
    activeSceneId: active ? active.id : null,
    dimming: bulbs.some(function(l) { return l.dimming }),
    color: bulbs.some(function(l) { return l.color }),
    temperature: tunable.length > 0,
    mirekMin: mins.length > 0 ? Math.min.apply(null, mins) : null,
    mirekMax: maxs.length > 0 ? Math.max.apply(null, maxs) : null,
    mode: mode,
    hex: shown ? shown.hex : null,
    mirek: litTemperature ? litTemperature.mirek : null
  }
}

function home(cache) {
  var lights = {}
  ofType(cache, "light").forEach(function(light) { lights[light.id] = buildLight(cache, light) })
  var scenes = ofType(cache, "scene").filter(function(s) { return get(s, ["group", "rid"]) }).map(function(s) {
    return {
      owner: s.group.rid,
      scene: { id: s.id, name: clean(get(s, ["metadata", "name"]) || "Scene"), active: sceneActive(cache, s) }
    }
  })
  // Rooms own their lights; zones only group them.
  ofType(cache, "room").forEach(function(room) {
    memberLights(cache, room).forEach(function(id) {
      if (!lights[id]) return
      lights[id].roomId = room.id
      lights[id].roomName = clean(get(room, ["metadata", "name"]))
    })
  })
  var groups = []
  ;["room", "zone"].forEach(function(kind) {
    groups = groups.concat(ofType(cache, kind).map(function(g) { return buildGroup(cache, g, kind, lights, scenes) }).sort(byName))
  })
  var homeGroup = ofType(cache, "grouped_light").filter(function(g) { return get(g, ["owner", "rtype"]) === "bridge_home" })[0]
  var ordered = Object.keys(lights).map(function(id) { return lights[id] }).sort(function(a, b) {
    var ra = a.roomName || "~", rb = b.roomName || "~"
    return ra !== rb ? ra.localeCompare(rb) : a.name.toLowerCase().localeCompare(b.name.toLowerCase())
  })
  return {
    groups: groups,
    lights: ordered,
    anyOn: ordered.some(function(l) { return l.on }),
    lightsOn: ordered.filter(function(l) { return l.on && !l.plug }).length,
    homeGroupedLightId: homeGroup ? homeGroup.id : null
  }
}

function bridgeName(cache) {
  var bridge = ofType(cache, "bridge")[0]
  return bridge ? get(device(cache, bridge), ["metadata", "name"]) || "" : ""
}

// ---- connecting by address --------------------------------------------------------

// `openssl s_client -connect <host>:443 -CAfile <Hue roots> -verify_return_error`:
// the bridge ID is the certificate's common name, and the chain must verify
// against Signify's roots. Returns the normalized ID or "".
function bridgeIdFromCertificate(text) {
  var output = String(text || "")
  if (!/Verify return code: 0 \(ok\)/.test(output)) return ""
  var match = output.match(/^subject=.*CN\s*=\s*([0-9A-Fa-f]{16})\s*$/m)
  return match ? match[1].toLowerCase() : ""
}

if (typeof module !== "undefined") module.exports = {
  CHANGED: CHANGED, NEEDS_RESYNC: NEEDS_RESYNC, UNCHANGED: UNCHANGED,
  parseHex: parseHex, rgbToXy: rgbToXy, xyToHex: xyToHex, mirekToHex: mirekToHex,
  stateBody: stateBody, createCache: createCache, replace: replace, apply: apply,
  parseEventData: parseEventData, home: home, bridgeName: bridgeName,
  sceneMatches: sceneMatches, bridgeIdFromCertificate: bridgeIdFromCertificate
}
