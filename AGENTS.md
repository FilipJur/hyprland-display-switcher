# Hyprland Display Switcher

## Required Reading

Read in order before any change:

1. `ARCHITECTURE.md` — authoritative behavior and design decisions.
2. `plan.md` — ordered gates; every gate has passed (historical record).
3. Existing source — the implemented native-HDMI behavior; the adapter-era runtime was deleted in the cutover.

The baseline before architecture work is commit `607ccaae0ad4c15ebf5592b72a8530f5ba504bac`.

## Project Status

Implemented and live. Per-display settings passed the Live Acceptance Matrix in `plan.md`, including the post-reboot run: the TV runs 3840x2160@144, 10-bit HDR (BT2020 RGB), VRR, over native HDMI FRL12; the monitor runs 3440x1440@74.98, 8-bit SDR. The monitor also offers two custom modelines (`1920×1080@74.65`, `2560×1440@74.89`) with GPU Full-aspect pillarbox, needing the patched Aquamarine.

FRL12 is reachable only because the TV VBIOS advertises `FRL_12G_EN=0` and the locally built CachyOS kernel forces FRL12 through `force_hdmi21_frl_enc_enable` for both `dcn30` and `dcn301`. See Tested Environment and Proven State.

The documentation cutover is complete: this file and `README.md` describe the implemented behavior, not the design target. `research/` remains adapter-era history and is not runtime guidance.

## Authoritative Scope

Two displays, each with an independent settings set: `res`, `hz`, `vrr`, `hdr`, `scale`.

- **Monitor (`monitor`):** Philips PHL 345E2; defaults `3440x1440@74.98`, 8-bit SDR, VRR off, scale 1. Custom monitor modes `1920×1080@74.65` and `2560×1440@74.89` (GPU Full-aspect pillarbox, patched Aquamarine).
- **TV (`tv`):** Philips 55OLED820/Philips UHDTV over native HDMI 2.1 FRL12; defaults `3840x2160@144`, 10-bit HDR (BT2020 RGB), VRR on, scale 1.5.

Applying one display disables the other; omitted keys take that display's defaults.

HDMI 2.1 FRL12 and VRR are proven on this hardware (see Tested Environment and Proven State); do not investigate or dispute them. A non-default request must be advertised, while each display's own default resolution and refresh is accepted even when unadvertised (a disabled TV omits 4K144 from `availableModes`). Omission never substitutes a different mode.

## Non-negotiable Invariants

1. Identify display roles from structured EDID fields and connector class; connector names are runtime data, never role constants.
2. Enable and verify the target before disabling the source. Never create a zero-monitor state.
3. Accept only `status`, `caps`, `ensure`, and `monitor`/`tv` with optional `res`, `hz`, `vrr`, `hdr`, `scale` keys; nothing else.
4. Verify effective JSON state after every mutation. A successful command exit is not proof.
5. No automatic downgrade from 4K144, 10-bit, HDR, or VRR: explicit user settings are not automatic, and `ensure` applies defaults only when no known display is enabled.
6. No sudo or privileged operations in project code.
7. No audio routing, Extend, Mirror, PCON/DPCD, DPM, adapter reset, daemon-kill, or Lua-generation compatibility path.
8. Keep `research/` unchanged as adapter-era history.
9. Touch only files assigned by the current task; `plan.md` gates are passed history.
10. The clean cutover is complete: do not reintroduce deleted helpers, aliases, adapter-era kernel parameters, or compatibility paths.

## Runtime Boundaries

| File | Responsibility |
|---|---|
| `src/display_switcher.py` | Cold blue-black terminal GTK overlay in Martian Mono: `MONITOR`/`TV` frames with device, transport, `ACTIVE` and `SDR` tags, plus `RESOLUTION`/`REFRESH`/`VRR`/`HDR`/`SCALE` rows from `caps` (VRR/HDR only when capable); prompt shows the exact command; keys `↑↓`/`jk`, `←→`/`hl`, `space`, `tab`/`Super+O`, `1`/`2`, `enter`, `esc`; 5 s countdown; detached apply, `notify-send` failure |
| `src/display_apply.sh` | Discovery, `status`/`caps`/`ensure`, request preflight, safe transition, generated config, workspace migration, verification |
| `src/display_watch.py` | Hotplug failover: socket2 `monitoradded`/`monitorremoved`, 3 s debounce, runs `ensure` at startup and after events |
| `config/display-switcher.css` | Cold blue-black terminal theme in Martian Mono: tracked uppercase chrome, italic hints |
| `monitors.conf` | Comments plus `WAYLAND-1/2` disables; no `monitorv2` blocks (cold-boot fallback is HyDE's `monitor = ,preferred,auto,auto` in `base.conf`) |
| `install.sh` | Symlinks, dependency checks, source-order validation, stale project-link cleanup |
| `ARCHITECTURE.md` | Design record |
| `plan.md` | Passed implementation and acceptance gates |
| `research/` | Historical evidence only; not runtime guidance |

The deployed HyDE config sources `monitors.conf` and then `display-switcher-generated.conf`. The single hyprlang `monitorv2` generator is implemented; the abandoned dual hyprlang/Lua branch was deleted in the cutover. The overlay builds its controls from `caps` and remembers settings per display in `~/.local/state/display-switcher-settings.json`; only non-default keys reach the command line.

## Hardware Identity

Discovery (stable across the adapter and native-HDMI eras):

- GPU: AMD Radeon RX 6800 (Navi 21, DCN 3.0).
- Monitor: make `Philips Consumer Electronics Company`, model `PHL 345E2`, serial `UK02226037640`.
- TV: make `Philips Consumer Electronics Company`, model `Philips UHDTV`, dummy serial `0x01010101`, connector class `HDMI-A-*`.

Use exact make/model/serial for the Monitor. Use HDMI connector class plus exact make/model for the TV; its dummy serial is not identity.

## Tested Environment and Proven State

Live-verified after the kernel cutover and reboot:

- GPU: AMD Radeon RX 6800 (Navi 21, DCN 3.0).
- Kernel: `7.2.2-2-cachyos` (locally rebuilt with `localmodcfg`), booted with `amdgpu.dcfeaturemask=0x402`.
- Transport: the TV VBIOS advertises `FRL_12G_EN=0`; the kernel's `force_hdmi21_frl_enc_enable` override for both `dcn30` and `dcn301` forces HDMI 2.1 FRL12 regardless. A stock kernel rebuild silently drops the link below 4K144.
- Proven TV state: 3840x2160@144.00, `currentFormat` `XRGB2101010` (10-bit), BT2020 RGB colorimetry, color preset `hdr`, VRR true, scale 1.5, `quirks:prefer_hdr=1`, `misc:vrr=1`.
- Proven monitor state: 3440x1440@74.98, 8-bit, `srgb`, VRR off, `quirks:prefer_hdr=0`, `misc:vrr=0`.
- Compositor: Hyprland 0.56.2.
- Dependencies verified by `install.sh`: Bash, `hyprctl`, `jq`, Python 3, PyGObject, GTK3, gtk-layer-shell. Optional capability probes: `modetest` and `di-edid-decode`, used by `caps`; a missing tool reports the capability as false.

## Commands

Static checks:

```bash
bash -n src/display_apply.sh install.sh
python3 -m py_compile src/display_switcher.py src/display_watch.py
```

Behavioral entry points:

```bash
src/display_apply.sh status
src/display_apply.sh caps
src/display_apply.sh ensure
src/display_apply.sh monitor
src/display_apply.sh monitor res=1920x1080 hz=74.65
src/display_apply.sh tv
src/display_apply.sh tv hz=120
src/display_apply.sh tv hdr=0 vrr=0
```

Live state evidence:

```bash
hyprctl -j monitors all
hyprctl getoption quirks:prefer_hdr
```

Final hardware validation has no substitute environment. The `plan.md` Live Acceptance Matrix passed after the kernel cutover and reboot; when touching settings, treat live effective `hyprctl` state as the acceptance source.

## External Migration

Project code must not perform these operator actions:

- Set TV HDMI Ultra HD to **Optimal (Auto Game)**.
- Keep `amdgpu.dcfeaturemask=0x402` on the kernel command line (`/etc/default/limine`); removing it strands the TV below 4K144.
- Maintain the locally built CachyOS kernel (`localmodcfg`) carrying `force_hdmi21_frl_enc_enable` for `dcn30` and `dcn301`; without that override the VBIOS `FRL_12G_EN=0` value keeps the TV off FRL12.

Treat user-reported hardware/kernel support as ground truth. Treat live effective mode fields as the proof that project behavior meets the requested settings.
