#!/usr/bin/env python3
"""Hyprland Display Switcher - terminal-style per-display settings overlay.

Top level is the display: each display gets a frame whose legend names it, and
inside sit the general settings the hardware advertises - resolution, refresh,
VRR and HDR when capable, scale. Values resolve from the remembered settings
file, then the display's current state, then its defaults, and only values that
differ from the defaults are put on the command line (shown in the prompt).
Displays are probed with `display-apply.sh caps`; applies run detached from the
overlay and a failure raises a notification with the applier's error.
"""

import json
import math
import os
import signal
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

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
SETTINGS_FILE = os.path.expanduser("~/.local/state/display-switcher-settings.json")
TIMEOUT_SECONDS = 5
CURSOR_BLINK_MS = 530

DISPLAY_ROLES = ("monitor", "tv")
DISPLAY_NAMES = {"monitor": "Monitor", "tv": "TV"}

# Wide tracking for chrome labels, in Pango units (~2px). Applied as a Pango span
# attribute so the uppercase hierarchy lever does not depend on GTK3 CSS support.
CHROME_TRACKING = 2048


def chrome_markup(text: str) -> str:
    return (
        f'<span letter_spacing="{CHROME_TRACKING}">'
        f"{GLib.markup_escape_text(text)}</span>"
    )


def chrome_label(text: str, name: str) -> Gtk.Label:
    label = Gtk.Label()
    label.set_name(name)
    label.get_style_context().add_class("chrome")
    label.set_markup(chrome_markup(text))
    label.set_xalign(0.0)
    return label


def set_chrome_text(label: Gtk.Label, text: str):
    label.set_markup(chrome_markup(text))


# Runs the applier detached from the overlay; on failure notifies with its last
# stderr line (log prefix stripped) and keeps the applier's exit code.
# $0 = applier script, $1 = display name, remaining args = role + settings.
APPLY_WRAPPER = r"""
name=$1
shift
err=$("$0" "$@" 2>&1 >/dev/null)
rc=$?
if [ "$rc" -ne 0 ]; then
    msg=$(printf '%s\n' "$err" | tail -n 1 | sed 's/^\[[^]]*\] //')
    [ -n "$msg" ] || msg="exit code $rc"
    notify-send -a "Display switcher" -u critical "$name failed" "$msg" || true
fi
exit "$rc"
"""


def format_hz(hz: float) -> str:
    """144 Hz for integral rates, 74.98 Hz otherwise."""
    if abs(hz - round(hz)) < 0.01:
        return f"{round(hz)} Hz"
    return f"{hz:.2f} Hz"


def format_hz_arg(hz: float) -> str:
    if abs(hz - round(hz)) < 0.01:
        return str(round(hz))
    return f"{hz:.2f}"


def format_scale(scale: float) -> str:
    return f"{scale:g}"


def load_remembered() -> Dict[str, Any]:
    try:
        with open(SETTINGS_FILE, "r") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_remembered(data: Dict[str, Any]):
    try:
        os.makedirs(os.path.dirname(SETTINGS_FILE), exist_ok=True)
        tmp_file = f"{SETTINGS_FILE}.tmp"
        with open(tmp_file, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        os.replace(tmp_file, SETTINGS_FILE)
    except OSError as e:
        print(f"Error saving display settings: {e}", file=sys.stderr)


class SettingRow(Gtk.Box):
    """One setting line: tracked label, then a choice or a boolean state."""

    def __init__(
        self,
        key: str,
        label_text: str,
        label_size_group: Gtk.SizeGroup,
        choices: bool,
    ):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.key = key
        self.set_name("setting-row")

        self.label = chrome_label(label_text, "setting-label")
        self.label.set_width_chars(10)
        label_size_group.add_widget(self.label)
        self.pack_start(self.label, False, False, 0)

        self.value_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self.value_box.set_name("setting-value-box")
        self.value = Gtk.Label(label="")
        self.value.set_name("setting-value")
        self.value.set_xalign(0.0)
        if choices:
            self.value_box.pack_start(self._chevron("‹"), False, False, 0)
            self.value_box.pack_start(self.value, False, False, 0)
            self.value_box.pack_start(self._chevron("›"), False, False, 0)
        else:
            self.value_box.pack_start(self.value, False, False, 0)
        self.pack_start(self.value_box, False, False, 0)

    @staticmethod
    def _chevron(glyph: str) -> Gtk.Label:
        chevron = Gtk.Label(label=glyph)
        chevron.set_name("setting-chevron")
        chevron.set_xalign(0.0)
        return chevron

    def set_value(self, text: str):
        self.value.set_text(text)

    def set_focused(self, focused: bool):
        context = self.get_style_context()
        if focused:
            context.add_class("focused")
        else:
            context.remove_class("focused")


class DisplayView(Gtk.Frame):
    """One display frame: legend cut into the border, settings rows inside."""

    def __init__(self, role: str, display: Optional[Dict[str, Any]]):
        super().__init__()
        self.role = role
        self.display = display
        self.settings: Optional[Dict[str, Any]] = None
        self.rows: Dict[str, SettingRow] = {}

        self.set_name("display-frame")
        if display is not None and not display.get("connected"):
            self.get_style_context().add_class("disconnected")

        legend = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        legend.set_name("frame-legend")

        name = chrome_label(role.upper(), "legend-name")
        legend.pack_start(name, False, False, 0)

        device = Gtk.Label(label=self._device_text())
        device.set_name("legend-device")
        device.set_xalign(0.0)
        legend.pack_start(device, False, False, 0)

        spacer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        spacer.set_hexpand(True)
        legend.pack_start(spacer, True, True, 0)

        self.legend_note = Gtk.Label(label="")
        self.legend_note.set_name("legend-note")
        self.legend_note.set_no_show_all(True)
        self.legend_note.set_visible(False)
        legend.pack_start(self.legend_note, False, False, 0)

        self.legend_tag = chrome_label("ACTIVE", "legend-tag")
        self.legend_tag.set_no_show_all(True)
        self.legend_tag.set_visible(bool(display and display.get("enabled")))
        legend.pack_start(self.legend_tag, False, False, 0)

        self.set_label_widget(legend)

        if (
            display is not None
            and display.get("connected")
            and not display.get("hdr_capable")
        ):
            self.legend_note.set_text("SDR")
            self.legend_note.set_visible(True)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        body.set_name("frame-body")

        self.note = Gtk.Label(label="")
        self.note.set_name("frame-note")
        self.note.set_xalign(0.0)
        self.note.set_no_show_all(True)
        self.note.set_visible(False)
        body.pack_start(self.note, False, False, 0)

        self.rows_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        self.rows_box.set_name("setting-list")
        body.pack_start(self.rows_box, False, False, 0)

        self.add(body)

    def _device_text(self) -> str:
        if not self.display:
            return ""
        device = self.display.get("device") or ""
        transport = self.display.get("transport")
        if transport:
            return f"{device} │ {transport}" if device else transport
        return device

    def set_note(self, text: str, error: bool = False):
        self.note.set_text(text)
        context = self.note.get_style_context()
        if error:
            context.add_class("error")
        else:
            context.remove_class("error")
        self.note.set_visible(bool(text))

    def add_row(
        self,
        key: str,
        label: str,
        choices: bool,
        label_size_group: Gtk.SizeGroup,
    ):
        row = SettingRow(key, label, label_size_group, choices)
        self.rows[key] = row
        self.rows_box.pack_start(row, False, False, 0)


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

        self.caps: Optional[Dict[str, Any]] = None
        self.remembered: Dict[str, Any] = load_remembered()
        self.views: Dict[str, DisplayView] = {}
        self.focus_rows: List[Tuple[str, str]] = []
        self.focus_index: Optional[int] = None
        self.caps_process = None
        self.caps_poll_id = None
        self.timeout_id = None
        self.cursor_timer_id = None
        self.cursor_dimmed = False
        self.deadline = 0.0

        self.build_ui()

        self.connect("key-press-event", self.on_key_press)
        self.connect("destroy", self.on_destroy)
        signal.signal(signal.SIGUSR1, self.on_cycle_signal)

        self.show_all()
        self.rebuild(None)
        self.request_caps()
        self.reset_timer()
        self.cursor_timer_id = GLib.timeout_add(CURSOR_BLINK_MS, self.on_cursor_blink)

    # ------------------------------------------------------------- probing --

    def request_caps(self):
        """Read display capabilities without blocking the GTK main loop."""
        try:
            self.caps_process = subprocess.Popen(
                [APPLIER_SCRIPT, "caps"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except (OSError, subprocess.SubprocessError) as e:
            print(f"Error probing displays: {e}", file=sys.stderr)
            self.rebuild(None, failed=True)
            return

        self.caps_poll_id = GLib.timeout_add(50, self.poll_caps)

    def poll_caps(self):
        process = self.caps_process
        if process is None:
            self.caps_poll_id = None
            return False
        if process.poll() is None:
            return True

        try:
            stdout, stderr = process.communicate()
        except (OSError, subprocess.SubprocessError) as e:
            stdout = ""
            stderr = str(e)

        self.caps_process = None
        self.caps_poll_id = None
        if stderr and stderr.strip():
            print(stderr.rstrip(), file=sys.stderr)

        caps = None
        if process.returncode == 0:
            try:
                caps = json.loads(stdout or "")
            except ValueError:
                caps = None

        if isinstance(caps, dict) and isinstance(caps.get("displays"), list):
            self.rebuild(caps)
        else:
            self.rebuild(None, failed=True)
        return False

    # --------------------------------------------------------------- setup --

    def rebuild(self, caps: Optional[Dict[str, Any]], failed: bool = False):
        self.caps = caps
        for child in self.frames_box.get_children():
            child.destroy()
        self.views = {}
        self.focus_rows = []
        self.focus_index = None

        displays = caps.get("displays") if caps else None
        if not displays:
            note = "caps unavailable" if failed else "probing…"
            for role in DISPLAY_ROLES:
                view = DisplayView(role, None)
                view.set_note(note, error=failed)
                self.views[role] = view
                self.frames_box.pack_start(view, False, False, 0)
            self.header_active.set_markup(chrome_markup("ACTIVE · NONE"))
        else:
            for display in displays:
                role = display.get("role")
                if not role or role in self.views:
                    continue
                view = DisplayView(role, display)
                self.views[role] = view
                self.frames_box.pack_start(view, False, False, 0)
                if not display.get("connected"):
                    view.set_note("not connected")
                    continue
                view.settings = self.resolve_settings(display)
                for key in self.build_rows(view):
                    self.focus_rows.append((role, key))
            active = caps.get("active")
            set_chrome_text(
                self.header_active,
                f"ACTIVE · {str(active).upper()}"
                if active in self.views
                else "ACTIVE · NONE",
            )

        self.frames_box.show_all()
        self.apply_initial_focus()
        for role in self.views:
            self.refresh_view(role)
        self.update_prompt()

    def build_rows(self, view: DisplayView) -> List[str]:
        display = view.display or {}
        if not display.get("modes"):
            return []
        keys: List[Tuple[str, str, bool]] = [
            ("res", "RESOLUTION", True),
            ("hz", "REFRESH", True),
        ]
        if display.get("vrr_capable"):
            keys.append(("vrr", "VRR", False))
        if display.get("hdr_capable"):
            keys.append(("hdr", "HDR", False))
        if any(
            self._scales_for(display, mode.get("res"))
            for mode in display.get("modes") or []
        ):
            keys.append(("scale", "SCALE", True))
        for key, label, choices in keys:
            view.add_row(key, label, choices, self.label_size_group)
        return [key for key, _, _ in keys]

    # ------------------------------------------------------------ settings --

    def resolve_settings(self, display: Dict[str, Any]) -> Dict[str, Any]:
        role = display.get("role")
        for candidate in (
            self.remembered.get(role),
            display.get("current"),
            display.get("defaults"),
        ):
            settings = self.sanitize_settings(display, candidate)
            if settings is not None:
                return settings
        return self.fallback_settings(display)

    def sanitize_settings(
        self, display: Dict[str, Any], candidate: Any
    ) -> Optional[Dict[str, Any]]:
        if not isinstance(candidate, dict):
            return None
        modes = {
            mode.get("res"): mode.get("rates") or []
            for mode in display.get("modes") or []
        }
        res = candidate.get("res")
        if res not in modes:
            return None
        hz = candidate.get("hz")
        if not isinstance(hz, (int, float)):
            return None
        rate = next(
            (r for r in modes[res] if abs(r.get("hz", 0) - hz) <= 0.1), None
        )
        if rate is None:
            return None
        scale = candidate.get("scale")
        if not isinstance(scale, (int, float)):
            return None
        scales = self._scales_for(display, res)
        matched_scale = next((s for s in scales if abs(s - scale) <= 0.001), None)
        if matched_scale is None:
            return None
        return {
            "res": res,
            "hz": rate["hz"],
            "vrr": bool(candidate.get("vrr")) and bool(display.get("vrr_capable")),
            "hdr": bool(candidate.get("hdr")) and bool(display.get("hdr_capable")),
            "scale": matched_scale,
        }

    def fallback_settings(self, display: Dict[str, Any]) -> Dict[str, Any]:
        modes = display.get("modes") or []
        res = modes[0]["res"] if modes else ""
        rates = (modes[0].get("rates") or []) if modes else []
        scales = self._scales_for(display, res)
        return {
            "res": res,
            "hz": rates[0]["hz"] if rates else 0.0,
            "vrr": False,
            "hdr": False,
            "scale": scales[0] if scales else 1,
        }

    @staticmethod
    def _rates_for(display: Dict[str, Any], res: str) -> List[Dict[str, Any]]:
        for mode in display.get("modes") or []:
            if mode.get("res") == res:
                return mode.get("rates") or []
        return []

    @staticmethod
    def _scales_for(display: Dict[str, Any], res: str) -> List[float]:
        for mode in display.get("modes") or []:
            if mode.get("res") == res:
                return mode.get("scales") or []
        return []

    @staticmethod
    def _nearest_scale(scales: List[float], target: float) -> float:
        return min(scales, key=lambda scale: (abs(scale - target), scale))

    @classmethod
    def _rate_for(
        cls, display: Dict[str, Any], res: str, hz: float
    ) -> Optional[Dict[str, Any]]:
        for rate in cls._rates_for(display, res):
            if abs(rate.get("hz", 0) - hz) <= 0.1:
                return rate
        return None

    # --------------------------------------------------------------- focus --

    def focused(self) -> Optional[Tuple[str, str]]:
        if self.focus_index is None or not self.focus_rows:
            return None
        return self.focus_rows[self.focus_index]

    def focused_role(self) -> Optional[str]:
        current = self.focused()
        return current[0] if current else None

    def apply_initial_focus(self):
        """First connected, non-active display; the active one if that is all."""
        if not self.focus_rows:
            self.set_focus(None)
            return
        roles: List[str] = []
        for role, _ in self.focus_rows:
            if role not in roles:
                roles.append(role)
        active = (self.caps or {}).get("active", "unknown")
        target = next((role for role in roles if role != active), roles[0])
        index = next(i for i, (role, _) in enumerate(self.focus_rows) if role == target)
        self.set_focus(index)

    def set_focus(self, index: Optional[int]):
        if index is None or not self.focus_rows:
            self.focus_index = None
        else:
            self.focus_index = index % len(self.focus_rows)
        current = (
            self.focus_rows[self.focus_index] if self.focus_index is not None else None
        )
        for view in self.views.values():
            frame_context = view.get_style_context()
            if current is not None and current[0] == view.role:
                frame_context.add_class("focused")
            else:
                frame_context.remove_class("focused")
            for key, row in view.rows.items():
                row.set_focused(current is not None and current == (view.role, key))
        self.update_prompt()

    def move_focus(self, delta: int):
        if not self.focus_rows:
            return
        if self.focus_index is None:
            self.set_focus(0)
            return
        self.set_focus(self.focus_index + delta)

    def next_display(self):
        if not self.focus_rows:
            return
        roles: List[str] = []
        for role, _ in self.focus_rows:
            if role not in roles:
                roles.append(role)
        current = self.focused_role()
        if current in roles:
            target = roles[(roles.index(current) + 1) % len(roles)]
        else:
            target = roles[0]
        index = next(i for i, (role, _) in enumerate(self.focus_rows) if role == target)
        self.set_focus(index)

    # -------------------------------------------------------------- values --

    def refresh_view(self, role: str):
        view = self.views.get(role)
        if not view or not view.settings:
            return
        display = view.display or {}
        for key, row in view.rows.items():
            row.set_value(self.value_text(display, view.settings, key))

    def value_text(
        self, display: Dict[str, Any], settings: Dict[str, Any], key: str
    ) -> str:
        if key == "res":
            return settings["res"].replace("x", "×")
        if key == "hz":
            text = format_hz(settings["hz"])
            rate = self._rate_for(display, settings["res"], settings["hz"])
            custom = rate.get("custom") if rate else None
            return f"{text} · {custom}" if custom else text
        if key in ("vrr", "hdr"):
            return "[x]" if settings.get(key) else "[ ]"
        if key == "scale":
            return format_scale(settings["scale"])
        return ""

    def change_value(self, delta: int):
        current = self.focused()
        if current is None:
            return
        role, key = current
        view = self.views[role]
        display = view.display or {}
        settings = view.settings
        if not settings:
            return
        if key == "res":
            self.cycle_resolution(display, settings, delta)
        elif key == "hz":
            self.cycle_refresh(display, settings, delta)
        elif key in ("vrr", "hdr"):
            settings[key] = not settings[key]
        elif key == "scale":
            self.cycle_scale(display, settings, delta)
        self.refresh_view(role)
        self.update_prompt()

    def toggle_value(self):
        current = self.focused()
        if current is None or current[1] not in ("vrr", "hdr"):
            return
        role, key = current
        settings = self.views[role].settings
        if not settings:
            return
        settings[key] = not settings[key]
        self.refresh_view(role)
        self.update_prompt()

    def cycle_resolution(
        self, display: Dict[str, Any], settings: Dict[str, Any], delta: int
    ):
        resolutions = [mode.get("res") for mode in display.get("modes") or []]
        if settings.get("res") not in resolutions:
            return
        index = resolutions.index(settings["res"])
        new_res = resolutions[(index + delta) % len(resolutions)]
        rates = self._rates_for(display, new_res)
        if not rates:
            return
        keep = self._rate_for(display, new_res, settings.get("hz", 0))
        settings["res"] = new_res
        settings["hz"] = keep["hz"] if keep else rates[0]["hz"]
        scales = self._scales_for(display, new_res)
        current_scale = settings.get("scale", 0)
        if scales and not any(abs(s - current_scale) <= 0.001 for s in scales):
            settings["scale"] = self._nearest_scale(scales, current_scale)

    def cycle_refresh(
        self, display: Dict[str, Any], settings: Dict[str, Any], delta: int
    ):
        rates = self._rates_for(display, settings.get("res"))
        if not rates:
            return
        index = next(
            (
                i
                for i, rate in enumerate(rates)
                if abs(rate.get("hz", 0) - settings.get("hz", 0)) <= 0.1
            ),
            0,
        )
        settings["hz"] = rates[(index + delta) % len(rates)]["hz"]

    def cycle_scale(
        self, display: Dict[str, Any], settings: Dict[str, Any], delta: int
    ):
        scales = self._scales_for(display, settings.get("res"))
        if not scales:
            return
        index = next(
            (
                i
                for i, scale in enumerate(scales)
                if abs(scale - settings.get("scale", 0)) <= 0.001
            ),
            0,
        )
        settings["scale"] = scales[(index + delta) % len(scales)]

    # --------------------------------------------------------------- apply --

    def command_args(self, role: str) -> List[str]:
        view = self.views.get(role)
        if not view or not view.settings:
            return []
        display = view.display or {}
        settings = view.settings
        defaults = display.get("defaults") or {}
        args: List[str] = []
        if settings["res"] != defaults.get("res"):
            args.append(f"res={settings['res']}")
        if abs(settings["hz"] - defaults.get("hz", settings["hz"])) > 0.05:
            args.append(f"hz={format_hz_arg(settings['hz'])}")
        if bool(settings["vrr"]) != bool(defaults.get("vrr")):
            args.append(f"vrr={1 if settings['vrr'] else 0}")
        if bool(settings["hdr"]) != bool(defaults.get("hdr")):
            args.append(f"hdr={1 if settings['hdr'] else 0}")
        if abs(settings["scale"] - defaults.get("scale", settings["scale"])) > 0.001:
            args.append(f"scale={format_scale(settings['scale'])}")
        return args

    def update_prompt(self):
        role = self.focused_role()
        if not role:
            self.prompt_args.set_text("")
            return
        parts = [role] + self.command_args(role)
        self.prompt_args.set_text(" " + " ".join(parts))

    def apply_focused(self) -> bool:
        role = self.focused_role()
        return self.apply_role(role) if role else False

    def apply_role(self, role: str) -> bool:
        view = self.views.get(role)
        if not view or not view.settings or not view.rows:
            return False
        args = self.command_args(role)
        self.remembered[role] = dict(view.settings)
        save_remembered(self.remembered)
        name = DISPLAY_NAMES.get(role, role.upper())
        self.close()
        try:
            subprocess.Popen(
                ["sh", "-c", APPLY_WRAPPER, APPLIER_SCRIPT, name, role] + args,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except Exception as e:
            print(f"Error applying display: {e}", file=sys.stderr)
        return True

    def apply_index(self, index: int) -> bool:
        displays = (self.caps or {}).get("displays") or []
        if not (0 <= index < len(displays)):
            return False
        role = displays[index].get("role")
        return self.apply_role(role) if role else False

    # ---------------------------------------------------------------- input --

    def on_key_press(self, widget, event):
        keyval = event.keyval

        if keyval == Gdk.KEY_Escape:
            self.close()
            return True

        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            if self.apply_focused():
                return True
            self.reset_timer()
            return True

        if keyval in (Gdk.KEY_Tab, Gdk.KEY_ISO_Left_Tab) or (
            keyval == Gdk.KEY_o and (event.state & Gdk.ModifierType.MOD4_MASK)
        ):
            self.next_display()
        elif keyval in (Gdk.KEY_Up, Gdk.KEY_k):
            self.move_focus(-1)
        elif keyval in (Gdk.KEY_Down, Gdk.KEY_j):
            self.move_focus(1)
        elif keyval in (Gdk.KEY_Left, Gdk.KEY_h):
            self.change_value(-1)
        elif keyval in (Gdk.KEY_Right, Gdk.KEY_l):
            self.change_value(1)
        elif keyval == Gdk.KEY_space:
            self.toggle_value()
        elif keyval in (Gdk.KEY_1, Gdk.KEY_2):
            if self.apply_index(keyval - Gdk.KEY_1):
                return True

        self.reset_timer()
        return True

    def on_cycle_signal(self, signum, frame):
        GLib.idle_add(self._next_display_and_reset)

    def _next_display_and_reset(self):
        self.next_display()
        self.reset_timer()
        return False

    # ---------------------------------------------------------------- timer --

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

    # ------------------------------------------------------------------ ui --

    def build_ui(self):
        self.set_name("display-switcher")

        overlay = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        overlay.set_halign(Gtk.Align.FILL)
        overlay.set_valign(Gtk.Align.FILL)

        center = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        center.set_halign(Gtk.Align.CENTER)
        center.set_valign(Gtk.Align.CENTER)

        panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        panel.set_name("terminal-panel")
        panel.set_halign(Gtk.Align.CENTER)
        panel.set_valign(Gtk.Align.CENTER)

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        header.set_name("terminal-header")
        title = chrome_label("DISPLAY SWITCHER", "header-title")
        self.header_active = chrome_label("ACTIVE · NONE", "header-active")
        self.header_active.set_xalign(1.0)
        self.header_active.set_hexpand(True)
        header.pack_start(title, False, False, 0)
        header.pack_start(self.header_active, True, True, 0)

        prompt_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        prompt_row.set_name("prompt-row")
        prompt = Gtk.Label(label="$ display-apply.sh")
        prompt.set_name("prompt-text")
        prompt.set_xalign(0.0)
        self.prompt_args = Gtk.Label(label="")
        self.prompt_args.set_name("prompt-args")
        self.prompt_args.set_xalign(0.0)
        self.cursor = Gtk.Label(label="▌")
        self.cursor.set_name("prompt-cursor")
        self.cursor.set_xalign(0.0)
        prompt_row.pack_start(prompt, False, False, 0)
        prompt_row.pack_start(self.prompt_args, False, False, 0)
        prompt_row.pack_start(self.cursor, False, False, 0)

        self.label_size_group = Gtk.SizeGroup(mode=Gtk.SizeGroupMode.HORIZONTAL)
        self.frames_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.frames_box.set_name("display-list")

        footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        footer.set_name("footer")
        hints = Gtk.Label(
            label="↑↓ select · ←→ change · space toggle · enter apply · tab next display · esc"
        )
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
        panel.pack_start(self.frames_box, False, False, 0)
        panel.pack_start(footer, False, False, 0)

        center.pack_start(panel, False, False, 0)
        overlay.pack_start(center, True, True, 0)
        self.add(overlay)

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
/* display-switcher.css - Cold terminal theme */

@define-color bg #060a0e;
@define-color surface #0c1116;
@define-color raised #141a21;
@define-color line #2c3742;
@define-color line_strong #505c69;
@define-color fg #dde6ec;
@define-color muted #95a0aa;
@define-color faint #64707d;
@define-color signal #7de2fa;
@define-color bad #f47a7d;

/* ── Backdrop ── */
#display-switcher {
    background: rgba(6, 10, 14, 0.85);
}

/* One monospace family everywhere; body size only, the prompt is the exception. */
#display-switcher label {
    font-family: "Martian Mono", "JetBrainsMono Nerd Font", "DejaVu Sans Mono", monospace;
    font-size: 12px;
}

/* ── Panel ── */
#terminal-panel {
    background: @surface;
    border: 1px solid @line;
    border-radius: 0;
    padding: 16px 20px;
    min-width: 640px;
}

/* ── Chrome: uppercase, tracked caps (tracking is a Pango attr, see CHROME_TRACKING) ── */
#display-switcher .chrome {
    color: @muted;
    font-weight: 600;
}

/* ── Header ── */
#terminal-header {
    border-bottom: 1px solid @line;
    padding-bottom: 10px;
}

#header-active {
    color: @muted;
}

/* ── Prompt (the one size step) ── */
#prompt-row {
    padding: 10px 0;
}

#display-switcher #prompt-text {
    color: @fg;
    font-size: 16px;
    font-weight: 500;
}

#display-switcher #prompt-args {
    color: @signal;
    font-size: 16px;
    font-weight: 600;
}

#display-switcher #prompt-cursor {
    color: @signal;
    font-size: 16px;
    margin-left: 1px;
}

#display-switcher #prompt-cursor.off {
    opacity: 0;
}

/* ── Display frames ── */
#display-frame {
    background: transparent;
}

#display-frame > border {
    border: 1px solid @line_strong;
    border-radius: 0;
}

#display-frame.focused > border {
    border: 1px solid @signal;
}

#display-frame.disconnected > border {
    border: 1px solid @line;
}

#display-frame.disconnected #legend-name {
    color: @faint;
}

#frame-legend {
    background: @surface;
    padding: 0 6px;
}

#legend-name {
    color: @muted;
}

#display-frame.focused #legend-name {
    color: @signal;
}

#legend-device {
    color: @faint;
}

#legend-note {
    color: @faint;
}

#display-switcher #legend-tag {
    background: @signal;
    color: @bg;
    padding: 1px 6px;
}

/* ── Frame body ── */
#frame-body {
    padding: 10px 12px;
}

#frame-note {
    color: @faint;
    font-size: 12px;
    font-style: italic;
    padding: 2px 4px;
}

#frame-note.error {
    color: @bad;
}

/* ── Setting rows ── */
#setting-row {
    background: transparent;
    border-left: 2px solid transparent;
    padding: 3px 8px;
}

#setting-row.focused {
    background: @raised;
    border-left: 2px solid @signal;
}

#setting-label {
    color: @muted;
}

#setting-row.focused #setting-label {
    color: @signal;
}

#setting-value {
    color: @fg;
    font-size: 12px;
    font-weight: 500;
}

#setting-row.focused #setting-value {
    color: @signal;
    font-weight: 600;
}

#setting-chevron {
    color: @faint;
    font-size: 12px;
}

/* ── Footer ── */
#footer {
    border-top: 1px solid @line;
    padding-top: 10px;
}

#footer-hints {
    color: @faint;
    font-size: 12px;
    font-style: italic;
}

#countdown {
    color: @faint;
    font-size: 12px;
    font-style: italic;
}
"""


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
