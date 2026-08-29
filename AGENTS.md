# Hyprland Display Switcher

## Required Reading

Read in order before implementation:

1. `ARCHITECTURE.md` — authoritative target behavior and design decisions.
2. `plan.md` — ordered implementation and validation gates.
3. Existing source — legacy behavior to replace, not preserve by default.

The baseline before architecture work is commit `607ccaae0ad4c15ebf5592b72a8530f5ba504bac`.

## Project Status

Architecture approved; native-HDMI implementation pending. Current runtime code is adapter-era legacy and is broken against the present `DP-2` + `HDMI-A-1` topology.

Do not update README to claim the refactor works until the post-reboot live acceptance matrix passes.

## Authoritative Scope

Exactly two exclusive modes:

- **Monitor:** Philips PHL 345E2, 3440×1440@74.98, 10-bit SDR, scale 1.
- **TV:** Philips 55OLED820/Philips UHDTV over native HDMI, 3840×2160@144, 10-bit HDR, scale 1.5, VRR enabled.

HDMI 2.1 and VRR kernel support are confirmed facts. Do not investigate or dispute them. The TV must advertise the exact 4K144 mode before TV-mode mutation; absence is a fail-closed precondition, never permission to fall back.

## Non-negotiable Invariants

1. Identify display roles from structured EDID fields and connector class; connector names are runtime data, never role constants.
2. Enable and verify the target before disabling the source. Never create a zero-monitor state.
3. Accept only `status`, `monitor`, and `tv` in the applier.
4. Verify effective JSON state after every mutation. A successful command exit is not proof.
5. No automatic downgrade from 4K144, 10-bit, HDR, or VRR.
6. No sudo or privileged operations in project code.
7. No audio routing, Extend, Mirror, PCON/DPCD, DPM, adapter reset, daemon-kill, or Lua-generation compatibility path.
8. Keep `research/` unchanged as adapter-era history.
9. Touch only files assigned by the current phase in `plan.md`.
10. Do not preserve dead helpers or aliases after the clean cutover.

## Target Runtime Boundaries

| File | Responsibility |
|---|---|
| `src/display_switcher.py` | GTK presentation, two-mode selection, asynchronous invocation |
| `src/display_apply.sh` | Discovery, status, preflight, safe transition, generated config, workspace migration, verification |
| `config/display-switcher.css` | Existing visual theme; minimal two-button layout adjustment only |
| `monitors.conf` | EDID-based cold-start Monitor profile |
| `install.sh` | Symlinks, dependency checks, source-order validation, stale project-link cleanup |
| `ARCHITECTURE.md` | Target design |
| `plan.md` | Implementation and acceptance sequence |
| `research/` | Historical evidence only; not runtime guidance |

The deployed HyDE config currently sources `monitors.conf` and then `display-switcher-generated.conf`. Use one hyprlang `monitorv2` generator for this cutover. Do not retain the abandoned dual hyprlang/Lua branch.

## Hardware Identity

Architecture-time discovery:

- Monitor: make `Philips Consumer Electronics Company`, model `PHL 345E2`, serial `UK02226037640`.
- TV: make `Philips Consumer Electronics Company`, model `Philips UHDTV`, dummy serial `0x01010101`, connector class `HDMI-A-*`.

Use exact make/model/serial for the Monitor. Use HDMI connector class plus exact make/model for the TV; its dummy serial is not identity.

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

There is no substitute test environment for final hardware validation. Complete every row in `plan.md`'s Live Acceptance Matrix, including the run after boot-parameter cleanup and reboot.

## External Migration

Project code must not perform these operator actions:

- Set TV HDMI Ultra HD to **Optimal (Auto Game)**.
- Remove adapter-era amdgpu masks and `snd_hda_intel.probe_mask=1` from `/etc/default/limine`.
- Run `sudo limine-update` and reboot.
- Remove obsolete DPM/PCON sudoers rules with `visudo`.

Treat user-reported hardware/kernel support as ground truth. Treat live effective mode fields as the proof that project behavior meets the configured profile.
