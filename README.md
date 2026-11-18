# Hyprland Display Switcher Overlay

A Windows+P-style display mode switcher for Hyprland using a GTK3 layer-shell overlay.

## Status

Implemented and in use. The modes are verified against live compositor state:
the TV runs 3840×2160@144, 10-bit HDR, VRR over native HDMI 2.1 (FRL12 link
training) on kernel `7.2.2-2-cachyos`, and the monitor runs 3440×1440@74.98 in
8-bit SDR. See [ARCHITECTURE.md](ARCHITECTURE.md)
for the design and `plan.md` for the developer handoff.

## Modes

Five exclusive modes over two displays; switching disables the other display
and never leaves the desktop without an active output:

| Mode | Display | Profile |
|---|---|---|
| **Monitor** | Philips PHL 345E2 | `3440x1440@74.98`, scale 1, 8-bit SDR (`cm = srgb`), VRR off |
| **CS2** | Philips PHL 345E2 | custom `1920x1080@~75` modeline, GPU Full-aspect pillarbox (needs patched Aquamarine) |
| **CS2 2K** | Philips PHL 345E2 | custom `2560x1440@~75` modeline, same pillarbox treatment (applier only; not in the overlay) |
| **TV** | Philips 55OLED820 ("Philips UHDTV") | `3840x2160@144` exactly, scale 1.5, 10-bit HDR (`cm = hdr`), VRR on, native HDMI 2.1 FRL12 |
| **TV alt** | Philips 55OLED820 ("Philips UHDTV") | identical to TV with VRR off |

Both displays are matched by their full EDID description selectors, so
connector renumbering cannot invalidate the persistent rules:

```
desc:Philips Consumer Electronics Company PHL 345E2 UK02226037640
desc:Philips Consumer Electronics Company Philips UHDTV 0x01010101
```

## How it works

- The terminal-style overlay asks the applier for `status` and the `connected`
  roles, dims and skips rows whose display is not connected, and invokes it
  with `monitor`, `cs2`, `tv`, or `tv-alt` (`cs2-2k` is applier-only);
  `src/display_apply.sh` is the sole control plane. Applies launch detached,
  and a failed switch raises a `notify-send` notification with the applier's
  last error line.
- Each switch atomically rewrites
  `~/.config/hypr/display-switcher-generated.conf` (temporary file + rename,
  so Hyprland never sees a partial config) with hyprlang `monitorv2` rules,
  reloads, migrates workspaces to the target, and polls `hyprctl -j monitors
  all` until the full target profile is active — mode, scale, color preset,
  VRR, HDR preference, and the other display disabled (10-bit output is also
  asserted for the TV profiles). Actual 10-bit output on the HDMI link can be
  confirmed via the connector's `amdgpu_current_bpc` sysfs value.
- Fail-closed: if the requested display or the exact target mode is
  unavailable, the applier exits nonzero before changing topology. Reapplying
  the current mode is idempotent.
- Failover: `display_watch.py` listens to Hyprland's event socket and, 3 s
  after monitor hotplug events settle (and once at startup), runs
  `display_apply.sh ensure`. It retries 2 s later if the applier lock is held
  (exit 5). While any known display is enabled it does nothing, so a working
  display is never switched away from. When none is
  enabled (TV unplugged or powered off in TV mode, monitor off in monitor
  mode, or booting into a saved mode whose display is gone), it applies the
  monitor profile if the monitor is connected, else the TV profile.

## Installation

```bash
./install.sh
```

This symlinks `display-switcher.py`, `display-apply.sh`, and `display-watch.py` into
`~/.local/bin/`, installs the overlay CSS, verifies runtime dependencies,
validates that your `hyprland.conf` sources `monitors.conf` before
`display-switcher-generated.conf`, and removes stale repository-owned links.

Dependencies: Bash, `hyprctl` (Hyprland), `jq`, Python 3, PyGObject, GTK3,
gtk-layer-shell.

Add the keybinding to `~/.config/hypr/keybindings.conf`:

```
bindd = $mainMod, O, Toggle display mode, exec, python3 ~/.local/bin/display-switcher.py
```

Start the failover watcher after the startup reload in
`~/.config/hypr/userprefs.conf`:

```
exec-once = sh -c 'sleep 3 && hyprctl reload; exec python3 ~/.local/bin/display-watch.py'
```

## Usage

Press `Super+O` to open the terminal-style overlay: a monospace panel with a
warm dark background and a single cyan accent, a header showing the active
mode, a `$ display-apply.sh` prompt with a blinking cursor, and one row per
mode (`monitor`, `cs2`, `tv`, `tv-alt`) with device/spec columns and a
`● active` or `not connected` tag. Unavailable rows are dimmed and skipped.

- `Super+O`, `Down`, or `j` — next row
- `Up` or `k` — previous row
- `1`–`4` — apply that row directly
- `Enter` — apply the selected row
- `Esc` — cancel

The footer shows these key hints plus a 3 s auto-close countdown that resets
on input. Applying launches the applier detached; a failure raises a
`notify-send` notification with the applier's last error line.

The header and the `● active` row follow
`display_apply.sh status` (`monitor`, `cs2`, `cs2-2k`, `tv`, `tv-alt`, or
`unknown`; `cs2-2k` appears in the header only). Manual control:

```bash
~/.local/bin/display-apply.sh status
~/.local/bin/display-apply.sh connected
~/.local/bin/display-apply.sh ensure
~/.local/bin/display-apply.sh monitor
~/.local/bin/display-apply.sh cs2
~/.local/bin/display-apply.sh cs2-2k
~/.local/bin/display-apply.sh tv
~/.local/bin/display-apply.sh tv-alt
```

## Files

- `src/display_switcher.py` — GTK3 terminal-style overlay: active-mode header, `$ display-apply.sh` prompt, one row per mode (`monitor`, `cs2`, `tv`, `tv-alt`), dimmed unavailable rows, detached apply with failure notification
- `src/display_apply.sh` — discovery, preflight, atomic generated config, safe transition, workspace migration, verification, `connected`/`ensure` failover
- `src/display_watch.py` — hotplug watcher: runs `display_apply.sh ensure` on boot and monitor add/remove
- `config/display-switcher.css` — GTK styling matching the HyDE "Another World" theme
- `monitors.conf` — comments plus `WAYLAND-1/2` disables only; the cold-boot fallback is HyDE's `monitor = ,preferred,auto,auto` in `base.conf`, and the generated file selects the outputs
- `install.sh` — symlinks, dependency checks, source-order validation
- `research/` — adapter-era investigation notes; historical context only, not runtime guidance

## Kernel note

The TV path (4K144, 10-bit, VRR over FRL12) runs on the experimental
`7.2.2-2-cachyos` kernel with the amdgpu HDMI 2.1 FRL12 override
(`amdgpu.dcfeaturemask=0x402` and `force_hdmi21_frl_enc_enable` on
dcn30/dcn301). The stock kernel remains the fallback.
