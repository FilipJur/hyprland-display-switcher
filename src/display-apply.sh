#!/bin/bash
# display-apply.sh - Apply display configuration modes for Hyprland
# Uses exact resolutions from user's monitors.conf

set -uo pipefail

# Mode state file
STATE_FILE="$HOME/.local/state/display-mode"
NOTIFY_APP="Display Switcher"
LOG_FILE="$HOME/.local/state/display-switcher.log"

# Monitor definitions (exact from user's display-toggle.sh)
MONITOR="DP-2"
TV="HDMI-A-1"
MONITOR_RES="3440x1440@74.98"
TV_RES="3840x2160@120"
TV_SCALE="1.5"

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Get current mode
get_current_mode() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "monitor"
    fi
}

# Save current mode
save_mode() {
    local mode="$1"
    mkdir -p "$(dirname "$STATE_FILE")"
    echo "$mode" > "$STATE_FILE"
}

# Send notification
notify() {
    local msg="$1"
    local urgency="${2:-normal}"
    notify-send -a "$NOTIFY_APP" -u "$urgency" "$msg" 2>> "$LOG_FILE" || true
}

# Migrate workspaces from one monitor to another before disabling
migrate_workspaces() {
    local from_monitor="$1"
    local to_monitor="$2"
    
    log "Migrating workspaces from $from_monitor to $to_monitor"
    
    # Check if jq is available
    if ! command -v jq > /dev/null 2>&1; then
        log "Warning: jq not found, skipping workspace migration"
        return 0
    fi
    
    # Get workspaces on the source monitor and move them
    local workspaces
    workspaces=$(hyprctl workspaces -j 2>> "$LOG_FILE" | jq -r ".[] | select(.monitor == \"$from_monitor\") | .id" 2>> "$LOG_FILE")
    
    if [[ -n "$workspaces" ]]; then
        while IFS= read -r ws_id; do
            if [[ -n "$ws_id" ]]; then
                log "Moving workspace $ws_id from $from_monitor to $to_monitor"
                hyprctl dispatch moveworkspacetomonitor "$ws_id" "$to_monitor" >> "$LOG_FILE" 2>&1 || true
            fi
        done <<< "$workspaces"
    fi
}

# Apply monitor configuration
apply_mode() {
    local mode="$1"
    local current_mode
    current_mode=$(get_current_mode)
    
    log "Applying mode: $mode (current: $current_mode)"
    
    # Don't reapply same mode
    if [[ "$mode" == "$current_mode" ]]; then
        log "Already in $mode mode, skipping"
        notify "Already in $mode mode" "low"
        return 0
    fi
    
    # Notify user
    notify "Switching to $mode mode..."
    
    # Small delay for visual feedback
    sleep 1
    
    case "$mode" in
        monitor)
            # Migrate workspaces from TV to monitor before disabling
            migrate_workspaces "$TV" "$MONITOR"
            
            # Disable TV, enable monitor with exact resolution
            log "Disabling $TV, enabling $MONITOR"
            hyprctl keyword monitor "${TV},disable" >> "$LOG_FILE" 2>&1 || {
                log "Error: Failed to disable $TV"
                notify "Failed to disable TV" "critical"
                return 1
            }
            hyprctl keyword monitor "${MONITOR},${MONITOR_RES},0x0,1" >> "$LOG_FILE" 2>&1 || {
                log "Error: Failed to enable $MONITOR"
                notify "Failed to enable monitor" "critical"
                return 1
            }
            ;;
        
        extend)
            # Enable both with exact resolutions and positioning
            log "Enabling extended mode: $MONITOR + $TV"
            hyprctl keyword monitor "${MONITOR},${MONITOR_RES},0x0,1" >> "$LOG_FILE" 2>&1 || {
                log "Error: Failed to configure $MONITOR"
                notify "Failed to configure monitor" "critical"
                return 1
            }
            hyprctl keyword monitor "${TV},${TV_RES},-2560x0,${TV_SCALE},bitdepth,10" >> "$LOG_FILE" 2>&1 || {
                log "Error: Failed to configure $TV"
                notify "Failed to configure TV" "critical"
                return 1
            }
            ;;
        
        mirror)
            # Enable monitor, mirror to TV with exact resolutions
            log "Enabling mirror mode: $MONITOR -> $TV"
            hyprctl keyword monitor "${MONITOR},${MONITOR_RES},0x0,1" >> "$LOG_FILE" 2>&1 || {
                log "Error: Failed to configure $MONITOR"
                notify "Failed to configure monitor" "critical"
                return 1
            }
            hyprctl keyword monitor "${TV},${TV_RES},auto,${TV_SCALE},bitdepth,10,mirror,${MONITOR}" >> "$LOG_FILE" 2>&1 || {
                log "Error: Failed to mirror $TV"
                notify "Failed to mirror TV" "critical"
                return 1
            }
            ;;
        
        tv)
            # Migrate workspaces from monitor to TV before disabling
            migrate_workspaces "$MONITOR" "$TV"
            
            # Disable monitor, enable TV with exact resolution
            log "Disabling $MONITOR, enabling $TV"
            hyprctl keyword monitor "${MONITOR},disable" >> "$LOG_FILE" 2>&1 || {
                log "Error: Failed to disable $MONITOR"
                notify "Failed to disable monitor" "critical"
                return 1
            }
            hyprctl keyword monitor "${TV},${TV_RES},0x0,${TV_SCALE},bitdepth,10" >> "$LOG_FILE" 2>&1 || {
                log "Error: Failed to enable $TV"
                notify "Failed to enable TV" "critical"
                return 1
            }
            ;;
        
        *)
            log "Error: Unknown mode: $mode"
            notify "Unknown mode: $mode" "critical"
            return 1
            ;;
    esac
    
    # Save state
    save_mode "$mode"
    log "Mode saved: $mode"
    
    # Confirm notification
    notify "Display mode: $mode"
    
    # Restart waybar to adapt to new monitor configuration
    restart_waybar
}

# Restart waybar
restart_waybar() {
    log "Restarting waybar..."
    
    if pgrep -x waybar > /dev/null 2>&1; then
        # Try graceful reload first (SIGUSR2)
        log "Sending SIGUSR2 to waybar"
        if killall -SIGUSR2 waybar >> "$LOG_FILE" 2>&1; then
            sleep 1
            
            # Check if waybar is still running after reload
            if pgrep -x waybar > /dev/null 2>&1; then
                log "Waybar reloaded successfully"
                return 0
            else
                log "Waybar crashed after reload, restarting..."
            fi
        else
            log "SIGUSR2 reload failed, trying full restart..."
        fi
        
        # Fallback: kill and restart
        log "Killing waybar"
        killall waybar >> "$LOG_FILE" 2>&1 || true
        sleep 0.5
        
        log "Starting waybar"
        waybar >> "$LOG_FILE" 2>&1 &
    else
        # Start waybar if not running
        log "Waybar not running, starting..."
        waybar >> "$LOG_FILE" 2>&1 &
    fi
}

# Main
main() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <mode>"
        echo "Modes: monitor, extend, mirror, tv"
        exit 1
    fi
    
    local mode="$1"
    
    # Validate mode
    case "$mode" in
        monitor|extend|mirror|tv)
            apply_mode "$mode"
            ;;
        *)
            echo "Invalid mode: $mode"
            echo "Valid modes: monitor, extend, mirror, tv"
            exit 1
            ;;
    esac
}

main "$@"
