"""Persistent bridge selection (plain JSON) and the application key (Secret Service)."""

import json
import os
import re
import subprocess
from pathlib import Path

KEYRING_SERVICE = "io.github.mahype.omarchy-light-control-hue"
_BRIDGE_ID = re.compile(r"^[0-9a-f]{16}$")


def normalize_bridge_id(value):
    bridge_id = str(value or "").strip().lower()
    if not _BRIDGE_ID.match(bridge_id):
        raise ValueError("Hue bridge ID must contain exactly 16 hexadecimal characters")
    return bridge_id


def config_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.environ["HOME"], ".config")
    return Path(base) / "omarchy-light-control-hue"


def _config_path():
    return config_dir() / "config.json"


def load():
    """Returns the selected bridge as {"id", "host", "name"} or None."""
    try:
        data = json.loads(_config_path().read_text())
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as error:
        raise RuntimeError(f"{_config_path()} is not valid configuration") from error
    bridge = data.get("bridge") if isinstance(data, dict) else None
    if not bridge:
        return None
    return {
        "id": normalize_bridge_id(bridge.get("id")),
        "host": str(bridge.get("host") or ""),
        "name": str(bridge.get("name") or "Hue Bridge"),
    }


def save(bridge):
    path = _config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    # Write-then-rename so a concurrently starting watcher never reads half a file.
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps({"bridge": bridge}, indent=2) + "\n")
    os.replace(temporary, path)


def _secret_tool(*args, secret=None):
    try:
        return subprocess.run(
            ["secret-tool", *args],
            input=secret, capture_output=True, text=True, timeout=15, check=False,
        )
    except FileNotFoundError as error:
        raise RuntimeError("secret-tool is missing; install libsecret") from error
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("the Secret Service did not answer") from error


def load_key(bridge_id):
    """Returns None when the bridge has never been paired."""
    result = _secret_tool("lookup", "service", KEYRING_SERVICE, "username", normalize_bridge_id(bridge_id))
    key = result.stdout.strip()
    return key or None


def store_key(bridge_id, key):
    bridge_id = normalize_bridge_id(bridge_id)
    result = _secret_tool(
        "store", f"--label=Hue bridge {bridge_id} (Omarchy Light Control for Hue)",
        "service", KEYRING_SERVICE, "username", bridge_id,
        secret=key,
    )
    if result.returncode != 0:
        raise RuntimeError("cannot store the Hue key in the Secret Service")


def forget_key(bridge_id):
    _secret_tool("clear", "service", KEYRING_SERVICE, "username", normalize_bridge_id(bridge_id))
