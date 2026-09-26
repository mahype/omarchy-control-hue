import QtQuick
import Quickshell
import Quickshell.Io
import "HueBridge.js" as Hue
import "HueHome.js" as HueHome
import "Model.js" as Model
import "Profiles.js" as Profiles

// Owner of all Hue state. Mounted once per session; the bar widget and the
// panel reach it through `bar.shell.serviceFor(...)` and call only the action
// functions below.
//
// Everything runs on tools Omarchy already ships: curl for the bridge API and
// its event stream (verified against the bundled Hue root CAs, with the bridge
// ID as TLS name), openssl to read the ID of a bridge entered by address,
// secret-tool for the bridge key and avahi-browse for discovery. Profile
// shortcuts come from hypr/bindings.lua, which the user's Hyprland bindings
// include once.
Item {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  readonly property string secretService: "io.github.mahype.omarchy-control-hue"
  readonly property string deviceType: "omarchy-control-hue#desktop"
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy-control-hue"
  readonly property string configPath: configDir + "/config.json"
  readonly property string caFile: localPath("../certs/hue-ca-bundle.pem")
  readonly property var strings: Model.strings(Qt.locale().name)
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string hyprBindingsPath: (Quickshell.env("XDG_CONFIG_HOME") || (homeDir + "/.config")) + "/hypr/bindings.lua"
  // The installed plugin's path, so the include survives rebuilds of a checkout.
  readonly property string pluginBindingsPath: (Quickshell.env("XDG_CONFIG_HOME") || (homeDir + "/.config"))
    + "/omarchy/plugins/io.github.mahype.omarchy-control-hue/hypr/bindings.lua"

  // ---- State the panel reads ----------------------------------------------------

  // { state, bridge, home } — state: unconfigured, unpaired, connecting, ready,
  // unreachable or unauthorized.
  property var doc: null
  property var home: Model.emptyHome()
  readonly property bool installed: true
  property string error: ""
  property string statusMessage: ""
  property var bridges: []
  property bool bridgesLoaded: false
  property bool discovering: false
  property var pairingBridge: null
  property int pairingSecondsLeft: 0
  property bool identifying: false

  readonly property string state: doc ? String(doc.state || "") : ""
  readonly property bool ready: state === "ready"
  readonly property var bridge: config.bridge
  readonly property bool pairing: pairingBridge !== null
  readonly property bool setupBusy: discovering || pairing || identifying || secretStore.running

  property var config: ({ version: 1, bridge: null, profiles: [] })
  readonly property var profiles: config.profiles
  // False until the user's Hyprland bindings include the profile shortcuts.
  property bool bindingsInstalled: true
  // Credentials stay inside the service; they are never rendered or logged.
  property var credentials: null

  // Raw CLIP v2 resources, updated in place from the event stream.
  property var cache: HueHome.createCache()
  property int retryDelay: 1000

  function localPath(relative) {
    return decodeURIComponent(String(Qt.resolvedUrl(relative)).replace(/^file:\/\//, ""))
  }

  function errorText(code) {
    if (code === "unreachable") return strings.unreachable
    if (code === "unauthorized") return strings.unauthorized
    return strings.commandFailed
  }

  function bridgeInfo() {
    if (!bridge) return null
    var name = HueHome.bridgeName(cache)
    return { id: bridge.id, host: bridge.host, name: name || bridge.name }
  }

  function setState(next) {
    if (next !== "ready") home = Model.emptyHome()
    doc = { state: next, bridge: bridgeInfo(), home: next === "ready" ? home : null }
  }

  function publish() {
    var next = HueHome.home(cache)
    // The bridge reports a room change light by light; until a command has
    // settled, its expected result wins over those intermediate states so a
    // switch never flips back for a moment.
    var now = Date.now()
    overrides = overrides.filter(function(entry) { return entry.until > now })
    home = Model.applyOverrides(next, overrides, now)
    doc = { state: "ready", bridge: bridgeInfo(), home: home }
  }

  // ---- Optimistic updates -----------------------------------------------------------

  // How long a confirmed command keeps priority while the lights report in.
  readonly property int settleTime: 1500
  property var overrides: []

  function expect(key, kind, id, change) {
    overrides = overrides.filter(function(entry) { return entry.key !== key })
      .concat([{ key: key, kind: kind, id: id, change: change, until: Date.now() + 15000 }])
    home = Model.patchHome(home, kind, id, change)
    settleTimer.start()
  }

  function settle(key, ok) {
    var until = ok ? Date.now() + settleTime : 0
    overrides = overrides.map(function(entry) {
      return entry.key === key ? Object.assign({}, entry, { until: until }) : entry
    })
    // A failed command shows the real state right away.
    if (!ok && ready) publish()
  }

  // ---- Settings -------------------------------------------------------------------

  function normalizeConfig(raw) {
    var value = raw && typeof raw === "object" ? raw.bridge : null
    var id = Hue.normalizeBridgeId(value && value.id)
    var host = String(value && value.host || "").trim()
    return {
      version: 1,
      bridge: id && Hue.isHost(host) ? { id: id, host: host, name: String(value.name || "Hue Bridge") } : null,
      profiles: Profiles.normalize(raw && raw.profiles)
    }
  }

  // next: the fields to change; the rest stays as it is.
  function saveConfig(next) {
    var normalized = normalizeConfig(Object.assign({}, config, next))
    configFile.setText(JSON.stringify(normalized, null, 2) + "\n")
    applyConfig(normalized)
  }

  function applyConfig(next) {
    var before = config.bridge ? config.bridge.id + "@" + config.bridge.host : ""
    var after = next.bridge ? next.bridge.id + "@" + next.bridge.host : ""
    config = next
    if (before === after && doc) return
    disconnect()
    if (!next.bridge) setState("unconfigured")
    else loadCredentials()
  }

  // ---- Bridge requests --------------------------------------------------------------

  property var queue: []
  property var current: null

  // One curl at a time; bridges rate-limit and a queue keeps commands in order.
  function request(method, path, body, callback, target) {
    var text = Hue.curlConfig({
      bridge: target || bridge, method: method, path: path, body: body,
      key: target ? "" : (credentials ? credentials.applicationKey : ""), caFile: caFile
    })
    if (!text) { callback({ status: 0, body: null }); return }
    queue = queue.concat([{ config: text, callback: callback }])
    pump()
  }

  function clip(method, path, body, callback) {
    request(method, path, body, function(response) { callback(Hue.parseClip(response)) })
  }

  function pump() {
    if (http.running || queue.length === 0) return
    current = queue[0]
    queue = queue.slice(1)
    http.stdinEnabled = true
    http.running = true
  }

  // ---- Connection -----------------------------------------------------------------

  function loadCredentials() {
    credentials = null
    if (!bridge) return
    secretLookup.command = ["secret-tool", "lookup", "service", secretService, "bridge", bridge.id]
    secretLookup.running = true
  }

  function disconnect() {
    retryTimer.stop()
    resyncTimer.stop()
    publishTimer.stop()
    credentials = null
    stream.running = false
    overrides = []
    cache = HueHome.createCache()
  }

  function connect() {
    if (!bridge || !credentials) return
    if (!ready) setState("connecting")
    loadResources(true)
  }

  function loadResources(startStream) {
    clip("GET", "/clip/v2/resource", undefined, function(result) {
      if (!credentials) return
      if (!result.ok) {
        stream.running = false
        if (result.error === "unauthorized") {
          setState("unauthorized")
          return
        }
        setState("unreachable")
        error = errorText(result.error)
        retryTimer.interval = retryDelay
        retryDelay = Math.min(retryDelay * 2, 30000)
        retryTimer.restart()
        return
      }
      if (!ready) error = ""
      retryDelay = 1000
      HueHome.replace(cache, result.data)
      publish()
      resyncTimer.restart()
      if (startStream && !stream.running) openStream()
    })
  }

  // ---- Event stream -------------------------------------------------------------------

  function openStream() {
    var text = Hue.curlConfig({
      bridge: bridge, method: "GET", path: "/eventstream/clip/v2",
      key: credentials ? credentials.applicationKey : "", caFile: caFile, timeout: 86400
    })
    if (!text) return
    // Without this header the bridge answers once and closes instead of
    // streaming. An idle stream is dropped after five minutes and reopened.
    stream.config = text + "header = \"accept: text/event-stream\"\n"
      + "speed-limit = 1\nspeed-time = 300\n"
    stream.stdinEnabled = true
    stream.running = true
  }

  // The bridge sends each event batch as one `data:` line. SplitParser drops
  // the blank lines that end SSE events, so every data line is handled on its own.
  function streamLine(line) {
    if (line.indexOf("data:") !== 0) return
    var batch = HueHome.parseEventData(line.slice(5))
    if (!batch) return
    var applied = HueHome.apply(cache, batch)
    if (applied === HueHome.NEEDS_RESYNC) loadResources(false)
    else if (applied === HueHome.CHANGED && !publishTimer.running) publishTimer.start()
  }

  // ---- Controls ------------------------------------------------------------------------

  // One request in flight per control; newer values replace queued ones so a
  // dragged slider never builds up a backlog.
  property var inflight: ({})
  property var pending: ({})

  function send(key, job) {
    if (!ready) return false
    if (inflight[key]) {
      var queued = Object.assign({}, pending)
      queued[key] = job
      pending = queued
      return true
    }
    var busy = Object.assign({}, inflight)
    busy[key] = true
    inflight = busy
    clip("PUT", job.path, job.body, function(result) {
      var done = Object.assign({}, inflight)
      delete done[key]
      inflight = done
      error = result.ok ? "" : errorText(result.error)
      if (!pending[key]) settle(key, result.ok)
      var next = pending[key]
      if (next) {
        var rest = Object.assign({}, pending)
        delete rest[key]
        pending = rest
        send(key, next)
      }
    })
    return true
  }

  function put(key, type, id, body) {
    if (!body || !Hue.isUuid(id)) return false
    return send(key, { path: "/clip/v2/resource/" + type + "/" + id, body: body })
  }

  function setGroup(groupedLightId, change) {
    if (!groupedLightId) return false
    var key = "group:" + groupedLightId + ":" + Object.keys(change).join(",")
    expect(key, "group", groupedLightId, change)
    return put(key, "grouped_light", groupedLightId, HueHome.stateBody(change))
  }

  // With a scene active the scene is re-recalled at the new brightness, which
  // keeps its per-lamp proportions; otherwise the whole group is dimmed.
  function dimGroup(group, brightness) {
    if (!group || !group.groupedLightId) return false
    if (!group.activeSceneId) return setGroup(group.groupedLightId, { brightness: brightness })
    var level = HueHome.stateBody({ brightness: brightness })
    if (!level) return false
    var key = "group:" + group.groupedLightId + ":brightness"
    expect(key, "group", group.groupedLightId, { brightness: brightness })
    return put(key, "scene", group.activeSceneId,
      { recall: { action: "active", dimming: level.dimming } })
  }

  function setLight(lightId, change) {
    if (!lightId) return false
    var key = "light:" + lightId + ":" + Object.keys(change).join(",")
    expect(key, "light", lightId, change)
    return put(key, "light", lightId, HueHome.stateBody(change))
  }

  function recallScene(sceneId) {
    return put("scene:" + sceneId, "scene", sceneId, { recall: { action: "active" } })
  }

  function allOff() {
    var target = home.homeGroupedLightId
    if (!target) return false
    expect("all", "all-off", "", {})
    return put("all", "grouped_light", target, { on: { on: false } })
  }

  function allOn() {
    return setGroup(home.homeGroupedLightId, { on: true })
  }

  // ---- Profiles ------------------------------------------------------------------------

  // draft: { id (empty for a new profile), name, slot, lightIds, recapture }.
  // New lights are always saved with their current state.
  function saveProfile(draft) {
    if (!ready || !draft) return false
    var previous = draft.id ? Profiles.find(profiles, draft.id) : null
    var lights = Profiles.entries(draft.lightIds, previous, !previous || draft.recapture === true, function(id) {
      var light = cache.resources[id]
      return light && light.type === "light" ? Hue.restoreState(light) : null
    })
    var profile = Profiles.normalizeProfile({
      id: previous ? previous.id : Profiles.newId(Date.now(), Math.random()),
      name: draft.name, slot: draft.slot, lights: lights
    })
    if (!profile) { error = strings.commandFailed; return false }
    saveConfig({ profiles: Profiles.upsert(profiles, profile) })
    return true
  }

  function deleteProfile(id) {
    if (!Profiles.find(profiles, id)) return false
    saveConfig({ profiles: Profiles.remove(profiles, id) })
    return true
  }

  // key: slot number, profile ID or name. Lights outside the profile stay as they are.
  function applyProfile(key) {
    var profile = Profiles.find(profiles, key)
    if (!ready || !profile) return false
    profile.lights.forEach(function(entry) {
      if (!cache.resources[entry.id]) return
      var body = Profiles.lightBody(entry.state)
      var change = Profiles.expectedChange(entry.state, HueHome.xyToHex)
      if (!body || !change) return
      var requestKey = "light:" + entry.id + ":profile"
      expect(requestKey, "light", entry.id, change)
      put(requestKey, "light", entry.id, body)
    })
    return true
  }

  function installBindings() {
    var addition = Profiles.bindingsAppend(hyprBindings.loaded ? hyprBindings.text() : "",
      Profiles.includeBlock(pluginBindingsPath, homeDir))
    if (addition === "" || bindingsWriter.running) return false
    bindingsWriter.value = addition
    bindingsWriter.stdinEnabled = true
    bindingsWriter.running = true
    return true
  }

  // kind: "light" or "group" (a grouped light ID).
  function identify(kind, id) {
    return put("identify:" + id, kind === "group" ? "grouped_light" : "light", id, { alert: { action: "breathe" } })
  }

  // ---- Discovery, selection and pairing ---------------------------------------------------

  function discover() {
    if (discovering) return false
    error = ""
    statusMessage = strings.searching
    discovering = true
    bridges = []
    bridgesLoaded = false
    avahi.running = true
    return true
  }

  function finishDiscovery(found) {
    discovering = false
    statusMessage = ""
    bridges = found
    bridgesLoaded = true
    // Follow the selected bridge when DHCP gave it a new address.
    for (var i = 0; bridge && i < found.length; i++) {
      if (found[i].id === bridge.id && found[i].host !== bridge.host)
        saveConfig({ bridge: { id: bridge.id, host: found[i].host, name: bridge.name } })
    }
  }

  function useBridge(candidate) {
    if (!candidate || !Hue.normalizeBridgeId(candidate.id) || !Hue.isHost(candidate.host)) return false
    error = ""
    bridges = []
    bridgesLoaded = false
    saveConfig({ bridge: { id: candidate.id, host: candidate.host, name: candidate.name || "Hue Bridge" } })
    return true
  }

  // A bridge entered by address: its ID is read from the certificate, which
  // must chain to Signify's roots; everything after that is verified by ID.
  function connectHost(host) {
    var value = String(host || "").trim()
    if (!Hue.isHost(value) || identifying) { error = strings.commandFailed; return false }
    error = ""
    identifying = true
    certificate.host = value
    certificate.command = ["openssl", "s_client", "-connect",
      (value.indexOf(":") >= 0 ? "[" + value + "]" : value) + ":443",
      "-CAfile", caFile, "-verify_return_error"]
    certificate.running = true
    return true
  }

  function pair() {
    if (!bridge || pairing) return false
    error = ""
    pairingBridge = { id: bridge.id, host: bridge.host, name: bridge.name }
    pairingSecondsLeft = 30
    pairTimer.restart()
    attemptPairing()
    return true
  }

  function attemptPairing() {
    var target = pairingBridge
    if (!target) return
    request("POST", "/api", { devicetype: deviceType, generateclientkey: true }, function(response) {
      if (pairingBridge !== target) return
      var result = Hue.parsePairResponse(response)
      if (result.state === "paired") {
        stopPairing()
        storeCredentials(target, result.credentials)
      } else if (result.state === "error") {
        stopPairing()
        error = errorText(result.error)
      }
      // "waiting": pairTimer tries again until the link button is pressed.
    }, target)
  }

  function stopPairing() {
    pairingBridge = null
    pairTimer.stop()
  }

  function cancelPairing() {
    stopPairing()
    return true
  }

  function storeCredentials(target, value) {
    secretStore.value = value
    secretStore.command = ["secret-tool", "store", "--label", "Omarchy Control for Hue (" + target.id + ")",
      "service", secretService, "bridge", target.id]
    secretStore.stdinEnabled = true
    secretStore.running = true
  }

  function forget() {
    if (!bridge) return false
    Quickshell.execDetached(["secret-tool", "clear", "service", secretService, "bridge", bridge.id])
    saveConfig({ bridge: null })
    return true
  }

  // ---- Plumbing -----------------------------------------------------------------------------

  Process {
    id: http
    command: ["curl", "-K", "-"]
    stdout: StdioCollector { id: httpOut; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      write(root.current.config)
      stdinEnabled = false
    }
    onExited: {
      var done = root.current
      root.current = null
      var response = Hue.parseCurlOutput(httpOut.text)
      if (done) done.callback(response)
      Qt.callLater(root.pump)
    }
  }

  Process {
    id: stream
    property string config: ""
    command: ["curl", "-N", "-K", "-"]
    stdout: SplitParser { onRead: function(line) { root.streamLine(line) } }
    onStarted: {
      write(config)
      config = ""
      stdinEnabled = false
    }
    // The bridge closes streams now and then; reload and reconnect.
    onExited: if (root.ready && root.credentials) { retryTimer.interval = 1000; retryTimer.restart() }
  }

  Process {
    id: avahi
    command: ["timeout", "4", "avahi-browse", "-rpt", "_hue._tcp"]
    stdout: StdioCollector { id: avahiOut; waitForEnd: true }
    onExited: {
      var found = Hue.parseAvahi(avahiOut.text)
      if (found.length > 0) root.finishDiscovery(found)
      else cloudDiscovery.running = true
    }
  }

  Process {
    id: cloudDiscovery
    command: ["curl", "-sS", "--max-time", "8", Hue.DISCOVERY_URL]
    stdout: StdioCollector { id: cloudOut; waitForEnd: true }
    onExited: root.finishDiscovery(Hue.parseCloudDiscovery(cloudOut.text))
  }

  Process {
    id: certificate
    property string host: ""
    stdout: StdioCollector { id: certificateOut; waitForEnd: true }
    onExited: {
      var id = HueHome.bridgeIdFromCertificate(certificateOut.text)
      if (!id) {
        root.identifying = false
        root.error = root.strings.unreachable
        return
      }
      var target = { id: id, host: host }
      root.request("GET", "/api/0/config", undefined, function(response) {
        root.identifying = false
        var body = response.body || {}
        if (!response.status || Hue.normalizeBridgeId(body.bridgeid) !== id) {
          root.error = root.strings.unreachable
          return
        }
        root.useBridge({ id: id, host: target.host, name: String(body.name || "Hue Bridge") })
      }, target)
    }
  }

  Process {
    id: secretStore
    property var value: null
    onStarted: {
      write(JSON.stringify(value))
      value = null
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.error = root.strings.commandFailed; return }
      root.loadCredentials()
    }
  }

  Process {
    id: secretLookup
    stdout: StdioCollector { id: secretOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.credentials = exitCode === 0 ? Hue.parseCredentials(secretOut.text) : null
      if (root.credentials) root.connect()
      else root.setState("unpaired")
    }
  }

  Timer {
    id: pairTimer
    interval: 1000
    repeat: true
    // Counts down every second for the panel; asks the bridge every other one.
    onTriggered: {
      root.pairingSecondsLeft -= 1
      if (root.pairingSecondsLeft <= 0) {
        root.stopPairing()
        root.error = root.strings.pairFailed
      } else if (root.pairingSecondsLeft % 2 === 0) root.attemptPairing()
    }
  }

  Timer {
    id: retryTimer
    onTriggered: if (root.credentials) root.loadResources(true)
  }

  // Shows the bridge's own state once pending commands have settled.
  Timer {
    id: settleTimer
    interval: 250
    repeat: true
    onTriggered: {
      var now = Date.now()
      if (!root.overrides.some(function(entry) { return entry.until <= now })) return
      if (root.ready) root.publish()
      else root.overrides = []
      if (root.overrides.length === 0) stop()
    }
  }

  // Coalesces bursts of events into one update of the panel.
  Timer {
    id: publishTimer
    interval: 80
    onTriggered: if (root.ready) root.publish()
  }

  // A periodic full reload corrects anything the stream may have missed.
  Timer {
    id: resyncTimer
    interval: 300000
    repeat: true
    onTriggered: if (root.ready) root.loadResources(false)
  }

  // Appends the include block; tee -a never rewrites what is already there.
  Process {
    id: bindingsWriter
    property string value: ""
    command: ["tee", "-a", root.hyprBindingsPath]
    stdout: StdioCollector { waitForEnd: true }
    onStarted: {
      write(value)
      value = ""
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.error = root.strings.commandFailed; return }
      hyprBindings.reload()
      Quickshell.execDetached(["hyprctl", "reload"])
    }
  }

  FileView {
    id: hyprBindings
    property bool loaded: false
    path: root.hyprBindingsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      loaded = true
      root.bindingsInstalled = text().indexOf(Profiles.BINDINGS_MARKER) >= 0
    }
    onLoadFailed: {
      loaded = false
      root.bindingsInstalled = false
    }
  }

  // FileView does not create parent directories.
  Process {
    id: configDirProc
    command: ["install", "-d", "-m", "700", root.configDir]
    running: true
    onExited: configFile.reload()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var parsed = null
      try { parsed = JSON.parse(text()) } catch (e) { parsed = null }
      root.applyConfig(root.normalizeConfig(parsed))
    }
    onLoadFailed: root.applyConfig(root.normalizeConfig(null))
  }
}
