#!/usr/bin/env python3
"""wm_release.py - PRIVATE tool: bring a new WonderMaker System release (for example 1.1.14) to this Pi.

Not part of any installer (folder tools/wm-release of the repo).
Everything is read-only unless you run `apply --apply` (and type APPLY), `rollback`, or `flash --run` (and type FLASH).

  (no command) / menu          a numbered menu that runs the steps below; option 1 does all the steps
  all [--source board|web]     every needed step, in order; asks first: old screen board, or WonderMaker's website
  check                        ask WonderMaker's firmware page for the newest published version (downloads nothing)
  status                       what is recorded: baseline, fetched releases, log
  pid-cfg [--fix]              check where the PID settings of the hotends, bed and chamber heater live (SAVE_CONFIG must be able to store a PID result); --fix moves them into printer.cfg
  init-baseline --from-board  record the board as it is NOW (the version before the new one); also --from-dir DIR or --src DIR (repo factory copy)
  promote VERSION              make a fetched release the baseline for the next one
  fetch --from-board [HOST]    copy the updated files from the WonderMaker screen board over SSH (read only)
  fetch --from-dir DIR         same, from a folder that has klipper/, moonraker/, printer_data/config/, mcu_update/, TM_T1/scripts/
  fetch --from-soc FILE        decrypt a WonderMaker TM_T1_SOC file on the Pi and use it as the new version (no board needed)
  fetch --from-web [VERSION]   download the SOC straight from WonderMaker's firmware page (newest, or a given version), then decrypt it here
  init-baseline --from-soc FILE  record a TM_T1_SOC file as the baseline (the version before the new one)
  fetch --from-archive VER     reinstall/downgrade from a SOC zip kept in the firmware archive (offline)
  firmware                     list the SOC zips kept in the firmware archive (~/wm-firmware)
  diff VERSION                 baseline <-> release <-> your live files; saves a report
  compare OLD NEW              what WonderMaker changed between two fetched releases (read only)
  mcu ZIP_OR_DIR               check MCU firmware (versions, md5), print the flashing steps; never flashes
  flash [main|thr|ext|hub|cell] [--run]  flash ~/mcu_update firmware - dry run unless --run, then you type FLASH
  settings                     show/change the decrypt key, firmware page URL and board address
  apply VERSION [--apply]      plan only; with --apply: backup, then apply after you type APPLY
  rollback [BACKUP]            put back the files from the backup made by apply
  checklist VERSION            test list for after the update
  notes VERSION [--add TEXT]   your own notes for this release
  log                          history of what was done
Version: see --version.  Data folder: $WMR_HOME (default ~/wm-private-data).  Live files: $WMR_LIVE_HOME (default ~).
"""
import argparse, atexit, getpass, hashlib, io, json, os, re, shutil, subprocess, sys, tarfile, tempfile, time, urllib.request, urllib.parse, zipfile

TOOL_VERSION = "1.6.0"   # this tool's own version (not the installer's VERSION file); see README "Version history"
HOME = os.path.expanduser("~")
DATA = os.environ.get("WMR_HOME", os.path.join(HOME, "wm-private-data"))
LIVE = os.environ.get("WMR_LIVE_HOME", HOME)
MOONRAKER = os.environ.get("WMR_MOONRAKER", "http://127.0.0.1:7125")
BOARD_KEY = os.environ.get("WMR_BOARD_KEY", "")
# WonderMaker's firmware page; the newest tm_t1_soc(x.y.z).zip link on it is the newest published System version
DEFAULT_WIKI_URL = "https://wiki.wondermaker3d.com/en/ZR-Ultra-S/Standard-Operating-Procedures/Fireware-Download"
# live-relative roots that belong to the WonderMaker release, and the folder names in this repo's factory/ultra-s
ROOTS = ["klipper", "moonraker", "printer_data/config", "mcu_update", "TM_T1/scripts"]
REPO_MAP = {"klipper": "klipper", "moonraker": "moonraker", "printer_data/config": "config", "mcu_update": "mcu", "TM_T1/scripts": "scripts"}
# never changed by apply: your own data or files that hold your includes / SAVE_CONFIG block
PROTECTED = {"printer_data/config/printer.cfg", "printer_data/config/saved_variables.cfg", "printer_data/config/tmt1.ini"}
SKIP_DIRS = {".git", "__pycache__", ".pytest_cache"}
SKIP_SUFFIX = (".pyc", ".log")
SKIP_GLOBS = ("plr*.ini*", "client_log.txt", "*.zrbak_*", "*.bkp", "*.wm-*.new", "*.wm-before-*")   # runtime data and leftovers, never compared
# Compared by checksum only (nothing is copied, nothing is ever applied): (folder, find filter)
# Folders under the home folder, then absolute system folders written without the leading slash.
REPORT_ROOTS = [("TM_T1/bin", ""), ("TM_T1/other", ""), ("TM_T1/access", ""), ("moonraker-timelapse", ""), ("fluidd-config", ""), ("crowsnest", ""),
                ("fluidd", ""), ("access", ""), ("etc/systemd/system", "-maxdepth 1 -name '*.service'"), ("etc/nginx/conf.d", ""),
                ("etc/nginx/sites-enabled", ""), ("etc/udev/rules.d", "-maxdepth 1 -name '*wm*.rules'")]
ENVS = ("klippy-env", "moonraker-env")   # their pip freeze is compared too
TEXT_SUFFIX = (".cfg", ".conf", ".py", ".sh", ".txt", ".ini", ".json", ".md", ".service", ".gcode", ".yml", ".yaml")
MCU_BIN = {"MCU": "klipper.bin", "THR": "klipper_THR.bin", "EXT": "klipper_EXT.bin", "HUB": "klipper_HUB.bin", "CELL": "klipper_CELL.bin"}
MCU_SCRIPT = {"MCU": "mcu_update.sh", "THR": "mcu_update_THRs.sh", "EXT": "mcu_update_EXT.sh", "HUB": "mcu_update_HUB.sh", "CELL": "mcu_update_CELL.sh"}


import fnmatch
def now(): return time.strftime("%Y%m%d-%H%M%S")
def vkey(v): return tuple(int(x) for x in re.findall(r"\d+", v))
def skipped(name): return name.endswith(SKIP_SUFFIX) or any(fnmatch.fnmatch(name, g) for g in SKIP_GLOBS) or os.path.basename(name) in _rpi_names()
def say(*a): print(*a, flush=True)
def die(msg, fix=""):
    say("ERROR: " + msg + ("\n  What to do: " + fix if fix else "")); sys.exit(1)
def p(*a): return os.path.join(*a)
def ensure(d): os.makedirs(d, exist_ok=True); return d
def _repo_factory_dir():
    """find factory/ultra-s in the repo, however deep this script sits"""
    d = os.path.dirname(os.path.abspath(__file__))
    for _ in range(6):
        if os.path.isdir(p(d, "factory", "ultra-s")): return p(d, "factory", "ultra-s")
        d = os.path.dirname(d)
    return p(os.path.dirname(os.path.abspath(__file__)), "..", "..", "factory", "ultra-s")


def _repo_rpi_cfg_dir():
    """the repo's rpi-cfg/ folder (the Pi's own config files, such as wm_calibration.cfg), or None when the tool runs outside the repo"""
    d = os.path.dirname(os.path.abspath(__file__))
    for _ in range(6):
        if os.path.isdir(p(d, "rpi-cfg")): return p(d, "rpi-cfg")
        d = os.path.dirname(d)
    return None


_RPI_NAMES = None
def _rpi_names():
    global _RPI_NAMES
    if _RPI_NAMES is None: _RPI_NAMES = set(rpi_cfg_files())
    return _RPI_NAMES


def rpi_cfg_files():
    """names of the Pi's own config files. They are not WonderMaker's, so no release contains them and apply never changes them"""
    d = _repo_rpi_cfg_dir()
    names = sorted(x for x in os.listdir(d) if x.endswith(".cfg")) if d else []
    return names or ["wm_calibration.cfg"]


# a release that ships a file with one of these names must not replace the Pi's own copy
PROTECTED = PROTECTED | {"printer_data/config/" + _n for _n in rpi_cfg_files()}


def rpi_cfg_state():
    """[(name, 'ok' | what is wrong)] for each of the Pi's own config files in the live config folder"""
    cfgd = p(LIVE, "printer_data", "config"); d = _repo_rpi_cfg_dir(); out = []
    try: pc = open(p(cfgd, "printer.cfg"), errors="replace").read()
    except OSError: pc = ""
    for n in rpi_cfg_files():
        live = p(cfgd, n)
        if not os.path.isfile(live): st = "missing (run ./installer.sh --rpi-cfg)"
        elif not re.search(r"^\s*\[include\s+%s\s*\]" % re.escape(n), pc, re.M): st = "not included in printer.cfg (run ./installer.sh --rpi-cfg)"
        elif d and os.path.isfile(p(d, n)) and not same_text(live, p(d, n)): st = "differs from the copy in rpi-cfg (edited, or older; ./installer.sh --rpi-cfg replaces it and keeps yours)"
        else: st = "ok"
        out.append((n, st))
    return out


def _pidcfg_script():
    """the repo's scripts/wm_pidcfg.py (checks where the PID settings live), or None when the tool runs outside the repo"""
    d = os.path.dirname(os.path.abspath(__file__))
    for _ in range(6):
        if os.path.isfile(p(d, "scripts", "wm_pidcfg.py")): return p(d, "scripts", "wm_pidcfg.py")
        d = os.path.dirname(d)
    return None


def pid_cfg_run(fix=False):
    """(exit code, output lines) of scripts/wm_pidcfg.py check|fix on the live config folder; exit code None = cannot run"""
    sc = _pidcfg_script(); cfgd = p(LIVE, "printer_data", "config")
    if not sc: return None, ["scripts/wm_pidcfg.py not found (run the tool from the wm-ultra-rpi repository)"]
    if not os.path.isfile(p(cfgd, "printer.cfg")): return None, ["no printer.cfg in " + cfgd]
    cmd = [sys.executable, sc, "fix" if fix else "check", cfgd] + ([now()] if fix else [])
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    return r.returncode, [l for l in r.stdout.splitlines() if l.strip()]


def pid_cfg_release_conflicts(release_cfgs):
    """a release file that sets control / pid_* for a heater would bring the SAVE_CONFIG conflict back once applied.
    release_cfgs: {file name: path}; main printer.cfg is skipped (SAVE_CONFIG handles that one)"""
    out = []
    for n, path in sorted(release_cfgs.items()):
        if n == "printer.cfg" or not is_text(path): continue
        sec = None
        for line in open(path, errors="replace").read().splitlines():
            m = re.match(r"^\[(.+?)\]", line)
            if m: sec = m.group(1).strip(); continue
            if sec and re.match(r"^(extruder\d*|heater_bed|heater_generic .+)$", sec) and re.match(r"^(control|pid_k[pid])\s*[:=]", line, re.I):
                out.append("  %-18s [%s] sets %s" % (n, sec, re.split(r"[:=]", line)[0].strip())); 
    return out


def rpi_cfg_clash(release_cfgs):
    """macro names that a WonderMaker release defines and the Pi's own files define too: the later include would win in Klipper.
    release_cfgs: {file name: path} of the release's .cfg files"""
    d = _repo_rpi_cfg_dir(); mine = {}
    for n in rpi_cfg_files():
        for cand in (p(LIVE, "printer_data", "config", n), p(d, n) if d else ""):
            if cand and os.path.isfile(cand): mine[n] = cand; break
    own = macros_of(mine); theirs = macros_of(release_cfgs)
    return ["  %-28s defined by the release in %s and by your %s" % (m, ", ".join(sorted(theirs[m])), ", ".join(sorted(own[m])))
            for m in sorted(set(own) & set(theirs))]


def sha(path):
    if os.path.islink(path): return "link:" + os.readlink(path)
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()


def listing(root):
    """relative path -> absolute path, without .git, caches and logs"""
    out = {}
    if not os.path.isdir(root): return out
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
        for f in files:
            if skipped(f): continue
            a = p(d, f); out[os.path.relpath(a, root)] = a
    return out


def is_text(path):
    if path.endswith(TEXT_SUFFIX): return True
    try:
        with open(path, "rb") as f: return b"\0" not in f.read(8192)
    except OSError: return False


def read(path):
    with open(path, "rb") as f: return f.read()


def copy_file(src, dst):
    ensure(os.path.dirname(dst))
    if os.path.lexists(dst) and not os.path.isdir(dst): os.remove(dst)
    if os.path.islink(src): os.symlink(os.readlink(src), dst)
    else: shutil.copy2(src, dst)


def copy_tree(src, dst):
    n = 0
    for rel, a in listing(src).items(): copy_file(a, p(dst, rel)); n += 1
    return n


# ---------------------------------------------------------------- baseline and releases
def baseline_dir(for_ver=None):
    """the newest baseline that is OLDER than the release being compared (the version before it)"""
    d = p(DATA, "baseline")
    if not os.path.isdir(d): return None, None
    vs = sorted((x for x in os.listdir(d) if os.path.isdir(p(d, x)) and re.match(r"^\d+(\.\d+)+$", x)), key=vkey)
    if for_ver: vs = [x for x in vs if vkey(x) < vkey(for_ver)]
    return (vs[-1], p(d, vs[-1])) if vs else (None, None)


def board_version(text):
    v = re.findall(r"System_(\d+\.\d+\.\d+)", text)
    return v[-1] if v else None


def live_version():
    """the System version this machine says it has: ~/iso_version.txt (System_x.y.z), or None"""
    try: return board_version(open(p(LIVE, "iso_version.txt")).read())
    except OSError: return None


def write_live_version(ver):
    """record a System version the way the factory image does: keep the file's header and history, add one line
    '<date time>: Add System_x.y.z' (the newest System_ line is the version in use)"""
    path = p(LIVE, "iso_version.txt")
    try: old = open(path).read()
    except OSError: old = ""
    if old and not old.endswith("\n"): old += "\n"
    with open(path, "w") as f: f.write(old + "%s: Add System_%s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), ver))


BOARD = {"host": None, "user": None, "dir": None, "sock": None}   # one SSH connection to the board, reused by every step


def board_close():
    if BOARD["sock"]:
        subprocess.run(["ssh", "-S", BOARD["sock"], "-O", "exit", "x"], capture_output=True, stdin=subprocess.DEVNULL)
    if BOARD["dir"]: shutil.rmtree(BOARD["dir"], ignore_errors=True)
    BOARD.update(host=None, user=None, dir=None, sock=None)


def _master(sock, user, host, env=None, batch=True):
    cmd = ["ssh", "-fN", "-M", "-S", sock, "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new",
           "-o", "BatchMode=yes" if batch else "BatchMode=no"]
    if batch and BOARD_KEY: cmd += ["-i", BOARD_KEY]
    if not batch: cmd += ["-o", "NumberOfPasswordPrompts=1", "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive"]
    return subprocess.run(cmd + ["%s@%s" % (user, host)], capture_output=True, text=True, stdin=subprocess.DEVNULL, env=env)


def board_open(host):
    """Connect once. First without a password (a key or an ssh agent); if that fails, ask for the board's user and password.
    The password is typed hidden, lives only in this process, is handed to ssh through a one-shot helper (never on a command line), and is never saved."""
    if BOARD["host"] == host and BOARD["sock"]: return
    board_close()
    d = tempfile.mkdtemp(prefix="wmr-"); sock = p(d, "cm"); atexit.register(board_close)
    user = os.environ.get("WMR_BOARD_USER") or conf_get("board_user") or "t13dp"
    r = _master(sock, user, host)
    tries = 0
    while r.returncode != 0 and tries < 3:
        if tries == 0:
            say("  The board %s wants a login." % host)
            if not os.environ.get("WMR_BOARD_USER"): user = ask("Board user name", user)
        pw = getpass.getpass("  Password for %s@%s (typed hidden, not saved): " % (user, host))
        helper = p(d, "askpass.sh")
        with open(helper, "w") as f: f.write('#!/bin/sh\nprintf "%s\\n" "$WMR_ASKPASS_PW"\n')
        os.chmod(helper, 0o700)
        env = dict(os.environ, SSH_ASKPASS=helper, SSH_ASKPASS_REQUIRE="force", WMR_ASKPASS_PW=pw)
        env.setdefault("DISPLAY", "wmr-none")
        r = _master(sock, user, host, env=env, batch=False)
        os.remove(helper); del pw, env
        tries += 1
        if r.returncode != 0: say("  Login failed (%s)." % (r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "wrong user or password"))
    if r.returncode != 0:
        shutil.rmtree(d, ignore_errors=True)
        die("could not log in to the board %s." % host, "check the address, user name and password; the board must allow SSH password login")
    BOARD.update(host=host, user=user, dir=d, sock=sock)
    if conf_get("board_user") != user: conf_set("board_user", user)


def ssh_base(host):
    board_open(host)
    return ["ssh", "-S", BOARD["sock"], "-o", "BatchMode=yes", "%s@%s" % (BOARD["user"], host)]


def conf_get(k, d=""):
    try: return json.load(open(p(DATA, "config.json"))).get(k, d)
    except (OSError, ValueError): return d


def conf_set(k, v):
    try: c = json.load(open(p(DATA, "config.json")))
    except (OSError, ValueError): c = {}
    c[k] = v; ensure(DATA); json.dump(c, open(p(DATA, "config.json"), "w"))


# settings resolve env -> saved config -> built-in default (so the settings screen can change them)
def soc_key():  return os.environ.get("WMR_SOC_KEY") or conf_get("soc_key") or DEFAULT_SOC_KEY
def wiki_url(): return os.environ.get("WMR_WIKI_URL") or conf_get("wiki_url") or DEFAULT_WIKI_URL
ARCHIVE = os.environ.get("WMR_FIRMWARE_DIR", p(HOME, "wm-firmware"))   # kept copies of downloaded SOC zips


def board_host(h, may_ask=False):
    h = h or os.environ.get("WMR_BOARD_HOST", "") or conf_get("board_host")
    if not h and may_ask:
        h = ask("Board address (the WonderMaker screen board's IP)")
        if h: conf_set("board_host", h)
    if not h: die("which board?", "give its address: --from-board 192.168.x.x  (or set WMR_BOARD_HOST, or press s in the menu)")
    return h


def local_manifest(base):
    """checksums of the report-only roots in a folder laid out like the home folder (etc/... for system files)"""
    m = {}
    for rel, flt in REPORT_ROOTS:
        for r, a in listing(p(base, rel)).items():
            if "-maxdepth 1" in flt and os.sep in r: continue
            pat = re.findall(r"-name '([^']+)'", flt)
            if pat and not fnmatch.fnmatch(os.path.basename(r), pat[0]): continue
            m[p(rel, r)] = sha(a)
    return m


def remote_manifest(host):
    m = {}
    for rel, flt in REPORT_ROOTS:
        where = "/" + rel if rel.startswith("etc/") else rel
        pre = "cd ~ && " if not rel.startswith("etc/") else ""
        ex = " ".join("! -name '%s'" % g for g in SKIP_GLOBS) + " ! -name '*.pyc' ! -name '*.log'"
        r = subprocess.run(ssh_base(host) + ["%sfind %s %s -type f %s -exec sha256sum {} + 2>/dev/null" % (pre, where, flt, ex)], capture_output=True, text=True)
        for line in r.stdout.splitlines():
            h, _, path = line.partition("  ")
            if h and path: m[path.lstrip("/")] = h
    return m


def env_freeze_local(base):
    out = {}
    for e in ENVS:
        f = p(base, "_meta", e + ".txt")
        if os.path.isfile(f): out[e] = open(f).read()
    return out


def snapshot(dst, host=None, src_dir=None, version=None):
    """copy the printer's own files and note checksums of everything else; read-only on the source"""
    n = 0
    if src_dir:
        base = os.path.abspath(src_dir)
        if not os.path.isdir(base): die("no such folder: " + base)
        vtxt = p(base, "iso_version.txt")
        ver = version or (board_version(open(vtxt).read()) if os.path.isfile(vtxt) else None)
        if not ver: die("cannot tell the version.", "add --version 1.1.14")
        dst = p(os.path.dirname(dst), ver)
        for rel in ROOTS:
            if os.path.isdir(p(base, rel)): n += copy_tree(p(base, rel), p(dst, rel))
        if os.path.isfile(vtxt): shutil.copy2(vtxt, ensure(dst) + "/iso_version.txt")
        man = local_manifest(base)
        for e in ENVS:
            f = p(base, "_meta", e + ".txt")
            if os.path.isfile(f): shutil.copy2(f, ensure(p(dst, "_meta")) + "/" + e + ".txt")
    else:
        r = subprocess.run(ssh_base(host) + ["cat ~/iso_version.txt"], capture_output=True, text=True)
        if r.returncode: die("cannot read the board %s: %s" % (host, r.stderr.strip()), "check the address and that the board is on")
        ver = version or board_version(r.stdout)
        if not ver: die("the board has no System version in iso_version.txt.", "add --version 1.1.14")
        dst = p(os.path.dirname(dst), ver); ensure(dst)
        open(p(dst, "iso_version.txt"), "w").write(r.stdout)
        ex = sum((["--exclude", x] for x in list(SKIP_DIRS) + ["*.pyc", "*.log"] + list(SKIP_GLOBS)), [])
        e = " ".join(ssh_base(host)[:-1])   # reuses the one logged-in connection
        for rel in ROOTS:
            ensure(p(dst, rel))
            r = subprocess.run(["rsync", "-a", "-e", e] + ex + ["%s@%s:~/%s/" % (BOARD["user"], host, rel), p(dst, rel) + "/"], capture_output=True, text=True)
            if r.returncode: say("  warning: could not read ~/%s on the board (%s)" % (rel, r.stderr.strip().splitlines()[-1] if r.stderr.strip() else r.returncode))
            n += len(listing(p(dst, rel)))
        man = remote_manifest(host)
        for en in ENVS:
            r = subprocess.run(ssh_base(host) + ["~/%s/bin/pip freeze 2>/dev/null" % en], capture_output=True, text=True)
            if r.stdout.strip(): open(ensure(p(dst, "_meta")) + "/" + en + ".txt", "w").write(r.stdout)
    json.dump(man, open(p(dst, "_manifest.json"), "w"), indent=0, sort_keys=True)
    return ver, dst, n, len(man)


# ---------------------------------------------------------------- TM_T1_SOC (encrypted factory update) opened on the Pi
# A TM_T1_SOC file is WonderMaker's encrypted System package: a Debian package
# wrapped in two layers - a repeating-key XOR, then OpenSSL AES-256-CBC
# ("Salted__" + salt, key via EVP_BytesToKey/SHA-256). The key below is
# WonderMaker's own, read out of the stock `client` binary. Override with
# WMR_SOC_KEY if a future firmware changes it. This lets you take a new version
# straight from the TM_T1_SOC file on the Pi, with no factory screen board.
DEFAULT_SOC_KEY = "tmt1-mks"                 # overridable via WMR_SOC_KEY or the settings screen
SOC_ONLY = ("home/t13dp/boot.img", "lib/modules/", "usr/lib/modules/exfat.ko")  # SoC kernel bits; never in a Pi release


def _soc_xor(data, key):
    kb = key.encode()
    return bytes(b ^ kb[i % len(kb)] for i, b in enumerate(data))


def soc_to_deb(path, key=None):
    """decrypt a TM_T1_SOC file to the raw .deb bytes (XOR, then openssl AES-256-CBC)"""
    key = key or soc_key()
    raw = open(path, "rb").read()
    blob = _soc_xor(raw, key)
    if blob[:8] != b"Salted__":
        if raw[:8] == b"Salted__": blob = raw            # file already past the XOR layer
        else: die("this does not look like a TM_T1_SOC (no 'Salted__' after XOR).",
                  "check the file, or set WMR_SOC_KEY if WonderMaker changed the key")
    if not shutil.which("openssl"): die("openssl is needed to decrypt the SOC.", "sudo apt-get install -y openssl")
    with tempfile.NamedTemporaryFile(delete=False) as f: f.write(blob); tmp = f.name
    try:
        r = subprocess.run(["openssl", "enc", "-d", "-aes-256-cbc", "-md", "sha256", "-k", key, "-in", tmp],
                           capture_output=True)
    finally:
        os.unlink(tmp)
    if r.returncode: die("openssl could not decrypt the SOC (wrong key?): " + r.stderr.decode(errors="replace").strip())
    if r.stdout[:8] != b"!<arch>\n": die("the decrypted SOC is not a Debian package (wrong key?).")
    return r.stdout


def _ar_member(deb, prefix):
    off = 8
    while off + 60 <= len(deb):
        name = deb[off:off + 16].decode(errors="replace").strip()
        try: size = int(deb[off + 48:off + 58].decode().strip())
        except ValueError: break
        start = off + 60
        if name.startswith(prefix): return deb[start:start + size]
        off = start + size + (size & 1)
    return None


def _deb_version(deb):
    blob = _ar_member(deb, "control.tar")
    if not blob: return None
    try: tf = tarfile.open(fileobj=io.BytesIO(blob), mode="r:*")
    except Exception: return None
    for m in tf.getmembers():
        if m.name.lstrip("./") == "control":
            for line in tf.extractfile(m).read().decode(errors="replace").splitlines():
                if line.startswith("Version:"): return line.split(":", 1)[1].strip()
    return None


def stage_soc(path):
    """decrypt a TM_T1_SOC and lay it out like a --from-dir source; returns (dir, version)"""
    say("Decrypting %s ..." % os.path.basename(path))
    deb = soc_to_deb(os.path.expanduser(path))
    ver = _deb_version(deb) or die("could not read the version from the SOC package.")
    data = _ar_member(deb, "data.tar") or die("no data.tar inside the SOC package.")
    tf = tarfile.open(fileobj=io.BytesIO(data), mode="r:*")
    base = tempfile.mkdtemp(prefix="soc-%s-" % ver, dir=ensure(p(DATA, "soc")))
    atexit.register(lambda: shutil.rmtree(base, ignore_errors=True))
    n = 0
    for m in tf.getmembers():
        name = m.name.lstrip("./")
        if any(name == s or name.startswith(s) for s in SOC_ONLY): continue
        if name.startswith("home/t13dp/"): rel = name[len("home/t13dp/"):]
        elif name.startswith("etc/"): rel = name                 # system files go under <base>/etc/...
        else: continue
        if not rel: continue
        dst = p(base, rel)
        if m.isdir(): ensure(dst); continue
        ensure(os.path.dirname(dst))
        if m.issym() or m.islnk():
            try:
                if os.path.lexists(dst): os.remove(dst)
                os.symlink(m.linkname, dst)
            except OSError: pass
        else:
            src = tf.extractfile(m)
            if src is None: continue
            with open(dst, "wb") as out: shutil.copyfileobj(src, out)
            n += 1
    open(p(base, "iso_version.txt"), "w").write("System_%s\n" % ver)
    say("Decrypted System %s (%d files) into a private staging folder." % (ver, n))
    return base, ver


def soc_download_links(timeout=20):
    """{version: absolute url} for every tm_t1_soc(x.y.z).zip link on WonderMaker's firmware page"""
    req = urllib.request.Request(wiki_url(), headers={"User-Agent": "wm_release/" + TOOL_VERSION})
    with urllib.request.urlopen(req, timeout=timeout) as f:
        page_url = f.geturl()
        html = f.read().decode("utf-8", "replace")
    links = {}
    # every href whose target (or its text) names a tm_t1_soc(ver).zip
    for href in re.findall(r'''href\s*=\s*["']([^"']+)["']''', html, re.I):
        m = re.search(r"tm_t1_soc\(?(\d+(?:\.\d+)+)\)?\.zip", href, re.I)
        if m: links[m.group(1)] = urllib.parse.urljoin(page_url, href)
    return links


# ---------------------------------------------------------------- firmware archive (kept SOC zips, for offline reinstall/downgrade)
def archive_zip_path(ver): return p(ARCHIVE, "tm_t1_soc(%s).zip" % ver)


def archived_versions():
    """versions whose SOC zip is kept in the firmware archive folder"""
    if not os.path.isdir(ARCHIVE): return []
    vs = []
    for n in os.listdir(ARCHIVE):
        m = re.search(r"tm_t1_soc\(?(\d+(?:\.\d+)+)\)?\.zip", n, re.I)
        if m: vs.append(m.group(1))
    return sorted(set(vs), key=vkey)


def _soc_from_zip(zpath, out_dir):
    """pull the raw TM_T1_SOC file out of a tm_t1_soc zip; return its path"""
    try:
        z = zipfile.ZipFile(zpath)
    except zipfile.BadZipFile:
        die("not a zip: %s" % zpath, "check the file / re-download")
    names = [n for n in z.namelist() if not n.endswith("/")]
    soc = (next((n for n in names if os.path.basename(n) == "TM_T1_SOC"), None)
           or next((n for n in names if os.path.basename(n).upper().endswith("_SOC")), None)
           or next((n for n in names if "SOC" in os.path.basename(n).upper()), None))
    if not soc:
        die("no TM_T1_SOC file inside %s." % os.path.basename(zpath), "zip contains: " + ", ".join(names))
    dest = p(ensure(out_dir), "TM_T1_SOC")
    with z.open(soc) as src, open(dest, "wb") as w:
        shutil.copyfileobj(src, w)
    return dest


def fetch_from_archive(ver):
    """use a SOC zip already kept in the firmware archive (no network); return (SOC file path, version)"""
    z = archive_zip_path(ver)
    if not os.path.isfile(z):
        die("no archived firmware for %s." % ver, "archived: " + (", ".join(archived_versions()) or "none; download one first"))
    dest = _soc_from_zip(z, p(DATA, "soc"))
    atexit.register(lambda: os.path.exists(dest) and os.remove(dest))
    say("Using archived System %s (%s)." % (ver, z))
    return dest, ver


def download_soc(version=None, timeout=20):
    """download the chosen (or newest) tm_t1_soc zip, keep it in the archive, return (SOC file path, version)"""
    try:
        links = soc_download_links(timeout)
    except Exception as e:
        die("could not read WonderMaker's firmware page: %s" % e,
            "check the Pi's internet, or download the zip yourself and use --from-soc FILE")
    if not links:
        die("found no tm_t1_soc(...).zip download link on the firmware page.",
            "WonderMaker may have changed the page; download the zip yourself and use --from-soc FILE (or set WMR_WIKI_URL)")
    ver = version or sorted(links, key=vkey)[-1]
    if ver not in links:
        die("version %s is not on the page." % ver, "available: " + ", ".join(sorted(links, key=vkey)))
    zpath = archive_zip_path(ver)
    if os.path.isfile(zpath):
        say("Using the archived copy of System %s (already downloaded)." % ver)
    else:
        url = links[ver]; ensure(ARCHIVE)
        say("Downloading System %s from %s ..." % (ver, url))
        req = urllib.request.Request(url, headers={"User-Agent": "wm_release/" + TOOL_VERSION})
        tmp = zpath + ".part"
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r, open(tmp, "wb") as w:
                shutil.copyfileobj(r, w)
            os.replace(tmp, zpath)                 # keep it in the firmware archive
        except Exception as e:
            if os.path.exists(tmp): os.remove(tmp)
            die("download failed: %s" % e, "try again, or download the zip yourself and use --from-soc FILE")
        say("Saved to the firmware archive: %s" % zpath)
    dest = _soc_from_zip(zpath, p(DATA, "soc"))
    atexit.register(lambda: os.path.exists(dest) and os.remove(dest))
    say("Got TM_T1_SOC from the zip (%s)." % ver)
    return dest, ver


def cmd_firmware(a):
    """list the SOC zips kept in the firmware archive"""
    vs = archived_versions()
    say("Firmware archive: %s" % ARCHIVE)
    if not vs: say("  (empty - a web download keeps a copy here automatically)"); return
    for v in vs:
        z = archive_zip_path(v)
        say("  %-10s %6.1f MiB   %s" % (v, os.path.getsize(z) / 1048576, z))
    say("Reinstall/downgrade one with:  python3 wm_release.py fetch --from-archive <version>")


def cmd_compare(a):
    """what WonderMaker changed between two fetched releases - read only, your live files are never touched"""
    r1 = p(DATA, "releases", a.old); r2 = p(DATA, "releases", a.new)
    if not os.path.isdir(r1): die("release %s was not fetched." % a.old, "fetch it (fetch --from-web %s, or --from-archive %s)" % (a.old, a.old))
    if not os.path.isdir(r2): die("release %s was not fetched." % a.new, "fetch it (fetch --from-web %s, or --from-archive %s)" % (a.new, a.new))
    A, B = {}, {}
    for rel in ROOTS:
        for r, ap in listing(p(r1, rel)).items(): A[p(rel, r)] = ap
        for r, ap in listing(p(r2, rel)).items(): B[p(rel, r)] = ap
    keys = sorted(set(A) | set(B))
    added = [k for k in keys if k in B and k not in A]
    removed = [k for k in keys if k in A and k not in B]
    changed = [k for k in keys if k in A and k in B and sha(A[k]) != sha(B[k])]
    say("What WonderMaker changed from %s to %s (printer files; read only):" % (a.old, a.new))
    say("  changed %d, added %d, removed %d, unchanged %d" %
        (len(changed), len(added), len(removed), len(keys) - len(changed) - len(added) - len(removed)))
    for tag, lst in (("CHANGED", changed), ("ADDED", added), ("REMOVED", removed)):
        for k in lst: say("  %-8s %s" % (tag, k))
    m1, m2 = load_manifest(r1), load_manifest(r2)
    if m1 and m2:
        dk = [k for k in set(m1) | set(m2) if m1.get(k) != m2.get(k)]
        say("  (other folders, by checksum: %d differ)" % len(dk))


def cmd_settings(a):
    """show or change the decrypt key, the firmware page URL and the board address (saved in config.json)"""
    envk, envu = os.environ.get("WMR_SOC_KEY"), os.environ.get("WMR_WIKI_URL")
    say("Settings (saved in %s):" % p(DATA, "config.json"))
    say("  decrypt key   : %s%s" % (soc_key(), "   (from WMR_SOC_KEY env, overrides saved)" if envk else ""))
    say("  firmware URL  : %s%s" % (wiki_url(), "   (from WMR_WIKI_URL env, overrides saved)" if envu else ""))
    say("  firmware store: %s  (%d saved)" % (ARCHIVE, len(archived_versions())))
    say("  board address : %s" % (conf_get("board_host") or "(not set)"))
    say("  board user    : %s" % (conf_get("board_user") or "t13dp"))
    if not sys.stdin.isatty(): return
    k = ask("Decrypt key (Enter keeps it)", "")
    if k: conf_set("soc_key", k); say("  saved." + ("  (note: WMR_SOC_KEY env is set and still overrides this)" if envk else ""))
    u = ask("Firmware page URL (Enter keeps it; 'default' resets)", "")
    if u == "default": conf_set("wiki_url", ""); _WIKI.clear(); say("  reset to default.")
    elif u: conf_set("wiki_url", u); _WIKI.clear(); say("  saved.")
    h = ask("Board address (Enter keeps it)", "")
    if h: conf_set("board_host", h); say("  saved.")


def _du(path):
    t = 0
    for r, _, fs in os.walk(path):
        for f in fs:
            try: t += os.lstat(p(r, f)).st_size
            except OSError: pass
    return t

def _clean_items():
    """everything this tool itself creates: (label, path)"""
    import glob
    items = [("tool data (baseline, fetched releases, backups, reports, notes, settings, history)", DATA),
             ("firmware archive (kept TM_T1_SOC zips)", ARCHIVE)]
    items += [("temporary files", t) for t in sorted(glob.glob(p(tempfile.gettempdir(), "wmr-*")))]
    return [(l, d) for l, d in items if os.path.lexists(d)]

def cmd_clean(a):
    """delete every file this tool created (never touches the printer's live files)"""
    protected = {os.path.realpath(x) for x in ("/", HOME, LIVE, os.path.expanduser("~"))}
    items = _clean_items()
    keep = set()
    if getattr(a, "keep_firmware", False): keep.add(os.path.realpath(ARCHIVE))
    if getattr(a, "keep_backups", False): keep.add(os.path.realpath(p(DATA, "backups")))
    for l, d in items:
        if os.path.realpath(d) in protected: die("refusing to delete %s" % d, "its location is a protected folder; check WMR_HOME / WMR_FIRMWARE_DIR")
    say("This tool created these (sizes):")
    if not items: say("  nothing - already clean."); return
    for l, d in items:
        mark = "   (kept)" if os.path.realpath(d) in keep else ""
        say("  %-8.1f MiB  %s%s\n               %s" % (_du(d) / 1048576 if os.path.isdir(d) else os.path.getsize(d) / 1048576, d, mark, l))
    say("\nNOT touched: klipper, moonraker, printer_data/config, mcu_update and TM_T1/scripts as they are on this machine now")
    say("(updates you already applied stay applied).  After cleaning there is NO baseline and NO backup to roll back to.")
    if not a.run: say("\nDry run - nothing deleted.  Delete for real with:  python3 wm_release.py clean --run"); return
    typed = os.environ.get("WMR_TEST_TYPED") or input("Type DELETE to permanently delete the folders above: ").strip()
    if typed != "DELETE": die("nothing deleted.", "type DELETE exactly to confirm")
    gone = 0
    for l, d in items:
        if os.path.realpath(d) in keep: continue
        if os.path.realpath(d) == os.path.realpath(DATA) and any(k.startswith(os.path.realpath(DATA) + os.sep) for k in keep):
            for n in os.listdir(d):
                if os.path.realpath(p(d, n)) in keep: continue
                (shutil.rmtree if os.path.isdir(p(d, n)) and not os.path.islink(p(d, n)) else os.remove)(p(d, n))
        else:
            (shutil.rmtree if os.path.isdir(d) and not os.path.islink(d) else os.remove)(d)
        gone += 1; say("  deleted %s" % d)
    say("Done: %d item(s) deleted." % gone)


def cmd_flash(a):
    """flash the bundled Klipper MCU firmware onto the motion/toolhead boards - guarded; nothing runs unless you add --run and type FLASH"""
    mdir = p(LIVE, "mcu_update")
    targets = {"main": "mcu_update.sh", "thr": "mcu_update_THRs.sh", "ext": "mcu_update_EXT.sh",
               "hub": "mcu_update_HUB.sh", "cell": "mcu_update_CELL.sh"}
    pick = (getattr(a, "target", None) or "main").lower()
    if pick not in targets: die("unknown target '%s'." % pick, "one of: " + ", ".join(targets))
    if not os.path.isdir(mdir): die("no ~/mcu_update on this Pi.", "apply a release first - it installs mcu_update/ with the firmware and scripts")
    scr = p(mdir, targets[pick])
    if not os.path.isfile(scr): die("flash script not found: %s" % scr, "this release may not include %s" % targets[pick])
    say("!! MCU FIRMWARE FLASH - this WRITES firmware to your %s board(s)." % pick.upper())
    say("   Wrong or interrupted firmware can leave a board unbootable until re-flashed by hand.")
    say("   The printer must be connected, powered, and NOT printing.")
    info = p(mdir, "mcu_info.ini")
    if os.path.isfile(info):
        say("   mcu_info.ini:")
        for ln in open(info).read().splitlines()[:20]: say("     " + ln)
    say("   Would run:  bash %s" % scr)
    say("   Access check (nothing is changed):")
    hf = p(mdir, "hid-flash")
    for label, path, mode in (("flash script readable", scr, os.R_OK), ("hid-flash program runnable", hf, os.X_OK), ("firmware file readable", p(mdir, "klipper.bin" if pick == "main" else "klipper_%s.bin" % pick.upper()), os.R_OK)):
        if pick == "main" or label != "hid-flash program runnable":
            say("     %-28s %s" % (label, "ok" if os.path.exists(path) and os.access(path, mode) else "NOT OK: " + path))
    if hasattr(os, "geteuid") and os.geteuid() != 0:
        say("     Running as a normal user. WonderMaker's stock app flashes as root. If the flash stops with a permission error on the")
        say("     bootloader device (/dev/serial/by-id/usb-*_DRIVER_BOOT*), nothing was written; the device needs a udev rule for your user.")
    pr, st = printing_now()
    if pr and not getattr(a, "force", False): die("a print is running (%s)." % st, "wait for it to finish")
    if not getattr(a, "run", False):
        say("\nDry run: nothing was flashed. To really flash: python3 wm_release.py flash %s --run" % pick); return
    typed = os.environ.get("WMR_TEST_TYPED") or input("Type FLASH to write firmware to the %s board(s): " % pick).strip()
    if typed != "FLASH": say("Nothing flashed."); return
    log("flash", "-", target=pick)
    say("Flashing %s ..." % pick)
    r = subprocess.run(["bash", scr], cwd=mdir)
    if r.returncode != 0: say("The flash script reported an error. If it said permission denied for the bootloader device, your user cannot open it: ask before changing permissions; no root change is made by this tool.")
    say("Flash script exited with %d. In Fluidd run FIRMWARE_RESTART and check the MCU comes back 'Ready'." % r.returncode)


def cmd_init_baseline(a):
    """record the files of the version BEFORE the one you will update to: from the board (best), a folder, or this repo's factory copy"""
    if getattr(a, "from_archive", None):
        a.from_soc, _ = fetch_from_archive(a.from_archive)
    if getattr(a, "from_web", None) is not None:
        a.from_soc, _ = download_soc(a.from_web or None)
    if getattr(a, "from_soc", None):
        a.from_dir, _ = stage_soc(a.from_soc)
    if a.from_board is not None or a.from_dir:
        bdir = p(DATA, "baseline", "_x")
        ver, dst, n, nm = snapshot(bdir, host=board_host(a.from_board, may_ask=True) if a.from_dir is None else None, src_dir=a.from_dir, version=a.version)
        log("init-baseline", ver, files=n, checksums=nm, source=a.from_dir or "board")
        say("Baseline %s recorded from %s: %d files copied, %d other files by checksum, in %s" % (ver, a.from_dir or "the board", n, nm, dst))
        say("Do this BEFORE the board is updated, so the baseline is the version before the new one.")
        return
    src = a.src or _repo_factory_dir()
    src = os.path.abspath(src)
    if not os.path.isdir(src): die("no source folder: " + src, "give --src DIR (a folder like factory/ultra-s)")
    ver = a.version or "1.1.13"
    dst = p(DATA, "baseline", ver)
    if os.path.isdir(dst) and not a.force: die("baseline %s already recorded." % ver, "use --force to record it again")
    if os.path.isdir(dst): shutil.rmtree(dst)
    tot = 0
    for live_rel, repo_name in REPO_MAP.items():
        s_ = p(src, repo_name)
        if os.path.isdir(s_): tot += copy_tree(s_, p(dst, live_rel))
    if tot == 0: die("nothing found in " + src, "it must contain klipper/, moonraker/, config/, mcu/, scripts/")
    log("init-baseline", ver, files=tot, source=src)
    say("Baseline %s recorded: %d files in %s (repo copy: only the printer's own folders, no board-wide checksums)" % (ver, tot, dst))


def cmd_fetch(a):
    if getattr(a, "from_archive", None):
        a.from_soc, _ = fetch_from_archive(a.from_archive)
    if getattr(a, "from_web", None) is not None:
        a.from_soc, _ = download_soc(a.from_web or None)
    if getattr(a, "from_soc", None):
        a.from_dir, _ = stage_soc(a.from_soc)
    if not a.from_dir and a.host is None and a.board is None: die("say where from.", "fetch --from-web  or  fetch --from-soc FILE  or  fetch --from-board  or  fetch --from-dir DIR")
    rdir = p(DATA, "releases", "_x")
    ver, dst, n, nm = snapshot(rdir, host=board_host(a.host, may_ask=sys.stdin.isatty()) if not a.from_dir else None, src_dir=a.from_dir, version=a.version)
    log("fetch", ver, files=n, checksums=nm)
    say("Release %s copied to %s (%d files, plus %d other files by checksum). Nothing was changed on the board or here." % (ver, dst, n, nm))
    bv, _ = baseline_dir(ver)
    say("Next: python3 wm_release.py diff %s%s" % (ver, "" if bv else "   (first run init-baseline, ideally --from-board while the board is still on the old version)"))


def cmd_promote(a):
    src = p(DATA, "releases", a.version); dst = p(DATA, "baseline", a.version)
    if not os.path.isdir(src): die("release %s was not fetched." % a.version)
    if os.path.isdir(dst): die("baseline %s already exists." % a.version)
    shutil.copytree(src, dst)
    log("promote", a.version)
    say("%s is now a baseline. The next release will be compared with it." % a.version)


# ---------------------------------------------------------------- compare
def norm(path):
    """text with LF line endings, no trailing spaces, one final newline: so only real changes count"""
    t = read(path).decode("utf-8", "replace").replace("\r\n", "\n").replace("\r", "\n")
    return "\n".join(x.rstrip() for x in t.split("\n")).rstrip("\n") + "\n"


def same_text(a, b):
    """identical, or identical apart from line endings / trailing spaces (text files only)"""
    if sha(a) == sha(b): return True
    return is_text(a) and is_text(b) and norm(a) == norm(b)


def merge3(live, base, new):
    """git merge-file on normalised copies: returns (clean, text)"""
    if not shutil.which("git"): return False, None
    with tempfile.TemporaryDirectory() as t:
        for n, src in (("live", live), ("base", base), ("new", new)): open(p(t, n), "w").write(norm(src))
        r = subprocess.run(["git", "merge-file", "-p", p(t, "live"), p(t, "base"), p(t, "new")], capture_output=True)
        return r.returncode == 0, r.stdout


def classify(rel, B, N, L):
    """rel is relative to the live home (e.g. printer_data/config/macros.cfg)"""
    b, n, l = B.get(rel), N.get(rel), L.get(rel)
    if rel in PROTECTED:
        return ("PROTECTED", None) if (n and (not b or sha(n) != sha(b))) else ("UNCHANGED", None)
    if n is None:
        return ("REMOVED", None) if b else ("UNCHANGED", None)
    if b and sha(b) == sha(n):
        if not l or sha(l) == sha(b): return ("UNCHANGED", None)
        return ("WHITESPACE", None) if same_text(l, b) else ("KEEP_MINE", None)
    if l is None: return ("ADD", None)
    if b and same_text(l, b): return ("TAKE", None)
    if same_text(l, n): return ("UNCHANGED", None)
    if b and is_text(l) and is_text(n) and is_text(b):
        ok, text = merge3(l, b, n)
        if ok: return ("MERGE", text)
    return ("CONFLICT", None)


def trees(ver):
    bv, bd = baseline_dir(ver)
    if not bd: die("no baseline older than %s is recorded." % ver, "python3 wm_release.py init-baseline --from-board  (while the board still has the old version)")
    rd = p(DATA, "releases", ver)
    if not os.path.isdir(rd): die("release %s was not fetched." % ver, "python3 wm_release.py fetch --from-board")
    B, N, L = {}, {}, {}
    for root in ROOTS:
        for rel, a in listing(p(bd, root)).items(): B[p(root, rel)] = a
        for rel, a in listing(p(rd, root)).items(): N[p(root, rel)] = a
        for rel in set(listing(p(bd, root))) | set(listing(p(rd, root))):
            lp = p(LIVE, root, rel)
            if os.path.lexists(lp): L[p(root, rel)] = lp
    return bv, B, N, L


def plan_for(ver):
    bv, B, N, L = trees(ver)
    plan = {}
    for rel in sorted(set(B) | set(N)):
        c, extra = classify(rel, B, N, L)
        plan[rel] = (c, extra)
    return bv, B, N, L, plan


BACKUP_CFG = re.compile(r"^printer-\d{8}_\d{6}\.cfg$|\.bak$|\.bkp$")


def macros_of(files):
    """macro name -> {file: body} for every [gcode_macro X] in the given config files"""
    out = {}
    for f, path in files.items():
        if not f.endswith(".cfg") or BACKUP_CFG.search(f): continue
        cur = None
        for line in read(path).decode("utf-8", "replace").splitlines():
            m = re.match(r"^\[gcode_macro\s+([^\]]+)\]", line)
            if m: cur = m.group(1).strip(); out.setdefault(cur, {})[os.path.basename(f)] = []; continue
            if line.startswith("["): cur = None
            if cur: out[cur][os.path.basename(f)].append(line.rstrip())
    return out


def dup_report(files):
    out = []
    for name, d in sorted(macros_of(files).items()):
        if len(d) > 1:
            bodies = {k: "\n".join(v).strip() for k, v in d.items()}
            out.append("  %-28s in %s: %s" % (name, ", ".join(sorted(d)), "identical" if len(set(bodies.values())) == 1 else "DIFFERENT"))
    return out


def load_manifest(d):
    f = p(d, "_manifest.json")
    return json.load(open(f)) if os.path.isfile(f) else None


def report_roots_diff(bd, rd):
    """checksum comparison of everything outside the printer's own folders; returns lines"""
    bm, nm = load_manifest(bd), load_manifest(rd)
    if bm is None or nm is None:
        return ["  (no board-wide checksums in the baseline or the release: record both with --from-board to compare these folders)"], [], 0
    out, py, total = [], [], 0
    for rel, _ in REPORT_ROOTS:
        pre = rel + "/"
        ch = sorted(f for f in nm if f.startswith(pre) and f in bm and nm[f] != bm[f])
        ad = sorted(f for f in nm if f.startswith(pre) and f not in bm)
        rm = sorted(f for f in bm if f.startswith(pre) and f not in nm)
        if not (ch or ad or rm): continue
        total += len(ch) + len(ad) + len(rm)
        out.append("  %-24s changed %d, new %d, removed %d" % (rel, len(ch), len(ad), len(rm)))
        for tag, lst in (("changed", ch), ("new", ad), ("removed", rm)):
            for f in lst[:25]: out.append("      %-8s %s" % (tag, f))
            if len(lst) > 25: out.append("      ... %d more %s" % (len(lst) - 25, tag))
        py += [f for f in ch + ad if f.endswith(".py")]
    return out, py, total


def env_diff(bd, rd):
    out = []
    for e in ENVS:
        fb, fr = p(bd, "_meta", e + ".txt"), p(rd, "_meta", e + ".txt")
        if not (os.path.isfile(fb) and os.path.isfile(fr)): continue
        pk = lambda f: dict(x.split("==", 1) for x in open(f).read().splitlines() if "==" in x)
        b, r = pk(fb), pk(fr)
        for k in sorted(set(b) | set(r)):
            if b.get(k) != r.get(k): out.append("  %-14s %-24s %s -> %s" % (e, k, b.get(k, "(not there)"), r.get(k, "(removed)")))
    return out


def cmd_diff(a):
    bv, B, N, L, plan = plan_for(a.version)
    bd, rd = p(DATA, "baseline", bv), p(DATA, "releases", a.version)
    groups = {}
    for rel, (c, _) in plan.items(): groups.setdefault(c, []).append(rel)
    lines = ["WonderMaker release %s compared with baseline %s and your live files" % (a.version, bv), "Made " + time.strftime("%Y-%m-%d %H:%M:%S"), ""]
    expl = [("TAKE", "WonderMaker changed it, you did not: safe to take the new file"),
            ("ADD", "new in this release and not on your Pi: safe to add"),
            ("MERGE", "both changed it, in different places: merges cleanly"),
            ("CONFLICT", "both changed the same place (or a binary): decide by hand"),
            ("KEEP_MINE", "only you changed it: stays as it is"),
            ("WHITESPACE", "your file differs from WonderMaker's only in line endings or trailing spaces: harmless, stays"),
            ("PROTECTED", "WonderMaker changed it, but it holds your includes or data: never applied, look yourself"),
            ("REMOVED", "removed in the release: nothing is deleted on your Pi")]
    lines.append("Summary: " + ", ".join("%s %d" % (k, len(groups.get(k, []))) for k, _ in expl if k != "WHITESPACE") + ", WHITESPACE %d, UNCHANGED %d" % (len(groups.get("WHITESPACE", [])), len(groups.get("UNCHANGED", []))))
    for k, text in expl:
        if groups.get(k):
            lines += ["", "== %s (%d): %s" % (k, len(groups[k]), text)] + ["  " + x for x in groups[k]]
    changed = [r for r, (c, _) in plan.items() if c in ("TAKE", "ADD", "MERGE", "CONFLICT", "PROTECTED")]
    so = [r for r in changed if r.endswith(".so") or ".cpython-" in r or r.endswith(".bin")]
    req = [r for r in changed if re.search(r"requirements.*\.txt$", r)]
    notes = []
    if so: notes.append("Compiled modules / binaries changed (%d): %s. Restart Klipper after applying." % (len(so), ", ".join(so[:6])))
    if req: notes.append("Python requirements changed: %s. The Python environments need rebuilding (the installer's --update does this)." % ", ".join(req))
    if any(r.startswith("mcu_update/") for r in changed): notes.append("mcu_update/ changed: run the mcu command; MCU firmware is only flashed if you run flash --run and type FLASH.")
    if any(r.startswith("printer_data/config/") and r.endswith("macros.cfg") for r in changed): notes.append("Macros changed: re-test tool change, start print, pause/resume, end print.")
    rep_lines, rep_py, rep_total = report_roots_diff(bd, rd)
    lines += ["", "== Everything else on the board (checksums only; shown for you, never applied; %d files differ)" % rep_total] + rep_lines
    ed = env_diff(bd, rd)
    if ed: lines += ["", "== Python package versions that differ (pip freeze of the board)"] + ed; notes.append("Python packages differ between the two versions: check the Pi's environments (the installer's --update rebuilds them).")
    pys = sorted(r for r in changed if r.endswith(".py")) + sorted(rep_py)
    lines += ["", "== Python files changed or new (%d)" % len(pys)] + ["  " + x for x in pys[:200]] + (["  ... %d more" % (len(pys) - 200)] if len(pys) > 200 else [])
    if notes: lines += ["", "== Things to do"] + ["  - " + x for x in notes]
    newcfg = {os.path.basename(r): N[r] for r in N if r.startswith("printer_data/config/") and r.endswith(".cfg")}
    d = dup_report({os.path.basename(r): N[r] for r in N if r.startswith("printer_data/config/") and r.endswith(".cfg")})
    # macros defined twice in the NEW release (the second include wins in Klipper)
    if d: lines += ["", "== Macros defined in more than one file in this release (the later include wins)"] + d
    clash = rpi_cfg_clash(newcfg)
    if clash: lines += ["", "== Macros this release defines that the Pi's own files (rpi-cfg) define too (the later include wins)"] + clash; notes.append("A macro name in this release is also used by rpi-cfg/wm_calibration.cfg: rename one of them.")
    ensure(p(DATA, "reports")); rp = p(DATA, "reports", "%s-%s.txt" % (a.version, now()))
    open(rp, "w").write("\n".join(lines) + "\n")
    say("\n".join(lines)); say("\nReport saved: " + rp)
    log("diff", a.version, report=rp)


# ---------------------------------------------------------------- printing guard
def printing_now():
    try:
        with urllib.request.urlopen(MOONRAKER + "/printer/objects/query?print_stats", timeout=4) as r:
            st = json.load(r)["result"]["status"]["print_stats"]["state"]
        return st in ("printing", "paused"), st
    except Exception:
        return False, None


# ---------------------------------------------------------------- apply / rollback
def cmd_apply(a):
    bv, B, N, L, plan = plan_for(a.version)
    todo = {r: (c, x) for r, (c, x) in plan.items() if c in ("TAKE", "ADD", "MERGE")}
    conf = [r for r, (c, _) in plan.items() if c == "CONFLICT"]
    say("Plan for release %s (baseline %s):" % (a.version, bv))
    for c in ("TAKE", "ADD", "MERGE"):
        for r in sorted(x for x, (k, _) in todo.items() if k == c): say("  %-6s %s" % (c, r))
    for r in conf: say("  HAND   %s   (conflict: saved for you in %s)" % (r, p(DATA, "conflicts", a.version)))
    for n, st in rpi_cfg_state(): say("  KEEP   printer_data/config/%s   (the Pi's own file, never changed by apply; %s)" % (n, st))
    clash = rpi_cfg_clash({os.path.basename(r): N[r] for r in N if r.startswith("printer_data/config/") and r.endswith(".cfg")})
    if clash: say("WARNING: this release defines macros that your Pi's own files define too (the later include wins in Klipper):"); [say(x) for x in clash]
    pidc = pid_cfg_release_conflicts({os.path.basename(r): N[r] for r in N if r.startswith("printer_data/config/") and r.endswith(".cfg")})
    if pidc: say("WARNING: this release sets PID values for a heater in an included file; Klipper's SAVE_CONFIG then refuses to save a PID result.\n  After apply run: python3 wm_release.py pid-cfg --fix"); [say(x) for x in pidc]
    if not todo and not conf: say("  nothing to do."); return
    if not a.apply:
        say("\nDry run: nothing was changed. To apply: python3 wm_release.py apply %s --apply" % a.version); return
    pr, st = printing_now()
    if pr and not a.force: die("a print is running (%s)." % st, "wait for it to finish")
    if st is None: say("Note: Moonraker did not answer, so I cannot tell whether a print is running.")
    typed = os.environ.get("WMR_TEST_TYPED") or input("Type APPLY to change %d files (a backup is made first): " % len(todo)).strip()
    if typed != "APPLY": say("Nothing changed."); return
    ensure(p(DATA, "backups")); bk = p(DATA, "backups", "%s-%s.tgz" % (a.version, now()))
    added, existing = [], []
    with tarfile.open(bk, "w:gz") as t:
        for r in todo:
            lp = p(LIVE, r)
            if os.path.lexists(lp): t.add(lp, arcname=r); existing.append(r)
            else: added.append(r)
        try: iso_before = open(p(LIVE, "iso_version.txt")).read()
        except OSError: iso_before = None
        info = json.dumps({"version": a.version, "added": added, "existing": existing, "iso_before": iso_before}).encode()
        ti = tarfile.TarInfo("wm-release-manifest.json"); ti.size = len(info); t.addfile(ti, io.BytesIO(info))
    os.chmod(bk, 0o600)
    for r, (c, text) in sorted(todo.items()):
        lp = p(LIVE, r)
        if c == "MERGE":
            mode = os.stat(lp).st_mode; open(lp, "wb").write(text); os.chmod(lp, mode)
        else:
            copy_file(N[r], lp)
    for r in conf:
        d = ensure(p(DATA, "conflicts", a.version, os.path.dirname(r)))
        if is_text(N[r]):
            ok, text = merge3(L[r], B[r], N[r]) if r in B and r in L else (False, None)
            if text is not None: open(p(d, os.path.basename(r) + ".merge"), "wb").write(text)
        shutil.copy2(N[r], p(d, os.path.basename(r) + ".theirs"))
    write_live_version(a.version)
    log("apply", a.version, files=len(todo), conflicts=len(conf), backup=bk)
    say("Applied %d files. Backup: %s" % (len(todo), bk))
    say("~/iso_version.txt now says System_%s." % a.version)
    if conf: say("%d conflict(s) left for you: %s" % (len(conf), p(DATA, "conflicts", a.version)))
    rc, out = pid_cfg_run()
    if rc == 1: say("PID settings: the new files put them where SAVE_CONFIG cannot store a PID result:"); [say("  " + x) for x in out]; say("  Fix: python3 wm_release.py pid-cfg --fix   (copies of the changed files are kept)")
    say("Next: restart Klipper (sudo systemctl restart klipper), then run the checklist: python3 wm_release.py checklist %s" % a.version)
    say("When the new version works for you: python3 wm_release.py promote %s   (so the next release is compared with it)" % a.version)
    say("Undo: python3 wm_release.py rollback")


def cmd_rollback(a):
    bk = a.backup
    if not bk:
        c = sorted(x for x in os.listdir(p(DATA, "backups"))) if os.path.isdir(p(DATA, "backups")) else []
        c = [x for x in c if x.endswith(".tgz")]
        if not c: die("no backups in " + p(DATA, "backups"))
        bk = p(DATA, "backups", c[-1])
    if not os.path.isfile(bk): die("no such backup: " + bk)
    pr, st = printing_now()
    if pr and not a.force: die("a print is running (%s)." % st, "wait for it to finish")
    with tarfile.open(bk) as t:
        man = json.load(t.extractfile("wm-release-manifest.json"))
        say("Backup %s: puts back %d files and removes %d files that apply added." % (os.path.basename(bk), len(man["existing"]), len(man["added"])))
        typed = os.environ.get("WMR_TEST_TYPED") or input("Type ROLLBACK to continue: ").strip()
        if typed != "ROLLBACK": say("Nothing changed."); return
        for m in t.getmembers():
            if m.name == "wm-release-manifest.json": continue
            dst = p(LIVE, m.name); ensure(os.path.dirname(dst))
            if os.path.lexists(dst): os.remove(dst)
            t.extract(m, p(DATA, "tmp-rollback"), filter="data") if sys.version_info >= (3, 12) else t.extract(m, p(DATA, "tmp-rollback"))
            shutil.move(p(DATA, "tmp-rollback", m.name), dst)
    shutil.rmtree(p(DATA, "tmp-rollback"), ignore_errors=True)
    if "iso_before" in man:
        iv = p(LIVE, "iso_version.txt")
        if man["iso_before"] is None:
            if os.path.lexists(iv): os.remove(iv)
        else: open(iv, "w").write(man["iso_before"])
        say("~/iso_version.txt put back: %s" % (live_version() or "none"))
    for r in man["added"]:
        if os.path.lexists(p(LIVE, r)): os.remove(p(LIVE, r))
    log("rollback", man["version"], backup=bk)
    say("Rolled back. Restart Klipper: sudo systemctl restart klipper")


# ---------------------------------------------------------------- MCU
def parse_ini(text):
    ver, md5 = {}, {}
    for line in text.splitlines():
        line = line.strip()
        m = re.match(r"^(version|md5)_([A-Z]+)\s*=\s*(\S+)", line)
        if m: (ver if m.group(1) == "version" else md5)[m.group(2)] = m.group(3)
    return ver, md5


def installed_mcu():
    try:
        with urllib.request.urlopen(MOONRAKER + "/printer/objects/list", timeout=4) as r:
            names = [x for x in json.load(r)["result"]["objects"] if x == "mcu" or x.startswith("mcu ")]
        q = "&".join(urllib.request.quote(n) for n in names)
        with urllib.request.urlopen(MOONRAKER + "/printer/objects/query?" + q, timeout=4) as r:
            st = json.load(r)["result"]["status"]
        v = {n: st[n].get("mcu_version") for n in names if st.get(n, {}).get("mcu_version")}
        return v or None
    except Exception:
        return None


def cmd_mcu(a):
    src = a.source; files = {}
    if os.path.isfile(src) and zipfile.is_zipfile(src):
        with zipfile.ZipFile(src) as z:
            for n in z.namelist():
                if "__MACOSX" in n or n.endswith("/"): continue
                files[os.path.basename(n)] = z.read(n)
    elif os.path.isdir(src):
        for rel, ab in listing(src).items(): files[os.path.basename(rel)] = read(ab)
    else: die("not a zip or a folder: " + src)
    if "mcu_info.ini" not in files: die("no mcu_info.ini in " + src, "give the zip from WonderMaker or its mcu_update folder")
    nv, nm = parse_ini(files["mcu_info.ini"].decode("utf-8", "replace"))
    bv, bd = baseline_dir(); ov = {}
    if bd and os.path.isfile(p(bd, "mcu_update", "mcu_info.ini")): ov, _ = parse_ini(open(p(bd, "mcu_update", "mcu_info.ini")).read())
    live = installed_mcu()
    say("MCU firmware in %s" % src)
    say("%-5s %-34s %-9s %-8s %s" % ("Part", "Version in package", "md5", "Baseline", "File"))
    flash = []
    for part in ("MCU", "THR", "EXT", "HUB", "CELL"):
        if part not in nv: say("%-5s (not in this package)" % part); continue
        b = files.get(MCU_BIN[part]); got = hashlib.md5(b).hexdigest() if b else None
        md = "missing" if not b else ("ok" if got == nm.get(part) else "BAD")
        st = "same" if ov.get(part) == nv[part] else ("new" if part in ov else "new part")
        say("%-5s %-34s %-9s %-8s %s" % (part, nv[part], md, st, MCU_BIN[part]))
        if md == "BAD": say("      md5 differs from mcu_info.ini: do NOT flash this file.")
        if st != "same" and md == "ok": flash.append(part)
    if live: say("\nInstalled now (from Klipper):"); [say("  %-12s %s" % (k, v)) for k, v in sorted(live.items())]
    else: say("\nInstalled now: not readable (Klipper is not ready or Moonraker did not answer), so no comparison with the running boards.")
    if not flash: say("\nNothing new to flash compared with the baseline."); return
    say("\nNew firmware for: " + ", ".join(flash))
    can = os.path.isdir("/sys/class/net/can0")
    if not can: say("WARNING: can0 is not up on this Pi. THR/EXT/HUB/CELL boards are flashed over CAN, so fix the CAN link first.")
    say("The mcu check never flashes. To flash: menu m or `flash --run` (guarded). WonderMaker's own commands (read their scripts first):")
    for part in flash: say("  %-4s bash ~/mcu_update/%s      # file: ~/mcu_update/%s" % (part, MCU_SCRIPT[part], MCU_BIN[part]))
    say("Steps: 1) copy the package's mcu_update folder to ~/mcu_update  2) make sure Klipper is idle  3) run the command above, one part at a time  4) restart Klipper and check the version shown by this command.")
    log("mcu", "-", source=src, new=flash)


# ---------------------------------------------------------------- log, notes, checklist
def log(action, ver, **kw):
    ensure(DATA)
    with open(p(DATA, "release-log.jsonl"), "a") as f:
        f.write(json.dumps({"time": time.strftime("%Y-%m-%d %H:%M:%S"), "action": action, "version": ver, "tool": TOOL_VERSION, **kw}) + "\n")


def cmd_log(a):
    f = p(DATA, "release-log.jsonl")
    if not os.path.isfile(f): say("No history yet."); return
    for line in open(f):
        d = json.loads(line); t = d.pop("time"); ac = d.pop("action"); v = d.pop("version"); d.pop("tool", None)
        say("%s  %-14s %-8s %s" % (t, ac, v, " ".join("%s=%s" % kv for kv in d.items())))


def cmd_status(a):
    bd_ = p(DATA, "baseline")
    bl = sorted((x for x in os.listdir(bd_) if os.path.isdir(p(bd_, x)) and re.match(r"^\d+(\.\d+)+$", x)), key=vkey) if os.path.isdir(bd_) else []
    say("Tool version: " + TOOL_VERSION); say("Data folder:  " + DATA); say("Live files:   " + LIVE)
    say("Baselines:    " + (", ".join(bl) if bl else "none (run init-baseline --from-board while the board has the old version)"))
    rd = p(DATA, "releases")
    say("Releases:     " + (", ".join(sorted(os.listdir(rd))) if os.path.isdir(rd) and os.listdir(rd) else "none fetched"))
    iv = p(LIVE, "iso_version.txt")
    if os.path.isfile(iv): say("This machine's iso_version.txt says: " + (board_version(open(iv).read()) or "?"))
    else: say("This machine has no ~/iso_version.txt (the installer puts it there; apply writes it).")
    if bl and live_version() and live_version() != bl[-1]: say("Note: iso_version.txt (%s) differs from your newest baseline (%s)." % (live_version(), bl[-1]))
    if os.path.isdir(p(DATA, "backups")): say("Backups:       %d in %s" % (len(os.listdir(p(DATA, "backups"))), p(DATA, "backups")))
    for n, st in rpi_cfg_state(): say("Pi's own file: %s: %s   (not from WonderMaker; updates never change it)" % (n, st))
    rc, out = pid_cfg_run()
    if rc == 0: say("PID settings:  ok (where Klipper's SAVE_CONFIG can store a PID result)")
    elif rc == 1: say("PID settings:  PROBLEM (python3 wm_release.py pid-cfg --fix repairs it):"); [say("    " + x) for x in out]
    else: say("PID settings:  not checked (%s)" % out[0])


def cmd_pid_cfg(a):
    """checks where the PID settings (control, pid_Kp, pid_Ki, pid_Kd) of the hotends, the bed and the chamber heater live; --fix moves them into printer.cfg"""
    rc, out = pid_cfg_run()
    if rc is None: die(out[0], "run it from the wm-ultra-rpi repository, on the Pi")
    for x in out: say(x)
    if rc == 0: say("Nothing to fix."); return
    if not a.fix: say("\nTo repair: python3 wm_release.py pid-cfg --fix   (a copy of every changed file is kept as <file>.wm-before-pidcfg-<time>)"); return
    pr, st = printing_now()
    if pr and not a.force: die("a print is running (%s)." % st, "wait for it to finish")
    rc, out = pid_cfg_run(fix=True)
    for x in out: say(x)
    log("pid-cfg", "fix", result=rc)
    say("Restart Klipper to use it: sudo systemctl restart klipper. After that PID results can be saved.")


BASE_CHECKS = ["Klipper reaches 'ready' with no error in Fluidd", "All toolheads, hub, load cell and extruder boards show up (no 'Unable to open CAN port')",
               "Homing X Y Z", "Bed heats; every nozzle heats and the temperatures read sensible", "Fans and chamber heater respond",
               "Tool change T0 -> T1 -> T2 -> T3 and back, no crash, wipe works", "Probe / bed mesh runs; the saved mesh loads",
               "Nozzle offsets still right (a short two-colour test print)", "Pause, resume and cancel", "Power-loss recovery marker (plr) still works",
               "Screen (KlipperScreen / ZR Tools) opens and shows temperatures", "Pi calibration macros are still there: WM_CAL_HELP in Fluidd lists them (rpi-cfg/wm_calibration.cfg)", "PID settings: python3 wm_release.py pid-cfg says OK (otherwise SAVE_CONFIG cannot store a PID result)", "Run: ./installer.sh --doctor and --check"]
KEY_CHECKS = [("macros", "Macros changed: dry-run START_PRINT / PRINT_END with a real file; check the purge line"), ("offset", "Offset files changed: redo or at least verify XY/Z offsets for every tool"),
              ("change_", "Tool-change files changed: watch the first 3 tool changes closely, hand on the stop"), ("load_cell", "Load cell config changed: test the probe 5 times in one spot"),
              ("hub", "Hub config changed: filament load/unload on each path"), ("extruder", "Extruder config changed: check rotation distance with a 100 mm extrusion"),
              ("moonraker", "Moonraker changed: Fluidd opens, history and timelapse still work"), ("klippy", "Klipper core changed: re-run input shaper and PID before real prints")]


def cmd_checklist(a):
    items = list(BASE_CHECKS)
    try:
        _, B, N, L, plan = plan_for(a.version)
        names = " ".join(r for r, (c, _) in plan.items() if c in ("TAKE", "ADD", "MERGE", "CONFLICT", "PROTECTED")).lower()
        items += [t for k, t in KEY_CHECKS if k in names]
    except SystemExit: pass
    ensure(p(DATA, "notes")); f = p(DATA, "notes", "%s-checklist.md" % a.version)
    open(f, "w").write("# Test list after WonderMaker %s\n\n" % a.version + "\n".join("- [ ] " + x for x in items) + "\n")
    say(open(f).read()); say("Saved: " + f)


def cmd_notes(a):
    ensure(p(DATA, "notes")); f = p(DATA, "notes", "%s-notes.md" % a.version)
    if not os.path.isfile(f): open(f, "w").write("# My notes for WonderMaker %s\n\n" % a.version)
    if a.add: open(f, "a").write("- %s  %s\n" % (time.strftime("%Y-%m-%d"), a.add))
    say(open(f).read()); say("File: " + f)


def board_system_version(host):
    r = subprocess.run(ssh_base(host) + ["cat ~/iso_version.txt"], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return board_version(r.stdout) if r.returncode == 0 else None


def step(n, total, text): say("\n[%d/%d] %s" % (n, total, text))


_WIKI = {}
def wiki_latest(timeout=6):
    """(newest published System version, all versions listed) from WonderMaker's page; (None, []) if the page cannot be read"""
    if "r" in _WIKI: return _WIKI["r"]
    r = (None, [])
    try:
        req = urllib.request.Request(wiki_url(), headers={"User-Agent": "wm_release/" + TOOL_VERSION})
        with urllib.request.urlopen(req, timeout=timeout) as f: html = f.read().decode("utf-8", "replace")
        vs = sorted(set(re.findall(r"tm_t1_soc\(?(\d+(?:\.\d+)+)\)?\.zip", html, re.I)), key=vkey)
        if vs: r = (vs[-1], vs)
    except Exception: pass
    _WIKI["r"] = r
    return r


def known_versions():
    return sorted(set(versions("baseline") + versions("releases")), key=vkey)


def wiki_line(board_ver=None):
    """one line saying whether WonderMaker has published something newer than what you have; None when the page cannot be read"""
    lat, _ = wiki_latest()
    if not lat: return None
    have = board_ver or live_version() or (known_versions() or [None])[-1]
    if not have: return "WonderMaker's newest published version is %s." % lat
    if vkey(lat) > vkey(have): return "NEW: WonderMaker published %s (you have %s). Get it with:  python3 wm_release.py fetch --from-web   (or menu option w), then diff and apply." % (lat, have)
    return "WonderMaker's newest published version is %s - you have %s, up to date." % (lat, have)


def cmd_check(a):
    """ask WonderMaker's firmware page for the newest published System version and compare (nothing is downloaded or changed)"""
    lat, vs = wiki_latest(10)
    if not lat: die("could not read " + wiki_url(), "check the internet connection; the page layout may also have changed")
    say("WonderMaker published: " + ", ".join(vs))
    say("Newest published:      " + lat)
    kv = known_versions()
    say("Your baselines/fetched releases: " + (", ".join(kv) if kv else "none"))
    say(wiki_line())


def cmd_all(a):
    """every needed step, in order; nothing changes until you type APPLY. First choose where the update comes from."""
    src = (getattr(a, "source", None) or os.environ.get("WMR_SOURCE")
           or ask("Update from the old screen board, or WonderMaker's website online? (board/web)", "web")).strip().lower()
    if src.startswith("w"): return _all_web(a)
    return _all_board(a)


def _all_board(a):
    """one-shot update by reading the old WonderMaker screen board over SSH"""
    saved = os.environ.get("WMR_BOARD_HOST", "") or conf_get("board_host")
    host = ask("Board address (the WonderMaker screen board's IP; Enter keeps the one shown)", saved)
    if not host: die("which board?", "type the screen board's IP address")
    if host != conf_get("board_host"): conf_set("board_host", host)
    wl = wiki_line()
    if wl: say("\n  " + wl)
    else: say("\n  (WonderMaker's firmware page could not be read; skipping the new-version check.)")
    step(1, 6, "Logging in to the board %s" % host)
    ssh_base(host)                                   # asks for user name and password if a login is needed
    say("  Logged in. The board is only read, never changed.")
    step(2, 6, "Which WonderMaker System version does the board run?")
    bv = board_system_version(host)
    if not bv: die("the board's iso_version.txt has no System version.", "use the single steps and give --version")
    bl = versions("baseline"); newest = bl[-1] if bl else None
    lat, _ = wiki_latest()
    if lat and vkey(lat) > vkey(bv): say("  Note: WonderMaker has published %s; the board is behind." % lat)
    say("  Board runs System %s.  Baselines saved: %s" % (bv, ", ".join(bl) if bl else "none"))
    if newest is None:
        step(3, 6, "Saving the board as it is now (%s) as the baseline" % bv)
        say("  Do this only while the board still has the OLD version. Then update the board with WonderMaker's own updater.")
        if ask("Save it? (y/n)", "y").lower().startswith("y"):
            cmd_init_baseline(argparse.Namespace(from_board=host, from_dir=None, from_soc=None, from_web=None, from_archive=None, src=None, version=None, force=False))
        say("\nNext: update the board with WonderMaker's updater, then choose this option again.")
        return
    if bv in bl and vkey(bv) == vkey(newest):
        say("\nThe board still runs %s, the same as your newest baseline. There is nothing new to bring over." % bv)
        say("Update the board with WonderMaker's updater first, then choose this option again.")
        return
    if vkey(bv) < vkey(newest):
        say("\nThe board (%s) is OLDER than your baseline %s. Nothing to do." % (bv, newest)); return
    step(3, 6, "Fetching System %s from the board (read only)" % bv)
    if bv in versions("releases"): say("  Already fetched; using it.")
    else: cmd_fetch(argparse.Namespace(board=host, host=host, from_dir=None, from_soc=None, from_web=None, from_archive=None, version=None))
    step(4, 6, "Comparing %s with %s and with your live files" % (bv, newest))
    cmd_diff(argparse.Namespace(version=bv))
    mcu = p(DATA, "releases", bv, "mcu_update")
    if os.path.isfile(p(mcu, "mcu_info.ini")):
        step(5, 6, "MCU firmware check (never flashes)")
        cmd_mcu(argparse.Namespace(source=mcu))
    else: step(5, 6, "MCU firmware: no mcu_info.ini in this release, skipped")
    step(6, 6, "What would be applied")
    cmd_apply(argparse.Namespace(version=bv, apply=False, force=False))
    if ask("Apply it now? Type yes to go on (a backup is made first)", "no").lower() == "yes":
        cmd_apply(argparse.Namespace(version=bv, apply=True, force=False))
        cmd_checklist(argparse.Namespace(version=bv))
        if ask("When it works for you, keep %s as the next baseline? (y/n)" % bv, "n").lower().startswith("y"):
            cmd_promote(argparse.Namespace(version=bv))
        else: say("  Later: menu 9, or: python3 wm_release.py promote %s" % bv)
    else: say("  Nothing applied. Run this option again, or menu 6, when you are ready.")


def _all_web(a):
    """one-shot online update straight from WonderMaker's firmware page (no screen board)"""
    lat, _ = wiki_latest()
    if not lat: die("WonderMaker's firmware page could not be read.",
                    "check the Pi's internet, or use the board path, or 'fetch --from-soc FILE'")
    bl = versions("baseline"); newest = bl[-1] if bl else None
    inst = live_version()
    say("\n  Newest published System version: %s.  This machine (iso_version.txt): %s.  Baselines saved: %s" % (lat, inst or "unknown", ", ".join(bl) if bl else "none"))
    if inst and (newest is None or vkey(inst) > vkey(newest)):
        step(1, 4, "Baseline for the version this machine says it has (%s)" % inst)
        say("  The tool needs the files of %s as the starting point so your own changes are kept." % inst)
        if ask("Record %s as the baseline? (y/n)" % inst, "y").lower().startswith("y"):
            src = dict(from_archive=inst, from_web=None) if inst in archived_versions() else dict(from_archive=None, from_web=inst)
            cmd_init_baseline(argparse.Namespace(from_board=None, from_dir=None, from_soc=None, src=None, version=None, force=False, **src))
            bl = versions("baseline"); newest = bl[-1] if bl else None
        else: return
    elif inst and newest and inst != newest:
        say("  Note: iso_version.txt (%s) is older than your newest baseline (%s)." % (inst, newest))
    if newest is None:
        step(1, 4, "No baseline yet")
        say("  To merge an update without losing your changes, the tool needs the version you had BEFORE, as a baseline.")
        say("  This machine has no ~/iso_version.txt, so I will assume it matches the current published version (%s)." % lat)
        if ask("Record %s as the baseline? (y/n)" % lat, "y").lower().startswith("y"):
            cmd_init_baseline(argparse.Namespace(from_board=None, from_dir=None, from_soc=None, from_web=lat, from_archive=None, src=None, version=None, force=False))
            write_live_version(lat)
            say("\nBaseline %s saved and ~/iso_version.txt set to System_%s. When WonderMaker publishes a newer version, run this again." % (lat, lat))
        return
    if vkey(lat) <= vkey(inst or newest):
        say("\nUp to date: newest published is %s and you have %s. Nothing to bring over." % (lat, inst or newest)); return
    step(1, 4, "Downloading System %s from WonderMaker (kept in the firmware archive)" % lat)
    if lat in versions("releases"): say("  Already downloaded; using it.")
    else: cmd_fetch(argparse.Namespace(board=None, host=None, from_dir=None, from_soc=None, from_web=lat, from_archive=None, version=None))
    step(2, 4, "Comparing %s with baseline %s and your live files" % (lat, newest))
    cmd_diff(argparse.Namespace(version=lat))
    mcu = p(DATA, "releases", lat, "mcu_update")
    if os.path.isfile(p(mcu, "mcu_info.ini")):
        step(3, 4, "MCU firmware check (never flashes here; menu m flashes, guarded)")
        cmd_mcu(argparse.Namespace(source=mcu))
    else: step(3, 4, "MCU firmware: none in this release, skipped")
    step(4, 4, "What would be applied")
    cmd_apply(argparse.Namespace(version=lat, apply=False, force=False))
    if ask("Apply it now? Type yes to go on (a backup is made first)", "no").lower() == "yes":
        cmd_apply(argparse.Namespace(version=lat, apply=True, force=False))
        cmd_checklist(argparse.Namespace(version=lat))
        if ask("When it works, keep %s as the next baseline? (y/n)" % lat, "y").lower().startswith("y"):
            cmd_promote(argparse.Namespace(version=lat))
        else: say("  Later: menu 9, or: python3 wm_release.py promote %s" % lat)
    else: say("  Nothing applied. Run this again, or menu 6, when you are ready.")


def versions(kind):
    d = p(DATA, kind)
    return sorted((x for x in os.listdir(d) if os.path.isdir(p(d, x)) and re.match(r"^\d+(\.\d+)+$", x)), key=vkey) if os.path.isdir(d) else []


def ask(q, default=""):
    try: r = input("  %s%s: " % (q, " [%s]" % default if default else "")).strip()
    except EOFError: raise SystemExit(0)
    return r or default


def pick_release(default_latest=True):
    rs = versions("releases")
    if not rs: say("  No release is fetched yet: use step 2 first."); return None
    return ask("Which release", rs[-1]) if len(rs) > 1 else rs[0]


def menu_status():
    bl, rs = versions("baseline"), versions("releases")
    lg = p(DATA, "release-log.jsonl")
    last = ""
    if os.path.isfile(lg):
        try: d = json.loads(open(lg).read().strip().splitlines()[-1]); last = "%s %s %s" % (d["time"], d["action"], d["version"])
        except (ValueError, IndexError): pass
    host = os.environ.get("WMR_BOARD_HOST", "") or conf_get("board_host")
    say("\nWonderMaker release tool %s" % TOOL_VERSION)
    say("  This machine (iso_version.txt): " + (live_version() or "none (~/iso_version.txt missing)"))
    say("  Baseline (version before):  " + (", ".join(bl) if bl else "none yet -> choose 1 now, BEFORE you update the board"))
    say("  Fetched new version:        " + (", ".join(rs) if rs else "none yet -> choose 1 again after you updated the board"))
    say("  Board address:              " + (host or "not set (choose 1 or s)"))
    say("  Last action:                " + (last or "none"))
    wl = wiki_line()
    say("  WonderMaker page:           " + (wl or "could not be read (offline?)"))


def cmd_menu(a):
    while True:
        menu_status()
        say("""
   1) ALL STEPS  - asks first: old screen board, or WonderMaker website; then does the rest
   ---- or one step at a time ----
   2) Save the baseline from the board        (before you update the board)
   3) Fetch the new version from the board    (after you updated it)
   f) Open a TM_T1_SOC file on the Pi         (decrypt it here; no factory board needed)
   w) Download the newest from WonderMaker    (gets the SOC from their website, then decrypts it here)
   a) Saved firmware                          (reinstall or downgrade from a kept copy, offline)
   4) Show the differences                    (read only, saves a report)
   v) Compare two versions                    (read only: what WonderMaker changed between them)
   5) Check MCU firmware                      (never flashes)
   6) Apply the new version                   (plan first; backup; you type APPLY)
   m) Flash MCU firmware                      (guarded; writes to the boards; you type FLASH)
   7) Test list and my notes
   8) Roll back the last apply
   9) Keep this version as the next baseline  (after it works)
   c) Check for a new WonderMaker version     (reads their firmware page)
   x) Clean up                                (delete every file this tool created; you type DELETE)
   g) Settings                                (decrypt key, firmware page URL, board)
   h) History
   s) Board address and user name
   0) Exit""")
        c = ask("Choose")
        try:
            if c == "0": return
            elif c == "1": cmd_all(argparse.Namespace())
            elif c == "c": cmd_check(argparse.Namespace())
            elif c == "s":
                h = ask("Board address (the screen board's IP)", conf_get("board_host"))
                if h: conf_set("board_host", h)
                u = ask("Board user name", conf_get("board_user") or "t13dp")
                if u: conf_set("board_user", u); say("  Saved. The password is never saved: it is asked each time you log in.")
            elif c == "2":
                say("  Reads the board's files as they are NOW. Do this only while the board still has the old version.")
                if ask("Continue? (y/n)", "y").lower().startswith("y"): cmd_init_baseline(argparse.Namespace(from_board="", from_dir=None, from_soc=None, from_web=None, from_archive=None, src=None, version=None, force=False))
            elif c == "3":
                cmd_fetch(argparse.Namespace(board="", host=None, from_dir=None, from_soc=None, from_web=None, from_archive=None, version=None))
            elif c == "f":
                soc = ask("Path to the TM_T1_SOC file on the Pi")
                if soc: cmd_fetch(argparse.Namespace(board=None, host=None, from_dir=None, from_soc=os.path.expanduser(soc), from_web=None, from_archive=None, version=None))
            elif c == "w":
                v = ask("Version to download (Enter for the newest on WonderMaker's page)")
                cmd_fetch(argparse.Namespace(board=None, host=None, from_dir=None, from_soc=None, from_web=v or "", from_archive=None, version=None))
            elif c == "a":
                cmd_firmware(argparse.Namespace())
                av = archived_versions()
                if av:
                    v = ask("Version to reinstall/downgrade from the archive (Enter to skip)", "")
                    if v: cmd_fetch(argparse.Namespace(board=None, host=None, from_dir=None, from_soc=None, from_web=None, from_archive=v, version=None))
            elif c == "v":
                rs = versions("releases")
                if len(rs) < 2: say("  Need two fetched versions to compare (have: %s). Fetch another with w or a." % (", ".join(rs) or "none")); continue
                o = ask("Older version", rs[-2]); n = ask("Newer version", rs[-1])
                if o and n: cmd_compare(argparse.Namespace(old=o, new=n))
            elif c == "g": cmd_settings(argparse.Namespace())
            elif c == "x":
                cmd_clean(argparse.Namespace(run=False, keep_firmware=False, keep_backups=False))
                if ask("Delete them for real now? (y/n)", "n").lower().startswith("y"):
                    cmd_clean(argparse.Namespace(run=True, keep_firmware=ask("Keep the firmware archive? (y/n)", "n").lower().startswith("y"), keep_backups=False))
            elif c == "m":
                t = ask("Which board? (main/thr/ext/hub/cell)", "main")
                cmd_flash(argparse.Namespace(target=t, run=False, force=False))
                if ask("Flash for real now? (y/n)", "n").lower().startswith("y"):
                    cmd_flash(argparse.Namespace(target=t, run=True, force=False))
            elif c in ("4", "6", "7", "9"):
                v = pick_release()
                if not v: continue
                if c == "4": cmd_diff(argparse.Namespace(version=v))
                elif c == "6":
                    cmd_apply(argparse.Namespace(version=v, apply=False, force=False))
                    if ask("Apply it now? Type yes to go on", "no").lower() == "yes": cmd_apply(argparse.Namespace(version=v, apply=True, force=False))
                elif c == "7":
                    cmd_checklist(argparse.Namespace(version=v))
                    n = ask("A note to save (Enter to skip)")
                    if n: cmd_notes(argparse.Namespace(version=v, add=n))
                elif c == "9": cmd_promote(argparse.Namespace(version=v))
            elif c == "5":
                rs = versions("releases"); dflt = p(DATA, "releases", rs[-1], "mcu_update") if rs else ""
                src = ask("Folder or zip with mcu_info.ini", dflt)
                if src: cmd_mcu(argparse.Namespace(source=os.path.expanduser(src)))
            elif c == "8": cmd_rollback(argparse.Namespace(backup=None, force=False))
            elif c == "h": cmd_log(argparse.Namespace())
            else: say("  Choose a number from the list.")
        except SystemExit as e:
            if e.code not in (0, None): say("  (stopped; nothing else was done)")
        ask("Press Enter to go on")


def main():
    ap = argparse.ArgumentParser(description="Private WonderMaker release tool", formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("--version", action="version", version="wm_release.py %s" % TOOL_VERSION)
    sp = ap.add_subparsers(dest="cmd")
    def add(n, fn, *args):
        s = sp.add_parser(n); s.set_defaults(fn=fn)
        for x in args: s.add_argument(*x[0], **x[1])
        return s
    add("status", cmd_status)
    add("menu", cmd_menu)
    add("check", cmd_check)
    add("pid-cfg", cmd_pid_cfg, (["--fix"], {"action": "store_true"}), (["--force"], {"action": "store_true"}))
    add("all", cmd_all, (["--source"], {"choices": ["board", "web"]}))
    add("init-baseline", cmd_init_baseline, (["--src"], {}), (["--version"], {}), (["--force"], {"action": "store_true"}),
        (["--from-board"], {"nargs": "?", "const": ""}), (["--from-dir"], {}), (["--from-soc"], {}),
        (["--from-web"], {"nargs": "?", "const": ""}), (["--from-archive"], {}))
    add("promote", cmd_promote, (["version"], {}))
    add("fetch", cmd_fetch, (["--from-board"], {"nargs": "?", "const": "", "dest": "board"}), (["--from-dir"], {}),
        (["--from-soc"], {}), (["--from-web"], {"nargs": "?", "const": ""}), (["--from-archive"], {}), (["--version"], {}))
    add("diff", cmd_diff, (["version"], {}))
    add("compare", cmd_compare, (["old"], {}), (["new"], {}))
    add("firmware", cmd_firmware)
    add("settings", cmd_settings)
    add("clean", cmd_clean, (["--run"], {"action": "store_true"}), (["--keep-firmware"], {"action": "store_true"}), (["--keep-backups"], {"action": "store_true"}))
    add("flash", cmd_flash, (["target"], {"nargs": "?"}), (["--run"], {"action": "store_true"}), (["--force"], {"action": "store_true"}))
    add("mcu", cmd_mcu, (["source"], {}))
    add("apply", cmd_apply, (["version"], {}), (["--apply"], {"action": "store_true"}), (["--force"], {"action": "store_true"}))
    add("rollback", cmd_rollback, (["backup"], {"nargs": "?"}), (["--force"], {"action": "store_true"}))
    add("checklist", cmd_checklist, (["version"], {}))
    add("notes", cmd_notes, (["version"], {}), (["--add"], {}))
    add("log", cmd_log)
    a = ap.parse_args()
    if a.cmd is None: a.fn = cmd_menu; a.cmd = "menu"   # no command: the menu
    if a.cmd == "fetch":
        if (a.board is None and not a.from_dir and not getattr(a, "from_soc", None)
                and getattr(a, "from_web", None) is None and not getattr(a, "from_archive", None)):
            die("say where from.", "fetch --from-web  or  --from-soc FILE  or  --from-archive VER  or  --from-board  or  --from-dir DIR")
        a.host = a.board or None
    a.fn(a)


if __name__ == "__main__":
    main()
