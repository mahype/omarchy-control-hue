"""Unit tests for the Python helper. Run with: python3 -m unittest discover -s tests"""

import copy
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "helper"))

import hue_bridge  # noqa: E402
import hue_color  # noqa: E402
import hue_config  # noqa: E402
import hue_model  # noqa: E402
import main  # noqa: E402

FIXTURE = [
    {"id": "dev-lamp", "type": "device", "metadata": {"name": " Stehlampe "},
     "product_data": {"product_archetype": "sultan_bulb"},
     "services": [{"rid": "light-1", "rtype": "light"}, {"rid": "zb-1", "rtype": "zigbee_connectivity"}]},
    {"id": "zb-1", "type": "zigbee_connectivity", "owner": {"rid": "dev-lamp", "rtype": "device"}, "status": "connected"},
    {"id": "light-1", "type": "light", "owner": {"rid": "dev-lamp", "rtype": "device"},
     "metadata": {"name": "Hue color lamp 1", "archetype": "sultan_bulb"},
     "on": {"on": True}, "dimming": {"brightness": 42.37},
     "color_temperature": {"mirek": None, "mirek_valid": False,
                           "mirek_schema": {"mirek_minimum": 153, "mirek_maximum": 500}},
     "color": {"xy": {"x": 0.675, "y": 0.322}}},
    {"id": "dev-plug", "type": "device", "metadata": {"name": "Kaffeemaschine"},
     "product_data": {"product_archetype": "plug"}, "services": [{"rid": "light-2", "rtype": "light"}]},
    {"id": "light-2", "type": "light", "owner": {"rid": "dev-plug", "rtype": "device"},
     "metadata": {"name": "Plug", "archetype": "plug"}, "on": {"on": False}},
    {"id": "room-1", "type": "room", "metadata": {"name": "Küche", "archetype": "kitchen"},
     "children": [{"rid": "dev-lamp", "rtype": "device"}, {"rid": "dev-plug", "rtype": "device"}],
     "services": [{"rid": "gl-1", "rtype": "grouped_light"}]},
    {"id": "gl-1", "type": "grouped_light", "owner": {"rid": "room-1", "rtype": "room"},
     "on": {"on": True}, "dimming": {"brightness": 40.0}},
    {"id": "zone-1", "type": "zone", "metadata": {"name": "Arbeitsplatte", "archetype": "other"},
     "children": [{"rid": "light-1", "rtype": "light"}], "services": [{"rid": "gl-2", "rtype": "grouped_light"}]},
    {"id": "gl-2", "type": "grouped_light", "owner": {"rid": "zone-1", "rtype": "zone"}, "on": {"on": True}},
    {"id": "gl-home", "type": "grouped_light", "owner": {"rid": "home", "rtype": "bridge_home"}, "on": {"on": True}},
    {"id": "scene-1", "type": "scene", "metadata": {"name": "Lesen"}, "group": {"rid": "room-1", "rtype": "room"},
     "status": {"active": "inactive"},
     "actions": [{"target": {"rid": "light-1", "rtype": "light"},
                  "action": {"on": {"on": True}, "color_temperature": {"mirek": 366}}}]},
    {"id": "scene-2", "type": "scene", "metadata": {"name": "Entspannen"}, "group": {"rid": "room-1", "rtype": "room"},
     "status": {"active": "inactive"},
     "actions": [{"target": {"rid": "light-1", "rtype": "light"},
                  "action": {"on": {"on": True}, "color": {"xy": {"x": 0.67, "y": 0.32}}}}]},
]


def cache():
    c = hue_model.Cache()
    c.replace(copy.deepcopy(FIXTURE))
    return c


def group(home, name):
    return next(g for g in home["groups"] if g["name"] == name)


def light(home, light_id):
    return next(l for l in home["lights"] if l["id"] == light_id)


class ModelTest(unittest.TestCase):
    def test_rooms_split_plugs_from_lights_and_resolve_names(self):
        home = hue_model.home(cache())
        kitchen = group(home, "Küche")
        self.assertEqual(kitchen["lightIds"], ["light-1"])
        self.assertEqual(kitchen["plugIds"], ["light-2"])
        self.assertEqual(kitchen["groupedLightId"], "gl-1")
        self.assertEqual(kitchen["brightness"], 42.4)
        self.assertTrue(kitchen["color"] and kitchen["temperature"])
        self.assertEqual(kitchen["mode"], "color")
        self.assertEqual([s["name"] for s in kitchen["scenes"]], ["Entspannen", "Lesen"])
        lamp = light(home, "light-1")
        self.assertEqual(lamp["name"], "Stehlampe")  # trimmed
        self.assertEqual(lamp["roomName"], "Küche")
        self.assertTrue(lamp["reachable"])
        plug = light(home, "light-2")
        self.assertTrue(plug["plug"] and not plug["dimming"])
        self.assertEqual(group(home, "Arbeitsplatte")["kind"], "zone")
        self.assertEqual(home["homeGroupedLightId"], "gl-home")
        self.assertEqual(home["lightsOn"], 1)

    def test_events_update_state_and_active_scene(self):
        c = cache()
        applied = c.apply([{"type": "update", "data": [
            {"id": "scene-1", "type": "scene", "status": {"active": "static"}},
            {"id": "light-1", "type": "light", "color_temperature": {"mirek": 366, "mirek_valid": True}},
        ]}])
        self.assertEqual(applied, hue_model.CHANGED)
        home = hue_model.home(c)
        kitchen = group(home, "Küche")
        self.assertEqual(kitchen["mode"], "scene")
        self.assertEqual(kitchen["activeSceneId"], "scene-1")
        lamp = light(home, "light-1")
        self.assertEqual(lamp["mode"], "temperature")
        self.assertEqual(lamp["mirek"], 366)
        self.assertEqual(lamp["mirekMax"], 500, "untouched sibling fields survive the merge")

    def test_scene_reported_active_but_changed_afterwards_is_not_active(self):
        c = cache()
        c.apply([{"type": "update", "data": [{"id": "scene-1", "type": "scene", "status": {"active": "static"}}]}])
        # The lamp still shows its red color, not the scene's 366 mirek.
        kitchen = group(hue_model.home(c), "Küche")
        self.assertIsNone(kitchen["activeSceneId"])
        self.assertEqual(kitchen["mode"], "color")

    def test_color_scene_matches_within_tolerance(self):
        c = cache()
        c.apply([{"type": "update", "data": [{"id": "scene-2", "type": "scene", "status": {"active": "static"}}]}])
        self.assertEqual(group(hue_model.home(c), "Küche")["activeSceneId"], "scene-2")

    def test_additions_request_a_resync(self):
        applied = cache().apply([{"type": "add", "data": [{"id": "x", "type": "light"}]}])
        self.assertEqual(applied, hue_model.NEEDS_RESYNC)


class ColorTest(unittest.TestCase):
    def test_hex_parsing(self):
        self.assertEqual(hue_color.parse_hex("#ff8000"), (255, 128, 0))
        self.assertEqual(hue_color.parse_hex("00FF00"), (0, 255, 0))
        for bad in ("fff", "gg0000", ""):
            with self.assertRaises(ValueError):
                hue_color.parse_hex(bad)

    def test_primaries_and_round_trip_keep_the_dominant_channel(self):
        x, y = hue_color.rgb_to_xy((255, 0, 0))
        self.assertTrue(x > 0.65 and y < 0.35)
        for rgb in ((255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 128, 0)):
            back = hue_color.parse_hex(hue_color.xy_to_hex(*hue_color.rgb_to_xy(rgb)))
            self.assertEqual(back.index(max(back)), rgb.index(max(rgb)), f"{rgb} -> {back}")

    def test_warm_is_orange_and_cool_is_blueish(self):
        warm = hue_color.parse_hex(hue_color.mirek_to_hex(454))
        cool = hue_color.parse_hex(hue_color.mirek_to_hex(153))
        self.assertGreater(warm[0], warm[2])
        self.assertGreater(cool[2], warm[2])


class RequestTest(unittest.TestCase):
    def test_brightness_implies_on_and_zero_implies_off(self):
        body = main.state_body(brightness=55)
        self.assertEqual(body["on"], {"on": True})
        self.assertEqual(body["dimming"], {"brightness": 55.0})
        self.assertEqual(main.state_body(brightness=0)["on"], {"on": False})

    def test_explicit_on_wins_and_color_becomes_xy(self):
        body = main.state_body(on=False, color="ff0000")
        self.assertEqual(body["on"], {"on": False})
        self.assertGreater(body["color"]["xy"]["x"], 0.6)

    def test_invalid_changes_are_rejected(self):
        with self.assertRaises(ValueError):
            main.state_body()
        with self.assertRaises(ValueError):
            main.state_body(brightness=float("nan"))
        with self.assertRaises(ValueError):
            main.resource_type("../config")


class BridgeTest(unittest.TestCase):
    def test_bridge_ids_are_normalized_and_validated(self):
        self.assertEqual(hue_config.normalize_bridge_id(" ECB5FAFFFE8F7CA6 "), "ecb5fafffe8f7ca6")
        for bad in ("ecb5fafffe8f7ca", "ecb5fafffe8f7cag", None):
            with self.assertRaises(ValueError):
                hue_config.normalize_bridge_id(bad)

    def test_avahi_output_prefers_ipv4_and_decodes_names(self):
        output = "\n".join([
            "+;wlp8s0;IPv4;Hue\\032Bridge;_hue._tcp;local",
            '=;wlp8s0;IPv4;Hue\\032Bridge\\032-\\0328F7CA6;_hue._tcp;local;x.local;10.0.0.41;443;'
            '"bridgeid=ecb5fafffe8f7ca6" "modelid=BSB002"',
            '=;wlp8s0;IPv6;Hue\\032Bridge\\032-\\0328F7CA6;_hue._tcp;local;x.local;fe80::1;443;'
            '"bridgeid=ecb5fafffe8f7ca6" "modelid=BSB002"',
        ])
        self.assertEqual(hue_bridge.parse_avahi(output),
                         [{"id": "ecb5fafffe8f7ca6", "host": "10.0.0.41", "name": "Hue Bridge - 8F7CA6"}])

    def test_certificate_names_include_common_name_and_san(self):
        certificate = {"subject": ((("commonName", "ECB5FAFFFE8F7CA6"),),),
                       "subjectAltName": (("DNS", "other.example"),)}
        self.assertEqual(hue_bridge._certificate_names(certificate), {"ecb5fafffe8f7ca6", "other.example"})

    def test_event_batches_are_decoded_and_garbage_skipped(self):
        seen = []
        hue_bridge._dispatch('[{"type":"update","data":[]}]', seen.append)
        hue_bridge._dispatch("not json", seen.append)
        self.assertEqual(seen, [[{"type": "update", "data": []}]])

    def test_bundled_roots_load(self):
        self.assertIsNotNone(hue_bridge._trusted_context())


if __name__ == "__main__":
    unittest.main()
