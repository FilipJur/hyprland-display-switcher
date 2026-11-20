#!/usr/bin/env python3
"""Philips TV (JointSpace API v6, Google TV) power-state client for display-switcher.

The HDMI link cannot tell a TV in standby from one that is on (the connector
stays "connected" and the EDID stays readable), so the switcher asks the TV
over the LAN instead.

  tv_control.py state            print on | standby | unknown (exit 0), one word
  tv_control.py wake             wake the TV, wait until it reports on (exit 0/1)
  tv_control.py hdmi1            ask the awake TV to select HDMI 1
  tv_control.py pair-request     start pairing: the TV shows a PIN on screen
  tv_control.py pair-grant PIN   finish pairing with the PIN shown on the TV

Credentials: ~/.config/display-switcher/tv.json (mode 600): host, MAC, device id
and the digest-auth key the TV issued. Only the standard library is used.
No sudo, no writes outside that file and the transient pairing file next to it.
"""

import base64
import hashlib
import hmac
import json
import os
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

CONFIG_DIR = os.path.expanduser("~/.config/display-switcher")
CONFIG = os.path.join(CONFIG_DIR, "tv.json")
PENDING = os.path.join(CONFIG_DIR, "tv-pairing.json")
HTTPS_PORT = 1926
API = "6"
TIMEOUT = 3
WAKE_TIMEOUT = 25

# JointSpace v6 signing key used by haphilipsjs, not a per-TV credential.
APP_SECRET = "ZmVay1EQVFOaZhwQ4Kv81ypLAZNczV9sG4KkseXWn1NEk6cXmPKO/MCa9sryslvLCFMnNe4Z4CPXzToowvhHvA=="

_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE  # the TV uses a self-signed certificate


def _load():
    try:
        with open(CONFIG) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _save(path, data):
    os.makedirs(CONFIG_DIR, mode=0o700, exist_ok=True)
    fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(path + ".tmp", path)

class DigestAuthHandler(urllib.request.HTTPDigestAuthHandler):
    def http_error_401(self, req, fp, code, msg, headers):
        # The TV can stall a new TLS handshake while the challenge socket is open.
        if not req.has_header("Authorization") and headers.get("WWW-Authenticate", "").startswith("Digest "):
            fp.close()
        return super().http_error_401(req, fp, code, msg, headers)



def _request(host, path, body=None, auth=None, timeout=TIMEOUT):
    """JSON request; returns (status, parsed-or-text). Raises OSError on no route."""
    url = f"https://{host}:{HTTPS_PORT}/{API}/{path}"
    handlers = [urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=_CTX)]
    if auth:
        mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
        mgr.add_password(None, f"https://{host}:{HTTPS_PORT}/", auth[0], auth[1])
        handlers.append(DigestAuthHandler(mgr))
    opener = urllib.request.build_opener(*handlers)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with opener.open(req, timeout=timeout) as r:
            raw = r.read().decode(errors="replace")
            status = r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read().decode(errors="replace"), e.code
    except (urllib.error.URLError, socket.timeout, ConnectionError) as e:
        raise OSError(str(e)) from e
    try:
        return status, json.loads(raw)
    except ValueError:
        return status, raw


def discover_host():
    """mDNS: the Google Cast service the TV advertises (avahi-browse)."""
    try:
        out = subprocess.run(
            ["avahi-browse", "-a", "-t", "-r", "-p"],
            capture_output=True, text=True, timeout=8,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        f = line.split(";")
        if line.startswith("=") and len(f) > 8 and f[2] == "IPv4" and f[4] == "_googlecast._tcp" \
                and f[3].lower().startswith("philips"):
            return f[7]
    return None


def mac_of(host):
    try:
        out = subprocess.run(["ip", "neigh", "show", host], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    parts = out.split()
    return parts[parts.index("lladdr") + 1] if "lladdr" in parts else None


def powerstate(cfg):
    """'on' | 'standby' | None (unreachable or not paired)."""
    if not cfg:
        return None
    try:
        status, body = _request(cfg["host"], "powerstate", auth=(cfg["user"], cfg["pass"]))
    except OSError:
        return None
    if status == 200 and isinstance(body, dict):
        state = str(body.get("powerstate", "")).lower()
        if state == "on":
            return "on"
        if state in ("standby", "off"):
            return "standby"
    return None


def wake(cfg):
    """Wake the TV (API power-state, Wake-on-LAN as a fallback) and wait for 'on'."""
    state = powerstate(cfg)
    if state == "on":
        return True
    if state == "standby":
        try:
            _request(cfg["host"], "powerstate", body={"powerstate": "On"}, auth=(cfg["user"], cfg["pass"]))
        except OSError:
            pass
        if powerstate(cfg) == "on":
            return True
    if cfg.get("mac"):
        try:
            mac = bytes.fromhex(cfg["mac"].replace(":", ""))
            if len(mac) == 6:
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                    s.sendto(b"\xff" * 6 + mac * 16, ("255.255.255.255", 9))
        except (OSError, ValueError):
            pass
    deadline = time.monotonic() + WAKE_TIMEOUT
    while time.monotonic() < deadline:
        if powerstate(cfg) == "on":
            return True
        time.sleep(1)
    return False


def select_hdmi1(cfg):
    # Philips Android TV maps HDMI 1 to MediaTek's HW5 passthrough input.
    intent = {
        "action": "org.droidtv.playtv.SELECTURI",
        "component": {
            "packageName": "org.droidtv.playtv",
            "className": "org.droidtv.playtv.PlayTvActivity",
        },
        "extras": {
            "uri": "content://android.media.tv/passthrough/com.mediatek.tvinput%2F.hdmi.HDMIInputService%2FHW5",
        },
    }
    try:
        status, body = _request(cfg["host"], "activities/launch",
                                body={"intent": intent}, auth=(cfg["user"], cfg["pass"]))
    except OSError as e:
        print(f"tv_control: HDMI 1 request failed: {e}", file=sys.stderr)
        return False
    result = body.get("error_id") if isinstance(body, dict) else None
    if status == 200 and result in (None, "SUCCESS"):
        return True
    print(f"tv_control: HDMI 1 request rejected (HTTP {status}, {result})", file=sys.stderr)
    return False


def pair_request():
    host = discover_host()
    if not host:
        print("tv_control: no Philips TV found via mDNS (is it on the LAN?)", file=sys.stderr)
        return 3
    device_id = uuid.uuid4().hex
    spec = {"device_name": "display-switcher", "device_os": "Linux", "app_name": "display-switcher",
            "type": "native", "app_id": "app.id", "id": device_id}
    access = {"scope": ["read", "write", "control"]}
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(f"http://{host}:1925/{API}/system", timeout=TIMEOUT) as response:
            system = json.load(response)
        if system.get("featuring"):
            access["featuring"] = system["featuring"]
        status, body = _request(host, "pair/request", body={"access": access, "device": spec})
    except (OSError, ValueError) as e:
        print(f"tv_control: could not request pairing from {host}: {e}", file=sys.stderr)
        return 4
    result = body.get("error_id") if isinstance(body, dict) else None
    if status != 200 or result != "SUCCESS":
        print(f"tv_control: pair/request failed (HTTP {status}, {result})", file=sys.stderr)
        return 4
    _save(PENDING, {"host": host, "mac": mac_of(host), "device_id": device_id, "spec": spec,
                    "auth_key": body["auth_key"], "timestamp": body["timestamp"]})
    print(f"{host} accepted the pairing request. Check the TV screen for a PIN.")
    return 0


def pair_grant(pin):
    try:
        with open(PENDING) as f:
            p = json.load(f)
    except (OSError, ValueError):
        print("tv_control: no pending pairing; run pair-request first", file=sys.stderr)
        return 3
    sig = hmac.new(base64.b64decode(APP_SECRET), str(p["timestamp"]).encode() + pin.encode(), hashlib.sha1)
    auth = {"auth_appId": "1", "pin": pin, "auth_timestamp": p["timestamp"],
            "auth_signature": base64.b64encode(sig.digest()).decode()}
    try:
        status, body = _request(p["host"], "pair/grant", body={"auth": auth, "device": p["spec"]},
                                auth=(p["device_id"], p["auth_key"]))
    except OSError as e:
        print(f"tv_control: could not confirm pairing: {e}", file=sys.stderr)
        return 4
    result = body.get("error_id") if isinstance(body, dict) else None
    if status != 200 or result != "SUCCESS":
        print(f"tv_control: pair/grant failed (HTTP {status}, {result})", file=sys.stderr)
        return 4
    cfg = {"host": p["host"], "mac": p.get("mac"), "user": p["device_id"], "pass": p["auth_key"]}
    _save(CONFIG, cfg)
    os.remove(PENDING)
    print(f"paired; credentials saved to {CONFIG}; powerstate: {powerstate(cfg)}")
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "state":
        print(powerstate(_load()) or "unknown")
        return 0
    if cmd in ("wake", "hdmi1"):
        cfg = _load()
        if not cfg:
            print("tv_control: not paired", file=sys.stderr)
            return 3
        if cmd == "hdmi1":
            return 0 if select_hdmi1(cfg) else 1
        return 0 if wake(cfg) else 1
    if cmd == "pair-request":
        return pair_request()
    if cmd == "pair-grant" and len(argv) == 3:
        return pair_grant(argv[2])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
