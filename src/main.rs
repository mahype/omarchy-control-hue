#![forbid(unsafe_code)]

//! `omarchy-light-control-hue` — the process boundary between the Omarchy shell plugin and a Hue bridge.
//!
//! Every command prints JSON on stdout and a single error line on stderr.
//! `watch` streams the home state as JSON lines and accepts requests on stdin.

mod bridge;
mod color;
mod config;
mod model;

use std::io::Write;
use std::net::IpAddr;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use clap::{Parser, Subcommand, ValueEnum};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use tokio::time::{Instant, sleep, sleep_until};

use crate::bridge::{ApiError, Bridge};
use crate::config::{BridgeConfig, Config};

#[derive(Parser)]
#[command(name = "omarchy-light-control-hue", version, about = "Control Philips Hue lights from Omarchy")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Find Hue bridges on the local network (mDNS, then Signify's discovery service).
    Discover,
    /// Select a bridge by address; its ID is read from the bridge itself.
    Connect { host: IpAddr },
    /// Select a discovered bridge.
    Use {
        id: String,
        host: IpAddr,
        #[arg(long)]
        name: Option<String>,
    },
    /// Register with the selected bridge. Press its link button first or while this runs.
    Pair {
        /// Seconds to keep trying while waiting for the link button.
        #[arg(long, default_value_t = 30)]
        wait: u64,
    },
    /// Remove the stored key and bridge selection.
    Forget,
    /// Stream the home state as newline-delimited JSON.
    Watch,
    /// Change a single light or a room/zone (grouped light).
    Set {
        target: Target,
        id: String,
        #[arg(long)]
        on: Option<bool>,
        /// 0–100
        #[arg(long)]
        brightness: Option<f64>,
        /// Color temperature in mirek (153 cold … 500 warm).
        #[arg(long)]
        mirek: Option<u32>,
        /// RRGGBB
        #[arg(long)]
        color: Option<String>,
    },
    /// Activate a scene, optionally at a brightness.
    Scene {
        id: String,
        #[arg(long)]
        brightness: Option<f64>,
    },
    /// Switch off every light connected to the bridge.
    AllOff,
    /// Let a light or room/zone blink so it can be found.
    Identify { target: Target, id: String },
}

#[derive(Clone, Copy, ValueEnum)]
enum Target {
    Light,
    Group,
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    if let Err(error) = run(cli.command).await {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}

async fn run(command: Command) -> Result<()> {
    match command {
        Command::Discover => print(&serde_json::to_value(bridge::discover().await?)?),
        Command::Connect { host } => {
            let candidate = bridge::identify(host).await?;
            select_bridge(BridgeConfig {
                id: candidate.id.clone(),
                host: candidate.host,
                name: candidate.name.clone(),
            })?;
            print(&serde_json::to_value(candidate)?)
        }
        Command::Use { id, host, name } => {
            let selected = BridgeConfig {
                id: config::normalize_bridge_id(&id)?,
                host,
                name: name.unwrap_or_else(|| "Hue Bridge".to_owned()),
            };
            select_bridge(selected.clone())?;
            print(&json!({ "id": selected.id, "host": selected.host, "name": selected.name }))
        }
        Command::Pair { wait } => pair(wait).await,
        Command::Forget => {
            let mut stored = Config::load()?;
            if let Some(selected) = stored.bridge.take() {
                blocking(move || config::forget_key(&selected.id)).await?;
            }
            stored.save()?;
            print(&json!({ "forgotten": true }))
        }
        Command::Watch => watch().await,
        Command::Set {
            target,
            id,
            on,
            brightness,
            mirek,
            color,
        } => {
            let op = Op::Set {
                target: match target {
                    Target::Light => "light".to_owned(),
                    Target::Group => "group".to_owned(),
                },
                id,
                on,
                brightness,
                mirek,
                color,
            };
            execute(&connected().await?, op).await?;
            print(&json!({ "ok": true }))
        }
        Command::Scene { id, brightness } => {
            execute(&connected().await?, Op::Scene { id, brightness }).await?;
            print(&json!({ "ok": true }))
        }
        Command::AllOff => {
            execute(&connected().await?, Op::AllOff).await?;
            print(&json!({ "ok": true }))
        }
        Command::Identify { target, id } => {
            let target = match target {
                Target::Light => "light",
                Target::Group => "group",
            };
            execute(&connected().await?, Op::Identify { target: target.to_owned(), id }).await?;
            print(&json!({ "ok": true }))
        }
    }
}

/// A state change, shared by the one-shot commands and `watch`'s stdin protocol.
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
enum Op {
    Set {
        /// `light` or `group` (a room's or zone's grouped light).
        target: String,
        id: String,
        on: Option<bool>,
        brightness: Option<f64>,
        mirek: Option<u32>,
        color: Option<String>,
    },
    Scene {
        id: String,
        brightness: Option<f64>,
    },
    AllOff,
    /// Let a light or group breathe once so it can be found.
    Identify { target: String, id: String },
}

fn resource_type(target: &str) -> Result<&'static str> {
    match target {
        "light" => Ok("light"),
        "group" => Ok("grouped_light"),
        other => bail!("unknown target {other}"),
    }
}

async fn execute(bridge: &Bridge, op: Op) -> Result<()> {
    match op {
        Op::Set {
            target,
            id,
            on,
            brightness,
            mirek,
            color,
        } => {
            let rtype = resource_type(&target)?;
            let body = state_body(on, brightness, mirek, color.as_deref())?;
            bridge.put(rtype, &id, &body).await.map_err(api)
        }
        Op::Scene { id, brightness } => {
            let mut recall = json!({ "action": "active" });
            if let Some(brightness) = brightness {
                recall["dimming"] = json!({ "brightness": clamp_brightness(brightness)? });
            }
            bridge
                .put("scene", &id, &json!({ "recall": recall }))
                .await
                .map_err(api)
        }
        Op::Identify { target, id } => bridge
            .put(
                resource_type(&target)?,
                &id,
                &json!({ "alert": { "action": "breathe" } }),
            )
            .await
            .map_err(api),
        Op::AllOff => {
            let mut cache = model::Cache::default();
            cache.replace(bridge.resources().await.map_err(api)?);
            let home = model::home(&cache)
                .home_grouped_light_id
                .context("the bridge reported no home group")?;
            bridge
                .put("grouped_light", &home, &json!({ "on": { "on": false } }))
                .await
                .map_err(api)
        }
    }
}

fn print(value: &Value) -> Result<()> {
    let mut stdout = std::io::stdout().lock();
    writeln!(stdout, "{value}").context("stdout closed")?;
    stdout.flush().context("stdout closed")
}

fn api(error: ApiError) -> anyhow::Error {
    anyhow!("{error}")
}

async fn blocking<T: Send + 'static>(job: impl FnOnce() -> Result<T> + Send + 'static) -> Result<T> {
    tokio::task::spawn_blocking(job)
        .await
        .context("background task failed")?
}

fn select_bridge(selected: BridgeConfig) -> Result<()> {
    let mut stored = Config::load()?;
    stored.bridge = Some(selected);
    stored.save()
}

async fn selected() -> Result<BridgeConfig> {
    Config::load()?
        .bridge
        .context("no Hue bridge selected; run `omarchy-light-control-hue discover` and `omarchy-light-control-hue use`")
}

async fn connected() -> Result<Bridge> {
    let selected = selected().await?;
    let id = selected.id.clone();
    let key = blocking(move || config::load_key(&id))
        .await?
        .context("the Hue bridge is not paired; run `omarchy-light-control-hue pair`")?;
    Bridge::new(&selected, Some(key))
}

async fn pair(wait: u64) -> Result<()> {
    let selected = selected().await?;
    let bridge = Bridge::new(&selected, None)?;
    let deadline = Instant::now() + Duration::from_secs(wait);
    loop {
        if let Some(key) = bridge.register().await? {
            let id = selected.id.clone();
            blocking(move || config::store_key(&id, &key)).await?;
            return print(&json!({ "paired": true }));
        }
        if Instant::now() >= deadline {
            print(&json!({ "paired": false }))?;
            bail!("the link button on the Hue bridge was not pressed");
        }
        sleep(Duration::from_millis(1500)).await;
    }
}

fn clamp_brightness(value: f64) -> Result<f64> {
    if !value.is_finite() {
        bail!("brightness must be a number");
    }
    Ok(value.clamp(0.0, 100.0))
}

fn state_body(
    on: Option<bool>,
    brightness: Option<f64>,
    mirek: Option<u32>,
    color: Option<&str>,
) -> Result<Value> {
    let mut body = Map::new();
    let mut turn_on = on;
    if let Some(brightness) = brightness {
        let brightness = clamp_brightness(brightness)?;
        body.insert("dimming".into(), json!({ "brightness": brightness }));
        turn_on = turn_on.or(Some(brightness > 0.0));
    }
    if let Some(mirek) = mirek {
        body.insert("color_temperature".into(), json!({ "mirek": mirek.clamp(153, 500) }));
        turn_on = turn_on.or(Some(true));
    }
    if let Some(color) = color {
        let (x, y) = color::rgb_to_xy(color::parse_hex(color)?);
        body.insert("color".into(), json!({ "xy": { "x": x, "y": y } }));
        turn_on = turn_on.or(Some(true));
    }
    if let Some(on) = turn_on {
        body.insert("on".into(), json!({ "on": on }));
    }
    if body.is_empty() {
        bail!("nothing to change; pass --on, --brightness, --mirek or --color");
    }
    Ok(Value::Object(body))
}


// ---------------------------------------------------------------------------
// watch
//
// stdout: `{"type":"state",...}` whenever the home changes and
//         `{"type":"result","id":…,"ok":…}` for each request.
// stdin:  one request per line, e.g. `{"id":1,"op":"set","target":"group","id":…}`
//         (see `Op`). Closing stdin ends the process, so it never outlives the shell.

const DEBOUNCE: Duration = Duration::from_millis(80);
const RESYNC_INTERVAL: Duration = Duration::from_secs(300);
const MAX_BACKOFF: Duration = Duration::from_secs(30);

type SharedBridge = tokio::sync::watch::Receiver<Option<Bridge>>;

#[derive(Deserialize)]
struct Request {
    #[serde(default, rename = "req")]
    request_id: Value,
    #[serde(flatten)]
    op: Op,
}

struct Emitter {
    last: String,
}

impl Emitter {
    fn emit(&mut self, mut value: Value) -> Result<()> {
        value["type"] = json!("state");
        let line = value.to_string();
        if line == self.last {
            return Ok(());
        }
        print(&value)?;
        self.last = line;
        Ok(())
    }
}

fn bridge_json(selected: &BridgeConfig) -> Value {
    json!({ "id": selected.id, "host": selected.host, "name": selected.name })
}

async fn serve_requests(bridge: SharedBridge) {
    use tokio::io::AsyncBufReadExt;

    let mut lines = tokio::io::BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        let (request_id, result) = match serde_json::from_str::<Request>(&line) {
            Ok(request) => {
                let current = bridge.borrow().clone();
                let result = match current {
                    Some(current) => execute(&current, request.op).await,
                    None => Err(anyhow!("the Hue bridge is not connected")),
                };
                (request.request_id, result)
            }
            Err(error) => (Value::Null, Err(anyhow!("invalid request: {error}"))),
        };
        let reply = match result {
            Ok(()) => json!({ "type": "result", "req": request_id, "ok": true }),
            Err(error) => json!({ "type": "result", "req": request_id, "ok": false,
                                  "error": format!("{error:#}") }),
        };
        if print(&reply).is_err() {
            break;
        }
    }
    std::process::exit(0);
}

async fn watch() -> Result<()> {
    let (publish, shared) = tokio::sync::watch::channel::<Option<Bridge>>(None);
    tokio::spawn(serve_requests(shared));
    let mut out = Emitter { last: String::new() };
    let mut backoff = Duration::from_secs(1);
    loop {
        publish.send_replace(None);
        let Some(selected) = Config::load()?.bridge else {
            out.emit(json!({ "state": "unconfigured" }))?;
            // Only a user action resolves this; the plugin restarts `watch` afterwards.
            std::future::pending::<()>().await;
            continue;
        };
        let id = selected.id.clone();
        let key = match blocking(move || config::load_key(&id)).await {
            Ok(Some(key)) => key,
            Ok(None) => {
                out.emit(json!({ "state": "unpaired", "bridge": bridge_json(&selected) }))?;
                std::future::pending::<()>().await;
                continue;
            }
            Err(error) => {
                out.emit(json!({ "state": "error", "bridge": bridge_json(&selected),
                                 "error": format!("{error:#}") }))?;
                sleep(MAX_BACKOFF).await;
                continue;
            }
        };
        let bridge = Bridge::new(&selected, Some(key))?;
        match session(&bridge, &selected, &mut out, &mut backoff, &publish).await {
            Ok(()) => sleep(Duration::from_secs(1)).await,
            Err(ApiError::Unauthorized) => {
                publish.send_replace(None);
                out.emit(json!({ "state": "unauthorized", "bridge": bridge_json(&selected) }))?;
                std::future::pending::<()>().await;
            }
            Err(ApiError::Other(error)) => {
                if error.to_string() == "stdout closed" {
                    return Err(error);
                }
                publish.send_replace(None);
                out.emit(json!({ "state": "unreachable", "bridge": bridge_json(&selected),
                                 "error": format!("{error:#}") }))?;
                sleep(backoff).await;
                backoff = (backoff * 2).min(MAX_BACKOFF);
            }
        }
    }
}

async fn session(
    bridge: &Bridge,
    selected: &BridgeConfig,
    out: &mut Emitter,
    backoff: &mut Duration,
    publish: &tokio::sync::watch::Sender<Option<Bridge>>,
) -> Result<(), ApiError> {
    let mut cache = model::Cache::default();
    cache.replace(bridge.resources().await?);
    let ready = |cache: &model::Cache| {
        let mut info = bridge_json(selected);
        if let Some(name) = model::bridge_name(cache) {
            info["name"] = json!(name);
        }
        json!({ "state": "ready", "bridge": info, "home": model::home(cache) })
    };
    out.emit(ready(&cache))?;
    publish.send_replace(Some(bridge.clone()));
    *backoff = Duration::from_secs(1);

    let (sender, mut batches) = tokio::sync::mpsc::channel(64);
    let stream = bridge.events(&sender);
    tokio::pin!(stream);
    let mut pending: Option<Instant> = None;
    let mut resync = tokio::time::interval_at(Instant::now() + RESYNC_INTERVAL, RESYNC_INTERVAL);
    loop {
        tokio::select! {
            result = &mut stream => return result,
            Some(batch) = batches.recv() => match cache.apply(&batch) {
                model::Applied::Changed => {
                    pending.get_or_insert_with(|| Instant::now() + DEBOUNCE);
                }
                model::Applied::NeedsResync => {
                    cache.replace(bridge.resources().await?);
                    pending.get_or_insert_with(|| Instant::now() + DEBOUNCE);
                }
                model::Applied::Unchanged => {}
            },
            () = async { sleep_until(pending.unwrap_or_else(Instant::now)).await }, if pending.is_some() => {
                pending = None;
                out.emit(ready(&cache))?;
            }
            _ = resync.tick() => {
                cache.replace(bridge.resources().await?);
                out.emit(ready(&cache))?;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn brightness_implies_on_and_zero_implies_off() {
        let body = state_body(None, Some(55.0), None, None).expect("body");
        assert_eq!(body["on"]["on"], json!(true));
        assert_eq!(body["dimming"]["brightness"], json!(55.0));
        let body = state_body(None, Some(0.0), None, None).expect("body");
        assert_eq!(body["on"]["on"], json!(false));
    }

    #[test]
    fn explicit_on_wins_and_color_becomes_xy() {
        let body = state_body(Some(false), None, None, Some("ff0000")).expect("body");
        assert_eq!(body["on"]["on"], json!(false));
        assert!(body["color"]["xy"]["x"].as_f64().is_some_and(|x| x > 0.6));
    }

    #[test]
    fn empty_changes_are_rejected() {
        assert!(state_body(None, None, None, None).is_err());
        assert!(state_body(None, Some(f64::NAN), None, None).is_err());
    }
}
