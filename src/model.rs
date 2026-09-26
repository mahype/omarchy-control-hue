//! Keeps the raw CLIP v2 resources and derives the compact home model the panel renders.

use std::collections::{BTreeMap, HashMap};

use serde::Serialize;
use serde_json::Value;

use crate::color;

/// Raw resources keyed by ID, updated in place from event-stream batches.
#[derive(Default)]
pub struct Cache {
    resources: BTreeMap<String, Value>,
}

pub enum Applied {
    Changed,
    /// Resources were added or removed; a full reload is the simplest correct response.
    NeedsResync,
    Unchanged,
}

impl Cache {
    pub fn replace(&mut self, resources: Vec<Value>) {
        self.resources = resources
            .into_iter()
            .filter_map(|resource| Some((str_at(&resource, "/id")?.to_owned(), resource)))
            .collect();
    }

    pub fn apply(&mut self, batch: &[Value]) -> Applied {
        let mut result = Applied::Unchanged;
        for event in batch {
            let Some(data) = event.get("data").and_then(Value::as_array) else { continue };
            match event.get("type").and_then(Value::as_str) {
                Some("update") => {
                    for partial in data {
                        let Some(id) = str_at(partial, "/id") else { continue };
                        if let Some(existing) = self.resources.get_mut(id) {
                            merge(existing, partial);
                            if matches!(result, Applied::Unchanged) {
                                result = Applied::Changed;
                            }
                        }
                    }
                }
                Some("add") | Some("delete") => return Applied::NeedsResync,
                _ => {}
            }
        }
        result
    }

    fn of_type<'a>(&'a self, rtype: &'a str) -> impl Iterator<Item = &'a Value> + 'a {
        self.resources
            .values()
            .filter(move |resource| str_at(resource, "/type") == Some(rtype))
    }

    fn get(&self, id: &str) -> Option<&Value> {
        self.resources.get(id)
    }
}

fn merge(target: &mut Value, patch: &Value) {
    match (target, patch) {
        (Value::Object(target), Value::Object(patch)) => {
            for (key, value) in patch {
                match target.get_mut(key) {
                    Some(existing) if existing.is_object() && value.is_object() => {
                        merge(existing, value)
                    }
                    _ => {
                        target.insert(key.clone(), value.clone());
                    }
                }
            }
        }
        (target, patch) => *target = patch.clone(),
    }
}

fn str_at<'a>(value: &'a Value, pointer: &str) -> Option<&'a str> {
    value.pointer(pointer).and_then(Value::as_str)
}

fn f64_at(value: &Value, pointer: &str) -> Option<f64> {
    value.pointer(pointer).and_then(Value::as_f64)
}

fn bool_at(value: &Value, pointer: &str) -> Option<bool> {
    value.pointer(pointer).and_then(Value::as_bool)
}

fn refs<'a>(value: &'a Value, key: &str, rtype: &'a str) -> impl Iterator<Item = &'a str> + 'a {
    value
        .get(key)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(move |reference| str_at(reference, "/rtype") == Some(rtype))
        .filter_map(|reference| str_at(reference, "/rid"))
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Light {
    pub id: String,
    pub name: String,
    pub on: bool,
    pub reachable: bool,
    /// Plugs and other on/off-only devices.
    pub plug: bool,
    pub dimming: bool,
    pub brightness: Option<f64>,
    pub color: bool,
    pub temperature: bool,
    pub mirek: Option<u32>,
    pub mirek_min: Option<u32>,
    pub mirek_max: Option<u32>,
    /// `color`, `temperature` or `none`, i.e. what the light currently shows.
    pub mode: &'static str,
    /// Display swatch of the current light output.
    pub hex: Option<String>,
    pub room_id: Option<String>,
    pub room_name: Option<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Scene {
    pub id: String,
    pub name: String,
    pub active: bool,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Group {
    pub id: String,
    /// `room` or `zone`.
    pub kind: &'static str,
    pub name: String,
    pub archetype: String,
    pub grouped_light_id: Option<String>,
    pub on: bool,
    pub brightness: Option<f64>,
    pub light_ids: Vec<String>,
    pub plug_ids: Vec<String>,
    pub scenes: Vec<Scene>,
    pub active_scene_id: Option<String>,
    pub dimming: bool,
    pub color: bool,
    pub temperature: bool,
    pub mirek_min: Option<u32>,
    pub mirek_max: Option<u32>,
    /// Which tab reflects the current state: `scene`, `color` or `temperature`.
    pub mode: &'static str,
    pub hex: Option<String>,
    pub mirek: Option<u32>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Home {
    pub groups: Vec<Group>,
    pub lights: Vec<Light>,
    pub any_on: bool,
    pub lights_on: usize,
    pub home_grouped_light_id: Option<String>,
}

fn device_name(cache: &Cache, light: &Value) -> Option<String> {
    let owner = str_at(light, "/owner/rid")?;
    str_at(cache.get(owner)?, "/metadata/name").map(str::to_owned)
}

fn device_is_plug(cache: &Cache, light: &Value) -> bool {
    let archetype_is_plug = |value: Option<&str>| value.is_some_and(|value| value.contains("plug"));
    let device = str_at(light, "/owner/rid").and_then(|owner| cache.get(owner));
    archetype_is_plug(device.and_then(|device| str_at(device, "/product_data/product_archetype")))
        || archetype_is_plug(str_at(light, "/metadata/archetype"))
        || light.get("dimming").is_none()
}

fn reachable(cache: &Cache, light: &Value) -> bool {
    let Some(owner) = str_at(light, "/owner/rid") else { return true };
    let Some(device) = cache.get(owner) else { return true };
    for connectivity in refs(device, "services", "zigbee_connectivity") {
        if let Some(status) = cache.get(connectivity).and_then(|c| str_at(c, "/status")) {
            return status == "connected";
        }
    }
    true
}

fn build_light(cache: &Cache, light: &Value) -> Option<Light> {
    let id = str_at(light, "/id")?.to_owned();
    let on = bool_at(light, "/on/on").unwrap_or(false);
    let color = light.get("color").is_some();
    let temperature = light.get("color_temperature").is_some();
    let mirek = light
        .pointer("/color_temperature/mirek")
        .and_then(Value::as_u64)
        .and_then(|value| u32::try_from(value).ok());
    let mirek_valid = bool_at(light, "/color_temperature/mirek_valid").unwrap_or(false);
    let mode = if temperature && mirek_valid && mirek.is_some() {
        "temperature"
    } else if color {
        "color"
    } else {
        "none"
    };
    let hex = match mode {
        "temperature" => mirek.map(color::mirek_to_hex),
        "color" => match (f64_at(light, "/color/xy/x"), f64_at(light, "/color/xy/y")) {
            (Some(x), Some(y)) => Some(color::xy_to_hex(x, y)),
            _ => None,
        },
        _ => None,
    };
    let schema = |key: &str| {
        light
            .pointer(&format!("/color_temperature/mirek_schema/{key}"))
            .and_then(Value::as_u64)
            .and_then(|value| u32::try_from(value).ok())
    };
    Some(Light {
        name: device_name(cache, light)
            .or_else(|| str_at(light, "/metadata/name").map(str::to_owned))
            .unwrap_or_else(|| "Hue".to_owned()),
        on,
        reachable: reachable(cache, light),
        plug: device_is_plug(cache, light),
        dimming: light.get("dimming").is_some(),
        brightness: f64_at(light, "/dimming/brightness").map(round1),
        color,
        temperature,
        mirek,
        mirek_min: schema("mirek_minimum"),
        mirek_max: schema("mirek_maximum"),
        mode,
        hex,
        room_id: None,
        room_name: None,
        id,
    })
}

fn round1(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

/// Light IDs of a room (children are devices) or zone (children are usually lights).
fn member_lights(cache: &Cache, group: &Value) -> Vec<String> {
    let mut ids = Vec::new();
    if let Some(children) = group.get("children").and_then(Value::as_array) {
        for child in children {
            match (str_at(child, "/rtype"), str_at(child, "/rid")) {
                (Some("light"), Some(rid)) => ids.push(rid.to_owned()),
                (Some("device"), Some(rid)) => {
                    if let Some(device) = cache.get(rid) {
                        ids.extend(refs(device, "services", "light").map(str::to_owned));
                    }
                }
                _ => {}
            }
        }
    }
    ids.dedup();
    ids
}

fn build_group(
    cache: &Cache,
    group: &Value,
    kind: &'static str,
    lights: &HashMap<String, Light>,
    scenes: &[(String, Scene)],
) -> Option<Group> {
    let id = str_at(group, "/id")?.to_owned();
    let grouped = refs(group, "services", "grouped_light")
        .next()
        .and_then(|rid| cache.get(rid));
    let members: Vec<&Light> = member_lights(cache, group)
        .iter()
        .filter_map(|id| lights.get(id))
        .collect();
    let (plugs, bulbs): (Vec<&Light>, Vec<&Light>) = members.into_iter().partition(|l| l.plug);
    let scenes: Vec<Scene> = scenes
        .iter()
        .filter(|(owner, _)| owner == &id)
        .map(|(_, scene)| scene.clone())
        .collect();
    let active_scene_id = scenes.iter().find(|s| s.active).map(|s| s.id.clone());
    let lit: Vec<&&Light> = bulbs.iter().filter(|l| l.on).collect();
    let lit_mode = |mode: &str| lit.iter().find(|l| l.mode == mode);
    let mode = if active_scene_id.is_some() {
        "scene"
    } else if lit_mode("color").is_some() {
        "color"
    } else if lit_mode("temperature").is_some() {
        "temperature"
    } else {
        "scene"
    };
    let shown = lit_mode("color").or_else(|| lit_mode("temperature"));
    let on_bulbs = bulbs.iter().any(|l| l.on);
    let brightness = if lit.is_empty() {
        grouped.and_then(|g| f64_at(g, "/dimming/brightness")).map(round1)
    } else {
        let sum: f64 = lit.iter().filter_map(|l| l.brightness).sum();
        let count = lit.iter().filter(|l| l.brightness.is_some()).count();
        (count > 0).then(|| round1(sum / count as f64))
    };
    let temperature_lights: Vec<&&Light> = bulbs.iter().filter(|l| l.temperature).collect();
    let mut sorted_scenes = scenes;
    sorted_scenes.sort_by_key(|scene| scene.name.to_lowercase());
    Some(Group {
        kind,
        name: str_at(group, "/metadata/name").unwrap_or("Hue").to_owned(),
        archetype: str_at(group, "/metadata/archetype").unwrap_or("other").to_owned(),
        grouped_light_id: grouped.and_then(|g| str_at(g, "/id")).map(str::to_owned),
        on: if bulbs.is_empty() {
            grouped.and_then(|g| bool_at(g, "/on/on")).unwrap_or(false)
        } else {
            on_bulbs
        },
        brightness,
        light_ids: bulbs.iter().map(|l| l.id.clone()).collect(),
        plug_ids: plugs.iter().map(|l| l.id.clone()).collect(),
        active_scene_id,
        scenes: sorted_scenes,
        dimming: bulbs.iter().any(|l| l.dimming),
        color: bulbs.iter().any(|l| l.color),
        temperature: !temperature_lights.is_empty(),
        mirek_min: temperature_lights.iter().filter_map(|l| l.mirek_min).min(),
        mirek_max: temperature_lights.iter().filter_map(|l| l.mirek_max).max(),
        mode,
        hex: shown.and_then(|l| l.hex.clone()),
        mirek: lit_mode("temperature").and_then(|l| l.mirek),
        id,
    })
}

pub fn home(cache: &Cache) -> Home {
    let mut lights: HashMap<String, Light> = cache
        .of_type("light")
        .filter_map(|light| build_light(cache, light))
        .map(|light| (light.id.clone(), light))
        .collect();
    let scenes: Vec<(String, Scene)> = cache
        .of_type("scene")
        .filter_map(|scene| {
            Some((
                str_at(scene, "/group/rid")?.to_owned(),
                Scene {
                    id: str_at(scene, "/id")?.to_owned(),
                    name: str_at(scene, "/metadata/name").unwrap_or("Szene").to_owned(),
                    active: str_at(scene, "/status/active").is_some_and(|s| s != "inactive"),
                },
            ))
        })
        .collect();

    // Rooms own their lights; zones only group them.
    for room in cache.of_type("room") {
        let name = str_at(room, "/metadata/name").map(str::to_owned);
        let id = str_at(room, "/id").map(str::to_owned);
        for light_id in member_lights(cache, room) {
            if let Some(light) = lights.get_mut(&light_id) {
                light.room_id.clone_from(&id);
                light.room_name.clone_from(&name);
            }
        }
    }

    let mut groups: Vec<Group> = cache
        .of_type("room")
        .filter_map(|room| build_group(cache, room, "room", &lights, &scenes))
        .collect();
    groups.sort_by_key(|group| group.name.to_lowercase());
    let mut zones: Vec<Group> = cache
        .of_type("zone")
        .filter_map(|zone| build_group(cache, zone, "zone", &lights, &scenes))
        .collect();
    zones.sort_by_key(|group| group.name.to_lowercase());
    groups.extend(zones);

    let home_grouped_light_id = cache
        .of_type("grouped_light")
        .find(|g| str_at(g, "/owner/rtype") == Some("bridge_home"))
        .and_then(|g| str_at(g, "/id"))
        .map(str::to_owned);

    let mut lights: Vec<Light> = lights.into_values().collect();
    lights.sort_by(|a, b| {
        (a.room_name.as_deref().unwrap_or("~"), a.name.to_lowercase())
            .cmp(&(b.room_name.as_deref().unwrap_or("~"), b.name.to_lowercase()))
    });
    let lights_on = lights.iter().filter(|l| l.on && !l.plug).count();
    Home {
        any_on: lights.iter().any(|l| l.on),
        lights_on,
        groups,
        lights,
        home_grouped_light_id,
    }
}

/// Bridge metadata worth showing (name, software version).
pub fn bridge_name(cache: &Cache) -> Option<String> {
    let bridge = cache.of_type("bridge").next()?;
    let device = cache.get(str_at(bridge, "/owner/rid")?)?;
    str_at(device, "/metadata/name").map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture() -> Cache {
        let mut cache = Cache::default();
        cache.replace(vec![
            json!({"id":"dev-lamp","type":"device","metadata":{"name":"Stehlampe"},
                   "product_data":{"product_archetype":"sultan_bulb"},
                   "services":[{"rid":"light-1","rtype":"light"},{"rid":"zb-1","rtype":"zigbee_connectivity"}]}),
            json!({"id":"zb-1","type":"zigbee_connectivity","owner":{"rid":"dev-lamp","rtype":"device"},"status":"connected"}),
            json!({"id":"light-1","type":"light","owner":{"rid":"dev-lamp","rtype":"device"},
                   "metadata":{"name":"Hue color lamp 1","archetype":"sultan_bulb"},
                   "on":{"on":true},"dimming":{"brightness":42.37},
                   "color_temperature":{"mirek":null,"mirek_valid":false,"mirek_schema":{"mirek_minimum":153,"mirek_maximum":500}},
                   "color":{"xy":{"x":0.675,"y":0.322}}}),
            json!({"id":"dev-plug","type":"device","metadata":{"name":"Kaffeemaschine"},
                   "product_data":{"product_archetype":"plug"},
                   "services":[{"rid":"light-2","rtype":"light"}]}),
            json!({"id":"light-2","type":"light","owner":{"rid":"dev-plug","rtype":"device"},
                   "metadata":{"name":"Plug","archetype":"plug"},"on":{"on":false}}),
            json!({"id":"room-1","type":"room","metadata":{"name":"Küche","archetype":"kitchen"},
                   "children":[{"rid":"dev-lamp","rtype":"device"},{"rid":"dev-plug","rtype":"device"}],
                   "services":[{"rid":"gl-1","rtype":"grouped_light"}]}),
            json!({"id":"gl-1","type":"grouped_light","owner":{"rid":"room-1","rtype":"room"},"on":{"on":true},"dimming":{"brightness":40.0}}),
            json!({"id":"zone-1","type":"zone","metadata":{"name":"Arbeitsplatte","archetype":"other"},
                   "children":[{"rid":"light-1","rtype":"light"}],"services":[{"rid":"gl-2","rtype":"grouped_light"}]}),
            json!({"id":"gl-2","type":"grouped_light","owner":{"rid":"zone-1","rtype":"zone"},"on":{"on":true}}),
            json!({"id":"gl-home","type":"grouped_light","owner":{"rid":"home","rtype":"bridge_home"},"on":{"on":true}}),
            json!({"id":"scene-1","type":"scene","metadata":{"name":"Lesen"},"group":{"rid":"room-1","rtype":"room"},"status":{"active":"inactive"}}),
            json!({"id":"scene-2","type":"scene","metadata":{"name":"Entspannen"},"group":{"rid":"room-1","rtype":"room"},"status":{"active":"inactive"}}),
        ]);
        cache
    }

    #[test]
    fn rooms_split_plugs_from_lights_and_resolve_names() {
        let home = home(&fixture());
        let kitchen = &home.groups[0];
        assert_eq!(kitchen.name, "Küche");
        assert_eq!(kitchen.light_ids, vec!["light-1"]);
        assert_eq!(kitchen.plug_ids, vec!["light-2"]);
        assert_eq!(kitchen.grouped_light_id.as_deref(), Some("gl-1"));
        assert_eq!(kitchen.brightness, Some(42.4));
        assert!(kitchen.color && kitchen.temperature);
        assert_eq!(kitchen.mode, "color");
        assert_eq!(
            kitchen.scenes.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(),
            vec!["Entspannen", "Lesen"]
        );
        let lamp = home.lights.iter().find(|l| l.id == "light-1").expect("lamp");
        assert_eq!(lamp.name, "Stehlampe");
        assert_eq!(lamp.room_name.as_deref(), Some("Küche"));
        assert!(lamp.reachable);
        let plug = home.lights.iter().find(|l| l.id == "light-2").expect("plug");
        assert!(plug.plug && !plug.dimming);
        assert_eq!(home.groups[1].kind, "zone");
        assert_eq!(home.home_grouped_light_id.as_deref(), Some("gl-home"));
        assert_eq!(home.lights_on, 1);
    }

    #[test]
    fn events_update_state_and_switch_mode_to_scene() {
        let mut cache = fixture();
        let applied = cache.apply(&[json!({"type":"update","data":[
            {"id":"scene-1","type":"scene","status":{"active":"static"}},
            {"id":"light-1","type":"light","color_temperature":{"mirek":366,"mirek_valid":true}}
        ]})]);
        assert!(matches!(applied, Applied::Changed));
        let home = home(&cache);
        let kitchen = &home.groups[0];
        assert_eq!(kitchen.mode, "scene");
        assert_eq!(kitchen.active_scene_id.as_deref(), Some("scene-1"));
        let lamp = home.lights.iter().find(|l| l.id == "light-1").expect("lamp");
        assert_eq!(lamp.mode, "temperature");
        assert_eq!(lamp.mirek, Some(366));
        // Untouched sibling fields survive the partial merge.
        assert_eq!(lamp.mirek_max, Some(500));
    }

    #[test]
    fn additions_request_a_resync() {
        let mut cache = fixture();
        let applied = cache.apply(&[json!({"type":"add","data":[{"id":"x","type":"light"}]})]);
        assert!(matches!(applied, Applied::NeedsResync));
    }
}
