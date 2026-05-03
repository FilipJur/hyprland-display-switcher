#!/usr/bin/env python3
"""
fix_pcon_audio.py - Fix CH7218 PCON HDMI audio mode via DPCD writes.

The amdgpu driver never sets DP_PROTOCOL_CONVERTER_CONTROL_0 (0x3050)
to HDMI output mode, leaving the PCON in DVI mode (no audio).
It also drops Source CTL mode on 0x305A, preventing proper FRL link setup.

This script fixes both registers and polls for FRL link readiness.
Must run as root (sudo) to access /dev/drm_dp_aux*.
"""

import os
import sys
import time
import glob


def find_aux_device(connector_name="DP-1"):
    """Find the DPCD AUX char device for a given DRM connector."""
    # Try card1 first (amdgpu), then card0
    for card in ["card1", "card0"]:
        aux_path = f"/sys/class/drm/{card}-{connector_name}/drm_dp_aux0"
        if os.path.exists(aux_path):
            dev_file = os.path.join(aux_path, "dev")
            if os.path.exists(dev_file):
                with open(dev_file) as f:
                    major_minor = f.read().strip()
                major, minor = major_minor.split(":")
                target_rdev = os.makedev(int(major), int(minor))
                # Find the matching device node
                for dev in sorted(glob.glob("/dev/drm_dp_aux*")):
                    try:
                        if os.stat(dev).st_rdev == target_rdev:
                            return dev
                    except (OSError, ValueError):
                        pass

    # Fallback: try aux0 if it exists and we can access it
    if os.path.exists("/dev/drm_dp_aux0"):
        return "/dev/drm_dp_aux0"

    return None


def read_dpcd(fd, addr):
    """Read a single byte from DPCD address."""
    os.lseek(fd, addr, os.SEEK_SET)
    data = os.read(fd, 1)
    return data[0] if data else None


def write_dpcd(fd, addr, value):
    """Write a single byte to DPCD address."""
    os.lseek(fd, addr, os.SEEK_SET)
    return os.write(fd, bytes([value]))


def fix_pcon_hdmi_mode():
    aux_dev = find_aux_device("DP-1")
    if not aux_dev:
        print("ERROR: Cannot find DPCD AUX device for DP-1", file=sys.stderr)
        sys.exit(1)

    print(f"Using AUX device: {aux_dev}", file=sys.stderr)

    try:
        fd = os.open(aux_dev, os.O_RDWR)
    except PermissionError:
        print(f"ERROR: Permission denied on {aux_dev} -- need root (sudo)", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: Cannot open {aux_dev}: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        # Read current state
        val_305A = read_dpcd(fd, 0x305A)
        val_3050 = read_dpcd(fd, 0x3050)
        val_303B = read_dpcd(fd, 0x303B)
        val_3036 = read_dpcd(fd, 0x3036)

        print(f"0x305A before: 0x{val_305A:02X}", file=sys.stderr)
        print(f"0x3050 before: 0x{val_3050:02X}", file=sys.stderr)
        print(f"0x303B before: 0x{val_303B:02X}", file=sys.stderr)
        print(f"0x3036 before: 0x{val_3036:02X}", file=sys.stderr)

        # Write Source CTL + FRL mode + HDMI link enable to 0x305A
        # Preserve max FRL BW bits (0-2), set Source CTL (3), FRL (5), HDMI link (7)
        new_305A = val_305A
        new_305A |= 0x08   # DP_PCON_ENABLE_SOURCE_CTL_MODE (bit 3)
        new_305A |= 0x20   # DP_PCON_ENABLE_LINK_FRL_MODE (bit 5)
        new_305A |= 0x80   # DP_PCON_ENABLE_HDMI_LINK (bit 7)
        # Ensure max FRL BW is set if zero
        if (new_305A & 0x07) == 0:
            new_305A |= 0x06  # 48 Gbps

        write_dpcd(fd, 0x305A, new_305A)
        print(f"Wrote 0x{new_305A:02X} to 0x305A", file=sys.stderr)

        # Write HDMI output mode (not DVI) to 0x3050
        write_dpcd(fd, 0x3050, 0x01)
        print("Wrote 0x01 to 0x3050 (HDMI mode)", file=sys.stderr)

        # Poll for HDMI TX link active
        print("Polling for HDMI TX link active...", end="", flush=True)
        link_active = False
        for i in range(20):
            time.sleep(0.5)
            val = read_dpcd(fd, 0x303B)
            if val is not None and (val & 0x01):
                print(f" OK (0x{val:02X})")
                link_active = True
                break
            print(".", end="", flush=True)
        else:
            val = read_dpcd(fd, 0x303B)
            print(f" TIMEOUT (0x{val:02X})")

        # Read final state
        final_303B = read_dpcd(fd, 0x303B)
        final_3036 = read_dpcd(fd, 0x3036)
        final_305A = read_dpcd(fd, 0x305A)
        final_3050 = read_dpcd(fd, 0x3050)
        print(f"Final state: 0x305A=0x{final_305A:02X} 0x3050=0x{final_3050:02X} "
              f"0x303B=0x{final_303B:02X} 0x3036=0x{final_3036:02X}", file=sys.stderr)

        if not link_active:
            print("WARNING: FRL link did not become active -- audio may still fail", file=sys.stderr)
            sys.exit(2)

    finally:
        os.close(fd)


if __name__ == "__main__":
    fix_pcon_hdmi_mode()
