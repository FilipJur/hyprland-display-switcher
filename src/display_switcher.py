#!/usr/bin/env python3
"""Hyprland Display Switcher - terminal-style overlay for monitor, CS2 and TV modes.

A CLI-flavoured panel lists one row per mode with aligned id/device/spec columns
and a status tag. Rows whose display is not connected (per
`display-apply.sh connected`) are dimmed and skipped when moving. Confirmed
modes run detached from the overlay; a failed apply raises a desktop
notification with the applier's error.
"""

import math
import os
import signal
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Set

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
CURSOR_BLINK_MS = 530

# Display role each mode needs, as reported by `display-apply.sh connected`.
MODE_ROLES = {
    "monitor": "monitor",
    "cs2": "monitor",
    "cs2-2k": "monitor",
    "tv": "tv",
    "tv-alt": "tv",
}

# Runs the applier detached from the overlay; on failure notifies with its last
# stderr line (log prefix stripped) and keeps the applier's exit code.
# $0 = applier script, $1 = mode id, $2 = mode name.
APPLY_WRAPPER = r"""
err=$("$0" "$1" 2>&1 >/dev/null)
rc=$?
if [ "$rc" -ne 0 ]; then
    msg=$(printf '%s\n' "$err" | tail -n 1 | sed 's/^\[[^]]*\] //')
    [ -n "$msg" ] || msg="exit code $rc"
    notify-send -a "Display switcher" -u critical "$2 failed" "$msg" || true
fi
exit "$rc"
"""

MODES: List[Dict[str, Any]] = [
    {
        "id": "monitor",
        "name": "Monitor",
        "device": "PHL 345E2",
        "desc": "3440×1440 · SDR",
    },
    {
        "id": "cs2",
        "name": "CS2",
        "device": "PHL 345E2",
        "desc": "1080p · 75 Hz · 16:9",
    },
    {
        "id": "tv",
        "name": "TV",
        "device": "UHDTV",
        "desc": "4K · 144 Hz · HDR · VRR",
    },
    {
        "id": "tv-alt",
        "name": "TV Alt",
        "device": "UHDTV",
        "desc": "4K · 144 Hz · HDR · no VRR",
    },
]


class ModeRow(Gtk.Box):
    """One menu row: marker, mode id, device, spec and status tag."""

    def __init__(self, mode_data: Dict[str, Any], size_groups: List[Gtk.SizeGroup]):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.mode_id = mode_data["id"]
        self._current = False
        self._available = True

        self.set_name("mode-row")

        self.marker = self._make_label(" ", "row-marker")
        self.marker.set_width_chars(1)
        self.id_label = self._make_label(mode_data["id"], "row-id")
        self.id_label.set_width_chars(9)
        self.device = self._make_label(mode_data["device"], "row-device")
        self.device.set_width_chars(9)
        self.spec = self._make_label(mode_data["desc"], "row-spec")
        self.status = self._make_label("", "row-status")
        self.status.set_xalign(1.0)
        self.status.set_hexpand(True)

        # Status is not size-grouped: it takes the rest of the row and right-aligns
        # against the row padding, so every tag ends on the same edge.
        for column, label in enumerate(
            (self.marker, self.id_label, self.device, self.spec)
        ):
            size_groups[column].add_widget(label)
            self.pack_start(label, False, False, 0)
        self.pack_end(self.status, True, True, 0)

    @staticmethod
    def _make_label(text: str, name: str) -> Gtk.Label:
        label = Gtk.Label(label=text)
        label.set_name(name)
        label.set_xalign(0.0)
        return label

    def set_selected(self, selected: bool):
        self.marker.set_text("›" if selected else " ")
        if selected:
            self.get_style_context().add_class("selected")
        else:
            self.get_style_context().remove_class("selected")

    def set_current(self, current: bool):
        self._current = current
        self._sync_status()

    def set_available(self, available: bool):
        self._available = available
        if available:
            self.get_style_context().remove_class("unavailable")
        else:
            self.get_style_context().add_class("unavailable")
        self._sync_status()

    def _sync_status(self):
        """Unavailable wins over active: a row that is gone must say so."""
        context = self.status.get_style_context()
        if not self._available:
            self.status.set_text("not connected")
            context.add_class("tag-error")
            context.remove_class("tag-active")
        elif self._current:
            self.status.set_text("● active")
            context.add_class("tag-active")
            context.remove_class("tag-error")
        else:
            self.status.set_text("")
            context.remove_class("tag-active")
            context.remove_class("tag-error")


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
        self.connected_roles: Optional[Set[str]] = None
        self.selection_interacted = False
        self.status_process = None
        self.status_poll_id = None
        self.connected_process = None
        self.connected_poll_id = None
        self.timeout_id = None
        self.cursor_timer_id = None
        self.cursor_dimmed = False
        self.deadline = 0.0
        self.rows: List[ModeRow] = []
        self.selected_index = self.get_next_index()

        self.build_ui()

        self.connect("key-press-event", self.on_key_press)
        self.connect("destroy", self.on_destroy)
        signal.signal(signal.SIGUSR1, self.on_cycle_signal)

        self.show_all()
        self.request_status()
        self.request_connected()
        self.reset_timer()
        self.cursor_timer_id = GLib.timeout_add(CURSOR_BLINK_MS, self.on_cursor_blink)

    def is_available(self, index: int) -> bool:
        """Unknown availability (not queried yet, or discovery failed) counts as available."""
        if self.connected_roles is None:
            return True
        return MODE_ROLES.get(MODES[index]["id"]) in self.connected_roles

    def request_connected(self):
        """Read the connected displays without blocking the GTK main loop."""
        try:
            self.connected_process = subprocess.Popen(
                [APPLIER_SCRIPT, "connected"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except (OSError, subprocess.SubprocessError) as e:
            print(f"Error checking connected displays: {e}", file=sys.stderr)
            return

        self.connected_poll_id = GLib.timeout_add(50, self.poll_connected)

    def poll_connected(self):
        process = self.connected_process
        if process is None:
            self.connected_poll_id = None
            return False
        if process.poll() is None:
            return True

        try:
            stdout, stderr = process.communicate()
        except (OSError, subprocess.SubprocessError) as e:
            stdout = ""
            stderr = str(e)

        self.connected_process = None
        self.connected_poll_id = None
        if stderr and stderr.strip():
            print(stderr.rstrip(), file=sys.stderr)

        if process.returncode == 0:
            self.connected_roles = set((stdout or "").split())
        else:
            self.connected_roles = None

        self.refresh_availability()
        return False

    def refresh_availability(self):
        if not self.rows:
            return
        for i, row in enumerate(self.rows):
            row.set_available(self.is_available(i))
        self.refresh_selection()

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
        if mode not in {"monitor", "cs2", "cs2-2k", "tv", "tv-alt"}:
            mode = "unknown"
        self.current_mode = mode
        self.active_label.set_text(f"active: {mode}")

        for row in self.rows:
            row.set_current(row.mode_id == mode)

        self.refresh_selection()

    def refresh_selection(self):
        if not self.selection_interacted and self.rows:
            self.rows[self.selected_index].set_selected(False)
            self.selected_index = self.get_next_index()
            self.rows[self.selected_index].set_selected(True)

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
/* display-switcher.css - Terminal theme */

@define-color term_panel #141312;
@define-color term_row #1c1b19;
@define-color term_row_hover #232220;
@define-color term_border #2e2c29;
@define-color term_text #e6e1d6;
@define-color term_muted #7d776d;
@define-color term_dim #55504a;
@define-color term_accent #04ddff;
@define-color term_error #cf7a5c;

/* ── Backdrop ── */
#display-switcher {
    background: rgba(0, 0, 0, 0.62);
}

#display-switcher label {
    font-family: "CaskaydiaCove Nerd Font Mono", "JetBrains Mono", "DejaVu Sans Mono", monospace;
}

/* ── Panel ── */
#terminal-panel {
    background: @term_panel;
    border: 1px solid @term_border;
    border-radius: 2px;
    padding: 18px 22px;
    box-shadow: 0 12px 32px rgba(0, 0, 0, 0.55);
    min-width: 640px;
}

/* ── Header: title · active mode ── */
#terminal-header {
    border-bottom: 1px solid @term_border;
    padding-bottom: 10px;
}

#term-title {
    color: @term_text;
    font-size: 16px;
    font-weight: 700;
}

#term-active {
    color: @term_muted;
    font-size: 11px;
}

/* ── Prompt line + blinking block cursor ── */
#prompt-row {
    padding: 4px 0 8px 0;
}

#prompt-text {
    color: @term_text;
    font-size: 16px;
    font-weight: 600;
}

#prompt-cursor {
    color: @term_accent;
    font-size: 16px;
    margin-left: 1px;
}

#prompt-cursor.off {
    opacity: 0;
}

/* ── Mode rows ── */
#mode-row {
    background: @term_row;
    border: 1px solid @term_border;
    border-left: 3px solid transparent;
    border-radius: 0;
    padding: 7px 10px;
}

#mode-row:hover {
    background: @term_row_hover;
}

#mode-row.selected {
    background: rgba(4, 221, 255, 0.08);
    border-color: rgba(4, 221, 255, 0.35);
    border-left: 3px solid @term_accent;
}

#row-marker {
    color: @term_accent;
    font-size: 13px;
    font-weight: 700;
}

#row-id {
    color: @term_text;
    font-size: 13px;
    font-weight: 600;
}

#row-device,
#row-spec {
    color: @term_muted;
    font-size: 13px;
}

#mode-row.selected #row-id {
    color: @term_accent;
}

/* ── Status tag ── */
#row-status {
    background-color: transparent;
    background-image: none;
    border: none;
    color: @term_muted;
    font-size: 11px;
}

#row-status.tag-active {
    color: @term_accent;
}

#row-status.tag-error {
    color: @term_error;
}

/* ── Unavailable rows: dimmed, never look selectable ── */
#mode-row.unavailable,
#mode-row.unavailable:hover,
#mode-row.unavailable.selected {
    background: rgba(28, 27, 25, 0.45);
    border-color: @term_border;
    border-left: 3px solid transparent;
}

#mode-row.unavailable #row-marker,
#mode-row.unavailable #row-id,
#mode-row.unavailable #row-device,
#mode-row.unavailable #row-spec,
#mode-row.unavailable.selected #row-id {
    color: @term_dim;
}

/* ── Footer: key hints · countdown ── */
#footer {
    border-top: 1px solid @term_border;
    padding-top: 10px;
}

#footer-hints {
    color: @term_muted;
    font-size: 13px;
}

#countdown {
    color: @term_muted;
    font-size: 11px;
}
"""

    def get_next_index(self) -> int:
        mode_ids = [m["id"] for m in MODES]
        if self.current_mode in mode_ids:
            base = (mode_ids.index(self.current_mode) + 1) % len(MODES)
        else:
            base = 0
        for step in range(len(MODES)):
            candidate = (base + step) % len(MODES)
            if self.is_available(candidate):
                return candidate
        return base

    def build_ui(self):
        self.set_name("display-switcher")

        overlay = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        overlay.set_halign(Gtk.Align.FILL)
        overlay.set_valign(Gtk.Align.FILL)

        center = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        center.set_halign(Gtk.Align.CENTER)
        center.set_valign(Gtk.Align.CENTER)

        panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        panel.set_name("terminal-panel")
        panel.set_halign(Gtk.Align.CENTER)
        panel.set_valign(Gtk.Align.CENTER)

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        header.set_name("terminal-header")
        title = Gtk.Label(label="display-switcher")
        title.set_name("term-title")
        title.set_xalign(0.0)
        self.active_label = Gtk.Label(label=f"active: {self.current_mode}")
        self.active_label.set_name("term-active")
        self.active_label.set_xalign(1.0)
        self.active_label.set_hexpand(True)
        header.pack_start(title, False, False, 0)
        header.pack_start(self.active_label, True, True, 0)

        prompt_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        prompt_row.set_name("prompt-row")
        prompt = Gtk.Label(label="$ display-apply.sh")
        prompt.set_name("prompt-text")
        prompt.set_xalign(0.0)
        self.cursor = Gtk.Label(label="▌")
        self.cursor.set_name("prompt-cursor")
        self.cursor.set_xalign(0.0)
        prompt_row.pack_start(prompt, False, False, 0)
        prompt_row.pack_start(self.cursor, False, False, 0)

        size_groups = [
            Gtk.SizeGroup(mode=Gtk.SizeGroupMode.HORIZONTAL) for _ in range(4)
        ]
        rows_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        rows_box.set_name("mode-list")
        for mode in MODES:
            row = ModeRow(mode, size_groups)
            self.rows.append(row)
            rows_box.pack_start(row, False, False, 0)

        footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        footer.set_name("footer")
        hints = Gtk.Label(label="↑↓/super+o move · enter apply · esc cancel")
        hints.set_name("footer-hints")
        hints.set_xalign(0.0)
        self.countdown = Gtk.Label(label="")
        self.countdown.set_name("countdown")
        self.countdown.set_xalign(1.0)
        self.countdown.set_hexpand(True)
        footer.pack_start(hints, False, False, 0)
        footer.pack_start(self.countdown, True, True, 0)

        panel.pack_start(header, False, False, 0)
        panel.pack_start(prompt_row, False, False, 0)
        panel.pack_start(rows_box, False, False, 0)
        panel.pack_start(footer, False, False, 0)

        center.pack_start(panel, False, False, 0)
        overlay.pack_start(center, True, True, 0)
        self.add(overlay)

        self.refresh_availability()
        for row in self.rows:
            row.set_current(row.mode_id == self.current_mode)

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

        if keyval in (Gdk.KEY_Up, Gdk.KEY_k):
            self.move(-1)
            self.reset_timer()
            return True

        if keyval in (Gdk.KEY_Down, Gdk.KEY_j):
            self.move(1)
            self.reset_timer()
            return True

        if Gdk.KEY_1 <= keyval <= Gdk.KEY_9:
            self.apply_row(keyval - Gdk.KEY_1)
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
        self.move(1)

    def move(self, delta: int):
        """Move the selection by delta rows, skipping unavailable ones (wraps)."""
        if not self.rows:
            return
        self.selection_interacted = True
        count = len(self.rows)
        for step in range(1, count + 1):
            candidate = (self.selected_index + delta * step) % count
            if self.is_available(candidate):
                self.set_selected_index(candidate)
                return

    def set_selected_index(self, index: int):
        self.rows[self.selected_index].set_selected(False)
        self.selected_index = index
        self.rows[self.selected_index].set_selected(True)

    def apply_row(self, index: int):
        """Number-key shortcut: select and apply a row; unavailable rows do nothing."""
        if not (0 <= index < len(self.rows)) or not self.is_available(index):
            self.reset_timer()
            return
        self.selection_interacted = True
        self.set_selected_index(index)
        self.confirm()

    def confirm(self):
        if not self.rows:
            return
        if not self.is_available(self.selected_index):
            self.reset_timer()
            return
        mode = MODES[self.selected_index]
        self.close()
        try:
            subprocess.Popen(
                ["sh", "-c", APPLY_WRAPPER, APPLIER_SCRIPT, mode["id"], mode["name"]],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except Exception as e:
            print(f"Error applying mode: {e}", file=sys.stderr)

    def reset_timer(self):
        self.remove_timer()
        self.deadline = time.monotonic() + TIMEOUT_SECONDS
        self.countdown.set_text(f"closing in {TIMEOUT_SECONDS}s")
        self.timeout_id = GLib.timeout_add_seconds(1, self.on_tick)

    def remove_timer(self):
        if self.timeout_id is not None:
            GLib.source_remove(self.timeout_id)
            self.timeout_id = None

    def on_tick(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            self.timeout_id = None
            self.close()
            return False
        self.countdown.set_text(f"closing in {math.ceil(remaining)}s")
        return True

    def on_cursor_blink(self):
        self.cursor_dimmed = not self.cursor_dimmed
        context = self.cursor.get_style_context()
        if self.cursor_dimmed:
            context.add_class("off")
        else:
            context.remove_class("off")
        return True

    def on_destroy(self, widget):
        self.remove_timer()
        if self.cursor_timer_id is not None:
            GLib.source_remove(self.cursor_timer_id)
            self.cursor_timer_id = None
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
