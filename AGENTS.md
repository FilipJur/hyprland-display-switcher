# Hyprland Display Switcher

A hardware-aware display mode toggle for Hyprland with GTK3 overlay UI.

## Project Overview

This project provides a Windows+P-style display switching interface for Hyprland on Linux. It allows cycling between monitor configurations (single, extend, mirror, TV-only) via a keyboard-driven overlay with persistent notifications.

## Components

| File | Purpose |
|------|---------|
| `src/display-switcher.py` | GTK3 overlay application with layer-shell support |
| `src/display-apply.sh` | Bash script that applies monitor configurations via hyprctl |
| `config/display-switcher.css` | Another World theme styling for the overlay |
| `install.sh` | Installation script |

## Keybindings

- **Super+O**: Open display switcher / cycle to next mode
- **Enter**: Confirm selection
- **Escape**: Cancel and close

## Dependencies

- python3
- python-gobject
- gtk3
- gtk-layer-shell
- hyprland
- dunstify (notifications)

## Monitor Configuration

The system is configured for:
- **DP-2**: Main ultrawide monitor (3440x1440@74.98)
- **DP-1**: TV via HDMI→DisplayPort adapter (3840x2160@120, 1.5x scale, positioned left)

## Architecture

### Display Modes

1. **Monitor Only**: Disable TV, use only main monitor
2. **Extend**: Both monitors side by side (TV left)
3. **Mirror**: TV mirrors main monitor
4. **TV Only**: Disable main monitor, use only TV

### State Management

- State is persisted to `~/.local/state/display-mode`
- Actual mode is detected from monitor layout on startup (not just state file)
- This prevents sync issues after crashes or manual config changes

### Monitor Detection

Uses `hyprctl monitors all` text output to detect physically connected monitors. This is more reliable than JSON output (`-j`) because:
- Text output shows ALL monitors including disabled ones
- JSON output only shows currently enabled monitors
- Allows distinguishing "disabled by software" from "physically unplugged"

## Important Notes

- Monitor identifiers are hardware-dependent. Changing cables/adapters may change port names (e.g., HDMI-A-1 → DP-1).
- The HDMI→DisplayPort adapter used in this setup causes intermittent disconnections. If the TV is not detected, check adapter seating or try a different adapter.
- `monitors.conf` must reference the correct port names for the configuration to apply on startup.

## Troubleshooting

### TV not detected after adapter change
1. Check `hyprctl monitors all` output for correct port name
2. Update `monitors.conf`, `display-apply.sh`, and `display-switcher.py` with new port name
3. Reload Hyprland: `hyprctl reload`

### Only "Monitor" mode shown
- Check if TV is physically connected: `hyprctl monitors all`
- Verify port name matches configuration
- Check adapter connection

### State out of sync after crash
- The overlay detects actual monitor layout on startup
- State file is used as fallback only
- Manually correct state file if needed: `echo "extend" > ~/.local/state/display-mode`

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
~/.local/bin/display-switcher.py    # Main overlay
~/.local/bin/display-apply.sh       # Mode application script
~/.config/hypr/display-switcher.css # Theme styling
~/.local/state/display-mode         # Current mode state
~/.local/state/display-switcher.log # Application logs
```
