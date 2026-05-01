#!/bin/bash
# display-dpm.sh - Force GPU DPM level for display adapter stability
set -euo pipefail

LEVEL="${1:-}"
[[ "$LEVEL" != "high" && "$LEVEL" != "auto" ]] && { echo "Usage: $0 {high|auto}"; exit 1; }

for card in card0 card1; do
    f="/sys/class/drm/$card/device/power_dpm_force_performance_level"
    [[ -f "$f" ]] || continue
    current=$(cat "$f" 2>/dev/null)
    if [[ "$current" != "$LEVEL" ]]; then
        echo "$LEVEL" > "$f"
    fi
done
