#!/bin/bash
# display_apply.sh - MVP display mode applier with verification
# Zero state, 8-bit default, logs to stdout/stderr

set -uo pipefail

MODE="${1:-monitor}"
LOG_FILE="$HOME/.local/state/display-switcher.log"
LOCK_FILE="$HOME/.local/state/display-apply.lock"
FORCE_8BIT="${DISPLAY_SWITCHER_8BIT:-1}"  # Default 8-bit for stability

# Monitor config
MONITOR="DP-2"
TV="DP-1"
MONITOR_RES="3440x1440@74.98"
TV_RES="3840x2160@120"
TV_SCALE="1.0"

# Bit depth
if [[ "$FORCE_8BIT" == "1" ]]; then
    BITDEPTH="8"
else
    BITDEPTH="10"
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
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

# Verify monitors match expected mode using text output (same as Python)
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
        elif [[ "$line" == disabled:* ]] && [[ -n "$current_name" ]]; then
            local val
            val=$(echo "$line" | awk -F': ' '{print $2}')
            monitors[$current_name,"disabled"]="$val"
        elif [[ "$line" == mirrorOf:* ]] && [[ -n "$current_name" ]]; then
            local val
            val=$(echo "$line" | awk -F': ' '{print $2}')
            monitors[$current_name,"mirror"]="$val"
        fi
    done <<< "$output"
    
    local dp2_enabled=false
    local dp1_enabled=false
    local dp1_mirror="none"
    
    if [[ "${monitors[DP-2,"disabled"]:-true}" == "false" ]]; then
        dp2_enabled=true
    fi
    if [[ "${monitors[DP-1,"disabled"]:-true}" == "false" ]]; then
        dp1_enabled=true
        dp1_mirror="${monitors[DP-1,"mirror"]:-none}"
    fi
    
    case "$expected" in
        monitor)
            [[ "$dp2_enabled" == true && "$dp1_enabled" == false ]]
            ;;
        extend)
            [[ "$dp2_enabled" == true && "$dp1_enabled" == true && "$dp1_mirror" != "DP-2" ]]
            ;;
        mirror)
            [[ "$dp2_enabled" == true && "$dp1_enabled" == true && "$dp1_mirror" == "DP-2" ]]
            ;;
        tv)
            [[ "$dp2_enabled" == false && "$dp1_enabled" == true ]]
            ;;
        *)
            return 1
            ;;
    esac
}

apply_mode() {
    local mode="$1"
    log "Applying mode: $mode (bitdepth: $BITDEPTH)"
    
    case "$mode" in
        monitor)
            hyprctl keyword monitor "${TV},disable" 2>/dev/null || true
            hyprctl keyword monitor "${MONITOR},${MONITOR_RES},0x0,1"
            ;;
        extend)
            hyprctl keyword monitor "${MONITOR},${MONITOR_RES},0x0,1"
            hyprctl keyword monitor "${TV},${TV_RES},-3840x0,${TV_SCALE},bitdepth,${BITDEPTH}"
            ;;
        mirror)
            hyprctl keyword monitor "${MONITOR},${MONITOR_RES},0x0,1"
            hyprctl keyword monitor "${TV},${TV_RES},auto,${TV_SCALE},bitdepth,${BITDEPTH},mirror,${MONITOR}"
            ;;
        tv)
            hyprctl keyword monitor "${MONITOR},disable" 2>/dev/null || true
            hyprctl keyword monitor "${TV},${TV_RES},0x0,${TV_SCALE},bitdepth,${BITDEPTH}"
            ;;
        *)
            log "ERROR: Unknown mode: $mode"
            exit 1
            ;;
    esac
    
    # Wait for compositor
    sleep 0.5
    
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
        log "ERROR: Mode verification failed for $mode"
        exit 1
    fi
}

# Main
mkdir -p "$(dirname "$LOG_FILE")"
acquire_lock
trap release_lock EXIT
apply_mode "$MODE"
