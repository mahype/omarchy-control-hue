import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Shared by every monitor. Owns the single `omarchy-light-control-hue watch` process, which
// streams the home state on stdout and takes light commands on stdin.
Item {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  property var doc: null
  property var home: Model.emptyHome()
  property bool installed: true
  property string streamError: ""
  property string lastError: ""
  property string statusMessage: ""
  property var bridges: []
  property bool bridgesLoaded: false
  property string setupOperation: ""

  readonly property string state: doc ? String(doc.state || "") : ""
  readonly property bool ready: state === "ready"
  readonly property var bridge: doc && doc.bridge ? doc.bridge : null
  readonly property string error: lastError || streamError
  readonly property bool setupBusy: setupProcess.running
  readonly property bool pairing: setupProcess.running && setupOperation === "pair"
  readonly property var strings: Model.strings(Qt.locale().name)

  // A development checkout runs straight from `cargo build --release`.
  readonly property string bundledHelper: {
    var url = String(Qt.resolvedUrl("../target/release/omarchy-light-control-hue"))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.slice(7)) : url
  }
  readonly property string locateHelper:
    "for c in \"$HOME/.local/bin/omarchy-light-control-hue\" \"$1\"; do [ -x \"$c\" ] && { h=\"$c\"; break; }; done; "
    + "[ -n \"$h\" ] || h=$(command -v omarchy-light-control-hue) || exit 127; "

  function helperCommand(args) {
    return ["sh", "-c", locateHelper + "shift; exec \"$h\" \"$@\"", "omarchy-light-control-hue", bundledHelper].concat(args)
  }

  // ---- stream ------------------------------------------------------------

  property int nextRequest: 1
  // One request in flight per control; newer values replace queued ones so a
  // dragged slider never builds up a backlog.
  property var inflight: ({})
  property var queued: ({})

  function take(line) {
    var message = Model.parseLine(line)
    if (!message) return
    installed = true
    if (message.type === "result") {
      finish(message)
      return
    }
    streamError = ""
    doc = message
    if (message.state === "ready" && message.home) home = message.home
    else if (message.state !== "ready") home = Model.emptyHome()
  }

  function finish(result) {
    var keys = Object.keys(inflight)
    for (var i = 0; i < keys.length; i++) {
      if (inflight[keys[i]] !== result.req) continue
      var copy = Object.assign({}, inflight)
      delete copy[keys[i]]
      inflight = copy
      if (queued[keys[i]]) {
        var request = queued[keys[i]]
        var rest = Object.assign({}, queued)
        delete rest[keys[i]]
        queued = rest
        dispatch(keys[i], request)
      }
      break
    }
    if (result.ok === false) lastError = Model.compactError(result.error, strings.commandFailed)
    else lastError = ""
  }

  function dispatch(key, request) {
    if (!watcher.running) return false
    var id = nextRequest++
    var copy = Object.assign({}, inflight)
    copy[key] = id
    inflight = copy
    watcher.write(JSON.stringify(Object.assign({ req: id }, request)) + "\n")
    return true
  }

  function send(key, request) {
    if (!ready) return false
    if (inflight[key] !== undefined) {
      var copy = Object.assign({}, queued)
      copy[key] = request
      queued = copy
      return true
    }
    return dispatch(key, request)
  }

  // ---- controls ----------------------------------------------------------

  function setGroup(groupedLightId, change) {
    if (!groupedLightId) return false
    home = Model.patchHome(home, "group", groupedLightId, change)
    return send("group:" + groupedLightId + ":" + Object.keys(change).join(","),
      Object.assign({ op: "set", target: "group", id: groupedLightId }, change))
  }

  // With a scene active the scene is re-recalled at the new brightness, which
  // keeps its per-lamp proportions; otherwise the whole group is dimmed.
  function dimGroup(group, brightness) {
    if (!group || !group.groupedLightId) return false
    if (!group.activeSceneId) return setGroup(group.groupedLightId, { brightness: brightness })
    home = Model.patchHome(home, "group", group.groupedLightId, { brightness: brightness })
    return send("group:" + group.groupedLightId + ":brightness",
      { op: "scene", id: group.activeSceneId, brightness: brightness })
  }

  function setLight(lightId, change) {
    if (!lightId) return false
    home = Model.patchHome(home, "light", lightId, change)
    return send("light:" + lightId + ":" + Object.keys(change).join(","),
      Object.assign({ op: "set", target: "light", id: lightId }, change))
  }

  function recallScene(sceneId, brightness) {
    var request = { op: "scene", id: sceneId }
    if (brightness !== undefined && brightness !== null) request.brightness = brightness
    return send("scene:" + sceneId, request)
  }

  function allOff() {
    home = Model.patchHome(home, "all-off", "", {})
    return send("all-off", { op: "all-off" })
  }

  function allOn() {
    return setGroup(home.homeGroupedLightId, { on: true })
  }

  // kind: "light" or "group" (a grouped light ID).
  function identify(kind, id) {
    if (!id) return false
    return send("identify:" + id, { op: "identify", target: kind, id: id })
  }

  // ---- setup -------------------------------------------------------------

  function runSetup(operation, args) {
    if (!installed || setupProcess.running) return false
    lastError = ""
    statusMessage = operation === "pair" ? strings.pressLink
      : operation === "discover" ? strings.searching : ""
    setupOperation = operation
    setupProcess.command = helperCommand(args)
    setupProcess.running = true
    return true
  }

  function discover() { return runSetup("discover", ["discover"]) }
  function useBridge(candidate) {
    if (!candidate || !candidate.id || !candidate.host) return false
    return runSetup("select", ["use", String(candidate.id), String(candidate.host), "--name", String(candidate.name || "Hue Bridge")])
  }
  function connectHost(host) {
    var value = String(host || "").trim()
    return value !== "" && runSetup("select", ["connect", value])
  }
  function pair() { return runSetup("pair", ["pair", "--wait", "30"]) }
  function forget() { return runSetup("forget", ["forget"]) }

  function restartWatcher() {
    inflight = ({})
    queued = ({})
    if (watcher.running) watcher.running = false
    else restart.restart()
  }

  Process {
    id: watcher
    command: root.helperCommand(["watch"])
    // stdin stays open for commands; closing it lets the helper exit with the shell.
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.take(line) } }
    stderr: SplitParser {
      onRead: function(line) {
        var message = Model.compactError(line, "")
        if (message) root.streamError = message
      }
    }
    onExited: function(exitCode) {
      root.inflight = ({})
      root.queued = ({})
      if (exitCode === 126 || exitCode === 127) {
        root.installed = false
        root.doc = null
        root.home = Model.emptyHome()
        root.streamError = ""
      }
      restart.interval = root.installed ? 1000 : 10000
      restart.restart()
    }
  }

  Timer {
    id: restart
    interval: 1000
    onTriggered: if (!watcher.running) watcher.running = true
  }

  Process {
    id: setupProcess
    command: []
    stdout: StdioCollector { id: setupOutput; waitForEnd: true }
    stderr: StdioCollector { id: setupError; waitForEnd: true }
    onExited: function(exitCode) {
      var operation = root.setupOperation
      root.setupOperation = ""
      root.statusMessage = ""
      if (exitCode === 126 || exitCode === 127) {
        root.installed = false
        return
      }
      if (exitCode !== 0) {
        root.lastError = operation === "pair" ? root.strings.pairFailed
          : Model.compactError(setupError.text || setupOutput.text, root.strings.commandFailed)
        return
      }
      if (operation === "discover") {
        var parsed = Model.parseJson(setupOutput.text)
        root.bridges = parsed.ok && Array.isArray(parsed.value) ? parsed.value : []
        root.bridgesLoaded = true
        return
      }
      root.bridges = []
      root.bridgesLoaded = false
      root.restartWatcher()
    }
  }

  Component.onCompleted: watcher.running = true
}
