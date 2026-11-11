# ZR Tools - KlipperScreen panel for the WonderMaker ZR Ultra-S (4 toolheads)
# Version 1
#
# Install:  copy to ~/KlipperScreen/panels/zr_tools.py
# Needs:    zr_tools.cfg included in printer.cfg
# Menu:     see KlipperScreen.conf snippet in INSTALL.md
#
# Data comes from Klipper/Moonraker (printer.objects.query, polled every 2 s
# while the panel is visible). Filament info is stored in save_variables:
#   zr_t<N>_color (int 0xRRGGBB), zr_t<N>_mat (index in MATERIALS),
#   zr_t<N>_temp (C), t<N>_pressure_advance (WonderMaker's own variable)
# Tool mapping uses WonderMaker's own box_modify_t<N> variables.

import json
import logging
import threading
import urllib.request
import uuid

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk, GLib  # noqa: E402

from ks_includes.screen_panel import ScreenPanel  # noqa: E402

try:                                   # KlipperScreen loads panels as "panels.<name>"
    from panels import zr_logic as L  # noqa: E402
    from panels.zr_views import ViewsMixin  # noqa: E402
except ImportError:                    # tests import the files from this folder
    import zr_logic as L  # noqa: E402
    from zr_views import ViewsMixin  # noqa: E402

NTOOLS = 4
POLL_SECONDS = 2

# (name, default nozzle temperature)
MATERIALS = [
    ("Empty", 0),
    ("PLA", 210),
    ("PLA+", 215),
    ("PLA Silk", 215),
    ("PLA Matte", 210),
    ("PLA-CF", 220),
    ("PETG", 240),
    ("PETG-CF", 245),
    ("ABS", 250),
    ("ASA", 255),
    ("TPU", 220),
    ("PA / Nylon", 270),
    ("PC", 270),
    ("PVA", 195),
    ("HIPS", 235),
    ("Other", 220),
]

COLOR_PRESETS = L.TOUCH_PALETTE         # same swatches, same order as the Fluidd panel and the touchscreen

CHAMBER_MAX = 65


def _rgb(color_int):
    color_int = int(color_int or 0) & 0xFFFFFF
    return (color_int >> 16) & 0xFF, (color_int >> 8) & 0xFF, color_int & 0xFF


def _color_name(color_int):
    """Closest preset name, or the hex code."""
    best, dist = None, 10 ** 9
    r, g, b = _rgb(color_int)
    for name, col in COLOR_PRESETS:
        cr, cg, cb = _rgb(col)
        d = (r - cr) ** 2 + (g - cg) ** 2 + (b - cb) ** 2
        if d < dist:
            best, dist = name, d
    return best if dist < 3000 else "#%06X" % (color_int & 0xFFFFFF)


def _ext_name(tool):
    return "extruder" if tool == 0 else f"extruder{tool}"


def _tool_from_ext(name):
    if not name or not str(name).startswith("extruder"):
        return -1
    suffix = str(name)[len("extruder"):]
    if suffix == "":
        return 0
    try:
        return int(suffix)
    except ValueError:
        return -1


class Panel(ViewsMixin, ScreenPanel):

    def __init__(self, screen, title):
        super().__init__(screen, title)
        self.view = "main"
        self.view_tool = 0
        self._timer = None
        self.st = {}          # last status received from Klipper
        self.w = {}           # widgets of the current view
        self.edit = None      # tool being edited: dict(color, mat, temp, pa)
        self._tmt1 = []       # [slot] colours and materials from tmt1.ini (shared with Fluidd)
        self._tmt1_text = ''
        self._tmt1_busy = False
        self.settings = L.load_settings()
        self.nav_btns = {}
        self.outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.nav = None
        self.outer.set_vexpand(True)
        self.outer.set_valign(Gtk.Align.FILL)
        self.content.set_vexpand(True)
        if hasattr(self.content, "pack_start"):
            self.content.pack_start(self.outer, True, True, 0)
        else:
            self.content.add(self.outer)
        self.outer.pack_start(self.root, True, True, 0)
        self._apply_settings()
        self.show_home()

    # ------------------------------------------------------------------
    # layout shell: A = card grid hub, C = big touch with a bottom tab bar
    # ------------------------------------------------------------------
    def _apply_settings(self):
        width, height = getattr(self._screen, "width", 0), getattr(self._screen, "height", 0)
        self.portrait = self._is_portrait(width, height)
        self.density = L.resolve_density(self.settings["density"], width, height)
        self.sz = L.sizes(self.density, self.portrait, width, height)
        self.scale, self.tiny = self.sz["scale"], self.sz["tiny"]
        self._add_css()
        if self.nav is not None:
            self.outer.remove(self.nav)
            self.nav = None
        if self.settings["layout"] == "tabs":
            self.nav = self._make_nav()
            self.outer.pack_end(self.nav, False, False, 0)
            self.nav.show_all()

    @staticmethod
    def _is_portrait(width, height):
        """Tall screen (480x800, 600x1024)?"""
        return bool(L.screen_profile(width, height)["portrait"])

    def _nav_entries(self):
        e = [("toolchanger", "Toolheads", self.show_main, ("main",)),
             ("filament", "Filament", self.show_filament, ("tool", "tool_edit")),
             ("heat-up", "Climate", self.show_chamber, ("chamber",))]
        if not self.tiny:            # on a 3 to 4 inch screen Calibrate moves into More to keep the tabs big enough to hit
            e.append(("settings", "Calibrate", self.show_utilities, ("utilities",)))
        if L.has_ace(self.st):
            e.append(("spool", "ACE", self.show_ace, ("ace",)))
        more = ("more", "hub", "collision", "extras", "system", "settings", "mapping")
        e.append(("main", "More", self.show_more, more + (("utilities",) if self.tiny else ())))
        return e

    def _make_nav(self):
        bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        bar.set_homogeneous(True)
        self.nav_btns = {}
        for icon, label, cb, views in self._nav_entries():
            b = self._tab_button(icon, L.short_label(label, self.portrait, self.density), cb)
            b.set_size_request(-1, self.sz["nav_h"])
            bar.pack_start(b, True, True, 0)
            self.nav_btns[label] = (b, views)
        return bar

    def _mark_nav(self):
        for label, (b, views) in self.nav_btns.items():
            ctx = b.get_style_context()
            if self.view in views:
                ctx.add_class("zr_selected")
            else:
                ctx.remove_class("zr_selected")

    def _rebuild_nav_if_needed(self):
        """The ACE tab appears as soon as an ACE shows up in the printer data."""
        if self.nav is not None and ("ACE" in self.nav_btns) != L.has_ace(self.st):
            self._apply_settings()

    def _home_view(self):
        return "main" if self.settings["layout"] == "tabs" else "hub"

    def show_home(self):
        if self.settings["layout"] == "tabs":
            self.show_main()
        else:
            self.show_hub()

    # ------------------------------------------------------------------
    # lifecycle
    # ------------------------------------------------------------------
    def activate(self):
        self._query()
        if self._timer is None:
            self._timer = GLib.timeout_add_seconds(POLL_SECONDS, self._poll)

    def deactivate(self):
        if self._timer is not None:
            GLib.source_remove(self._timer)
            self._timer = None

    def on_back(self):
        if self.view == "tool_edit":
            self.show_tool(self.view_tool)
            return True
        if self.view != self._home_view():
            self.show_home()
            return True
        return False

    def process_update(self, action, data):
        # Global KlipperScreen subscription (temperatures, toolhead ...).
        if action != "notify_status_update" or not isinstance(data, dict):
            return
        payload = data.get("status") if isinstance(data.get("status"), dict) else data
        changed = False
        for key, val in payload.items():
            if isinstance(val, dict) and key in self._objects():
                self.st.setdefault(key, {}).update(val)
                changed = True
        if changed:
            self._refresh_view()

    # ------------------------------------------------------------------
    # Klipper communication
    # ------------------------------------------------------------------
    def _objects(self):
        objs = {
            "toolhead": ["extruder", "homed_axes"],
            "print_stats": ["state"],
            "save_variables": ["variables"],
            "heater_generic chamber": ["temperature", "target"],
            "fan_generic air_fan": ["speed"],
            "gcode_button Door_button1": ["state"],
            "gcode_button Door_button2": ["state"],
            "ace_instance_0": None,
            "gcode_macro _WM_ACE": None,
        }
        for i in range(NTOOLS):
            objs[_ext_name(i)] = ["temperature", "target", "pressure_advance"]
            objs[f"filament_switch_sensor filament{i}"] = ["filament_detected"]
            objs[f"filament_switch_sensor docked{i}"] = ["filament_detected"]
            objs[f"filament_switch_sensor path_{i}"] = ["filament_detected"]
        return objs

    def _ws(self):
        ws = getattr(self._screen, "_ws", None)
        if callable(getattr(ws, "send_method", None)):
            return ws
        inner = getattr(getattr(ws, "klippy", None), "_ws", None)
        if callable(getattr(inner, "send_method", None)):
            return inner
        return None

    def _poll(self):
        self._query()
        return True

    def _http_base(self):
        ws = getattr(self._screen, "_ws", None)
        host, port = getattr(ws, "host", None), getattr(ws, "port", None)
        if not isinstance(host, str) or not host or not port:
            return None
        return "%s://%s:%s" % ("https" if getattr(ws, "ssl", False) else "http", host, port)

    def _fetch_tmt1(self):
        """Read tmt1.ini from Moonraker (in a thread, the screen must not wait for it)."""
        base = self._http_base()
        if base is None or self._tmt1_busy:
            return
        self._tmt1_busy = True

        def work():
            try:
                with urllib.request.urlopen(base + "/server/files/config/tmt1.ini", timeout=4) as r:
                    text = r.read().decode("utf-8", "replace")
                GLib.idle_add(self._set_tmt1, text)
            except Exception as e:
                logging.debug(f"ZR: tmt1.ini not read: {e}")
            finally:
                self._tmt1_busy = False
        threading.Thread(target=work, daemon=True).start()

    def _set_tmt1(self, text):
        self._tmt1_text = text
        self._tmt1 = L.parse_tmt1_slots(text, NTOOLS)
        self._refresh_view()
        return False

    def _write_tmt1(self, index, color_idx, mat_idx):
        """Change one slot in tmt1.ini so Fluidd and the touchscreen see it. Re-reads first, keeps every other line."""
        base = self._http_base()
        if base is None:
            return

        def work():
            try:
                with urllib.request.urlopen(base + "/server/files/config/tmt1.ini", timeout=4) as r:
                    cur = r.read().decode("utf-8", "replace")
                new = L.update_tmt1_slot(cur, index, color_idx, mat_idx)
                if new != cur:
                    b = uuid.uuid4().hex
                    body = (f'--{b}\r\nContent-Disposition: form-data; name="root"\r\n\r\nconfig\r\n'
                            f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="tmt1.ini"\r\n'
                            f'Content-Type: text/plain\r\n\r\n').encode() + new.encode() + f"\r\n--{b}--\r\n".encode()
                    req = urllib.request.Request(base + "/server/files/upload", body,
                                                 {"Content-Type": "multipart/form-data; boundary=" + b})
                    urllib.request.urlopen(req, timeout=6).read()
                GLib.idle_add(self._set_tmt1, new)
            except Exception as e:
                logging.error(f"ZR: could not write tmt1.ini: {e}")
                GLib.idle_add(self._screen.show_popup_message, "Could not share the colour with Fluidd (tmt1.ini).")
        threading.Thread(target=work, daemon=True).start()

    def _query(self):
        self._fetch_tmt1()
        ws = self._ws()
        if ws is None:
            return
        try:
            ws.send_method("printer.objects.query",
                           {"objects": self._objects()}, self._on_query)
        except Exception as e:
            logging.debug(f"ZR: query failed: {e}")

    def _on_query(self, response, *_):
        try:
            result = response or {}
            if isinstance(result, dict) and "result" in result:
                result = result["result"] or {}
            status = result.get("status", {}) if isinstance(result, dict) else {}
            if isinstance(status, dict) and status:
                GLib.idle_add(self._apply_status, status)
        except Exception as e:
            logging.debug(f"ZR: bad query response: {e}")

    def _apply_status(self, status):
        for key, val in status.items():
            if isinstance(val, dict):
                self.st.setdefault(key, {}).update(val)
        self._refresh_view()
        return False

    def _gcode(self, script, message=None):
        try:
            ws = self._screen._ws
            api = getattr(ws, "api", None)           # current KlipperScreen
            if api is None or not callable(getattr(api, "gcode_script", None)):
                api = getattr(ws, "klippy", None)    # older KlipperScreen
            if api is not None and callable(getattr(api, "gcode_script", None)):
                api.gcode_script(script)
            elif ws.send_method("printer.gcode.script", {"script": script}) is False:
                raise RuntimeError("not connected to Moonraker")
            if message:
                self._screen.show_popup_message(message, 1)
            GLib.timeout_add(800, self._query_once)
            return True
        except Exception as e:
            logging.error(f"ZR: gcode '{script}' failed: {e}")
            self._screen.show_popup_message("Connection error. Check Klipper.")
            return False

    def _query_once(self):
        self._query()
        return False

    # ------------------------------------------------------------------
    # state helpers
    # ------------------------------------------------------------------
    def _vars(self):
        return (self.st.get("save_variables") or {}).get("variables") or {}

    def _print_state(self):
        return (self.st.get("print_stats") or {}).get("state", "")

    def _busy(self):
        return self._print_state() in ("printing", "paused")

    def _active_tool(self):
        # WonderMaker keeps the tool on the carriage in current_extruder
        # (99 = no toolhead on the carriage). Fall back to Klipper's
        # active extruder if the variable is missing.
        cur = self._vars().get("current_extruder")
        try:
            cur = int(cur)
            if 0 <= cur < NTOOLS:
                return cur
            if cur == 99:
                return -1
        except (TypeError, ValueError):
            pass
        return _tool_from_ext((self.st.get("toolhead") or {}).get("extruder"))

    def _tool_info(self, i):
        v = self._vars()
        slot = self._tmt1[i] if i < len(self._tmt1) else {}
        if f"zr_t{i}_mat" in v:
            mat = int(v.get(f"zr_t{i}_mat", 0) or 0)
        elif slot.get("material") is not None:
            mat = L.TOUCH_MATERIALS[slot["material"]][2]
        else:
            mat = 0
        if mat < 0 or mat >= len(MATERIALS):
            mat = 0
        if slot.get("color") is not None:      # tmt1.ini is shared with Fluidd and the touchscreen
            color = L.TOUCH_PALETTE[slot["color"]][1]
        else:
            color = int(v.get(f"zr_t{i}_color", 0x404040) or 0)
        return {
            "color": color,
            "mat": mat,
            "temp": int(v.get(f"zr_t{i}_temp", MATERIALS[mat][1] or 220) or 0),
            "pa": float(v.get(f"t{i}_pressure_advance", 0.04) or 0.0),
        }

    def _temps(self, i):
        e = self.st.get(_ext_name(i)) or {}
        return e.get("temperature"), e.get("target")

    def _sensor(self, name):
        s = self.st.get(f"filament_switch_sensor {name}")
        if not isinstance(s, dict) or "filament_detected" not in s:
            return None
        return bool(s["filament_detected"])

    def _mapping(self):
        v = self._vars()
        out = []
        for t in range(NTOOLS):
            try:
                out.append(int(v.get(f"box_modify_t{t}", t)))
            except (TypeError, ValueError):
                out.append(t)
        return out

    def _require_idle(self):
        if self._busy():
            self._screen.show_popup_message("Not available during a print.")
            return False
        return True

    def _confirm(self, title, text, script, message=None):
        label = Gtk.Label(label=text)
        label.set_line_wrap(True)
        label.set_justify(Gtk.Justification.CENTER)
        buttons = [
            {"name": "Cancel", "response": Gtk.ResponseType.CANCEL},
            {"name": "OK", "response": Gtk.ResponseType.OK},
        ]

        def _resp(dialog, response_id):
            self._gtk.remove_dialog(dialog)
            if response_id == Gtk.ResponseType.OK:
                self._gcode(script, message)

        self._gtk.Dialog(title, buttons, label, _resp)

    # ------------------------------------------------------------------
    # small widget helpers
    # ------------------------------------------------------------------
    def _clear(self):
        for child in self.root.get_children():
            self.root.remove(child)
        self.w = {}
        self._mark_nav()

    def _label(self, text="", css=None, wrap=False):
        lbl = Gtk.Label(label=text)
        lbl.set_line_wrap(wrap)
        lbl.set_justify(Gtk.Justification.CENTER)
        if css:
            lbl.get_style_context().add_class(css)
        return lbl

    def _swatch(self, w, h):
        box = Gtk.EventBox()
        box.set_size_request(w, h)
        box.get_style_context().add_class("zr_swatch")
        return box

    def _set_swatch(self, box, color_int):
        if hasattr(box, "zr_color"):       # spool (drawn)
            box.zr_color = color_int
            box.queue_draw()
            return
        r, g, b = _rgb(color_int)
        box.override_background_color(
            Gtk.StateFlags.NORMAL, Gdk.RGBA(r / 255.0, g / 255.0, b / 255.0, 1.0))

    def _spool(self, size):
        """A round spool in the filament colour: centre hole and ring; dashed outline when empty."""
        da = Gtk.DrawingArea()
        da.set_size_request(size, size)
        da.zr_color = 0x303030
        da.zr_empty = False
        da.set_halign(Gtk.Align.CENTER)

        def draw(widget, cr):
            w, h = widget.get_allocated_width(), widget.get_allocated_height()
            d = min(w, h)
            cx, cy, rad = w / 2.0, h / 2.0, d / 2.0 - 3
            r_, g_, b_ = _rgb(widget.zr_color)
            if widget.zr_empty:
                cr.set_source_rgba(0.55, 0.6, 0.65, 1)
                cr.set_line_width(2)
                cr.set_dash([5, 4])
                cr.arc(cx, cy, rad, 0, 6.2832)
                cr.stroke()
                cr.set_dash([])
                return False
            cr.set_source_rgb(r_ / 255.0, g_ / 255.0, b_ / 255.0)
            cr.arc(cx, cy, rad, 0, 6.2832)
            cr.fill()
            lum = (0.299 * r_ + 0.587 * g_ + 0.114 * b_) / 255.0       # light ring on dark colours
            ring = (1, 1, 1, 0.35) if lum < 0.35 else (0, 0, 0, 0.25)
            cr.set_source_rgba(*ring)
            cr.set_line_width(max(2, rad * 0.06))
            cr.arc(cx, cy, rad * 0.62, 0, 6.2832)
            cr.stroke()
            cr.set_source_rgb(0.105, 0.137, 0.168)                      # centre hole
            cr.arc(cx, cy, rad * 0.26, 0, 6.2832)
            cr.fill()
            cr.set_source_rgba(*ring)
            cr.set_line_width(max(1.5, rad * 0.04))
            cr.arc(cx, cy, rad - 1, 0, 6.2832)
            cr.stroke()
            return False
        da.connect("draw", draw)
        return da

    def _tempbar(self):
        """Thin bar: how close the nozzle is to its target."""
        da = Gtk.DrawingArea()
        da.set_size_request(-1, 6)
        da.zr_frac = 0.0

        def draw(widget, cr):
            w, h = widget.get_allocated_width(), widget.get_allocated_height()
            cr.set_source_rgba(0.5, 0.55, 0.6, 0.35)
            cr.rectangle(0, 0, w, h)
            cr.fill()
            cr.set_source_rgb(0.18, 0.48, 0.96)
            cr.rectangle(0, 0, w * max(0.0, min(1.0, widget.zr_frac)), h)
            cr.fill()
            return False
        da.connect("draw", draw)
        return da

    def _pill(self, text="", kind=None):
        lbl = Gtk.Label(label=text)
        ctx = lbl.get_style_context()
        ctx.add_class("zr_pill")
        if kind:
            ctx.add_class("zr_pill_" + kind)
        lbl.set_halign(Gtk.Align.CENTER)
        return lbl

    def _set_pill(self, lbl, text, kind):
        ctx = lbl.get_style_context()
        for k in ("ready", "active", "empty", "info"):
            ctx.remove_class("zr_pill_" + k)
        if kind:
            ctx.add_class("zr_pill_" + kind)
        lbl.set_text(text)

    _PRIMARY_LABELS = ("Save", "Start drying", "Load from ACE", "Apply", "Confirm")
    _STYLE_CLASS = {"color1": "zr_btn_primary", "color2": "zr_btn_green", "color4": "zr_btn_orange"}

    def _button(self, icon, label, style, callback, *args):
        """Icon beside the label and no vertical stretching: a slim, uniform rounded button."""
        try:
            btn = self._gtk.Button(icon, label, style, scale=self._gtk.bsidescale, position=Gtk.PositionType.LEFT, lines=1)
        except (TypeError, AttributeError):
            btn = self._gtk.Button(icon, label, style)
        btn.set_vexpand(False)
        ctx = btn.get_style_context()
        ctx.add_class("zr_btn")
        if style == "color1" and label in self._PRIMARY_LABELS:      # one clear primary action; the rest stay calm
            ctx.add_class("zr_btn_primary")
        btn.connect("clicked", lambda _w: callback(*args))
        return btn

    def _tab_button(self, icon, label, callback):
        """Bottom tab bar: icon above the label."""
        btn = self._gtk.Button(icon, label, "color3", lines=1)
        btn.set_vexpand(False)
        btn.get_style_context().add_class("zr_tab")
        btn.connect("clicked", lambda _w: callback())
        return btn

    def _header(self, title, back=None, action=None):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        if back is not None or self.view != self._home_view():
            btn = self._button("arrow-left", "Back", "color3", back or self.show_home)
            btn.set_size_request(96, self.sz["btn_h"])
            row.pack_start(btn, False, False, 0)
        lbl = self._label()
        lbl.set_markup(f"<b>{title}</b>")
        row.pack_start(lbl, True, True, 0)
        if action is not None:
            icon, text, style, cb = action
            ab = self._button(icon, text, style, cb)
            ab.set_size_request(110, self.sz["btn_h"])
            row.pack_end(ab, False, False, 0)
        return row

    def _scrolled(self, child):
        sw = Gtk.ScrolledWindow()
        sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        sw.set_vexpand(True)
        sw.set_kinetic_scrolling(True)       # drag with a finger
        sw.set_overlay_scrolling(False)      # a visible scrollbar, so you can see there is more
        sw.add(child)
        return sw

    # ------------------------------------------------------------------
    # MAIN VIEW: 4 tool cards
    # ------------------------------------------------------------------
    def show_main(self):
        self.view = "main"
        self._clear()

        self.w["p_car"] = self._pill("On carriage: --", "info")
        self.w["p_state"] = self._pill("Printer: --", "info")
        self.w["p_ch"] = self._pill("", "info")
        self.w["p_ace"] = self._pill("", "info")
        if self.portrait:
            # Tall screen: the three pills would not fit in one row, so the chamber pill gets its own row.
            top = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            row1 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            row1.pack_start(self.w["p_car"], False, False, 0)
            row1.pack_start(self.w["p_state"], False, False, 0)
            top.pack_start(row1, False, False, 0)
            top.pack_start(self.w["p_ch"], False, False, 0)
            top.pack_start(self.w["p_ace"], False, False, 0)
        else:
            top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            top.pack_start(self.w["p_car"], False, False, 0)
            top.pack_start(self.w["p_state"], False, False, 0)
            top.pack_start(self.w["p_ace"], False, False, 0)
            top.pack_end(self.w["p_ch"], False, False, 0)
        self.root.pack_start(top, False, False, 0)

        self.w["cards"] = []
        if self.portrait:
            # Tall screen: the cards sit 2 x 2.
            cards = Gtk.Grid()
            cards.set_row_spacing(8)
            cards.set_column_spacing(8)
            cards.set_column_homogeneous(True)
            cards.set_row_homogeneous(True)
            for i in range(NTOOLS):
                card = self._make_card(i)
                card.set_hexpand(True)
                card.set_vexpand(True)
                cards.attach(card, i % self.sz["tool_cols"], i // self.sz["tool_cols"], 1, 1)
        else:
            # Wide screen: four cards in a row (unchanged).
            cards = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            cards.set_homogeneous(True)
            for i in range(NTOOLS):
                cards.pack_start(self._make_card(i), True, True, 0)
        self.root.pack_start(cards, True, True, 0)
        self.root.show_all()
        self._refresh_view()

    def _make_card(self, i):
        ev = Gtk.EventBox()
        ev.get_style_context().add_class("zr_card")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        for m in ("top", "bottom", "start", "end"):
            getattr(box, "set_margin_" + m)(7)
        big = self.density == "comfortable"
        c = {
            "ev": ev,
            "title": self._label("Toolhead %d" % (i + 1), "zr_title"),
            "chip": self._pill("", "empty"),
            "spool": self._spool(100 if big else 78),
            "mat": self._label("", "zr_mat"),
            "color": self._label("", "zr_small"),
            "temp": self._label("", "zr_small"),
            "bar": self._tempbar(),
            "fil": self._label("", "zr_small"),
            "dock": self._label("", "zr_small"),
            "ace": self._label("", "zr_small"),
        }
        for key in ("title", "chip", "spool", "mat", "color", "temp"):
            box.pack_start(c[key], False, False, 0)
        box.pack_start(c["bar"], False, False, 2)
        box.pack_start(c["fil"], False, False, 0)
        if big:                      # compact sizes keep the cards' touch area, so no ACE line there
            box.pack_start(c["ace"], False, False, 0)
        box.pack_end(c["dock"], False, False, 0)
        ev.add(box)
        ev.connect("button-release-event", lambda *_a, t=i: self.show_tool(t))
        self.w["cards"].append(c)
        return ev

    def _chamber_text(self):
        for key in ("heater_generic chamber", "temperature_sensor chamber", "temperature_sensor chamber_temp"):
            o = self.st.get(key)
            if isinstance(o, dict) and o.get("temperature") is not None:
                return "Chamber %.0f\u00b0C" % float(o["temperature"])
        return ""

    def _refresh_main(self):
        active = self._active_tool()
        state = self._print_state() or "unknown"
        self.w["p_car"].set_text("On carriage: %s" % ("T%d" % active if active >= 0 else "none"))
        self.w["p_state"].set_text("Printer: %s" % state)
        self.w["p_ch"].set_text(self._chamber_text())
        self.w["p_ch"].set_visible(bool(self._chamber_text()))
        bar = L.ace_bar_text(self.st)
        self.w["p_ace"].set_text(bar)
        self.w["p_ace"].set_visible(bool(bar))
        for i, c in enumerate(self.w.get("cards", [])):
            info = self._tool_info(i)
            name, _ = MATERIALS[info["mat"]]
            has = bool(info["mat"])
            ctx = c["ev"].get_style_context()
            if i == active:
                ctx.add_class("zr_active")
            else:
                ctx.remove_class("zr_active")
            if i == active:
                self._set_pill(c["chip"], "Active", "active")
            elif has:
                self._set_pill(c["chip"], "Ready", "ready")
            else:
                self._set_pill(c["chip"], "Empty", "empty")
            c["spool"].zr_empty = not has
            self._set_swatch(c["spool"], info["color"] if has else 0x303030)
            c["mat"].set_text(name if has else "Empty")
            c["color"].set_text(_color_name(info["color"]) if has else " ")
            cur, tgt = self._temps(i)
            if cur is None:
                c["temp"].set_text("--")
                c["bar"].zr_frac = 0.0
            else:
                goal = tgt or info.get("temp") or 0
                c["temp"].set_text("%.0f\u00b0 / %.0f\u00b0" % (cur, tgt or info.get("temp") or 0))
                c["bar"].zr_frac = (cur / goal) if goal else 0.0
            c["bar"].queue_draw()
            fil = self._sensor("filament%d" % i)
            dock = self._sensor("docked%d" % i)
            c["fil"].set_markup(self._dot(fil, "Filament"))
            c["dock"].set_text(("In dock" if dock else "On carriage") if dock is not None else " ")
            c["ace"].set_text(L.ace_card_text(self.st, i))

    @staticmethod
    def _dot(on, text):
        if on is None:
            return " "
        col = "#6fe39a" if on else "#8a96a2"
        return "<span foreground='%s'>\u25cf</span> %s" % (col, text)

    # ------------------------------------------------------------------
    # TOOL VIEW: actions + filament editor
    # ------------------------------------------------------------------
    def show_tool(self, i):
        """Left: hero card with the spool. Right: 3x3 grid of big actions, 'Edit filament' across the bottom."""
        self.view = "tool"
        self.view_tool = i
        self.edit = dict(self._tool_info(i))
        self._clear()
        self.root.pack_start(self._header("Toolhead %d (T%d)" % (i + 1, i)), False, False, 0)

        big = self.density == "comfortable"
        # Wide screen: the spool card on the left, the actions on the right.
        # Tall screen: the spool card is a strip on top and the actions are below it.
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL if self.portrait else Gtk.Orientation.HORIZONTAL, spacing=10)

        card = Gtk.EventBox()
        card.get_style_context().add_class("zr_card")
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        for m in ("top", "bottom", "start", "end"):
            getattr(col, "set_margin_" + m)(8)
        self.w["e_swatch"] = self._spool(110 if big else 84)
        self.w["h_mat"] = self._label("", "zr_mat")
        self.w["h_col"] = self._label("", "zr_small")
        self.w["h_chip"] = self._pill("", "ready")
        self.w["h_state"] = self._label("", "zr_small")
        self.w["h_ace1"] = self._label("", "zr_small")
        self.w["h_ace2"] = self._label("", "zr_small")
        if self.portrait:
            strip = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            strip.pack_start(self.w["e_swatch"], False, False, 0)
            texts = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            for k in ("h_mat", "h_col", "h_chip", "h_state", "h_ace1", "h_ace2"):
                texts.pack_start(self.w[k], False, False, 0)
            strip.pack_start(texts, True, True, 0)
            col.pack_start(strip, True, True, 0)
        else:
            col.pack_start(self.w["e_swatch"], True, True, 0)
            for k in ("h_mat", "h_col", "h_chip", "h_state", "h_ace1", "h_ace2"):
                col.pack_start(self.w[k], False, False, 0)
            card.set_size_request(190 if big else 150, -1)
        card.add(col)
        page.pack_start(card, False, False, 0)

        actions = Gtk.Grid()
        actions.set_row_spacing(8)
        actions.set_column_spacing(8)
        actions.set_column_homogeneous(True)
        items = [
            ("extruder", "Select", "color1", self._act_select),
            ("heat-up", "Heat", "color3", self._act_heat),
            ("cool-down", "Cool", "color3", self._act_cool),
            ("arrow-down", "Load", "color2", self._act_load),
            ("arrow-up", "Unload", "color4", self._act_unload),
            ("fine-tune", "Purge", "color3", self._act_purge),
        ]
        for n, (icon, text, style, cb) in enumerate(items):
            btn = self._gtk.Button(icon, text, style, lines=1)
            btn.get_style_context().add_class("zr_btn")
            if style in self._STYLE_CLASS:
                btn.get_style_context().add_class(self._STYLE_CLASS[style])
            btn.set_hexpand(True)
            btn.set_vexpand(True)
            btn.connect("clicked", lambda _w, f=cb: f(i))
            actions.attach(btn, n % 3, n // 3, 1, 1)
        edit_btn = self._button("fine-tune", "Edit filament", "color3", self.show_tool_edit, i)
        edit_btn.set_size_request(-1, int(self.sz["btn_h"] * 1.7))
        actions.attach(edit_btn, 0, 2, 2, 1)
        park_btn = self._button("extruder", "Park tool", "color3", self._act_park)
        park_btn.set_size_request(-1, int(self.sz["btn_h"] * 1.7))
        actions.attach(park_btn, 2, 2, 1, 1)
        page.pack_start(actions, True, True, 0)

        self.root.pack_start(page, True, True, 0)
        self.root.show_all()
        self._refresh_view()

    def show_tool_edit(self, i=None):
        """Filament editor: material chips, round colour swatches (custom colour is hidden until asked for), temperature."""
        i = self.view_tool if i is None else i
        self.view = "tool_edit"
        self.view_tool = i
        self._clear()
        self.root.pack_start(self._header(f"Filament, toolhead {i + 1}", back=lambda: self.show_tool(i),
                                          action=("complete", "Save", "color1", self._save_tool)), False, False, 0)
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        page.set_margin_start(4)
        page.set_margin_end(10)

        prev_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.w["e_swatch"] = self._swatch(84, 84)
        prev_row.pack_start(self.w["e_swatch"], False, False, 0)
        self.w["e_desc"] = self._label()
        self.w["e_desc"].set_halign(Gtk.Align.START)
        prev_row.pack_start(self.w["e_desc"], True, True, 0)
        page.pack_start(prev_row, False, False, 0)

        page.pack_start(self._section("Colour"), False, False, 0)
        dots = Gtk.Grid()
        dots.set_row_spacing(8)
        dots.set_column_spacing(8)
        dots.set_column_homogeneous(True)
        self.w["dots"] = {}
        for n, (name, col) in enumerate(COLOR_PRESETS):
            dot = Gtk.EventBox()
            dot.set_size_request(self.sz["dot"], self.sz["dot"])
            dot.set_halign(Gtk.Align.CENTER)
            dot.get_style_context().add_class("zr_dot")
            self._set_swatch(dot, col)
            dot.connect("button-release-event", lambda *_a, c=col: self._pick_color(c))
            dots.attach(dot, n % 6, n // 6, 1, 1)
            self.w["dots"][col] = dot
        page.pack_start(dots, False, False, 0)

        custom = self._button("fine-tune", "Custom colour", "color3", self._toggle_rgb)
        custom.set_size_request(-1, self.sz["btn_h"])
        page.pack_start(custom, False, False, 0)
        rgb_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        rgb_box.set_no_show_all(True)
        self.w["rgb_box"] = rgb_box
        self.w["sliders"] = []
        r, g, bl = _rgb(self.edit["color"])
        for name, val in (("R", r), ("G", g), ("B", bl)):
            srow = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
            srow.pack_start(self._label(name), False, False, 0)
            sc = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 255, 1)
            sc.set_value(val)
            sc.set_draw_value(True)
            sc.set_value_pos(Gtk.PositionType.RIGHT)
            sc.connect("value-changed", self._slider_changed)
            srow.pack_start(sc, True, True, 0)
            self.w["sliders"].append(sc)
            rgb_box.pack_start(srow, False, False, 0)
        page.pack_start(rgb_box, False, False, 0)

        page.pack_start(self._section("Material"), False, False, 0)
        mats = Gtk.Grid()
        mats.set_row_spacing(6)
        mats.set_column_spacing(6)
        mats.set_column_homogeneous(True)
        self.w["chips"] = {}
        for n, (name, _t) in enumerate(MATERIALS):
            chip = Gtk.Button(label=name)
            chip.get_style_context().add_class("zr_chip")
            chip.set_size_request(-1, self.sz["btn_h"] - 4)
            chip.connect("clicked", lambda _w, idx=n: self._pick_material(idx))
            mats.attach(chip, n % 4, n // 4, 1, 1)
            self.w["chips"][n] = chip
        page.pack_start(mats, False, False, 0)

        page.pack_start(self._section("Nozzle temperature"), False, False, 0)
        page.pack_start(self._stepper_row("temp", "Temp", -5, 5), False, False, 0)
        page.pack_start(self._section("Pressure advance"), False, False, 0)
        page.pack_start(self._stepper_row("pa", "PA", -0.002, 0.002), False, False, 0)

        self.root.pack_start(self._scrolled(page), True, True, 0)
        self.root.show_all()
        rgb_box.hide()
        self._update_editor()

    def _toggle_rgb(self):
        box = self.w.get("rgb_box")
        if box is None:
            return
        if box.get_visible():
            box.hide()
        else:
            box.show_all()

    def _section(self, text):
        lbl = self._label()
        lbl.set_markup(f"<b>{text}</b>")
        lbl.set_halign(Gtk.Align.START)
        lbl.get_style_context().add_class("zr_section")
        return lbl

    def _stepper_row(self, key, title, down, up):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        row.pack_start(self._label(title), False, False, 0)
        minus = self._button("decrease", None, "color3", self._step, key, down)
        plus = self._button("increase", None, "color3", self._step, key, up)
        for b in (minus, plus):
            b.set_size_request(80, self.sz["btn_h"])
        self.w[f"v_{key}"] = self._label()
        row.pack_start(minus, False, False, 0)
        row.pack_start(self.w[f"v_{key}"], True, True, 0)
        row.pack_start(plus, False, False, 0)
        return row

    def _step(self, key, delta):
        if key == "temp":
            self.edit["temp"] = max(0, min(320, int(self.edit["temp"] + delta)))
        else:
            self.edit["pa"] = round(max(0.0, min(1.0, self.edit["pa"] + delta)), 4)
        self._update_editor()

    def _pick_material(self, idx):
        self.edit["mat"] = idx
        if MATERIALS[idx][1]:
            self.edit["temp"] = MATERIALS[idx][1]
        self._update_editor()

    def _pick_color(self, col):
        self.edit["color"] = col
        for s, v in zip(self.w.get("sliders", []), _rgb(col)):
            s.handler_block_by_func(self._slider_changed)
            s.set_value(v)
            s.handler_unblock_by_func(self._slider_changed)
        self._update_editor()

    def _slider_changed(self, *_):
        r, g, b = (int(s.get_value()) for s in self.w["sliders"])
        self.edit["color"] = (r << 16) | (g << 8) | b
        self._update_editor()

    def _update_editor(self):
        if self.view != "tool_edit" or not self.edit:
            return
        self._set_swatch(self.w["e_swatch"], self.edit["color"])
        name = MATERIALS[self.edit["mat"]][0]
        self.w["e_desc"].set_markup(f"<big><b>{name}</b></big>\n<span size='small'>#{self.edit['color']:06X}</span>")
        self.w["v_temp"].set_text(f"{self.edit['temp']} C")
        self.w["v_pa"].set_text(f"{self.edit['pa']:.3f}")
        for idx, chip in self.w.get("chips", {}).items():
            ctx = chip.get_style_context()
            (ctx.add_class if idx == self.edit["mat"] else ctx.remove_class)("zr_chip_on")
        for col, dot in self.w.get("dots", {}).items():
            ctx = dot.get_style_context()
            (ctx.add_class if col == self.edit["color"] else ctx.remove_class)("zr_dot_on")

    def _save_tool(self):
        i = self.view_tool
        e = self.edit
        cidx = L.nearest_palette(int(e["color"]))      # tmt1.ini holds a swatch index, so a custom colour snaps to the closest swatch
        e["color"] = L.TOUCH_PALETTE[cidx][1]
        midx = next((n for n, m in enumerate(L.TOUCH_MATERIALS) if m[2] == int(e["mat"])), 0)
        if int(e["mat"]):
            self._write_tmt1(i, cidx, midx)
        script = (f"ZR_SET_TOOL_INFO T={i} COLOR={int(e['color'])} "
                  f"MAT={int(e['mat'])} TEMP={int(e['temp'])}")
        old_pa = self._tool_info(i)["pa"]
        if abs(e["pa"] - old_pa) > 1e-6:
            script += f"\nZR_SET_TOOL_PA T={i} PA={e['pa']:.4f}"
        self._gcode(script, f"Toolhead {i + 1} saved")
        self.show_tool(i)

    def _refresh_tool(self):
        i = self.view_tool
        info = self._tool_info(i)
        cur, tgt = self._temps(i)
        fil = self._sensor("filament%d" % i)
        dock = self._sensor("docked%d" % i)
        has = bool(info["mat"])
        name = MATERIALS[info["mat"]][0] if has else "Empty"
        self.w["e_swatch"].zr_empty = not has
        self._set_swatch(self.w["e_swatch"], info["color"] if has else 0x303030)
        self.w["h_mat"].set_text(name)
        temp = ("%.0f\u00b0 / %.0f\u00b0" % (cur, tgt or info.get("temp") or 0)) if cur is not None else "--"
        self.w["h_col"].set_text(("%s \u00b7 %s" % (_color_name(info["color"]), temp)) if has else temp)
        if i == self._active_tool():
            self._set_pill(self.w["h_chip"], "Active", "active")
        elif has:
            self._set_pill(self.w["h_chip"], "Ready", "ready")
        else:
            self._set_pill(self.w["h_chip"], "Empty", "empty")
        state = []
        if fil is not None:
            state.append("Filament OK" if fil else "No filament")
        if dock is not None:
            state.append("In dock" if dock else "On carriage")
        self.w["h_state"].set_text("   ".join(state) if state else " ")
        ace = L.ace_tool_lines(self.st, i)
        for n, key in enumerate(("h_ace1", "h_ace2")):
            self.w[key].set_text(ace[n] if n < len(ace) else "")
            self.w[key].set_visible(n < len(ace))

    # tool actions --------------------------------------------------------
    def _act_select(self, i):
        if self._require_idle():
            self._confirm("Select toolhead", f"Pick up toolhead {i + 1} (T{i})?",
                          f"_CHANGE_TOOL T={i}", f"Changing to toolhead {i + 1}...")

    def _act_park(self):
        if self._require_idle():
            self._confirm("Park tool", "Return the active toolhead to its dock?",
                          "PARK_CURRENT_TOOL", "Parking the toolhead...")

    def _act_heat(self, i):
        temp = int(self.edit["temp"] if self.edit and self.view_tool == i
                   else self._tool_info(i)["temp"]) or 220
        self._gcode(f"SET_HEATER_TEMPERATURE HEATER={_ext_name(i)} TARGET={temp}",
                    f"Heating toolhead {i + 1} to {temp} C")

    def _act_cool(self, i):
        self._gcode(f"SET_HEATER_TEMPERATURE HEATER={_ext_name(i)} TARGET=0",
                    f"Toolhead {i + 1} heater off")

    def _ace_connected(self):
        return L.has_ace(self.st) and bool(L.ace_state(self.st)["connected"])

    def _act_load(self, i):
        if not self._require_idle():
            return
        if self._ace_connected():           # ACE feeds the filament to this toolhead
            self._confirm("Load from ACE", f"Feed ACE slot {i + 1} to toolhead {i + 1} and load it?",
                          f"ACE_WM_LOAD T={i}", f"ACE loading T{i + 1}")
            return
        self._confirm("Load filament",
                      f"Insert filament into toolhead {i + 1}, then press OK.\n"
                      "It heats to the saved temperature and feeds 100 mm.",
                      f"ZR_LOAD T={i}", "Loading...")

    def _act_unload(self, i):
        if not self._require_idle():
            return
        if self._ace_connected():           # ACE pulls the filament back into its slot
            self._confirm("Unload to ACE", f"Unload toolhead {i + 1} and pull the filament back into ACE slot {i + 1}?",
                          f"ACE_WM_UNLOAD T={i}", f"ACE unloading T{i + 1}")
            return
        self._confirm("Unload filament",
                      f"Unload filament from toolhead {i + 1}?\n"
                      "It picks up the toolhead, heats it to the saved temperature and retracts the filament.",
                      f"ZR_RETRACT T={i}", "Unloading...")

    def _act_purge(self, i):
        if not self._require_idle():
            return
        if i != self._active_tool():
            self._screen.show_popup_message("Select this toolhead first (purge uses the active one).")
            return
        self._confirm("Purge", f"Purge 100 mm from toolhead {i + 1} and wipe the nozzle?",
                      "ZR_PURGE", "Purging...")

    # ------------------------------------------------------------------
    # MAPPING VIEW
    # ------------------------------------------------------------------
    def show_mapping(self):
        self.view = "mapping"
        self._clear()
        self.root.pack_start(self._header("Tool mapping"), False, False, 0)
        note = self._label(
            "Choose which toolhead prints each slicer tool. Set it just before "
            "starting a print: WonderMaker resets it to 1:1 after every print.",
            "zr_hint", wrap=True)
        self.root.pack_start(note, False, False, 0)
        grid = Gtk.Grid()
        grid.set_row_spacing(6)
        grid.set_column_spacing(6)
        grid.set_column_homogeneous(True)
        self.w["map_btns"] = {}
        self.w["map_sw"] = {}
        for t in range(NTOOLS):
            narrow = self.portrait and self.density == "compact"     # 480 px: "T0 ->" and "1".."4"
            grid.attach(self._label(f"T{t} ->" if narrow else f"Slicer T{t}  ->"), 0, t, 1, 1)
            for h in range(NTOOLS):
                b = Gtk.Button(label=f"{h + 1}" if narrow else f"Head {h + 1}")
                b.set_size_request(-1, min(self.sz["btn_h"], 42))
                b.connect("clicked", lambda _w, tt=t, hh=h: self._map(tt, hh))
                grid.attach(b, 1 + h, t, 1, 1)
                self.w["map_btns"][(t, h)] = b
            sw = self._swatch(50, 30)
            sw.set_valign(Gtk.Align.CENTER)
            grid.attach(sw, 5, t, 1, 1)
            self.w["map_sw"][t] = sw
        self.root.pack_start(grid, False, False, 0)
        reset = self._button("refresh", "Reset 1:1", "color3", self._map_reset)
        reset.set_size_request(-1, min(self.sz["btn_h"], 42))
        self.root.pack_start(reset, False, False, 0)
        self.root.show_all()
        self._refresh_view()

    def _map(self, t, h):
        if self._require_idle():
            self._gcode(f"ZR_MAP_TOOL T={t} H={h}", f"Slicer T{t} -> toolhead {h + 1}")

    def _map_reset(self):
        if self._require_idle():
            self._gcode("ZR_MAP_RESET", "Mapping reset to 1:1")

    def _refresh_mapping(self):
        mapping = self._mapping()
        for (t, h), b in self.w.get("map_btns", {}).items():
            ctx = b.get_style_context()
            if mapping[t] == h:
                ctx.add_class("zr_selected")
            else:
                ctx.remove_class("zr_selected")
        for t, sw in self.w.get("map_sw", {}).items():
            info = self._tool_info(mapping[t]) if 0 <= mapping[t] < NTOOLS else None
            self._set_swatch(sw, info["color"] if info and info["mat"] else 0x303030)

    # ------------------------------------------------------------------
    # UTILITIES VIEW
    # ------------------------------------------------------------------
    def show_utilities(self):
        self.view = "utilities"
        self._clear()
        self.root.pack_start(self._header("Calibration"), False, False, 0)
        a = self._active_tool()
        at = a if a >= 0 else 0
        have = {str(x).strip().upper() for x in (self._sections() or [])}

        def wm(name):      # WonderMaker calibration macros (rpi-cfg/wm_calibration.cfg, wm_nozzle.cfg): hidden when the Pi lacks them
            return not have or ("GCODE_MACRO " + name) in have

        # (icon, label, script, confirm question or None). The WM_* macros open their own Start / Cancel window
        # (Fluidd and here), so they are sent straight away.
        items = [("home", "Home all", "G28", "Home all axes?")]
        items += [x for x in (
            ("settings", "Full calibration", "WM_FULL_CALIBRATION", None),
            ("bed-level", "Bed leveling", "WM_BED_LEVELING", None),
            ("z-farther", "Probe calibrate (Z height)", "WM_PROBE_CALIBRATE", None),
            ("fine-tune", "Offsets: rapid", "WM_OFFSETS_RAPID", None),
            ("fine-tune", "Offsets: accurate", "WM_OFFSETS_ACCURATE", None),
            ("speed+", "Vibration compensation", "WM_VIBRATION_COMP", None),
            ("heat-up", "Bed PID", "WM_BED_PID", None),
            ("heat-up", f"Nozzle temperature T{at}", f"WM_NOZZLE_TEMP_CAL T={at}", None),
            ("extruder", "Nozzle type", "WM_NOZZLE_TYPE", None),
            ("extruder", "Nozzle change", "WM_NOZZLE_CHANGE", None),
            ("toolchanger", "Extruder setup", "WM_EXTRUDER_SETUP", None),
        ) if wm(x[2].split()[0])]
        items += [
            ("fine-tune", "Wipe nozzle", "WIPE_NOZZLE", "Wipe the active nozzle?"),
            ("extruder", "Park tool", "PARK_CURRENT_TOOL", "Return the active toolhead to its dock?"),
            ("motor-off", "Motors off", "M84", "Disable all motors?"),
            ("unlock", "Unlock gripper", "UNLOCK", "Open the toolhead gripper?"),
            ("lock", "Lock gripper", "LOCK", "Close the toolhead gripper?"),
        ]
        grid = Gtk.Grid()
        grid.set_row_spacing(6)
        grid.set_column_spacing(6)
        grid.set_column_homogeneous(True)
        for n, (icon, text, script, question) in enumerate(items):
            b = self._button(icon, text, "color%d" % (1 + n % 4), self._utility, text, script, question)
            b.set_size_request(-1, self.sz["tile_h"])
            grid.attach(b, n % self.sz["util_cols"], n // self.sz["util_cols"], 1, 1)
        self.root.pack_start(self._scrolled(grid), True, True, 0)
        self.root.show_all()

    def _utility(self, title, script, question):
        if not self._require_idle():
            return
        if question is None:            # the macro shows its own Start / Cancel window
            self._gcode(script)
        else:
            self._confirm(title, question, script, f"{title}...")

    # ------------------------------------------------------------------
    # CHAMBER VIEW
    # ------------------------------------------------------------------
    def _climate_card(self):
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        card.get_style_context().add_class("zr_card")
        card.set_border_width(8)
        return card

    def show_chamber(self):
        self.view = "chamber"
        self._clear()
        self.root.pack_start(self._header("Climate"), False, False, 0)
        bh = min(self.sz["btn_h"], 42)
        ch = self._climate_card()
        ch.pack_start(self._label("CHAMBER", "zr_small"), False, False, 0)
        vals = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        vals.set_halign(Gtk.Align.CENTER)
        self.w["ch_temp"] = self._label("", "zr_value")
        self.w["ch_target"] = self._label("", "zr_small")
        self.w["ch_target"].set_valign(Gtk.Align.END)
        vals.pack_start(self.w["ch_temp"], False, False, 0)
        vals.pack_start(self.w["ch_target"], False, False, 0)
        ch.pack_start(vals, False, False, 0)

        presets = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        presets.set_homogeneous(True)
        for t in (0, 40, 50, 60):
            b = self._button(None, "Off" if t == 0 else f"{t} C", "color2" if t else "color3", self._chamber_set, t)
            b.set_size_request(-1, bh)
            presets.pack_start(b, True, True, 0)
        ch.pack_start(presets, False, False, 0)

        adj = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        adj.set_homogeneous(True)
        for text, d in (("-5 C", -5), ("+5 C", 5)):
            b = self._button(None, text, "color3", self._chamber_step, d)
            b.set_size_request(-1, bh)
            adj.pack_start(b, True, True, 0)
        ch.pack_start(adj, False, False, 0)

        fan = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        fan.set_homogeneous(True)
        on = self._button("fan", "Air filter ON", "color1", self._air_filter, 1)
        off = self._button(None, "OFF", "color3", self._air_filter, 0)
        for b in (on, off):
            b.set_size_request(-1, bh + 4)
            fan.pack_start(b, True, True, 0)
        ch.pack_start(fan, False, False, 0)
        self.w["ch_fan"] = self._label("", "zr_small")
        self.w["ch_doors"] = self._label("", "zr_small", wrap=True)
        ch.pack_start(self.w["ch_fan"], False, False, 0)
        ch.pack_start(self.w["ch_doors"], False, False, 0)

        cards = [ch]
        if L.has_ace(self.st):
            dry = self._climate_card()
            self._build_dryer(dry)
            cards.append(dry)
        if len(cards) == 2 and not self.portrait and not self.tiny:      # side by side on a wide screen
            body = Gtk.Grid()
            body.set_column_spacing(10)
            body.set_column_homogeneous(True)
            for n, c in enumerate(cards):
                body.attach(c, n, 0, 1, 1)
        else:                                                           # stacked, scrolls
            body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
            for c in cards:
                body.pack_start(c, False, False, 0)
        self.root.pack_start(self._scrolled(body), True, True, 0)
        self.root.show_all()
        self._refresh_view()

    def _chamber_target(self):
        return float((self.st.get("heater_generic chamber") or {}).get("target") or 0)

    def _chamber_set(self, t):
        self._gcode(f"ZR_CHAMBER S={int(t)}", "Chamber off" if t == 0 else f"Chamber -> {t} C")

    def _chamber_step(self, d):
        t = max(0, min(CHAMBER_MAX, int(self._chamber_target() + d)))
        self._chamber_set(t)

    def _air_filter(self, on):
        self._gcode(f"ZR_AIR_FILTER S={on}", "Air filter on" if on else "Air filter off")

    def _refresh_chamber(self):
        ch = self.st.get("heater_generic chamber")
        if isinstance(ch, dict) and ch.get("temperature") is not None:
            tgt = ch.get("target") or 0
            self.w["ch_temp"].set_text("%.0f\u00b0" % ch["temperature"])
            self.w["ch_target"].set_text("target %.0f\u00b0" % tgt if tgt else "heater off")
        else:
            self.w["ch_temp"].set_text("--")
            self.w["ch_target"].set_text("Chamber heater not found (is zru-s.cfg included?)")
        fan = self.st.get("fan_generic air_fan")
        if isinstance(fan, dict) and fan.get("speed") is not None:
            self.w["ch_fan"].set_text(f"Air filter {fan['speed'] * 100:.0f}%")
        else:
            self.w["ch_fan"].set_text("Air filter: --")
        doors = []
        for n in (1, 2):
            d = self.st.get(f"gcode_button Door_button{n}")
            if isinstance(d, dict) and d.get("state"):
                doors.append(f"{n}: {str(d['state']).lower()}")
        self.w["ch_doors"].set_text(("Doors  " + "   ".join(doors)) if doors else "")
        self._refresh_dryer()

    # ------------------------------------------------------------------
    def _refresh_view(self):
        try:
            if self.view == "main":
                self._refresh_main()
            elif self.view == "tool":
                self._refresh_tool()
            elif self.view == "tool_edit":
                pass
            elif self.view == "mapping":
                self._refresh_mapping()
            elif self.view == "chamber":
                self._refresh_chamber()
            else:
                self.refresh_extra_views()
            self._rebuild_nav_if_needed()
            self._mark_nav()
        except Exception as e:
            logging.debug(f"ZR: refresh error: {e}")

    def _add_css(self):
        css = L.build_css(self.settings.get("theme"), self.settings.get("style"), self.density, self.scale).encode()
        if getattr(self, "_css_provider", None) is None:
            self._css_provider = Gtk.CssProvider()
            Gtk.StyleContext.add_provider_for_screen(
                Gdk.Screen.get_default(), self._css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        try:
            self._css_provider.load_from_data(css)
        except Exception as e:      # a bad style must never stop the panel from opening
            logging.warning(f"ZR: could not load the style: {e}")
