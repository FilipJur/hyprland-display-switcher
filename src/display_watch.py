#!/usr/bin/env python3
"""Display failover watcher: keeps one known display active.

Listens to Hyprland's event socket. After monitor hotplug events settle (and
once at startup), runs `display-apply.sh ensure`, which does nothing while any
known display is enabled and otherwise enables a connected one. It never
switches away from a working display. Exits when Hyprland closes the socket.
"""

import os
import socket
import subprocess
import sys
import time

APPLIER = os.path.expanduser("~/.local/bin/display-apply.sh")
SETTLE_SECONDS = 3.0  # rides out HDMI link retraining / HPD bounces
LOCK_RETRY_SECONDS = 2.0  # applier exit 5: another apply holds the lock
EXIT_LOCKED = 5
EVENTS = (b"monitoradded", b"monitorremoved")  # also matches the v2 variants


def socket_path() -> str:
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    if not sig:
        sys.exit("display-watch: HYPRLAND_INSTANCE_SIGNATURE is not set")
    runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    return os.path.join(runtime, "hypr", sig, ".socket2.sock")


def ensure() -> int:
    return subprocess.run([APPLIER, "ensure"], stdout=subprocess.DEVNULL).returncode


def main() -> None:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(socket_path())
    deadline = time.monotonic() + SETTLE_SECONDS  # startup check covers boot
    pending = b""
    while True:
        if deadline is None:
            sock.settimeout(None)
        else:
            sock.settimeout(max(0.001, deadline - time.monotonic()))
        try:
            data = sock.recv(4096)
        except socket.timeout:
            deadline = None
            if ensure() == EXIT_LOCKED:
                deadline = time.monotonic() + LOCK_RETRY_SECONDS
            continue
        if not data:
            return
        *lines, pending = (pending + data).split(b"\n")
        if any(line.startswith(EVENTS) for line in lines):
            deadline = time.monotonic() + SETTLE_SECONDS


if __name__ == "__main__":
    main()
