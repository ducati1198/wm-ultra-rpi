#!/usr/bin/env python3
"""Renders every macro of rpi-cfg/wm_calibration.cfg and rpi-cfg/wm_nozzle.cfg with jinja2 (Klipper style: { } for expressions) and a mock printer.
Run: python3 tests/rpi_cfg_render.py      (needs jinja2; exit 0 = all good, 77 = jinja2 not installed)"""
import os, re, sys
try:
    import jinja2
except ImportError:
    sys.exit(77)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
text = open(os.path.join(ROOT, "rpi-cfg", "wm_calibration.cfg")).read() + "\n" + open(os.path.join(ROOT, "rpi-cfg", "wm_nozzle.cfg")).read()
macros = {m.group(1): m.group(2) for m in re.finditer(r'^\[gcode_macro (\S+)\]\n(?:.*\n)*?gcode:\n((?:(?:    .*|)\n)+)', text, re.M)}
HEAT = ['heater_bed', 'extruder', 'extruder1', 'extruder2', 'extruder3', 'heater_generic chamber']
class Raise(Exception): pass
env = jinja2.Environment(variable_start_string='{', variable_end_string='}')
def run(name, params=None, target=None, control='pid', printing='standby', chamber=True, sv=None, temps=None, docks=None, shell=True, ids=None, actual=None, canids=True):
    svars = {'thr_number': 4, 'current_extruder': 0, 'fail_flag': 0, 'fail_tool': 99, 'is_nozzle_setting': 0}; svars.update(sv or {})
    printer = {'save_variables': {'variables': svars},
               'print_stats': {'state': printing}, 'heaters': {'available_heaters': HEAT}, 'toolhead': {'homed_axes': 'xyz'},
               'configfile': {'settings': {h: {'control': control} for h in (HEAT[:5] + (HEAT[5:] if chamber else []))}}}
    for h in HEAT: printer[h] = {'target': (target or {}).get(h, 0.0), 'temperature': (temps or {}).get(h, 25.0)}
    cs = printer['configfile']['settings']
    for i, h in enumerate(HEAT[1:5]): cs[h]['nozzle_diameter'] = 0.4
    if shell: cs['gcode_shell_command wm_nozzle'] = {}
    if canids: cs['gcode_shell_command wm_canids'] = {}
    for i in range(4): cs['mcu t%d' % i] = {'canbus_uuid': (ids or ['ac8b57e80210', 'ac80ddd6ebe5', 'ac4068351d2c', 'ac6290884b96'])[i]}
    printer['gcode_macro _WM_MATCH_STATE'] = {'actual': [0, 1, 2, 3] if actual is None else actual}
    for i in range(4):
        cs['filament_switch_sensor docked%d' % i] = {}
        printer['filament_switch_sensor docked%d' % i] = {'filament_detected': (docks or {}).get(i, True)}
    def raise_(m): raise Raise(m)
    info = []
    def respond_info(m): info.append(m); return ''
    try: out = env.from_string(macros[name]).render(printer=printer, params=params or {}, action_raise_error=raise_, action_respond_info=respond_info)
    except Raise as e: return ["INFO: " + x for x in info] + ["RAISE: " + str(e)]
    return [l.strip() for l in out.splitlines() if l.strip()]
bad = []
def want(label, lines, *must, none=()):
    j = "\n".join(lines)
    for m in must:
        if m not in j: bad.append("%s: missing %r in\n%s" % (label, m, j))
    for m in none:
        if m in j: bad.append("%s: unexpected %r in\n%s" % (label, m, j))
for n in macros: env.from_string(macros[n])
want("all macros present", sorted(macros), *["WM_BED_LEVELING", "WM_PROBE_CALIBRATE", "WM_PROBE_DONE", "WM_OFFSETS_RAPID", "WM_OFFSETS_ACCURATE", "WM_VIBRATION_COMP", "WM_NOZZLE_TEMP_CAL", "WM_CAL_STOP", "WM_CAL_HELP", "WM_ZOFFSET_UP", "WM_ZOFFSET_DOWN", "WM_BED_PID", "WM_FULL_CALIBRATION", "_WM_FULL_CALIBRATION", "_WM_FULL_CALIBRATION_DONE", "WM_NOZZLE_TYPE", "WM_NOZZLE_CHANGE_END", "WM_EXTRUDER_SETUP", "WM_NOZZLE_CHANGE"])
want("level asks first", run("WM_BED_LEVELING"), "_WM_CAL_ASK STAGE=level", none=("G29",))
want("level runs", run("WM_BED_LEVELING", {"CONFIRM": "1"}), "G28", "G29", "TURN_OFF_HEATERS", "SAVE_CONFIG")
want("level SAVE=0", run("WM_BED_LEVELING", {"CONFIRM": "1", "SAVE": "0"}), "G29", none=("SAVE_CONFIG",))
want("precheck: print running", run("_WM_CAL_PRECHECK", printing="printing"), "RAISE")
want("precheck: heater on", run("_WM_CAL_PRECHECK", target={"extruder1": 200.0}), "RAISE: extruder1")
want("precheck: bed on", run("_WM_CAL_PRECHECK", target={"heater_bed": 60.0}), "RAISE: heater_bed")
want("precheck: bed allowed", run("_WM_CAL_PRECHECK", {"ALLOW_BED": "1"}, target={"heater_bed": 60.0}), none=("RAISE",))
want("probe warms bed then PROBE_CALIBRATE", run("WM_PROBE_CALIBRATE", {"CONFIRM": "1"}), "M190 S60", "PROBE_CALIBRATE", none=("SAVE_CONFIG",))
want("probe refuses a bed above 100", run("WM_PROBE_CALIBRATE", {"CONFIRM": "1", "BED": "120"}), "RAISE")
want("rapid: G28, every tool, park, heaters off", run("WM_OFFSETS_RAPID", {"CONFIRM": "1"}), "G28", "RAPID_MODE T=0", "RAPID_MODE T=3", "PARK_CURRENT_TOOL", "TURN_OFF_HEATERS", none=("NOZZLE_PREPARE",))
want("rapid: two tools only", run("WM_OFFSETS_RAPID", {"CONFIRM": "1"}, sv={"thr_number": 2}), "RAPID_MODE T=1", none=("RAPID_MODE T=2",))
want("rapid asks first", run("WM_OFFSETS_RAPID"), "_WM_CAL_ASK STAGE=offsets MODE=rapid", none=("G28", "RAPID_MODE"))
want("accurate asks first", run("WM_OFFSETS_ACCURATE"), "_WM_CAL_ASK STAGE=offsets MODE=accurate", none=("G28", "NOZZLE_PREPARE"))
want("accurate start: G28, prepare T0, debris window", run("WM_OFFSETS_ACCURATE", {"CONFIRM": "1"}), "G28", "NOZZLE_PREPARE S=220 T=0", "purged debris has been manually removed", "WM_OFFSETS_ACCURATE STEP=clean N=0 TEMP=220", none=("NOZZLE_CALIBRATE_TOOL_OFFSET", "RAPID_MODE"))
want("accurate TEMP", run("WM_OFFSETS_ACCURATE", {"CONFIRM": "1", "TEMP": "240"}), "NOZZLE_PREPARE S=240 T=0", "TEMP=240")
want("accurate TEMP out of range", run("WM_OFFSETS_ACCURATE", {"CONFIRM": "1", "TEMP": "400"}), "RAISE")
want("accurate clean T1: wipe, then prepare T2", run("WM_OFFSETS_ACCURATE", {"STEP": "clean", "N": "1", "TEMP": "230"}), "NOZZLE_CALIBRATE_TOOL_OFFSET T=1", "NOZZLE_PREPARE S=230 T=2", "STEP=clean N=2 TEMP=230", none=("RAPID_MODE", "G28"))
want("accurate clean last tool: rapid for all, park", run("WM_OFFSETS_ACCURATE", {"STEP": "clean", "N": "3"}), "NOZZLE_CALIBRATE_TOOL_OFFSET T=3", "RAPID_MODE T=0", "RAPID_MODE T=3", "PARK_CURRENT_TOOL", "TURN_OFF_HEATERS", none=("NOZZLE_PREPARE",))
want("accurate clean last tool (2 tools)", run("WM_OFFSETS_ACCURATE", {"STEP": "clean", "N": "1"}, sv={"thr_number": 2}), "RAPID_MODE T=1", none=("RAPID_MODE T=2", "NOZZLE_PREPARE"))
want("accurate clean while printing", run("WM_OFFSETS_ACCURATE", {"STEP": "clean", "N": "0"}, printing="printing"), "RAISE")
want("accurate bad step", run("WM_OFFSETS_ACCURATE", {"STEP": "x"}), "RAISE")
want("shaper", run("WM_VIBRATION_COMP", {"CONFIRM": "1"}), "G28", "SHAPER_CALIBRATE", "SAVE_CONFIG")
want("pid tool 1", run("WM_NOZZLE_TEMP_CAL", {"CONFIRM": "1", "T": "1"}), "PID_CALIBRATE HEATER=extruder1 TARGET=220", "M106 S255", "M106 S0", "TURN_OFF_HEATERS")
want("pid refuses watermark", run("WM_NOZZLE_TEMP_CAL", {"CONFIRM": "1"}, control="watermark"), "RAISE: extruder uses control: watermark")
want("pid refuses odd target", run("WM_NOZZLE_TEMP_CAL", {"TARGET": "400"}), "RAISE")
want("pid refuses unknown heater", run("WM_NOZZLE_TEMP_CAL", {"T": "7"}), "RAISE")
want("bed pid asks first", run("WM_BED_PID"), "_WM_CAL_ASK STAGE=bedpid TARGET=60", none=("PID_CALIBRATE",))
want("bed pid runs", run("WM_BED_PID", {"CONFIRM": "1"}), "PID_CALIBRATE HEATER=heater_bed TARGET=60", "TURN_OFF_HEATERS", "SAVE_CONFIG")
want("bed pid SAVE=0", run("WM_BED_PID", {"CONFIRM": "1", "SAVE": "0"}), "PID_CALIBRATE", none=("SAVE_CONFIG",))
want("bed pid refuses watermark", run("WM_BED_PID", {"CONFIRM": "1"}, control="watermark"), "RAISE: heater_bed uses control: watermark")
want("no chamber macro any more", sorted(macros), none=("WM_CHAMBER_PID",))
want("bed pid refuses odd target", run("WM_BED_PID", {"TARGET": "200"}), "RAISE")
want("full calibration: window, nothing runs", run("WM_FULL_CALIBRATION"), "prompt_begin Full Calibration", "_WM_FULL_CALIBRATION", "Hotend PID: tunes", none=("G29", "SAVE_CONFIG\n", "PID_CALIBRATE"))
want("full calibration: watermark says skipped", run("WM_FULL_CALIBRATION", control="watermark"), "Hotend PID: skipped")
want("full calibration: checks first", run("WM_FULL_CALIBRATION")[:1], "_WM_CAL_PRECHECK")
want("full calibration runs 5 stages in order", run("_WM_FULL_CALIBRATION"), "WM_BED_LEVELING CONFIRM=1 SAVE=0", "WM_OFFSETS_RAPID CONFIRM=1", "WM_VIBRATION_COMP CONFIRM=1 SAVE=0", "WM_BED_PID CONFIRM=1 SAVE=0", "WM_NOZZLE_TEMP_CAL T=0 CONFIRM=1 SAVE=0", "WM_NOZZLE_TEMP_CAL T=3 CONFIRM=1 SAVE=0", "_WM_FULL_CALIBRATION_DONE", none=("SAVE_CONFIG\n",))
want("full calibration skips PID on watermark", run("_WM_FULL_CALIBRATION", control="watermark"), "skipped", none=("WM_NOZZLE_TEMP_CAL",))
want("full calibration end window saves only on click", run("_WM_FULL_CALIBRATION_DONE"), "Save and Restart|_WM_SAVE", "WM_PROBE_CALIBRATE")
want("window buttons close the screen window first", run("_WM_SAVE"), "action:prompt_end", "SAVE_CONFIG")
want("cancel closes the window and says so", run("_WM_PROMPT_CLOSE", params={"MSG": "Cancelled"}), "action:prompt_end", "M118 Cancelled")
want("the start path closes the window first", run("WM_CAL_STOP"), "action:prompt_end", "TURN_OFF_HEATERS")
want("both files' macros present", sorted(macros), "WM_NOZZLE_TYPE", "_WM_NOZZLE_MATERIAL", "_WM_NOZZLE_DIAMETER", "_WM_NOZZLE_SURE", "_WM_NOZZLE_APPLY", "WM_NOZZLE_CHANGE", "_WM_NCHANGE_CHECK", "_WM_NCHANGE_RUN", "_WM_NCHANGE_AFTER", "_WM_NCHANGE_FAILED", "WM_NOZZLE_CHANGE_END")
want("nozzle type: refuses while printing", run("WM_NOZZLE_TYPE", printing="printing"), "RAISE")
want("nozzle type: one button per tool, shows the current values", run("WM_NOZZLE_TYPE"), "prompt_begin Nozzle Type", "Nozzle 1: hardened steel, 0.4 mm", "_WM_NOZZLE_MATERIAL T=0", "_WM_NOZZLE_MATERIAL T=3")
want("nozzle type: only as many buttons as tools", run("WM_NOZZLE_TYPE", sv={"thr_number": 2}), "_WM_NOZZLE_MATERIAL T=1", none=("_WM_NOZZLE_MATERIAL T=2",))
want("nozzle type: shows a saved stainless nozzle", run("WM_NOZZLE_TYPE", sv={"nozzle_type2": 1}), "Nozzle 3: stainless steel")
want("nozzle type: material step carries the tool", run("_WM_NOZZLE_MATERIAL", {"T": "2"}), "Nozzle 3: material", "_WM_NOZZLE_DIAMETER T=2 TYPE=0", "_WM_NOZZLE_DIAMETER T=2 TYPE=1")
want("nozzle type: diameter step", run("_WM_NOZZLE_DIAMETER", {"T": "1", "TYPE": "1"}), "_WM_NOZZLE_SURE T=1 TYPE=1 D=0.2", "D=0.4", "D=0.6", "D=0.8")
want("nozzle type: confirm writes nothing", run("_WM_NOZZLE_SURE", {"T": "0", "TYPE": "0", "D": "0.6"}), "_WM_NOZZLE_APPLY T=0 TYPE=0 D=0.6", "hardened steel, 0.6 mm", none=("RUN_SHELL_COMMAND", "SAVE_VARIABLE"))
want("nozzle type: apply saves and edits printer.cfg", run("_WM_NOZZLE_APPLY", {"T": "3", "TYPE": "1", "D": "0.8"}), "SAVE_VARIABLE VARIABLE=nozzle_type3 VALUE=1", 'RUN_SHELL_COMMAND CMD=wm_nozzle PARAMS="set 3 0.8 1"', "RESTART")
want("nozzle type: apply refuses without the shell command", run("_WM_NOZZLE_APPLY", {"T": "0"}, shell=False), "RAISE: The wm_nozzle shell command is not loaded")
want("nozzle type: apply refuses while printing", run("_WM_NOZZLE_APPLY", {"T": "0"}, printing="paused"), "RAISE")
want("nozzle change: window explains and nothing moves", run("WM_NOZZLE_CHANGE"), "hang the extruders on the rear support", "_WM_NCHANGE_RUN", none=("_UNLOCK_TOOL", "SAVE_VARIABLE", "G28"))
want("nozzle change: refuses while printing", run("_WM_NCHANGE_CHECK", printing="printing"), "RAISE")
want("nozzle change: the refusal also opens a Fluidd window", run("_WM_NCHANGE_CHECK", printing="printing"), "INFO: action:prompt_begin Cannot start", "INFO: action:prompt_text A print is running", "INFO: action:prompt_footer_button Close", "INFO: action:prompt_show", "RAISE")
want("matching: a tool head out of its dock opens a Fluidd window naming it", run("_WM_MATCH_CHECK", docks={0: False}), "INFO: action:prompt_text Tool head 1 is not seen in its dock", "INFO: action:prompt_show", "RAISE")
want("nozzle change: refuses with a heater on", run("_WM_NCHANGE_CHECK", target={"heater_bed": 60.0}), "RAISE: heater_bed")
want("nozzle change: refuses with a hot nozzle", run("_WM_NCHANGE_CHECK", temps={"extruder2": 120.0}), "RAISE: extruder2 is still at 120")
want("nozzle change: cold printer passes", run("_WM_NCHANGE_CHECK"), none=("RAISE",))
want("nozzle change: switch on, then park the tool on the carriage", run("_WM_NCHANGE_RUN", sv={"current_extruder": 2}), "SAVE_VARIABLE VARIABLE=is_nozzle_setting VALUE=1", "_UNLOCK_TOOL T=2", "_WM_NCHANGE_AFTER")
want("nozzle change: no tool on the carriage, nothing to unlock", run("_WM_NCHANGE_RUN", sv={"current_extruder": 99}), "is_nozzle_setting VALUE=1", "_WM_NCHANGE_AFTER", none=("_UNLOCK_TOOL",))
want("nozzle change: a stale fail_flag stops it and puts the switch back", run("_WM_NCHANGE_RUN", sv={"fail_flag": -3}), "_WM_NCHANGE_FAILED", none=("_UNLOCK_TOOL",))
want("nozzle change: unlock success asks for Done", run("_WM_NCHANGE_AFTER"), "tools released", "WM_NOZZLE_CHANGE_END")
want("nozzle change: unlock failure", run("_WM_NCHANGE_AFTER", sv={"fail_flag": -3, "fail_tool": 1}), "_WM_NCHANGE_FAILED", none=("WM_NOZZLE_CHANGE_END|primary",))
want("nozzle change: failed puts the switch back", run("_WM_NCHANGE_FAILED", {"REASON": "x"}), "is_nozzle_setting VALUE=0")
want("nozzle change end: switch off, docks fine", run("WM_NOZZLE_CHANGE_END"), "is_nozzle_setting VALUE=0", "Every tool head is seen in its dock")
want("nozzle change end: names an empty dock", run("WM_NOZZLE_CHANGE_END", docks={1: False, 3: False}), "is_nozzle_setting VALUE=0", "tool head 2, 4 shows an empty dock")
want("match: all macros present", sorted(macros), "WM_EXTRUDER_SETUP", "_WM_MATCH_STATE", "_WM_MATCH_CHECK", "_WM_MATCH_RUN", "_WM_MATCH_STEP", "_WM_MATCH_AFTER", "_WM_MATCH_FINISH", "_WM_MATCH_APPLY", "_WM_MATCH_STOP")
want("match: window shows the ids, nothing moves", run("WM_EXTRUDER_SETUP"), "prompt_begin Extruder Setup", "hang the extruders on the rear support", "T0 ac8b57e80210", "T3 ac6290884b96", "Set Up|_WM_MATCH_RUN", none=("T0\n", "SAVE_VARIABLE", "G28", "PARK_CURRENT_TOOL"))
want("match: check runs the Extruder Setup safety check first", run("WM_EXTRUDER_SETUP")[:1], "_WM_MATCH_CHECK")
want("match: check refuses without the wm_canids shell command", run("_WM_MATCH_CHECK", canids=False), "RAISE: The wm_canids shell command is not loaded")
want("match: check refuses while a nozzle change is on", run("_WM_MATCH_CHECK", sv={"is_nozzle_setting": 1}), "RAISE: The nozzle change is still on")
want("match: check refuses with fail_flag set", run("_WM_MATCH_CHECK", sv={"fail_flag": -3}), "RAISE: WonderMaker's tool change error flag")
want("match: check refuses when a head is not in its dock", run("_WM_MATCH_CHECK", docks={2: False}), "RAISE: Tool head 3 is not seen in its dock")
want("match: check refuses a missing CAN id", run("_WM_MATCH_CHECK", ids=["ac8b57e80210", "", "ac4068351d2c", "ac6290884b96"]), "RAISE: [mcu T1] has no canbus_uuid")
want("match: check passes on a good printer", run("_WM_MATCH_CHECK"), none=("RAISE",))
want("match: run switches on, homes if needed, parks, starts at T0", run("_WM_MATCH_RUN", sv={"current_extruder": 1}), "SET_GCODE_VARIABLE MACRO=_WM_MATCH_STATE VARIABLE=actual VALUE=\"[]\"", "is_nozzle_setting VALUE=1", "PARK_CURRENT_TOOL", "_WM_MATCH_STEP N=0")
want("match: run does not park when no tool is on the carriage", run("_WM_MATCH_RUN", sv={"current_extruder": 99}), "_WM_MATCH_STEP N=0", none=("PARK_CURRENT_TOOL",))
want("match: step picks the tool and checks", run("_WM_MATCH_STEP", {"N": "2"}), "T2", "M400", "_WM_MATCH_AFTER N=2")
want("match: step stops on a stale fail_flag", run("_WM_MATCH_STEP", {"N": "1"}, sv={"fail_flag": -1}), "_WM_MATCH_STOP", none=("\nT1\n",))
want("match: after notes the empty dock and goes on", run("_WM_MATCH_AFTER", {"N": "0"}, docks={0: False}, actual=[]), 'VALUE="[0]"', "VARIABLE=next VALUE=1", "UPDATE_DELAYED_GCODE ID=_WM_MATCH_NEXT DURATION=0.5", none=("_WM_MATCH_STEP N=",))
want("match: after records a different dock", run("_WM_MATCH_AFTER", {"N": "1"}, docks={3: False}, actual=[0]), 'VALUE="[0, 3]"', "empty dock is tool head 4", "VARIABLE=next VALUE=2", "UPDATE_DELAYED_GCODE ID=_WM_MATCH_NEXT")
want("match: after the last tool finishes", run("_WM_MATCH_AFTER", {"N": "3"}, docks={3: False}, actual=[0, 1, 2]), 'VALUE="[0, 1, 2, 3]"', "_WM_MATCH_FINISH", none=("_WM_MATCH_STEP",))
want("match: after stops when no dock is empty", run("_WM_MATCH_AFTER", {"N": "1"}, actual=[0]), "_WM_MATCH_STOP", "no dock sensor shows an empty dock", none=("_WM_MATCH_STEP",))
want("match: after stops when the pick failed", run("_WM_MATCH_AFTER", {"N": "1"}, docks={1: False}, actual=[0], sv={"fail_flag": -1, "fail_tool": 1}), "_WM_MATCH_STOP", "T1 could not be picked up", none=("_WM_MATCH_STEP",))
want("match: finish with identity changes nothing", run("_WM_MATCH_FINISH"), "PARK_CURRENT_TOOL", "is_nozzle_setting VALUE=0", "nothing was changed", none=("_WM_MATCH_APPLY", "RUN_SHELL_COMMAND", "FIRMWARE_RESTART"))
want("match: finish with a swap offers the new ids, writes nothing", run("_WM_MATCH_FINISH", actual=[0, 2, 1, 3]), "T1: ac80ddd6ebe5 -> ac4068351d2c (from dock 3)", "T2: ac4068351d2c -> ac80ddd6ebe5 (from dock 2)", "_WM_MATCH_APPLY ID0=ac8b57e80210 ID1=ac4068351d2c ID2=ac80ddd6ebe5 ID3=ac6290884b96", none=("RUN_SHELL_COMMAND", "FIRMWARE_RESTART", "T0: ", "T3: "))
want("match: finish with a duplicate writes nothing", run("_WM_MATCH_FINISH", actual=[0, 2, 2, 3]), "T1 and T2 would get the same CAN id", "nothing was written", "T1: dock 3", none=("_WM_MATCH_APPLY", "RUN_SHELL_COMMAND"))
want("match: apply writes the four ids, then restarts the firmware", run("_WM_MATCH_APPLY", {"ID0": "a", "ID1": "b", "ID2": "c", "ID3": "d"}), 'RUN_SHELL_COMMAND CMD=wm_canids PARAMS="apply a b c d"', "FIRMWARE_RESTART")
want("match: apply refuses without the shell command", run("_WM_MATCH_APPLY", {"ID0": "a"}, canids=False), "RAISE: The wm_canids shell command is not loaded")
want("match: apply refuses while printing", run("_WM_MATCH_APPLY", {"ID0": "a"}, printing="printing"), "RAISE")
want("match: stop switches off and writes nothing", run("_WM_MATCH_STOP", {"REASON": "x"}), "is_nozzle_setting VALUE=0", "Nothing was written", none=("RUN_SHELL_COMMAND", "SAVE_CONFIG"))
want("nozzle change end: offers Extruder Setup (matching)", run("WM_NOZZLE_CHANGE_END"), "Extruder Setup|WM_EXTRUDER_SETUP|secondary")
want("calibration refuses while Extruder Setup or a nozzle change is on", run("_WM_CAL_PRECHECK", sv={"is_nozzle_setting": 1}), "RAISE: Extruder Setup or a nozzle change is still on")
want("z offset", run("WM_ZOFFSET_DOWN", {"STEP": "0.01"}), "SET_GCODE_OFFSET Z_ADJUST=-0.01 MOVE=1")
# every macro the file calls that is not defined here must be a WonderMaker or Klipper command that exists in the repo's factory files
if bad: print("\n".join(bad)); sys.exit(1)
print("all %d macros render and behave" % len(macros))
