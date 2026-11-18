#!/usr/bin/env python3
"""Hyprland Display Switcher - terminal-style overlay for monitor, CS2 and TV modes.

A CLI-flavoured panel groups the modes by display: an uppercase group heading
with its device, then one row per mode with aligned number/name/spec columns and
a status tag. Rows whose display is not connected (per
`display-apply.sh connected`) are dimmed and skipped when moving; the group
heading carries the reason. Confirmed modes run detached from the overlay; a
failed apply raises a desktop notification with the applier's error.
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

# Display role each group needs, as reported by `display-apply.sh connected`.
GROUPS: List[Dict[str, Any]] = [
    {
        "role": "monitor",
        "label": "MONITOR",
        "title": "Monitor",
        "device": "PHL 345E2 · DP",
        "modes": [
            {"id": "monitor", "name": "Desktop", "spec": "3440×1440 · 75 Hz · SDR"},
            {"id": "cs2", "name": "CS2", "spec": "1080p · 75 Hz · 16:9"},
        ],
    },
    {
        "role": "tv",
        "label": "TV",
        "title": "TV",
        "device": "Philips UHDTV · HDMI",
        "modes": [
            {"id": "tv", "name": "HDR · VRR", "spec": "4K · 144 Hz"},
            {"id": "tv-alt", "name": "HDR", "spec": "4K · 144 Hz · VRR off"},
        ],
    },
]

# Flat row order (digits 1-4); navigation, selection and apply are row-based.
ROWS: List[Dict[str, Any]] = [
    {
        "id": mode["id"],
        "name": mode["name"],
        "spec": mode["spec"],
        "role": group["role"],
        "group_title": group["title"],
    }
    for group in GROUPS
    for mode in group["modes"]
]

# Status tokens the applier may report that have no row of their own.
STATUS_MODES = {row["id"] for row in ROWS} | {"cs2-2k"}

# Runs the applier detached from the overlay; on failure notifies with its last
# stderr line (log prefix stripped) and keeps the applier's exit code.
# $0 = applier script, $1 = mode id, $2 = notification name.
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


class GroupHeader(Gtk.Box):
    """Uppercase display heading: label, device and the reason it is unavailable."""

    def __init__(self, group: Dict[str, Any]):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.role = group["role"]
        self.set_name("group-header")

        label = Gtk.Label(label=group["label"])
        label.set_name("group-label")
        label.set_xalign(0.0)

        device = Gtk.Label(label=group["device"])
        device.set_name("group-device")
        device.set_xalign(0.0)

        self.status = Gtk.Label(label="")
        self.status.set_name("group-status")
        self.status.set_xalign(1.0)
        self.status.set_hexpand(True)

        self.pack_start(label, False, False, 0)
        self.pack_start(device, False, False, 0)
        self.pack_end(self.status, True, True, 0)

    def set_available(self, available: bool):
        self.status.set_text("" if available else "not connected")


class ModeRow(Gtk.Box):
    """One menu row: number, marker, mode name, spec and status tag."""

    def __init__(
        self, row_data: Dict[str, Any], number: int, size_groups: List[Gtk.SizeGroup]
    ):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.mode_id = row_data["id"]
        self._current = False
        self._available = True

        self.set_name("mode-row")

        self.number = self._make_label(str(number), "row-number")
        self.number.set_width_chars(1)
        self.marker = self._make_label(" ", "row-marker")
        self.marker.set_width_chars(1)
        self.name = self._make_label(row_data["name"], "row-name")
        # Reserve a ~12-char name column so specs never read as part of the name.
        self.name.set_width_chars(12)
        self.spec = self._make_label(row_data["spec"], "row-spec")
        self.status = self._make_label("", "row-status")
        self.status.set_xalign(1.0)
        self.status.set_hexpand(True)

        # Status is not size-grouped: it takes the rest of the row and right-aligns
        # against the row padding, so every tag ends on the same edge.
        for column, label in enumerate(
            (self.number, self.marker, self.name, self.spec)
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

    def _sync_status(self):
        context = self.status.get_style_context()
        if self._current:
            self.status.set_text("● active")
            context.add_class("tag-active")
        else:
            self.status.set_text("")
            context.remove_class("tag-active")


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
        self.group_headers: List[GroupHeader] = []
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

    def is_available_role(self, role: str) -> bool:
        """Unknown availability (not queried yet, or discovery failed) counts as available."""
        if self.connected_roles is None:
            return True
        return role in self.connected_roles

    def is_available(self, index: int) -> bool:
        return self.is_available_role(ROWS[index]["role"])

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
        for header in self.group_headers:
            header.set_available(self.is_available_role(header.role))
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

    def describe_mode(self, mode: str) -> str:
        """Return "Monitor · Desktop" for a row, the bare token otherwise (cs2-2k)."""
        for row in ROWS:
            if row["id"] == mode:
                return f"{row['group_title']} · {row['name']}"
        return mode

    def set_current_mode(self, mode: str):
        if mode not in STATUS_MODES:
            mode = "unknown"
        self.current_mode = mode
        self.active_label.set_text(f"active: {self.describe_mode(mode)}")

        for row in self.rows:
            row.set_current(row.mode_id == mode)

        self.refresh_selection()

    def refresh_selection(self):
        if not self.selection_interacted and self.rows:
            self.set_selected_index(self.get_next_index())

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
    font-family: "IBM Plex Mono", "JetBrainsMono Nerd Font", "DejaVu Sans Mono", monospace;
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
    font-weight: 600;
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

#prompt-mode {
    color: @term_accent;
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

/* ── Group heading: uppercase label · device · not connected ── */
#group-header {
    margin: 12px 0 4px 0;
}

#group-label {
    color: @term_muted;
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 2px;
}

#group-device {
    color: @term_muted;
    font-size: 11px;
}

#group-status {
    color: @term_error;
    font-size: 11px;
}

/* ── Mode rows ── */
#mode-row {
    background: @term_row;
    border: 1px solid @term_border;
    border-left: 3px solid transparent;
    border-radius: 0;
    padding: 6px 10px;
    margin: 2px 0 2px 16px;
}

#mode-row:hover {
    background: @term_row_hover;
}

#mode-row.selected {
    background: rgba(4, 221, 255, 0.08);
    border-color: rgba(4, 221, 255, 0.35);
    border-left: 3px solid @term_accent;
}

#row-number {
    color: @term_muted;
    font-size: 11px;
}

#row-marker {
    color: @term_accent;
    font-size: 13px;
    font-weight: 700;
}

#row-name {
    color: @term_text;
    font-size: 13px;
    font-weight: 600;
}

#row-spec {
    color: @term_muted;
    font-size: 13px;
}

#mode-row.selected #row-name {
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

/* ── Unavailable rows: dimmed, never look selectable ── */
#mode-row.unavailable,
#mode-row.unavailable:hover,
#mode-row.unavailable.selected {
    background: rgba(28, 27, 25, 0.45);
    border-color: @term_border;
    border-left: 3px solid transparent;
}

#mode-row.unavailable #row-number,
#mode-row.unavailable #row-marker,
#mode-row.unavailable #row-name,
#mode-row.unavailable #row-spec,
#mode-row.unavailable.selected #row-name {
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
        mode_ids = [row["id"] for row in ROWS]
        if self.current_mode in mode_ids:
            base = (mode_ids.index(self.current_mode) + 1) % len(ROWS)
        else:
            base = 0
        for step in range(len(ROWS)):
            candidate = (base + step) % len(ROWS)
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
        title = Gtk.Label(label="Display switcher")
        title.set_name("term-title")
        title.set_xalign(0.0)
        self.active_label = Gtk.Label(
            label=f"active: {self.describe_mode(self.current_mode)}"
        )
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
        self.prompt_mode = Gtk.Label(label="")
        self.prompt_mode.set_name("prompt-mode")
        self.prompt_mode.set_xalign(0.0)
        self.cursor = Gtk.Label(label="▌")
        self.cursor.set_name("prompt-cursor")
        self.cursor.set_xalign(0.0)
        prompt_row.pack_start(prompt, False, False, 0)
        prompt_row.pack_start(self.prompt_mode, False, False, 0)
        prompt_row.pack_start(self.cursor, False, False, 0)

        size_groups = [
            Gtk.SizeGroup(mode=Gtk.SizeGroupMode.HORIZONTAL) for _ in range(4)
        ]
        rows_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        rows_box.set_name("mode-list")
        for group in GROUPS:
            header_row = GroupHeader(group)
            self.group_headers.append(header_row)
            rows_box.pack_start(header_row, False, False, 0)
            for mode in group["modes"]:
                row = ModeRow(mode, len(self.rows) + 1, size_groups)
                self.rows.append(row)
                rows_box.pack_start(row, False, False, 0)

        footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        footer.set_name("footer")
        hints = Gtk.Label(label="↑↓ move · 1–4 jump · enter apply · esc cancel")
        hints.set_name("footer-hints")
        hints.set_xalign(0.0)
        self.countdown = Gtk.Label(label="")
        self.countdown.set_name("countdown")
        self.countdown.set_xalign(1.0)
        self.countdown.set_hexpand(True)
        footer.pack_start(hints, False, False, 0)
        footer.pack_end(self.countdown, True, True, 0)

        panel.pack_start(header, False, False, 0)
        panel.pack_start(prompt_row, False, False, 0)
        panel.pack_start(rows_box, False, False, 0)
        panel.pack_start(footer, False, False, 0)

        center.pack_start(panel, False, False, 0)
        overlay.pack_start(center, True, True, 0)
        self.add(overlay)

        for row in self.rows:
            row.set_current(row.mode_id == self.current_mode)
        self.refresh_availability()

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
        self.update_prompt()

    def update_prompt(self):
        self.prompt_mode.set_text(f" {ROWS[self.selected_index]['id']}")

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
        mode = ROWS[self.selected_index]
        name = f"{mode['group_title']} · {mode['name']}"
        self.close()
        try:
            subprocess.Popen(
                ["sh", "-c", APPLY_WRAPPER, APPLIER_SCRIPT, mode["id"], name],
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
