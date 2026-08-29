# Hyprland Display Switcher Overlay

A Windows+P-style display mode switcher for Hyprland using a GTK3 layer-shell overlay.

## Status

Implemented and in use. Both modes are verified against live compositor state:
the TV runs 3840×2160@144, 10-bit HDR, VRR over native HDMI 2.1 (FRL12 link
training) on kernel `7.2.2-2-cachyos`. See [ARCHITECTURE.md](ARCHITECTURE.md)
for the design and `plan.md` for the developer handoff.

## Modes

Exactly two exclusive modes; switching disables the other display and never
leaves the desktop without an active output:

| Mode | Display | Profile |
|---|---|---|
| **Monitor** | Philips PHL 345E2 | `3440x1440@74.98`, scale 1, 10-bit SDR (`cm = srgb`), VRR off |
| **TV** | Philips 55OLED820 ("Philips UHDTV") | `3840x2160@144` exactly, scale 1.5, 10-bit HDR (`cm = hdr`), VRR on, native HDMI 2.1 FRL12 |

Both displays are matched by their full EDID description selectors, so
connector renumbering cannot invalidate the persistent rules:

```
desc:Philips Consumer Electronics Company PHL 345E2 UK02226037640
desc:Philips Consumer Electronics Company Philips UHDTV 0x01010101
```

## How it works

- The overlay asks the applier for its status and invokes it with `monitor` or
  `tv`; `src/display_apply.sh` is the sole control plane.
- Each switch atomically rewrites
  `~/.config/hypr/display-switcher-generated.conf` (temporary file + rename,
  so Hyprland never sees a partial config) with hyprlang `monitorv2` rules,
  reloads, migrates workspaces to the target, and polls `hyprctl -j monitors
  all` until the full target profile is active — mode, scale, bit depth,
  color preset, VRR, HDR preference, and the other display disabled. Actual
  10-bit output on the HDMI link can be confirmed via the connector's
  `amdgpu_current_bpc` sysfs value.
- Fail-closed: if the requested display or the exact target mode is
  unavailable, the applier exits nonzero before changing topology. Reapplying
  the current mode is idempotent.

## Installation

```bash
./install.sh
```

This symlinks `display-switcher.py` and `display-apply.sh` into
`~/.local/bin/`, installs the overlay CSS, verifies runtime dependencies,
validates that your `hyprland.conf` sources `monitors.conf` before
`display-switcher-generated.conf`, and removes stale repository-owned links.

Dependencies: Bash, `hyprctl` (Hyprland), `jq`, Python 3, PyGObject, GTK3,
gtk-layer-shell.

Add the keybinding to `~/.config/hypr/keybindings.conf`:

```
bindd = $mainMod, O, Toggle display mode, exec, python3 ~/.local/bin/display-switcher.py
```

## Usage

Press `Super+O` to open the overlay, then:

- `Super+O` inside the overlay to cycle between the two modes
- `Enter` to confirm
- `Escape` to cancel

The overlay marks the current mode as reported by
`display_apply.sh status` (`monitor`, `tv`, or `unknown`). Manual control:

```bash
~/.local/bin/display-apply.sh status
~/.local/bin/display-apply.sh monitor
~/.local/bin/display-apply.sh tv
```

## Files

- `src/display_switcher.py` — GTK3 overlay: two mode buttons, status display, async invocation
- `src/display_apply.sh` — discovery, preflight, atomic generated config, safe transition, workspace migration, verification
- `config/display-switcher.css` — GTK styling matching the HyDE "Another World" theme
- `monitors.conf` — EDID-based cold-start profile (monitor active, TV disabled)
- `install.sh` — symlinks, dependency checks, source-order validation
- `research/` — adapter-era investigation notes; historical context only, not runtime guidance

## Kernel note

The TV path (4K144, 10-bit, VRR over FRL12) runs on the experimental
`7.2.2-2-cachyos` kernel with the amdgpu HDMI 2.1 FRL12 override
(`amdgpu.dcfeaturemask=0x402` and `force_hdmi21_frl_enc_enable` on
dcn30/dcn301). The stock kernel remains the fallback.
