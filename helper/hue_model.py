"""Keeps the raw CLIP v2 resources and derives the compact home model the panel renders."""

import hue_color

CHANGED, NEEDS_RESYNC, UNCHANGED = "changed", "resync", "unchanged"
# How far a light may drift from a scene's stored value before the scene no
# longer counts as active (the bridge keeps reporting it active regardless).
XY_TOLERANCE = 0.03
MIREK_TOLERANCE = 10


def _get(value, *path, default=None):
    for key in path:
        if not isinstance(value, dict) or key not in value:
            return default
        value = value[key]
    return value


def _merge(target, patch):
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            _merge(target[key], value)
        else:
            target[key] = value


class Cache:
    """Raw resources keyed by ID, updated in place from event-stream batches."""

    def __init__(self):
        self.resources = {}

    def replace(self, resources):
        self.resources = {r["id"]: r for r in resources if isinstance(r, dict) and r.get("id")}

    def apply(self, batch):
        result = UNCHANGED
        for event in batch:
            data = event.get("data") if isinstance(event, dict) else None
            if not isinstance(data, list):
                continue
            kind = event.get("type")
            if kind in ("add", "delete"):
                # A full reload is the simplest correct response.
                return NEEDS_RESYNC
            if kind != "update":
                continue
            for partial in data:
                existing = self.resources.get(_get(partial, "id"))
                if existing is not None:
                    _merge(existing, partial)
                    result = CHANGED
        return result

    def of_type(self, rtype):
        return [r for r in self.resources.values() if r.get("type") == rtype]

    def get(self, resource_id):
        return self.resources.get(resource_id)


def _refs(resource, key, rtype):
    return [ref.get("rid") for ref in resource.get(key) or []
            if isinstance(ref, dict) and ref.get("rtype") == rtype and ref.get("rid")]


def _clean(name):
    # Names typed in the Hue app sometimes carry stray spaces.
    return str(name).strip()


def _round1(value):
    return round(float(value) * 10) / 10


def _device(cache, light):
    return cache.get(_get(light, "owner", "rid"))


def _is_plug(cache, light):
    device = _device(cache, light) or {}
    archetypes = (_get(device, "product_data", "product_archetype") or "",
                  _get(light, "metadata", "archetype") or "")
    return any("plug" in a for a in archetypes) or "dimming" not in light


def _reachable(cache, light):
    device = _device(cache, light)
    if not device:
        return True
    for rid in _refs(device, "services", "zigbee_connectivity"):
        status = _get(cache.get(rid), "status")
        if status:
            return status == "connected"
    return True


def build_light(cache, light):
    color = "color" in light
    temperature = "color_temperature" in light
    mirek = _get(light, "color_temperature", "mirek")
    mirek_valid = bool(_get(light, "color_temperature", "mirek_valid"))
    if temperature and mirek_valid and mirek is not None:
        mode = "temperature"
    elif color:
        mode = "color"
    else:
        mode = "none"
    hex_value = None
    if mode == "temperature":
        hex_value = hue_color.mirek_to_hex(mirek)
    elif mode == "color":
        x, y = _get(light, "color", "xy", "x"), _get(light, "color", "xy", "y")
        if x is not None and y is not None:
            hex_value = hue_color.xy_to_hex(x, y)
    brightness = _get(light, "dimming", "brightness")
    device_name = _get(_device(cache, light), "metadata", "name")
    return {
        "id": light["id"],
        "name": _clean(device_name or _get(light, "metadata", "name") or "Hue"),
        "on": bool(_get(light, "on", "on")),
        "reachable": _reachable(cache, light),
        "plug": _is_plug(cache, light),
        "dimming": "dimming" in light,
        "brightness": _round1(brightness) if brightness is not None else None,
        "color": color,
        "temperature": temperature,
        "mirek": mirek,
        "mirekMin": _get(light, "color_temperature", "mirek_schema", "mirek_minimum"),
        "mirekMax": _get(light, "color_temperature", "mirek_schema", "mirek_maximum"),
        "mode": mode,
        "hex": hex_value,
        "roomId": None,
        "roomName": None,
    }


def member_lights(cache, group):
    """Light IDs of a room (children are devices) or zone (children are usually lights)."""
    ids = []
    for child in group.get("children") or []:
        rtype, rid = _get(child, "rtype"), _get(child, "rid")
        if rtype == "light" and rid:
            ids.append(rid)
        elif rtype == "device" and cache.get(rid):
            ids.extend(_refs(cache.get(rid), "services", "light"))
    return list(dict.fromkeys(ids))


def scene_matches(cache, scene):
    """Whether the lights still show what the scene set.

    The bridge keeps a scene "active" after a color or temperature change, so
    the stored actions are compared with the lights. Brightness is ignored:
    recalling at another brightness keeps the scene."""
    for entry in scene.get("actions") or []:
        light = cache.get(_get(entry, "target", "rid"))
        action = _get(entry, "action") or {}
        if not light:
            continue
        light_on = bool(_get(light, "on", "on"))
        wanted_on = _get(action, "on", "on")
        if wanted_on is not None and wanted_on != light_on:
            return False
        if not light_on:
            continue
        mirek_valid = bool(_get(light, "color_temperature", "mirek_valid"))
        wanted_xy = _get(action, "color", "xy")
        if isinstance(wanted_xy, dict):
            x, y = _get(light, "color", "xy", "x"), _get(light, "color", "xy", "y")
            if mirek_valid or x is None or y is None:
                return False
            if abs(x - wanted_xy.get("x", 0)) > XY_TOLERANCE or abs(y - wanted_xy.get("y", 0)) > XY_TOLERANCE:
                return False
        wanted_mirek = _get(action, "color_temperature", "mirek")
        if wanted_mirek is not None:
            mirek = _get(light, "color_temperature", "mirek")
            if not mirek_valid or mirek is None or abs(mirek - wanted_mirek) > MIREK_TOLERANCE:
                return False
    return True


def _scene_active(cache, scene):
    status = _get(scene, "status", "active") or "inactive"
    if status == "inactive":
        return False
    # Dynamic scenes keep changing colors on purpose; trust the bridge there.
    return status == "dynamic_palette" or scene_matches(cache, scene)


def build_group(cache, group, kind, lights, scenes):
    grouped = next((cache.get(rid) for rid in _refs(group, "services", "grouped_light")), None)
    members = [lights[i] for i in member_lights(cache, group) if i in lights]
    plugs = [l for l in members if l["plug"]]
    bulbs = [l for l in members if not l["plug"]]
    own_scenes = sorted((s for owner, s in scenes if owner == group["id"]), key=lambda s: s["name"].lower())
    active_scene = next((s["id"] for s in own_scenes if s["active"]), None)
    lit = [l for l in bulbs if l["on"]]
    lit_color = next((l for l in lit if l["mode"] == "color"), None)
    lit_temperature = next((l for l in lit if l["mode"] == "temperature"), None)
    if active_scene:
        mode = "scene"
    elif lit_color:
        mode = "color"
    elif lit_temperature:
        mode = "temperature"
    else:
        mode = "scene"
    shown = lit_color or lit_temperature
    if lit:
        levels = [l["brightness"] for l in lit if l["brightness"] is not None]
        brightness = _round1(sum(levels) / len(levels)) if levels else None
    else:
        level = _get(grouped, "dimming", "brightness")
        brightness = _round1(level) if level is not None else None
    tunable = [l for l in bulbs if l["temperature"]]
    return {
        "id": group["id"],
        "kind": kind,
        "name": _clean(_get(group, "metadata", "name") or "Hue"),
        "archetype": _get(group, "metadata", "archetype") or "other",
        "groupedLightId": _get(grouped, "id"),
        "on": any(l["on"] for l in bulbs) if bulbs else bool(_get(grouped, "on", "on")),
        "brightness": brightness,
        "lightIds": [l["id"] for l in bulbs],
        "plugIds": [l["id"] for l in plugs],
        "scenes": own_scenes,
        "activeSceneId": active_scene,
        "dimming": any(l["dimming"] for l in bulbs),
        "color": any(l["color"] for l in bulbs),
        "temperature": bool(tunable),
        "mirekMin": min((l["mirekMin"] for l in tunable if l["mirekMin"] is not None), default=None),
        "mirekMax": max((l["mirekMax"] for l in tunable if l["mirekMax"] is not None), default=None),
        "mode": mode,
        "hex": shown["hex"] if shown else None,
        "mirek": lit_temperature["mirek"] if lit_temperature else None,
    }


def home(cache):
    lights = {l["id"]: build_light(cache, l) for l in cache.of_type("light")}
    scenes = [
        (_get(s, "group", "rid"), {
            "id": s["id"],
            "name": _clean(_get(s, "metadata", "name") or "Scene"),
            "active": _scene_active(cache, s),
        })
        for s in cache.of_type("scene") if _get(s, "group", "rid")
    ]
    # Rooms own their lights; zones only group them.
    for room in cache.of_type("room"):
        for light_id in member_lights(cache, room):
            if light_id in lights:
                lights[light_id]["roomId"] = room["id"]
                lights[light_id]["roomName"] = _clean(_get(room, "metadata", "name") or "")
    groups = []
    for kind in ("room", "zone"):
        built = [build_group(cache, g, kind, lights, scenes) for g in cache.of_type(kind)]
        groups.extend(sorted(built, key=lambda g: g["name"].lower()))
    home_group = next((g["id"] for g in cache.of_type("grouped_light")
                       if _get(g, "owner", "rtype") == "bridge_home"), None)
    ordered = sorted(lights.values(), key=lambda l: (l["roomName"] or "~", l["name"].lower()))
    return {
        "groups": groups,
        "lights": ordered,
        "anyOn": any(l["on"] for l in ordered),
        "lightsOn": sum(1 for l in ordered if l["on"] and not l["plug"]),
        "homeGroupedLightId": home_group,
    }


def bridge_name(cache):
    bridge = next(iter(cache.of_type("bridge")), None)
    return _get(_device(cache, bridge or {}), "metadata", "name")
