//! Persistent bridge selection (plain JSON) and the application key (Secret Service).

use std::net::IpAddr;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

const KEYRING_SERVICE: &str = "io.github.mahype.omarchy-light-control-hue";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BridgeConfig {
    pub id: String,
    pub host: IpAddr,
    #[serde(default = "default_bridge_name")]
    pub name: String,
}

fn default_bridge_name() -> String {
    "Hue Bridge".to_owned()
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub bridge: Option<BridgeConfig>,
}

pub fn config_dir() -> Result<PathBuf> {
    if let Some(dir) = std::env::var_os("XDG_CONFIG_HOME").filter(|dir| !dir.is_empty()) {
        return Ok(PathBuf::from(dir).join("omarchy-light-control-hue"));
    }
    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home).join(".config").join("omarchy-light-control-hue"))
}

fn config_path() -> Result<PathBuf> {
    Ok(config_dir()?.join("config.json"))
}

impl Config {
    pub fn load() -> Result<Self> {
        let path = config_path()?;
        match std::fs::read_to_string(&path) {
            Ok(text) => serde_json::from_str(&text)
                .with_context(|| format!("{} is not valid configuration", path.display())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(error) => Err(error).with_context(|| format!("cannot read {}", path.display())),
        }
    }

    pub fn save(&self) -> Result<()> {
        let path = config_path()?;
        let dir = path.parent().context("configuration path has no parent")?;
        std::fs::create_dir_all(dir).with_context(|| format!("cannot create {}", dir.display()))?;
        // Write-then-rename so a concurrently starting watcher never reads half a file.
        let temporary = path.with_extension("json.tmp");
        let text = serde_json::to_string_pretty(self).context("cannot encode configuration")?;
        std::fs::write(&temporary, text + "\n")
            .with_context(|| format!("cannot write {}", temporary.display()))?;
        std::fs::rename(&temporary, &path)
            .with_context(|| format!("cannot replace {}", path.display()))
    }
}

pub fn normalize_bridge_id(id: &str) -> Result<String> {
    let id = id.trim();
    if id.len() != 16 || !id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("Hue bridge ID must contain exactly 16 hexadecimal characters");
    }
    Ok(id.to_ascii_lowercase())
}

fn entry(bridge_id: &str) -> Result<keyring::Entry> {
    keyring::Entry::new(KEYRING_SERVICE, &normalize_bridge_id(bridge_id)?)
        .context("cannot open Secret Service")
}

/// Returns `None` when the bridge has never been paired.
pub fn load_key(bridge_id: &str) -> Result<Option<String>> {
    match entry(bridge_id)?.get_password() {
        Ok(key) if !key.trim().is_empty() => Ok(Some(key)),
        Ok(_) | Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(error).context("cannot read the Hue key from Secret Service"),
    }
}

pub fn store_key(bridge_id: &str, key: &str) -> Result<()> {
    entry(bridge_id)?
        .set_password(key)
        .context("cannot store the Hue key in Secret Service")
}

pub fn forget_key(bridge_id: &str) -> Result<()> {
    match entry(bridge_id)?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(error).context("cannot remove the Hue key from Secret Service"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bridge_ids_are_normalized_and_validated() {
        assert_eq!(
            normalize_bridge_id(" ECB5FAFFFE8F7CA6 ").ok().as_deref(),
            Some("ecb5fafffe8f7ca6")
        );
        assert!(normalize_bridge_id("ecb5fafffe8f7ca").is_err());
        assert!(normalize_bridge_id("ecb5fafffe8f7cag").is_err());
    }

    #[test]
    fn config_round_trips() {
        let config = Config {
            bridge: Some(BridgeConfig {
                id: "ecb5fafffe8f7ca6".to_owned(),
                host: "10.0.0.41".parse().expect("valid address"),
                name: "Hue Bridge".to_owned(),
            }),
        };
        let text = serde_json::to_string(&config).expect("encodes");
        let back: Config = serde_json::from_str(&text).expect("decodes");
        assert_eq!(back.bridge, config.bridge);
    }
}
