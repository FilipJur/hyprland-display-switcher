#!/bin/bash
# install.sh - Install Hyprland Display Switcher

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/hypr"
STATE_DIR="$HOME/.local/state"

echo "Installing Hyprland Display Switcher..."

# Create directories
mkdir -p "$BIN_DIR"
mkdir -p "$CONFIG_DIR"
mkdir -p "$STATE_DIR"

# Backup old toggle script if exists
if [[ -f "$BIN_DIR/display-toggle.sh" && ! -f "$BIN_DIR/display-toggle.sh.bak" ]]; then
    echo "Backing up old display-toggle.sh to display-toggle.sh.bak"
    mv "$BIN_DIR/display-toggle.sh" "$BIN_DIR/display-toggle.sh.bak"
fi

# Install scripts
install -m 755 "$SCRIPT_DIR/src/display-switcher.py" "$BIN_DIR/display-switcher.py"
install -m 755 "$SCRIPT_DIR/src/display-apply.sh" "$BIN_DIR/display-apply.sh"

# Install CSS config if not exists
if [[ ! -f "$CONFIG_DIR/display-switcher.css" ]]; then
    install -m 644 "$SCRIPT_DIR/config/display-switcher.css" "$CONFIG_DIR/display-switcher.css"
    echo "Installed default CSS config to $CONFIG_DIR/display-switcher.css"
else
    echo "CSS config already exists at $CONFIG_DIR/display-switcher.css (not overwritten)"
fi

echo ""
echo "Installed:"
echo "  $BIN_DIR/display-switcher.py"
echo "  $BIN_DIR/display-apply.sh"
echo ""

# Check for duplicate keybinding
echo "Checking keybindings.conf..."
if grep -v '^\s*#' "$CONFIG_DIR/keybindings.conf" 2>/dev/null | grep -q "display-toggle.sh"; then
    echo "WARNING: Old display-toggle.sh binding still found in keybindings.conf"
    echo "  Please comment out or remove:"
    echo "    bindd = \$mainMod, O, ... display-toggle.sh"
fi

echo ""
echo "Add this to your ~/.config/hypr/keybindings.conf (if not already present):"
echo "  bindd = \$mainMod, O, Toggle display mode, exec, python3 ~/.local/bin/display-switcher.py"
echo ""
echo "Window rules added/verified in ~/.config/hypr/windowrules.conf:"
echo "  windowrule = float, ^(display-switcher)\$"
echo "  windowrule = center, ^(display-switcher)\$"
echo "  windowrule = noanim, ^(display-switcher)\$"
echo "  windowrule = noborder, ^(display-switcher)\$"
echo "  windowrule = noshadow, ^(display-switcher)\$"
echo ""

# Check for dependencies
missing_deps=()

if ! command -v python3 &> /dev/null; then
    missing_deps+=("python3")
fi

if ! python3 -c "import gi" &> /dev/null; then
    missing_deps+=("python3-gi (PyGObject)")
fi

if ! command -v hyprctl &> /dev/null; then
    missing_deps+=("hyprland")
fi

if ! python3 -c "import gi; gi.require_version('GtkLayerShell', '0.1'); from gi.repository import GtkLayerShell" &> /dev/null; then
    missing_deps+=("gtk-layer-shell")
fi

if ! command -v jq &> /dev/null; then
    missing_deps+=("jq")
fi

if [[ ${#missing_deps[@]} -gt 0 ]]; then
    echo "WARNING: Missing dependencies:"
    printf '  - %s\n' "${missing_deps[@]}"
    echo ""
    echo "On Arch Linux, install with:"
    echo "  sudo pacman -S python python-gobject gtk3 gtk-layer-shell jq"
fi

echo ""
echo "Installation complete!"
echo "Press Super+O to test the display switcher."
