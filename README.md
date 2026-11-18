# Hyprland Display Switcher Overlay

A Windows+P-style display mode switcher for Hyprland using a GTK3 layer-shell overlay.

## Status

Implemented and in use. Per-display settings are verified against live
compositor state: the TV runs 3840×2160@144, 10-bit HDR, VRR over native
HDMI 2.1 (FRL12 link training) on kernel `7.2.2-2-cachyos`, and the monitor
runs 3440×1440@74.98 in 8-bit SDR. See [ARCHITECTURE.md](ARCHITECTURE.md)
for the design and `plan.md` for the developer handoff.

## Displays and settings

Each display is configured per apply; applying one disables the other and
never leaves the desktop without an active output. Omitted keys take that
display's defaults.

| Display | Identity | Defaults |
|---|---|---|
| **Monitor** | Philips PHL 345E2 | `3440x1440@74.98`, scale 1, 8-bit SDR (`cm = srgb`), VRR off |
| **TV** | Philips 55OLED820 ("Philips UHDTV") | `3840x2160@144`, scale 1.5, 10-bit HDR (`cm = hdr`), VRR on, native HDMI 2.1 FRL12 |

Settings are resolution, refresh, VRR on/off, HDR on/off, and scale ∈
{1, 1.25, 1.5, 1.6, 1.75, 2}; the scale must give an integral logical size at
the chosen resolution, and `caps` reports the valid scales per resolution. The
monitor also offers two custom modelines, `1920x1080@74.65` and
`2560x1440@74.89`, with GPU Full-aspect pillarbox (needs the patched
Aquamarine).

Both displays are matched by their full EDID description selectors, so
connector renumbering cannot invalidate the persistent rules:

```
desc:Philips Consumer Electronics Company PHL 345E2 UK02226037640
desc:Philips Consumer Electronics Company Philips UHDTV 0x01010101
```

## How it works

- The overlay probes the applier with `caps` and builds one frame per display
  from it; `src/display_apply.sh` is the sole control plane. Applies launch
  detached, and a failure raises a `notify-send` notification titled
  `<Display> failed` with the applier's last error line.
- Each apply atomically rewrites
  `~/.config/hypr/display-switcher-generated.conf` (temporary file + rename,
  so Hyprland never sees a partial config) with hyprlang `monitorv2` rules,
  reloads, migrates workspaces to the target, and polls `hyprctl -j monitors
  all` until the requested settings are active — resolution, refresh, scale,
  color preset, VRR, HDR preference, and the other display disabled (10-bit
  output is asserted for the TV). The final poll also checks the kernel's DRM
  state (`modetest -c/-e/-p`): CRTC mode and refresh, `VRR_ENABLED`,
  `Colorspace`, and the HDR metadata EOTF. Actual 10-bit output on the HDMI
  link can be confirmed via the connector's `amdgpu_current_bpc` sysfs value.
- VRR is applied through the global `misc:vrr` only; generated display rules
  carry no `vrr`, because Hyprland 0.56.2 treats a VRR-only rule change as a
  full match and would keep a stale per-display value. A rule written by an
  older version keeps its per-display `vrr` until the display's rule is
  rewritten (display switch, mode/scale change, or restart).
- Fail-closed: a non-default mode must be advertised (or be a custom monitor
  modeline), and unsupported VRR/HDR or scale exits nonzero before changing
  topology. Reapplying the same settings is idempotent.
- Failover: `display_watch.py` listens to Hyprland's event socket and, 3 s
  after monitor hotplug events settle (and once at startup), runs
  `display_apply.sh ensure`. It retries 2 s later if the applier lock is held
  (exit 5). While any known display is enabled it does nothing, so a working
  display is never switched away from. When none is enabled (TV unplugged or
  powered off, monitor off, or booting into saved settings whose display is
  gone), it applies the monitor's defaults if the monitor is connected, else
  the TV's defaults.

## Installation

```bash
./install.sh
```

This symlinks `display-switcher.py`, `display-apply.sh`, and `display-watch.py` into
`~/.local/bin/`, installs the overlay CSS, verifies runtime dependencies,
validates that your `hyprland.conf` sources `monitors.conf` before
`display-switcher-generated.conf`, and removes stale repository-owned links.

Dependencies: Bash, `hyprctl` (Hyprland), `jq`, Python 3, PyGObject, GTK3,
gtk-layer-shell. Optional capability probes: `modetest` (libdrm) and
`di-edid-decode` (libdisplay-info), used by `caps`; without them VRR/HDR
controls are hidden.

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

Press `Super+O` to open the overlay: a cold blue-black terminal panel in
Martian Mono (installed user-level in `~/.local/share/fonts/MartianMono`),
with tracked uppercase chrome and italic hints.

Displays are the top level: a 1px frame per display whose legend carries the
role, device and transport, an inverse `ACTIVE` tag, and `SDR` when the
display cannot do HDR; a disconnected frame reads `not connected`. Inside each
frame are `RESOLUTION`, `REFRESH`, `VRR`, `HDR`, and `SCALE` rows built from
`caps` — VRR and HDR only when the display is capable, scales only where the
logical size stays integral (changing resolution snaps the scale to the
nearest valid one) — and the prompt shows the exact command with a blinking
cursor, e.g. `$ display-apply.sh tv hz=120` (only keys that differ from the
display's defaults).

Initial values per display come from the remembered settings file
(`~/.local/state/display-switcher-settings.json`), then the display's current
state, then its defaults.

- `↑`/`↓` or `j`/`k` — select a setting row
- `←`/`→` or `h`/`l` — change the value
- `space` — toggle VRR/HDR
- `Tab` or `Super+O` — next display
- `1`/`2` — apply that display
- `Enter` — apply the focused row's display
- `Esc` — close

The footer shows these hints plus a 5 s auto-close countdown that resets on
input. Applying launches the applier detached; a failure raises a
`notify-send` notification titled `<Display> failed` with the applier's last
error line.

Manual control:

```bash
~/.local/bin/display-apply.sh status
~/.local/bin/display-apply.sh caps
~/.local/bin/display-apply.sh ensure
~/.local/bin/display-apply.sh monitor
~/.local/bin/display-apply.sh monitor res=1920x1080 hz=74.65
~/.local/bin/display-apply.sh tv
~/.local/bin/display-apply.sh tv hz=120
~/.local/bin/display-apply.sh tv hdr=0 vrr=0
```

## Files

- `src/display_switcher.py` — cold blue-black terminal GTK overlay: per-display frames (`MONITOR`/`TV`) with device/transport, `ACTIVE`/`SDR` tags, `RESOLUTION`/`REFRESH`/`VRR`/`HDR`/`SCALE` rows from `caps`, remembered settings, detached apply with failure notification
- `src/display_apply.sh` — discovery, `status`/`caps`/`ensure`, request preflight, atomic generated config, safe transition, workspace migration, verification
- `src/display_watch.py` — hotplug watcher: runs `display_apply.sh ensure` on boot and monitor add/remove
- `config/display-switcher.css` — cold blue-black terminal theme in Martian Mono: tracked uppercase chrome, italic hints
- `monitors.conf` — comments plus `WAYLAND-1/2` disables only; the cold-boot fallback is HyDE's `monitor = ,preferred,auto,auto` in `base.conf`, and the generated file selects the outputs
- `install.sh` — symlinks, dependency checks, source-order validation
- `research/` — adapter-era investigation notes; historical context only, not runtime guidance

## Kernel note

The TV path (4K144, 10-bit, VRR over FRL12) runs on the experimental
`7.2.2-2-cachyos` kernel with the amdgpu HDMI 2.1 FRL12 override
(`amdgpu.dcfeaturemask=0x402` and `force_hdmi21_frl_enc_enable` on
dcn30/dcn301). The stock kernel remains the fallback.
