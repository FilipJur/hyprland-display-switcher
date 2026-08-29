#!/bin/bash
# display_apply.sh - MVP display mode applier with verification
# Zero state, 10-bit for adapter stability, logs to stdout/stderr
#
# TV OVERSCAN FIX:
# If you see edges cut off in TV mode, your Philips TV is likely overscanning.
# The EDID reports "IT scan behavior: Always Underscanned" which means PC
# content gets scaled down. To fix:
#   Settings → Picture → Screen Format → "Unscaled" / "Just Scan" / "Screen Fit"
# Or on Philips 55OLED820:
#   Settings → Channels & inputs → External Inputs → HDMI → PC Mode (enable)
#
# Apps not respecting 1.5x scaling?
#   - XWayland apps: add 'xwayland { force_zero_scaling = true }' to hyprland.conf
#   - Native Wayland apps should scale automatically via wl_output protocol
#   - GTK: unset GDK_SCALE (don't set it globally)
#   - Qt: QT_AUTO_SCREEN_SCALE_FACTOR=1

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-monitor}"

# Restore Hyprland IPC environment if missing (e.g., launched from a non-Hyprland shell).
# /run/user/<uid>/hypr/<sig>/.socket.sock is created by Hyprland on startup.
if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  local_sig=$(ls -t /run/user/"$(id -u)"/hypr/ 2>/dev/null | head -1)
  [[ -n "$local_sig" ]] && export HYPRLAND_INSTANCE_SIGNATURE="$local_sig"
fi

LOG_FILE="$HOME/.local/state/display-switcher.log"
LOCK_FILE="$HOME/.local/state/display-apply.lock"
# Monitor config
MONITOR="DP-2"
TV="DP-1"
MONITOR_RES="3440x1440@74.98"
TV_RES="3840x2160@120"
TV_SCALE="1.5"
BITDEPTH="10"

# IMPORTANT: Hyprland 0.55 monitorv2 {} blocks work, but they CONFLICT
# with legacy monitor= lines for the same output. Never write both for
# the same physical port in the same generated config.
#
# Lua migration: set DISPLAY_SWITCHER_LUA=1 to generate hl.monitor() Lua
# blocks instead of hyprlang monitorv2 {}. Requires hyprland.lua as
# main config with require("display-switcher-generated"). Defaults to
# hyprlang .conf for HyDE compatibility until HyDE ships Lua.

# Color management presets (used by verify_mode() only)
CM_SDR="srgb"
CM_HDR="hdr"

# Escape hatch for reconfigure_dp_encoder — used via hyprctl keyword monitor
TV_HDR_OPTIONS="bitdepth,10,cm,hdr,sdrbrightness,1.0,sdrsaturation,1.0"

# ------------------------------------------------------------------
# Generated config path — extension varies by format.
# hyprlang: display-switcher-generated.conf (sourced from hyprland.conf)
# Lua:      display-switcher-generated.lua  (required from hyprland.lua)
# ------------------------------------------------------------------
USE_LUA="${DISPLAY_SWITCHER_LUA:-0}"
if [[ "$USE_LUA" == "1" ]]; then
  GENERATED_EXT="lua"
  HYPR_CONFIG="$HOME/.config/hypr/hyprland.lua"
  CHECK_SOURCE_STRING='require.*display-switcher-generated"\?\(\.conf\)\?'
  SOURCE_LOG_LINE='  require("display-switcher-generated")  -- Lua mode'
else
  GENERATED_EXT="conf"
  HYPR_CONFIG="$HOME/.config/hypr/hyprland.conf"
  CHECK_SOURCE_STRING='source.*display-switcher-generated.conf'
  SOURCE_LOG_LINE="  source = $HOME/.config/hypr/display-switcher-generated.conf"
fi
GENERATED_CONFIG="$HOME/.config/hypr/display-switcher-generated.$GENERATED_EXT"

# Sourced helpers
source "${SCRIPT_DIR}/debug-video.sh"                                # log_video_metadata()
[[ "$USE_LUA" == "1" ]] && source "${SCRIPT_DIR}/lua-monitor-lib.sh" # lua_monitor_{active,disabled}()

# Audio sink names (PipeWire/ALSA)
AUDIO_TA10R="alsa_output.usb-xDuoo_USB_Audio_2.0_TA-10R-00.analog-stereo"
AUDIO_FIIO="alsa_output.usb-FiiO_DigiHug_USB_Audio-01.analog-stereo"
AUDIO_TV="alsa_output.pci-0000_09_00.1.hdmi-stereo"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Check TV EDID for scan behavior that causes overscan/underscan
# Logs a warning if the TV is configured to scan PC content incorrectly
check_tv_scan_behavior() {
  local edid_path="/sys/class/drm/card1-DP-1/edid"
  if [[ ! -f "$edid_path" ]]; then
    edid_path="/sys/class/drm/card0-DP-1/edid"
  fi

  if [[ ! -f "$edid_path" ]] || ! command -v edid-decode >/dev/null 2>&1; then
    return
  fi

  local scan_info
  scan_info=$(edid-decode "$edid_path" 2>/dev/null | grep -E "scan behavior|Overscan|Underscan")
  if [[ -n "$scan_info" ]]; then
    log "TV EDID scan behavior:"
    while IFS= read -r line; do
      log "  $line"
    done <<<"$scan_info"

    # Warn about common overscan issues
    if echo "$scan_info" | grep -qi "overscan"; then
      log "WARNING: TV reports overscan behavior. If edges are cut off,"
      log "  set TV to: Picture → Screen Format → Unscaled/Just Scan"
    fi
  fi
}

# Simple lock file (PID-based) to prevent concurrent execution
acquire_lock() {
  local max_age=30 # seconds

  if [[ -f "$LOCK_FILE" ]]; then
    local old_pid
    old_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      log "ERROR: Another instance is already running (PID: $old_pid)"
      exit 1
    fi
    log "WARNING: Stale lock file found, removing"
    rm -f "$LOCK_FILE"
  fi

  echo "$$" >"$LOCK_FILE"
}

release_lock() {
  rm -f "$LOCK_FILE"
}

# DPM performance level paths (card0 or card1 depending on GPU index)
DPM_FILE="/sys/class/drm/card1/device/power_dpm_force_performance_level"
CURRENT_FREQ_FILE="/sys/class/drm/card1/device/pp_dpm_mclk"
if [[ ! -f "$DPM_FILE" ]]; then
  DPM_FILE="/sys/class/drm/card0/device/power_dpm_force_performance_level"
  CURRENT_FREQ_FILE="/sys/class/drm/card0/device/pp_dpm_mclk"
fi

# Force GPU to high performance level to prevent clock transitions
# that destabilize the CH7218 adapter during mode switches.
# Requires display-dpm.sh sudoers rule for passwordless operation.
DPM_HELPER="$HOME/.local/bin/display-dpm.sh"

force_dpm_high() {
  if [[ -x "$DPM_HELPER" ]]; then
    if sudo -n "$DPM_HELPER" high 2>/dev/null; then
      log "DPM forced to high"
    else
      log "WARNING: DPM force failed (sudo not configured — see AGENTS.md)"
    fi
  fi
}

restore_dpm_auto() {
  if [[ -x "$DPM_HELPER" ]]; then
    sudo -n "$DPM_HELPER" auto 2>/dev/null || true
  fi
}

migrate_workspaces() {
  local from_monitor="$1"
  local to_monitor="$2"

  local workspaces
  workspaces=$(hyprctl workspaces -j 2>/dev/null)
  if [[ -z "$workspaces" ]]; then
    return
  fi

  local moved=0
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    hyprctl dispatch moveworkspacetomonitor "$id" "$to_monitor" >/dev/null 2>&1
    ((moved++))
  done < <(echo "$workspaces" | python3 -c "
import json, sys
try:
    for ws in json.load(sys.stdin):
        if ws.get('monitor') == '$from_monitor':
            print(ws.get('id'))
except Exception:
    pass
" 2>/dev/null)

  if ((moved > 0)); then
    log "Moved $moved workspace(s) from $from_monitor to $to_monitor"
  fi
}

log_clocks() {
  local label="${1:-}"
  [[ -n "$label" ]] && label=" ($label)"
  if [[ -f "$CURRENT_FREQ_FILE" ]]; then
    local cur
    cur=$(grep '*' "$CURRENT_FREQ_FILE" 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    log "GPU clock state${label}: MCLK=${cur:-unknown}"
  fi
  if [[ -f "$DPM_FILE" ]]; then
    log "DPM level: $(cat "$DPM_FILE" 2>/dev/null)"
  fi
}

active_monitor_count() {
  local monitors
  monitors=$(hyprctl monitors -j 2>/dev/null) || {
    echo 0
    return
  }

  echo "$monitors" | python3 -c "
import json, sys
try:
    print(sum(1 for monitor in json.load(sys.stdin) if not monitor.get('disabled')))
except Exception:
    print(0)
" 2>/dev/null
}

set_audio() {
  local sink_name="$1"
  local label="$2"
  local retry="${3:-0}"

  if ! command -v pactl >/dev/null 2>&1; then
    log "WARNING: pactl not available, skipping audio switch"
    return 1
  fi

  local waited=0
  while true; do
    if pactl list sinks short | grep -q "${sink_name}"; then
      pactl set-default-sink "${sink_name}" 2>/dev/null
      pactl suspend-sink "${sink_name}" 0 2>/dev/null
      log "Audio: ${label}"
      return 0
    fi
    if [[ "$waited" -ge "$retry" ]]; then
      log "WARNING: Audio sink not found: ${sink_name}"
      log "Available sinks:"
      pactl list sinks short 2>/dev/null | while IFS= read -r line; do
        log "  $line"
      done
      return 1
    fi
    log "Audio: waiting for sink ${sink_name}... ($waited/${retry}s)"
    sleep 1
    ((waited++))
  done
}

# Restart audio PCM device to force fresh audio SDPs after PCON FRL link stabilizes
restart_audio_sink() {
  local sink_name="$1"

  if ! command -v pactl >/dev/null 2>&1; then
    return
  fi

  if pactl list sinks short | grep -q "${sink_name}"; then
    log "Restarting audio stream for fresh PCON SDPs..."
    pactl suspend-sink "${sink_name}" 1 2>/dev/null
    sleep 2
    pactl suspend-sink "${sink_name}" 0 2>/dev/null
    log "Audio stream restarted"
  fi
}

# Fix CH7218 PCON DPCD registers for HDMI audio forwarding.
# The amdgpu driver never sets 0x3050 (HDMI mode) and drops Source CTL on 0x305A.
# This script sets both and polls for FRL link readiness.
# Requires root access to /dev/drm_dp_aux0.
fix_pcon_hdmi_mode() {
  local script_path="${SCRIPT_DIR}/fix-pcon-audio.py"

  if [[ ! -f "$script_path" ]]; then
    log "WARNING: fix-pcon-audio.py not found -- skipping PCON HDMI fix"
    return 1
  fi

  if [[ ! -e /dev/drm_dp_aux0 ]]; then
    log "WARNING: DPCD AUX device not found -- skipping PCON HDMI fix"
    return 1
  fi

  log "Fixing PCON HDMI mode for audio forwarding..."

  local output
  if [[ "$(id -u)" -eq 0 ]]; then
    output=$(python3 "$script_path" 2>&1)
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    output=$(sudo python3 "$script_path" 2>&1)
  else
    log "WARNING: Cannot fix PCON HDMI mode -- root required for DPCD access"
    log "Add to /etc/sudoers: filip ALL=(ALL) NOPASSWD: $script_path"
    return 1
  fi

  # Log script output
  while IFS= read -r line; do
    log "PCON: $line"
  done <<<"$output"

  return 0
}

# Check that the generated config is sourced (hyprlang) or required (Lua)
# from the main config file.
check_generated_config_sourced() {
  if [[ ! -f "$HYPR_CONFIG" ]]; then
    log "WARNING: $HYPR_CONFIG not found"
    return 1
  fi

  if ! grep -q "$CHECK_SOURCE_STRING" "$HYPR_CONFIG" 2>/dev/null; then
    log "WARNING: Generated config not sourced from $HYPR_CONFIG"
    log "Add this line to $HYPR_CONFIG:"
    log "  $SOURCE_LOG_LINE"
    return 1
  fi

  return 0
}

# Write monitor configuration to the generated config file.
# Format depends on $USE_LUA:
#   hyprlang (default): monitorv2 {} blocks, sourced from hyprland.conf
#   Lua (USE_LUA=1):    hl.monitor() calls, required from hyprland.lua
#
# CRITICAL (hyprlang mode): Never mix monitorv2 {} and monitor = lines
# for the same output — Hyprland 0.55 conflicts them.
write_monitor_config() {
  local mode="$1"

  # Create header with auto-generated warning
  if [[ "$USE_LUA" == "1" ]]; then
    cat >"$GENERATED_CONFIG" <<'HEADER'
-- AUTO-GENERATED by display_apply.sh
-- DO NOT EDIT MANUALLY — changes will be overwritten on next mode switch
-- Loaded via require("display-switcher-generated") from hyprland.lua

HEADER
  else
    cat >"$GENERATED_CONFIG" <<'HEADER'
# AUTO-GENERATED by display_apply.sh
# DO NOT EDIT MANUALLY — changes will be overwritten on next mode switch
# This file is sourced from hyprland.conf

HEADER
  fi

  # Shared monitor field definitions (used by both formats)
  local DP2_ACTIVE=("bitdepth = 10" "cm = srgb" "sdr_eotf = srgb" "sdrsaturation = 1.2")
  local DP1_HDR=(
    "bitdepth = 10"
    "cm = hdr"
    "sdrbrightness = 1.0"
    "sdrsaturation = 1.0"
    "sdr_min_luminance = 0.005"
    "sdr_max_luminance = 200"
    "min_luminance = 0"
    "max_luminance = 1400"
    "max_avg_luminance = 250"
    "supports_hdr = 1"
    "supports_wide_color = 1"
  )

  case "$mode" in
  monitor)
    if [[ "$USE_LUA" == "1" ]]; then
      cat >>"$GENERATED_CONFIG" <<EOF
-- Monitor mode: DP-2 only
EOF
      lua_monitor_active "DP-2" "${MONITOR_RES}" "0x0" "1" "${DP2_ACTIVE[@]}" >>"$GENERATED_CONFIG"
      lua_monitor_disabled "DP-1" >>"$GENERATED_CONFIG"
    else
      cat >>"$GENERATED_CONFIG" <<EOF
# Monitor mode: DP-2 only
monitorv2 {
    output = DP-2
    mode = ${MONITOR_RES}
    position = 0x0
    scale = 1
    bitdepth = 10
    cm = srgb
    sdr_eotf = srgb
    sdrsaturation = 1.2
}
monitorv2 {
    output = DP-1
    disabled = true
}
EOF
    fi
    ;;
  extend)
    if [[ "$USE_LUA" == "1" ]]; then
      cat >>"$GENERATED_CONFIG" <<EOF
-- Extend mode: DP-2 primary, DP-1 to the left
EOF
      lua_monitor_active "DP-2" "${MONITOR_RES}" "0x0" "1" "${DP2_ACTIVE[@]}" >>"$GENERATED_CONFIG"
      lua_monitor_active "DP-1" "${TV_RES}" "-2560x0" "${TV_SCALE}" "${DP1_HDR[@]}" >>"$GENERATED_CONFIG"
    else
      cat >>"$GENERATED_CONFIG" <<EOF
# Extend mode: DP-2 primary, DP-1 to the left
monitorv2 {
    output = DP-2
    mode = ${MONITOR_RES}
    position = 0x0
    scale = 1
    bitdepth = 10
    cm = srgb
    sdr_eotf = srgb
    sdrsaturation = 1.2
}
monitorv2 {
    output = DP-1
    mode = ${TV_RES}
    position = -2560x0
    scale = ${TV_SCALE}
    bitdepth = 10
    cm = hdr
    sdrbrightness = 1.0
    sdrsaturation = 1.0
    sdr_min_luminance = 0.005
    sdr_max_luminance = 200
    min_luminance = 0
    max_luminance = 1400
    max_avg_luminance = 250
    supports_hdr = 1
    supports_wide_color = 1
}
EOF
    fi
    ;;
  mirror)
    if [[ "$USE_LUA" == "1" ]]; then
      cat >>"$GENERATED_CONFIG" <<EOF
-- Mirror mode: DP-2 primary, DP-1 mirroring DP-2
EOF
      lua_monitor_active "DP-2" "${MONITOR_RES}" "0x0" "1" "${DP2_ACTIVE[@]}" >>"$GENERATED_CONFIG"
      lua_monitor_active "DP-1" "${TV_RES}" "auto" "${TV_SCALE}" "${DP1_HDR[@]}" "mirror = DP-2" >>"$GENERATED_CONFIG"
    else
      cat >>"$GENERATED_CONFIG" <<EOF
# Mirror mode: DP-2 primary, DP-1 mirroring DP-2
monitor = DP-2,${MONITOR_RES},0x0,1,bitdepth,10,cm,srgb
monitor = DP-1,${TV_RES},auto,${TV_SCALE},bitdepth,10,cm,${CM_HDR},mirror,DP-2
EOF
    fi
    ;;
  tv)
    if [[ "$USE_LUA" == "1" ]]; then
      cat >>"$GENERATED_CONFIG" <<EOF
-- TV mode: DP-1 only
EOF
      lua_monitor_active "DP-1" "${TV_RES}" "0x0" "${TV_SCALE}" "${DP1_HDR[@]}" >>"$GENERATED_CONFIG"
      lua_monitor_disabled "DP-2" >>"$GENERATED_CONFIG"
    else
      cat >>"$GENERATED_CONFIG" <<EOF
# TV mode: DP-1 only
monitorv2 {
    output = DP-1
    mode = ${TV_RES}
    position = 0x0
    scale = ${TV_SCALE}
    bitdepth = 10
    cm = hdr
    sdrbrightness = 1.0
    sdrsaturation = 1.0
    sdr_min_luminance = 0.005
    sdr_max_luminance = 200
    min_luminance = 0
    max_luminance = 1400
    max_avg_luminance = 250
    supports_hdr = 1
    supports_wide_color = 1
}
monitorv2 {
    output = DP-2
    disabled = true
}
EOF
    fi
    ;;
  monitor_only)
    if [[ "$USE_LUA" == "1" ]]; then
      cat >>"$GENERATED_CONFIG" <<EOF
-- Reset helper: DP-2 only
EOF
      lua_monitor_active "DP-2" "${MONITOR_RES}" "0x0" "1" "${DP2_ACTIVE[@]}" >>"$GENERATED_CONFIG"
      lua_monitor_disabled "DP-1" >>"$GENERATED_CONFIG"
    else
      cat >>"$GENERATED_CONFIG" <<EOF
# Reset helper: DP-2 only
monitorv2 {
    output = DP-2
    mode = ${MONITOR_RES}
    position = 0x0
    scale = 1
    bitdepth = 10
    cm = srgb
    sdr_eotf = srgb
    sdrsaturation = 1.2
}
monitorv2 {
    output = DP-1
    disabled = true
}
EOF
    fi
    ;;
  tv_only)
    if [[ "$USE_LUA" == "1" ]]; then
      cat >>"$GENERATED_CONFIG" <<EOF
-- Reset helper: DP-1 only
EOF
      lua_monitor_active "DP-1" "${TV_RES}" "0x0" "${TV_SCALE}" "${DP1_HDR[@]}" >>"$GENERATED_CONFIG"
      lua_monitor_disabled "DP-2" >>"$GENERATED_CONFIG"
    else
      cat >>"$GENERATED_CONFIG" <<EOF
# Reset helper: DP-1 only
monitorv2 {
    output = DP-1
    mode = ${TV_RES}
    position = 0x0
    scale = ${TV_SCALE}
    bitdepth = 10
    cm = hdr
    sdrbrightness = 1.0
    sdrsaturation = 1.0
    sdr_min_luminance = 0.005
    sdr_max_luminance = 200
    min_luminance = 0
    max_luminance = 1400
    max_avg_luminance = 250
    supports_hdr = 1
    supports_wide_color = 1
}
monitorv2 {
    output = DP-2
    disabled = true
}
EOF
    fi
    ;;
  *)
    log "ERROR: Unknown mode in write_monitor_config: $mode"
    return 1
    ;;
  esac

  log "Generated monitor config for mode: $mode (format: ${GENERATED_EXT})"
}

# Trigger DP encoder reconfiguration by toggling a display parameter.
# This forces amdgpu to re-read PCON DPCD state and reconfigure audio SDP generation.
# NOTE: Uses hyprctl keyword monitor directly; include bitdepth/cm because
# omitted values fall back to 8-bit SDR defaults.
reconfigure_dp_encoder() {
  local display="$1"
  local res="$2"
  local pos="$3"
  local scale="$4"

  log "Reconfiguring DP encoder for audio SDP generation..."
  if (($(active_monitor_count) > 1)); then
    # Safe to toggle: disable then re-enable forces DP encoder reconfig
    hyprctl keyword monitor "${display},disable" 2>/dev/null || true
    sleep 1
    hyprctl keyword monitor "${display},${res},${pos},${scale},${TV_HDR_OPTIONS}" 2>/dev/null || true
    sleep 2
    log "DP encoder reconfigured via keyword toggle"
  else
    log "Only one active monitor — reloading to trigger encoder reconfig"
  fi
}

# Verify monitors match expected mode using text output (same as Python)
is_tv_active() {
  local check_format="${1:-false}"
  local output
  output=$(hyprctl monitors all 2>/dev/null)

  local in_dp1=false
  local dp1_disabled="true"
  local dp1_format=""

  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//')
    if [[ "$line" == Monitor\ DP-1* ]]; then
      in_dp1=true
      dp1_disabled="false"
    elif [[ "$line" == Monitor* ]]; then
      # Hit a different monitor, stop processing DP-1
      in_dp1=false
    elif [[ "$in_dp1" == true ]] && [[ "$line" == disabled:* ]]; then
      local val
      val=$(echo "$line" | awk -F': ' '{print $2}')
      if [[ "$val" == "true" ]]; then
        dp1_disabled="true"
      fi
    elif [[ "$in_dp1" == true ]] && [[ "$line" == currentFormat:* ]]; then
      dp1_format=$(echo "$line" | awk -F': ' '{print $2}')
    fi
  done <<<"$output"

  if [[ "$dp1_disabled" == "false" ]]; then
    # For 10-bit modes, verify format is actually 10-bit
    if [[ "$check_format" == "true" ]] && [[ "$BITDEPTH" == "10" ]]; then
      if [[ "$dp1_format" != "XRGB2101010" && "$dp1_format" != "XBGR2101010" && "$dp1_format" != "ARGB2101010" ]]; then
        log "WARNING: TV active but format is $dp1_format (expected 10-bit)"
        return 1
      fi
    fi
    return 0
  fi
  return 1
}

verify_mode() {
  local expected="$1"
  local output
  output=$(hyprctl monitors all 2>/dev/null)

  local -A monitors
  local current_name=""

  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//')

    if [[ "$line" == Monitor* ]]; then
      current_name=$(echo "$line" | awk '{print $2}')
      monitors[$current_name,"disabled"]="false"
      monitors[$current_name,"mirror"]="none"
      monitors[$current_name,"cm"]="srgb"
    elif [[ "$line" == disabled:* ]] && [[ -n "$current_name" ]]; then
      local val
      val=$(echo "$line" | awk -F': ' '{print $2}')
      monitors[$current_name,"disabled"]="$val"
    elif [[ "$line" == mirrorOf:* ]] && [[ -n "$current_name" ]]; then
      local val
      val=$(echo "$line" | awk -F': ' '{print $2}')
      monitors[$current_name,"mirror"]="$val"
    elif [[ "$line" == colorManagementPreset:* ]] && [[ -n "$current_name" ]]; then
      local val
      val=$(echo "$line" | awk -F': ' '{print $2}')
      monitors[$current_name,"cm"]="$val"
    fi
  done <<<"$output"

  local dp2_enabled=false
  local dp1_enabled=false
  local dp1_mirror="none"
  local dp1_cm="srgb"

  if [[ "${monitors[DP-2,"disabled"]:-true}" == "false" ]]; then
    dp2_enabled=true
  fi
  if [[ "${monitors[DP-1,"disabled"]:-true}" == "false" ]]; then
    dp1_enabled=true
    dp1_mirror="${monitors[DP-1,"mirror"]:-none}"
    dp1_cm="${monitors[DP-1,"cm"]:-srgb}"
  fi

  case "$expected" in
  monitor)
    [[ "$dp2_enabled" == true && "$dp1_enabled" == false ]]
    ;;
  extend)
    [[ "$dp2_enabled" == true && "$dp1_enabled" == true && "$dp1_mirror" != "DP-2" && "$dp1_cm" == "$CM_HDR" ]] && is_tv_active "true"
    ;;
  mirror)
    [[ "$dp2_enabled" == true && "$dp1_enabled" == true && "$dp1_mirror" == "DP-2" ]]
    ;;
  tv)
    [[ "$dp2_enabled" == false && "$dp1_enabled" == true && "$dp1_cm" == "$CM_HDR" ]] && is_tv_active "true"
    ;;
  *)
    return 1
    ;;
  esac
}

apply_mode() {
  local mode="$1"
  log "Applying mode: $mode (reload-based config)"

  log_clocks "before switch"
  force_dpm_high

  # Ensure generated config is sourced (warn but don't fail)
  check_generated_config_sourced || true

  # Write the monitor configuration for the desired mode
  if ! write_monitor_config "$mode"; then
    log "ERROR: Failed to write monitor config"
    exit 1
  fi

  # Kill layer-shell clients before reload to prevent
  # CInputManager::refocusLastWindow SIGABRT during monitor teardown.
  # Hyprland #14555 claimed fixed in 0.55.2 but still crashes.
  pkill -x dunst 2>/dev/null || true
  pkill -x swaync 2>/dev/null || true
  pkill -x swww-daemon 2>/dev/null || true

  # Apply via reload — atomic, no zero-monitor risk, preserves monitorv2 settings
  # Toggle global HDR signaling — prefer_hdr tells Hyprland to advertise HDR
  # support to Wayland clients. Must only be enabled when the TV is active,
  # otherwise browsers like Helium apply HDR transfer functions to SDR content.
  case "$mode" in
  monitor|monitor_only)
    hyprctl keyword quirks:prefer_hdr 0
    log "HDR signaling disabled (SDR monitor mode)"
    ;;
  *)
    hyprctl keyword quirks:prefer_hdr 1
    log "HDR signaling enabled (TV active)"
    ;;
  esac
  log "Applying monitor config via reload..."
  hyprctl reload
  sleep 6 # Wait for FRL link training and DSC negotiation

  # Force compositor repaint after monitor reconfiguration.
  # Without this, Hyprland sometimes renders panels but not workspace
  # content (solitaryBlockedBy: missing candidate — compositor desync).
  hyprctl dispatch focusmonitor "${MONITOR}" 2>/dev/null || true
  sleep 0.2

  # Verify with retry logic
  local verify_ok=false
  if verify_mode "$mode"; then
    verify_ok=true
  else
    log "Initial reload failed verification, retrying with reset..."
    # Retry: disable problematic display, reload, re-enable
    local reset_mode="monitor_only"
    if [[ "$mode" == "tv" ]]; then
      reset_mode="monitor_only" # Reset to DP-2 only
    elif [[ "$mode" == "monitor" ]]; then
      reset_mode="tv_only" # Reset to DP-1 only
    else
      reset_mode="monitor_only" # Default reset
    fi

    write_monitor_config "$reset_mode"
    pkill -x dunst 2>/dev/null || true
    pkill -x swaync 2>/dev/null || true
    pkill -x swww-daemon 2>/dev/null || true
    hyprctl reload
    sleep 2

    write_monitor_config "$mode"
    pkill -x dunst 2>/dev/null || true
    pkill -x swaync 2>/dev/null || true
    pkill -x swww-daemon 2>/dev/null || true
    hyprctl reload
    sleep 6

    hyprctl dispatch focusmonitor "${MONITOR}" 2>/dev/null || true
    sleep 0.2

    if verify_mode "$mode"; then
      verify_ok=true
      log "Mode verified after retry"
    fi
  fi

  # Mode-specific post-processing (audio, PCON fix, etc.)
  case "$mode" in
  monitor)
    migrate_workspaces "$TV" "$MONITOR"
    set_audio "$AUDIO_TA10R" "TA-10R (headphones)"
    ;;
  extend | mirror)
    set_audio "$AUDIO_FIIO" "FiiO E10 (desktop)"
    ;;
  tv)
    if [[ "$verify_ok" == true ]]; then
      migrate_workspaces "$MONITOR" "$TV"
      check_tv_scan_behavior

      # Try PCON DPCD fix first (needs sudo)
      local pcon_fixed=false
      if fix_pcon_hdmi_mode; then
        pcon_fixed=true
        log "PCON HDMI mode fixed successfully"
      else
        log "PCON fix failed, using DP encoder reconfigure fallback"
      fi

      # If PCON fix didn't work, force DP encoder reconfig
      if [[ "$pcon_fixed" != true ]]; then
        reconfigure_dp_encoder "$TV" "$TV_RES" "0x0" "$TV_SCALE"
        # reconfigure_dp_encoder uses hyprctl keyword monitor which wipes
        # monitorv2 settings. Reload to restore sdr_min_luminance etc.
        hyprctl reload
        sleep 2
        hyprctl dispatch focusmonitor "${TV}" 2>/dev/null || true
      fi

      # Wait for HDMI audio sink to appear after display reconfig
      log "Waiting for HDMI audio sink to initialize..."
      sleep 5

      set_audio "$AUDIO_TV" "TV HDMI (Philips)" 20
      restart_audio_sink "$AUDIO_TV"
    fi
    ;;
  esac

  # Wait for compositor and adapter to fully settle
  sleep 0.5

  log_clocks "after mode applied"
  restore_dpm_auto

  # Final verification
  if [[ "$verify_ok" == true ]]; then
    log "SUCCESS: Mode $mode verified"

    # Restart layer-shell daemons killed before reload.
    hyprctl dispatch exec swww-daemon 2>/dev/null || true
    hyprctl dispatch exec dunst 2>/dev/null || true

    exit 0
  else
    log_clocks "after verify fail"
    log "ERROR: Mode verification failed for $mode"
    log_video_metadata "VERIFY_FAILED"
    exit 1
  fi
}

# Main
mkdir -p "$(dirname "$LOG_FILE")"
acquire_lock
trap release_lock EXIT
apply_mode "$MODE"
