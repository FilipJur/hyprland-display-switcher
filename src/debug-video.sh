#!/bin/bash
# debug-video.sh — sourced by display_apply.sh
# DRM/EDID/HDR metadata dump, called only on verification failure or
# explicit debug requests. Requires log() from the sourcing script.

# Log comprehensive DRM/HDR metadata for debugging
log_video_metadata() {
  local label="$1"
  log "--- Video Metadata Dump: $label ---"

  # Hyprland monitor state
  log "[HYPRCTL monitors all]"
  hyprctl monitors all 2>/dev/null | while IFS= read -r line; do
    log "  $line"
  done

  # JSON monitor output (for structured data)
  log "[HYPRCTL monitors -j]"
  local hypr_json
  hypr_json=$(hyprctl monitors -j 2>/dev/null)
  if [[ -n "$hypr_json" ]]; then
    echo "$hypr_json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for m in data:
        print(f\"  Monitor: {m.get('name')}\")
        print(f\"    disabled: {m.get('disabled')}\")
        print(f\"    currentFormat: {m.get('currentFormat')}\")
        print(f\"    colorManagementPreset: {m.get('colorManagementPreset')}\")
        print(f\"    sdrBrightness: {m.get('sdrBrightness')}\")
        print(f\"    sdrSaturation: {m.get('sdrSaturation')}\")
        print(f\"    sdrMinLuminance: {m.get('sdrMinLuminance')}\")
        print(f\"    sdrMaxLuminance: {m.get('sdrMaxLuminance')}\")
        print(f\"    minLuminance: {m.get('minLuminance')}\")
        print(f\"    maxLuminance: {m.get('maxLuminance')}\")
        print(f\"    maxAvgLuminance: {m.get('maxAvgLuminance')}\")
        print(f\"    availableModes: {len(m.get('availableModes', []))} modes\")
except Exception as e:
    print(f'    Parse error: {e}')
" 2>/dev/null | while IFS= read -r line; do
      log "  $line"
    done
  fi

  # DRM connector properties (most authoritative for HDR signaling)
  log "[DRM CONNECTOR STATE]"
  if command -v modetest >/dev/null 2>&1; then
    modetest -p -c 2>/dev/null | grep -A5 "DP-1\|DP-2" | while IFS= read -r line; do
      log "  $line"
    done

    # Check HDR metadata specifically
    log "[HDR OUTPUT METADATA]"
    modetest -p -c 2>/dev/null | grep -B1 -A10 "HDR_OUTPUT_METADATA" | while IFS= read -r line; do
      log "  $line"
    done
  else
    log "  modetest not available (install libdrm-utils)"
  fi

  # EDID info for DP-1
  log "[EDID - DP-1]"
  local edid_path="/sys/class/drm/card1-DP-1/edid"
  if [[ -f "$edid_path" ]]; then
    if command -v edid-decode >/dev/null 2>&1; then
      edid-decode "$edid_path" 2>/dev/null | grep -E "Manufacturer|Model|HDR|Color|Gamut|Display|Max|Luminance" | while IFS= read -r line; do
        log "  $line"
      done
    else
      log "  edid-decode not available (install edid-decode)"
      log "  EDID file exists: $edid_path ($(wc -c <"$edid_path") bytes)"
    fi
  else
    log "  No EDID file found at $edid_path"
  fi

  # amdgpu driver info
  log "[GPU DRIVER]"
  if [[ -f /sys/class/drm/card1/device/vendor ]]; then
    log "  Vendor: $(cat /sys/class/drm/card1/device/vendor 2>/dev/null)"
  fi
  if [[ -f /sys/class/drm/card1/device/device ]]; then
    log "  Device: $(cat /sys/class/drm/card1/device/device 2>/dev/null)"
  fi
  if [[ -f /sys/class/drm/card1/driver/version ]]; then
    log "  Driver version: $(cat /sys/class/drm/card1/driver/version 2>/dev/null)"
  fi
  log "  Kernel: $(uname -r)"

  log "--- End Video Metadata Dump ---"
}
