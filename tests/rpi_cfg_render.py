#!/usr/bin/env python3
"""Renders every macro of rpi-cfg/wm_calibration.cfg with jinja2 (Klipper style: { } for expressions) and a mock printer.
Run: python3 tests/rpi_cfg_render.py      (needs jinja2; exit 0 = all good, 77 = jinja2 not installed)"""
import os, re, sys
try:
    import jinja2
except ImportError:
    sys.exit(77)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
text = open(os.path.join(ROOT, "rpi-cfg", "wm_calibration.cfg")).read()
macros = {m.group(1): m.group(2) for m in re.finditer(r'^\[gcode_macro (\S+)\]\n(?:.*\n)*?gcode:\n((?:(?:    .*|)\n)+)', text, re.M)}
HEAT = ['heater_bed', 'extruder', 'extruder1', 'extruder2', 'extruder3', 'heater_generic chamber']
class Raise(Exception): pass
env = jinja2.Environment(variable_start_string='{', variable_end_string='}')
def run(name, params=None, target=None, control='pid', printing='standby', chamber=True):
    printer = {'print_stats': {'state': printing}, 'heaters': {'available_heaters': HEAT}, 'toolhead': {'homed_axes': 'xyz'},
               'configfile': {'settings': {h: {'control': control} for h in (HEAT[:5] + (HEAT[5:] if chamber else []))}}}
    for h in HEAT: printer[h] = {'target': (target or {}).get(h, 0.0)}
    def raise_(m): raise Raise(m)
    try: out = env.from_string(macros[name]).render(printer=printer, params=params or {}, action_raise_error=raise_)
    except Raise as e: return ["RAISE: " + str(e)]
    return [l.strip() for l in out.splitlines() if l.strip()]
bad = []
def want(label, lines, *must, none=()):
    j = "\n".join(lines)
    for m in must:
        if m not in j: bad.append("%s: missing %r in\n%s" % (label, m, j))
    for m in none:
        if m in j: bad.append("%s: unexpected %r in\n%s" % (label, m, j))
for n in macros: env.from_string(macros[n])
want("all macros present", sorted(macros), *["WM_BED_LEVELING", "WM_PROBE_CALIBRATE", "WM_PROBE_DONE", "WM_TOOL_OFFSETS", "WM_VIBRATION_COMP", "WM_NOZZLE_TEMP_CAL", "WM_CAL_ALL", "WM_CAL_STOP", "WM_CAL_HELP", "WM_ZOFFSET_UP", "WM_ZOFFSET_DOWN", "WM_BED_PID", "WM_CHAMBER_PID", "WM_QUICK_START", "_WM_QUICK_START", "_WM_QUICK_START_DONE"])
want("level asks first", run("WM_BED_LEVELING"), "_WM_CAL_ASK STAGE=level", none=("G29",))
want("level runs", run("WM_BED_LEVELING", {"CONFIRM": "1"}), "G28", "G29", "TURN_OFF_HEATERS", "SAVE_CONFIG")
want("level SAVE=0", run("WM_BED_LEVELING", {"CONFIRM": "1", "SAVE": "0"}), "G29", none=("SAVE_CONFIG",))
want("precheck: print running", run("_WM_CAL_PRECHECK", printing="printing"), "RAISE")
want("precheck: heater on", run("_WM_CAL_PRECHECK", target={"extruder1": 200.0}), "RAISE: extruder1")
want("precheck: bed on", run("_WM_CAL_PRECHECK", target={"heater_bed": 60.0}), "RAISE: heater_bed")
want("precheck: bed allowed", run("_WM_CAL_PRECHECK", {"ALLOW_BED": "1"}, target={"heater_bed": 60.0}), none=("RAISE",))
want("probe warms bed then PROBE_CALIBRATE", run("WM_PROBE_CALIBRATE", {"CONFIRM": "1"}), "M190 S60", "PROBE_CALIBRATE", none=("SAVE_CONFIG",))
want("probe refuses a bed above 100", run("WM_PROBE_CALIBRATE", {"CONFIRM": "1", "BED": "120"}), "RAISE")
want("offsets rapid", run("WM_TOOL_OFFSETS", {"CONFIRM": "1"}), "CALIBRATE_OFFSET_ALL_RAPID_MODE", "TURN_OFF_HEATERS")
want("offsets accurate", run("WM_TOOL_OFFSETS", {"CONFIRM": "1", "MODE": "accurate"}), "CALIBRATE_OFFSET_ALL_FINE_MODE")
want("offsets bad mode", run("WM_TOOL_OFFSETS", {"MODE": "x"}), "RAISE")
want("shaper", run("WM_VIBRATION_COMP", {"CONFIRM": "1"}), "G28", "SHAPER_CALIBRATE", "SAVE_CONFIG")
want("pid tool 1", run("WM_NOZZLE_TEMP_CAL", {"CONFIRM": "1", "T": "1"}), "PID_CALIBRATE HEATER=extruder1 TARGET=220", "M106 S255", "M106 S0", "TURN_OFF_HEATERS")
want("pid refuses watermark", run("WM_NOZZLE_TEMP_CAL", {"CONFIRM": "1"}, control="watermark"), "RAISE: extruder uses control: watermark")
want("pid refuses odd target", run("WM_NOZZLE_TEMP_CAL", {"TARGET": "400"}), "RAISE")
want("pid refuses unknown heater", run("WM_NOZZLE_TEMP_CAL", {"T": "7"}), "RAISE")
want("all: PID=1 needs pid control", run("WM_CAL_ALL", {"PID": "1"}, control="watermark"), "RAISE")
want("all: starts at stage 0", run("WM_CAL_ALL"), "_WM_CAL_STAGE N=0 MODE=rapid PID=0")
want("stage 0 prompt", run("_WM_CAL_STAGE", {"N": "0"}), "Stage 1 of 4", "_WM_CAL_RUN N=0", "_WM_CAL_STAGE N=1")
want("stage 4 without PID is the end", run("_WM_CAL_STAGE", {"N": "4"}), "All stages finished", "SAVE_CONFIG")
want("stage 4 with PID is a stage", run("_WM_CAL_STAGE", {"N": "4", "PID": "1"}), "Stage 5 of 5")
want("stage 2 turns the bed off", run("_WM_CAL_STAGE", {"N": "2"}), "M140 S0")
want("run stage 0 saves nothing", run("_WM_CAL_RUN", {"N": "0"}), "WM_BED_LEVELING CONFIRM=1 SAVE=0", "_WM_CAL_STAGE N=1")
want("run stage 1 waits for you", run("_WM_CAL_RUN", {"N": "1"}, target={"heater_bed": 60.0}), "WM_PROBE_CALIBRATE CONFIRM=1", "prompt_button Next", none=("_WM_CAL_STAGE N=2 MODE=rapid PID=0\n",))
want("bed pid asks first", run("WM_BED_PID"), "_WM_CAL_ASK STAGE=bedpid TARGET=60", none=("PID_CALIBRATE",))
want("bed pid runs", run("WM_BED_PID", {"CONFIRM": "1"}), "PID_CALIBRATE HEATER=heater_bed TARGET=60", "TURN_OFF_HEATERS", "SAVE_CONFIG")
want("bed pid SAVE=0", run("WM_BED_PID", {"CONFIRM": "1", "SAVE": "0"}), "PID_CALIBRATE", none=("SAVE_CONFIG",))
want("bed pid refuses watermark", run("WM_BED_PID", {"CONFIRM": "1"}, control="watermark"), "RAISE: heater_bed uses control: watermark")
want("bed pid refuses odd target", run("WM_BED_PID", {"TARGET": "200"}), "RAISE")
want("chamber pid asks", run("WM_CHAMBER_PID"), "_WM_CAL_ASK STAGE=chamberpid TARGET=45", none=("PID_CALIBRATE",))
want("chamber pid runs", run("WM_CHAMBER_PID", {"CONFIRM": "1", "SAVE": "0"}), "PID_CALIBRATE HEATER=chamber TARGET=45", "TURN_OFF_HEATERS", none=("SAVE_CONFIG",))
want("chamber pid saves", run("WM_CHAMBER_PID", {"CONFIRM": "1"}), "SAVE_CONFIG")
want("chamber pid not on Ultra", run("WM_CHAMBER_PID", chamber=False), "RAISE: This printer has no chamber heater")
want("chamber pid refuses watermark", run("WM_CHAMBER_PID", control="watermark"), "RAISE")
want("chamber pid refuses 80", run("WM_CHAMBER_PID", {"TARGET": "80"}), "RAISE")
want("chamber window", run("_WM_CAL_ASK", {"STAGE": "chamberpid"}), "WM_CHAMBER_PID TARGET=45 CONFIRM=1")
want("quick start: no chamber on Ultra", run("_WM_QUICK_START", chamber=False), "WM_BED_PID CONFIRM=1 SAVE=0", "chamber PID skipped", none=("WM_CHAMBER_PID",))
want("quick start: with chamber", run("_WM_QUICK_START"), "WM_CHAMBER_PID CONFIRM=1 SAVE=0")
want("quick start: window mentions chamber", run("WM_QUICK_START"), "Chamber heater PID at 45 C")
want("quick start: window on Ultra", run("WM_QUICK_START", chamber=False), "Chamber PID: skipped")
want("quick start: window, nothing runs", run("WM_QUICK_START"), "prompt_begin Quick Start Calibration", "_WM_QUICK_START", "Hotend PID: tunes", none=("G29", "SAVE_CONFIG\n", "PID_CALIBRATE"))
want("quick start: watermark says skipped", run("WM_QUICK_START", control="watermark"), "Hotend PID: skipped")
want("quick start: checks first", run("WM_QUICK_START")[:1], "_WM_CAL_PRECHECK")
want("quick start runs 5 stages in order", run("_WM_QUICK_START"), "WM_BED_LEVELING CONFIRM=1 SAVE=0", "WM_TOOL_OFFSETS MODE=rapid CONFIRM=1", "WM_VIBRATION_COMP CONFIRM=1 SAVE=0", "WM_BED_PID CONFIRM=1 SAVE=0", "WM_NOZZLE_TEMP_CAL T=0 CONFIRM=1 SAVE=0", "WM_NOZZLE_TEMP_CAL T=3 CONFIRM=1 SAVE=0", "_WM_QUICK_START_DONE", none=("SAVE_CONFIG\n",))
want("quick start skips PID on watermark", run("_WM_QUICK_START", control="watermark"), "skipped", none=("WM_NOZZLE_TEMP_CAL",))
want("quick start end window saves only on click", run("_WM_QUICK_START_DONE"), "Save and Restart|SAVE_CONFIG", "WM_PROBE_CALIBRATE")
want("z offset", run("WM_ZOFFSET_DOWN", {"STEP": "0.01"}), "SET_GCODE_OFFSET Z_ADJUST=-0.01 MOVE=1")
# every macro the file calls that is not defined here must be a WonderMaker or Klipper command that exists in the repo's factory files
if bad: print("\n".join(bad)); sys.exit(1)
print("all %d macros render and behave" % len(macros))
