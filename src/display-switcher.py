#!/usr/bin/env python3
"""Hyprland Display Switcher Overlay - GTK3 Layer-Shell Display Mode Selector"""

import os
import sys
import json
import subprocess
import signal
from typing import List, Dict, Any, Optional, Set
import gi

gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')

try:
    gi.require_version('GtkLayerShell', '0.1')
    from gi.repository import GtkLayerShell
    HAS_LAYER_SHELL = True
except (ValueError, ImportError):
    HAS_LAYER_SHELL = False

from gi.repository import Gtk, Gdk, GLib

# Configuration
CSS_FILE = os.path.expanduser("~/.config/hypr/display-switcher.css")
STATE_FILE = os.path.expanduser("~/.local/state/display-mode")
TIMEOUT_SECONDS = 3

# Icon fallbacks (emoji) if symbolic icons not available
ICON_FALLBACKS = {
    "video-display-symbolic": "🖥️",
    "video-joined-displays-symbolic": "↔️",
    "view-mirror-symbolic": "🪞",
    "tv-symbolic": "📺",
}

DISPLAY_MODES: List[Dict[str, Any]] = [
    {
        "id": "monitor",
        "name": "Monitor Only",
        "icon": "video-display-symbolic",
        "description": "Disable external display",
        "requires": ["DP-2"],
    },
    {
        "id": "extend",
        "name": "Extend",
        "icon": "video-joined-displays-symbolic",
        "description": "Extended desktop",
        "requires": ["DP-2", "HDMI-A-1"],
    },
    {
        "id": "mirror",
        "name": "Mirror",
        "icon": "view-mirror-symbolic",
        "description": "Duplicate displays",
        "requires": ["DP-2", "HDMI-A-1"],
    },
    {
        "id": "tv",
        "name": "TV Only",
        "icon": "tv-symbolic",
        "description": "Disable built-in display",
        "requires": ["HDMI-A-1"],
    },
]


class ModeButton(Gtk.Box):
    """Individual display mode option button"""

    def __init__(self, mode_data: Dict[str, Any]) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=8)

        self.mode_id: str = mode_data["id"]
        self.is_selected: bool = False
        self.is_current: bool = False

        self.set_name("mode-button")
        self.set_size_request(130, 150)
        self.set_homogeneous(False)
        self.set_halign(Gtk.Align.CENTER)
        self.set_valign(Gtk.Align.CENTER)

        # Active indicator (dot)
        self.indicator = Gtk.Label(label="●")
        self.indicator.set_name("mode-indicator")
        self.indicator.set_no_show_all(True)
        self.indicator.hide()

        # Icon with fallback
        icon_name = mode_data["icon"]
        icon_theme = Gtk.IconTheme.get_default()

        if icon_theme.has_icon(icon_name):
            self.icon = Gtk.Image.new_from_icon_name(icon_name, Gtk.IconSize.DIALOG)
            self.icon.set_pixel_size(48)
            self.icon.set_name("mode-icon")
        else:
            # Fallback to emoji label
            self.icon = Gtk.Label(label=ICON_FALLBACKS.get(icon_name, "🖥️"))
            self.icon.set_name("mode-icon-fallback")
            self.icon.get_style_context().add_class("emoji-icon")

        # Label
        self.label = Gtk.Label(label=mode_data["name"])
        self.label.set_name("mode-label")
        self.label.set_justify(Gtk.Justification.CENTER)

        # Description
        self.desc = Gtk.Label(label=mode_data["description"])
        self.desc.set_name("mode-desc")
        self.desc.set_justify(Gtk.Justification.CENTER)

        # Pack widgets
        self.pack_start(self.indicator, False, False, 0)
        self.pack_start(self.icon, False, False, 0)
        self.pack_start(self.label, False, False, 0)
        self.pack_start(self.desc, False, False, 0)

        self.show_all()

    def set_selected(self, selected: bool) -> None:
        """Update selection state and styling"""
        self.is_selected = selected

        if selected:
            self.get_style_context().add_class("selected")
        else:
            self.get_style_context().remove_class("selected")

    def set_current(self, current: bool) -> None:
        """Mark as the currently active mode"""
        self.is_current = current

        if current:
            self.indicator.show()
            self.get_style_context().add_class("current")
        else:
            self.indicator.hide()
            self.get_style_context().remove_class("current")

    def get_mode_id(self) -> str:
        return self.mode_id


class DisplaySwitcher(Gtk.Window):
    """Main overlay window for display mode switching"""

    def __init__(self) -> None:
        super().__init__(title="display-switcher")

        self.set_decorated(False)
        self.set_resizable(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)

        # CRITICAL: Layer-shell MUST be initialized BEFORE window is realized/shown
        self.setup_layer_shell()

        # Load CSS
        self.load_css()

        # Detect available modes
        self.available_modes = self.detect_available_modes()
        if not self.available_modes:
            self.show_error("No display modes available")
            return

        # Load current mode
        self.current_mode = self.load_current_mode()
        self.selected_index = self.get_next_mode_index()

        # Setup UI (build but don't show yet)
        self.build_ui()

        # Setup keyboard handling
        self.connect("key-press-event", self.on_key_press)
        self.connect("destroy", self.on_destroy)

        # Now show the window (after layer-shell is configured)
        self.show_all()

        # Setup timeout timer
        self.timeout_id: Optional[int] = None
        self.reset_timer()

    def setup_layer_shell(self) -> None:
        """Configure gtk-layer-shell for proper overlay behavior"""
        if not HAS_LAYER_SHELL:
            # Fallback for systems without layer-shell
            self.set_type_hint(Gdk.WindowTypeHint.SPLASHSCREEN)
            return

        GtkLayerShell.init_for_window(self)
        GtkLayerShell.set_layer(self, GtkLayerShell.Layer.OVERLAY)
        GtkLayerShell.set_keyboard_mode(self, GtkLayerShell.KeyboardMode.EXCLUSIVE)

        # Fill entire screen for backdrop effect
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.TOP, True)
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.BOTTOM, True)
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.LEFT, True)
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.RIGHT, True)

        # Set margins to 0 (fill screen)
        GtkLayerShell.set_margin(self, GtkLayerShell.Edge.TOP, 0)
        GtkLayerShell.set_margin(self, GtkLayerShell.Edge.BOTTOM, 0)
        GtkLayerShell.set_margin(self, GtkLayerShell.Edge.LEFT, 0)
        GtkLayerShell.set_margin(self, GtkLayerShell.Edge.RIGHT, 0)

    def load_css(self) -> None:
        """Load custom CSS styling"""
        css_provider = Gtk.CssProvider()

        try:
            if os.path.exists(CSS_FILE):
                css_provider.load_from_path(CSS_FILE)
            else:
                css_provider.load_from_data(self.get_default_css().encode())

            screen = Gdk.Screen.get_default()
            if screen:
                Gtk.StyleContext.add_provider_for_screen(
                    screen,
                    css_provider,
                    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
                )
        except Exception as e:
            print(f"Warning: Failed to load CSS: {e}", file=sys.stderr)

    def get_default_css(self) -> str:
        """Return default CSS if file doesn't exist"""
        return """
        #display-switcher {
            background: rgba(0, 0, 0, 0.6);
        }

        #menu-container {
            background: rgba(19, 19, 29, 0.95);
            border: 2px solid rgba(120, 198, 235, 0.5);
            border-radius: 16px;
            padding: 24px;
        }

        #mode-button {
            background: rgba(255, 255, 255, 0.05);
            border: 2px solid transparent;
            border-radius: 12px;
            padding: 16px 24px;
            margin: 0 8px;
        }

        #mode-button:hover {
            background: rgba(255, 255, 255, 0.1);
        }

        #mode-button.selected {
            background: rgba(106, 169, 201, 0.15);
            border-color: rgba(106, 169, 201, 0.8);
            box-shadow: 0 0 20px rgba(106, 169, 201, 0.3);
        }

        #mode-button.current {
            border-color: rgba(255, 255, 255, 0.2);
        }

        #mode-indicator {
            color: rgba(106, 169, 201, 0.9);
            font-size: 8px;
            margin-bottom: 4px;
        }

        #mode-icon {
            color: #FFFFFF;
            opacity: 0.7;
        }

        .emoji-icon {
            color: #FFFFFF;
            font-size: 36px;
            opacity: 0.9;
        }

        #mode-button.selected #mode-icon {
            color: #6AA9C9;
            opacity: 1;
        }

        #mode-button.selected .emoji-icon {
            color: #6AA9C9;
            opacity: 1;
        }

        #mode-label {
            color: #FFFFFF;
            font-size: 14px;
            font-weight: 500;
            margin-top: 8px;
        }

        #mode-button.selected #mode-label {
            color: #EFEFF5;
            font-weight: 700;
        }

        #mode-desc {
            color: rgba(255, 255, 255, 0.6);
            font-size: 11px;
            margin-top: 4px;
        }
        """

    def detect_available_modes(self) -> List[Dict[str, Any]]:
        """Detect which display modes are available based on connected monitors"""
        try:
            output = subprocess.check_output(
                ["hyprctl", "monitors", "-j"],
                text=True,
                timeout=5
            )
            monitors = json.loads(output)
            connected: Set[str] = {m["name"] for m in monitors}
        except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError) as e:
            print(f"Warning: Failed to detect monitors: {e}", file=sys.stderr)
            return []

        available = []
        for mode in DISPLAY_MODES:
            if all(req in connected for req in mode["requires"]):
                available.append(mode)

        return available

    def load_current_mode(self) -> str:
        """Load current display mode from state file"""
        if os.path.exists(STATE_FILE):
            try:
                with open(STATE_FILE, 'r') as f:
                    mode = f.read().strip()
                    if any(m["id"] == mode for m in DISPLAY_MODES):
                        return mode
            except (IOError, OSError) as e:
                print(f"Warning: Failed to read state file: {e}", file=sys.stderr)
        return "monitor"

    def get_next_mode_index(self) -> int:
        """Get index of next mode in cycle"""
        mode_ids = [m["id"] for m in self.available_modes]

        if self.current_mode in mode_ids:
            current_idx = mode_ids.index(self.current_mode)
            return (current_idx + 1) % len(mode_ids)

        return 0

    def build_ui(self) -> None:
        """Build the user interface"""
        self.set_name("display-switcher")

        # Backdrop + centering container
        overlay = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        overlay.set_halign(Gtk.Align.FILL)
        overlay.set_valign(Gtk.Align.FILL)
        overlay.set_homogeneous(False)

        # Center alignment
        center_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        center_box.set_halign(Gtk.Align.CENTER)
        center_box.set_valign(Gtk.Align.CENTER)
        center_box.set_homogeneous(False)

        # Menu container
        menu_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        menu_box.set_name("menu-container")
        menu_box.set_homogeneous(True)

        # Create mode buttons
        self.buttons: List[ModeButton] = []
        for mode in self.available_modes:
            btn = ModeButton(mode)
            self.buttons.append(btn)
            menu_box.pack_start(btn, True, True, 0)

        # Set initial states
        if self.buttons:
            self.buttons[self.selected_index].set_selected(True)

            # Mark current mode
            mode_ids = [m["id"] for m in self.available_modes]
            if self.current_mode in mode_ids:
                current_idx = mode_ids.index(self.current_mode)
                self.buttons[current_idx].set_current(True)

        center_box.pack_start(menu_box, False, False, 0)
        overlay.pack_start(center_box, True, True, 0)

        self.add(overlay)

    def on_key_press(self, widget: Gtk.Widget, event: Gdk.EventKey) -> bool:
        """Handle keyboard input"""
        keyval = event.keyval

        # Escape - cancel
        if keyval == Gdk.KEY_Escape:
            self.close()
            return True

        # Enter/Return - confirm
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            self.confirm_selection()
            return True

        # Super+O (MOD4+o) - cycle
        if keyval == Gdk.KEY_o and (event.state & Gdk.ModifierType.MOD4_MASK):
            self.cycle_selection()
            self.reset_timer()
            return True

        # Any other key - reset timer
        self.reset_timer()
        return True

    def cycle_selection(self) -> None:
        """Move selection to next available mode"""
        if not self.buttons:
            return

        # Deselect current
        self.buttons[self.selected_index].set_selected(False)

        # Move to next
        self.selected_index = (self.selected_index + 1) % len(self.buttons)

        # Select new
        self.buttons[self.selected_index].set_selected(True)

    def confirm_selection(self) -> None:
        """Apply selected display mode"""
        if not self.buttons:
            return

        selected_mode = self.buttons[self.selected_index].get_mode_id()

        # Close overlay first
        self.close()

        # Apply mode
        try:
            script_path = os.path.expanduser("~/.local/bin/display-apply.sh")
            if os.path.exists(script_path):
                subprocess.Popen(
                    [script_path, selected_mode],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
            else:
                print(f"Error: {script_path} not found", file=sys.stderr)
        except OSError as e:
            print(f"Error: Failed to run display-apply.sh: {e}", file=sys.stderr)

    def reset_timer(self) -> None:
        """Reset inactivity timeout timer"""
        if self.timeout_id is not None:
            GLib.source_remove(self.timeout_id)

        self.timeout_id = GLib.timeout_add_seconds(
            TIMEOUT_SECONDS,
            self.on_timeout
        )

    def on_timeout(self) -> bool:
        """Handle timeout - close overlay"""
        self.close()
        return False

    def on_destroy(self, widget: Gtk.Widget) -> None:
        """Clean up on window destroy"""
        if self.timeout_id is not None:
            GLib.source_remove(self.timeout_id)
            self.timeout_id = None

    def show_error(self, message: str) -> None:
        """Show error dialog"""
        dialog = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.ERROR,
            buttons=Gtk.ButtonsType.OK,
            text=message,
        )
        dialog.run()
        dialog.destroy()
        self.close()


def check_single_instance() -> str:
    """Ensure only one instance is running"""
    pid_file = os.path.expanduser("~/.local/state/display-switcher.pid")

    if os.path.exists(pid_file):
        try:
            with open(pid_file, 'r') as f:
                old_pid = int(f.read().strip())
            os.kill(old_pid, signal.SIGTERM)
        except (ValueError, ProcessLookupError, OSError):
            pass

    with open(pid_file, 'w') as f:
        f.write(str(os.getpid()))

    return pid_file


def cleanup_pid(pid_file: str) -> None:
    """Remove PID file on exit"""
    if os.path.exists(pid_file):
        os.remove(pid_file)


def main() -> None:
    # Check single instance
    pid_file = check_single_instance()

    try:
        app = DisplaySwitcher()
        app.connect("destroy", lambda w: cleanup_pid(pid_file))
        Gtk.main()
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        cleanup_pid(pid_file)
        sys.exit(1)


if __name__ == "__main__":
    main()
