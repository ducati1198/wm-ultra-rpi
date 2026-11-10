#!/usr/bin/env python3
"""Bring your own calibration from the old WonderMaker board to the Pi.  Local files only: the installer
fetches the two files from the old board with a read-only `cat` over SSH and hands them to this script.

  wm_import_settings.py plan  --old-printer F --old-vars F --printer F --vars F
  wm_import_settings.py apply --old-printer F --old-vars F --printer F --vars F [--stamp S]

What is taken
  * the SAVE_CONFIG block at the end of the old printer.cfg (PID, input shaper, bed mesh, probe z_offset, ...).
    Sections with the same name replace the ones in the Pi's block; the others are added. [mcu ...] sections
    (canbus_uuid) are never taken: the Pi has its own.
  * options in the Pi's printer.cfg (above its SAVE_CONFIG block) that the imported block overrides are commented
    out with "#", so Klipper's next SAVE_CONFIG does not complain about duplicates.
  * from saved_variables.cfg only the calibration keys (tool offsets, tool centres, positions, pressure advance,
    flow). State keys (current tool, fail flags, last file, ...) stay as the Pi has them. Keys the Pi does not
    have are not added.
Backups: <file>.wm-before-import-<stamp>.  Nothing is written by `plan`.
"""
import re, sys, time, shutil

MARK = re.compile(r"^#\*# <-+ SAVE_CONFIG -+>")
SEC = re.compile(r"^#\*# \[([^\]]+)\]\s*$")
KEYS = re.compile(r"^(t[0-3]_(center\d?|offset|position|xy_position\d|z_position|pressure_advance|flow_extruder|t0)|probe_position|wipe_position)$")
HEADER = ["#*# <---------------------- SAVE_CONFIG ---------------------->",
          "#*# DO NOT EDIT THIS BLOCK OR BELOW. The contents are auto-generated.", "#*#"]


def read(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def split(text):
    """(main lines, {section: [lines 'key = value']} in order)"""
    lines = text.split("\n")
    i = next((k for k, l in enumerate(lines) if MARK.match(l)), None)
    main = lines if i is None else lines[:i]
    blk, cur = {}, None
    for l in ([] if i is None else lines[i:]):
        m = SEC.match(l)
        if m: cur = m.group(1); blk[cur] = []; continue
        if cur and l.startswith("#*#"):
            body = l[3:].strip()
            if body: blk[cur].append(body)
    return main, blk


def keyname(entry): return re.split(r"\s*[:=]", entry, maxsplit=1)[0].strip().lower()


def merge_blocks(old, new):
    out = dict(new)
    skipped = []
    for s, items in old.items():
        if s.split()[0] == "mcu": skipped.append(s); continue
        out[s] = items
    return out, skipped


def render_block(blk):
    t = list(HEADER)
    for s, items in blk.items():
        t.append("#*# [%s]" % s); t.extend("#*# " + i for i in items); t.append("#*#")
    return t


def comment_overrides(main, blk):
    """comment out options in the main body that the block sets; returns (lines, [what])"""
    out, done, cur = [], [], None
    want = {s: {keyname(i) for i in items} for s, items in blk.items()}
    for l in main:
        m = re.match(r"^\[([^\]]+)\]\s*$", l)
        if m: cur = m.group(1)
        mo = re.match(r"^([A-Za-z0-9_]+)\s*[:=]", l)
        if cur in want and mo and mo.group(1).lower() in want[cur]:
            out.append("#" + l + "   # commented out by wm_import_settings: the SAVE_CONFIG block below sets it")
            done.append("[%s] %s" % (cur, mo.group(1)))
        else:
            out.append(l)
    return out, done


def vars_import(old_text, new_text):
    old = {}
    for l in old_text.split("\n"):
        m = re.match(r"^([A-Za-z0-9_]+)\s*=\s*(.*)$", l)
        if m and KEYS.match(m.group(1)): old[m.group(1)] = m.group(2)
    out, changed, n = [], [], 0
    for l in new_text.split("\n"):
        m = re.match(r"^([A-Za-z0-9_]+)\s*=\s*(.*)$", l)
        if m and m.group(1) in old:
            n += 1
            if old[m.group(1)].strip() != m.group(2).strip():
                changed.append((m.group(1), m.group(2).strip(), old[m.group(1)].strip()))
                l = "%s = %s" % (m.group(1), old[m.group(1)])
        out.append(l)
    return "\n".join(out), changed, len(old) - n


def build(a):
    old_main, old_blk = split(read(a["old-printer"]))
    pi_text = read(a["printer"])
    pi_main, pi_blk = split(pi_text)
    if not old_blk: return None
    merged, skipped = merge_blocks(old_blk, pi_blk)
    imported = {s: v for s, v in old_blk.items() if s in merged and s.split()[0] != "mcu"}
    main2, done = comment_overrides(pi_main, imported)
    while main2 and main2[-1] == "": main2.pop()
    new_text = "\n".join(main2 + [""] + render_block(merged)) + "\n"
    v_new, changed, missing = vars_import(read(a["old-vars"]), read(a["vars"])) if a.get("old-vars") else (None, [], 0)
    return dict(new_text=new_text, imported=imported, skipped=skipped, commented=done, vars_text=v_new, vars_changed=changed, vars_missing=missing)


def report(r):
    t = []
    if r is None:
        return ["The old printer.cfg has no SAVE_CONFIG block: no PID, input shaper, bed mesh or probe offset to copy."]
    t.append("SAVE_CONFIG sections that will be copied (%d):" % len(r["imported"]))
    for s, items in r["imported"].items():
        t.append("  [%s]  %d value(s)" % (s, len([i for i in items if not i.startswith("#")])))
    for s in r["skipped"]: t.append("  not copied: [%s] (the Pi has its own)" % s)
    t.append("Lines in printer.cfg commented out because the block sets them: %d" % len(r["commented"]))
    for c in r["commented"]: t.append("  " + c)
    if r["vars_text"] is not None:
        t.append("Calibration variables that differ and will be copied: %d" % len(r["vars_changed"]))
        for k, was, now in r["vars_changed"]: t.append("  %s: %s -> %s" % (k, was, now))
        if r["vars_missing"]: t.append("  %d calibration key(s) exist only on the old board and are not added" % r["vars_missing"])
    return t


def main(argv):
    if len(argv) < 2 or argv[1] not in ("plan", "apply"): print(__doc__); return 2
    a, i = {}, 2
    while i < len(argv):
        if argv[i].startswith("--") and i + 1 < len(argv): a[argv[i][2:]] = argv[i + 1]; i += 2
        else: print(__doc__); return 2
    for k in ("old-printer", "printer"):
        if k not in a: print("missing --%s" % k); return 2
    r = build(a)
    if argv[1] == "plan" or r is None: print("\n".join(report(r)))
    if r is None or argv[1] == "plan": return 0
    stamp = a.get("stamp", time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(a["printer"], "%s.wm-before-import-%s" % (a["printer"], stamp))
    with open(a["printer"], "w", encoding="utf-8") as f: f.write(r["new_text"])
    if r["vars_text"] is not None and r["vars_changed"]:
        shutil.copy2(a["vars"], "%s.wm-before-import-%s" % (a["vars"], stamp))
        with open(a["vars"], "w", encoding="utf-8") as f: f.write(r["vars_text"])
    print("Written. Backups: *.wm-before-import-%s" % stamp)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
