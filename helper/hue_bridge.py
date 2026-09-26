"""HTTPS access to a local Hue bridge: discovery, pairing, CLIP v2 and the event stream."""

import http.client
import json
import re
import socket
import ssl
import subprocess
import urllib.request
from pathlib import Path

from hue_config import normalize_bridge_id

DISCOVERY_URL = "https://discovery.meethue.com/"
REQUEST_TIMEOUT = 10
# The bridge sends a keep-alive comment well within this window.
STREAM_IDLE_TIMEOUT = 90
DEVICE_TYPE = "omarchy-light-control-hue#desktop"
_CERTS = Path(__file__).resolve().parent / "certs"
_SEGMENT = re.compile(r"^[A-Za-z0-9_-]+$")


class Unauthorized(Exception):
    """The bridge rejected the stored application key."""

    def __str__(self):
        return "the Hue bridge rejected the stored key"


class BridgeError(Exception):
    pass


def _trusted_context():
    # Chain validation against Signify's two published roots stays on. The name
    # is checked by _verify_identity(): legacy bridge certificates carry the
    # bridge ID only as common name, which OpenSSL's hostname check skips.
    # Only Signify's roots are trusted here, not the system store.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.load_verify_locations(cadata="".join(p.read_text() for p in sorted(_CERTS.glob("*.pem"))))
    context.check_hostname = False
    context.verify_mode = ssl.CERT_REQUIRED
    return context


def _certificate_names(certificate):
    names = [value for key, value in certificate.get("subjectAltName", ()) if key == "DNS"]
    for rdn in certificate.get("subject", ()):
        for key, value in rdn:
            if key == "commonName":
                names.append(value)
    return {name.lower() for name in names}


def _verify_identity(sock, bridge_id):
    if bridge_id not in _certificate_names(sock.getpeercert() or {}):
        raise BridgeError("the Hue bridge certificate does not match the selected bridge")


class _Connection(http.client.HTTPSConnection):
    """HTTPS to the bridge's address, verified as the bridge ID."""

    def __init__(self, bridge_id, host, timeout):
        super().__init__(host, 443, timeout=timeout, context=_trusted_context())
        self._bridge_id = bridge_id

    def connect(self):
        super().connect()
        _verify_identity(self.sock, self._bridge_id)


class Bridge:
    def __init__(self, bridge, key=None):
        self.bridge_id = normalize_bridge_id(bridge["id"])
        self.host = str(bridge["host"])
        self.key = key

    def _request(self, method, path, body=None, authorized=True, timeout=REQUEST_TIMEOUT):
        headers = {"Accept": "application/json"}
        if authorized:
            if not self.key:
                raise Unauthorized()
            headers["hue-application-key"] = self.key
        payload = None
        if body is not None:
            payload = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        connection = _Connection(self.bridge_id, self.host, timeout)
        try:
            connection.request(method, path, body=payload, headers=headers)
            response = connection.getresponse()
            status = response.status
            raw = response.read()
        except (OSError, http.client.HTTPException) as error:
            raise BridgeError(f"the Hue bridge is unreachable ({error})") from error
        finally:
            connection.close()
        if status in (401, 403):
            raise Unauthorized()
        try:
            return status, json.loads(raw or b"null")
        except ValueError as error:
            raise BridgeError("the Hue bridge returned malformed JSON") from error

    def _clip(self, method, path, body=None):
        status, document = self._request(method, path, body)
        document = document if isinstance(document, dict) else {}
        errors = [e.get("description", "") for e in document.get("errors") or [] if isinstance(e, dict)]
        if status >= 300 or errors:
            raise BridgeError("Hue bridge error: " + ("; ".join(errors) if errors else f"HTTP {status}"))
        return document.get("data") or []

    def resources(self):
        """Every CLIP v2 resource in one request."""
        return self._clip("GET", "/clip/v2/resource")

    def put(self, rtype, resource_id, body):
        if not _SEGMENT.match(rtype) or not _SEGMENT.match(resource_id):
            raise BridgeError("invalid Hue resource reference")
        self._clip("PUT", f"/clip/v2/resource/{rtype}/{resource_id}", body)

    def register(self):
        """Registers a new application key; None while the link button is not pressed.

        Not retried on transport errors: a duplicate POST could mint two keys."""
        _, entries = self._request("POST", "/api", {"devicetype": DEVICE_TYPE}, authorized=False)
        entry = entries[0] if isinstance(entries, list) and entries else {}
        success = entry.get("success") or {}
        if success.get("username"):
            return success["username"]
        error = entry.get("error") or {}
        if error.get("type") == 101:
            return None
        if "type" in error:
            raise BridgeError(f"Hue pairing failed (bridge error {error['type']})")
        raise BridgeError("the Hue bridge returned an invalid pairing response")

    def events(self, handle, stopped=lambda: False):
        """Reads the server-sent event stream and passes each batch to handle().
        Returns when the stream ends; the caller reconnects."""
        if not self.key:
            raise Unauthorized()
        connection = _Connection(self.bridge_id, self.host, STREAM_IDLE_TIMEOUT)
        try:
            connection.request("GET", "/eventstream/clip/v2", headers={
                "hue-application-key": self.key, "Accept": "text/event-stream",
            })
            response = connection.getresponse()
            if response.status in (401, 403):
                raise Unauthorized()
            if response.status >= 300:
                raise BridgeError(f"the Hue event stream failed with HTTP {response.status}")
            data = []
            while not stopped():
                line = response.readline()
                if not line:
                    return
                text = line.decode("utf-8", "replace").rstrip("\r\n")
                if text == "":
                    if data:
                        _dispatch("\n".join(data), handle)
                        data = []
                elif text.startswith("data:"):
                    data.append(text[5:].removeprefix(" "))
        except (OSError, http.client.HTTPException) as error:
            raise BridgeError(f"the Hue event stream was interrupted ({error})") from error
        finally:
            connection.close()


def _dispatch(data, handle):
    try:
        batch = json.loads(data)
    except ValueError:
        return  # Malformed batches are skipped; the next resync corrects the state.
    if isinstance(batch, list):
        handle(batch)


def identify(host):
    """Looks up the bridge ID behind an address. The chain must still be Signify's,
    and the certificate must name the ID the bridge reports."""
    with socket.create_connection((host, 443), timeout=REQUEST_TIMEOUT) as raw:
        with _trusted_context().wrap_socket(raw) as sock:
            names = _certificate_names(sock.getpeercert() or {})
            request = f"GET /api/0/config HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"
            sock.sendall(request.encode())
            chunks = []
            while chunk := sock.recv(65536):
                chunks.append(chunk)
    head, _, body = b"".join(chunks).partition(b"\r\n\r\n")
    if b"chunked" in head.lower():
        body = _unchunk(body)
    try:
        config = json.loads(body)
        bridge_id = normalize_bridge_id(config.get("bridgeid"))
    except (ValueError, AttributeError) as error:
        raise BridgeError(f"no Hue bridge answered at {host}") from error
    if bridge_id not in names:
        raise BridgeError("the Hue bridge certificate does not match its reported ID")
    return {"id": bridge_id, "host": str(host), "name": str(config.get("name") or "Hue Bridge")}


def _unchunk(body):
    out = b""
    while body:
        size_line, _, rest = body.partition(b"\r\n")
        size = int(size_line.split(b";")[0] or b"0", 16)
        if size == 0:
            break
        out += rest[:size]
        body = rest[size + 2:]
    return out


def discover():
    bridges = _discover_local()
    return bridges if bridges else _discover_cloud()


def parse_avahi(output):
    """Parses `avahi-browse -rpt _hue._tcp` lines into bridge candidates."""
    bridges = {}
    for line in output.splitlines():
        fields = line.split(";")
        if len(fields) < 10 or fields[0] != "=":
            continue
        address, txt = fields[7], ";".join(fields[9:])
        match = re.search(r'"bridgeid=([0-9A-Fa-f]{16})"', txt)
        if not match:
            continue
        bridge_id = match.group(1).lower()
        if ":" in address and bridge_id in bridges:
            continue  # prefer IPv4
        name = re.sub(r"\\(\d{3})", lambda m: chr(int(m.group(1))), fields[3])
        bridges[bridge_id] = {"id": bridge_id, "host": address, "name": name}
    return sorted(bridges.values(), key=lambda b: b["id"])


def _discover_local():
    try:
        result = subprocess.run(
            ["avahi-browse", "-rpt", "_hue._tcp"],
            capture_output=True, text=True, timeout=6, check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []
    return parse_avahi(result.stdout)


def _discover_cloud():
    try:
        with urllib.request.urlopen(DISCOVERY_URL, timeout=REQUEST_TIMEOUT) as response:
            entries = json.load(response)
    except (OSError, ValueError) as error:
        raise BridgeError("the Hue discovery service is unavailable") from error
    bridges = []
    for entry in entries if isinstance(entries, list) else []:
        try:
            bridges.append({
                "id": normalize_bridge_id(entry.get("id")),
                "host": str(entry["internalipaddress"]),
                "name": "Hue Bridge",
            })
        except (ValueError, KeyError, AttributeError):
            continue
    return bridges
