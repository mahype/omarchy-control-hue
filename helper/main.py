#!/usr/bin/env python3
"""omarchy-light-control-hue helper — the process boundary between the Omarchy
shell plugin and a Hue bridge. Python standard library only.

Every command prints JSON on stdout and a single error line on stderr.
`watch` streams the home state as JSON lines and accepts requests on stdin:

stdout: {"type":"state",...} whenever the home changes and
        {"type":"result","req":…,"ok":…} for each request.
stdin:  one request per line, e.g. {"req":1,"op":"set","target":"group","id":…}.
        Closing stdin ends the process, so it never outlives the shell.
"""

import argparse
import json
import math
import os
import queue
import sys
import threading
import time

import hue_color
import hue_config
import hue_model
from hue_bridge import Bridge, BridgeError, Unauthorized, discover, identify

DEBOUNCE = 0.08
RESYNC_INTERVAL = 300
MAX_BACKOFF = 30

_stdout_lock = threading.Lock()


def emit_line(value):
    line = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    with _stdout_lock:
        try:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            os._exit(0)


# ---------------------------------------------------------------------------
# state changes shared by the one-shot commands and the watch protocol

def clamp_brightness(value):
    value = float(value)
    if not math.isfinite(value):
        raise ValueError("brightness must be a number")
    return max(0.0, min(100.0, value))


def state_body(on=None, brightness=None, mirek=None, color=None):
    body = {}
    turn_on = on
    if brightness is not None:
        brightness = clamp_brightness(brightness)
        body["dimming"] = {"brightness": brightness}
        turn_on = turn_on if turn_on is not None else brightness > 0
    if mirek is not None:
        body["color_temperature"] = {"mirek": max(153, min(500, int(mirek)))}
        turn_on = turn_on if turn_on is not None else True
    if color is not None:
        x, y = hue_color.rgb_to_xy(hue_color.parse_hex(color))
        body["color"] = {"xy": {"x": x, "y": y}}
        turn_on = turn_on if turn_on is not None else True
    if turn_on is not None:
        body["on"] = {"on": bool(turn_on)}
    if not body:
        raise ValueError("nothing to change; pass on, brightness, mirek or color")
    return body


def resource_type(target):
    types = {"light": "light", "group": "grouped_light"}
    if target not in types:
        raise ValueError(f"unknown target {target}")
    return types[target]


def execute(bridge, request):
    op = request.get("op")
    if op == "set":
        body = state_body(request.get("on"), request.get("brightness"),
                          request.get("mirek"), request.get("color"))
        bridge.put(resource_type(request.get("target")), str(request.get("id")), body)
    elif op == "scene":
        recall = {"action": "active"}
        if request.get("brightness") is not None:
            recall["dimming"] = {"brightness": clamp_brightness(request["brightness"])}
        bridge.put("scene", str(request.get("id")), {"recall": recall})
    elif op == "identify":
        bridge.put(resource_type(request.get("target")), str(request.get("id")),
                   {"alert": {"action": "breathe"}})
    elif op == "all-off":
        cache = hue_model.Cache()
        cache.replace(bridge.resources())
        home_group = hue_model.home(cache)["homeGroupedLightId"]
        if not home_group:
            raise BridgeError("the bridge reported no home group")
        bridge.put("grouped_light", home_group, {"on": {"on": False}})
    else:
        raise ValueError(f"unknown request {op!r}")


# ---------------------------------------------------------------------------
# one-shot commands

def selected():
    bridge = hue_config.load()
    if not bridge:
        raise RuntimeError("no Hue bridge selected; run `discover` and `use` first")
    return bridge


def connected():
    bridge = selected()
    key = hue_config.load_key(bridge["id"])
    if not key:
        raise RuntimeError("the Hue bridge is not paired; run `pair` first")
    return Bridge(bridge, key)


def pair(wait):
    bridge = selected()
    deadline = time.monotonic() + wait
    while True:
        key = Bridge(bridge).register()
        if key:
            hue_config.store_key(bridge["id"], key)
            emit_line({"paired": True})
            return
        if time.monotonic() >= deadline:
            emit_line({"paired": False})
            raise RuntimeError("the link button on the Hue bridge was not pressed")
        time.sleep(1.5)


def forget():
    bridge = hue_config.load()
    if bridge:
        hue_config.forget_key(bridge["id"])
    config_file = hue_config.config_dir() / "config.json"
    config_file.unlink(missing_ok=True)
    emit_line({"forgotten": True})


# ---------------------------------------------------------------------------
# watch

class Shared:
    """The bridge the request thread uses; None while not connected."""

    def __init__(self):
        self._lock = threading.Lock()
        self._bridge = None

    def set(self, bridge):
        with self._lock:
            self._bridge = bridge

    def get(self):
        with self._lock:
            return self._bridge


class Emitter:
    def __init__(self):
        self.last = None

    def emit(self, value):
        value = dict(value, type="state")
        line = json.dumps(value, sort_keys=True)
        if line != self.last:
            emit_line(value)
            self.last = line


def serve_requests(shared):
    for line in sys.stdin:
        if not line.strip():
            continue
        request_id = None
        try:
            request = json.loads(line)
            request_id = request.get("req")
            bridge = shared.get()
            if bridge is None:
                raise RuntimeError("the Hue bridge is not connected")
            execute(bridge, request)
            emit_line({"type": "result", "req": request_id, "ok": True})
        except Exception as error:  # every failure becomes a result line
            emit_line({"type": "result", "req": request_id, "ok": False, "error": str(error)})
    os._exit(0)


def bridge_json(bridge):
    return {"id": bridge["id"], "host": bridge["host"], "name": bridge["name"]}


def park():
    """States only a user action resolves; the plugin restarts `watch` afterwards."""
    threading.Event().wait()


def watch():
    shared = Shared()
    threading.Thread(target=serve_requests, args=(shared,), daemon=True).start()
    out = Emitter()
    backoff = [1]
    while True:
        shared.set(None)
        try:
            bridge_config = hue_config.load()
        except RuntimeError as error:
            out.emit({"state": "error", "error": str(error)})
            park()
        if not bridge_config:
            out.emit({"state": "unconfigured"})
            park()
        info = bridge_json(bridge_config)
        try:
            key = hue_config.load_key(bridge_config["id"])
        except RuntimeError as error:
            out.emit({"state": "error", "bridge": info, "error": str(error)})
            time.sleep(MAX_BACKOFF)
            continue
        if not key:
            out.emit({"state": "unpaired", "bridge": info})
            park()
        bridge = Bridge(bridge_config, key)
        try:
            session(bridge, info, out, shared, backoff)
            time.sleep(1)
        except Unauthorized:
            shared.set(None)
            out.emit({"state": "unauthorized", "bridge": info})
            park()
        except (BridgeError, OSError) as error:
            shared.set(None)
            out.emit({"state": "unreachable", "bridge": info, "error": str(error)})
            time.sleep(backoff[0])
            backoff[0] = min(backoff[0] * 2, MAX_BACKOFF)


def session(bridge, info, out, shared, backoff):
    cache = hue_model.Cache()
    cache.replace(bridge.resources())

    def ready():
        details = dict(info)
        name = hue_model.bridge_name(cache)
        if name:
            details["name"] = name
        return {"state": "ready", "bridge": details, "home": hue_model.home(cache)}

    out.emit(ready())
    shared.set(bridge)
    backoff[0] = 1

    batches = queue.Queue()
    stop = threading.Event()
    failure = []

    def read_stream():
        try:
            bridge.events(batches.put, stop.is_set)
        except Exception as error:
            failure.append(error)
        finally:
            batches.put(None)

    threading.Thread(target=read_stream, daemon=True).start()
    pending = None
    next_resync = time.monotonic() + RESYNC_INTERVAL
    try:
        while True:
            now = time.monotonic()
            if pending is not None and now >= pending:
                pending = None
                out.emit(ready())
            if now >= next_resync:
                cache.replace(bridge.resources())
                out.emit(ready())
                next_resync = now + RESYNC_INTERVAL
            deadline = min(pending if pending is not None else next_resync, next_resync)
            try:
                batch = batches.get(timeout=max(0.0, deadline - time.monotonic()))
            except queue.Empty:
                continue
            if batch is None:
                if failure:
                    raise failure[0]
                return
            applied = cache.apply(batch)
            if applied == hue_model.NEEDS_RESYNC:
                cache.replace(bridge.resources())
            if applied != hue_model.UNCHANGED and pending is None:
                pending = time.monotonic() + DEBOUNCE
    finally:
        stop.set()


# ---------------------------------------------------------------------------
# command line

def _bool(value):
    if value.lower() in ("true", "on", "1", "yes"):
        return True
    if value.lower() in ("false", "off", "0", "no"):
        return False
    raise argparse.ArgumentTypeError("expected true or false")


def parser():
    root = argparse.ArgumentParser(prog="omarchy-light-control-hue",
                                   description="Control Philips Hue lights from Omarchy")
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("discover", help="find Hue bridges on the local network")
    connect = commands.add_parser("connect", help="select a bridge by address")
    connect.add_argument("host")
    use = commands.add_parser("use", help="select a discovered bridge")
    use.add_argument("id")
    use.add_argument("host")
    use.add_argument("--name", default="Hue Bridge")
    pair_cmd = commands.add_parser("pair", help="register with the bridge (press its link button)")
    pair_cmd.add_argument("--wait", type=int, default=30)
    commands.add_parser("forget", help="remove the stored key and bridge selection")
    commands.add_parser("watch", help="stream the home state as JSON lines")
    set_cmd = commands.add_parser("set", help="change a light or a room/zone")
    set_cmd.add_argument("target", choices=["light", "group"])
    set_cmd.add_argument("id")
    set_cmd.add_argument("--on", type=_bool)
    set_cmd.add_argument("--brightness", type=float)
    set_cmd.add_argument("--mirek", type=int)
    set_cmd.add_argument("--color")
    scene = commands.add_parser("scene", help="activate a scene")
    scene.add_argument("id")
    scene.add_argument("--brightness", type=float)
    ident = commands.add_parser("identify", help="let a light or room blink")
    ident.add_argument("target", choices=["light", "group"])
    ident.add_argument("id")
    commands.add_parser("all-off", help="switch off every light")
    return root


def run(args):
    if args.command == "discover":
        emit_line(discover())
    elif args.command == "connect":
        bridge = identify(args.host)
        hue_config.save(bridge)
        emit_line(bridge)
    elif args.command == "use":
        bridge = {"id": hue_config.normalize_bridge_id(args.id), "host": args.host, "name": args.name}
        hue_config.save(bridge)
        emit_line(bridge)
    elif args.command == "pair":
        pair(args.wait)
    elif args.command == "forget":
        forget()
    elif args.command == "watch":
        watch()
    else:
        request = {"op": args.command}
        if args.command == "set":
            request.update(target=args.target, id=args.id, on=args.on, brightness=args.brightness,
                           mirek=args.mirek, color=args.color)
        elif args.command == "scene":
            request.update(id=args.id, brightness=args.brightness)
        elif args.command == "identify":
            request.update(target=args.target, id=args.id)
        execute(connected(), request)
        emit_line({"ok": True})


def main():
    try:
        run(parser().parse_args())
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
