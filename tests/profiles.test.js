// Run with: node --test tests/
const assert = require("assert")
const test = require("node:test")

const Profiles = require("../shell/Profiles.js")
const Model = require("../shell/Model.js")

const L1 = "11111111-1111-4111-8111-111111111111"
const L2 = "22222222-2222-4222-8222-222222222222"

const warm = { on: { on: true }, dimming: { brightness: 60 }, color_temperature: { mirek: 366 } }
const red = { on: { on: true }, dimming: { brightness: 80 }, color: { xy: { x: 0.675, y: 0.322 } } }
const off = { on: { on: false }, dimming: { brightness: 40 }, color: { xy: { x: 0.3, y: 0.3 } } }

function profile(id, slot, name) {
  return { id, name: name || id, slot, lights: [{ id: L1, state: warm }] }
}

test("normalize drops invalid profiles and lights and keeps slots unique", () => {
  const list = Profiles.normalize([
    profile("aaaa", 1, "Arbeiten"),
    profile("bbbb", 1, "Lesen"),
    { id: "cccc", name: "  ", slot: 2, lights: [{ id: L1, state: warm }] },
    { id: "dddd", name: "Leer", slot: 3, lights: [{ id: "not-a-uuid", state: warm }] },
    { id: "eeee", name: "Zehn", slot: 10, lights: [{ id: L2, state: red }, { id: L2, state: warm }] },
    profile("aaaa", 4, "Doppelt")
  ])
  assert.deepStrictEqual(list.map(p => [p.id, p.slot]), [["aaaa", 1], ["bbbb", 0], ["eeee", 0]])
  assert.strictEqual(list[2].lights.length, 1)
})

test("stored states keep only what the bridge accepts back", () => {
  assert.deepStrictEqual(Profiles.normalizeState({ on: { on: true }, dimming: { brightness: 140 }, color_temperature: { mirek: 366.4 }, color: { xy: { x: 0.1, y: 0.2 } }, alert: {} }),
    { on: { on: true }, dimming: { brightness: 100 }, color_temperature: { mirek: 366 } })
  assert.deepStrictEqual(Profiles.normalizeState({ on: { on: true }, color: { xy: { x: 0.1, y: 0.2 } } }),
    { on: { on: true }, color: { xy: { x: 0.1, y: 0.2 } } })
  assert.strictEqual(Profiles.normalizeState(null), null)
})

test("free slot is the lowest unused key", () => {
  const list = [profile("aaaa", 1), profile("bbbb", 2), profile("cccc", 4)]
  assert.strictEqual(Profiles.freeSlot(list, ""), 3)
  assert.strictEqual(Profiles.freeSlot(list, "bbbb"), 2)
  assert.strictEqual(Profiles.freeSlot(Profiles.SLOTS.map((s, i) => profile("p00" + i, s)), ""), 0)
})

test("saving on a taken key moves the key over", () => {
  const list = [profile("aaaa", 1), profile("bbbb", 2)]
  const next = Profiles.upsert(list, profile("cccc", 2))
  assert.deepStrictEqual(next.map(p => [p.id, p.slot]), [["aaaa", 1], ["bbbb", 0], ["cccc", 2]])
  assert.strictEqual(Profiles.slotOwner(list, 2, "cccc").id, "bbbb")
  assert.strictEqual(Profiles.slotOwner(list, 2, "bbbb"), null)
  const renamed = Profiles.upsert(next, Object.assign(profile("aaaa", 1), { name: "Neu" }))
  assert.deepStrictEqual(renamed.map(p => p.name), ["Neu", "bbbb", "cccc"])
})

test("profiles are found by key, ID or name", () => {
  const list = [profile("aaaa", 3, "Arbeiten"), profile("bbbb", 0, "Kino")]
  assert.strictEqual(Profiles.find(list, "3").id, "aaaa")
  assert.strictEqual(Profiles.find(list, 3).id, "aaaa")
  assert.strictEqual(Profiles.find(list, "bbbb").name, "Kino")
  assert.strictEqual(Profiles.find(list, "kino").id, "bbbb")
  assert.strictEqual(Profiles.find(list, "5"), null)
  assert.strictEqual(Profiles.find(list, ""), null)
})

test("editing keeps stored states unless asked to recapture", () => {
  const previous = { id: "aaaa", lights: [{ id: L1, state: warm }] }
  const capture = id => (id === L1 ? red : off)
  assert.deepStrictEqual(Profiles.entries([L1, L2, L2], previous, false, capture),
    [{ id: L1, state: warm }, { id: L2, state: Profiles.normalizeState(off) }])
  assert.deepStrictEqual(Profiles.entries([L1], previous, true, capture), [{ id: L1, state: red }])
  assert.deepStrictEqual(Profiles.entries([L1], null, true, () => null), [])
})

test("a lamp saved as off is only switched off", () => {
  assert.deepStrictEqual(Profiles.lightBody(off), { on: { on: false } })
  assert.deepStrictEqual(Profiles.lightBody(warm), warm)
  assert.deepStrictEqual(Profiles.expectedChange(off, () => "#000000"), { on: false })
  assert.deepStrictEqual(Profiles.expectedChange(warm, () => "#000000"), { on: true, brightness: 60, mirek: 366 })
  assert.deepStrictEqual(Profiles.expectedChange(red, () => "#ff0000"), { on: true, brightness: 80, color: "#ff0000" })
})

test("the bindings include is appended once and survives plugin removal", () => {
  const block = Profiles.includeBlock("/home/me/.config/omarchy/plugins/x/hypr/bindings.lua", "/home/me")
  assert.match(block, /^-- omarchy-control-hue: profile shortcuts\n/)
  assert.match(block, /\(os\.getenv\("HOME"\) or ""\) \.\. "\/\.config\/omarchy\/plugins\/x\/hypr\/bindings\.lua"/)
  assert.match(block, /io\.open\(control_hue_bindings, "r"\)/)
  assert.strictEqual(Profiles.bindingsAppend("", block), block)
  assert.strictEqual(Profiles.bindingsAppend("a\n", block), "\n" + block)
  assert.strictEqual(Profiles.bindingsAppend("a", block), "\n\n" + block)
  assert.strictEqual(Profiles.bindingsAppend("a\n\n", block), block)
  assert.strictEqual(Profiles.bindingsAppend("x\n" + block, block), "")
  assert.match(Profiles.includeBlock("/opt/a \"b\"/bindings.lua", "/home/me"), /"\/opt\/a \\"b\\"\/bindings\.lua"/)
})

test("editor lists lights by room, the rest last", () => {
  const home = {
    groups: [
      { id: "r1", kind: "room", name: "Küche", lightIds: [L1], plugIds: [] },
      { id: "z1", kind: "zone", name: "Zone", lightIds: [L1, L2], plugIds: [] }
    ],
    lights: [{ id: L1, name: "Decke" }, { id: L2, name: "Stehlampe" }]
  }
  assert.deepStrictEqual(Model.lightsByRoom(home, "Ohne Raum").map(s => [s.name, s.lights.map(l => l.name)]),
    [["Küche", ["Decke"]], ["Ohne Raum", ["Stehlampe"]]])
})
