//! HTTPS access to a local Hue bridge: discovery, pairing, CLIP v2 and the event stream.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use futures_util::StreamExt;
use reqwest::{Certificate, Client, ClientBuilder, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::config::{BridgeConfig, normalize_bridge_id};

const DISCOVERY_URL: &str = "https://discovery.meethue.com/";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
/// The bridge sends a keep-alive comment well within this window.
const STREAM_IDLE_TIMEOUT: Duration = Duration::from_secs(90);
const DEVICE_TYPE: &str = "omarchy-light-control-hue#desktop";

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Candidate {
    pub id: String,
    pub host: IpAddr,
    pub name: String,
}

#[derive(Debug)]
pub enum ApiError {
    Unauthorized,
    Other(anyhow::Error),
}

impl From<anyhow::Error> for ApiError {
    fn from(error: anyhow::Error) -> Self {
        Self::Other(error)
    }
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unauthorized => formatter.write_str("the Hue bridge rejected the stored key"),
            Self::Other(error) => write!(formatter, "{error:#}"),
        }
    }
}

fn trusted_builder() -> Result<ClientBuilder> {
    // Signify publishes both roots; certificate chain validation stays enabled.
    let legacy = Certificate::from_pem(include_bytes!("hue-root-bridge.pem"))
        .context("bundled legacy Hue root certificate is invalid")?;
    let current = Certificate::from_pem(include_bytes!("hue-root-ca-01.pem"))
        .context("bundled current Hue root certificate is invalid")?;
    Ok(Client::builder()
        .https_only(true)
        .no_proxy()
        .tls_built_in_root_certs(false)
        .add_root_certificate(legacy)
        .add_root_certificate(current))
}

#[derive(Clone)]
pub struct Bridge {
    client: Client,
    stream_client: Client,
    /// The bridge ID doubles as the TLS server name.
    host: String,
    key: Option<String>,
}

impl Bridge {
    pub fn new(config: &BridgeConfig, key: Option<String>) -> Result<Self> {
        let host = normalize_bridge_id(&config.id)?;
        let address = SocketAddr::new(config.host, 443);
        let client = trusted_builder()?
            .timeout(REQUEST_TIMEOUT)
            .resolve(&host, address)
            .build()
            .context("cannot build the Hue HTTPS client")?;
        let stream_client = trusted_builder()?
            .connect_timeout(REQUEST_TIMEOUT)
            .read_timeout(STREAM_IDLE_TIMEOUT)
            .resolve(&host, address)
            .build()
            .context("cannot build the Hue event stream client")?;
        Ok(Self {
            client,
            stream_client,
            host,
            key,
        })
    }

    fn url(&self, path: &str) -> String {
        format!("https://{}{}", self.host, path)
    }

    fn key(&self) -> Result<&str, ApiError> {
        self.key.as_deref().ok_or(ApiError::Unauthorized)
    }

    /// Every CLIP v2 resource in one request.
    pub async fn resources(&self) -> Result<Vec<Value>, ApiError> {
        let response = self
            .client
            .get(self.url("/clip/v2/resource"))
            .header("hue-application-key", self.key()?)
            .send()
            .await
            .context("the Hue bridge is unreachable")?;
        clip_data(response).await
    }

    pub async fn put(&self, rtype: &str, id: &str, body: &Value) -> Result<(), ApiError> {
        validate_segment(rtype)?;
        validate_segment(id)?;
        let response = self
            .client
            .put(self.url(&format!("/clip/v2/resource/{rtype}/{id}")))
            .header("hue-application-key", self.key()?)
            .json(body)
            .send()
            .await
            .context("the Hue bridge is unreachable")?;
        clip_data(response).await.map(|_| ())
    }

    /// Registers a new application key. Returns `None` while the link button is not pressed.
    ///
    /// Registration is deliberately not retried on transport errors: a
    /// duplicate POST could mint two keys.
    pub async fn register(&self) -> Result<Option<String>> {
        let response = self
            .client
            .post(self.url("/api"))
            .json(&json!({ "devicetype": DEVICE_TYPE }))
            .send()
            .await
            .context("the Hue bridge is unreachable")?;
        let entries: Vec<Value> = response
            .json()
            .await
            .context("the Hue bridge returned an invalid pairing response")?;
        let entry = entries.first().context("empty Hue pairing response")?;
        if let Some(username) = entry.pointer("/success/username").and_then(Value::as_str) {
            return Ok(Some(username.to_owned()));
        }
        match entry.pointer("/error/type").and_then(Value::as_u64) {
            Some(101) => Ok(None),
            Some(code) => bail!("Hue pairing failed (bridge error {code})"),
            None => bail!("the Hue bridge returned an invalid pairing response"),
        }
    }

    /// Opens the server-sent event stream and forwards each event batch.
    /// Returns when the stream ends; the caller reconnects.
    pub async fn events(
        &self,
        sink: &tokio::sync::mpsc::Sender<Vec<Value>>,
    ) -> Result<(), ApiError> {
        let response = self
            .stream_client
            .get(self.url("/eventstream/clip/v2"))
            .header("hue-application-key", self.key()?)
            .header("accept", "text/event-stream")
            .send()
            .await
            .context("cannot open the Hue event stream")?;
        match response.status() {
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => return Err(ApiError::Unauthorized),
            status if !status.is_success() => {
                return Err(anyhow!("the Hue event stream failed with HTTP {status}").into());
            }
            _ => {}
        }
        let mut parser = SseParser::default();
        let mut body = response.bytes_stream();
        while let Some(chunk) = body.next().await {
            let chunk = chunk.context("the Hue event stream was interrupted")?;
            for data in parser.push(&chunk) {
                // Malformed batches are skipped; the next resync corrects the state.
                if let Ok(batch) = serde_json::from_str::<Vec<Value>>(&data) {
                    if sink.send(batch).await.is_err() {
                        return Ok(());
                    }
                }
            }
        }
        Ok(())
    }
}

async fn clip_data(response: reqwest::Response) -> Result<Vec<Value>, ApiError> {
    let status = response.status();
    if status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN {
        return Err(ApiError::Unauthorized);
    }
    let body: Value = response
        .json()
        .await
        .context("the Hue bridge returned malformed JSON")?;
    let errors: Vec<String> = body
        .get("errors")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|error| error.get("description").and_then(Value::as_str))
        .map(str::to_owned)
        .collect();
    if !status.is_success() || !errors.is_empty() {
        let detail = if errors.is_empty() {
            format!("HTTP {status}")
        } else {
            errors.join("; ")
        };
        return Err(anyhow!("Hue bridge error: {detail}").into());
    }
    Ok(body
        .get("data")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default())
}

fn validate_segment(segment: &str) -> Result<()> {
    if segment.is_empty()
        || !segment
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        bail!("invalid Hue resource reference");
    }
    Ok(())
}

/// Minimal `text/event-stream` framing: collects `data:` lines until a blank line.
#[derive(Default)]
struct SseParser {
    buffer: Vec<u8>,
    data: Vec<String>,
}

impl SseParser {
    fn push(&mut self, chunk: &[u8]) -> Vec<String> {
        self.buffer.extend_from_slice(chunk);
        let mut events = Vec::new();
        while let Some(position) = self.buffer.iter().position(|&byte| byte == b'\n') {
            let line: Vec<u8> = self.buffer.drain(..=position).collect();
            let line = String::from_utf8_lossy(&line);
            let line = line.trim_end_matches(['\n', '\r']);
            if line.is_empty() {
                if !self.data.is_empty() {
                    events.push(self.data.join("\n"));
                    self.data.clear();
                }
            } else if let Some(value) = line.strip_prefix("data:") {
                self.data.push(value.strip_prefix(' ').unwrap_or(value).to_owned());
            }
        }
        events
    }
}

/// Looks up the bridge ID behind an address. Hostname checks are relaxed only
/// here because the ID is what we are asking for; the chain must still be Signify's.
pub async fn identify(host: IpAddr) -> Result<Candidate> {
    let client = trusted_builder()?
        .timeout(REQUEST_TIMEOUT)
        .danger_accept_invalid_hostnames(true)
        .build()
        .context("cannot build the Hue HTTPS client")?;
    let authority = match host {
        IpAddr::V4(address) => address.to_string(),
        IpAddr::V6(address) => format!("[{address}]"),
    };
    let config: Value = client
        .get(format!("https://{authority}/api/0/config"))
        .send()
        .await
        .with_context(|| format!("no Hue bridge answered at {host}"))?
        .json()
        .await
        .context("the device did not answer like a Hue bridge")?;
    let id = config
        .get("bridgeid")
        .and_then(Value::as_str)
        .context("the device did not report a Hue bridge ID")?;
    Ok(Candidate {
        id: normalize_bridge_id(id)?,
        host,
        name: config
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("Hue Bridge")
            .to_owned(),
    })
}

pub async fn discover() -> Result<Vec<Candidate>> {
    let local = tokio::task::spawn_blocking(discover_local)
        .await
        .context("local discovery task failed")?
        .unwrap_or_default();
    if !local.is_empty() {
        return Ok(local);
    }
    discover_cloud().await
}

fn discover_local() -> Result<Vec<Candidate>> {
    use mdns_sd::{ServiceDaemon, ServiceEvent};

    const SERVICE_TYPE: &str = "_hue._tcp.local.";
    let daemon = ServiceDaemon::new().context("cannot start mDNS discovery")?;
    let receiver = daemon
        .browse(SERVICE_TYPE)
        .context("cannot browse for Hue bridges")?;
    let deadline = Instant::now() + Duration::from_secs(4);
    let mut bridges = HashMap::new();
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        match receiver.recv_timeout(remaining) {
            Ok(ServiceEvent::ServiceResolved(info)) => {
                let id = info
                    .get_property_val_str("bridgeid")
                    .or_else(|| info.get_property_val_str("id"))
                    .and_then(|id| normalize_bridge_id(id).ok());
                let Some(id) = id else { continue };
                let host = info
                    .get_addresses()
                    .iter()
                    .map(mdns_sd::ScopedIp::to_ip_addr)
                    .filter(|address| !address.is_loopback() && !address.is_unspecified())
                    .min_by_key(|address| u8::from(address.is_ipv6()));
                if let Some(host) = host {
                    let name = info
                        .get_property_val_str("name")
                        .unwrap_or("Hue Bridge")
                        .to_owned();
                    bridges.insert(id.clone(), Candidate { id, host, name });
                }
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    let _ = daemon.stop_browse(SERVICE_TYPE);
    let _ = daemon.shutdown();
    let mut bridges: Vec<_> = bridges.into_values().collect();
    bridges.sort_by(|left, right| left.id.cmp(&right.id));
    Ok(bridges)
}

#[derive(Deserialize)]
struct CloudBridge {
    id: String,
    internalipaddress: IpAddr,
}

async fn discover_cloud() -> Result<Vec<Candidate>> {
    let bridges: Vec<CloudBridge> = Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .context("cannot build the discovery client")?
        .get(DISCOVERY_URL)
        .send()
        .await
        .context("the Hue discovery service is unavailable")?
        .error_for_status()
        .context("the Hue discovery service returned an error")?
        .json()
        .await
        .context("the Hue discovery service returned invalid data")?;
    bridges
        .into_iter()
        .map(|bridge| {
            Ok(Candidate {
                id: normalize_bridge_id(&bridge.id)?,
                host: bridge.internalipaddress,
                name: "Hue Bridge".to_owned(),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sse_parser_handles_split_chunks_and_comments() {
        let mut parser = SseParser::default();
        assert!(parser.push(b": hi\n\nid: 1:0\ndata: [{\"a\"").is_empty());
        let events = parser.push(b":1}]\r\n\r\n");
        assert_eq!(events, vec!["[{\"a\":1}]".to_owned()]);
    }

    #[test]
    fn resource_segments_reject_path_tricks() {
        assert!(validate_segment("grouped_light").is_ok());
        assert!(validate_segment("3f1c7f2a-0000-4000-8000-000000000000").is_ok());
        assert!(validate_segment("../config").is_err());
        assert!(validate_segment("").is_err());
    }
}
