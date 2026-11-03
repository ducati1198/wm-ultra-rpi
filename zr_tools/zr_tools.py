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

import logging

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk, GLib  # noqa: E402

from ks_includes.screen_panel import ScreenPanel  # noqa: E402

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

COLOR_PRESETS = [
    ("White", 0xFFFFFF), ("Black", 0x000000), ("Grey", 0x808080),
    ("Red", 0xE01010), ("Orange", 0xFF8C00), ("Yellow", 0xFFD700),
    ("Green", 0x20A020), ("Blue", 0x1060E0), ("Purple", 0x8020A0),
    ("Pink", 0xFF69B4), ("Brown", 0x8B4513), ("Clear", 0xD8E8F0),
]

CHAMBER_MAX = 65


def _rgb(color_int):
    color_int = int(color_int or 0) & 0xFFFFFF
    return (color_int >> 16) & 0xFF, (color_int >> 8) & 0xFF, color_int & 0xFF


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


class Panel(ScreenPanel):

    def __init__(self, screen, title):
        super().__init__(screen, title)
        self.view = "main"
        self.view_tool = 0
        self._timer = None
        self.st = {}          # last status received from Klipper
        self.w = {}           # widgets of the current view
        self.edit = None      # tool being edited: dict(color, mat, temp, pa)
        self._add_css()
        self.root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.content.add(self.root)
        self.show_main()

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
        if self.view != "main":
            self.show_main()
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

    def _query(self):
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
            self._screen._ws.klippy.gcode_script(script)
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
        mat = int(v.get(f"zr_t{i}_mat", 0) or 0)
        if mat < 0 or mat >= len(MATERIALS):
            mat = 0
        return {
            "color": int(v.get(f"zr_t{i}_color", 0x404040) or 0),
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
        r, g, b = _rgb(color_int)
        box.override_background_color(
            Gtk.StateFlags.NORMAL, Gdk.RGBA(r / 255.0, g / 255.0, b / 255.0, 1.0))

    def _button(self, icon, label, style, callback, *args):
        btn = self._gtk.Button(icon, label, style)
        btn.connect("clicked", lambda _w: callback(*args))
        return btn

    def _header(self, title):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        back = self._button("arrow-left", "Back", "color3", self.show_main)
        back.set_size_request(110, 46)
        row.pack_start(back, False, False, 0)
        lbl = self._label()
        lbl.set_markup(f"<big><b>{title}</b></big>")
        row.pack_start(lbl, True, True, 0)
        return row

    def _scrolled(self, child):
        sw = Gtk.ScrolledWindow()
        sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        sw.set_vexpand(True)
        sw.add(child)
        return sw

    # ------------------------------------------------------------------
    # MAIN VIEW: 4 tool cards
    # ------------------------------------------------------------------
    def show_main(self):
        self.view = "main"
        self._clear()

        top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self.w["status"] = self._label("Waiting for printer...")
        self.w["status"].set_halign(Gtk.Align.START)
        top.pack_start(self.w["status"], True, True, 4)
        for icon, text, cb in (("shuffle", "Mapping", self.show_mapping),
                               ("settings", "Utilities", self.show_utilities),
                               ("heat-up", "Chamber", self.show_chamber)):
            b = self._button(icon, text, "color3", cb)
            b.set_size_request(120, 46)
            top.pack_end(b, False, False, 0)
        self.root.pack_start(top, False, False, 0)

        cards = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        cards.set_homogeneous(True)
        self.w["cards"] = []
        for i in range(NTOOLS):
            cards.pack_start(self._make_card(i), True, True, 0)
        self.root.pack_start(cards, True, True, 0)

        hint = self._label("Tap a toolhead to load, unload, heat or set its filament.", "zr_hint")
        self.root.pack_start(hint, False, False, 0)
        self.root.show_all()
        self._refresh_view()

    def _make_card(self, i):
        ev = Gtk.EventBox()
        ev.get_style_context().add_class("zr_card")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        box.set_margin_top(6)
        box.set_margin_bottom(6)
        box.set_margin_start(6)
        box.set_margin_end(6)
        c = {
            "ev": ev,
            "title": self._label(),
            "swatch": self._swatch(80, 46),
            "mat": self._label(),
            "temp": self._label(),
            "state": self._label("", "zr_small", wrap=True),
            "map": self._label("", "zr_small", wrap=True),
        }
        c["swatch"].set_halign(Gtk.Align.CENTER)
        for key in ("title", "swatch", "mat", "temp", "state", "map"):
            box.pack_start(c[key], False, False, 0)
        ev.add(box)
        ev.connect("button-release-event", lambda *_a, t=i: self.show_tool(t))
        self.w["cards"].append(c)
        return ev

    def _refresh_main(self):
        active = self._active_tool()
        state = self._print_state() or "unknown"
        names = {0: "T0", 1: "T1", 2: "T2", 3: "T3"}
        self.w["status"].set_markup(
            f"<b>On carriage:</b> {names.get(active, 'none')}    <b>Printer:</b> {state}")
        mapping = self._mapping()
        for i, c in enumerate(self.w.get("cards", [])):
            info = self._tool_info(i)
            name, _ = MATERIALS[info["mat"]]
            ctx = c["ev"].get_style_context()
            if i == active:
                ctx.add_class("zr_active")
                c["title"].set_markup(f"<b>Toolhead {i + 1} (T{i})</b>\n<span foreground='#4CAF50'>ACTIVE</span>")
            else:
                ctx.remove_class("zr_active")
                c["title"].set_markup(f"<b>Toolhead {i + 1} (T{i})</b>\n ")
            self._set_swatch(c["swatch"], info["color"] if info["mat"] else 0x303030)
            c["swatch"].set_opacity(1.0 if info["mat"] else 0.4)
            c["mat"].set_markup(f"<b>{name}</b>" if info["mat"] else "<i>Empty</i>")
            cur, tgt = self._temps(i)
            if cur is None:
                c["temp"].set_text("-- C")
            else:
                c["temp"].set_text(f"{cur:.0f} / {tgt or 0:.0f} C")
            parts = []
            fil = self._sensor(f"filament{i}")
            if fil is not None:
                parts.append("Filament OK" if fil else "No filament")
            dock = self._sensor(f"docked{i}")
            if dock is not None:
                parts.append("In dock" if dock else "On carriage")
            c["state"].set_text("\n".join(parts) if parts else " ")
            slicer = [f"T{t}" for t, h in enumerate(mapping) if h == i]
            c["map"].set_text("Prints slicer " + ", ".join(slicer) if slicer else "Not mapped")

    # ------------------------------------------------------------------
    # TOOL VIEW: actions + filament editor
    # ------------------------------------------------------------------
    def show_tool(self, i):
        self.view = "tool"
        self.view_tool = i
        self.edit = dict(self._tool_info(i))
        self._clear()
        self.root.pack_start(self._header(f"Toolhead {i + 1} (T{i})"), False, False, 0)

        body = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)

        # left: live state + actions
        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.w["temp"] = self._label()
        left.pack_start(self.w["temp"], False, False, 0)
        actions = Gtk.Grid()
        actions.set_row_spacing(6)
        actions.set_column_spacing(6)
        actions.set_column_homogeneous(True)
        items = [
            ("extruder", "Select", "color1", self._act_select),
            ("heat-up", "Heat", "color2", self._act_heat),
            ("cool-down", "Cool", "color3", self._act_cool),
            ("arrow-down", "Load", "color1", self._act_load),
            ("arrow-up", "Unload", "color4", self._act_unload),
            ("fine-tune", "Purge", "color2", self._act_purge),
        ]
        for n, (icon, text, style, cb) in enumerate(items):
            b = self._button(icon, text, style, cb, i)
            b.set_size_request(110, 64)
            actions.attach(b, n % 2, n // 2, 1, 1)
        left.pack_start(actions, False, False, 0)
        body.pack_start(left, False, False, 0)

        # right: filament editor (scrollable)
        right = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)

        prev_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.w["e_swatch"] = self._swatch(70, 40)
        prev_row.pack_start(self.w["e_swatch"], False, False, 0)
        self.w["e_desc"] = self._label()
        self.w["e_desc"].set_halign(Gtk.Align.START)
        prev_row.pack_start(self.w["e_desc"], True, True, 0)
        save = self._button("complete", "Save", "color1", self._save_tool)
        save.set_size_request(110, 46)
        prev_row.pack_end(save, False, False, 0)
        right.pack_start(prev_row, False, False, 0)

        right.pack_start(self._section("Material"), False, False, 0)
        mats = Gtk.Grid()
        mats.set_row_spacing(4)
        mats.set_column_spacing(4)
        mats.set_column_homogeneous(True)
        for n, (name, _t) in enumerate(MATERIALS):
            b = Gtk.Button(label=name)
            b.set_size_request(-1, 38)
            b.connect("clicked", lambda _w, idx=n: self._pick_material(idx))
            mats.attach(b, n % 4, n // 4, 1, 1)
        right.pack_start(mats, False, False, 0)

        right.pack_start(self._section("Colour"), False, False, 0)
        presets = Gtk.Grid()
        presets.set_row_spacing(4)
        presets.set_column_spacing(4)
        presets.set_column_homogeneous(True)
        for n, (name, col) in enumerate(COLOR_PRESETS):
            b = Gtk.Button(label=name)
            b.set_size_request(-1, 38)
            r, g, bl = _rgb(col)
            b.override_background_color(
                Gtk.StateFlags.NORMAL, Gdk.RGBA(r / 255.0, g / 255.0, bl / 255.0, 1.0))
            light = (r * 0.299 + g * 0.587 + bl * 0.114) > 140
            b.override_color(Gtk.StateFlags.NORMAL,
                             Gdk.RGBA(0, 0, 0, 1) if light else Gdk.RGBA(1, 1, 1, 1))
            b.connect("clicked", lambda _w, c=col: self._pick_color(c))
            presets.attach(b, n % 4, n // 4, 1, 1)
        right.pack_start(presets, False, False, 0)

        self.w["sliders"] = []
        r, g, bl = _rgb(self.edit["color"])
        for n, (name, val) in enumerate((("R", r), ("G", g), ("B", bl))):
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
            row.pack_start(self._label(name), False, False, 0)
            s = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 255, 1)
            s.set_value(val)
            s.set_draw_value(True)
            s.set_value_pos(Gtk.PositionType.RIGHT)
            s.connect("value-changed", self._slider_changed)
            row.pack_start(s, True, True, 0)
            self.w["sliders"].append(s)
            right.pack_start(row, False, False, 0)

        right.pack_start(self._section("Nozzle temperature / pressure advance"), False, False, 0)
        right.pack_start(self._stepper_row("temp", "Temp", -5, 5), False, False, 0)
        right.pack_start(self._stepper_row("pa", "PA", -0.002, 0.002), False, False, 0)

        body.pack_start(self._scrolled(right), True, True, 0)
        self.root.pack_start(body, True, True, 0)
        self.root.show_all()
        self._update_editor()
        self._refresh_view()

    def _section(self, text):
        lbl = self._label()
        lbl.set_markup(f"<b>{text}</b>")
        lbl.set_halign(Gtk.Align.START)
        return lbl

    def _stepper_row(self, key, title, down, up):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        row.pack_start(self._label(title), False, False, 0)
        minus = self._button("decrease", None, "color3", self._step, key, down)
        plus = self._button("increase", None, "color3", self._step, key, up)
        for b in (minus, plus):
            b.set_size_request(70, 40)
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
        if self.view != "tool" or not self.edit:
            return
        self._set_swatch(self.w["e_swatch"], self.edit["color"])
        name = MATERIALS[self.edit["mat"]][0]
        self.w["e_desc"].set_markup(f"<b>{name}</b>   #{self.edit['color']:06X}")
        self.w["v_temp"].set_text(f"{self.edit['temp']} C")
        self.w["v_pa"].set_text(f"{self.edit['pa']:.3f}")

    def _save_tool(self):
        i = self.view_tool
        e = self.edit
        script = (f"ZR_SET_TOOL_INFO T={i} COLOR={int(e['color'])} "
                  f"MAT={int(e['mat'])} TEMP={int(e['temp'])}")
        old_pa = self._tool_info(i)["pa"]
        if abs(e["pa"] - old_pa) > 1e-6:
            script += f"\nZR_SET_TOOL_PA T={i} PA={e['pa']:.4f}"
        self._gcode(script, f"Toolhead {i + 1} saved")

    def _refresh_tool(self):
        i = self.view_tool
        cur, tgt = self._temps(i)
        fil = self._sensor(f"filament{i}")
        dock = self._sensor(f"docked{i}")
        lines = [f"<big><b>{cur:.0f} / {tgt or 0:.0f} C</b></big>" if cur is not None else "-- C"]
        if i == self._active_tool():
            lines.append("<span foreground='#4CAF50'><b>ACTIVE</b></span>")
        if fil is not None:
            lines.append("Filament OK" if fil else "No filament")
        if dock is not None:
            lines.append("In dock" if dock else "On carriage")
        self.w["temp"].set_markup("\n".join(lines))

    # tool actions --------------------------------------------------------
    def _act_select(self, i):
        if self._require_idle():
            self._confirm("Select toolhead", f"Pick up toolhead {i + 1} (T{i})?",
                          f"_CHANGE_TOOL T={i}", f"Changing to toolhead {i + 1}...")

    def _act_heat(self, i):
        temp = int(self.edit["temp"] if self.edit and self.view_tool == i
                   else self._tool_info(i)["temp"]) or 220
        self._gcode(f"SET_HEATER_TEMPERATURE HEATER={_ext_name(i)} TARGET={temp}",
                    f"Heating toolhead {i + 1} to {temp} C")

    def _act_cool(self, i):
        self._gcode(f"SET_HEATER_TEMPERATURE HEATER={_ext_name(i)} TARGET=0",
                    f"Toolhead {i + 1} heater off")

    def _act_load(self, i):
        if self._require_idle():
            self._confirm("Load filament",
                          f"Insert filament into toolhead {i + 1}, then press OK.\n"
                          "It heats to the saved temperature and feeds 100 mm.",
                          f"ZR_LOAD T={i}", "Loading...")

    def _act_unload(self, i):
        if self._require_idle():
            self._confirm("Unload filament", f"Unload filament from toolhead {i + 1}?",
                          f"ZR_UNLOAD T={i}", "Unloading...")

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
            grid.attach(self._label(f"Slicer T{t}  ->"), 0, t, 1, 1)
            for h in range(NTOOLS):
                b = Gtk.Button(label=f"Head {h + 1}")
                b.set_size_request(-1, 46)
                b.connect("clicked", lambda _w, tt=t, hh=h: self._map(tt, hh))
                grid.attach(b, 1 + h, t, 1, 1)
                self.w["map_btns"][(t, h)] = b
            sw = self._swatch(50, 30)
            sw.set_valign(Gtk.Align.CENTER)
            grid.attach(sw, 5, t, 1, 1)
            self.w["map_sw"][t] = sw
        self.root.pack_start(grid, False, False, 0)
        reset = self._button("refresh", "Reset 1:1", "color3", self._map_reset)
        reset.set_size_request(-1, 50)
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
        self.root.pack_start(self._header("Utilities"), False, False, 0)
        a = self._active_tool()
        at = a if a >= 0 else 0
        items = [
            ("home", "Home all", "G28", "Home all axes?"),
            ("fine-tune", "Offsets: fine (all)", "CALIBRATE_OFFSET_ALL_FINE_MODE",
             "Calibrate XY offsets of all toolheads (fine mode)?\nThis heats the nozzles."),
            ("fine-tune", "Offsets: rapid (all)", "CALIBRATE_OFFSET_ALL_RAPID_MODE",
             "Calibrate offsets of all toolheads (rapid mode)?"),
            ("z-farther", f"Z offset T{at}", f"CALIBRATE_TOOL_Z_OFFSET T={at}",
             f"Calibrate the Z offset of the active toolhead (T{at})?"),
            ("move", f"XY offset T{at}", f"CALIBRATE_TOOL_OFFSET T={at}",
             f"Calibrate the XY offset of the active toolhead (T{at})?"),
            ("bed-level", "Bed mesh", "BED_MESH_CALIBRATE", "Run a full bed mesh?"),
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
            b.set_size_request(-1, 70)
            grid.attach(b, n % 3, n // 3, 1, 1)
        self.root.pack_start(self._scrolled(grid), True, True, 0)
        self.root.show_all()

    def _utility(self, title, script, question):
        if self._require_idle():
            self._confirm(title, question, script, f"{title}...")

    # ------------------------------------------------------------------
    # CHAMBER VIEW
    # ------------------------------------------------------------------
    def show_chamber(self):
        self.view = "chamber"
        self._clear()
        self.root.pack_start(self._header("Chamber"), False, False, 0)
        self.w["ch_temp"] = self._label()
        self.root.pack_start(self.w["ch_temp"], False, False, 6)

        presets = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        presets.set_homogeneous(True)
        for t in (0, 40, 50, 60):
            b = self._button("heat-up" if t else "cool-down", "Off" if t == 0 else f"{t} C",
                             "color2" if t else "color3", self._chamber_set, t)
            b.set_size_request(-1, 60)
            presets.pack_start(b, True, True, 0)
        self.root.pack_start(presets, False, False, 0)

        adj = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        adj.set_homogeneous(True)
        adj.pack_start(self._button("decrease", "-5 C", "color3", self._chamber_step, -5), True, True, 0)
        adj.pack_start(self._button("increase", "+5 C", "color3", self._chamber_step, 5), True, True, 0)
        self.root.pack_start(adj, False, False, 0)

        fan = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        fan.set_homogeneous(True)
        self.w["ch_fan"] = self._label()
        fan.pack_start(self.w["ch_fan"], True, True, 0)
        fan.pack_start(self._button("fan", "Air filter ON", "color1", self._air_filter, 1), True, True, 0)
        fan.pack_start(self._button("fan-off", "Air filter OFF", "color3", self._air_filter, 0), True, True, 0)
        self.root.pack_start(fan, False, False, 0)

        self.w["ch_doors"] = self._label("", "zr_small", wrap=True)
        self.root.pack_start(self.w["ch_doors"], False, False, 6)
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
            self.w["ch_temp"].set_markup(
                f"<big><b>Chamber: {ch['temperature']:.0f} / {ch.get('target') or 0:.0f} C</b></big>")
        else:
            self.w["ch_temp"].set_text("Chamber heater not found (is zru-s.cfg included?)")
        fan = self.st.get("fan_generic air_fan")
        if isinstance(fan, dict) and fan.get("speed") is not None:
            self.w["ch_fan"].set_text(f"Air filter: {fan['speed'] * 100:.0f}%")
        else:
            self.w["ch_fan"].set_text("Air filter: --")
        doors = []
        for n in (1, 2):
            d = self.st.get(f"gcode_button Door_button{n}")
            if isinstance(d, dict) and d.get("state"):
                doors.append(f"Door switch {n}: {d['state']}")
        self.w["ch_doors"].set_text("\n".join(doors) + (
            "\n(Air filter needs air_filter=1 in tmt1.ini)" if doors else ""))

    # ------------------------------------------------------------------
    def _refresh_view(self):
        try:
            if self.view == "main":
                self._refresh_main()
            elif self.view == "tool":
                self._refresh_tool()
            elif self.view == "mapping":
                self._refresh_mapping()
            elif self.view == "chamber":
                self._refresh_chamber()
        except Exception as e:
            logging.debug(f"ZR: refresh error: {e}")

    def _add_css(self):
        css = b"""
        .zr_card { border: 2px solid #555; border-radius: 10px; background: rgba(255,255,255,0.04); }
        .zr_active { border: 3px solid #4CAF50; }
        .zr_swatch { border: 2px solid #ffffff; border-radius: 6px; }
        .zr_small { font-size: 85%; color: #bbbbbb; }
        .zr_hint { font-size: 85%; color: #999999; }
        .zr_selected { background: #2e7d32; color: #ffffff; }
        """
        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
