# Hyprland Display Switcher Overlay

A Windows+P-style display mode switcher for Hyprland using GTK3 overlay.

> **Status:** The native-HDMI two-mode refactor is designed but not implemented.
> Current runtime code is adapter-era legacy. See [ARCHITECTURE.md](ARCHITECTURE.md)
> for the approved design and [plan.md](plan.md) for the developer handoff.

## Installation

```bash
./install.sh
```

This will symlink the scripts to `~/.local/bin/` and update your Hyprland configuration.

## Usage

Press `Super+O` to open the overlay, then:
- `Super+O` inside overlay to cycle modes
- `Enter` to confirm
- `Escape` to cancel

## Files

- `src/display-switcher.py` - Main GTK overlay application
- `src/display-apply.sh` - Script to apply display configurations
- `config/display-switcher.css` - GTK styling matching HyDE "Another World" theme
