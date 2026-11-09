"""Tests for tools/devbox (the dev box branch). No Klipper, no Pi: a fake data folder and stand-in Klipper objects."""
import importlib.util, os, shutil, sys, tempfile, types, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "devbox")
TMP = tempfile.mkdtemp()
os.environ["DEVBOX_DATA"] = os.path.join(TMP, "printer_data")
os.environ["DEVBOX_ENV"] = os.path.join(TMP, "printer_data", "systemd", "klipper.env")


def load(name):
    sp = importlib.util.spec_from_file_location(name, os.path.join(TOOL, name + ".py"))
    m = importlib.util.module_from_spec(sp)
    sys.modules[name] = m
    sp.loader.exec_module(m)
    return m


D = load("devbox")
S = load("devbox_sim")


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(text)


class Tool(unittest.TestCase):
    def test_dictionary_choice(self):
        self.assertEqual(D.dict_for(""), "main")
        self.assertEqual([D.dict_for(n) for n in ("T0", "T3", "EX_T", "HUB", "CELL", "SOMETHING")],
                         ["thr", "thr", "ext", "hub", "cell", "thr"])

    def test_mcu_names_found_in_all_config_files(self):
        write(os.path.join(D.CFG, "printer.cfg"), "[mcu]\nserial: x\n[include a.cfg]\n")
        write(os.path.join(D.CFG, "a.cfg"), "[mcu T0]\ncanbus_uuid: 1\n[mcu HUB]\ncanbus_uuid: 2\n")
        write(os.path.join(D.CFG, "a.cfg.before-update"), "[mcu OLD]\n")
        self.assertEqual(sorted(D.mcu_names()), ["", "HUB", "T0"])

    def test_klipper_arguments_roundtrip_keeps_newline_and_other_options(self):
        orig = 'KLIPPER_ARGS="/k/klippy.py %s -I /c/klippy.serial -l /l/klippy.log -a /c/klippy.sock"\n' % os.path.join(D.CFG, "printer.cfg")
        write(D.ENV, orig)
        _, m = D.read_args()
        tokens = D.strip_dev_args(__import__("shlex").split(m.group(1)))
        tokens = [D.DEV_PRINTER_CFG if t == os.path.join(D.CFG, "printer.cfg") else t for t in tokens]
        tokens += ["-o", os.path.join(D.DEV, "out", "mcu"), "-d", os.path.join(D.DEV, "dict", "main.json"),
                   "-d", "T0=" + os.path.join(D.DEV, "dict", "thr.json")]
        D.write_args(tokens)
        self.assertTrue(D.is_on())
        self.assertIn(D.DEV_PRINTER_CFG, open(D.ENV).read())
        _, m = D.read_args()
        D.write_args(D.strip_dev_args(__import__("shlex").split(m.group(1))))
        self.assertFalse(D.is_on())
        self.assertEqual(open(D.ENV).read(), orig)

    def test_generated_config_has_the_stand_ins(self):
        cfg = D.DEVBOX_CFG % (3.0, "/x/saved_variables.cfg")
        for need in ("[devbox_sim]", "speed: 3.0", "filename: /x/saved_variables.cfg", "[gcode_macro LOCK]",
                     "[gcode_macro UNLOCK]", "[gcode_macro _CHECK_AND_LOCK]", "[gcode_macro _CHECK_AND_UNLOCK]", "min_extrude_temp: 0"):
            self.assertIn(need, cfg)

    def test_dictionaries_come_out_of_the_firmware_in_the_repo(self):
        if not os.path.isdir(os.path.join(ROOT, "factory")):
            self.skipTest("no factory folder")
        out = os.path.join(TMP, "dict")
        try:
            D.extract_dicts(out, quiet=True)
        except SystemExit:
            self.skipTest("firmware not in this checkout")
        import json
        main = json.load(open(os.path.join(out, "main.json")))
        self.assertIn("commands", main)
        self.assertIn("config", main)
        self.assertTrue(os.path.exists(os.path.join(out, "cell.json")))


class Obj:
    pass


class Sim(unittest.TestCase):
    def make(self):
        printer = Obj()
        heater = Obj()
        heater.target_temp = 0.
        heater.calibration_factor = 1.
        heater.last = []
        heater.temperature_callback = lambda t, v: heater.last.append(v)
        printer.objs = {"heaters": types.SimpleNamespace(heaters={"extruder": heater}), "gcode": Obj()}
        printer.objs["gcode"].register_command = lambda *a, **k: None
        printer.lookup_object = lambda n, d=None: printer.objs.get(n, d)
        printer.lookup_objects = lambda: list(printer.objs.items())
        printer.register_event_handler = lambda *a: None
        printer.get_reactor = lambda: types.SimpleNamespace(monotonic=lambda: 0.)
        printer.event_handlers = {}
        cfg = Obj()
        cfg.get_printer = lambda: printer
        cfg.getfloat = lambda n, d, **k: d
        cfg.getboolean = lambda n, d: d
        return S.DevboxSim(cfg), heater

    def test_heater_warms_up_to_target_and_cools_down(self):
        sim, h = self.make()
        sim.last = 0.
        h.target_temp = 100.
        for i in range(1, 200):
            sim._tick(i * 0.5)
        self.assertAlmostEqual(sim.state["extruder"], 100., delta=0.01)
        h.target_temp = 0.
        for i in range(200, 600):
            sim._tick(i * 0.5)
        self.assertAlmostEqual(sim.state["extruder"], 25., delta=0.01)

    def test_calibration_factor_is_divided_out(self):
        sim, h = self.make()
        h.calibration_factor = 1.25
        sim.last = 0.
        h.target_temp = 50.
        for i in range(1, 100):
            sim._tick(i * 0.5)
        self.assertAlmostEqual(h.last[-1] * 1.25, 50., delta=0.01)

    def test_changer_sensors_follow_lock_state(self):
        sim, _ = self.make()
        hall = Obj()
        hall.last_adc_value_raw = 0
        sim.printer.objs["custom_hall"] = hall
        seen = {}
        for n in ("sensor_b", "docked0", "docked1", "docked2", "docked3"):
            o = Obj()
            o.runout_helper = Obj()
            o.runout_helper.note_filament_present = (lambda name: (lambda t, p: seen.__setitem__(name, p)))(n)
            sim.printer.objs["filament_switch_sensor " + n] = o
        sim.locked, sim.held = False, None
        sim._apply_changer()
        self.assertGreaterEqual(hall.last_adc_value_raw, 4700)
        self.assertEqual((seen["sensor_b"], seen["docked0"], seen["docked3"]), (False, True, True))
        sim.pending, sim.locked, sim.held = 2, True, 2
        sim._apply_changer()
        self.assertLess(hall.last_adc_value_raw, 4700)
        self.assertEqual((seen["sensor_b"], seen["docked2"], seen["docked1"]), (True, False, True))
        sim.in_dock = 2          # back at its dock, still locked: the dock sees it
        sim._apply_changer()
        self.assertTrue(seen["docked2"])


if __name__ == "__main__":
    try:
        unittest.main(verbosity=1)
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
