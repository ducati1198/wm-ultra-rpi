#!/usr/bin/env python3
"""devbox.py - turn a Raspberry Pi with the WonderMaker Klipper into a dev box: no printer, no MCUs, no sensors.

Klipper still reads WonderMaker's real config and loads WonderMaker's real (compiled) modules, but every MCU is a fake that
accepts every command. Heaters warm up and cool down in a simple simulation (Fluidd shows live curves), the tool changer
is simulated, and your real config is never changed: Klipper runs on a private copy. Fluidd, Moonraker, KlipperScreen and
nearly every macro work as on a printer, except for real motion, endstops, probing, load cells and the offset calibration.

  python3 devbox.py on        switch dev mode on  (restarts Klipper)
  python3 devbox.py off       switch back to the real printer (restarts Klipper)
  python3 devbox.py status    is dev mode on, is Klipper ready, current simulated temperatures
  python3 devbox.py smoke     run a list of G-code commands and report which ones work
  python3 devbox.py gcode "M104 S200" ...   send G-code to Klipper (through Moonraker)
  python3 devbox.py --help

Options for on:  --speed N (heating speed, default 2)   --yes (do not ask)   --force (even if a real printer seems connected)
Nothing here is used by the installers. See README-DEVBOX.md.
"""
import argparse, json, os, re, shlex, shutil, subprocess, sys, time, urllib.error, urllib.request, zlib

TOOL_VERSION = "0.1.0"
HOME = os.path.expanduser("~")
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DATA = os.environ.get("DEVBOX_DATA", os.path.join(HOME, "printer_data"))
CFG = os.path.join(DATA, "config")
DEV = os.path.join(DATA, "devbox")
SYS = os.environ.get("DEVBOX_SYS", "/sys")               # where USB devices and network links are read from (changed in tests)
COPY_IGNORE = ("*.before-*", "*.wm-before-*", "*.wm-removed-*", "*.wm-tmp", "*.zrbak*", "*.bak", "*.log", "__pycache__")   # saved copies and logs are not part of the private config
REAL_USB_IDS = (("1d50", "606f"),)                       # the USB bridge between the Pi and WonderMaker's main board
ENV = os.environ.get("DEVBOX_ENV", os.path.join(DATA, "systemd", "klipper.env"))
KLIPPER = os.environ.get("DEVBOX_KLIPPER", os.path.join(HOME, "klipper"))
MOONRAKER = os.environ.get("DEVBOX_MOONRAKER", "http://127.0.0.1:7125")
SIM_SRC = os.path.join(HERE, "devbox_sim.py")
INCLUDE_LINE = "[include devbox.cfg]"
DEV_CFG = os.path.join(DEV, "config")                    # private copy of the config folder used while dev mode is on
DEV_PRINTER_CFG = os.path.join(DEV_CFG, "printer.cfg")
# which dictionary each MCU gets: by the name in its [mcu NAME] section
DICT_FOR = (("T", "thr"), ("EX", "ext"), ("HUB", "hub"), ("CELL", "cell"))
FIRMWARE = {"klipper.bin": "main", "klipper_THR.bin": "thr", "klipper_EXT.bin": "ext", "klipper_HUB.bin": "hub",
            "klipper_CELL.bin": "cell"}

DEVBOX_CFG = """# Written by devbox.py on. Remove with: python3 devbox.py off
[devbox_sim]
speed: %s

# private copy of the saved variables
[save_variables]
filename: %s

# Klipper does not wait for temperatures when it has no real MCU (M109 returns at once), so a macro would start
# extruding while the simulated nozzle is still cold. The minimum extrusion temperature is lifted instead.
[extruder]
min_extrude_temp: 0
[extruder1]
min_extrude_temp: 0
[extruder2]
min_extrude_temp: 0
[extruder3]
min_extrude_temp: 0

# Stand-ins for the tool changer motor: there is no motor, so the lock state is kept by devbox_sim,
# which then answers the hall sensor, the lock sensor and the four dock sensors like a real changer would.
[gcode_macro LOCK]
gcode:
    DEVBOX_HALL LOCK=1

[gcode_macro UNLOCK]
gcode:
    DEVBOX_HALL LOCK=0

[gcode_macro _CHECK_AND_UNLOCK]
gcode:
    DEVBOX_HALL DOCK={params.T|int}
    UNLOCK
    G0 Y310 F6000
    M400
    UNLOCK_TOOL_FINISH

[gcode_macro _CHECK_AND_LOCK]
gcode:
    {%% set target_tool = params.T|int %%}
    {%% set is_nozzle_setting = printer.save_variables.variables.is_nozzle_setting|int %%}
    {%% if printer['filament_switch_sensor docked%%d' %% target_tool].filament_detected == False and is_nozzle_setting == 0 %%}
        SAVE_VARIABLE VARIABLE=fail_flag VALUE=-1
        { action_respond_info("tool is not properly placed on the mounting bracket") }
    {%% else %%}
        DEVBOX_HALL TOOL={target_tool}
        LOCK
        _LOCK_TOOL_FINISH T={target_tool}
    {%% endif %%}
"""

OK, BAD, INFO = "ok  ", "FAIL", "    "


def say(msg=""):
    print(msg, flush=True)


def die(msg, hint=""):
    print("\nERROR: " + msg)
    if hint:
        print("  -> " + hint)
    sys.exit(1)


# ---------------------------------------------------------------------------------------------- Moonraker
def api(path, method="GET", timeout=10, body=None):
    req = urllib.request.Request(MOONRAKER + path, method=method, data=body)
    with urllib.request.urlopen(req, timeout=timeout) as f:
        return json.loads(f.read().decode("utf-8", "replace") or "{}")


def klippy_state():
    try:
        return api("/printer/info", timeout=5)["result"]["state"]
    except Exception:
        return None


def print_state():
    try:
        return api("/printer/objects/query?print_stats", timeout=5)["result"]["status"]["print_stats"]["state"]
    except Exception:
        return None


def run_gcode(script, timeout=180):
    """returns (ok, message)"""
    try:
        api("/printer/gcode/script?script=" + urllib.request.quote(script), method="POST", timeout=timeout)
        return True, "ok"
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read().decode("utf-8", "replace")).get("error", {}).get("message", str(e))
        except Exception:
            msg = str(e)
        return False, msg
    except Exception as e:
        return False, "no answer: %s" % e


# ---------------------------------------------------------------------------------------------- model, dictionaries
def model_name():
    for p in (os.path.join(DATA, "wm-model"), os.path.join(HOME, "wm-model")):
        if os.path.exists(p):
            v = open(p).read().strip()
            if v:
                return v
    return "ultra-s"


def mcu_dir():
    return os.path.join(REPO, "factory", model_name(), "mcu")


def find_dict(data):
    """Klipper firmware carries its protocol dictionary as a zlib block"""
    for m in re.finditer(rb"\x78[\x01\x5e\x9c\xda]", data):
        try:
            raw = zlib.decompressobj().decompress(data[m.start():m.start() + 400000])
        except zlib.error:
            continue
        if not raw.startswith(b"{"):
            continue
        try:
            j = json.loads(raw)
        except ValueError:
            continue
        if "commands" in j and "config" in j and "version" in j:
            return raw, j
    return None, None


def extract_dicts(out_dir, quiet=False):
    src = mcu_dir()
    if not os.path.isdir(src):
        die("no MCU firmware folder at %s" % src, "run this from a wm-ultra-rpi checkout that has factory/%s/mcu" % model_name())
    os.makedirs(out_dir, exist_ok=True)
    got = {}
    for fn, key in FIRMWARE.items():
        p = os.path.join(src, fn)
        if not os.path.exists(p):
            continue
        raw, j = find_dict(open(p, "rb").read())
        if raw is None:
            die("no protocol dictionary found inside %s" % p)
        open(os.path.join(out_dir, key + ".json"), "wb").write(raw)
        got[key] = j
        if not quiet:
            say("  %s dictionary %-5s %-34s %s" % (OK, key, j["version"], j["config"].get("MCU", "?")))
    if "main" not in got:
        die("main MCU firmware (klipper.bin) not found in %s" % src)
    if "cell" not in got and "thr" in got:
        shutil.copyfile(os.path.join(out_dir, "thr.json"), os.path.join(out_dir, "cell.json"))
        if not quiet:
            say("  %s dictionary cell  (no CELL firmware in the repo: the THR dictionary is used)" % OK)
    return got


def mcu_names():
    """names of all [mcu NAME] sections in the config folder ('' = the main MCU)"""
    names, seen = [], set()
    for root, _, files in os.walk(CFG):
        for fn in files:
            if not fn.endswith(".cfg") or ".before-" in fn or ".zrbak" in fn:
                continue
            try:
                text = open(os.path.join(root, fn), errors="replace").read()
            except OSError:
                continue
            for m in re.finditer(r"^\[mcu(?:\s+([^\]\s]+))?\]", text, re.M):
                n = m.group(1) or ""
                if n not in seen:
                    seen.add(n)
                    names.append(n)
    return names


def dict_for(name):
    if not name:
        return "main"
    for prefix, key in DICT_FOR:
        if name.upper().startswith(prefix):
            return key
    return "thr"


# ---------------------------------------------------------------------------------------------- klipper.env
def read_args():
    if not os.path.exists(ENV):
        die("%s not found" % ENV, "this tool expects the Klipper service of wm-ultra-rpi (KLIPPER_ARGS in klipper.env)")
    text = open(ENV).read()
    m = re.search(r'^KLIPPER_ARGS="(.*)"[ \t]*$', text, re.M)
    if not m:
        die("no KLIPPER_ARGS line in %s" % ENV)
    return text, m


def strip_dev_args(tokens):
    out, i = [], 0
    while i < len(tokens):
        t = tokens[i]
        if t in ("-o", "-d") and i + 1 < len(tokens) and DEV in tokens[i + 1]:
            i += 2
            continue
        out.append(os.path.join(CFG, "printer.cfg") if t == DEV_PRINTER_CFG else t)
        i += 1
    return out


def write_args(tokens):
    text, m = read_args()
    new = text[:m.start()] + 'KLIPPER_ARGS="%s"' % " ".join(shlex.quote(t) if " " in t else t for t in tokens) + text[m.end():]
    open(ENV, "w").write(new)


def is_on():
    try:
        _, m = read_args()
    except SystemExit:
        return False
    return DEV in m.group(1)


# ---------------------------------------------------------------------------------------------- restart
def restart_klipper():
    say("  Restarting Klipper (sudo may ask for the password of this user; it is never stored)...")
    for cmd in (["sudo", "-n", "systemctl", "restart", "klipper"], ["sudo", "systemctl", "restart", "klipper"]):
        try:
            if subprocess.call(cmd) == 0:
                return True
        except OSError:
            break
    try:
        api("/machine/services/restart?service=klipper", method="POST", timeout=30)
        return True
    except Exception:
        return False


def wait_ready(seconds=90):
    end, last = time.time() + seconds, None
    while time.time() < end:
        st = klippy_state()
        if st != last and st:
            last = st
        if st == "ready":
            return True
        if st == "shutdown" or st == "error":
            time.sleep(3)
            if klippy_state() in ("shutdown", "error"):
                return False
        time.sleep(2)
    return False


# ---------------------------------------------------------------------------------------------- commands
def real_printer_signs():
    """what says that a real WonderMaker printer is connected to this Pi: [text]"""
    found = []
    base = os.path.join(SYS, "bus", "usb", "devices")
    try:
        for d in sorted(os.listdir(base)):
            try:
                ids = (open(os.path.join(base, d, "idVendor")).read().strip().lower(), open(os.path.join(base, d, "idProduct")).read().strip().lower())
            except OSError:
                continue
            if ids in REAL_USB_IDS:
                found.append("the main board's USB bridge %s:%s is plugged in" % ids)
    except OSError:
        pass
    try:
        if open(os.path.join(SYS, "class", "net", "can0", "operstate")).read().strip().lower() == "up":
            found.append("the CAN bus can0 is up")
    except OSError:
        pass
    return found


def cmd_on(a):
    if is_on():
        say("Dev mode is already on. (python3 devbox.py status)")
        return
    if not os.path.exists(SIM_SRC):
        die("devbox_sim.py is missing next to devbox.py")
    if not os.path.isdir(KLIPPER):
        die("Klipper not found at %s" % KLIPPER)
    if print_state() in ("printing", "paused"):
        die("a print is running or paused", "dev mode restarts Klipper: wait until the print is finished")
    signs = real_printer_signs()
    if signs and not a.force:
        die("this Pi looks like it is connected to a real printer (%s)" % "; ".join(signs),
            "dev mode would cut Klipper off from the printer. Use it on a Pi with no printer. If you are sure, add --force.")
    if not a.yes:
        say("Dev mode: Klipper will stop talking to any real printer and use fake MCUs with simulated temperatures.")
        say("It restarts Klipper. Switch back with:  python3 devbox.py off")
        if input("Type DEVBOX to continue: ").strip() != "DEVBOX":
            die("not confirmed, nothing changed")
    say("\nSwitching dev mode on")
    dicts = os.path.join(DEV, "dict")
    extract_dicts(dicts)
    os.makedirs(os.path.join(DEV, "out"), exist_ok=True)
    # A private copy of the config folder: macros such as G29 call SAVE_CONFIG, which would overwrite the real printer.cfg
    # (the real bed mesh and offsets). The real folder is never touched in dev mode.
    real_vars = os.path.join(CFG, "saved_variables.cfg")
    dev_vars = os.path.join(DEV, "saved_variables.cfg")
    shutil.rmtree(DEV_CFG, ignore_errors=True)
    shutil.copytree(CFG, DEV_CFG, ignore=shutil.ignore_patterns(*COPY_IGNORE))
    say("  %s private copy of the config folder: %s" % (OK, DEV_CFG))
    if os.path.exists(real_vars) and not os.path.exists(dev_vars):
        shutil.copyfile(real_vars, dev_vars)
    # the Klipper module
    dst = os.path.join(KLIPPER, "klippy", "extras", "devbox_sim.py")
    if os.path.lexists(dst):
        os.remove(dst)
    os.symlink(SIM_SRC, dst)
    say("  %s Klipper module devbox_sim linked into %s" % (OK, os.path.dirname(dst)))
    open(os.path.join(DEV_CFG, "devbox.cfg"), "w").write(DEVBOX_CFG % (a.speed, dev_vars))
    pc = DEV_PRINTER_CFG
    lines = open(pc).read().split("\n")
    # after every other section (so the stand-ins win), before the SAVE_CONFIG block
    at = next((i for i, l in enumerate(lines) if l.startswith("#*# <---")), len(lines))
    lines[at:at] = ["", INCLUDE_LINE, ""]
    open(pc, "w").write("\n".join(lines))
    say("  %s stand-in tool changer and private saved_variables added to the copy" % OK)
    # Klipper arguments: fake MCUs, one dictionary each
    text, m = read_args()
    tokens = strip_dev_args(shlex.split(m.group(1)))
    tokens = [DEV_PRINTER_CFG if t == os.path.join(CFG, "printer.cfg") else t for t in tokens]
    names = mcu_names()
    tokens += ["-o", os.path.join(DEV, "out", "mcu")]
    tokens += ["-d", os.path.join(dicts, "main.json")]
    for n in names:
        if n:
            tokens += ["-d", "%s=%s" % (n, os.path.join(dicts, dict_for(n) + ".json"))]
    write_args(tokens)
    say("  %s Klipper arguments changed: %d fake MCUs (%s)" % (OK, len(names), ", ".join(n or "main" for n in names)))
    if not restart_klipper():
        die("could not restart Klipper by itself", "run: sudo systemctl restart klipper   (then: python3 devbox.py status)")
    if wait_ready():
        say("\nDev mode is ON. Klipper is ready with fake MCUs. Open Fluidd and try it.")
        say("Check the macros:  python3 devbox.py smoke        Back to the printer:  python3 devbox.py off")
    else:
        say("\nKlipper did not become ready. Look at ~/printer_data/logs/klippy.log, or switch back: python3 devbox.py off")
        sys.exit(1)


def cmd_off(a):
    on = is_on()
    legacy = os.path.join(CFG, "devbox.cfg")        # written by an early version straight into the real folder
    if not on and not os.path.exists(legacy) and not os.path.isdir(DEV_CFG):
        say("Dev mode is not on. Nothing to do.")
        return
    if print_state() in ("printing", "paused"):
        die("a print is running or paused")
    say("Switching dev mode off")
    if on:
        text, m = read_args()
        write_args(strip_dev_args(shlex.split(m.group(1))))
        say("  %s Klipper arguments are back to normal" % OK)
    pc = os.path.join(CFG, "printer.cfg")
    if os.path.exists(pc):
        lines = open(pc).read().split("\n")
        if INCLUDE_LINE in lines:
            open(pc, "w").write("\n".join(l for l in lines if l != INCLUDE_LINE))
    if os.path.exists(legacy):
        os.remove(legacy)
    shutil.rmtree(DEV_CFG, ignore_errors=True)
    link = os.path.join(KLIPPER, "klippy", "extras", "devbox_sim.py")
    if os.path.islink(link):
        os.remove(link)
    shutil.rmtree(os.path.join(DEV, "out"), ignore_errors=True)
    if os.path.exists(os.path.join(DEV, "saved_variables.cfg")):
        os.remove(os.path.join(DEV, "saved_variables.cfg"))
    say("  %s the private copy of the config is removed (your real config was never changed)" % OK)
    if not restart_klipper():
        die("could not restart Klipper by itself", "run: sudo systemctl restart klipper")
    say("\nDev mode is OFF. Klipper restarts with the normal config (it shows an error until the real printer is connected).")


def cmd_status(a):
    on = is_on()
    say("devbox %s    model %s    repo %s" % (TOOL_VERSION, model_name(), REPO))
    say("  dev mode:   %s" % ("ON (fake MCUs, simulated temperatures)" if on else "off"))
    say("  Klipper:    %s" % (klippy_state() or "no answer from Moonraker"))
    if on:
        try:
            q = api("/printer/objects/query?extruder&extruder1&extruder2&extruder3&heater_bed&heater_generic%20chamber", timeout=5)
            for n, v in q["result"]["status"].items():
                say("  %-22s %6.1f C   target %s" % (n, v["temperature"], int(v["target"])))
        except Exception:
            pass
        say("  In the console: DEVBOX_STATUS (all sensors), DEVBOX_AMBIENT T=30, DEVBOX_FILAMENT SENSOR=filament0 PRESENT=0")


SMOKE = [
    ("Basics", ["G28", "G28 X Y", "QUERY_PROBE"]),
    ("Heating and waiting", ["M104 S190", "M109 S190", "M104 S0", "M140 S50", "M190 S50", "M140 S0", "M141 S30", "M191 S30", "M141 S0"]),
    ("Fans", ["M106 S128", "M107"]),
    ("Tool changes", ["T1", "T2", "T3", "T0", "PARK_CURRENT_TOOL"]),
    ("Filament", ["T0", "LOAD_FILAMENT", "UNLOAD_FILAMENT"]),
    ("Calibration", ["T0", "PROBE", "BED_MESH_CALIBRATE", "G29", "NOZZLE_PREPARE T=0"]),
    ("A short print", ["START_PRINT BED=50 EXTRUDER=190 INITIAL_TOOL=0", "PAUSE", "RESUME", "PRINT_END", "G28", "CANCEL_PRINT"]),
]


BAD_WORDS = ("!!", "Hall sensor error", "not properly placed", "Lock fail", "Unlock fail", "sequence error", "failed", "Unknown command")


def console_since(t):
    """lines Klipper printed to the console after time t (the macros report many failures that way, not as errors)"""
    try:
        rows = api("/server/gcode_store?count=200")["result"]["gcode_store"]
    except Exception:
        return []
    return [r["message"] for r in rows if r.get("time", 0) > t and r.get("type") == "response"]


def cmd_smoke(a):
    if not is_on():
        die("dev mode is off", "switch it on first: python3 devbox.py on")
    if klippy_state() != "ready":
        die("Klipper is not ready (%s)" % klippy_state(), "see ~/printer_data/logs/klippy.log")
    total = bad = 0
    for group, cmds in SMOKE:
        say("\n" + group)
        for c in cmds:
            t0 = time.time()
            ok, msg = run_gcode(c, timeout=a.timeout)
            if ok:
                hits = [l for l in console_since(t0 - 1) if any(w in l for w in BAD_WORDS)]
                if hits:
                    ok, msg = False, hits[0].strip("/ !")
            total += 1
            bad += not ok
            say("  %s %-52s %5.1fs  %s" % (OK if ok else BAD, c, time.time() - t0, "" if ok else msg[:90]))
            if not ok and "timed out" in msg:
                say("       (it did not finish: restarting Klipper so the next command can run)")
                if not (restart_klipper() and wait_ready()):
                    say("  Klipper did not come back. Look at ~/printer_data/logs/klippy.log")
                    sys.exit(1)
            if not ok and "shutdown" in msg.lower():
                say("  Klipper shut down: use FIRMWARE_RESTART, then run smoke again.")
                sys.exit(1)
    run_gcode("M104 S0")
    say("\n%d commands, %d failed. A failure here is a macro that needs something a fake MCU cannot give, or a real problem." % (total, bad))
    sys.exit(1 if bad else 0)


def cmd_gcode(a):
    rc = 0
    for c in a.commands:
        ok, msg = run_gcode(c, timeout=a.timeout)
        say("%s %s%s" % (OK if ok else BAD, c, "" if ok else "   " + msg))
        rc |= (not ok)
    sys.exit(rc)


def cmd_dicts(a):
    extract_dicts(a.out or os.path.join(DEV, "dict"))


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("--version", action="version", version="devbox " + TOOL_VERSION)
    sub = p.add_subparsers(dest="cmd")
    s = sub.add_parser("on"); s.add_argument("--speed", type=float, default=2.0); s.add_argument("--yes", action="store_true"); s.add_argument("--force", action="store_true", help="switch on even though a real printer seems to be connected"); s.set_defaults(f=cmd_on)
    s = sub.add_parser("off"); s.set_defaults(f=cmd_off)
    s = sub.add_parser("status"); s.set_defaults(f=cmd_status)
    s = sub.add_parser("smoke"); s.add_argument("--timeout", type=int, default=180); s.set_defaults(f=cmd_smoke)
    s = sub.add_parser("gcode"); s.add_argument("commands", nargs="+"); s.add_argument("--timeout", type=int, default=180); s.set_defaults(f=cmd_gcode)
    s = sub.add_parser("dicts"); s.add_argument("out", nargs="?"); s.set_defaults(f=cmd_dicts)
    a = p.parse_args()
    if not a.cmd:
        p.print_help()
        return 0
    a.f(a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
