// Run with: node tests/model.test.js
const assert = require("assert")
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "shell", "Model.js"), "utf8").replace(".pragma library", "")
const Model = {}
vm.runInNewContext(source + "\nObject.assign(exports, { strings, TABS, parseLine, lightsOf, groupsOfKind, plugs, tabsFor, initialTab, kelvin, mirek, kelvinRange, subtitle, hueDistance, summary, needsAttention, patchHome, compactError })", { exports: Model })

const home = {
  groups: [
    { id: "r1", kind: "room", name: "Küche", groupedLightId: "g1", on: true, brightness: 40, lightIds: ["l1"], plugIds: ["p1"],
      scenes: [{ id: "s1", name: "Lesen", active: true }], activeSceneId: "s1", color: true, temperature: true, mode: "scene" },
    { id: "z1", kind: "zone", name: "Arbeitsplatte", groupedLightId: "g2", on: false, lightIds: ["l1"], plugIds: [], scenes: [],
      color: false, temperature: true, mode: "temperature", mirekMin: 153, mirekMax: 454 }
  ],
  lights: [
    { id: "l1", name: "Lampe", on: true, plug: false, brightness: 40 },
    { id: "p1", name: "Kaffee", on: true, plug: true }
  ],
  anyOn: true, lightsOn: 1
}

let tests = 0
function test(name, fn) { fn(); tests++ }

test("tabs keep scene, color, temperature order and skip unsupported ones", () => {
  assert.deepStrictEqual(Array.from(Model.tabsFor(home.groups[0], true)), ["scene", "color", "temperature"])
  assert.deepStrictEqual(Array.from(Model.tabsFor(home.groups[1], true)), ["temperature"])
  assert.deepStrictEqual(Array.from(Model.tabsFor({ color: true, temperature: true, scenes: [{}] }, false)), ["color", "temperature"])
})

test("initial tab follows the user's choice, then the current mode", () => {
  assert.strictEqual(Model.initialTab(home.groups[0], true, ""), "scene")
  assert.strictEqual(Model.initialTab(home.groups[0], true, "color"), "color")
  assert.strictEqual(Model.initialTab(home.groups[1], true, "scene"), "temperature")
})

test("temperature converts between mirek and Kelvin", () => {
  assert.strictEqual(Model.kelvin(370), 2703)
  assert.strictEqual(Model.mirek(Model.kelvin(300)), 300)
  const range = Model.kelvinRange(home.groups[1])
  assert.strictEqual(range.min, 2203)
  assert.strictEqual(range.max, 6536)
})

test("subtitles name the scene, color or temperature", () => {
  const de = Model.strings("de_DE")
  assert.strictEqual(Model.subtitle({ ...home.groups[0], dimming: true }, true, de), "40 % · Lesen")
  assert.strictEqual(Model.subtitle(home.groups[1], true, de), "aus")
  assert.strictEqual(Model.subtitle({ on: true, dimming: true, brightness: 80, mode: "temperature", mirek: 370 }, false, de), "80 % · 2700 K")
  assert.strictEqual(Model.subtitle({ on: true, reachable: false }, false, de), "nicht erreichbar")
  assert.strictEqual(Model.hueDistance(350, 10), 20)
})

test("group edits patch members; switching off includes plugs", () => {
  const off = Model.patchHome(home, "group", "g1", { on: false })
  assert.strictEqual(off.groups[0].on, false)
  assert.strictEqual(off.lights[1].on, false)
  assert.strictEqual(off.anyOn, false)
  const dimmed = Model.patchHome(home, "group", "g1", { brightness: 70 })
  assert.strictEqual(dimmed.lights[0].brightness, 70)
  assert.strictEqual(dimmed.lights[1].on, true, "dimming leaves plugs alone")
  const colored = Model.patchHome(home, "group", "g1", { color: "#ff0000" })
  assert.strictEqual(colored.groups[0].mode, "color")
  assert.strictEqual(colored.groups[0].activeSceneId, null)
  assert.strictEqual(home.groups[0].on, true, "the original stays untouched")
})

test("all-off clears everything", () => {
  const next = Model.patchHome(home, "all-off", "", {})
  assert.ok(next.lights.every((light) => !light.on))
  assert.strictEqual(next.lightsOn, 0)
})

test("stream lines are validated", () => {
  assert.strictEqual(Model.parseLine("nope"), null)
  assert.strictEqual(Model.parseLine('{"state":"ready"}'), null)
  assert.strictEqual(Model.parseLine('{"type":"state","state":"ready"}').state, "ready")
})

test("English is the default, German follows a German locale", () => {
  assert.strictEqual(Model.strings().off, "off")
  assert.strictEqual(Model.strings("en_US").scene, "Scene")
  assert.strictEqual(Model.strings("de_AT").scene, "Szene")
})

test("summaries and attention", () => {
  const de = Model.strings("de_DE")
  assert.strictEqual(Model.summary({ state: "ready", home: { lightsOn: 3 } }, true, de), "3 Lampen an")
  assert.strictEqual(Model.summary({ state: "ready", home: { lightsOn: 0 } }, true, de), "Alle Lampen aus")
  assert.strictEqual(Model.summary(null, false, de), de.missing)
  assert.strictEqual(Model.needsAttention({ state: "unreachable" }, true), true)
  assert.strictEqual(Model.needsAttention({ state: "unpaired" }, true), false)
  assert.strictEqual(Model.compactError("a\nfinal problem\n", "x"), "final problem")
})

console.log(`${tests} tests passed`)
