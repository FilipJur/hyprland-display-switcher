#!/bin/bash
# display_apply.sh - MVP display mode applier with verification
# Zero state, 8-bit default, logs to stdout/stderr

set -uo pipefail

MODE="${1:-monitor}"
LOG_FILE="$HOME/.local/state/display-switcher.log"
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

# Verify monitors match expected mode
verify_mode() {
    local expected="$1"
    local output
    output=$(hyprctl monitors -j 2>/dev/null)
    
    local dp2_enabled=false
    local dp1_enabled=false
    local dp1_mirror="none"
    
    # Parse JSON output
    if echo "$output" | grep -q '"name": "DP-2"'; then
        dp2_enabled=true
    fi
    if echo "$output" | grep -q '"name": "DP-1"'; then
        dp1_enabled=true
        # Check mirror status from full output
        if echo "$output" | grep -A 20 '"name": "DP-1"' | grep -q '"mirrorOf": "DP-2"'; then
            dp1_mirror="DP-2"
        fi
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
            hyprctl keyword monitor "${TV},${TV_RES},-2560x0,${TV_SCALE},bitdepth,${BITDEPTH}"
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
        exit 0
    else
        log "ERROR: Mode verification failed for $mode"
        exit 1
    fi
}

# Main
mkdir -p "$(dirname "$LOG_FILE")"
apply_mode "$MODE"
