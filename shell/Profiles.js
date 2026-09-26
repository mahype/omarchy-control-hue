// Light profiles: a saved state for a chosen set of lights, optionally on a
// shortcut slot (SUPER + CTRL + ALT + 1…9). Pure functions, no I/O; the
// service captures the states from the raw CLIP v2 lights and sends them.

var SLOTS = [1, 2, 3, 4, 5, 6, 7, 8, 9]
var MAX_NAME = 60

// Marks the include block in ~/.config/hypr/bindings.lua.
var BINDINGS_MARKER = "-- omarchy-control-hue: profile shortcuts"

function isUuid(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(value || ""))
}

function cleanName(value) {
  return String(value || "").replace(/\s+/g, " ").trim().slice(0, MAX_NAME)
}

function number(value) {
  var n = Number(value)
  return isFinite(n) ? n : null
}

function xy(value) {
  var x = number(value && value.x), y = number(value && value.y)
  return x !== null && y !== null ? { x: x, y: y } : null
}

// Keeps only the parts of a stored light state the bridge accepts back.
function normalizeState(raw) {
  if (!raw || typeof raw !== "object") return null
  var state = { on: { on: !!(raw.on && raw.on.on) } }
  var brightness = number(raw.dimming && raw.dimming.brightness)
  if (brightness !== null) state.dimming = { brightness: Math.max(0, Math.min(100, brightness)) }
  var points = raw.gradient && Array.isArray(raw.gradient.points)
    ? raw.gradient.points.map(function(point) { return xy(point && point.color && point.color.xy) }).filter(Boolean) : []
  var mirek = number(raw.color_temperature && raw.color_temperature.mirek)
  var color = xy(raw.color && raw.color.xy)
  if (points.length > 0) {
    state.gradient = { points: points.map(function(p) { return { color: { xy: p } } }) }
    if (raw.gradient.mode) state.gradient.mode = String(raw.gradient.mode)
  } else if (mirek !== null) state.color_temperature = { mirek: Math.round(mirek) }
  else if (color) state.color = { xy: color }
  return state
}

function normalizeProfile(raw) {
  if (!raw || typeof raw !== "object") return null
  var id = String(raw.id || "")
  var name = cleanName(raw.name)
  if (!/^[a-z0-9]{4,32}$/.test(id) || !name) return null
  var seen = {}
  var lights = (Array.isArray(raw.lights) ? raw.lights : []).map(function(entry) {
    if (!entry || !isUuid(entry.id) || seen[entry.id]) return null
    var state = normalizeState(entry.state)
    if (!state) return null
    seen[entry.id] = true
    return { id: String(entry.id), state: state }
  }).filter(Boolean)
  if (lights.length === 0) return null
  var slot = Math.round(Number(raw.slot))
  return { id: id, name: name, slot: SLOTS.indexOf(slot) >= 0 ? slot : 0, lights: lights }
}

// Drops invalid entries and keeps every slot on at most one profile.
function normalize(list) {
  var used = {}
  var ids = {}
  return (Array.isArray(list) ? list : []).map(normalizeProfile).filter(function(profile) {
    if (!profile || ids[profile.id]) return false
    ids[profile.id] = true
    if (profile.slot && used[profile.slot]) profile.slot = 0
    if (profile.slot) used[profile.slot] = true
    return true
  })
}

function newId(now, random) {
  return (Number(now) || 0).toString(36) + Math.floor((Number(random) || 0) * 1e6).toString(36)
}

// Lowest slot no other profile uses, or 0 when all are taken.
function freeSlot(profiles, exceptId) {
  for (var i = 0; i < SLOTS.length; i++) {
    var taken = (profiles || []).some(function(p) { return p.slot === SLOTS[i] && p.id !== exceptId })
    if (!taken) return SLOTS[i]
  }
  return 0
}

function slotOwner(profiles, slot, exceptId) {
  if (!slot) return null
  var list = profiles || []
  for (var i = 0; i < list.length; i++) if (list[i].slot === slot && list[i].id !== exceptId) return list[i]
  return null
}

// Inserts or replaces a profile; a slot taken by another profile moves over.
function upsert(profiles, profile) {
  var replaced = false
  var next = (profiles || []).map(function(p) {
    if (p.id === profile.id) { replaced = true; return profile }
    return profile.slot && p.slot === profile.slot ? Object.assign({}, p, { slot: 0 }) : p
  })
  if (!replaced) next.push(profile)
  return normalize(next)
}

function remove(profiles, id) {
  return (profiles || []).filter(function(p) { return p.id !== id })
}

// A profile by slot number ("3"), ID or name (case-insensitive).
function find(profiles, key) {
  var list = profiles || []
  var text = String(key === undefined || key === null ? "" : key).trim()
  if (!text) return null
  var slot = /^[1-9]$/.test(text) ? Number(text) : 0
  var lower = text.toLowerCase()
  for (var i = 0; i < list.length; i++) if (slot && list[i].slot === slot) return list[i]
  for (var j = 0; j < list.length; j++) if (list[j].id === text) return list[j]
  for (var k = 0; k < list.length; k++) if (list[k].name.toLowerCase() === lower) return list[k]
  return null
}

// Builds the stored lights of a profile. capture(id) returns the current state
// of a light or null; states of lights not recaptured are kept.
function entries(lightIds, previous, recapture, capture) {
  var old = {}
  ;((previous && previous.lights) || []).forEach(function(entry) { old[entry.id] = entry.state })
  return (lightIds || []).filter(function(id, index, all) { return all.indexOf(id) === index }).map(function(id) {
    var state = (!recapture && old[id]) || normalizeState(capture(id))
    return state ? { id: id, state: state } : null
  }).filter(Boolean)
}

// CLIP v2 body that restores a stored state. A lamp saved as off is only
// switched off, so its color is not touched.
function lightBody(state) {
  var normalized = normalizeState(state)
  if (!normalized) return null
  if (!normalized.on.on) return { on: { on: false } }
  return normalized
}

// Change for the panel's optimistic update while the bridge reports in.
// toHex(x, y) and mirekHex(mirek) give display colors.
function expectedChange(state, toHex) {
  var normalized = normalizeState(state)
  if (!normalized) return null
  var change = { on: normalized.on.on }
  if (!change.on) return change
  if (normalized.dimming) change.brightness = normalized.dimming.brightness
  if (normalized.color_temperature) change.mirek = normalized.color_temperature.mirek
  else if (normalized.color) change.color = toHex(normalized.color.xy.x, normalized.color.xy.y)
  else if (normalized.gradient) change.color = toHex(normalized.gradient.points[0].color.xy.x, normalized.gradient.points[0].color.xy.y)
  return change
}

function shortcutLabel(slot) {
  return slot ? "Super + Ctrl + Alt + " + slot : ""
}

function luaString(value) {
  return "\"" + String(value).replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\n/g, "\\n") + "\""
}

// Include block for ~/.config/hypr/bindings.lua. The existence check keeps
// Hyprland's config loading when the plugin is removed.
function includeBlock(path, home) {
  var file = String(path || "")
  var expression = home && file.indexOf(home + "/") === 0
    ? "(os.getenv(\"HOME\") or \"\") .. " + luaString(file.slice(home.length))
    : luaString(file)
  return BINDINGS_MARKER + "\n"
    + "local control_hue_bindings = " + expression + "\n"
    + "local control_hue_file = io.open(control_hue_bindings, \"r\")\n"
    + "if control_hue_file then control_hue_file:close(); dofile(control_hue_bindings) end\n"
}

// Text to append to the user's bindings file, or "" when it is already there.
function bindingsAppend(current, block) {
  var text = String(current || "")
  if (text.indexOf(BINDINGS_MARKER) >= 0) return ""
  var separator = text === "" || /\n\n$/.test(text) ? "" : (/\n$/.test(text) ? "\n" : "\n\n")
  return separator + block
}

if (typeof module !== "undefined") module.exports = {
  SLOTS: SLOTS, BINDINGS_MARKER: BINDINGS_MARKER,
  normalizeState: normalizeState, normalizeProfile: normalizeProfile, normalize: normalize, newId: newId,
  freeSlot: freeSlot, slotOwner: slotOwner, upsert: upsert, remove: remove, find: find, entries: entries,
  lightBody: lightBody, expectedChange: expectedChange, shortcutLabel: shortcutLabel,
  includeBlock: includeBlock, bindingsAppend: bindingsAppend
}
