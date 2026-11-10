#!/usr/bin/env python3
"""Two small, safe fixes for WonderMaker's Moonraker on the Pi.  Idempotent; nothing is written without --write.

  wm_moonraker_conf.py conf     FILE [--write]   moonraker.conf: add the sections [database] [file_manager] [machine] [secrets]
                                                 (only the options that are missing; your own values are never changed)
                                                 and the K1 [timelapse] options (frames in ~/printer_data/frames/ instead of /tmp, park back_right, ...)
  wm_moonraker_conf.py metadata FILE [--write]   moonraker/components/file_manager/metadata.py: filament_type of an OrcaSlicer
                                                 file is returned as a string like upstream Moonraker ("PLA;PLA;PLA;PLA")
                                                 instead of a list. With the list Fluidd's Jobs page stays on "Loading items". nozzle_diameter is returned as one
                                                 number (the first nozzle), not a list: OctoApp refuses a list ("Expected JsonPrimitive, but had JsonArray").

Exit code: 0 nothing to change, 10 a change is needed / was written, 2 usage or unreadable file.
"""
import re, sys

WANT = [  # (section, [(option, value)]) in the order they are added
    ("database", []),
    ("file_manager", [("queue_gcode_uploads", "False"), ("enable_object_processing", "True")]),
    ("machine", [("provider", "systemd_dbus"), ("validate_service", "False"), ("validate_config", "False")]),
    ("secrets", []),
]
TIMELAPSE = [  # [timelapse] options of the K1 setup, added only when missing
    ("output_path", "~/printer_data/timelapse/"), ("frame_path", "~/printer_data/frames/"), ("camera", "default"),
    ("parkpos", "back_right"), ("#", "# only relevant when parkpos is custom"),
    ("park_custom_pos_x", "0"), ("park_custom_pos_y", "0"), ("park_travel_speed", "400"), ("park_retract_speed", "40"),
    ("park_extrude_speed", "40"), ("park_retract_distance", "0.5"), ("park_extrude_distance", "0.5"),
    ("extraoutputparams", "-preset superfast"),
]
FACTORY_FRAME = "/tmp/timelapse/"   # WonderMaker's value: frames in /tmp are lost at a reboot; changed to the frames folder


def sections(lines):
    """{name: (start, end)} line ranges (end exclusive) of every [section]"""
    out, cur = {}, None
    for i, l in enumerate(lines):
        m = re.match(r"^\[([^\]]+)\]\s*$", l)
        if m:
            if cur: out[cur[0]] = (cur[1], i)
            cur = (m.group(1).strip(), i)
    if cur: out[cur[0]] = (cur[1], len(lines))
    return out


def fix_conf(text):
    lines = text.split("\n")
    notes = []
    # 1. [timelapse]: frames folder instead of /tmp, and the K1 options that are missing
    sec = sections(lines)
    if "timelapse" in sec:
        a, b = sec["timelapse"]
        for i in range(a + 1, b):
            m = re.match(r"^frame_path\s*[:=]\s*(.*?)\s*$", lines[i])
            if m and m.group(1) == FACTORY_FRAME:
                lines[i] = "frame_path: ~/printer_data/frames/"
                notes.append("[timelapse] frame_path: /tmp/timelapse/ -> ~/printer_data/frames/")
        have = {re.match(r"^([A-Za-z_]+)", l).group(1) for l in lines[a + 1:b] if re.match(r"^[A-Za-z_]+\s*[:=]", l)}
        add = []
        for k, v in TIMELAPSE:
            if k == "#":
                if "park_custom_pos_x" not in have: add.append(v)
            elif k not in have: add.append("%s: %s" % (k, v))
        if add:
            ins = b
            while ins - 1 > a and not lines[ins - 1].strip(): ins -= 1
            lines[ins:ins] = add
            notes.append("[timelapse]: added " + ", ".join(x.split(":")[0] for x in add if not x.startswith("#")))
    # 2. add the sections / options that are missing
    for name, opts in WANT:
        sec = sections(lines)
        if name not in sec:
            at = sec["octoprint_compat"][0] if "octoprint_compat" in sec else len(lines)
            block = ["[%s]" % name] + ["%s: %s" % o for o in opts] + [""]
            if at == len(lines) and lines and lines[-1].strip(): block.insert(0, "")
            lines[at:at] = block
            notes.append("added [%s]%s" % (name, (" with " + ", ".join(o[0] for o in opts)) if opts else ""))
            continue
        a, b = sec[name]
        have = {re.match(r"^([A-Za-z_]+)", l).group(1) for l in lines[a + 1:b] if re.match(r"^[A-Za-z_]+\s*[:=]", l)}
        add = ["%s: %s" % o for o in opts if o[0] not in have]
        if add:
            ins = b
            while ins - 1 > a and not lines[ins - 1].strip(): ins -= 1
            lines[ins:ins] = add
            notes.append("[%s]: added %s" % (name, ", ".join(x.split(":")[0] for x in add)))
    return "\n".join(lines), notes


OLD_SIG = "    def parse_filament_type(self) -> Optional[List[str]]:\n"
NEW_SIG = "    def parse_filament_type(self) -> Optional[str]:\n"
OLD_RET = "                return materials if materials else None\n"
NEW_RET = ("                # a string like upstream Moonraker (Fluidd cannot show a list here); one entry per extruder, joined with \";\"\n"
           "                return \";\".join(materials) if materials else None\n")
OLD_NZ_SIG = "    def parse_nozzle_diameter(self) -> Optional[List[float]]:\n"
NEW_NZ_SIG = "    def parse_nozzle_diameter(self) -> Optional[float]:\n"
OLD_NZ_RET = "                return costs\n"
NEW_NZ_RET = ("                # one number like upstream Moonraker (OctoApp and Fluidd read a float): the first nozzle (T0)\n"
              "                return costs[0] if costs else None\n")


def fix_metadata(text):
    notes = []
    if OLD_SIG in text and OLD_RET in text:
        text = text.replace(OLD_SIG, NEW_SIG).replace(OLD_RET, NEW_RET)
        notes.append("filament_type is returned as a string (upstream behaviour)")
    i = text.find(OLD_NZ_SIG)
    j = text.find(OLD_NZ_RET, i) if i >= 0 else -1
    if i >= 0 and j >= 0 and j - i < 800:   # only the return inside this one function (BaseSlicer has similar lines for filament cost)
        text = text[:i] + NEW_NZ_SIG + text[i + len(OLD_NZ_SIG):j] + NEW_NZ_RET + text[j + len(OLD_NZ_RET):]
        notes.append("nozzle_diameter is returned as one number (upstream behaviour)")
    return text, notes


def main(argv):
    if len(argv) < 3 or argv[1] not in ("conf", "metadata"): print(__doc__); return 2
    write = "--write" in argv
    try:
        text = open(argv[2], encoding="utf-8", newline="").read()
    except OSError as e:
        print("cannot read %s: %s" % (argv[2], e)); return 2
    new, notes = (fix_conf if argv[1] == "conf" else fix_metadata)(text)
    for n in notes: print(n)
    if new == text: return 0
    if write:
        with open(argv[2], "w", encoding="utf-8", newline="") as f: f.write(new)
    return 10


if __name__ == "__main__":
    sys.exit(main(sys.argv))
