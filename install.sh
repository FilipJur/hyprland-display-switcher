#!/bin/bash
# install.sh - Install Hyprland Display Switcher (MVP)
# Creates symlinks for development

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/hypr"
STATE_DIR="$HOME/.local/state"

echo "Installing Hyprland Display Switcher (MVP)..."

# Create directories
mkdir -p "$BIN_DIR"
mkdir -p "$CONFIG_DIR"
mkdir -p "$STATE_DIR"

# Remove old standalone copies if they exist (not symlinks)
if [[ -f "$BIN_DIR/display-switcher.py" && ! -L "$BIN_DIR/display-switcher.py" ]]; then
    echo "Removing old standalone display-switcher.py"
    rm -f "$BIN_DIR/display-switcher.py"
fi
if [[ -f "$BIN_DIR/display-apply.sh" && ! -L "$BIN_DIR/display-apply.sh" ]]; then
    echo "Removing old standalone display-apply.sh"
    rm -f "$BIN_DIR/display-apply.sh"
fi

# Create symlinks (dev mode)
ln -sf "$SCRIPT_DIR/src/display_switcher.py" "$BIN_DIR/display-switcher.py"
ln -sf "$SCRIPT_DIR/src/display_apply.sh" "$BIN_DIR/display-apply.sh"
chmod +x "$SCRIPT_DIR/src/display_switcher.py"
chmod +x "$SCRIPT_DIR/src/display_apply.sh"

# Install CSS config if not exists
if [[ ! -f "$CONFIG_DIR/display-switcher.css" ]]; then
    install -m 644 "$SCRIPT_DIR/config/display-switcher.css" "$CONFIG_DIR/display-switcher.css"
    echo "Installed default CSS config"
else
    echo "CSS config already exists (not overwritten)"
fi

echo ""
echo "Installed (symlinks):"
echo "  $BIN_DIR/display-switcher.py -> src/display_switcher.py"
echo "  $BIN_DIR/display-apply.sh -> src/display_apply.sh"
echo ""

# Check keybinding
echo "Ensure this is in ~/.config/hypr/keybindings.conf:"
echo '  bindd = $mainMod, O, Toggle display mode, exec, python3 ~/.local/bin/display-switcher.py'
echo ""

# Check deps
missing=()
if ! command -v python3 >/dev/null 2>&1; then missing+=("python3"); fi
if ! python3 -c "import gi" 2>/dev/null; then missing+=("python-gobject"); fi
if ! command -v hyprctl >/dev/null 2>&1; then missing+=("hyprland"); fi
if ! python3 -c "import gi; gi.require_version('GtkLayerShell', '0.1')" 2>/dev/null; then missing+=("gtk-layer-shell"); fi

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "WARNING: Missing dependencies: ${missing[*]}"
    echo "On Arch: sudo pacman -S python python-gobject gtk3 gtk-layer-shell"
fi

echo ""
echo "Installation complete!"
