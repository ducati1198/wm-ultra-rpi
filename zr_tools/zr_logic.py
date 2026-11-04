# ZR Tools: logic that has no screen code in it, so it can be tested without KlipperScreen/GTK.
# Settings, ACE state, calibration list, collision settings, dryer presets, small helpers.

import configparser
import os

SETTINGS_FILE = os.path.expanduser("~/printer_data/config/zr_screen.conf")
DEFAULTS = {"layout": "tabs", "density": "auto", "theme": "dark", "style": "soft"}
LAYOUTS = ("tabs", "grid")          # C (big touch, tabs) and A (card grid)
DENSITIES = ("auto", "compact", "comfortable")
THEMES = ("dark", "light")
STYLES = ("soft", "flat", "bold", "classic")    # the look of cards, chips and colour dots
COMPACT_MAX_WIDTH = 900             # 800x480 (5 inch) is compact, 1024x600 (7 inch) is comfortable


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


def resolve_density(setting, width):
    if setting in ("compact", "comfortable"):
        return setting
    return "compact" if (width or 0) <= COMPACT_MAX_WIDTH else "comfortable"


def sizes(density):
    """Pixel sizes used by the views for a density."""
    if density == "compact":
        return {"btn_h": 40, "tile_h": 44, "nav_h": 52, "cols": 2}
    return {"btn_h": 54, "tile_h": 60, "nav_h": 64, "cols": 3}


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


# ---------------------------------------------------------------------------
# Looks (style x theme): plain GTK3 CSS, built here so it can be tested
# ---------------------------------------------------------------------------
_STYLE_TOKENS = {
    # radius, border width, accent, accent text, font scale
    "soft": {"radius": 16, "bw": 1, "accent": "#3b82f6", "on_text": "#ffffff", "font": "100%"},
    "flat": {"radius": 6, "bw": 0, "accent": "#14b8a6", "on_text": "#ffffff", "font": "100%"},
    "bold": {"radius": 10, "bw": 3, "accent": "#ff9800", "on_text": "#000000", "font": "110%"},
    "classic": {"radius": 10, "bw": 2, "accent": "#2e7d32", "on_text": "#ffffff", "font": "100%"},
}


def build_css(theme, style):
    t = _STYLE_TOKENS.get(style) or _STYLE_TOKENS["soft"]
    light = theme == "light"
    if light:
        card_bg, edge, small, hint, chip_bg, track = "rgba(0,0,0,0.06)", "rgba(0,0,0,0.30)", "#444444", "#666666", "rgba(0,0,0,0.08)", "rgba(0,0,0,0.35)"
        dot_edge = "#444444"
    else:
        card_bg, edge, small, hint, chip_bg, track = "rgba(255,255,255,0.07)", "rgba(255,255,255,0.28)", "#c4c4c4", "#9a9a9a", "rgba(255,255,255,0.10)", "rgba(255,255,255,0.45)"
        dot_edge = "#ffffff"
    if style == "classic":
        card_bg = "rgba(255,255,255,0.04)" if not light else "rgba(0,0,0,0.05)"
        edge = "#9a9a9a" if light else "#555555"
    bw = t["bw"]
    return """
    .zr_card { border: %(bw)dpx solid %(edge)s; border-radius: %(r)dpx; background-color: %(card_bg)s; }
    .zr_active { border: 3px solid #4CAF50; }
    .zr_swatch { border: 2px solid %(dot_edge)s; border-radius: %(sr)dpx; }
    .zr_dot { border: 2px solid %(edge)s; border-radius: 28px; }
    .zr_dot_on { border: 5px solid %(accent)s; }
    .zr_chip { border-radius: %(r)dpx; background-image: none; background-color: %(chip_bg)s; border: %(bw)dpx solid %(edge)s; font-size: %(font)s; }
    .zr_chip_on { background-color: %(accent)s; color: %(on_text)s; border-color: %(accent)s; }
    .zr_section { font-size: %(font)s; padding-top: 6px; }
    .zr_small { font-size: 85%%; color: %(small)s; }
    .zr_hint { font-size: 85%%; color: %(hint)s; }
    .zr_selected { background-image: none; background-color: %(accent)s; color: %(on_text)s; }
    scrollbar.vertical { min-width: 18px; }
    scrollbar slider { min-width: 14px; min-height: 40px; border-radius: 8px; background-color: %(track)s; }
    """ % {"bw": bw, "edge": edge, "r": t["radius"], "sr": max(t["radius"] // 2, 4), "card_bg": card_bg, "accent": t["accent"],
           "on_text": t["on_text"], "font": t["font"], "small": small, "hint": hint, "chip_bg": chip_bg,
           "track": track, "dot_edge": dot_edge}
