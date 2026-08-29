# Hyprland Display Switcher

## Required Reading

Read in order before any change:

1. `ARCHITECTURE.md` — authoritative target behavior and design decisions.
2. `plan.md` — ordered gates; every gate has passed (historical record).
3. Existing source — the implemented native-HDMI behavior; the adapter-era runtime was deleted in the cutover.

The baseline before architecture work is commit `607ccaae0ad4c15ebf5592b72a8530f5ba504bac`.

## Project Status

Implemented and live. Both exclusive modes passed the Live Acceptance Matrix in `plan.md`, including the post-reboot run: the TV runs 3840x2160@144, 10-bit HDR (BT2020 RGB), VRR, over native HDMI FRL12; the monitor runs 3440x1440@74.98, 10-bit SDR.

FRL12 is reachable only because the TV VBIOS advertises `FRL_12G_EN=0` and the locally built CachyOS kernel forces FRL12 through `force_hdmi21_frl_enc_enable` for both `dcn30` and `dcn301`. See Tested Environment and Proven State.

The documentation cutover is complete: this file and `README.md` describe the implemented behavior, not the design target. `research/` remains adapter-era history and is not runtime guidance.

## Authoritative Scope

Exactly two exclusive modes:

- **Monitor:** Philips PHL 345E2, 3440×1440@74.98, 10-bit SDR, scale 1.
- **TV:** Philips 55OLED820/Philips UHDTV over native HDMI 2.1 FRL12, 3840x2160@144, 10-bit HDR (BT2020 RGB), scale 1.5, VRR enabled.

HDMI 2.1 FRL12 and VRR are proven on this hardware (see Tested Environment and Proven State); do not investigate or dispute them. The applier still requires the exact advertised 4K144 mode before TV-mode mutation; absence remains a fail-closed precondition, never permission to fall back.

## Non-negotiable Invariants

1. Identify display roles from structured EDID fields and connector class; connector names are runtime data, never role constants.
2. Enable and verify the target before disabling the source. Never create a zero-monitor state.
3. Accept only `status`, `monitor`, and `tv` in the applier.
4. Verify effective JSON state after every mutation. A successful command exit is not proof.
5. No automatic downgrade from 4K144, 10-bit, HDR, or VRR.
6. No sudo or privileged operations in project code.
7. No audio routing, Extend, Mirror, PCON/DPCD, DPM, adapter reset, daemon-kill, or Lua-generation compatibility path.
8. Keep `research/` unchanged as adapter-era history.
9. Touch only files assigned by the current task; `plan.md` gates are passed history.
10. The clean cutover is complete: do not reintroduce deleted helpers, aliases, adapter-era kernel parameters, or compatibility paths.

## Runtime Boundaries

| File | Responsibility |
|---|---|
| `src/display_switcher.py` | GTK presentation, two-mode selection, asynchronous invocation |
| `src/display_apply.sh` | Discovery, status, preflight, safe transition, generated config, workspace migration, verification |
| `config/display-switcher.css` | Existing visual theme; minimal two-button layout adjustment only |
| `monitors.conf` | EDID-based cold-start Monitor profile |
| `install.sh` | Symlinks, dependency checks, source-order validation, stale project-link cleanup |
| `ARCHITECTURE.md` | Design record |
| `plan.md` | Passed implementation and acceptance gates |
| `research/` | Historical evidence only; not runtime guidance |

The deployed HyDE config sources `monitors.conf` and then `display-switcher-generated.conf`. The single hyprlang `monitorv2` generator is implemented; the abandoned dual hyprlang/Lua branch was deleted in the cutover.

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
- Proven monitor state: 3440x1440@74.98, 10-bit, `srgb`, VRR off, `quirks:prefer_hdr=0`, `misc:vrr=0`.
- Compositor: Hyprland 0.56.2.
- Dependencies verified by `install.sh`: Bash, `hyprctl`, `jq`, Python 3, PyGObject, GTK3, gtk-layer-shell.

## Commands

Static checks:

```bash
bash -n src/display_apply.sh install.sh
python3 -m py_compile src/display_switcher.py
```

Behavioral entry points:

```bash
src/display_apply.sh status
src/display_apply.sh monitor
src/display_apply.sh tv
```

Live state evidence:

```bash
hyprctl -j monitors all
hyprctl getoption quirks:prefer_hdr
```

Final hardware validation has no substitute environment. The `plan.md` Live Acceptance Matrix passed after the kernel cutover and reboot; when touching profiles, treat live effective `hyprctl` state as the acceptance source.

## External Migration

Project code must not perform these operator actions:

- Set TV HDMI Ultra HD to **Optimal (Auto Game)**.
- Keep `amdgpu.dcfeaturemask=0x402` on the kernel command line (`/etc/default/limine`); removing it strands the TV below 4K144.
- Maintain the locally built CachyOS kernel (`localmodcfg`) carrying `force_hdmi21_frl_enc_enable` for `dcn30` and `dcn301`; without that override the VBIOS `FRL_12G_EN=0` value keeps the TV off FRL12.

Treat user-reported hardware/kernel support as ground truth. Treat live effective mode fields as the proof that project behavior meets the configured profile.
