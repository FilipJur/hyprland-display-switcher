#!/usr/bin/env python3
"""Hyprland Display Switcher - monitor, CS2, and TV modes."""

import os
import signal
import subprocess
import sys
from typing import Any, Dict, List

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")

try:
    gi.require_version("GtkLayerShell", "0.1")
    from gi.repository import GtkLayerShell

    HAS_LAYER_SHELL = True
except (ValueError, ImportError):
    HAS_LAYER_SHELL = False

from gi.repository import Gdk, GLib, Gtk

CSS_FILE = os.path.expanduser("~/.config/hypr/display-switcher.css")
PID_FILE = os.path.expanduser("~/.local/state/display-switcher.pid")
APPLIER_SCRIPT = os.path.expanduser("~/.local/bin/display-apply.sh")
TIMEOUT_SECONDS = 3

MODES: List[Dict[str, Any]] = [
    {
        "id": "monitor",
        "name": "Monitor",
        "icon": "video-display-symbolic",
        "desc": "3440×1440 · SDR",
    },
    {
        "id": "cs2",
        "name": "CS2",
        "icon": "steam_icon_730",
        "desc": "1080p · 75 Hz · 16:9",
    },
    {
        "id": "cs2-2k",
        "name": "CS2 2K",
        "icon": "input-gaming-symbolic",
        "desc": "1440p · 75 Hz · 16:9",
    },
    {
        "id": "tv",
        "name": "TV",
        "icon": "tv-symbolic",
        "desc": "4K · 144 Hz · HDR · VRR",
    },
]


class ModeButton(Gtk.Box):
    def __init__(self, mode_data: Dict[str, Any]):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.mode_id = mode_data["id"]

        self.set_name("mode-button")
        self.set_size_request(136, 140)
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
            for edge in [
                GtkLayerShell.Edge.TOP,
                GtkLayerShell.Edge.BOTTOM,
                GtkLayerShell.Edge.LEFT,
                GtkLayerShell.Edge.RIGHT,
            ]:
                GtkLayerShell.set_anchor(self, edge, True)
                GtkLayerShell.set_margin(self, edge, 0)
        else:
            self.set_type_hint(Gdk.WindowTypeHint.SPLASHSCREEN)

        self.load_css()

        self.current_mode = "unknown"
        self.selected_index = self.get_next_index()
        self.selection_interacted = False
        self.status_process = None
        self.status_poll_id = None
        self.timeout_id = None

        self.build_ui()

        self.connect("key-press-event", self.on_key_press)
        self.connect("destroy", self.on_destroy)
        signal.signal(signal.SIGUSR1, self.on_cycle_signal)

        self.show_all()
        self.request_status()
        self.reset_timer()

    def request_status(self):
        """Read the applier's status without blocking the GTK main loop."""
        try:
            self.status_process = subprocess.Popen(
                [APPLIER_SCRIPT, "status"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except (OSError, subprocess.SubprocessError) as e:
            print(f"Error checking display status: {e}", file=sys.stderr)
            self.set_current_mode("unknown")
            return

        self.status_poll_id = GLib.timeout_add(50, self.poll_status)

    def poll_status(self):
        process = self.status_process
        if process is None:
            self.status_poll_id = None
            return False
        if process.poll() is None:
            return True

        try:
            stdout, stderr = process.communicate()
        except (OSError, subprocess.SubprocessError) as e:
            stdout = ""
            stderr = str(e)

        self.status_process = None
        self.status_poll_id = None
        if stderr and stderr.strip():
            print(stderr.rstrip(), file=sys.stderr)

        status = (stdout or "").strip() if process.returncode == 0 else "unknown"
        self.set_current_mode(status)
        return False

    def set_current_mode(self, mode: str):
        if mode not in {"monitor", "cs2", "cs2-2k", "tv"}:
            mode = "unknown"
        self.current_mode = mode

        for button in self.buttons:
            button.set_current(button.mode_id == mode)

        if not self.selection_interacted and self.buttons:
            self.buttons[self.selected_index].set_selected(False)
            self.selected_index = self.get_next_index()
            self.buttons[self.selected_index].set_selected(True)


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
                    screen, css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
                )
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
            min-width: 136px;
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
        self.selection_interacted = True
        self.buttons[self.selected_index].set_selected(False)
        self.selected_index = (self.selected_index + 1) % len(self.buttons)
        self.buttons[self.selected_index].set_selected(True)

    def confirm(self):
        if not self.buttons:
            return
        selected = self.buttons[self.selected_index].mode_id
        self.close()
        try:
            subprocess.Popen([APPLIER_SCRIPT, selected], stdout=subprocess.DEVNULL)
        except Exception as e:
            print(f"Error applying mode: {e}", file=sys.stderr)

    def reset_timer(self):
        if self.timeout_id is not None:
            GLib.source_remove(self.timeout_id)
        self.timeout_id = GLib.timeout_add_seconds(TIMEOUT_SECONDS, self.on_timeout)

    def on_timeout(self):
        self.timeout_id = None
        self.close()
        return False

    def on_destroy(self, widget):
        if self.timeout_id is not None:
            GLib.source_remove(self.timeout_id)
            self.timeout_id = None
        Gtk.main_quit()


def check_instance():
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE, "r") as f:
                old_pid = int(f.read().strip())
            os.kill(old_pid, 0)
            os.kill(old_pid, signal.SIGUSR1)
            return False, PID_FILE
        except (ValueError, ProcessLookupError, OSError):
            pass

    with open(PID_FILE, "w") as f:
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
