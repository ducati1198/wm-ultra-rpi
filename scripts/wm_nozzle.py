#!/usr/bin/env python3
"""Sets the nozzle diameter (and type) of one tool head on the Pi, like the WonderMaker screen's Nozzle Type page does.

  wm_nozzle.py [--config DIR] show                      lists the diameter of every tool head found in printer.cfg
  wm_nozzle.py [--config DIR] set TOOL DIAMETER [TYPE]  TOOL 0-3 (nozzle 1-4), DIAMETER in mm (0.1-2.0), TYPE 0 = hardened steel, 1 = stainless steel

What "set" changes (Klipper has to be restarted afterwards to read the new diameter):
  - the "nozzle_diameter:" line in [extruder] / [extruder1] ... of printer.cfg (and the same option in the SAVE_CONFIG block, if it is there)
  - tmt1.ini [nozzle] typeN, only when that file exists and a TYPE was given (that is where the factory app keeps the type)
Every file it changes is first copied to <file>.wm-before-nozzle-STAMP. Nothing else in the files is touched.
The config folder is --config, else $WM_CONFIG_DIR, else ~/printer_data/config. Exit 0 = done, 1 = refused (message says why)."""
import os, re, sys, time

MARK = "#*# <---------------------- SAVE_CONFIG ---------------------->"


def section_name(tool):
    return "extruder" if tool == 0 else "extruder%d" % tool


def split_autosave(text):
    i = text.find("\n" + MARK)
    if text.startswith(MARK): return "", text
    return (text, "") if i < 0 else (text[:i + 1], text[i + 1:])


def find_option(lines, sec, opt, autosave=False):
    """index of the active line "opt: value" inside [sec] (lines of the config text; for the autosave block lines start with '#*# ')"""
    inside = False; pre = r"#\*#\s?" if autosave else ""
    for n, line in enumerate(lines):
        body = re.sub(r"^#\*#\s?", "", line) if autosave else line
        if autosave and not line.startswith("#*#"): continue
        if not autosave and (not body.strip() or body.lstrip()[:1] in "#;"): continue
        m = re.match(r"^\[(.+?)\]\s*(?:[#;].*)?$", body.strip()) if body[:1] == "[" else None
        if m: inside = (m.group(1).strip() == sec); continue
        if inside and re.match(r"^%s\s*[:=]" % re.escape(opt), body, re.I): return n
    return None


def has_section(lines, sec, autosave=False):
    for line in lines:
        body = re.sub(r"^#\*#\s?", "", line) if autosave else line
        if body.startswith("[") and body.strip().rstrip("]").lstrip("[").strip() == sec: return True
    return False


def replace_value(line, value):
    m = re.match(r"^(\s*#?\*?#?\s?[A-Za-z0-9_]+\s*[:=]\s*)([^#;\s]*)(.*)$", line)
    return (m.group(1) + value + m.group(3)) if m else line


def read(p):
    return open(p, errors="replace").read()


def write(path, text, stamp, done):
    if path not in done:
        if os.path.exists(path): open(path + ".wm-before-nozzle-" + stamp, "w").write(read(path))
        done.add(path)
    tmp = path + ".wm-tmp"; open(tmp, "w").write(text); os.replace(tmp, path)


def show(cfgdir):
    pc = os.path.join(cfgdir, "printer.cfg")
    if not os.path.isfile(pc): print("no printer.cfg in " + cfgdir); return 1
    regular, auto = split_autosave(read(pc)); rl = regular.split("\n"); al = auto.split("\n"); out = []
    for t in range(4):
        sec = section_name(t)
        if not has_section(rl, sec): continue
        i = find_option(al, sec, "nozzle_diameter", True) if auto else None
        if i is not None: v = re.sub(r"^.*[:=]\s*", "", al[i]).strip()
        else:
            j = find_option(rl, sec, "nozzle_diameter"); v = re.sub(r"^.*?[:=]\s*", "", rl[j]).split("#")[0].strip() if j is not None else "(not set)"
        out.append("Nozzle %d (tool T%d, [%s]): %s mm" % (t + 1, t, sec, v))
    print("\n".join(out) if out else "no [extruder] section found"); return 0 if out else 1


def set_nozzle(cfgdir, tool, diameter, ntype=None, stamp=None):
    stamp = stamp or time.strftime("%Y%m%d_%H%M%S"); pc = os.path.join(cfgdir, "printer.cfg"); done = set()
    if tool not in range(4): print("refused: the tool must be 0 to 3 (nozzle 1 to 4)"); return 1
    try: d = float(diameter)
    except ValueError: print("refused: the diameter must be a number in mm, like 0.4"); return 1
    if not 0.1 <= d <= 2.0: print("refused: a diameter of %s mm is outside 0.1 to 2.0" % diameter); return 1
    if ntype is not None and ntype not in (0, 1): print("refused: the type must be 0 (hardened steel) or 1 (stainless steel)"); return 1
    if not os.path.isfile(pc): print("refused: no printer.cfg in " + cfgdir); return 1
    sec = section_name(tool); value = "%.6f" % d
    text = read(pc); regular, auto = split_autosave(text); rl = regular.split("\n"); al = auto.split("\n") if auto else []
    if not has_section(rl, sec): print("refused: [%s] is not an active section of printer.cfg: tool T%d is not set up on this printer" % (sec, tool)); return 1
    i = find_option(rl, sec, "nozzle_diameter")
    if i is not None: rl[i] = replace_value(rl[i], value)
    else:
        hdr = next(n for n, l in enumerate(rl) if l.strip().startswith("[%s]" % sec)); rl.insert(hdr + 1, "nozzle_diameter: " + value)
    if al:
        k = find_option(al, sec, "nozzle_diameter", True)
        if k is not None: al[k] = replace_value(al[k], value)
    new = "\n".join(rl) + ("\n".join(al) if al else "")
    if new != text: write(pc, new, stamp, done)
    msg = "Nozzle %d (T%d): nozzle_diameter is now %s mm in printer.cfg" % (tool + 1, tool, value)
    ini = os.path.join(cfgdir, "tmt1.ini")
    if ntype is not None and os.path.isfile(ini):
        t = read(ini); key = "type%d" % tool
        if re.search(r"^\[nozzle\]", t, re.M):
            body = re.search(r"^\[nozzle\]\n((?:(?!\[).*\n?)*)", t, re.M)
            if re.search(r"^%s\s*=" % key, body.group(1), re.M):
                t2 = t[:body.start(1)] + re.sub(r"^%s\s*=.*$" % key, "%s=%d" % (key, ntype), body.group(1), flags=re.M) + t[body.end(1):]
            else:
                t2 = t[:body.start(1)] + body.group(1).rstrip("\n") + "\n%s=%d\n" % (key, ntype) + t[body.end(1):]
        else: t2 = t.rstrip("\n") + "\n\n[nozzle]\n%s=%d\n" % (key, ntype)
        if t2 != t: write(ini, t2, stamp, done)
        msg += "; tmt1.ini type%d=%d" % (tool, ntype)
    print(msg + ". Restart Klipper to use it."); return 0


def main(argv):
    a = argv[1:]; cfgdir = os.environ.get("WM_CONFIG_DIR") or os.path.expanduser("~/printer_data/config")
    if len(a) >= 2 and a[0] == "--config": cfgdir = a[1]; a = a[2:]
    if not a: print(__doc__); return 2
    if a[0] == "show": return show(cfgdir)
    if a[0] == "set" and len(a) in (3, 4):
        try: tool = int(a[1]); ntype = int(a[3]) if len(a) == 4 else None
        except ValueError: print("refused: TOOL and TYPE must be whole numbers"); return 1
        return set_nozzle(cfgdir, tool, a[2], ntype)
    print(__doc__); return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
