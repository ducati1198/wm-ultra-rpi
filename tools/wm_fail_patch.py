#!/usr/bin/env python3
"""Make the errors of WM_OFFSETS_ACCURATE and _WM_CAL_PRECHECK run AFTER the "close the popup" line.
Klipper reads the whole macro before it runs any line, so {action_raise_error(...)} stopped the macro before
RESPOND ... action:prompt_end ran, and the KlipperScreen window stayed open. The error now comes from a tiny macro,
_WM_FAIL, called as a normal line (it runs after prompt_end). Idempotent.
usage: wm_fail_patch.py wm_calibration.cfg"""
import re
import sys

p = sys.argv[1]
s = open(p).read()
FAIL = '''[gcode_macro _WM_FAIL]
description: Stop a macro with an error AFTER its window was closed (action_raise_error inside the macro text runs before any line of it)
gcode:
    {action_raise_error(params.MSG|default("Calibration stopped."))}

'''
n = 0
for name in ("_WM_CAL_PRECHECK", "WM_OFFSETS_ACCURATE"):
    m = re.search(r"^\[gcode_macro %s\]\n(?:.*\n)*?(?=^\[|\Z)" % re.escape(name), s, re.M)
    if not m:
        continue
    block = m.group(0)
    new, k = re.subn(r"^(\s*)\{action_raise_error\((.*)\)\}$", r'\1_WM_FAIL MSG="{\2}"', block, flags=re.M)
    n += k
    s = s.replace(block, new, 1)
if "[gcode_macro _WM_FAIL]" not in s:
    i = s.find("[gcode_macro _WM_CAL_PRECHECK]")
    s = s[:i] + FAIL + s[i:]
open(p, "w").write(s)
print("replaced %d error lines" % n)
