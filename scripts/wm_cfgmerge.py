#!/usr/bin/env python3
"""3-way merge of printer.cfg when WonderMaker publishes a new version, so that WonderMaker's new settings arrive on the Pi
and the Pi's own additions stay.

  BASE  = the WonderMaker printer.cfg the Pi was set up from (e.g. 1.1.13)
  REL   = the new WonderMaker printer.cfg (e.g. 1.1.14)
  LIVE  = the printer.cfg on the Pi (BASE + the Pi's own changes + the SAVE_CONFIG block)

Rules, always:
  - the SAVE_CONFIG block (the '#*#' lines at the end: PID, input shaper, bed mesh, probe values) is LIVE's, byte for byte
  - the Pi's [include ...] lines stay (a missing one is put back); sections and lines the Pi added stay
  - canbus_uuid / serial / canbus_interface keep the Pi's values
  - a setting only WonderMaker changed is taken; a setting only the Pi changed is kept
  - a setting both changed to different values is a conflict: you choose, one by one (mine / theirs)

  wm_cfgmerge.py plan   BASE REL LIVE                    what would change (nothing is written). Exit 0 = nothing to do, 10 = clean changes, 11 = conflicts
  wm_cfgmerge.py apply  BASE REL LIVE [--all mine|theirs] [--choices m,t,...] [--stamp S]
                                                         writes LIVE (the old one is copied to LIVE.wm-before-cfgmerge-S); asks per conflict when on a terminal
  wm_cfgmerge.py addkeys REL LIVE [--stamp S]            saved_variables.cfg: adds keys that LIVE does not have; never changes a value
(no extra programs needed)"""
import difflib, os, re, shutil, subprocess, sys, tempfile, time

MARK = "#*# <---------------------- SAVE_CONFIG ---------------------->"
ID_OPT = re.compile(r"^(canbus_uuid|serial|canbus_interface)\s*([:=])\s*(.*)$", re.I)


def read(p):
    return open(p, errors="replace").read()


def split_autosave(text):
    if text.startswith(MARK): return "", text
    i = text.find("\n" + MARK)
    return (text, "") if i < 0 else (text[:i + 1], text[i + 1:])


def nl(t):
    return t if (not t or t.endswith("\n")) else t + "\n"


def sections(text):
    """[(line index, section)] of the active lines; helper for the include and id rules"""
    out, sec = [], None
    for n, line in enumerate(text.split("\n")):
        pr = re.sub("[#;].*$", "", line).rstrip()
        if pr.startswith("["): sec = pr[1:-1].strip()
        out.append((n, sec))
    return out


def live_ids(live):
    d = {}
    for (n, sec), line in zip(sections(live), live.split("\n")):
        m = ID_OPT.match(line)
        if m and sec: d[(sec, m.group(1).lower())] = m.group(3)
    return d


def pin_ids(text, ids):
    """in TEXT, give canbus_uuid / serial / canbus_interface the value LIVE has for the same section"""
    lines = text.split("\n")
    for (n, sec), line in zip(sections(text), list(lines)):
        m = ID_OPT.match(line)
        if m and (sec, m.group(1).lower()) in ids: lines[n] = "%s%s %s" % (m.group(1), m.group(2), ids[(sec, m.group(1).lower())])
    return "\n".join(lines)


def parse_cfg(text):
    """[section dict]: {'id': (name, n), 'name', 'head': raw header line or None, 'items': [{'kind': 'opt'|'other', 'key', 'norm', 'raw': [lines]}]}
    The first section (name None) holds what stands above the first [header]. A section name that appears twice gets n = 1, 2, ..."""
    secs, count = [{"id": (None, 0), "name": None, "head": None, "items": []}], {}
    lines = text.split("\n")
    if lines and lines[-1] == "": lines.pop()
    seen = {}
    for line in lines:
        pr = re.sub("[#;].*$", "", line).rstrip()
        if pr.startswith("[") and not line[:1].isspace():
            name = pr[1:-1].strip(); count[name] = count.get(name, 0) + 1
            secs.append({"id": (name, count[name]), "name": name, "head": line, "items": []}); continue
        items = secs[-1]["items"]
        if pr and line[:1].isspace() and items and items[-1]["kind"] == "opt":   # continuation of the option above
            items[-1]["raw"].append(line); items[-1]["norm"] += " " + re.sub(r"\s+", " ", pr.strip()); continue
        if pr and not line[:1].isspace():
            key = re.sub(r"\s*[:=].*$", "", pr).strip().lower(); val = re.sub(r"^[^:=]*[:=]\s*", "", pr).strip()
            k = seen.setdefault((secs[-1]["id"], key), 0); seen[(secs[-1]["id"], key)] = k + 1
            items.append({"kind": "opt", "key": key if k == 0 else "%s#%d" % (key, k + 1), "norm": re.sub(r"\s+", " ", val), "raw": [line]})
        else: items.append({"kind": "other", "key": None, "norm": None, "raw": [line]})
    return secs


def merge_cfg(base, rel, live, choices=()):
    """(merged regular text, [conflict dicts], [notes]). choices: 'm' / 't' for the conflicts in order (default m)"""
    B = {s["id"]: s for s in parse_cfg(base)}; R = parse_cfg(rel); L = parse_cfg(live); Rd = {s["id"]: s for s in R}; Ld = {s["id"]: s for s in L}
    conflicts, notes, out = [], [], []
    def choice():
        k = len(conflicts) - 1
        return choices[k] if k < len(choices) else "m"
    def opts(sec): return {} if sec is None else {i["key"]: i for i in sec["items"] if i["kind"] == "opt"}
    ids = live_ids(live)
    for ls in L:
        sid = ls["id"]; bs, rs = B.get(sid), Rd.get(sid)
        if sid != (None, 0) and bs is not None and rs is None:   # WonderMaker removed the section
            if [i["raw"] for i in ls["items"] if i["kind"] == "opt"] == [i["raw"] for i in bs["items"] if i["kind"] == "opt"]:
                notes.append("removed [%s] (WonderMaker no longer has it and you had not changed it)" % ls["name"]); continue
            notes.append("kept [%s]: WonderMaker removed it, but you changed it" % ls["name"])
        bo, ro, lo = opts(bs), opts(rs), opts(ls)
        if bs is None or rs is None: out.append(ls); continue   # the Pi's own section, or nothing to compare with
        items = [dict(i, raw=list(i["raw"])) for i in ls["items"]]; add = []
        for key in list(dict.fromkeys(list(lo) + list(ro) + list(bo))):
            b, r, l = bo.get(key), ro.get(key), lo.get(key)
            bn, rn, ln = (b or {}).get("norm"), (r or {}).get("norm"), (l or {}).get("norm")
            if ID_OPT.match((l or r or {"raw": [""]})["raw"][0]) and (sid[0], key) in ids: continue   # canbus_uuid / serial: the Pi's
            if rn == bn or ln == rn: continue                    # WonderMaker did not change it, or both agree
            if ln == bn:                                        # only WonderMaker changed it
                if l is None: add.append(r)                      # a new or restored setting
                elif r is None: items = [x for x in items if x is not next(y for y in items if y["key"] == key)]; notes.append("[%s] %s: removed (WonderMaker dropped it)" % (ls["name"], key))
                else:
                    at = next(n for n, y in enumerate(items) if y["key"] == key); items[at] = dict(r, raw=list(r["raw"])); notes.append("[%s] %s: now %s (WonderMaker changed it)" % (ls["name"], key, rn))
                continue
            conflicts.append({"section": ls["name"], "key": key, "mine": l["raw"] if l else [], "theirs": r["raw"] if r else []}); ch = choice()
            if ch == "t":
                at = next((n for n, y in enumerate(items) if y["key"] == key), None)
                if r is None and at is not None: items.pop(at)
                elif at is not None: items[at] = dict(r, raw=list(r["raw"]))
                elif r is not None: add.append(r)
            # 'm': nothing to do
        if add:
            last = max([n for n, y in enumerate(items) if y["kind"] == "opt"] or [-1])
            for r in add: items.insert(last + 1, dict(r, raw=list(r["raw"]))); last += 1; notes.append("[%s] %s: added (new in WonderMaker's version)" % (ls["name"], r["key"]))
        out.append(dict(ls, items=items))
    have = {s["id"] for s in out}
    for n, rs in enumerate(R):                                  # sections only the new version has
        sid = rs["id"]
        if sid in have or sid in Ld or sid in B or rs["name"] is None: continue
        prev = next((R[k]["id"] for k in range(n - 1, -1, -1) if R[k]["id"] in have), None)
        at = next((k + 1 for k, x in enumerate(out) if x["id"] == prev), len(out)) if prev else len(out)
        out.insert(at, dict(rs, items=[dict(i, raw=list(i["raw"])) for i in rs["items"]])); have.add(sid)
        notes.append("added [%s] (new in WonderMaker's version)" % rs["name"])
    lines = []
    for s in out:
        if s["head"] is not None: lines.append(s["head"])
        for i in s["items"]: lines += i["raw"]
    return "\n".join(lines) + "\n", conflicts, notes


def merge(base, rel, live):
    b, _ = split_autosave(base); r, _ = split_autosave(rel); l, auto = split_autosave(live)
    return {"base": b, "rel": r, "live": l, "auto": auto}


def render(m, choices):
    text, conflicts, notes = merge_cfg(m["base"], m["rel"], m["live"], choices)
    m["notes"], m["conflicts"] = notes, conflicts
    return text + m["auto"]


def conflicts_of(m):
    render(m, ["m"] * 999)
    return [("conflict", c["mine"], c["theirs"], c) for c in m["conflicts"]]


def diff_lines(old, new, n=1):
    return [l for l in difflib.unified_diff(old.split("\n"), new.split("\n"), "printer.cfg (now)", "printer.cfg (after)", lineterm="", n=n)]


def summary(m, live):
    cs = conflicts_of(m); text = render(m, ["m"] * len(cs)); out = []
    if text == live and not cs: return 0, ["printer.cfg: nothing to merge (the Pi already has everything from the new version)."], text
    d = diff_lines(live, text)
    out += ["  " + x for x in m["notes"]]
    out.append("printer.cfg: %d line(s) from WonderMaker's new version would be added or changed, your own lines stay:" % sum(1 for x in d if x[:1] in "+-" and x[:3] not in ("+++", "---")))
    out += ["  " + x for x in d]
    for i, c in enumerate(cs, 1):
        out.append("CONFLICT %d: [%s] %s: you and WonderMaker changed it differently." % (i, c[3]["section"], c[3]["key"]))
        out += ["  mine:    " + x.strip() for x in c[1]] or ["  mine:    (removed)"]
        out += ["  theirs:  " + x.strip() for x in c[2]] or ["  theirs:  (removed)"]
    return (11 if cs else 10), out, text


def choose(m, ask):
    ch = []
    for i, c in enumerate(conflicts_of(m), 1):
        print("\nConflict %d of %d: [%s] %s (you and WonderMaker changed it differently)" % (i, len(conflicts_of(m)), c[3]["section"], c[3]["key"]))
        print("  m = mine:\n" + "\n".join("      " + x.strip() for x in c[1]) + "\n  t = WonderMaker's new:\n" + "\n".join("      " + x.strip() for x in c[2]))
        a = ""
        while a not in ("m", "t"): a = ask("  Keep (m)ine or take (t)heirs? ").strip().lower()[:1]
        ch.append(a)
    return ch


def write_live(path, text, stamp):
    bk = "%s.wm-before-cfgmerge-%s" % (path, stamp); shutil.copy2(path, bk)
    tmp = path + ".wm-tmp"; open(tmp, "w").write(text); shutil.copystat(path, tmp); os.replace(tmp, path)
    return bk


def addkeys(rel, live):
    """(new live text, [keys added]) : keys of REL that LIVE does not have; existing values are never changed"""
    def parse(t):
        d, sec, order = {}, None, []
        for line in t.split("\n"):
            pr = re.sub("[#;].*$", "", line).rstrip()
            if not pr or pr[0].isspace(): continue
            if pr[0] == "[": sec = pr[1:-1].strip(); order.append(sec); d.setdefault(sec, {}); continue
            k = re.sub(r"\s*[:=].*$", "", pr).strip().lower()
            if sec is not None: d[sec][k] = line
        return d
    r, l = parse(rel), parse(live); lines = live.rstrip("\n").split("\n"); added = []
    for sec, opts in r.items():
        missing = [(k, v) for k, v in opts.items() if k not in l.get(sec, {})]
        if not missing: continue
        if sec in l:
            at = max(i for i, x in enumerate(lines) if re.sub("[#;].*$", "", x).strip() == "[%s]" % sec)
            lines[at + 1:at + 1] = [v for k, v in missing]
        else: lines += ["", "[%s]" % sec] + [v for k, v in missing]
        added += ["%s/%s" % (sec, k) for k, v in missing]
    return "\n".join(lines) + "\n", added


def main(argv):
    if len(argv) < 2 or argv[1] not in ("plan", "apply", "addkeys"): print(__doc__); return 2
    cmd, a = argv[1], argv[2:]
    opt = lambda f: a[a.index(f) + 1] if f in a else None
    stamp = opt("--stamp") or time.strftime("%Y%m%d_%H%M%S")
    if cmd == "addkeys":
        rel, live = a[0], a[1]; text, added = addkeys(read(rel), read(live))
        if not added: print("saved_variables.cfg: nothing to add."); return 0
        if "--dry-run" not in a: print("saved_variables.cfg: added %s (backup %s)" % (", ".join(added), write_live(live, text, stamp)))
        else: print("saved_variables.cfg: would add " + ", ".join(added))
        return 10
    base, rel, live = a[0], a[1], a[2]
    live_text = read(live); m = merge(read(base), read(rel), live_text); code, lines, _ = summary(m, live_text)
    print("\n".join(lines))
    if cmd == "plan" or code == 0: return code
    cs = conflicts_of(m)
    if opt("--all"): ch = ["m" if opt("--all") == "mine" else "t"] * len(cs)
    elif opt("--choices"): ch = opt("--choices").split(",")
    elif cs and os.environ.get("WM_CFGMERGE_CHOICE"): ch = list(os.environ["WM_CFGMERGE_CHOICE"])
    elif cs: ch = choose(m, input)
    else: ch = []
    text = render(m, ch); bk = write_live(live, text, stamp)
    print("\nprinter.cfg updated. The old one is saved as %s" % bk)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
