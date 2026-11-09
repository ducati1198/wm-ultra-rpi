#!/usr/bin/env python3
"""Reads and sets the CAN ids of the four tool heads on the Pi (the canbus_uuid of [mcu T0] ... [mcu T3]), like the WonderMaker screen's Extruder Setup does.

  wm_canids.py [--config DIR] show                    prints the id of T0 to T3 as written in wm_zru_thr0.cfg ... wm_zru_thr3.cfg
  wm_canids.py [--config DIR] apply ID0 ID1 ID2 ID3   writes these four ids (12 hex digits each) into the four files

"apply" refuses (and changes nothing) when an id is not 12 hex digits, when two tools would get the same id, or when a file is missing.
Every file it changes is first copied to <file>.wm-before-match-STAMP, and only the canbus_uuid line of that file is touched.
Klipper has to be restarted afterwards (FIRMWARE_RESTART) to use the new ids.
The config folder is --config, else $WM_CONFIG_DIR, else ~/printer_data/config. Exit 0 = done, 1 = refused (the message says why)."""
import os, re, sys, time

LINE = re.compile(r"^(\s*canbus_uuid\s*[:=]\s*)([^#;\s]*)(.*)$", re.I | re.M)
HEX12 = re.compile(r"^[0-9a-f]{12}$")


def path(cfgdir, tool):
    return os.path.join(cfgdir, "wm_zru_thr%d.cfg" % tool)


def read(p):
    return open(p, errors="replace").read()


def current(cfgdir):
    """{tool: id or None}; None when the file or the canbus_uuid line is missing"""
    out = {}
    for t in range(4):
        p = path(cfgdir, t); m = LINE.search(read(p)) if os.path.isfile(p) else None
        out[t] = m.group(2).strip().lower() if m else None
    return out


def show(cfgdir):
    cur = current(cfgdir); bad = 0
    for t in range(4):
        print("T%d %s" % (t, cur[t] or "(not found in wm_zru_thr%d.cfg)" % t)); bad += cur[t] is None
    return 1 if bad else 0


def apply(cfgdir, ids, stamp=None):
    stamp = stamp or time.strftime("%Y%m%d_%H%M%S"); new = [i.strip().lower() for i in ids]
    for t, i in enumerate(new):
        if not HEX12.match(i): print("refused: the id of T%d (%r) is not 12 hex digits" % (t, ids[t])); return 1
    for a in range(4):
        for b in range(a + 1, 4):
            if new[a] == new[b]: print("refused: T%d and T%d would both get %s" % (a, b, new[a])); return 1
    cur = current(cfgdir)
    for t in range(4):
        if cur[t] is None: print("refused: %s is missing or has no canbus_uuid line" % path(cfgdir, t)); return 1
    changed = []
    for t in range(4):
        if cur[t] == new[t]: continue
        p = path(cfgdir, t); text = read(p)
        open(p + ".wm-before-match-" + stamp, "w").write(text)
        tmp = p + ".wm-tmp"; open(tmp, "w").write(LINE.sub(lambda m: m.group(1) + new[t] + m.group(3), text, count=1)); os.replace(tmp, p)
        changed.append("T%d %s -> %s" % (t, cur[t], new[t]))
    print(("Changed: " + "; ".join(changed) + ". Restart Klipper (FIRMWARE_RESTART) to use them.") if changed else "Nothing to change: the four ids are already these.")
    return 0


def main(argv):
    a = argv[1:]; cfgdir = os.environ.get("WM_CONFIG_DIR") or os.path.expanduser("~/printer_data/config")
    if len(a) >= 2 and a[0] == "--config": cfgdir = a[1]; a = a[2:]
    if a and a[0] == "show" and len(a) == 1: return show(cfgdir)
    if a and a[0] == "apply" and len(a) == 5: return apply(cfgdir, a[1:])
    print(__doc__); return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
