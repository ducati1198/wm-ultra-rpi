#!/usr/bin/env python3
"""Checks (and fixes) where the heaters' PID settings live, so Klipper's SAVE_CONFIG can store a PID result.

Why: SAVE_CONFIG refuses with "section '...' option 'control' conflicts with included value" when an [include]d file sets
control / pid_Kp / pid_Ki / pid_Kd for a section it has to save. Those four options must live in printer.cfg itself (Klipper
then keeps its own copy in the SAVE_CONFIG block). This looks at the hotends and the heated bed.
The chamber heater (heater_generic chamber) is deliberately NOT looked at: WonderMaker's heaters.py multiplies the chamber
reading by 1.18 while it heats, which breaks PID_CALIBRATE, so the chamber stays as zru-s.cfg has it.
The version that also moved the chamber heater into printer.cfg is kept in chamber_test/ (see chamber_test/README.md).
Second check: every hotend ([extruder], [extruder1] ...) must end up with control: pid (an active line in printer.cfg or a value
in the SAVE_CONFIG block); with neither, the hotend is a watermark heater and PID_CALIBRATE has nothing to tune.

  wm_pidcfg.py check CONFIG_DIR            lists the problems; exit 0 = none, 1 = problems, 2 = no printer.cfg
  wm_pidcfg.py fix   CONFIG_DIR [STAMP]    repairs them; every file it changes is first copied to <file>.wm-before-pidcfg-STAMP
Nothing else in the files is touched. Lines beginning "CONFLICT", "HOTEND" and "FIXED" are meant to be read by the installer."""
import glob, os, re, sys, time

MARK = "#*# <---------------------- SAVE_CONFIG ---------------------->"
OPTS = ("control", "pid_kp", "pid_ki", "pid_kd")
DEFAULTS = (("control", "pid"), ("pid_Kp", "26.0"), ("pid_Ki", "7.8"), ("pid_Kd", "21.0"))   # only used when nothing else is known


def target(sec):
    return sec == "extruder" or re.fullmatch(r"extruder\d+", sec or "") is not None or sec == "heater_bed"


def hotend(sec):
    return sec == "extruder" or re.fullmatch(r"extruder\d+", sec or "") is not None


def split_autosave(text):
    i = text.find("\n" + MARK)
    if text.startswith(MARK): return "", text
    return (text, "") if i < 0 else (text[:i + 1], text[i + 1:])


def entries(text):
    """[(line index, section, field, value, is_header)] for the active lines (not comments, not continuation lines)"""
    out, sec = [], None
    for n, line in enumerate(text.split("\n")):
        pr = re.sub("[#;].*$", "", line).rstrip()
        if not pr or pr[0].isspace(): continue
        if pr[0] == "[":
            sec = pr[1:-1].strip(); out.append((n, sec, None, None, True)); continue
        field = re.sub("[^A-Za-z0-9_].*$", "", pr).lower()
        val = re.sub(r"^[A-Za-z0-9_]+\s*[:=]\s*", "", pr)
        out.append((n, sec, field, val.strip(), False))
    return out


def autosave_values(auto):
    """{section: {option: value}} from the '#*# ' lines"""
    plain = "\n".join(re.sub(r"^#\*#\s?", "", l) for l in auto.split("\n") if l.startswith("#*#"))
    d = {}
    for _, sec, f, v, hdr in entries(plain):
        if not hdr: d.setdefault(sec, {})[f] = v
    return d


def includes_of(path, text, seen=None):
    seen = seen if seen is not None else []
    for _, sec, f, v, hdr in entries(text):
        if hdr and sec.startswith("include "):
            spec = sec[8:].strip()
            for fn in sorted(glob.glob(os.path.join(os.path.dirname(path), spec))):
                if fn in seen or not os.path.isfile(fn): continue
                seen.append(fn)
                includes_of(fn, open(fn, errors="replace").read(), seen)
    return seen


def read(path):
    return open(path, errors="replace").read()


def conflicts(cfgdir):
    """[(file path, section, [(line index, option as written, value)])] for PID options set in files that printer.cfg includes"""
    pc = os.path.join(cfgdir, "printer.cfg"); regular, _ = split_autosave(read(pc)); out = []
    for fn in includes_of(pc, regular):
        t = read(fn); by = {}
        for n, sec, f, v, hdr in entries(t):
            if not hdr and f in OPTS and target(sec):
                name = re.sub("[^A-Za-z0-9_].*$", "", t.split("\n")[n])
                by.setdefault(sec, []).append((n, name, v))
        for sec, items in by.items(): out.append((fn, sec, items))
    return out


def hotend_states(cfgdir):
    """[(section, effective control)] for every hotend section found in printer.cfg or the files it includes"""
    pc = os.path.join(cfgdir, "printer.cfg"); text = read(pc); regular, auto = split_autosave(text)
    av = autosave_values(auto); files = [pc] + includes_of(pc, regular); ctl, secs = {}, []
    for fn in files:
        t = split_autosave(read(fn))[0]
        for n, sec, f, v, hdr in entries(t):
            if hotend(sec) and sec not in secs: secs.append(sec)
            if not hdr and hotend(sec) and f == "control": ctl[sec] = v.lower()
    out = []
    for sec in secs:
        c = ctl.get(sec) or av.get(sec, {}).get("control", "watermark")
        out.append((sec, c.lower()))
    return out


def check(cfgdir):
    probs = []
    for fn, sec, items in conflicts(cfgdir):
        probs.append("CONFLICT %s [%s] %s" % (os.path.basename(fn), sec, " ".join(i[1] for i in items)))
    for sec, c in hotend_states(cfgdir):
        if c != "pid": probs.append("HOTEND [%s] control is %s, not pid" % (sec, c))
    return probs


def write_with_backup(path, text, stamp, done):
    if path not in done:
        if os.path.exists(path): open(path + ".wm-before-pidcfg-" + stamp, "w").write(read(path))
        done.add(path)
    tmp = path + ".wm-tmp"; open(tmp, "w").write(text); os.replace(tmp, path)


def section_range(lines, sec):
    """(header index, end index) of the first active [sec] block in lines (end = the next header or the end)"""
    ents = entries("\n".join(lines)); start = None
    for n, s, f, v, hdr in ents:
        if hdr and s == sec and start is None: start = n; continue
        if hdr and start is not None: return start, n
    return (start, len(lines)) if start is not None else (None, None)


def fix(cfgdir, stamp=None):
    stamp = stamp or time.strftime("%Y%m%d_%H%M%S"); pc = os.path.join(cfgdir, "printer.cfg"); done = set(); said = []
    moves = {}   # section -> [(option as written, value, source file)]
    # 1. take the options out of the included files
    for fn, sec, items in conflicts(cfgdir):
        lines = read(fn).split("\n"); drop = set()
        for n, name, v in items:
            drop.add(n); k = n + 1
            while k < len(lines) and lines[k][:1].isspace() and lines[k].strip(): drop.add(k); k += 1
            moves.setdefault(sec, []).append((name, v, os.path.basename(fn)))
        left = [l for i, l in enumerate(lines) if i not in drop]
        write_with_backup(fn, "\n".join(left), stamp, done)
        said.append("FIXED %s: removed %s from [%s] (copy: %s.wm-before-pidcfg-%s)" % (os.path.basename(fn), " ".join(i[1] for i in items), sec, os.path.basename(fn), stamp))
    # 2. put them into printer.cfg
    regular, auto = split_autosave(read(pc)); av = autosave_values(auto)
    lines = regular.split("\n"); changed = False
    for sec, items in moves.items():
        s, e = section_range(lines, sec)
        have = {f for n, ss, f, v, hdr in entries("\n".join(lines)) if ss == sec and not hdr}
        add = [(nm, v) for nm, v, src in items if nm.lower() not in have and nm.lower() not in av.get(sec, {})]
        if s is None:
            while lines and lines[-1] == "": lines.pop()
            lines += ["", "[%s]" % sec, "# moved here from %s: Klipper's SAVE_CONFIG cannot save a value that an included file sets" % items[0][2]] + ["%s: %s" % x for x in add] + [""]
            changed = True
        elif add:
            lines[s + 1:s + 1] = ["%s: %s" % x for x in add]; changed = True
        said.append("FIXED printer.cfg: [%s] now holds %s" % (sec, " ".join(x[0] for x in items)))
    # 3. hotends without PID
    for sec, c in hotend_states(cfgdir):
        if c == "pid": continue
        s, e = section_range(lines, sec)
        if s is None:
            said.append("HOTEND [%s] is not in printer.cfg itself: edit the file that holds it (control: pid and pid_Kp, pid_Ki, pid_Kd)" % sec); continue
        for opt, dflt in DEFAULTS:
            s, e = section_range(lines, sec); block = range(s + 1, e); lo = opt.lower()
            act = [i for i in block if re.match(r"^%s\s*[:=]" % lo, lines[i].lower())]
            com = [i for i in block if re.match(r"^#\s*%s\s*[:=]" % lo, lines[i].lower())]
            if opt == "control":
                if act: lines[act[0]] = re.sub(r"[:=].*$", ": pid", lines[act[0]])
                elif com: lines[com[0]] = re.sub(r"^#\s*", "", re.sub(r"[:=].*$", ": pid", lines[com[0]]))
                else: lines.insert(s + 1, "control: pid")
            elif act or lo in av.get(sec, {}): continue
            elif com: lines[com[0]] = re.sub(r"^#\s*", "", lines[com[0]])
            else: lines.insert(s + 1, "%s: %s" % (opt, dflt))
        changed = True
        said.append("FIXED printer.cfg: [%s] now has control: pid (run WM_NOZZLE_TEMP_CAL to tune it)" % sec)
    if changed: write_with_backup(pc, "\n".join(lines).rstrip("\n") + "\n" + (("\n" + auto) if auto else ""), stamp, done)
    return said


def main(argv):
    if len(argv) < 3 or argv[1] not in ("check", "fix"): print(__doc__); return 2
    cfgdir = argv[2]
    if not os.path.isfile(os.path.join(cfgdir, "printer.cfg")): print("no printer.cfg in " + cfgdir); return 2
    if argv[1] == "check":
        probs = check(cfgdir); print("\n".join(probs) if probs else "OK"); return 1 if probs else 0
    for s in fix(cfgdir, argv[3] if len(argv) > 3 else None): print(s)
    probs = [p for p in check(cfgdir)]
    print("\n".join(probs) if probs else "OK"); return 1 if probs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
