#!/usr/bin/env python3
"""Display failover watcher: keeps one known display active.

Runs `display-apply.sh ensure` at startup, after hotplug settles, and while
the TV is the active output. Exits when Hyprland closes the event socket.
"""

import os
import socket
import subprocess
import sys
import time

APPLIER = os.path.expanduser("~/.local/bin/display-apply.sh")
SETTLE_SECONDS = 3.0  # rides out HDMI link retraining / HPD bounces
LOCK_RETRY_SECONDS = 2.0  # applier exit 5: another apply holds the lock
POWER_POLL_SECONDS = 8.0
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
    hotplug = time.monotonic() + SETTLE_SECONDS  # startup check covers boot
    power_poll = hotplug + POWER_POLL_SECONDS
    pending = b""
    while True:
        deadline = power_poll if hotplug is None else min(hotplug, power_poll)
        sock.settimeout(max(0.001, deadline - time.monotonic()))
        try:
            data = sock.recv(4096)
        except socket.timeout:
            now = time.monotonic()
            run_ensure = hotplug is not None and now >= hotplug
            if run_ensure:
                hotplug = None
            if now >= power_poll:
                power_poll = now + POWER_POLL_SECONDS
                if hotplug is None and not run_ensure:
                    status = subprocess.run([APPLIER, "status"], capture_output=True, text=True)
                    run_ensure = status.returncode == 0 and status.stdout.strip() == "tv"
            if run_ensure and ensure() == EXIT_LOCKED:
                hotplug = time.monotonic() + LOCK_RETRY_SECONDS
            continue
        if not data:
            return
        *lines, pending = (pending + data).split(b"\n")
        if any(line.startswith(EVENTS) for line in lines):
            hotplug = time.monotonic() + SETTLE_SECONDS


if __name__ == "__main__":
    main()
