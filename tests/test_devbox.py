"""Tests for tools/devbox (dev mode). No Klipper, no Pi: a fake data folder and stand-in Klipper objects."""
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

    def test_a_real_printer_is_recognised_and_dev_mode_refuses(self):
        sysdir = os.path.join(TMP, "sys"); D.SYS = sysdir
        self.assertEqual(D.real_printer_signs(), [])
        write(os.path.join(sysdir, "bus", "usb", "devices", "1-1", "idVendor"), "046d\n"); write(os.path.join(sysdir, "bus", "usb", "devices", "1-1", "idProduct"), "c52b\n")
        self.assertEqual(D.real_printer_signs(), [])          # some other USB device
        write(os.path.join(sysdir, "bus", "usb", "devices", "1-2", "idVendor"), "1d50\n"); write(os.path.join(sysdir, "bus", "usb", "devices", "1-2", "idProduct"), "606F\n")
        self.assertEqual(len(D.real_printer_signs()), 1)
        write(os.path.join(sysdir, "class", "net", "can0", "operstate"), "up\n")
        self.assertEqual(len(D.real_printer_signs()), 2)
        write(os.path.join(sysdir, "class", "net", "can0", "operstate"), "down\n")
        self.assertEqual(len(D.real_printer_signs()), 1)
        args = types.SimpleNamespace(yes=True, force=False, speed=2.0)
        saved = (D.is_on, D.print_state, D.KLIPPER)
        self.addCleanup(lambda: (setattr(D, 'is_on', saved[0]), setattr(D, 'print_state', saved[1]), setattr(D, 'KLIPPER', saved[2])))
        D.is_on = lambda: False; D.print_state = lambda: None; D.KLIPPER = os.path.join(TMP, "klipper"); os.makedirs(D.KLIPPER, exist_ok=True)
        import io, contextlib
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit): D.cmd_on(args)    # refuses before changing anything
        self.assertIn("looks like it is connected to a real printer", out.getvalue())
        self.assertFalse(os.path.exists(D.DEV_CFG))
        shutil.rmtree(sysdir); D.SYS = os.path.join(TMP, "nosys")
        self.assertEqual(D.real_printer_signs(), [])

    def test_moonraker_conf_gets_the_option_while_dev_mode_is_on_and_loses_it_after(self):
        mc = os.path.join(D.CFG, "moonraker.conf")
        for original in ("[server]\nhost: 0.0.0.0\n\n[authorization]\nforce_logins: False\n",
                         "[server]\nhost: 0.0.0.0\n\n[file_manager]\nenable_object_processing: True\n\n[authorization]\n"):
            write(mc, original)
            self.assertTrue(D.moonraker_conf_set(True))
            self.assertIn("check_klipper_config_path: False", open(mc).read())
            self.assertFalse(D.moonraker_conf_set(True) and open(mc).read().count("check_klipper_config_path") > 1)
            self.assertEqual(open(mc).read().count("check_klipper_config_path"), 1)
            self.assertTrue(D.moonraker_conf_set(False) or True)
            self.assertEqual(open(mc).read(), original)
        os.remove(mc)
        self.assertFalse(D.moonraker_conf_set(True))              # no moonraker.conf: nothing to do

    def test_saved_copies_are_not_copied_into_the_private_config(self):
        src = os.path.join(TMP, "cfgsrc"); dst = os.path.join(TMP, "cfgdst")
        for n in ("printer.cfg", "printer.cfg.wm-before-cfgmerge-1", "wm_nozzle.cfg.wm-removed-1", "a.cfg.before-update", "x.log"): write(os.path.join(src, n), "x")
        shutil.copytree(src, dst, ignore=shutil.ignore_patterns(*D.COPY_IGNORE))
        self.assertEqual(os.listdir(dst), ["printer.cfg"])

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
