# Hyprland Display Switcher

A hardware-aware display mode toggle for Hyprland with GTK3 overlay UI.

## Project Overview

This project provides a Windows+P-style display switching interface for Hyprland on Linux. It allows cycling between monitor configurations (monitor, extend, mirror, TV) via a keyboard-driven overlay. All modes that use the TV default to 10-bit HDR output.

## Components

| File | Purpose |
|------|---------|
| `src/display_switcher.py` | GTK3 overlay application with layer-shell support |
| `src/display_apply.sh` | Bash script that applies monitor configurations via hyprctl |
| `src/display-dpm.sh` | DPM performance level control (optional, requires sudoers) |
| `config/display-switcher.css` | Another World theme styling for the overlay |
| `install.sh` | Creates symlinks to `~/.local/bin/` |

## Keybindings

- **Super+O**: Open display switcher / cycle to next mode
- **Enter**: Confirm selection
- **Escape**: Cancel and close

## Hardware Setup

- **GPU**: AMD RX 6800 XT (Navi 21, RDNA 2)
- **Main monitor**: DP-2, 3440x1440@74.98 (10-bit SDR, Philips 345E2)
- **TV**: Philips 55OLED820 (2024 OLED, LG WOLED panel), 4K@144Hz HDMI 2.1
- **Adapter**: UGREEN 8K DP 1.4→HDMI 2.1 (Chrontel CH7218 chip)
- **OS**: CachyOS Linux, kernel 7.0.2-2-cachyos

### Required Kernel Boot Parameters

Add to kernel command line:
```
amdgpu.dcdebugmask=0x420000 amdgpu.dcfeaturemask=0x0
```

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `amdgpu.dcdebugmask` | `0x420000` | `0x400000` (DC_OVERRIDE_PCON_VRR_ID_CHECK) + `0x20000` (DC_DISABLE_SUBVP_FAMS) |
| `amdgpu.dcfeaturemask` | `0x0` | Disables multi-monitor MCLK switching (clears bit 1) |

Without these parameters, the CH7218 adapter experiences HDMI 2.1 FRL link training failures causing black screens and 8-bit/10-bit oscillation.

### Persisting Boot Parameters (Limine)

Do NOT edit `/boot/limine.conf` directly — `limine-entry-tool` regenerates it on kernel updates. Instead, edit `/etc/default/limine`:

```
KERNEL_CMDLINE[default]+="amdgpu.dcdebugmask=0x420000 amdgpu.dcfeaturemask=0x0 quiet nowatchdog splash rw rootflags=subvol=/@ root=UUID=..."
```

Then run `sudo limine-update` to regenerate the boot config.

### TV Settings (Critical for Stability and Color Accuracy)

The CH7218 adapter's FRL link training fails when VRR/FreeSync is negotiated on the TV. **Disable VRR**:

```
Settings → Channels & inputs → External Inputs → HDMI (port) → HDMI Ultra HD → Optimal
```

This enables 4K@120Hz 10-bit HDR but disables FreeSync/VRR. For gaming, switch back to "Optimal (Auto Game)" to restore VRR.

**Picture settings for accurate colors (LG WOLED panel):**

| Setting | Value | Why |
|---------|-------|-----|
| Picture mode | **Monitor** | Enables 4:4:4 chroma, disables processing |
| Color gamut | **Auto** | Clamps SDR to sRGB; "Native" oversaturates |
| Color temperature | Warm 50 | D65 reference white |
| Sharpness | 0 | Critical for text clarity |
| Gamma | 2.2 | sRGB standard for PC |
| Contrast | 85-90 SDR / 100 HDR | Avoid clipping |
| HDMI Black Level | Normal | Must match GPU Full Range (0-255) |
| All motion/noise/processing | Off | Motion smoothing, noise reduction, dynamic contrast |

## Architecture

### Display Modes (4 modes, HDR default)

| # | Mode | DP-2 | DP-1 | CM Preset |
|---|------|------|------|-----------|
| 1 | **Monitor** | 10b SDR, active | off | `cm,srgb` |
| 2 | **Extend** | 10b SDR, active | 10b HDR, scale 1.5 | `cm,hdr` |
| 3 | **Mirror** | 10b SDR, active | 10b SDR, mirror | `cm,srgb` |
| 4 | **TV** | off | 10b HDR, scale 1.5 | `cm,hdr` |

HDR tuning: `sdrbrightness=1.5`, `sdrsaturation=1.01`

### State Management

- Zero state files — detect actual monitor layout on every overlay open
- `hyprctl monitors all` (text) for detection — shows disabled monitors
- `hyprctl monitors -j` only shows enabled monitors (insufficient)
- Prevents stale state after crashes or manual changes

### Crash Prevention

**Always enable the target monitor BEFORE disabling the old one.** A zero-monitor state causes Hyprland SIGSEGV.

### Retry + Adapter Reset Logic

`enable_tv()` function in `display_apply.sh`:
1. Disable DP-1 → sleep 2s (forces clean DSC/FRL re-handshake)
2. Enable with `bitdepth,10,cm,hdr` → sleep 6s for HDR, 3s for SDR
3. Verify DP-1 is active AND format is `XRGB2101010` (10-bit)
4. Retry once if verification fails

## Confirmed Behavior

### What works (stable)
- **Monitor**: 10-bit SDR, DP-2 only
- **Extend**: 10-bit HDR on DP-1 + 10-bit SDR on DP-2 (FRL link stable with both displays active)
- **TV**: 10-bit HDR on DP-1 (stable with VRR disabled on TV)

### What fails
- **Mirror mode**: Fails verification every time. `mirrorOf` field not populating correctly.
- **VRR/FreeSync**: CH7218 FRL link training fails when VRR is negotiated. Fixed by setting TV HDMI to "Optimal" (disables VRR).

### Known Hardware Limitations
- **CH7218 PCON**: FRL link training at 4K@120Hz is unreliable. Software cannot fix this — it's a chip-level firmware issue.
- **Kernel DSC validation bug**: `dsc_cfg.is_frl` is never set to `true` for PCON adapters in the amdgpu driver, causing DSC to be stripped during bandwidth validation. A kernel patch exists at `~/build/kernel/0001-dont-strip-dsc-for-frl-pcon.patch` (not yet applied).
- **DSC required for 4K@120Hz 10-bit**: DP 1.4 bandwidth (25.92 Gbps) can't fit uncompressed 4K@120Hz 10-bit (~30 Gbps). DSC is mandatory.

### Color Fixes Applied
- `cm,srgb` on all DP-2 configs — prevents stale BT.2020/PQ DRM state from previous HDR mode
- `cm,hdr` on all DP-1 configs — consistent HDR signaling
- Broadcast RGB: Automatic (Full range 0-255) — confirmed via modetest

## Important Notes

- Monitor port identifiers changed from `HDMI-A-1` to `DP-1` during development
- `monitors.conf` uses `bitdepth,10,cm,srgb` for DP-2 startup config
- `DISPLAY_SWITCHER_8BIT` env var removed — bitdepth hardcoded to 10
- `sdr_min_luminance` and `sdr_max_luminance` NOT supported by `hyprctl keyword monitor` — only in `monitorv2 {}` blocks
- `cm_auto_hdr` is left at default `1` — not toggled by scripts

## Troubleshooting

### TV shows black screen / oscillation
1. Verify boot params: `cat /proc/cmdline | grep amdgpu`
2. Verify TV HDMI is set to "Optimal" (not "Auto Game")
3. Check logs: `tail -50 ~/.local/state/display-switcher.log`
4. Manual test: `hyprctl keyword monitor "DP-1,3840x2160@120,0x0,1,bitdepth,10,cm,hdr,sdrbrightness,1.5,sdrsaturation,1.01"`

### Colors look washed out on TV
1. Set Picture mode to **Monitor**
2. Set Color gamut to **Auto** (not Native)
3. Verify HDMI Black Level = Normal (matching GPU Full range)
4. Check Sharpness = 0

### Mirror mode fails
- Known broken — use extend or tv modes instead

### Overlay won't open
1. Clear stale files: `rm -f ~/.local/state/display-switcher.{pid,cooldown} ~/.local/state/display-apply.lock`
2. Launch manually: `python3 ~/.local/bin/display-switcher.py`

### DPM force not working
- Requires sudoers rule: `filip ALL=(ALL) NOPASSWD: /home/filip/.local/bin/display-dpm.sh`
- Without it, GPU clock transitions during mode switch are handled by kernel boot params

## Installation

```bash
cd ~/projects/hyprland-display-switcher
./install.sh
```

Then add to `~/.config/hypr/keybindings.conf`:
```
bindd = $mainMod, O, Toggle display mode, exec, python3 ~/.local/bin/display-switcher.py
```

## Files

```
~/.local/bin/display-switcher.py    # Symlink → src/display_switcher.py
~/.local/bin/display-apply.sh       # Symlink → src/display_apply.sh
~/.local/bin/display-dpm.sh         # Symlink → src/display-dpm.sh
~/.config/hypr/display-switcher.css # Theme styling
~/.local/state/display-switcher.log # Application logs
~/.local/state/display-apply.lock   # Concurrent execution lock
~/.local/state/display-switcher.pid # Single instance PID
/etc/default/limine                 # Persistent kernel parameters
```

## Research

- `research/ch7218_dim02.md` — PCON FRL link training code paths, `read_and_intersect_post_frl_lt_status`
- `research/ch7218_dim03.md` — DSC `is_frl` bug, bandwidth validation mismatch, single vs dual display
- `research/ch7218_dim04.md` — PCON FRL patches and bug reports
- `research/ch7218_dim05.md` — amdgpu kernel parameters, DC debug/feature masks
- `research/ch7218_dim06.md` — EDID/DPCD register analysis, debugfs DPCD access
- `research/ch7218_dim07.md` — MCLK behavior on RDNA 2, FAMS, VRR clock interaction
- `research/ch7218_dim08.md` — Known workarounds for PCON adapters, community fixes
- `research/ch7218_dim09.md` — DPM sysfs access without root
- `research/ch7218_dim10.md` — Kernel 6.18 vs 7.0 amdgpu display code differences
- `plan.md` — Root cause analysis plan for PCON FRL link training failure
- `research/` — Deep research on CH7218 adapter and HDR on Linux

## Kernel Patch (Unapplied)

A kernel patch to fix the DSC `is_frl` bug exists at:
```
~/build/kernel/0001-dont-strip-dsc-for-frl-pcon.patch
```

This removes DSC stripping from `dp_active_dongle_validate_timing()` in the amdgpu driver. The `is_frl` field is never set to `true` for any PCON adapter, causing bandwidth validation to use uncompressed timing and reject valid 10-bit modes. Not yet applied — building a custom kernel takes 1-2 hours and requires ~30GB disk space.
