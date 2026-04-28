#!/bin/bash
# display-apply.sh - Apply display configuration modes for Hyprland

set -euo pipefail

# Mode state file
STATE_FILE="$HOME/.local/state/display-mode"
NOTIFY_APP="Display Switcher"

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
    local urgency="${2:-normal}"
    notify-send -a "$NOTIFY_APP" -u "$urgency" "$1"
}

# Apply monitor configuration
apply_mode() {
    local mode="$1"
    local current_mode
    current_mode=$(get_current_mode)
    
    # Don't reapply same mode
    if [[ "$mode" == "$current_mode" ]]; then
        notify "Already in $mode mode" "low"
        return 0
    fi
    
    # Notify user
    notify "Switching to $mode mode..."
    
    # Small delay for visual feedback
    sleep 1
    
    case "$mode" in
        monitor)
            # Disable HDMI-A-1, enable DP-2
            hyprctl keyword monitor "HDMI-A-1,disable" > /dev/null 2>&1 || true
            hyprctl keyword monitor "DP-2,preferred,auto,1" > /dev/null 2>&1 || true
            ;;
        
        extend)
            # Enable both: DP-2 primary, HDMI-A-1 to the left
            hyprctl keyword monitor "DP-2,preferred,auto,1" > /dev/null 2>&1 || true
            hyprctl keyword monitor "HDMI-A-1,preferred,-1920x0,1" > /dev/null 2>&1 || true
            ;;
        
        mirror)
            # Mirror DP-2 to HDMI-A-1
            hyprctl keyword monitor "DP-2,preferred,auto,1" > /dev/null 2>&1 || true
            hyprctl keyword monitor "HDMI-A-1,preferred,auto,1,mirror,DP-2" > /dev/null 2>&1 || true
            ;;
        
        tv)
            # Disable DP-2, enable HDMI-A-1
            hyprctl keyword monitor "DP-2,disable" > /dev/null 2>&1 || true
            hyprctl keyword monitor "HDMI-A-1,preferred,auto,1" > /dev/null 2>&1 || true
            ;;
        
        *)
            notify "Unknown mode: $mode" "critical"
            return 1
            ;;
    esac
    
    # Save state
    save_mode "$mode"
    
    # Confirm notification
    notify "Display mode: $mode"
    
    # Restart waybar to adapt to new monitor configuration
    restart_waybar
}

# Restart waybar
restart_waybar() {
    # Try graceful reload first
    if pgrep -x waybar > /dev/null 2>&1; then
        killall -SIGUSR2 waybar > /dev/null 2>&1 || true
        sleep 0.5
        
        # Check if waybar is still running
        if ! pgrep -x waybar > /dev/null 2>&1; then
            # Restart if it crashed or didn't reload
            (sleep 1 && waybar &)
        fi
    else
        # Start waybar if not running
        waybar &
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
