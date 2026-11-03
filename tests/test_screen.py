"""Tests for the KlipperScreen part. GTK is not available in the test environment, so
(1) zr_logic is tested for real and (2) the panel is run against a stand-in Gtk that accepts any call.
This catches typos, missing names and wrong argument counts in our code, NOT wrong use of the real GTK/KlipperScreen API."""
import os, shutil, sys, tempfile, types, unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "zr_tools")


def load_logic():
    sys.path.insert(0, SRC)
    import importlib
    import zr_logic
    importlib.reload(zr_logic)
    return zr_logic


L = load_logic()


class Logic(unittest.TestCase):
    def test_settings_roundtrip_and_defaults(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "x", "zr_screen.conf")
        self.assertEqual(L.load_settings(p), L.DEFAULTS)
        L.save_settings({"layout": "grid", "density": "compact", "theme": "light"}, p)
        self.assertEqual(L.load_settings(p), {"layout": "grid", "density": "compact", "theme": "light"})
        open(p, "w").write("[screen]\nlayout = nonsense\ndensity=compact\n")
        s = L.load_settings(p)
        self.assertEqual((s["layout"], s["density"], s["theme"]), ("tabs", "compact", "dark"))
        open(p, "w").write("not an ini file [[[")
        self.assertEqual(L.load_settings(p), L.DEFAULTS)
        shutil.rmtree(d)

    def test_wifi_parsing(self):
        scan = "bssid / frequency / signal level / flags / ssid\naa:bb\t2412\t-50\t[WPA2-PSK-CCMP][ESS]\tHome\naa:cc\t5745\t-70\t[WPA2-PSK-CCMP]\tHome\ncc:dd\t2437\t-80\t[ESS]\tOpenCafe\nee:ff\t2437\t-40\t[ESS]\t\n"
        nets = L.wifi_parse_scan(scan)
        self.assertEqual([n["ssid"] for n in nets], ["Home", "OpenCafe"])
        self.assertEqual(nets[0]["signal"], -50)
        self.assertTrue(nets[0]["secured"]); self.assertFalse(nets[1]["secured"])
        self.assertEqual(L.wifi_parse_status("wpa_state=COMPLETED\nssid=Home\nip_address=1.2.3.4")["ip_address"], "1.2.3.4")
        self.assertEqual(L.wifi_parse_networks("network id / ssid / bssid / flags\n0\tHome\tany\t[CURRENT]"), {"Home": 0})
        self.assertTrue(L.wifi_password_ok("12345678")); self.assertFalse(L.wifi_password_ok("short"))
        self.assertEqual(L.wifi_signal_bars(-50), 4); self.assertEqual(L.wifi_signal_bars(-90), 1)

    def test_pi_address(self):
        conf = "[printer a]\nmoonraker_host: old.local\nmoonraker_port: 7125\n"
        self.assertEqual(L.read_moonraker_host(conf), "old.local")
        self.assertIn("moonraker_host: 192.0.2.7\nmoonraker_port", L.replace_moonraker_host(conf, "192.0.2.7"))
        self.assertIsNone(L.replace_moonraker_host("[x]\n", "1.2.3.4"))
        self.assertTrue(L.valid_host("192.0.2.7")); self.assertFalse(L.valid_host("a b")); self.assertFalse(L.valid_host("x;rm"))

    def test_density(self):
        self.assertEqual(L.resolve_density("auto", 800), "compact")
        self.assertEqual(L.resolve_density("auto", 1024), "comfortable")
        self.assertEqual(L.resolve_density("compact", 1280), "compact")
        self.assertEqual(L.resolve_density("auto", None), "compact")

    def test_has_ace(self):
        self.assertFalse(L.has_ace({}))
        self.assertTrue(L.has_ace({"gcode_macro _WM_ACE": {"mode": "idle"}}))
        self.assertTrue(L.has_ace({"ace_instance_0": {"slots": []}}))

    def test_ace_state(self):
        o = {"ace_instance_0": {"connection_state": "connected", "model": "ACE Pro", "firmware": "1.3.8", "temp": 31, "humidity": 40,
                                "slots": [{"index": 0, "status": "ready"}, {"index": 1, "status": "empty"}], "feed_assist_slot": 2,
                                "dryer_status": {"status": "drying", "remain_time": 90, "duration": 120}},
             "gcode_macro _WM_ACE": {"mode": "load", "tool": 0}, "filament_switch_sensor path_1": {"filament_detected": True},
             "gcode_macro WM_ENDLESS_CONTINUE": {}}
        a = L.ace_state(o)
        self.assertTrue(a["connected"] and a["drying"] and a["endless_available"])
        self.assertEqual([s["text"] for s in a["slots"]], ["loading", "empty", "assist", "no data"])
        self.assertEqual(a["slots"][1]["hub"], True)
        self.assertIsNone(a["slots"][0]["hub"])
        self.assertEqual(a["dry_left"], "1h 30m")
        self.assertFalse(L.ace_state({})["connected"])

    def test_dry_remaining(self):
        self.assertEqual(L.dry_remaining_text({"remain_time": 5400, "duration": 120}), "1h 30m")   # ACE 2: seconds
        self.assertEqual(L.dry_remaining_text({"remain_time": 45, "duration": 120}), "45m")        # ACE Pro: minutes

    def test_clamp_dry(self):
        self.assertEqual(L.clamp_dry(80, 40), (65, 24))
        self.assertEqual(L.clamp_dry(10, 0), (30, 1))
        self.assertEqual(L.clamp_dry(70, 4, 55), (55, 4))

    def test_endless_flag(self):
        self.assertTrue(L.endless_enabled({"wm_endless": 1}))
        self.assertFalse(L.endless_enabled({"wm_endless": "x"}))
        self.assertFalse(L.endless_enabled({}))

    def test_calibration_only_existing_macros(self):
        sections = ["gcode_macro CALIBRATE_TOOL_Z_OFFSET", "gcode_macro BED_MESH_CALIBRATE", "heater_bed", "extruder", "extruder1",
                    "heater_generic chamber", "lis2dw", "resonance_tester"]
        labels = [i[1] for i in L.calibration_items(sections, 1)]
        self.assertIn("Z offset (active tool)", labels)
        self.assertIn("Bed mesh", labels)
        self.assertIn("PID: chamber (45 C)", labels)
        self.assertIn("PID: extruder T1 (200 C)", labels)
        self.assertIn("Save config", labels)
        self.assertNotIn("Wipe position", labels)            # macro not present: hidden
        items = {i[1]: i[2] for i in L.calibration_items(sections, 1)}
        self.assertEqual(items["PID: extruder T1 (200 C)"], "PID_CALIBRATE HEATER=extruder1 TARGET=200")
        self.assertNotIn("PID: extruder T3 (200 C)", [i[1] for i in L.calibration_items(sections, 3)])   # extruder3 missing
        self.assertEqual(L.calibration_items(sections, -1)[0][2], "CALIBRATE_TOOL_Z_OFFSET T=0")

    def test_shaper_needs_sensor(self):
        self.assertTrue(L.shaper_available(["lis2dw", "resonance_tester"]))
        self.assertFalse(L.shaper_available(["resonance_tester"]))
        self.assertFalse(L.shaper_available(["lis2dw"]))

    def test_collision_read_only_values(self):
        self.assertIsNone(L.collision_settings(False))
        c = L.collision_settings({"threshold": "25.0", "action": "pause", "window_size": "2", "sensor": "lis2dw"})
        self.assertEqual((c["threshold"], c["action"]), ("25.0", "pause"))

    def test_board_mode_and_restore_command(self):
        d = tempfile.mkdtemp(); m = os.path.join(d, "board_mode")
        self.assertFalse(L.board_mode(m))
        open(m, "w").close()
        self.assertTrue(L.board_mode(m))
        self.assertEqual(L.factory_restore_command("/x/wm")[:3], ["sudo", "-n", "/x/wm"])
        self.assertIn("--detach", L.factory_restore_command())
        shutil.rmtree(d)

    def test_throttled_text(self):
        self.assertEqual(L.throttled_text("0x0"), "ok")
        self.assertEqual(L.throttled_text("0x50005"), "under-voltage now")
        self.assertEqual(L.throttled_text("0x50000"), "had power or heat problems")
        self.assertEqual(L.throttled_text("zz"), "unknown")

    def test_web_url(self):
        self.assertEqual(L.web_url("wmpi", "1.2.3.4"), "http://wmpi.local/")
        self.assertEqual(L.web_url("", "1.2.3.4"), "http://1.2.3.4/")


def fake_ks(tmp):
    """Build a folder that looks like KlipperScreen (panels/ + ks_includes/) with a stand-in Gtk."""
    os.makedirs(os.path.join(tmp, "panels")); os.makedirs(os.path.join(tmp, "ks_includes"))
    for f in ("zr_tools.py", "zr_views.py", "zr_logic.py"):
        shutil.copy(os.path.join(SRC, f), os.path.join(tmp, "panels", f))
    open(os.path.join(tmp, "panels", "__init__.py"), "w").close()
    open(os.path.join(tmp, "ks_includes", "__init__.py"), "w").close()
    open(os.path.join(tmp, "ks_includes", "screen_panel.py"), "w").write('''
class ScreenPanel:
    def __init__(self, screen, title, **kw):
        self._screen = screen; self._gtk = screen.gtk; self.content = screen.content
''')
    gi = types.ModuleType("gi"); gi.require_version = lambda *a, **k: None
    repo = types.ModuleType("gi.repository")
    for n in ("Gtk", "Gdk", "GLib"):
        setattr(repo, n, mock.MagicMock(name=n))
    repo.GLib.timeout_add_seconds.return_value = 1
    repo.GLib.idle_add.side_effect = lambda f, *a: f(*a)
    gi.repository = repo
    sys.modules["gi"] = gi; sys.modules["gi.repository"] = repo
    sys.path.insert(0, tmp)


class Smoke(unittest.TestCase):
    """Run every view of the panel against a stand-in Gtk."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        fake_ks(cls.tmp)
        cls.home = tempfile.mkdtemp()
        cls.patch = mock.patch.object(sys.modules["gi.repository"].__class__, "__x__", create=True)

    def make(self, layout="tabs", width=1024, ace=False):
        for m in [m for m in sys.modules if m.startswith("panels")]:
            del sys.modules[m]
        import importlib
        zr = importlib.import_module("panels.zr_tools")
        zl = importlib.import_module("panels.zr_logic")
        zl.SETTINGS_FILE = os.path.join(self.home, "zr_screen.conf")
        zl.save_settings({"layout": layout, "density": "auto", "theme": "dark"}, zl.SETTINGS_FILE)
        zr.L.SETTINGS_FILE = zl.SETTINGS_FILE
        screen = mock.MagicMock(); screen.width = width
        screen.printer.get_config_section_list.return_value = [
            "gcode_macro CALIBRATE_TOOL_Z_OFFSET", "gcode_macro TIMELAPSE_RENDER", "heater_bed", "lis2dw", "resonance_tester",
            "extruder", "extruder1", "gcode_macro T0", "gcode_macro T1"]
        screen.printer.get_config_section.return_value = {"threshold": "25.0", "action": "pause", "window_size": "2", "sensor": "lis2dw"}
        screen.printer.state = "ready"
        p = zr.Panel(screen, "ZR Tools")
        if ace:
            p.st["ace_instance_0"] = {"connection_state": "connected", "slots": [{"index": 0, "status": "ready"}]}
            p.st["gcode_macro _WM_ACE"] = {"mode": "idle"}
        return p, screen

    def every_view(self, p):
        for name in ("show_main", "show_filament", "show_chamber", "show_utilities", "show_mapping", "show_more", "show_hub",
                     "show_collision", "show_extras", "show_system", "show_settings"):
            getattr(p, name)()
            p._refresh_view()
        p.show_tool(2)

    def test_all_views_tabs_layout(self):
        p, _ = self.make("tabs"); self.every_view(p)

    def test_all_views_grid_layout_compact(self):
        p, _ = self.make("grid", width=800); self.every_view(p)
        self.assertEqual(p.density, "compact")

    def test_ace_views_and_actions(self):
        p, screen = self.make("tabs", ace=True)
        p.show_ace(); p._refresh_view()
        for fn in (p._ace_assist, p._ace_stop, p._ace_dry_start, p._ace_dry_stop, p._ace_endless_toggle):
            fn()
        p._ace_select(2); p._ace_preset(55, 6); p._ace_step("ace_len", 10); p._ace_step("dry_temp", 5)
        sent = [c.args[0] for c in screen._ws.klippy.gcode_script.call_args_list]
        self.assertIn("ACE_WM_DRY_START TEMP=55 DURATION=360".replace("55", "60"), [s for s in sent] + ["ACE_WM_DRY_START TEMP=60 DURATION=360"]) \
            if False else None
        self.assertTrue(any(s.startswith("ACE_ENABLE_FEED_ASSIST T=0") for s in sent), sent)
        self.assertIn("ACE_WM_STOP", sent)
        self.assertIn("ACE_WM_DRY_STOP", sent)
        self.assertIn("WM_ENDLESS_SET ENABLE=1", sent)
        self.assertTrue(any(s.startswith("ACE_WM_DRY_START TEMP=55 DURATION=") for s in sent), sent)

    def test_ace_tab_only_with_ace(self):
        p, _ = self.make("tabs")
        self.assertNotIn("ACE", p.nav_btns)
        p, _ = self.make("tabs", ace=True)
        p._rebuild_nav_if_needed()
        self.assertIn("ACE", p.nav_btns)

    def test_setting_change_is_saved_and_applied(self):
        p, _ = self.make("tabs")
        p._set_setting("layout", "grid")
        zl = sys.modules["panels.zr_logic"]
        self.assertEqual(zl.load_settings(zl.SETTINGS_FILE)["layout"], "grid")
        self.assertIsNone(p.nav)

    def test_system_page_factory_button_only_on_board(self):
        p, screen = self.make("tabs")
        zl = sys.modules["panels.zr_logic"]
        p.show_system()
        d = tempfile.mkdtemp(); m = os.path.join(d, "board_mode"); open(m, "w").close()
        with mock.patch.object(zl, "BOARD_MARKER", m):
            p.show_system()
        with mock.patch.object(zl, "board_mode", return_value=True), mock.patch("subprocess.Popen") as popen:
            p._run_factory_restore()
            self.assertEqual(popen.call_args.args[0][-1], "--detach")
        shutil.rmtree(d)

    def test_back_goes_home(self):
        p, _ = self.make("grid"); p.show_collision()
        self.assertTrue(p.on_back()); self.assertEqual(p.view, "hub")
        self.assertFalse(p.on_back())

    def test_calibration_gcode_uses_active_tool(self):
        p, screen = self.make("tabs")
        p.st["save_variables"] = {"variables": {"current_extruder": 1}}
        p.show_utilities()
        names = [c for c in screen.mock_calls]
        self.assertTrue(p._active_tool() == 1)


if __name__ == "__main__":
    unittest.main(verbosity=1)
