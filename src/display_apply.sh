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
LOG_FILE="$HOME/.local/state/display-switcher.log"
LOCK_FILE="$HOME/.local/state/display-apply.lock"
# Monitor config
MONITOR="DP-2"
TV="DP-1"
MONITOR_RES="3440x1440@74.98"
TV_RES="3840x2160@120"
TV_SCALE="1.5"
BITDEPTH="10"

# IMPORTANT: Color management (bitdepth, cm, sdrbrightness, sdr_min_luminance)
# is now handled by monitorv2 {} blocks in ~/.config/hypr/hyprland.conf.
# This script only handles monitor enable/disable/layout.
# See the monitorv2 example in the README or project docs.
#
# Reference values for monitorv2 config:
#   DP-1 (TV):  cm=hdr, bitdepth=10, sdr_min_luminance=0.005
#   DP-2 (Main): cm=dcip3, bitdepth=10

# Color management presets (used by verify_mode() only)
CM_SDR="srgb"
CM_HDR="hdr"

# Legacy tuning values (for reference, configure in monitorv2 {})
SDR_MIN_LUMINANCE="0.005"
SDR_MAX_LUMINANCE="400"

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
        done <<< "$scan_info"
        
        # Warn about common overscan issues
        if echo "$scan_info" | grep -qi "overscan"; then
            log "WARNING: TV reports overscan behavior. If edges are cut off,"
            log "  set TV to: Picture → Screen Format → Unscaled/Just Scan"
        fi
    fi
}

# Simple lock file (PID-based) to prevent concurrent execution
acquire_lock() {
    local max_age=30  # seconds
    
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
    
    echo "$$" > "$LOCK_FILE"
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
    done <<< "$output"
    
    return 0
}

# Trigger DP encoder reconfiguration by toggling a display parameter.
# This forces amdgpu to re-read PCON DPCD state and reconfigure audio SDP generation.
# NOTE: Color/bitdepth settings are handled by monitorv2 {} in hyprland.conf.
reconfigure_dp_encoder() {
    local display="$1"
    local res="$2"
    local pos="$3"
    local scale="$4"
    
    log "Reconfiguring DP encoder for audio SDP generation..."
    # Toggle resolution temporarily to force a mode set
    # bitdepth and cm required here too — hyprctl keyword monitor overrides
    # monitorv2 settings and defaults to 8-bit without them.
    hyprctl keyword monitor "${display},disable" 2>/dev/null || true
    sleep 1
    hyprctl keyword monitor "${display},${res},${pos},${scale},bitdepth,10,cm,hdr" 2>/dev/null || true
    sleep 2
    log "DP encoder reconfigured"
}

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
            log "  EDID file exists: $edid_path ($(wc -c < "$edid_path") bytes)"
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
    done <<< "$output"
    
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

enable_tv() {
    local position="$1"
    local mirror_target="$2"

    # Disable first to force clean DSC re-handshake
    log "Disabling ${TV} for clean reset..."
    hyprctl keyword monitor "${TV},disable" 2>/dev/null || true
    sleep 2

    # Build the monitor config string
    # NOTE: bitdepth and cm are required here because hyprctl keyword monitor
    # overrides monitorv2 {} settings and reverts to defaults for unspecified params.
    # Without bitdepth,10 the adapter falls back to 8-bit (XRGB8888), failing verification.
    # sdrbrightness and sdrsaturation removed to avoid Hyprland SIGABRT (issue #9716).
    # sdr_min_luminance, sdr_max_luminance handled by monitorv2 {} only (not supported inline).
    local tv_config="${TV},${TV_RES},${position},${TV_SCALE},bitdepth,10,cm,hdr"

    if [[ -n "$mirror_target" ]]; then
        tv_config+=",mirror,${mirror_target}"
    fi

    log "Enabling ${TV}: ${tv_config}"
    hyprctl keyword monitor "${tv_config}"

    # Wait for adapter to settle (DSC + FRL link training)
    local settle_time=6
    log "Waiting ${settle_time}s for adapter stabilization..."
    sleep "$settle_time"

    # Verify TV is actually active (check format for 10-bit modes)
    if is_tv_active "true"; then
        log "TV enabled successfully (format verified)"
        return 0
    fi

    # Retry once
    log "TV not active or wrong format, retrying..."
    hyprctl keyword monitor "${TV},disable" 2>/dev/null || true
    sleep 2
    hyprctl keyword monitor "${tv_config}"
    sleep "$settle_time"

    if is_tv_active "true"; then
        log "TV enabled successfully on retry"
        return 0
    fi

    log "ERROR: Failed to enable TV after retry"
    log_video_metadata "TV_ENABLE_FAILED"
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
    done <<< "$output"

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
            [[ "$dp2_enabled" == true && "$dp1_enabled" == true && "$dp1_mirror" != "DP-2" && "$dp1_cm" == "$CM_HDR" ]]
            ;;
        mirror)
            [[ "$dp2_enabled" == true && "$dp1_enabled" == true && "$dp1_mirror" == "DP-2" ]]
            ;;
        tv)
            [[ "$dp2_enabled" == false && "$dp1_enabled" == true && "$dp1_cm" == "$CM_HDR" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

apply_mode() {
    local mode="$1"
    log "Applying mode: $mode (color managed by monitorv2)"
    
    log_clocks "before switch"
    force_dpm_high
    
    case "$mode" in
        monitor)
            # Enable target monitor FIRST, then disable old one
            # Prevents zero-monitor state which crashes Hyprland
            # NOTE: Color management is handled by monitorv2 {} in hyprland.conf
            hyprctl keyword monitor "${MONITOR},${MONITOR_RES},0x0,1"
            sleep 0.3
            hyprctl keyword monitor "${TV},disable" 2>/dev/null || true
            set_audio "$AUDIO_TA10R" "TA-10R (headphones)"
            ;;
        extend)
            # NOTE: Color management is handled by monitorv2 {} in hyprland.conf
            hyprctl keyword monitor "${MONITOR},${MONITOR_RES},0x0,1"
            # Position: -2560x0 = TV logical width (3840/1.5) to the left, no gap
            if ! enable_tv "-2560x0" ""; then
                log_clocks "after extend fail"
                log "ERROR: Failed to enable TV in extend mode"
                exit 1
            fi
            set_audio "$AUDIO_FIIO" "FiiO E10 (desktop)"
            ;;
        mirror)
            # NOTE: Color management is handled by monitorv2 {} in hyprland.conf
            hyprctl keyword monitor "${MONITOR},${MONITOR_RES},0x0,1"
            if ! enable_tv "auto" "${MONITOR}"; then
                log_clocks "after mirror fail"
                log "ERROR: Failed to enable TV in mirror mode"
                exit 1
            fi
            set_audio "$AUDIO_FIIO" "FiiO E10 (desktop)"
            ;;
        tv)
            # Enable target monitor FIRST, then disable old one
            # Prevents zero-monitor state which crashes Hyprland
            check_tv_scan_behavior
            if ! enable_tv "0x0" ""; then
                log_clocks "after tv fail"
                log "ERROR: Failed to enable TV in tv mode"
                exit 1
            fi
            sleep 0.3
            hyprctl keyword monitor "${MONITOR},disable" 2>/dev/null || true
            
            # Fix PCON HDMI mode so the CH7218 forwards audio.
            # The amdgpu driver leaves 0x3050=0x00 (DVI, no audio) and drops
            # Source CTL on 0x305A, preventing FRL link training completion.
            fix_pcon_hdmi_mode
            
            # Force DP encoder reconfiguration so amdgpu re-reads the corrected
            # PCON state and enables audio SDP generation for HDMI mode.
            reconfigure_dp_encoder "$TV" "$TV_RES" "0x0" "$TV_SCALE"
            
            set_audio "$AUDIO_TV" "TV HDMI (Philips)" 10
            restart_audio_sink "$AUDIO_TV"
            ;;
        *)
            log "ERROR: Unknown mode: $mode"
            exit 1
            ;;
    esac
    
    # Wait for compositor and adapter to fully settle
    sleep 0.5
    
    log_clocks "after mode applied"
    restore_dpm_auto
    
    # Verify
    if verify_mode "$mode"; then
        log "SUCCESS: Mode $mode verified"
        
        # Check if waybar died during monitor transition
        if ! pgrep -x waybar > /dev/null 2>&1; then
            log "WARNING: Waybar not running after mode switch, restarting..."
            waybar &
            log "Waybar restarted (PID: $!)"
        fi
        
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
