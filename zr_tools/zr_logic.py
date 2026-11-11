# ZR Tools: logic that has no screen code in it, so it can be tested without KlipperScreen/GTK.
# Settings, ACE state, calibration list, collision settings, dryer presets, small helpers.

import configparser
import os

SETTINGS_FILE = os.path.expanduser("~/printer_data/config/zr_screen.conf")
DEFAULTS = {"layout": "tabs", "density": "comfortable", "theme": "dark", "style": "soft"}
LAYOUTS = ("tabs", "grid")          # C (big touch, tabs) and A (card grid)
DENSITIES = ("auto", "compact", "comfortable")
THEMES = ("dark", "light")
STYLES = ("soft", "flat", "bold", "classic")    # the look of cards, chips and colour dots
COMPACT_MAX_WIDTH = 900             # the long side: 800x480 and 480x800 are compact, 1024x600 and 600x1024 are comfortable
TINY_MAX_SHORT = 400                # the short side: 480x320 and 480x272 (3.5 and 4 inch) get the "tiny" layout
WIDE_MIN_LONG = 1200                # the long side: 1280x800 and up (9 to 10 inch) get more columns
SCALE_MIN, SCALE_MAX = 0.75, 1.5    # buttons and text never shrink or grow more than this
REF_SHORT = {"compact": 480, "comfortable": 600}   # the short side the base sizes were made for
COMPACT_MAX_SHORT = 520             # the short side: 480 (5 inch class) is compact, 600 (7 inch 1024x600) is comfortable


def load_settings(path=None):
    """Read the layout settings; anything missing or invalid falls back to the defaults."""
    out = dict(DEFAULTS)
    cp = configparser.ConfigParser()
    try:
        cp.read(path or SETTINGS_FILE)
        sec = cp["screen"] if cp.has_section("screen") else {}
    except (configparser.Error, OSError):
        return out
    for key, allowed in (("layout", LAYOUTS), ("density", DENSITIES), ("theme", THEMES), ("style", STYLES)):
        val = str(sec.get(key, "")).strip().lower() if sec else ""
        if val in allowed:
            out[key] = val
    return out


def save_settings(settings, path=None):
    path = path or SETTINGS_FILE
    cp = configparser.ConfigParser()
    cp["screen"] = {k: settings.get(k, DEFAULTS[k]) for k in DEFAULTS}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write("# Written by ZR Tools (Settings page) and ./installer.sh --screen-layout\n")
        cp.write(f)
    os.replace(tmp, path)


def _px(value):
    """A pixel count, or 0 when the value is missing or not a number."""
    return int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0 else 0


def screen_profile(width, height=None):
    """Orientation and size class of the screen, from its pixels.
    portrait: taller than wide (480x800, 600x1024); landscape otherwise (800x480, 1024x600).
    class: "small" = 800x480 or smaller (a 5 inch, and many 7 inch, screens), "large" = 1024x600 and up."""
    w, h = _px(width), _px(height)
    portrait = bool(w and h and h > w)
    short, long_ = (min(w, h), max(w, h)) if (w and h) else (w, w)
    small = (short <= COMPACT_MAX_SHORT) or (long_ <= COMPACT_MAX_WIDTH)
    known = bool(w and h)
    return {"portrait": portrait, "class": "small" if small else "large", "width": w, "height": h,
            "tiny": bool(known and short <= TINY_MAX_SHORT),
            "wide": bool(known and not portrait and long_ >= WIDE_MIN_LONG)}


def scale_factor(density, width, height=None):
    """How much to grow or shrink buttons and text for the real pixel size: 1.0 at 800x480 (compact) and 1024x600
    (comfortable), smaller below, larger above, within SCALE_MIN..SCALE_MAX. 1.0 when the height is unknown."""
    w, h = _px(width), _px(height)
    if not (w and h):
        return 1.0
    ref = REF_SHORT.get(density, REF_SHORT["compact"])
    return round(max(SCALE_MIN, min(SCALE_MAX, min(w, h) / float(ref))), 2)


def resolve_density(setting, width, height=None):
    if setting in ("compact", "comfortable"):
        return setting
    return "compact" if screen_profile(width, height)["class"] == "small" else "comfortable"


def sizes(density, portrait=False, width=None, height=None):
    """Pixel sizes and column counts used by the views for a density and an orientation."""
    if density == "compact":
        out = {"btn_h": 40, "tile_h": 44, "nav_h": 52, "cols": 2}
    else:
        out = {"btn_h": 54, "tile_h": 60, "nav_h": 64, "cols": 3}
    prof = screen_profile(width, height)
    k = scale_factor(density, width, height)
    for key in ("btn_h", "tile_h", "nav_h"):
        out[key] = int(round(out[key] * k))
    out["scale"] = k
    out["tiny"] = prof["tiny"]
    out["portrait"] = bool(portrait)
    out["tool_cols"] = 2 if portrait else 4        # toolhead cards per row: 2x2 on a tall screen
    out["util_cols"] = 2 if portrait else 3        # calibration tiles per row
    if portrait:
        out["cols"] = 2                            # hub and More tiles
    if prof["wide"] and density == "comfortable":
        out["cols"] = out["util_cols"] = 4        # a 9 to 10 inch screen has room for more tiles per row
    out["dot"] = int(round((56 if (portrait and density == "compact") else 64) * k))   # round colour swatches in the editor
    return out


def short_label(label, portrait, density):
    """Tab and button labels shortened on a narrow (5 inch, tall) screen, where six tabs share 480 px."""
    if portrait and density == "compact":
        return {"Toolheads": "Heads", "Calibrate": "Calib."}.get(label, label)
    return label


# --------------------------------------------------------------------------------------
# ACE Pro (same data model as the Fluidd panel: wm-ultra-fluidd-acepro-panel)
# --------------------------------------------------------------------------------------
DRY_PRESETS = [("PLA", 45, 4), ("PETG", 55, 6), ("ABS/ASA", 65, 6), ("TPU", 50, 6), ("Nylon/PA", 65, 8), ("PVA", 45, 6)]
DRY_MAX_TEMP = 65


def has_ace(objects):
    return objects.get("gcode_macro _WM_ACE") is not None or objects.get("ace") is not None \
        or isinstance(objects.get("ace_instance_0"), dict)


def dry_remaining_text(dryer):
    """ACE Pro reports minutes, ACE 2 seconds (as the Fluidd panel does)."""
    remain = max(0, dryer.get("remain_time") or 0)
    duration = dryer.get("duration") or 0
    if duration > 0:
        total = remain if remain > duration + 1 else remain * 60
    else:
        total = remain * 60 if remain < 1000 else remain
    h, m = int(total // 3600), int((total % 3600) // 60)
    return "%dh %02dm" % (h, m) if h > 0 else "%dm" % m


def ace_state(objects, ntools=4):
    inst = objects.get("ace_instance_0")
    inst = inst if isinstance(inst, dict) else {}
    wm = objects.get("gcode_macro _WM_ACE") or {}
    conn = inst.get("connection_state")
    connected = bool(inst) and (conn is None or conn == "connected")
    dryer = inst.get("dryer_status") or inst.get("dryer") or {"status": "stop"}
    drying = str(dryer.get("status", "stop")) not in ("stop", "stopped", "idle", "unknown")
    slots_raw = inst.get("slots") if isinstance(inst.get("slots"), list) else []
    feed_assist = inst.get("feed_assist_slot")
    slots = []
    for i in range(ntools):
        slot = next((s for s in slots_raw if isinstance(s, dict) and s.get("index") == i), None)
        mode = str(wm.get("mode", "idle"))
        if str(wm.get("tool")) == str(i) and mode.startswith("load"):
            text = "loading"
        elif str(wm.get("tool")) == str(i) and mode.startswith("unload"):
            text = "unloading"
        elif feed_assist == i:
            text = "assist"
        elif slot is None:
            text = "no data"
        elif slot.get("status") == "empty":
            text = "empty"
        elif slot.get("status") == "ready":
            text = "ready"
        else:
            text = str(slot.get("status", "unknown"))
        sw = objects.get("filament_switch_sensor path_%d" % i)
        slots.append({"index": i, "text": text, "empty": slot is not None and slot.get("status") == "empty",
                      "assist": feed_assist == i,
                      "hub": None if sw is None else sw.get("filament_detected") is True})
    return {"connected": connected, "state": conn or ("ACE" if inst else "no data"),
            "model": inst.get("model", "ACE"), "firmware": inst.get("firmware", ""),
            "temp": inst.get("temp"), "humidity": inst.get("humidity"),
            "drying": drying, "dryer": dryer, "dry_left": dry_remaining_text(dryer) if drying else "",
            "max_temp": inst.get("max_dryer_temperature") or DRY_MAX_TEMP, "slots": slots,
            "endless_available": objects.get("gcode_macro WM_ENDLESS_CONTINUE") is not None}


def ace_tool_lines(objects, tool):
    """Up to two short lines about the ACE slot that feeds this tool (tool N = slot N), for the Filament page."""
    if not has_ace(objects):
        return []
    a = ace_state(objects)
    if not a["connected"]:
        return ["ACE: not connected"]
    slot = a["slots"][tool] if 0 <= tool < len(a["slots"]) else None
    first = "ACE slot %d: %s" % (tool + 1, slot["text"] if slot else "no data")
    if slot and slot["assist"]:
        first += " \u00b7 feed assist on"
    elif slot:
        first += " \u00b7 feed assist off"
    second = "ACE %s\u00b0" % ("%.0f" % a["temp"] if isinstance(a["temp"], (int, float)) else "--")
    second += (" \u00b7 drying, %s left" % a["dry_left"]) if a["drying"] else " \u00b7 dryer off"
    return [first, second]


def ace_card_text(objects, tool):
    """Short ACE line for a tool card on the Toolheads page ('' when there is no ACE)."""
    if not has_ace(objects):
        return ""
    a = ace_state(objects)
    if not a["connected"]:
        return "ACE offline"
    slot = a["slots"][tool] if 0 <= tool < len(a["slots"]) else None
    return "ACE %d: %s" % (tool + 1, slot["text"] if slot else "no data")


def ace_bar_text(objects):
    """One line for the top of the Toolheads page ('' when there is no ACE)."""
    if not has_ace(objects):
        return ""
    a = ace_state(objects)
    if not a["connected"]:
        return "ACE: not connected"
    temp = "%.0f\u00b0" % a["temp"] if isinstance(a["temp"], (int, float)) else "--"
    return "ACE %s \u00b7 %s" % (temp, ("drying, %s left" % a["dry_left"]) if a["drying"] else "dryer off")


def endless_enabled(variables):
    try:
        return int(float(variables.get("wm_endless", 0))) == 1
    except (TypeError, ValueError):
        return False


def clamp_dry(temp, hours, max_temp=DRY_MAX_TEMP):
    return max(30, min(int(temp), int(max_temp))), max(1, min(int(hours), 24))


# --------------------------------------------------------------------------------------
# Calibration list: only macros that exist on this printer are offered
# --------------------------------------------------------------------------------------
# (icon, label, gcode, question, requires)  requires: macro name, "klipper:<cmd>" or "object:<name>"
CALIBRATION = [
    ("z-farther", "Z offset (active tool)", "CALIBRATE_TOOL_Z_OFFSET T={tool}", "Calibrate the Z offset of toolhead T{tool}?", "CALIBRATE_TOOL_Z_OFFSET"),
    ("move", "XY offset (active tool)", "CALIBRATE_TOOL_OFFSET T={tool}", "Calibrate the XY offset of toolhead T{tool}?\nThis heats the nozzle.", "CALIBRATE_TOOL_OFFSET"),
    ("fine-tune", "Offsets, all: fine", "CALIBRATE_OFFSET_ALL_FINE_MODE", "Calibrate the offsets of all toolheads (fine mode)?\nThis heats the nozzles.", "CALIBRATE_OFFSET_ALL_FINE_MODE"),
    ("fine-tune", "Offsets, all: rapid", "CALIBRATE_OFFSET_ALL_RAPID_MODE", "Calibrate the offsets of all toolheads (rapid mode)?", "CALIBRATE_OFFSET_ALL_RAPID_MODE"),
    ("move", "Tool position", "CALIBRATE_TOOL_POSITION", "Calibrate the dock position of the active toolhead?", "CALIBRATE_TOOL_POSITION"),
    ("move", "Wipe position", "CALIBRATE_WIPE_POSITION", "Calibrate the wipe position?", "CALIBRATE_WIPE_POSITION"),
    ("bed-mesh", "Bed mesh", "BED_MESH_CALIBRATE", "Run a full bed mesh?", "BED_MESH_CALIBRATE"),
    ("heat-up", "PID: bed (60 C)", "PID_CALIBRATE HEATER=heater_bed TARGET=60", "Tune the bed heater (PID)?\nThe bed heats to 60 C and stays on for several minutes.", "object:heater_bed"),
    ("heat-up", "PID: chamber (45 C)", "PID_CALIBRATE HEATER=chamber TARGET=45", "Tune the chamber heater (PID)?\nIt heats to 45 C and stays on for several minutes.", "object:heater_generic chamber"),
    ("heat-up", "PID: extruder T{tool} (200 C)", "PID_CALIBRATE HEATER={ext} TARGET=200", "Tune the heater of toolhead T{tool} (PID)?\nThe nozzle heats to 200 C.", "object:{ext}"),
    ("settings", "Save config", "SAVE_CONFIG", "Save the pending changes?\nKlipper restarts.", "klipper:SAVE_CONFIG"),
]


def ext_name(tool):
    return "extruder" if tool == 0 else "extruder%d" % tool


def calibration_items(sections, active_tool):
    """Items whose macro or object exists. `sections` = section names of printer.cfg
    (for example "gcode_macro BED_MESH_CALIBRATE", "heater_bed", "heater_generic chamber")."""
    tool = active_tool if active_tool is not None and active_tool >= 0 else 0
    ext = ext_name(tool)
    have = {str(x).strip().upper() for x in sections}
    out = []
    for icon, label, script, question, req in CALIBRATION:
        req = req.format(tool=tool, ext=ext)
        if req.startswith("object:"):
            ok = req[7:].upper() in have
        elif req.startswith("klipper:"):
            ok = True
        else:
            ok = ("GCODE_MACRO " + req).upper() in have
        if ok:
            out.append((icon, label.format(tool=tool), script.format(tool=tool, ext=ext), question.format(tool=tool), req))
    return out


def shaper_available(sections):
    """Input shaper needs the accelerometer (LIS2DW on the tool-changer MCU EX_T) and [resonance_tester]."""
    have = {str(x).strip().lower() for x in sections}
    return "lis2dw" in have and "resonance_tester" in have


def collision_settings(section):
    """Read-only values from the printer config ([collision_detect] has no live status object)."""
    if not section:
        return None
    try:
        get = section.get
    except AttributeError:
        return None
    return {"threshold": get("threshold", None), "action": get("action", "shutdown"),
            "window": get("window_size", None), "sensor": get("sensor", "lis2dw")}


# --------------------------------------------------------------------------------------
# System page helpers
# --------------------------------------------------------------------------------------
def throttled_text(flags):
    """vcgencmd get_throttled value (hex string) -> readable text."""
    try:
        v = int(str(flags).strip(), 16)
    except ValueError:
        return "unknown"
    if v & 0x1:
        return "under-voltage now"
    if v & 0x50000:
        return "had power or heat problems"
    return "ok"


def read_pi_temp(path="/sys/class/thermal/thermal_zone0/temp"):
    try:
        with open(path) as f:
            return int(f.read().strip()) / 1000.0
    except (OSError, ValueError):
        return None


def web_url(hostname, ip):
    return "http://%s.local/" % hostname if hostname else ("http://%s/" % ip if ip else "")


# --------------------------------------------------------------------------------------
# Factory screen board mode (KlipperScreen installed on the WonderMaker screen board)
# --------------------------------------------------------------------------------------
BOARD_DIR = os.path.expanduser("~/wm-screen-backup")
BOARD_MARKER = os.path.join(BOARD_DIR, "board_mode")          # written by scripts/screen_board.sh
BOARD_SCRIPT = "/usr/local/sbin/wm-factory-restore"           # root-owned copy of the script; sudoers allows only this one command


def board_mode(marker=None):
    """True when this KlipperScreen runs on the WonderMaker screen board (the restore button is shown then)."""
    return os.path.exists(marker or BOARD_MARKER)


RESCUE_SCRIPT = "/usr/local/sbin/wm-screen-rescue"             # root-owned; sudoers allows only "wm-screen-rescue open"
RESCUE_UNITS = ("/etc/systemd/system/wm-screen-rescue.service",)


def rescue_available(unit_files=None):
    """True when the rescue tool is installed on this board (the Rescue tile is shown then)."""
    return all(os.path.exists(f) for f in (unit_files or RESCUE_UNITS))


def rescue_command(script=None):
    """Opens the rescue window. KlipperScreen is stopped while it is open (the window has its own screen server)."""
    return ["sudo", "-n", script or RESCUE_SCRIPT, "open"]


def factory_restore_command(script=None):
    """The script re-starts itself under systemd (--detach), because stopping KlipperScreen would otherwise kill it."""
    return ["sudo", "-n", script or BOARD_SCRIPT, "--factory-restore", "--yes", "--detach"]


# ---------------------------------------------------------------------------
# Wi-Fi on the screen board (wpa_supplicant + wpa_cli; no NetworkManager)
# ---------------------------------------------------------------------------
def wifi_parse_scan(text):
    """wpa_cli scan_results -> [{ssid, signal, secured}] strongest first, one entry per name, hidden names dropped."""
    best = {}
    for line in (text or "").splitlines():
        parts = line.split("\t")
        if len(parts) < 5 or parts[0] == "bssid / frequency / signal level / flags / ssid":
            continue
        ssid = parts[4].strip()
        if not ssid or "\\x00" in ssid:
            continue
        try:
            sig = int(parts[2])
        except ValueError:
            continue
        flags = parts[3]
        secured = any(k in flags for k in ("WPA", "WEP", "RSN", "SAE"))
        if ssid not in best or sig > best[ssid]["signal"]:
            best[ssid] = {"ssid": ssid, "signal": sig, "secured": secured}
    return sorted(best.values(), key=lambda n: -n["signal"])


def wifi_signal_bars(dbm):
    return 4 if dbm >= -55 else 3 if dbm >= -65 else 2 if dbm >= -75 else 1


def wifi_parse_status(text):
    """wpa_cli status -> dict (key=value lines)."""
    d = {}
    for line in (text or "").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    return d


def wifi_parse_networks(text):
    """wpa_cli list_networks -> {ssid: id}"""
    out = {}
    for line in (text or "").splitlines()[1:]:
        p = line.split("\t")
        if len(p) >= 2 and p[0].isdigit():
            out[p[1]] = int(p[0])
    return out


def wifi_password_ok(pw):
    return 8 <= len(pw) <= 63


# ---------------------------------------------------------------------------
# Pi address on the screen board (KlipperScreen.conf: moonraker_host)
# ---------------------------------------------------------------------------
import re as _re


def valid_host(host):
    return bool(_re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$", host or ""))


def replace_moonraker_host(text, host):
    """Return the config text with every moonraker_host line set to host (None if there is none)."""
    new, n = _re.subn(r"(?m)^(moonraker_host\s*[:=]).*$", lambda m: "%s %s" % (m.group(1), host), text)
    return new if n else None


def read_moonraker_host(text):
    m = _re.search(r"(?m)^moonraker_host\s*[:=]\s*(\S+)", text or "")
    return m.group(1) if m else ""


KS_CONF = os.path.expanduser("~/printer_data/config/KlipperScreen.conf")
LOCAL_HOSTS = ("", "localhost", "127.0.0.1", "::1")


def fluidd_url(hostname="", ip="", conf=None):
    """Where Fluidd is: the Pi address entered in KlipperScreen.conf (moonraker_host) when it is a real address,
    otherwise this machine's own name or address (KlipperScreen running on the Pi itself)."""
    try:
        with open(conf or KS_CONF) as f:
            host = read_moonraker_host(f.read())
    except OSError:
        host = ""
    if host not in LOCAL_HOSTS:
        return "http://%s/" % host
    return web_url(hostname, ip)


# ---------------------------------------------------------------------------
# Looks (style x theme): plain GTK3 CSS, built here so it can be tested
# ---------------------------------------------------------------------------
_STYLE_TOKENS = {
    # radius, border width, accent, accent text, font scale
    "soft": {"radius": 14, "bw": 1, "accent": "#2f7bf6", "on_text": "#ffffff", "font": "100%"},
    "flat": {"radius": 6, "bw": 0, "accent": "#14b8a6", "on_text": "#ffffff", "font": "100%"},
    "bold": {"radius": 10, "bw": 3, "accent": "#ff9800", "on_text": "#000000", "font": "110%"},
    "classic": {"radius": 10, "bw": 2, "accent": "#2e7d32", "on_text": "#ffffff", "font": "100%"},
}


def build_css(theme, style, density="compact", scale=1.0):
    """Design A: tall rounded cards, status chips, a rounded tab bar, big action buttons. Plain GTK3 CSS."""
    t = _STYLE_TOKENS.get(style) or _STYLE_TOKENS["soft"]
    big = density == "comfortable"
    k = scale if isinstance(scale, (int, float)) and scale > 0 else 1.0
    light = theme == "light"
    if light:
        bg, card, card_on, edge, small, hint = "#eef1f4", "#ffffff", "#e4eefc", "#cfd6de", "#44505c", "#66727e"
        text = "#14181c"
        ready = ("#d6f3e0", "#17703d"); active = ("#d9e6fd", "#1b4fb3"); empty = ("#fdebd0", "#a15c00")
        dot_edge = "#44505c"
    else:
        bg, card, card_on, edge, small, hint = "#11161b", "#1b232b", "#18222f", "#2a343e", "#b4bec8", "#8a96a2"
        text = "#e8edf2"
        ready = ("#173b25", "#6fe39a"); active = ("#16325f", "#8db8ff"); empty = ("#4a3212", "#ffb74d")
        dot_edge = "#ffffff"
    acc = t["accent"]
    r = t["radius"] if style != "soft" else 14
    return """
    .zr_card { border: 2px solid %(edge)s; border-radius: %(r)dpx; background-image: none; background-color: %(card)s; color: %(text)s; }
    .zr_active { border: 2px solid %(acc)s; background-color: %(card_on)s; }
    .zr_swatch { border: 2px solid %(dot_edge)s; border-radius: %(sr)dpx; }
    .zr_dot { border: 2px solid %(edge)s; border-radius: 32px; }
    .zr_dot_on { border: 5px solid %(acc)s; }
    .zr_chip { border-radius: %(r)dpx; background-image: none; background-color: %(card)s; color: %(text)s; border: 2px solid %(edge)s; }
    .zr_chip_on { background-color: %(acc)s; color: #ffffff; border-color: %(acc)s; }
    .zr_pill { border-radius: 14px; padding: 2px 10px; font-weight: bold; font-size: %(pill)s; background-color: %(card)s; color: %(small)s; }
    .zr_pill_ready { background-color: %(ready_bg)s; color: %(ready_fg)s; }
    .zr_pill_active { background-color: %(active_bg)s; color: %(active_fg)s; }
    .zr_pill_empty { background-color: %(empty_bg)s; color: %(empty_fg)s; }
    .zr_pill_info { background-color: %(card)s; color: %(text)s; border: 1px solid %(edge)s; }
    .zr_title { font-weight: bold; font-size: %(title)s; }
    .zr_mat { font-weight: bold; font-size: %(mat)s; }
    .zr_btn, .zr_tab { border-radius: %(r)dpx; background-image: none; background-color: %(card)s; color: %(text)s; border: 1px solid %(edge)s; box-shadow: none; text-shadow: none; }
    .zr_btn_primary { background-color: %(acc)s; border-color: %(acc)s; color: #ffffff; }
    .zr_btn_green { background-color: #2e9d57; border-color: #2e9d57; color: #ffffff; }
    .zr_btn_orange { background-color: #d9822b; border-color: #d9822b; color: #ffffff; }
    .zr_btn_purple { background-color: #7b4fd0; border-color: #7b4fd0; color: #ffffff; }
    .zr_arrow { background-color: #27323c; border-color: #3b4955; color: #ffffff; font-weight: bold; padding: 0; }
    .zr_arrow label { font-size: 125%%; font-weight: bold; }
    .zr_btn_cyan { background-color: #17a2b8; border-color: #17a2b8; color: #ffffff; }
    .zr_btn_red { background-color: #c0392b; border-color: #c0392b; color: #ffffff; }
    .zr_selected { background-image: none; background-color: %(acc)s; border-color: %(acc)s; color: #ffffff; }
    .zr_section { font-weight: bold; padding-top: 6px; }
    .zr_small { font-size: %(small_pct)s; color: %(small)s; }
    .zr_value { font-weight: bold; font-size: %(value)s; }
    .zr_value_dim { font-weight: bold; font-size: %(value_dim)s; color: %(small)s; }
    .zr_hint { font-size: %(small_pct)s; color: %(hint)s; }
    scrollbar.vertical { min-width: 18px; }
    scrollbar slider { min-width: 14px; min-height: 40px; border-radius: 8px; background-color: %(edge)s; }
    """ % {"edge": edge, "r": r, "sr": max(r // 2, 4), "card": card, "card_on": card_on, "acc": acc, "text": text,
           "small": small, "hint": hint, "dot_edge": dot_edge,
           "ready_bg": ready[0], "ready_fg": ready[1], "active_bg": active[0], "active_fg": active[1],
           "empty_bg": empty[0], "empty_fg": empty[1],
           "pill": "%d%%" % round((100 if big else 85) * k), "title": "%d%%" % round((120 if big else 100) * k),
           "mat": "%d%%" % round((130 if big else 110) * k),
           "value": "%d%%" % round((330 if big else 290) * k), "value_dim": "%d%%" % round((230 if big else 200) * k), "small_pct": "%d%%" % round(85 * k)}


# ---------------------------------------------------------------------
# Filament colour / material shared with the Fluidd panel and the factory touchscreen.
# All three read and write the [slot] section of tmt1.ini (colourN / materialN are list indices).
# The lists below are the touchscreen's own, same order as the Fluidd panel.
# ---------------------------------------------------------------------
TOUCH_PALETTE = [
    ("White", 0xFFFFFF), ("Beige", 0xF3E8C8), ("Brown", 0x9A6738), ("Grey", 0xC7D5DF), ("Black", 0x000000),
    ("Cyan", 0x00DDE3), ("Light blue", 0x13A7E8), ("Dark blue", 0x0B4BD8), ("Light green", 0x16E900),
    ("Dark green", 0x00A84F), ("Yellow", 0xFFF200), ("Orange", 0xFF5A1F), ("Light pink", 0xDDBFDE),
    ("Magenta", 0xE72DBE), ("Red", 0xFF1C2E), ("Bright blue", 0x006EFF), ("Gold", 0xD9A520),
    ("Copper", 0xB86B44), ("Silver", 0xAFC0CC), ("Multicolour", 0xC060C0), ("Clear", 0xD5E8EE),
]
# touchscreen material list: (name, temperature, index in the ZR Tools material list)
TOUCH_MATERIALS = [
    ("PLA", 210, 1), ("PLA Silk", 215, 3), ("ABS", 250, 8), ("PETG", 240, 6), ("PLA Matte", 210, 4),
    ("PLA Metal", 215, 15), ("ABS Matte", 250, 8), ("PETG Matte", 240, 6), ("PVA", 200, 13), ("TPE", 225, 10),
    ("Marble", 210, 15), ("HIPS", 235, 14), ("TPU", 225, 10), ("PET", 240, 15), ("Wood", 200, 15), ("ASA", 255, 9),
]


def nearest_palette(color_int):
    """Index of the touchscreen swatch closest to an 0xRRGGBB colour."""
    r, g, b = (color_int >> 16) & 255, (color_int >> 8) & 255, color_int & 255
    best, dist = 0, None
    for i, (_n, c) in enumerate(TOUCH_PALETTE):
        cr, cg, cb = (c >> 16) & 255, (c >> 8) & 255, c & 255
        rm = (r + cr) / 2.0
        d = (2 + rm / 256) * (r - cr) ** 2 + 4 * (g - cg) ** 2 + (2 + (255 - rm) / 256) * (b - cb) ** 2
        if dist is None or d < dist:
            best, dist = i, d
    return best


def parse_tmt1_slots(text, ntools=4):
    """[{'color': palette index or None, 'material': index or None}] from the [slot] section of tmt1.ini."""
    slots = [{"color": None, "material": None} for _ in range(ntools)]
    section = ""
    for raw in (text or "").splitlines():
        line = raw.strip()
        m = _re.match(r"^\[(.+)\]$", line)
        if m:
            section = m.group(1).strip().lower()
            continue
        if section != "slot":
            continue
        m = _re.match(r"^(color|material)(\d+)\s*=\s*(-?\d+)\s*$", line, _re.I)
        if not m or int(m.group(2)) >= ntools:
            continue
        key, idx, val = m.group(1).lower(), int(m.group(2)), int(m.group(3))
        limit = len(TOUCH_PALETTE) if key == "color" else len(TOUCH_MATERIALS)
        slots[idx][key] = val if 0 <= val < limit else None
    return slots


def update_tmt1_slot(text, index, color, material):
    """tmt1.ini text with one slot changed; every other line stays as it was."""
    eol = "\r\n" if "\r\n" in text else "\n"
    lines = text.splitlines()
    section, slot_end, done_c, done_m = "", -1, False, False
    for i, raw in enumerate(lines):
        line = raw.strip()
        m = _re.match(r"^\[(.+)\]$", line)
        if m:
            if section == "slot":
                slot_end = i
            section = m.group(1).strip().lower()
            continue
        if section != "slot":
            continue
        if _re.match(r"^color%d\s*=" % index, line, _re.I):
            lines[i], done_c = "color%d=%d" % (index, color), True
        elif _re.match(r"^material%d\s*=" % index, line, _re.I):
            lines[i], done_m = "material%d=%d" % (index, material), True
    if not (done_c and done_m):
        extra = []
        if not done_c:
            extra.append("color%d=%d" % (index, color))
        if not done_m:
            extra.append("material%d=%d" % (index, material))
        if section == "slot" and slot_end < 0:
            at = len(lines)
        elif slot_end >= 0:
            at = slot_end
        else:
            lines += ["", "[slot]"]
            at = len(lines)
        while at > 0 and lines[at - 1].strip() == "":
            at -= 1
        lines[at:at] = extra
    return eol.join(lines) + (eol if text.endswith(("\n", "\r")) else "")
