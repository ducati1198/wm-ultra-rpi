"""Checks of the Fluidd window macros in rpi-cfg/wm_nozzle.cfg. Usage: check_windows.py checks|restart"""
import os
import sys

s = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rpi-cfg", "wm_nozzle.cfg")).read()


def body(name):
    i = s.index("[gcode_macro %s]" % name)
    j = s.find("\n[", i + 1)
    return s[i:j if j > 0 else len(s)]


if sys.argv[1] == "checks":
    ok = True
    for n in ("_WM_NCHANGE_CHECK", "_WM_MATCH_CHECK"):
        b = body(n)
        # one macro fail(why) that opens the window and then raises, and every other stop goes through fail()
        ok = ok and "macro fail(why)" in b and "action:prompt_show" in b and b.count("action_raise_error(") == 1
    sys.exit(0 if ok else 1)
if sys.argv[1] == "restart":
    b = body("_WM_RESTART_KLIPPER")
    sys.exit(0 if 0 <= b.find("action:prompt_end") < b.find("\n    RESTART") else 1)
sys.exit(2)
