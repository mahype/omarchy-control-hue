const test = require("node:test")
const assert = require("node:assert/strict")
const Home = require("../shell/HueHome.js")

const FIXTURE = [
  { id: "dev-lamp", type: "device", metadata: { name: " Stehlampe " },
    product_data: { product_archetype: "sultan_bulb" },
    services: [{ rid: "light-1", rtype: "light" }, { rid: "zb-1", rtype: "zigbee_connectivity" }] },
  { id: "zb-1", type: "zigbee_connectivity", owner: { rid: "dev-lamp", rtype: "device" }, status: "connected" },
  { id: "light-1", type: "light", owner: { rid: "dev-lamp", rtype: "device" },
    metadata: { name: "Hue color lamp 1", archetype: "sultan_bulb" },
    on: { on: true }, dimming: { brightness: 42.37 },
    color_temperature: { mirek: null, mirek_valid: false, mirek_schema: { mirek_minimum: 153, mirek_maximum: 500 } },
    color: { xy: { x: 0.675, y: 0.322 } } },
  { id: "dev-plug", type: "device", metadata: { name: "Kaffeemaschine" },
    product_data: { product_archetype: "plug" }, services: [{ rid: "light-2", rtype: "light" }] },
  { id: "light-2", type: "light", owner: { rid: "dev-plug", rtype: "device" },
    metadata: { name: "Plug", archetype: "plug" }, on: { on: false } },
  { id: "room-1", type: "room", metadata: { name: "Küche", archetype: "kitchen" },
    children: [{ rid: "dev-lamp", rtype: "device" }, { rid: "dev-plug", rtype: "device" }],
    services: [{ rid: "gl-1", rtype: "grouped_light" }] },
  { id: "gl-1", type: "grouped_light", owner: { rid: "room-1", rtype: "room" }, on: { on: true }, dimming: { brightness: 40 } },
  { id: "zone-1", type: "zone", metadata: { name: "Arbeitsplatte", archetype: "other" },
    children: [{ rid: "light-1", rtype: "light" }], services: [{ rid: "gl-2", rtype: "grouped_light" }] },
  { id: "gl-2", type: "grouped_light", owner: { rid: "zone-1", rtype: "zone" }, on: { on: true } },
  { id: "gl-home", type: "grouped_light", owner: { rid: "home", rtype: "bridge_home" }, on: { on: true } },
  { id: "scene-1", type: "scene", metadata: { name: "Lesen" }, group: { rid: "room-1", rtype: "room" },
    status: { active: "inactive" },
    actions: [{ target: { rid: "light-1", rtype: "light" }, action: { on: { on: true }, color_temperature: { mirek: 366 } } }] },
  { id: "scene-2", type: "scene", metadata: { name: "Entspannen" }, group: { rid: "room-1", rtype: "room" },
    status: { active: "inactive" },
    actions: [{ target: { rid: "light-1", rtype: "light" }, action: { on: { on: true }, color: { xy: { x: 0.67, y: 0.32 } } } }] }
]

function cache() { return Home.replace(Home.createCache(), JSON.parse(JSON.stringify(FIXTURE))) }
function group(home, name) { return home.groups.find((g) => g.name === name) }
function light(home, id) { return home.lights.find((l) => l.id === id) }

test("rooms split plugs from lights and resolve trimmed device names", () => {
  const home = Home.home(cache())
  const kitchen = group(home, "Küche")
  assert.deepEqual(kitchen.lightIds, ["light-1"])
  assert.deepEqual(kitchen.plugIds, ["light-2"])
  assert.equal(kitchen.groupedLightId, "gl-1")
  assert.equal(kitchen.brightness, 42.4)
  assert.ok(kitchen.color && kitchen.temperature)
  assert.equal(kitchen.mode, "color")
  assert.deepEqual(kitchen.scenes.map((s) => s.name), ["Entspannen", "Lesen"])
  const lamp = light(home, "light-1")
  assert.equal(lamp.name, "Stehlampe")
  assert.equal(lamp.roomName, "Küche")
  assert.ok(lamp.reachable)
  const plug = light(home, "light-2")
  assert.ok(plug.plug && !plug.dimming)
  assert.equal(group(home, "Arbeitsplatte").kind, "zone")
  assert.equal(home.homeGroupedLightId, "gl-home")
  assert.equal(home.lightsOn, 1)
})

test("events update state and select the matching scene", () => {
  const c = cache()
  const applied = Home.apply(c, [{ type: "update", data: [
    { id: "scene-1", type: "scene", status: { active: "static" } },
    { id: "light-1", type: "light", color_temperature: { mirek: 366, mirek_valid: true } }
  ] }])
  assert.equal(applied, Home.CHANGED)
  const home = Home.home(c)
  assert.equal(group(home, "Küche").mode, "scene")
  assert.equal(group(home, "Küche").activeSceneId, "scene-1")
  const lamp = light(home, "light-1")
  assert.equal(lamp.mode, "temperature")
  assert.equal(lamp.mirek, 366)
  assert.equal(lamp.mirekMax, 500, "untouched sibling fields survive the merge")
})

test("a scene the bridge still reports active but no longer shows is not active", () => {
  const c = cache()
  Home.apply(c, [{ type: "update", data: [{ id: "scene-1", type: "scene", status: { active: "static" } }] }])
  const kitchen = group(Home.home(c), "Küche")
  assert.equal(kitchen.activeSceneId, null)
  assert.equal(kitchen.mode, "color")
})

test("a color scene matches within tolerance", () => {
  const c = cache()
  Home.apply(c, [{ type: "update", data: [{ id: "scene-2", type: "scene", status: { active: "static" } }] }])
  assert.equal(group(Home.home(c), "Küche").activeSceneId, "scene-2")
})

test("added or removed resources request a resync", () => {
  assert.equal(Home.apply(cache(), [{ type: "add", data: [{ id: "x", type: "light" }] }]), Home.NEEDS_RESYNC)
})

test("event stream payloads are decoded and garbage skipped", () => {
  assert.deepEqual(Home.parseEventData('[{"type":"update","data":[]}]'), [{ type: "update", data: [] }])
  assert.equal(Home.parseEventData("not json"), null)
  assert.equal(Home.parseEventData('{"a":1}'), null)
})

test("hex parsing", () => {
  assert.deepEqual(Home.parseHex("#ff8000"), [255, 128, 0])
  assert.deepEqual(Home.parseHex("00FF00"), [0, 255, 0])
  for (const bad of ["fff", "gg0000", ""]) assert.equal(Home.parseHex(bad), null)
})

test("primaries survive a round trip through xy", () => {
  const red = Home.rgbToXy([255, 0, 0])
  assert.ok(red.x > 0.65 && red.y < 0.35)
  for (const rgb of [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 128, 0]]) {
    const xy = Home.rgbToXy(rgb)
    const back = Home.parseHex(Home.xyToHex(xy.x, xy.y))
    assert.equal(back.indexOf(Math.max(...back)), rgb.indexOf(Math.max(...rgb)), `${rgb} -> ${back}`)
  }
})

test("warm temperatures are orange and cool ones blueish", () => {
  const warm = Home.parseHex(Home.mirekToHex(454))
  const cool = Home.parseHex(Home.mirekToHex(153))
  assert.ok(warm[0] > warm[2])
  assert.ok(cool[2] > warm[2])
})

test("state bodies: brightness implies on, zero implies off, explicit on wins", () => {
  assert.deepEqual(Home.stateBody({ brightness: 55 }), { dimming: { brightness: 55 }, on: { on: true } })
  assert.deepEqual(Home.stateBody({ brightness: 0 }).on, { on: false })
  const body = Home.stateBody({ on: false, color: "ff0000" })
  assert.deepEqual(body.on, { on: false })
  assert.ok(body.color.xy.x > 0.6)
  assert.deepEqual(Home.stateBody({ mirek: 999 }).color_temperature, { mirek: 500 })
})

test("state bodies reject empty or invalid changes", () => {
  assert.equal(Home.stateBody({}), null)
  assert.equal(Home.stateBody({ brightness: NaN }), null)
  assert.equal(Home.stateBody({ color: "red" }), null)
})

test("bridge ID comes only from a verified certificate", () => {
  const verified = "CONNECTED(00000003)\n---\nsubject=C=NL, O=Philips Hue, CN=ECB5FAFFFE8F7CA6\nissuer=C=NL\n---\n    Verify return code: 0 (ok)\n"
  assert.equal(Home.bridgeIdFromCertificate(verified), "ecb5fafffe8f7ca6")
  assert.equal(Home.bridgeIdFromCertificate(verified.replace("0 (ok)", "21 (unable to verify the first certificate)")), "")
  assert.equal(Home.bridgeIdFromCertificate("subject=CN=example.com\n    Verify return code: 0 (ok)\n"), "")
})
