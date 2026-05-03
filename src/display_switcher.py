#!/usr/bin/env python3
"""Hyprland Display Switcher - MVP
Zero state, detects actual monitor layout, always shows 4 modes.
"""

import os
import sys
import time
import subprocess
import signal
from typing import List, Dict, Any
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

CSS_FILE = os.path.expanduser("~/.config/hypr/display-switcher.css")
PID_FILE = os.path.expanduser("~/.local/state/display-switcher.pid")
COOLDOWN_FILE = os.path.expanduser("~/.local/state/display-switcher.cooldown")
COOLDOWN_SECONDS = 8
TIMEOUT_SECONDS = 3

MODES: List[Dict[str, Any]] = [
    {"id": "monitor",  "name": "Monitor",  "icon": "video-display-symbolic",        "desc": "SDR"},
    {"id": "extend",   "name": "Extend",   "icon": "video-joined-displays-symbolic", "desc": "HDR"},
    {"id": "mirror",   "name": "Mirror",   "icon": "view-mirror-symbolic",           "desc": "SDR"},
    {"id": "tv",       "name": "TV",       "icon": "tv-symbolic",                    "desc": "HDR"},
]

ICON_FALLBACKS = {
    "video-display-symbolic": "🖥️",
    "video-joined-displays-symbolic": "↔️",
    "view-mirror-symbolic": "🪞",
    "tv-symbolic": "📺",
}


def detect_current_mode() -> str:
    """Detect current mode from actual monitor layout."""
    try:
        output = subprocess.check_output(
            ["hyprctl", "monitors", "all"],
            text=True,
            timeout=5
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return "monitor"  # fallback

    monitors = {}
    current_monitor = None
    for line in output.split('\n'):
        line = line.strip()
        if line.startswith('Monitor '):
            parts = line.split()
            if len(parts) >= 2:
                current_monitor = parts[1]
                monitors[current_monitor] = {"disabled": False, "mirror": None, "cm": "srgb"}
        elif line.startswith('disabled: ') and current_monitor:
            monitors[current_monitor]["disabled"] = (line.split(': ')[1] == "true")
        elif line.startswith('mirrorOf: ') and current_monitor:
            monitors[current_monitor]["mirror"] = line.split(': ')[1]
        elif line.startswith('colorManagementPreset: ') and current_monitor:
            monitors[current_monitor]["cm"] = line.split(': ')[1]

    dp2 = monitors.get("DP-2", {})
    dp1 = monitors.get("DP-1", {})

    dp2_enabled = dp2.get("disabled", True) is False
    dp1_enabled = dp1.get("disabled", True) is False
    dp1_mirror = dp1.get("mirror", "none")

    if dp2_enabled and not dp1_enabled:
        return "monitor"
    elif dp1_enabled and not dp2_enabled:
        return "tv"
    elif dp2_enabled and dp1_enabled:
        if dp1_mirror == "DP-2":
            return "mirror"
        return "extend"

    return "monitor"  # ultimate fallback


class ModeButton(Gtk.Box):
    def __init__(self, mode_data: Dict[str, Any]):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.mode_id = mode_data["id"]

        self.set_name("mode-button")
        self.set_size_request(120, 140)
        self.set_halign(Gtk.Align.CENTER)
        self.set_valign(Gtk.Align.CENTER)

        # Active indicator (purple dot)
        self.indicator = Gtk.Label(label="●")
        self.indicator.set_name("mode-indicator")
        self.indicator.set_no_show_all(True)
        self.indicator.hide()

        # Icon + text flex container
        self.content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.content.set_halign(Gtk.Align.CENTER)
        self.content.set_valign(Gtk.Align.CENTER)
        self.content.set_name("mode-content")

        # Icon with fallback
        icon_name = mode_data["icon"]
        icon_theme = Gtk.IconTheme.get_default()
        if icon_theme.has_icon(icon_name):
            self.icon = Gtk.Image.new_from_icon_name(icon_name, Gtk.IconSize.DIALOG)
            self.icon.set_pixel_size(48)
            self.icon.set_name("mode-icon")
        else:
            self.icon = Gtk.Label(label=ICON_FALLBACKS.get(icon_name, "🖥️"))
            self.icon.set_name("mode-icon-fallback")
            self.icon.get_style_context().add_class("emoji-icon")
        self.icon.set_halign(Gtk.Align.CENTER)

        # Label
        self.label = Gtk.Label(label=mode_data["name"])
        self.label.set_name("mode-label")
        self.label.set_justify(Gtk.Justification.CENTER)
        self.label.set_halign(Gtk.Align.CENTER)

        # Description (HDR/SDR indicator)
        self.desc = Gtk.Label(label=mode_data["desc"])
        self.desc.set_name("mode-desc")
        self.desc.set_justify(Gtk.Justification.CENTER)
        self.desc.set_halign(Gtk.Align.CENTER)

        self.content.pack_start(self.icon, False, False, 0)
        self.content.pack_start(self.label, False, False, 0)
        self.content.pack_start(self.desc, False, False, 0)

        self.pack_start(self.indicator, False, False, 0)
        self.pack_start(self.content, True, True, 0)
        self.show_all()

    def set_selected(self, selected: bool):
        if selected:
            self.get_style_context().add_class("selected")
        else:
            self.get_style_context().remove_class("selected")

    def set_current(self, current: bool):
        if current:
            self.indicator.show()
            self.get_style_context().add_class("current")
        else:
            self.indicator.hide()
            self.get_style_context().remove_class("current")


class DisplaySwitcher(Gtk.Window):
    def __init__(self):
        super().__init__(title="display-switcher")
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)

        # Layer-shell FIRST
        if HAS_LAYER_SHELL:
            GtkLayerShell.init_for_window(self)
            GtkLayerShell.set_layer(self, GtkLayerShell.Layer.OVERLAY)
            GtkLayerShell.set_keyboard_mode(self, GtkLayerShell.KeyboardMode.EXCLUSIVE)
            for edge in [GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.BOTTOM,
                         GtkLayerShell.Edge.LEFT, GtkLayerShell.Edge.RIGHT]:
                GtkLayerShell.set_anchor(self, edge, True)
                GtkLayerShell.set_margin(self, edge, 0)
        else:
            self.set_type_hint(Gdk.WindowTypeHint.SPLASHSCREEN)

        self.load_css()

        # Detect actual current mode
        self.current_mode = detect_current_mode()
        self.selected_index = self.get_next_index()
        self.timeout_id = None

        self.build_ui()

        self.connect("key-press-event", self.on_key_press)
        self.connect("destroy", self.on_destroy)
        signal.signal(signal.SIGUSR1, self.on_cycle_signal)

        self.show_all()
        self.reset_timer()

    def load_css(self):
        css_provider = Gtk.CssProvider()
        try:
            if os.path.exists(CSS_FILE):
                css_provider.load_from_path(CSS_FILE)
            else:
                css_provider.load_from_data(self.default_css().encode())
            screen = Gdk.Screen.get_default()
            if screen:
                Gtk.StyleContext.add_provider_for_screen(
                    screen, css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        except Exception as e:
            print(f"CSS warning: {e}", file=sys.stderr)

    def default_css(self) -> str:
        return """
        #display-switcher { background: rgba(0, 0, 0, 0.6); }
        #menu-container {
            background: rgba(14, 17, 26, 0.96);
            border: 1px solid rgba(120, 198, 235, 0.15);
            border-radius: 0;
            padding: 32px 40px;
        }
        #mode-button {
            background: rgba(255, 255, 255, 0.04);
            border: 1px solid rgba(120, 198, 235, 0.12);
            border-radius: 0;
            padding: 20px 20px 16px 20px;
            margin: 0 8px;
            min-width: 120px;
            min-height: 140px;
        }
        #mode-button.selected {
            background: rgba(106, 169, 201, 0.15);
            border: 2px solid rgba(120, 198, 235, 0.9);
        }
        #mode-button.current {
            border: 2px solid rgba(174, 0, 243, 0.7);
        }
        #mode-indicator {
            color: #ae00f3;
            font-size: 14px;
            font-weight: 700;
            margin-bottom: 4px;
            min-height: 14px;
        }
        #mode-icon { color: #ffffff; opacity: 0.6; }
        .emoji-icon { color: #ffffff; font-size: 40px; opacity: 0.8; }
        #mode-label { color: rgba(255, 255, 255, 0.55); font-size: 13px; font-weight: 600; }
        #mode-desc { color: rgba(255, 255, 255, 0.35); font-size: 10px; }
        #mode-button.selected #mode-label { color: #04ddff; font-weight: 700; }
        #mode-button.selected #mode-icon { color: #04ddff; opacity: 1; }
        #mode-button.selected #mode-desc { color: rgba(4, 221, 255, 0.7); }
        """

    def get_next_index(self) -> int:
        mode_ids = [m["id"] for m in MODES]
        if self.current_mode in mode_ids:
            return (mode_ids.index(self.current_mode) + 1) % len(MODES)
        return 0

    def build_ui(self):
        self.set_name("display-switcher")

        overlay = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        overlay.set_halign(Gtk.Align.FILL)
        overlay.set_valign(Gtk.Align.FILL)

        center = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        center.set_halign(Gtk.Align.CENTER)
        center.set_valign(Gtk.Align.CENTER)

        menu = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        menu.set_name("menu-container")

        self.buttons: List[ModeButton] = []
        for mode in MODES:
            btn = ModeButton(mode)
            self.buttons.append(btn)
            menu.pack_start(btn, False, False, 0)

        if self.buttons:
            self.buttons[self.selected_index].set_selected(True)
            for i, btn in enumerate(self.buttons):
                if btn.mode_id == self.current_mode:
                    btn.set_current(True)
                    break

        center.pack_start(menu, False, False, 0)
        overlay.pack_start(center, True, True, 0)
        self.add(overlay)

    def on_key_press(self, widget, event):
        keyval = event.keyval

        if keyval == Gdk.KEY_Escape:
            self.close()
            return True

        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            self.confirm()
            return True

        if keyval == Gdk.KEY_o and (event.state & Gdk.ModifierType.MOD4_MASK):
            self.cycle()
            self.reset_timer()
            return True

        self.reset_timer()
        return True

    def on_cycle_signal(self, signum, frame):
        GLib.idle_add(self._cycle_and_reset)

    def _cycle_and_reset(self):
        self.cycle()
        self.reset_timer()
        return False

    def cycle(self):
        if not self.buttons:
            return
        self.buttons[self.selected_index].set_selected(False)
        self.selected_index = (self.selected_index + 1) % len(self.buttons)
        self.buttons[self.selected_index].set_selected(True)

    def confirm(self):
        if not self.buttons:
            return
        selected = self.buttons[self.selected_index].mode_id
        self.close()
        try:
            # Write cooldown timestamp to prevent rapid re-invocation
            with open(COOLDOWN_FILE, 'w') as f:
                f.write(str(time.time()))
            script = os.path.expanduser("~/.local/bin/display-apply.sh")
            subprocess.Popen([script, selected], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as e:
            print(f"Error applying mode: {e}", file=sys.stderr)

    def reset_timer(self):
        if self.timeout_id is not None:
            GLib.source_remove(self.timeout_id)
        self.timeout_id = GLib.timeout_add_seconds(TIMEOUT_SECONDS, self.on_timeout)

    def on_timeout(self):
        self.close()
        return False

    def on_destroy(self, widget):
        if self.timeout_id is not None:
            GLib.source_remove(self.timeout_id)
            self.timeout_id = None


def check_instance():
    # Check cooldown to prevent rapid re-invocation
    if os.path.exists(COOLDOWN_FILE):
        try:
            with open(COOLDOWN_FILE, 'r') as f:
                last_confirm = float(f.read().strip())
            elapsed = time.time() - last_confirm
            if elapsed < COOLDOWN_SECONDS:
                print(f"Cooldown active ({COOLDOWN_SECONDS - elapsed:.1f}s remaining)", file=sys.stderr)
                return False, PID_FILE
        except (ValueError, OSError):
            pass

    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE, 'r') as f:
                old_pid = int(f.read().strip())
            os.kill(old_pid, 0)
            os.kill(old_pid, signal.SIGUSR1)
            return False, PID_FILE
        except (ValueError, ProcessLookupError, OSError):
            pass

    with open(PID_FILE, 'w') as f:
        f.write(str(os.getpid()))
    return True, PID_FILE


def prewarm():
    """Prewarm GTK3 imports so first Super+O is instant."""
    try:
        # Only warm icon theme if a display is available
        screen = Gdk.Screen.get_default()
        if screen:
            Gtk.IconTheme.get_for_screen(screen)
        print("Display switcher ready", file=sys.stderr)
    except Exception as e:
        print(f"Prewarm warning: {e}", file=sys.stderr)


def cleanup(pid_file):
    if os.path.exists(pid_file):
        os.remove(pid_file)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--prewarm":
        prewarm()
        sys.exit(0)

    is_new, pid_file = check_instance()
    if not is_new:
        sys.exit(0)

    try:
        app = DisplaySwitcher()
        app.connect("destroy", lambda w: cleanup(pid_file))
        Gtk.main()
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        cleanup(pid_file)
        sys.exit(1)


if __name__ == "__main__":
    main()
