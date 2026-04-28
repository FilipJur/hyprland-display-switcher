#!/usr/bin/env python3
"""Hyprland Display Switcher Overlay - GTK3 Layer-Shell Display Mode Selector"""

import os
import sys
import json
import subprocess
import signal
import gi

gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
gi.require_version('GdkPixbuf', '2.0')

try:
    gi.require_version('GtkLayerShell', '0.1')
    from gi.repository import GtkLayerShell
    HAS_LAYER_SHELL = True
except (ValueError, ImportError):
    HAS_LAYER_SHELL = False

from gi.repository import Gtk, Gdk, GdkPixbuf, GLib, GObject

# Configuration
CSS_FILE = os.path.expanduser("~/.config/hypr/display-switcher.css")
STATE_FILE = os.path.expanduser("~/.local/state/display-mode")
TIMEOUT_SECONDS = 3

DISPLAY_MODES = [
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
    
    def __init__(self, mode_data):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        
        self.mode_id = mode_data["id"]
        self.is_selected = False
        
        self.set_name("mode-button")
        self.set_size_request(120, 140)
        self.set_homogeneous(False)
        
        # Icon
        icon_name = mode_data["icon"]
        self.icon = Gtk.Image.new_from_icon_name(icon_name, Gtk.IconSize.DIALOG)
        self.icon.set_pixel_size(48)
        self.icon.set_name("mode-icon")
        
        # Label
        self.label = Gtk.Label(label=mode_data["name"])
        self.label.set_name("mode-label")
        self.label.set_justify(Gtk.Justification.CENTER)
        
        # Description
        self.desc = Gtk.Label(label=mode_data["description"])
        self.desc.set_name("mode-desc")
        self.desc.set_justify(Gtk.Justification.CENTER)
        
        # Pack widgets
        self.pack_start(self.icon, False, False, 0)
        self.pack_start(self.label, False, False, 0)
        self.pack_start(self.desc, False, False, 0)
        
        self.show_all()
    
    def set_selected(self, selected):
        """Update selection state and styling"""
        self.is_selected = selected
        
        if selected:
            self.get_style_context().add_class("selected")
        else:
            self.get_style_context().remove_class("selected")
    
    def get_mode_id(self):
        return self.mode_id


class DisplaySwitcher(Gtk.Window):
    """Main overlay window for display mode switching"""
    
    def __init__(self):
        super().__init__(title="display-switcher")
        
        self.set_default_size(600, 200)
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_type_hint(Gdk.WindowTypeHint.SPLASHSCREEN)
        
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
        
        # Setup UI
        self.build_ui()
        
        # Setup keyboard handling
        self.connect("key-press-event", self.on_key_press)
        self.connect("destroy", self.on_destroy)
        
        # Grab keyboard
        self.grab_keyboard()
        
        # Setup timeout timer
        self.timeout_id = None
        self.reset_timer()
        
        # Position window
        self.position_window()
    
    def load_css(self):
        """Load custom CSS styling"""
        css_provider = Gtk.CssProvider()
        
        if os.path.exists(CSS_FILE):
            css_provider.load_from_path(CSS_FILE)
        else:
            css_provider.load_from_data(self.get_default_css().encode())
        
        screen = Gdk.Screen.get_default()
        style_context = Gtk.StyleContext()
        style_context.add_provider_for_screen(
            screen, css_provider, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )
    
    def get_default_css(self):
        """Return default CSS if file doesn't exist"""
        return """
        #display-switcher {
            background: rgba(19, 19, 29, 0.95);
            border: 2px solid rgba(120, 198, 235, 0.5);
            border-radius: 16px;
            padding: 24px;
        }
        
        #mode-button {
            background: rgba(255, 255, 255, 0.05);
            border: 2px solid transparent;
            border-radius: 12px;
            padding: 20px 30px;
            margin: 0 8px;
        }
        
        #mode-button.selected {
            background: rgba(106, 169, 201, 0.15);
            border-color: rgba(106, 169, 201, 0.8);
        }
        
        #mode-label {
            color: #FFFFFF;
            font-size: 14px;
            font-weight: 500;
        }
        
        #mode-button.selected #mode-label {
            color: #EFEFF5;
            font-weight: 700;
        }
        
        #mode-desc {
            color: rgba(255, 255, 255, 0.6);
            font-size: 11px;
        }
        """
    
    def detect_available_modes(self):
        """Detect which display modes are available based on connected monitors"""
        try:
            output = subprocess.check_output(
                ["hyprctl", "monitors", "-j"],
                text=True,
                timeout=5
            )
            monitors = json.loads(output)
            connected = {m["name"] for m in monitors}
        except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
            return []
        
        available = []
        for mode in DISPLAY_MODES:
            if all(req in connected for req in mode["requires"]):
                available.append(mode)
        
        return available
    
    def load_current_mode(self):
        """Load current display mode from state file"""
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE, 'r') as f:
                mode = f.read().strip()
                if any(m["id"] == mode for m in DISPLAY_MODES):
                    return mode
        return "monitor"
    
    def get_next_mode_index(self):
        """Get index of next mode in cycle"""
        mode_ids = [m["id"] for m in self.available_modes]
        
        if self.current_mode in mode_ids:
            current_idx = mode_ids.index(self.current_mode)
            return (current_idx + 1) % len(mode_ids)
        
        return 0
    
    def build_ui(self):
        """Build the user interface"""
        self.set_name("display-switcher")
        
        # Main container
        main_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        main_box.set_homogeneous(True)
        main_box.set_margin_top(20)
        main_box.set_margin_bottom(20)
        main_box.set_margin_start(20)
        main_box.set_margin_end(20)
        
        # Create mode buttons
        self.buttons = []
        for mode in self.available_modes:
            btn = ModeButton(mode)
            self.buttons.append(btn)
            main_box.pack_start(btn, True, True, 0)
        
        # Set initial selection
        if self.buttons:
            self.buttons[self.selected_index].set_selected(True)
        
        self.add(main_box)
        self.show_all()
    
    def position_window(self):
        """Position window at center of all monitors"""
        display = Gdk.Display.get_default()
        if not display:
            return
        
        # Calculate bounding box of all monitors
        min_x = float('inf')
        min_y = float('inf')
        max_x = float('-inf')
        max_y = float('-inf')
        
        for i in range(display.get_n_monitors()):
            monitor = display.get_monitor(i)
            geom = monitor.get_geometry()
            min_x = min(min_x, geom.x)
            min_y = min(min_y, geom.y)
            max_x = max(max_x, geom.x + geom.width)
            max_y = max(max_y, geom.y + geom.height)
        
        canvas_width = max_x - min_x
        canvas_height = max_y - min_y
        
        # Get window size
        win_width, win_height = self.get_size()
        
        # Calculate position
        x = min_x + (canvas_width - win_width) // 2
        y = min_y + (canvas_height - win_height) // 2
        
        self.move(x, y)
    
    def grab_keyboard(self):
        """Grab keyboard input"""
        self.grab_add()
        Gdk.keyboard_grab(
            self.get_window(),
            True,
            Gdk.CURRENT_TIME
        )
    
    def release_keyboard(self):
        """Release keyboard grab"""
        Gdk.keyboard_ungrab(Gdk.CURRENT_TIME)
        self.grab_remove()
    
    def on_key_press(self, widget, event):
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
    
    def cycle_selection(self):
        """Move selection to next available mode"""
        if not self.buttons:
            return
        
        # Deselect current
        self.buttons[self.selected_index].set_selected(False)
        
        # Move to next
        self.selected_index = (self.selected_index + 1) % len(self.buttons)
        
        # Select new
        self.buttons[self.selected_index].set_selected(True)
    
    def confirm_selection(self):
        """Apply selected display mode"""
        if not self.buttons:
            return
        
        selected_mode = self.buttons[self.selected_index].get_mode_id()
        
        # Close overlay first
        self.close()
        
        # Apply mode
        try:
            script_path = os.path.expanduser("~/.local/bin/display-apply.sh")
            subprocess.Popen([script_path, selected_mode])
        except FileNotFoundError:
            print(f"Error: {script_path} not found", file=sys.stderr)
    
    def reset_timer(self):
        """Reset inactivity timeout timer"""
        if self.timeout_id:
            GLib.source_remove(self.timeout_id)
        
        self.timeout_id = GLib.timeout_add_seconds(
            TIMEOUT_SECONDS,
            self.on_timeout
        )
    
    def on_timeout(self):
        """Handle timeout - close overlay"""
        self.close()
        return False
    
    def on_destroy(self, widget):
        """Clean up on window destroy"""
        self.release_keyboard()
        if self.timeout_id:
            GLib.source_remove(self.timeout_id)
    
    def show_error(self, message):
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


def check_single_instance():
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


def cleanup_pid(pid_file):
    """Remove PID file on exit"""
    if os.path.exists(pid_file):
        os.remove(pid_file)


def main():
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
