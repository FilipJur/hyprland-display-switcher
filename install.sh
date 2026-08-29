#!/bin/bash
# install.sh - Install the Hyprland Display Switcher
# Creates executable symlinks for the overlay and the applier, installs the
# overlay CSS, checks runtime dependencies, and validates that the deployed
# hyprlang source chain loads monitors.conf before the switcher's generated
# desired-state file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/hypr"
STATE_DIR="$HOME/.local/state"
HYPRLAND_CONF="$CONFIG_DIR/hyprland.conf"

# ---------------------------------------------------------------------------
# Source-order validation (fails before anything is installed)
# ---------------------------------------------------------------------------

fail_source_order() {
    local reason="$1"
    {
        echo "ERROR: $reason"
        echo ""
        echo "Expected in $HYPRLAND_CONF, in this order:"
        echo "  source = ./monitors.conf"
        echo "  source = ./display-switcher-generated.conf"
        echo ""
        echo "The desired-state file written on every mode switch must be sourced"
        echo "after monitors.conf so it remains the final override."
        echo "Edit $HYPRLAND_CONF manually, then re-run install.sh; the installer"
        echo "never edits user configuration."
    } >&2
    exit 1
}

# Line number of the first non-comment "source =" line whose value ends with
# $1, or empty output when absent.
find_source_line() {
    awk -v name="$1" '
        /^[[:space:]]*#/ { next }
        $1 == "source" && $2 == "=" {
            value = $3
            gsub(/"/, "", value)
            count = split(value, segments, "/")
            if (segments[count] == name) { print NR; exit }
        }
    ' "$HYPRLAND_CONF"
}

validate_source_order() {
    if [[ ! -f "$HYPRLAND_CONF" ]]; then
        fail_source_order "$HYPRLAND_CONF not found."
    fi
    local monitors_line generated_line
    monitors_line="$(find_source_line "monitors.conf")"
    generated_line="$(find_source_line "display-switcher-generated.conf")"
    if [[ -z "$monitors_line" && -z "$generated_line" ]]; then
        fail_source_order "$HYPRLAND_CONF sources neither monitors.conf nor display-switcher-generated.conf."
    fi
    if [[ -z "$monitors_line" ]]; then
        fail_source_order "$HYPRLAND_CONF does not source monitors.conf."
    fi
    if [[ -z "$generated_line" ]]; then
        fail_source_order "$HYPRLAND_CONF does not source display-switcher-generated.conf."
    fi
    if (( monitors_line >= generated_line )); then
        fail_source_order "$HYPRLAND_CONF sources display-switcher-generated.conf (line $generated_line) before monitors.conf (line $monitors_line)."
    fi
    echo "Source order OK: monitors.conf (line $monitors_line) before display-switcher-generated.conf (line $generated_line)"
}

# ---------------------------------------------------------------------------
# Repository-owned stale link cleanup
# ---------------------------------------------------------------------------

# Remove a stale helper symlink only when its resolved target lives inside
# this repository, so unrelated user files are never touched.
remove_repo_owned_link() {
    local link="$BIN_DIR/$1" target
    [[ -L "$link" ]] || return 0
    target="$(readlink -f "$link" 2>/dev/null)" || return 0
    if [[ "$target" == "$SCRIPT_DIR"/* ]]; then
        rm -f "$link"
        echo "Removed obsolete symlink: $link -> $target"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "Installing Hyprland Display Switcher..."
validate_source_order

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$STATE_DIR"

remove_repo_owned_link "display-dpm.sh"
remove_repo_owned_link "fix-pcon-audio.py"

# Executable symlinks for the overlay and the applier
ln -sfn "$SCRIPT_DIR/src/display_switcher.py" "$BIN_DIR/display-switcher.py"
ln -sfn "$SCRIPT_DIR/src/display_apply.sh" "$BIN_DIR/display-apply.sh"
chmod +x "$SCRIPT_DIR/src/display_switcher.py" "$SCRIPT_DIR/src/display_apply.sh"

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

# Runtime dependencies
missing=()
command -v bash >/dev/null 2>&1 || missing+=("bash")
command -v hyprctl >/dev/null 2>&1 || missing+=("hyprland")
command -v jq >/dev/null 2>&1 || missing+=("jq")
command -v python3 >/dev/null 2>&1 || missing+=("python")
python3 -c "import gi" >/dev/null 2>&1 || missing+=("python-gobject")
python3 -c "import gi; gi.require_version('Gtk', '3.0')" >/dev/null 2>&1 || missing+=("gtk3")
python3 -c "import gi; gi.require_version('GtkLayerShell', '0.1')" >/dev/null 2>&1 || missing+=("gtk-layer-shell")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "WARNING: Missing dependencies: ${missing[*]}"
    echo "On Arch, install with your package manager: hyprland jq python python-gobject gtk3 gtk-layer-shell"
fi

echo ""
echo "Ensure this is in ~/.config/hypr/keybindings.conf:"
echo '  bindd = $mainMod, O, Toggle display mode, exec, python3 ~/.local/bin/display-switcher.py'
echo ""
echo "Installation complete!"
