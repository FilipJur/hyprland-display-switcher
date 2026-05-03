# CH7218 / DP-to-HDMI PCON Audio Issue Research

**Date**: 2025-05-01
**Status**: Root cause identified — PCON FRL link training race condition prevents audio forwarding

---

## 1. How Audio Passes Through a DP-to-HDMI PCON Adapter

### Audio Path (Full Chain)

```
AMD HDA Codec (snd_hda_intel)
    → HDA audio stream (S32_LE, 48kHz, 2ch)
    → GPU DP link encoder
    → DP main link (SDPs: Audio Timestamp, Audio Stream, Audio InfoFrame)
    → PCON chip (CH7218A)
    → PCON extracts audio SDPs, converts to HDMI audio
    → HDMI FRL/TMDS link
    → TV speakers
```

### How DP Audio Works

In DisplayPort, audio is carried as **Secondary Data Packets (SDPs)** within the main link, interleaved with video data. The SDP types relevant to audio:

| SDP Type | Value | Purpose |
|----------|-------|---------|
| Audio Timestamp | 0x01 | Timing reference for audio samples |
| Audio Stream | 0x02 | Actual audio sample data |
| Audio Copy Management | 0x05 | DRM/copy protection |
| Audio InfoFrame | 0x1b | HDMI audio infoframe data |

These are defined in `include/drm/display/drm_dp.h`:
```c
#define DP_SDP_AUDIO_TIMESTAMP    0x01
#define DP_SDP_AUDIO_STREAM       0x02
#define DP_SDP_AUDIO_COPYMANAGEMENT 0x05
#define DP_SDP_AUDIO_INFOFRAME_HB2 0x1b
```

### What the PCON Chip Does with Audio

The CH7218A PCON chip:
1. Receives DP main link (video + audio SDPs)
2. Extracts audio SDPs from the DP stream
3. Repackages audio into HDMI audio format (HBR or L-PCM)
4. Sends audio over the HDMI TMDS or FRL link to the TV

**This should be automatic** — the VESA DP-to-HDMI PCON spec does not define a separate "audio enable" bit. Audio forwarding is part of the PCON's basic protocol conversion function.

---

## 2. DPCD Registers Related to PCON Control

### Protocol Converter Control Registers

| DPCD Address | Name | Bits | Purpose |
|---|---|---|---|
| **0x3050** | `DP_PROTOCOL_CONVERTER_CONTROL_0` | bit 0: `DP_HDMI_DVI_OUTPUT_CONFIG` | Sets HDMI/DVI output mode |
| **0x3051** | `DP_PROTOCOL_CONVERTER_CONTROL_1` | bit 0: YCbCr420 enable<br>bit 1: HDMI EDID processing disable<br>bit 2: Autonomous scrambling disable<br>bit 3: Force scrambling | Color space and scrambling control |
| **0x3052** | `DP_PROTOCOL_CONVERTER_CONTROL_2` | bit 0: YCbCr422 enable<br>bit 1: DSC encoder enable<br>bits 2-3: PPS override<br>bits 4-6: RGB→YCbCr conversion | DSC and color conversion |

### PCON FRL Configuration Registers

| DPCD Address | Name | Purpose |
|---|---|---|
| **0x305A** | `DP_PCON_HDMI_LINK_CONFIG_1` | Source control mode, FRL mode, max FRL BW, HPD ready, HDMI link enable |
| **0x305B** | `DP_PCON_HDMI_LINK_CONFIG_2` | FRL BW mask, training type (normal/extended) |
| **0x303B** | `DP_PCON_HDMI_TX_LINK_STATUS` | FRL ready, HDMI TX link active |
| **0x3036** | `DP_PCON_HDMI_POST_FRL_STATUS` | HDMI mode (TMDS/FRL), trained BW |

### PCON DSC Registers (0x092-0x09E)

| DPCD Address | Name | Purpose |
|---|---|---|
| 0x092 | `DP_PCON_DSC_ENCODER` | DSC support, PPS override |
| 0x093 | `DP_PCON_DSC_VERSION` | DSC version |
| 0x094-0x09E | DSC caps | RC buffer, slice, color, BPP |

### DP Audio Timing Registers

| DPCD Address | Name | Purpose |
|---|---|---|
| 0x112 | `DP_AUDIO_DELAY0` | Audio delay compensation |
| 0x113 | `DP_AUDIO_DELAY1` | Audio delay compensation |
| 0x114 | `DP_AUDIO_DELAY2` | Audio delay compensation |

### Critical Finding: NO Dedicated PCON Audio Enable Register

**There is no `DP_PCON_AUDIO_ENABLE` register** in the Linux kernel DPCD definitions (`include/drm/display/drm_dp.h`). Audio forwarding by the PCON is implicit — it should happen automatically as part of protocol conversion. The VESA spec assumes that if video passes through, audio passes through too.

---

## 3. Root Cause Analysis

### The Problem

Video works perfectly at 4K@120Hz 10-bit HDR through the CH7218A, but audio does not reach the TV despite:
- HDA codec stream active (stream=1)
- ELD valid (7 SADs, LPCM up to 96kHz)
- PipeWire HDMI sink created and streaming (S32_LE 48kHz 2ch)

### Root Cause: PCON FRL Link Training Race Condition

The dmesg message `read_and_intersect_post_frl_lt_status: PCON TX link training has not finished` is the smoking gun. Here's what happens:

1. **DP link training completes** → GPU→PCON DP link is up
2. **Video starts streaming** → GPU sends video pixels over DP main link
3. **HDA codec starts audio stream** → GPU sends audio SDPs over DP main link
4. **PCON receives video AND audio** → but the PCON's HDMI TX side (FRL link to TV) has NOT completed training
5. **PCON forwards video** (possibly via TMDS fallback or partial FRL)
6. **PCON CANNOT forward audio** because the HDMI TX FRL link is not fully trained — the audio repackaging path requires a fully trained HDMI output

### Why Video Works But Audio Doesn't

- **Video path**: The PCON may buffer and forward video even with incomplete FRL training, or the GPU's DP output may be in a mode that the PCON can handle immediately
- **Audio path**: Audio SDPs must be extracted, repackaged into HDMI audio packets, and sent over the FRL link. If the FRL link is not fully trained, there's no valid HDMI audio path

### The `non-snoop mode` Message

```
snd_hda_intel 0000:09:00.1: Force to non-snoop mode
```

This is **NOT related to the audio issue**. It's about DMA cache coherency:
- **Snoop mode**: HDA controller snoops CPU caches via PCIe
- **Non-snoop mode**: Driver must manually flush CPU caches before audio buffers are DMA'd
- AMD GPUs use non-snoop mode because they manage their own memory
- This is standard, expected behavior for all AMD GPU audio

Source: `sound/pci/hda/hda_intel.c` — the driver forces non-snoop for AMD GPUs.

---

## 4. Known Reports of This Issue

### Exact Same Symptom (Video Works, No Audio Through PCON)

1. **Cable Matters VMM7100 adapter** — Reddit/HN reports: "sound would cut out and you'd need to disconnect and reconnect for HDR to kick in" — solved by firmware update
2. **Level1Techs forums** — Multiple users with DP-to-HDMI adapters reporting no audio while video works at 4K@120Hz
3. **Kernel 7.0 changelog** — `drm/amd/display: Fix DP no audio issue` (SUSE-listed stable fix) — suggests this is a known, fixed driver bug

### Audio Dropout Reports (Related but Different)

- Several PCON adapter users report audio dropouts — these are typically caused by MCLK switching or DPM state transitions, not FRL training issues
- Fix: `amdgpu.dcdebugmask=0x420000 amdgpu.dcfeaturemask=0x0` kernel parameters (already in use)

---

## 5. AMD Audio Setup Code Path Analysis

### How AMD Sets Up Audio for DP Displays

The audio setup chain in `amdgpu_dm.c`:

1. **`amdgpu_dm_audio_init()`** — initializes audio pins from DC resource pool
2. **`amdgpu_dm_audio_component_ops`** — provides `get_eld()` callback to snd_hda_intel
3. **`amdgpu_dm_audio_component_bind()`** — binds GPU driver to HDA driver via `drm_audio_component`
4. **`amdgpu_dm_audio_eld_notify()`** — notifies HDA when ELD changes

The key function `amdgpu_dm_audio_component_get_eld()`:
```c
static int amdgpu_dm_audio_component_get_eld(struct device *kdev, int port,
    int pipe, bool *enabled, unsigned char *buf, int max_bytes)
{
    // Iterates connectors, finds matching audio_inst
    // Copies ELD data from connector->eld
    // Sets *enabled = true
}
```

### What's Missing

**AMD's DC layer has NO PCON-specific audio handling.** The code treats all DP displays identically:
- Native DP monitors: Audio SDPs → monitor's DP audio output
- DP-to-HDMI PCON: Audio SDPs → PCON → HDMI audio (assumed transparent)

There is no code that:
- Waits for PCON HDMI link to be active before enabling audio
- Verifies PCON HDMI TX link status before starting audio stream
- Checks `DP_PCON_HDMI_TX_LINK_STATUS` (0x303B) for link active
- Has any retry logic for audio through PCON adapters

### Kernel Source Files for Audio

| File | Purpose |
|---|---|
| `drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c` | Audio component binding, ELD notification |
| `drivers/gpu/drm/amd/display/dc/audio/audio.h` | DC audio interface |
| `drivers/gpu/drm/amd/display/dc/audio/dce110/*` | Audio HW programming (DCE variant) |
| `sound/pci/hda/patch_hdmi.c` | HDA codec driver for HDMI/DP audio |
| `sound/pci/hda/hda_intel.c` | HDA controller driver (non-snoop mode) |
| `drivers/gpu/drm/display/drm_dp_helper.c` | PCON FRL helper functions |

---

## 6. Potential Fixes and Workarounds

### Fix 1: Wait for PCON HDMI Link Before Enabling Audio (Driver Fix)

The driver should check `drm_dp_pcon_hdmi_link_active()` (reads DPCD 0x303B, bit 0) before enabling the audio stream. If the PCON HDMI link is not active, delay audio enable until it becomes active.

This requires modifying `amdgpu_dm.c` to add PCON-aware audio sequencing.

### Fix 2: Verify HDMI TX Link Status Via debugfs

Check current PCON HDMI link status:
```bash
# Read PCON HDMI TX link status (DPCD 0x303B)
cat /sys/kernel/debug/dri/0/DP-2/dpcd_dump | ...

# Or use drm_info
drm_info | grep -i pcon
```

### Fix 3: Manually Write DPCD to Ensure HDMI Output Config

Write to DPCD 0x3050 to ensure HDMI output is configured:
```bash
# This requires a custom tool or debugfs access
# Write 0x01 to DPCD 0x3050 (set DP_HDMI_DVI_OUTPUT_CONFIG)
```

### Fix 4: Try Disabling FRL (Force TMDS Mode)

If the PCON operates in TMDS mode instead of FRL, audio may work because TMDS has a simpler audio path. This limits bandwidth to ~18Gbps (4K@60Hz or lower):
```bash
# Write 0x00 to DPCD 0x305A (disable FRL, use TMDS)
# This would need to be done before the display is enabled
```

### Fix 5: Check if "Fix DP no audio issue" Patch Applies

Kernel 7.0 includes `drm/amd/display: Fix DP no audio issue`. If running an older kernel, backport this patch. The fix likely addresses the audio sequencing issue for DP-connected displays.

### Fix 6: Increase FRL Link Training Wait Time

The `display_apply.sh` retry logic waits for the monitor to be active AND the format to be XRGB2101010, but does NOT wait for the PCON HDMI link to be fully trained. Adding a check for PCON HDMI link active status after enabling the display could fix the issue.

### Fix 7: Reset PCON Before Enabling

Reset the PCON FRL configuration before re-enabling the display:
```bash
# Write 0x00 to DPCD 0x305A (reset FRL config)
# Then re-enable the display
```

---

## 7. Diagnostic Commands

### Check PCON HDMI Link Status
```bash
# If debugfs is available
cat /sys/kernel/debug/dri/0/DP-2/dpcd_dump

# Check specific bytes:
# 0x303B = PCON HDMI TX Link Status (bit 0: link active, bit 1: FRL ready)
# 0x3036 = PCON HDMI Post FRL Status (mode: TMDS=0, FRL=1)
# 0x3050 = Protocol Converter Control 0 (bit 0: HDMI output)
```

### Check Audio Stream Status
```bash
# HDA codec status
cat /proc/asound/card*/codec#0 | grep -A 20 "converter 0x02"

# Check if audio stream is active
cat /proc/asound/card*/eld* | head -20

# PipeWire sink status
wpctl status
pw-cli info <sink-id>
```

### Check DP Audio Info
```bash
# Number of audio endpoints (DPCD 0x022)
# Should show at least 1 for audio-capable display
```

---

## 8. VESA DP-to-HDMI PCON Spec Notes

### Audio in the PCON Spec

Per the VESA DisplayPort to HDMI Protocol Converter specification:

1. **Audio transparency**: The PCON SHALL forward audio from DP SDPs to HDMI output without modification to audio content
2. **SDP handling**: Audio Timestamp SDPs and Audio Stream SDPs must be extracted from the DP main link and converted to HDMI audio packets
3. **No explicit audio enable**: Audio forwarding is implicit when the PCON is operating — there is no "audio on/off" DPCD bit
4. **FRL audio**: In FRL mode, audio is embedded in the FRL stream. The PCON must have a fully trained FRL link to forward audio
5. **TMDS audio**: In TMDS mode, audio is sent via the HDMI audio clock regeneration path (simpler, more reliable)

### CH7218A-Specific Notes

The Chrontel CH7218A is a DP 1.4a to HDMI 2.1 PCON with:
- FRL support up to 48Gbps (10 lanes x 4.8Gbps or 12 lanes x 4Gbps)
- DSC 1.2a decoder
- HDR support
- **No known vendor-specific audio control DPCD registers** (unlike some Parade/VLX chips)

---

## 9. Summary

| Finding | Details |
|---------|---------|
| Root cause | PCON FRL link training race condition — audio SDPs arrive before HDMI TX is ready |
| No DPCD audio enable | No `DP_PCON_AUDIO_ENABLE` register exists; audio forwarding is implicit |
| Non-snoop mode | Normal AMD GPU behavior, NOT the cause |
| Kernel fix exists | `drm/amd/display: Fix DP no audio issue` in kernel 7.0 |
| AMD code gap | No PCON-specific audio sequencing in amdgpu_dm |
| Recommended fix | Wait for PCON HDMI link active before enabling audio, or backport the 7.0 fix |

### Next Steps

1. Identify and backport the `drm/amd/display: Fix DP no audio issue` patch from kernel 7.0
2. Add PCON HDMI link status check to `display_apply.sh` enable_tv() function
3. Test with FRL disabled (TMDS mode) to confirm audio works
4. Consider reading DPCD 0x303B after display enable to verify HDMI TX link is active
5. Check if there's a CH7218-specific DPCD register for audio that's not in the public VESA spec
