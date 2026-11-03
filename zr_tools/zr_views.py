# ZR Tools: the extra views (hub, ACE Pro, calibration, collision, system, settings, extras).
# Mixed into the ZR Tools Panel (zr_tools.py). Uses only helpers the Panel already has:
#   _clear, _label, _button, _header, _scrolled, _confirm, _gcode, _require_idle, _vars, _active_tool, _busy
# KlipperScreen panels are loaded as "panels.<name>", so the logic module is imported from there.

import logging
import os
import socket
import subprocess

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib  # noqa: E402

try:
    from panels import zr_logic as L
except ImportError:                      # tests import it from the same folder
    import zr_logic as L

NTOOLS = 4


class ViewsMixin:

    # ------------------------------------------------------------------
    # small helpers
    # ------------------------------------------------------------------
    def _sections(self):
        try:
            return list(self._screen.printer.get_config_section_list(""))
        except Exception:
            return []

    def _tile_grid(self, items, cols=None):
        """items: (icon, label, callback). A homogeneous grid of buttons."""
        cols = cols or self.sz["cols"]
        grid = Gtk.Grid()
        grid.set_row_spacing(6)
        grid.set_column_spacing(6)
        grid.set_column_homogeneous(True)
        for n, (icon, label, cb) in enumerate(items):
            b = self._button(icon, label, "color%d" % (1 + n % 4), cb)
            b.set_size_request(-1, self.sz["tile_h"])
            grid.attach(b, n % cols, n // cols, 1, 1)
        return grid

    def _open_stock(self, panel, title):
        try:
            self._screen.show_panel(panel, title)
        except Exception as e:
            logging.error(f"ZR: could not open panel {panel}: {e}")
            self._screen.show_popup_message("Could not open %s." % title)

    def _row(self, *widgets, spacing=6):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=spacing)
        row.set_homogeneous(True)
        for w in widgets:
            row.pack_start(w, True, True, 0)
        return row

    def _seg(self, options, current, callback):
        """A row of buttons where `current` is highlighted."""
        buttons = {}

        def _pick(value):
            callback(value)

        for value, text in options:
            b = self._button(None, text, "color3", _pick, value)
            b.set_size_request(-1, self.sz["btn_h"])
            if value == current:
                b.get_style_context().add_class("zr_selected")
            buttons[value] = b
        return self._row(*buttons.values()), buttons

    # ------------------------------------------------------------------
    # HUB: every entry in one place (grid layout home, and the "More" tab)
    # ------------------------------------------------------------------
    def _hub_items(self, include_main=True):
        st = self.st
        items = []
        if include_main:
            items += [("toolchanger", "Toolheads", self.show_main),
                      ("filament", "Filament", self.show_filament),
                      ("heat-up", "Chamber / air", self.show_chamber),
                      ("settings", "Calibration", self.show_utilities)]
        if L.has_ace(st):
            items.append(("spool", "ACE Pro", self.show_ace))
        items += [("shuffle", "Choose toolheads", self.show_mapping),
                  ("fan", "Fans", lambda: self._open_stock("fan", "Fan")),
                  ("z-farther", "Z offset", lambda: self._open_stock("fine_tune", "Fine tuning")),
                  ("retract", "Pressure advance", lambda: self._open_stock("pressure_advance", "Pressure advance"))]
        if L.shaper_available(self._sections()):
            items.append(("speed+", "Input shaper", lambda: self._open_stock("input_shaper", "Input shaper")))
        if L.collision_settings(self._collision_section()):
            items.append(("warning", "Collision", self.show_collision))
        items += [("camera", "Camera", lambda: self._open_stock("camera", "Camera")),
                  ("clock", "Timelapse / restart", self.show_extras),
                  ("info", "System", self.show_system),
                  ("settings", "Screen settings", self.show_settings)]
        return items

    def show_hub(self, title="ZR Tools", include_main=True):
        self.view = "hub" if include_main else "more"
        self._clear()
        self.root.pack_start(self._header(title), False, False, 0)
        self.root.pack_start(self._scrolled(self._tile_grid(self._hub_items(include_main))), True, True, 0)
        self.root.show_all()

    def show_more(self):
        self.show_hub("More", include_main=False)
        self.view = "more"

    # ------------------------------------------------------------------
    # FILAMENT (the existing tool view: heat, load, unload, purge, colour/material/PA editor)
    # ------------------------------------------------------------------
    def show_filament(self):
        self.show_tool(max(self._active_tool(), 0))
        self.view = "tool"

    # ------------------------------------------------------------------
    # ACE PRO (only reachable when an ACE exists; same macros as the Fluidd panel)
    # ------------------------------------------------------------------
    def show_ace(self):
        self.view = "ace"
        self.ace_slot = getattr(self, "ace_slot", 0)
        self.dry_temp = getattr(self, "dry_temp", 55)
        self.dry_hours = getattr(self, "dry_hours", 6)
        self.ace_len = getattr(self, "ace_len", 50)
        self.ace_speed = getattr(self, "ace_speed", 5)
        self._clear()
        self.root.pack_start(self._header("ACE Pro"), False, False, 0)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.w["ace_info"] = self._label("", "zr_small")
        body.pack_start(self.w["ace_info"], False, False, 0)

        slots = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        slots.set_homogeneous(True)
        self.w["ace_slots"] = []
        for i in range(NTOOLS):
            b = self._button(None, "T%d" % (i + 1), "color3", self._ace_select, i)
            b.set_size_request(-1, self.sz["btn_h"])
            slots.pack_start(b, True, True, 0)
            self.w["ace_slots"].append(b)
        body.pack_start(slots, False, False, 0)

        act = [("load", "Load from ACE", self._ace_load), ("retract", "Unload to ACE", self._ace_unload),
               ("fan", "Feed assist", self._ace_assist), ("stop", "Stop motor", self._ace_stop)]
        body.pack_start(self._tile_grid(act, cols=2 if self.density == "compact" else 4), False, False, 0)

        mv = [("arrow-down", "Feed", self._ace_feed), ("arrow-up", "Retract", self._ace_retract)]
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self.w["ace_len_lbl"] = self._label("", "zr_small")
        self.w["ace_speed_lbl"] = self._label("", "zr_small")
        for text, key, step in (("Length -", "ace_len", -10), ("Length +", "ace_len", 10),
                                ("Speed -", "ace_speed", -1), ("Speed +", "ace_speed", 1)):
            b = self._button(None, text, "color3", self._ace_step, key, step)
            b.set_size_request(-1, self.sz["btn_h"] - 10)
            row.pack_start(b, True, True, 0)
        body.pack_start(row, False, False, 0)
        body.pack_start(self.w["ace_len_lbl"], False, False, 0)
        body.pack_start(self._tile_grid(mv, cols=2), False, False, 0)

        body.pack_start(self._label("Dryer", "zr_small"), False, False, 0)
        pres = Gtk.Grid()
        pres.set_column_spacing(6)
        pres.set_row_spacing(6)
        pres.set_column_homogeneous(True)
        for n, (name, temp, hours) in enumerate(L.DRY_PRESETS):
            b = self._button(None, name, "color3", self._ace_preset, temp, hours)
            b.set_size_request(-1, self.sz["btn_h"] - 14)
            pres.attach(b, n % 3, n // 3, 1, 1)
        body.pack_start(pres, False, False, 0)
        drow = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        for text, key, step in (("Temp -", "dry_temp", -5), ("Temp +", "dry_temp", 5),
                                ("Hours -", "dry_hours", -1), ("Hours +", "dry_hours", 1)):
            b = self._button(None, text, "color3", self._ace_step, key, step)
            b.set_size_request(-1, self.sz["btn_h"] - 10)
            drow.pack_start(b, True, True, 0)
        body.pack_start(drow, False, False, 0)
        self.w["dry_lbl"] = self._label("", "zr_small")
        body.pack_start(self.w["dry_lbl"], False, False, 0)
        body.pack_start(self._row(self._button("heat-up", "Start drying", "color1", self._ace_dry_start),
                                  self._button("stop", "Stop drying", "color3", self._ace_dry_stop)), False, False, 0)

        if L.ace_state(self.st)["endless_available"]:
            body.pack_start(self._label("Endless spool (experimental): when a head runs out, the print pauses; "
                                        "use Swap & continue in Fluidd.", "zr_hint", wrap=True), False, False, 0)
            self.w["endless"] = self._button("shuffle", "", "color3", self._ace_endless_toggle)
            self.w["endless"].set_size_request(-1, self.sz["btn_h"])
            body.pack_start(self.w["endless"], False, False, 0)
        self.root.pack_start(self._scrolled(body), True, True, 0)
        self.root.show_all()
        self._refresh_ace()

    def _refresh_ace(self):
        if "ace_info" not in self.w:
            return
        a = L.ace_state(self.st)
        t = []
        t.append("%s %s: %s" % (a["model"], a["firmware"], a["state"]))
        if a["temp"] is not None:
            t.append("%s C" % a["temp"])
        if a["humidity"] is not None:
            t.append("%s %% RH" % a["humidity"])
        if a["drying"]:
            t.append("drying, %s left" % a["dry_left"])
        self.w["ace_info"].set_text("   ".join(t))
        for i, b in enumerate(self.w["ace_slots"]):
            s = a["slots"][i]
            hub = "-" if s["hub"] is None else ("hub on" if s["hub"] else "hub off")
            b.set_label("T%d %s\n%s" % (i + 1, s["text"], hub))
            ctx = b.get_style_context()
            if i == self.ace_slot:
                ctx.add_class("zr_selected")
            else:
                ctx.remove_class("zr_selected")
        self.w["ace_len_lbl"].set_text("Manual move: %d mm at %d mm/s (slot T%d)" % (self.ace_len, self.ace_speed, self.ace_slot + 1))
        self.w["dry_lbl"].set_text("Drying: %d C for %d h (max %s C)" % (self.dry_temp, self.dry_hours, a["max_temp"]))
        if "endless" in self.w:
            self.w["endless"].set_label("Endless spool: %s (tap to switch)" % ("ON" if L.endless_enabled(self._vars()) else "off"))

    def _ace_select(self, i):
        self.ace_slot = i
        self._refresh_ace()

    def _ace_idle_gate(self):
        return self._require_idle()

    def _ace_load(self):
        if self._ace_idle_gate():
            self._confirm("Load from ACE", "Feed slot T%d to the toolhead and load it?" % (self.ace_slot + 1),
                          "ACE_WM_LOAD T=%d" % self.ace_slot, "ACE loading T%d" % (self.ace_slot + 1))

    def _ace_unload(self):
        if self._ace_idle_gate():
            self._confirm("Unload to ACE", "Unload toolhead T%d and pull the filament back into the ACE?" % (self.ace_slot + 1),
                          "ACE_WM_UNLOAD T=%d" % self.ace_slot, "ACE unloading T%d" % (self.ace_slot + 1))

    def _ace_assist(self):
        a = L.ace_state(self.st)["slots"][self.ace_slot]["assist"]
        cmd = "ACE_DISABLE_FEED_ASSIST" if a else "ACE_ENABLE_FEED_ASSIST"
        self._gcode("%s T=%d" % (cmd, self.ace_slot), "Feed assist %s" % ("off" if a else "on"))

    def _ace_stop(self):
        self._gcode("ACE_WM_STOP", "ACE stopped")

    def _ace_feed(self):
        if self._ace_idle_gate():
            self._gcode("ACE_FEED T=%d LENGTH=%d SPEED=%d" % (self.ace_slot, self.ace_len, self.ace_speed), "ACE feeding")

    def _ace_retract(self):
        if self._ace_idle_gate():
            self._gcode("ACE_RETRACT T=%d LENGTH=%d SPEED=%d" % (self.ace_slot, self.ace_len, self.ace_speed), "ACE retracting")

    def _ace_step(self, key, step):
        if key == "ace_len":
            self.ace_len = max(10, min(500, self.ace_len + step))
        elif key == "ace_speed":
            self.ace_speed = max(1, min(30, self.ace_speed + step))
        elif key == "dry_temp":
            self.dry_temp, self.dry_hours = L.clamp_dry(self.dry_temp + step, self.dry_hours, L.ace_state(self.st)["max_temp"])
        elif key == "dry_hours":
            self.dry_temp, self.dry_hours = L.clamp_dry(self.dry_temp, self.dry_hours + step, L.ace_state(self.st)["max_temp"])
        self._refresh_ace()

    def _ace_preset(self, temp, hours):
        self.dry_temp, self.dry_hours = L.clamp_dry(temp, hours, L.ace_state(self.st)["max_temp"])
        self._refresh_ace()

    def _ace_dry_start(self):
        self._gcode("ACE_WM_DRY_START TEMP=%d DURATION=%d" % (self.dry_temp, self.dry_hours * 60), "Drying started")

    def _ace_dry_stop(self):
        self._gcode("ACE_WM_DRY_STOP", "Drying stopped")

    def _ace_endless_toggle(self):
        on = L.endless_enabled(self._vars())
        self._gcode("WM_ENDLESS_SET ENABLE=%d" % (0 if on else 1), "Endless spool %s" % ("off" if on else "on"))

    # ------------------------------------------------------------------
    # CALIBRATION (only macros that exist on this printer)
    # ------------------------------------------------------------------
    def show_utilities(self):
        self.view = "utilities"
        self._clear()
        self.root.pack_start(self._header("Calibration"), False, False, 0)
        a = self._active_tool()
        items = [("home", "Home all", "G28", "Home all axes?")]
        items += [(i, l, s, q) for (i, l, s, q, _r) in L.calibration_items(self._sections(), a)]
        items += [("extruder", "Park tool", "PARK_CURRENT_TOOL", "Return the active toolhead to its dock?"),
                  ("motor-off", "Motors off", "M84", "Disable all motors?"),
                  ("unlock", "Unlock gripper", "UNLOCK", "Open the toolhead gripper?"),
                  ("lock", "Lock gripper", "LOCK", "Close the toolhead gripper?")]
        tiles = []
        for icon, text, script, question in items:
            tiles.append((icon, text, (lambda t=text, s=script, q=question: self._utility(t, s, q))))
        if L.shaper_available(self._sections()):
            tiles.append(("speed+", "Input shaper", lambda: self._open_stock("input_shaper", "Input shaper")))
        else:
            tiles.append(("speed+", "Input shaper (not available)", lambda: self._screen.show_popup_message(
                "Needs the LIS2DW sensor on the tool-changer board (EX_T) and [resonance_tester].")))
        self.root.pack_start(self._scrolled(self._tile_grid(tiles)), True, True, 0)
        self.root.show_all()

    # ------------------------------------------------------------------
    # COLLISION (read-only on purpose)
    # ------------------------------------------------------------------
    def _collision_section(self):
        try:
            return self._screen.printer.get_config_section("collision_detect")
        except Exception:
            return None

    def show_collision(self):
        self.view = "collision"
        self._clear()
        self.root.pack_start(self._header("Collision detection"), False, False, 0)
        c = L.collision_settings(self._collision_section())
        if not c:
            text = "No [collision_detect] section in the printer config."
        else:
            text = ("Sensor: %s\nThreshold: %s m/s^2\nWindow: %s samples\nAction on impact: %s\n\n"
                    "Read-only on purpose. To change the threshold edit change_extruder.cfg "
                    "([collision_detect]) and restart Klipper. WonderMaker's tool-offset macros switch "
                    "the detection on and off by themselves."
                    % (c["sensor"], c["threshold"], c["window"], c["action"]))
        self.root.pack_start(self._label(text, wrap=True), True, True, 0)
        self.root.show_all()

    # ------------------------------------------------------------------
    # TIMELAPSE / RESTART / TEST TOOL CHANGE
    # ------------------------------------------------------------------
    def show_extras(self):
        self.view = "extras"
        self._clear()
        self.root.pack_start(self._header("Timelapse and restart"), False, False, 0)
        have = {s.upper() for s in self._sections()}
        a = self._active_tool()
        nxt = (a + 1) % NTOOLS if a >= 0 else 0
        entries = [("camera", "Take frame", "TIMELAPSE_TAKE_FRAME", "Take one timelapse frame now?", "GCODE_MACRO TIMELAPSE_TAKE_FRAME"),
                   ("complete", "Render video", "TIMELAPSE_RENDER", "Render the timelapse video now?", "GCODE_MACRO TIMELAPSE_RENDER"),
                   ("refresh", "Restart Klipper", "RESTART", "Restart Klipper (reload the config)?", None),
                   ("refresh", "Firmware restart", "FIRMWARE_RESTART", "Firmware restart? This resets the MCUs.", None),
                   ("toolchanger", "Test change to T%d" % nxt, "T%d" % nxt, "Change to toolhead T%d now?\nThe printer must be homed." % nxt, "GCODE_MACRO T%d" % nxt)]
        tiles = []
        for icon, text, script, q, need in entries:
            if need is None or need in have:
                tiles.append((icon, text, (lambda t=text, s=script, qq=q: self._utility(t, s, qq))))
        self.root.pack_start(self._scrolled(self._tile_grid(tiles)), True, True, 0)
        self.root.show_all()

    # ------------------------------------------------------------------
    # SYSTEM
    # ------------------------------------------------------------------
    def show_system(self):
        self.view = "system"
        self._clear()
        self.root.pack_start(self._header("System"), False, False, 0)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.w["sys"] = self._label("", wrap=True)
        body.pack_start(self.w["sys"], False, False, 0)
        tiles = [("sd", "Backup settings", self._sys_backup),
                 ("refresh", "Reboot", self._sys_reboot),
                 ("shutdown", "Shut down", self._sys_shutdown)]
        body.pack_start(self._tile_grid(tiles), False, False, 0)
        self.root.pack_start(self._scrolled(body), True, True, 0)
        self.root.show_all()
        self._refresh_system()

    def _read_flags(self):
        try:
            out = subprocess.run(["vcgencmd", "get_throttled"], capture_output=True, text=True, timeout=2).stdout
            return out.split("=")[-1].strip()
        except Exception:
            return ""

    def _refresh_system(self):
        if "sys" not in self.w:
            return
        temp = L.read_pi_temp()
        flags = self._read_flags()
        try:
            host = socket.gethostname()
            ip = socket.gethostbyname(host)
        except OSError:
            host, ip = "", ""
        can = "down or missing"
        try:
            with open("/sys/class/net/can0/operstate") as f:
                can = "up" if f.read().strip() in ("up", "unknown") else "down"
        except OSError:
            pass
        try:
            kstate = self._screen.printer.state
        except Exception:
            kstate = "unknown"
        lines = ["Pi temperature: %s" % ("%.0f C" % temp if temp is not None else "unknown"),
                 "Power: %s" % (L.throttled_text(flags) if flags else "unknown"),
                 "can0: %s" % can, "Klipper: %s" % kstate,
                 "Fluidd: %s" % (L.web_url(host, ip) or "unknown")]
        self.w["sys"].set_text("\n".join(lines))

    def _install_dir(self):
        try:
            with open(os.path.expanduser("~/wm-rpi-backup/install.conf")) as f:
                for line in f:
                    if line.startswith("REPO_DIR="):
                        return line.split("=", 1)[1].strip()
        except OSError:
            pass
        return ""

    def _sys_backup(self):
        repo = self._install_dir()
        if not repo or not os.path.exists(os.path.join(repo, "installer.sh")):
            self._screen.show_popup_message("Installer folder not found. Run ./installer.sh --backup in a terminal.")
            return

        def _go():
            try:
                subprocess.Popen(["bash", os.path.join(repo, "installer.sh"), "--backup"],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self._screen.show_popup_message("Backup started. It is saved in ~/wm-backups.", 1)
            except OSError as e:
                self._screen.show_popup_message("Backup failed: %s" % e)
        self._confirm_call("Backup", "Save your config, calibration and database to ~/wm-backups?", _go)

    def _confirm_call(self, title, text, func):
        label = Gtk.Label(label=text)
        label.set_line_wrap(True)
        buttons = [{"name": "Cancel", "response": Gtk.ResponseType.CANCEL},
                   {"name": "OK", "response": Gtk.ResponseType.OK}]

        def _resp(dialog, response_id):
            self._gtk.remove_dialog(dialog)
            if response_id == Gtk.ResponseType.OK:
                func()
        self._gtk.Dialog(title, buttons, label, _resp)

    def _sys_reboot(self):
        if self._require_idle():
            self._confirm_call("Reboot", "Reboot the Pi?", lambda: self._screen._ws.send_method("machine.reboot"))

    def _sys_shutdown(self):
        if self._require_idle():
            self._confirm_call("Shut down", "Shut the Pi down?", lambda: self._screen._ws.send_method("machine.shutdown"))

    # ------------------------------------------------------------------
    # SCREEN SETTINGS (layout, density, theme)
    # ------------------------------------------------------------------
    def show_settings(self):
        self.view = "settings"
        self._clear()
        self.root.pack_start(self._header("Screen settings"), False, False, 0)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        for key, title, options in (
                ("layout", "Layout", [("tabs", "Big touch + tabs"), ("grid", "Card grid")]),
                ("density", "Size", [("auto", "Auto (%s)" % self.density), ("compact", "Compact"), ("comfortable", "Comfortable")]),
                ("theme", "Colours of these pages", [("dark", "Dark"), ("light", "Light")])):
            body.pack_start(self._label(title, "zr_small"), False, False, 0)
            row, _btns = self._seg(options, self.settings[key], (lambda v, k=key: self._set_setting(k, v)))
            body.pack_start(row, False, False, 0)
        body.pack_start(self._label("For a fully light screen also choose the material-light icon theme in KlipperScreen's "
                                    "own Configuration page. Saved in ~/printer_data/config/zr_screen.conf.", "zr_hint", wrap=True),
                        False, False, 0)
        self.root.pack_start(self._scrolled(body), True, True, 0)
        self.root.show_all()

    def _set_setting(self, key, value):
        self.settings[key] = value
        try:
            L.save_settings(self.settings)
        except OSError as e:
            self._screen.show_popup_message("Could not save the settings: %s" % e)
        self._apply_settings()
        self.show_settings()

    # ------------------------------------------------------------------
    # live refresh hook (called from the Panel's _refresh_view)
    # ------------------------------------------------------------------
    def refresh_extra_views(self):
        if self.view == "ace":
            self._refresh_ace()
        elif self.view == "system":
            self._refresh_system()
        elif self.view in ("hub", "more"):
            pass
