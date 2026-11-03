#!/bin/bash
# =============================================================================
# Pre-check for installing KlipperScreen on the WonderMaker screen board.   Run it on your Mac (or any computer with ssh).
# It logs in to the screen board, runs read-only checks and tells you READY or NOT READY. It does not install or stop anything.
# The only thing it writes on the board is apt's package list cache (apt-get update). Nothing else.
#
#   bash scripts/screen_board_precheck.sh BOARD_IP --pi wmpi.local
#   Options: --user t13dp   --backup (also stream a backup of the board's config to this computer)   --local-test (developer: run the checks here)
# Output: screen_board_precheck_<time>.txt next to where you run it (private IPs, MACs and passwords are removed; safe to send).
# =============================================================================
set -u
BOARD=""; PI="wmpi.local"; USER_NAME="t13dp"; BACKUP=0; LOCAL=0
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
while [ $# -gt 0 ]; do
    case "$1" in
        --pi) PI="${2:-}"; shift ;; --user) USER_NAME="${2:-}"; shift ;; --backup) BACKUP=1 ;; --local-test) LOCAL=1 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
        *) BOARD="$1" ;;
    esac; shift
done
[ "$LOCAL" = 1 ] || [ -n "$BOARD" ] || { echo "Usage: bash scripts/screen_board_precheck.sh BOARD_IP --pi wmpi.local"; exit 1; }
TS="$(date +%Y%m%d-%H%M%S)"; REPORT="$PWD/screen_board_precheck_$TS.txt"; RAW="$(mktemp)"
APT_PKGS="$(sed -n 's/^APT_PKGS="\(.*\)"$/\1/p' "$SCRIPT_DIR/screen_board.sh")"
SERVICES="$(sed -n 's/^SERVICES=(\(.*\))$/\1/p' "$SCRIPT_DIR/screen_board.sh")"
[ -n "$APT_PKGS" ] && [ -n "$SERVICES" ] || { echo "Could not read the package/service lists from screen_board.sh (run this from a full clone of the repository)."; exit 1; }

remote_script() { cat <<'REMOTE'
PASS=0; WARN=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "[PASS] $1"; }
warn() { WARN=$((WARN+1)); echo "[WARN] $1"; [ -n "${2:-}" ] && echo "       -> $2"; }
bad()  { FAIL=$((FAIL+1)); echo "[FAIL] $1"; [ -n "${2:-}" ] && echo "       -> $2"; }
info() { echo "[INFO] $1"; }
sec()  { echo; echo "===== $1 ====="; }
S() { if [ "$(id -u)" = 0 ]; then "$@"; elif sudo -n true 2>/dev/null; then sudo -n "$@"; else printf '%s\n' "${PW:-}" | sudo -S -p '' "$@"; fi; }
curlq() { curl -fsS -m "${2:-8}" "$1" 2>/dev/null; }

sec "1. Who and what"
info "user=$(id -un) host=$(hostname) $(uname -srm)"
[ "$(id -un)" = t13dp ] && ok "logged in as t13dp" || warn "logged in as $(id -un), the installer needs t13dp"
. /etc/os-release 2>/dev/null; [ "${VERSION_ID:-}" = 11 ] && ok "Debian 11 (${PRETTY_NAME:-})" || bad "not Debian 11 (${PRETTY_NAME:-unknown})" "screen_board.sh is written for the WonderMaker image"
[ "$(uname -m)" = aarch64 ] && ok "64-bit ARM" || bad "architecture is $(uname -m)"
S true 2>/dev/null && ok "sudo works" || bad "sudo does not work with that password" "re-run and type the board's password"
info "model: $(tr '\0' ' ' </proc/device-tree/model 2>/dev/null)"; info "image: $(cat ~/iso_version.txt 2>/dev/null | head -n1)"

sec "2. Display, touch, console"
[ -e /dev/fb0 ] && ok "/dev/fb0 exists ($(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null))" || bad "/dev/fb0 missing" "the screen is not initialised by the kernel"
ls /dev/dri/card* >/dev/null 2>&1 && ok "DRM device present ($(ls /dev/dri | tr '\n' ' '))" || warn "no /dev/dri: the X modesetting driver cannot work, the installer will fall back to fbdev"
for f in /sys/class/drm/card*-*/status; do [ -r "$f" ] && info "$f = $(cat $f) modes: $(head -n3 $(dirname $f)/modes 2>/dev/null | tr '\n' ' ')"; done
[ -e /dev/tty0 ] && ok "/dev/tty0 exists (KlipperScreen's service needs it)" || bad "/dev/tty0 missing" "KlipperScreen's service would not start; tell me, I will change the service"
if grep -qi goodix /proc/bus/input/devices 2>/dev/null; then ok "Goodix touch device is registered"; else
  if S dmesg 2>/dev/null | grep -qi goodix; then warn "Goodix seen in dmesg but not in /proc/bus/input/devices" "the factory app may be holding it, or the driver failed to bind"; else bad "no Goodix touch device" "the touch driver did not load"; fi; fi
for e in /sys/class/input/event*; do [ -e "$e" ] && info "$(basename $e): $(cat $e/device/name 2>/dev/null) touch=$(udevadm info -q property -p $e 2>/dev/null | grep -c 'ID_INPUT_TOUCHSCREEN=1')"; done
ls /sys/class/backlight >/dev/null 2>&1 && [ -n "$(ls /sys/class/backlight 2>/dev/null)" ] && ok "backlight: $(ls /sys/class/backlight | tr '\n' ' ')" || warn "no /sys/class/backlight" "brightness control in KlipperScreen will not work until I add it"

sec "3. Resources"
free_mb=$(df -Pm / | awk 'NR==2{print $4}'); [ "${free_mb:-0}" -gt 1500 ] && ok "disk free ${free_mb} MB" || bad "only ${free_mb} MB free on /" "need 1500+ MB"
mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo); swap=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
[ "${mem:-0}" -ge 900 ] && ok "RAM ${mem} MB, swap ${swap} MB" || { [ "${swap:-0}" -ge 512 ] && warn "RAM ${mem} MB (swap ${swap} MB)" "compiling PyGObject will be slow but should work with swap" || bad "RAM ${mem} MB and little swap" "the Python build may run out of memory; add a swap file first"; }
t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null); [ -n "$t" ] && info "CPU temperature $((t/1000)) C"; info "load: $(cut -d' ' -f1-3 /proc/loadavg)"
for c in python3 gcc make git curl; do command -v $c >/dev/null 2>&1 && ok "$c present" || { [ "$c" = git ] || [ "$c" = curl ] && bad "$c missing" "needed to download KlipperScreen" || warn "$c missing" "apt will install it"; }; done
info "python3: $(python3 --version 2>&1)"; python3 -c 'import sys; sys.exit(0 if sys.version_info>=(3,9) else 1)' && ok "Python 3.9 or newer" || bad "Python older than 3.9"
python3 -c 'import venv, ensurepip' 2>/dev/null && ok "python3-venv works" || warn "python3-venv not installed" "apt will install it"
[ -d ~/KlipperScreen ] && warn "~/KlipperScreen already exists" "the script will reuse it and check out the pinned commit"

sec "4. Factory software that will be stopped"
for u in $SERVICES KlipperScreen; do
  if systemctl cat $u.service >/dev/null 2>&1; then info "$u: $(systemctl is-enabled $u 2>/dev/null), $(systemctl is-active $u 2>/dev/null)"; fi; done
systemctl is-active --quiet makerbase-client 2>/dev/null && ok "makerbase-client (factory screen app) is running, it will be stopped by the installer" || warn "makerbase-client is not running" "the screen may already be in another state"
systemctl cat KlipperScreen.service >/dev/null 2>&1 && warn "a KlipperScreen service already exists"
st=$(curlq http://127.0.0.1:7125/printer/objects/query?print_stats 5 | tr -d ' \n'); case "$st" in *'"state":"printing"'*|*'"state":"paused"'*) bad "the board's own printer is printing/paused" "wait until it is finished";; *) ok "no print running on the board";; esac
for f in /usr/local/sbin/wm-factory-restore /etc/sudoers.d/wm-factory-restore; do [ -e $f ] && info "exists already: $f"; done

sec "5. X server (WonderMaker holds its own build)"
dpkg -s xserver-xorg-core 2>/dev/null | grep -E '^(Status|Version)' | tr '\n' ' ' | sed 's/^/[INFO] xserver-xorg-core: /'; echo
dpkg --audit 2>/dev/null | grep -q . && bad "dpkg reports broken packages" "run: sudo dpkg --audit" || ok "dpkg state is clean"
for p in xserver-xorg-core xserver-common xserver-xorg-legacy; do h=$(apt-mark showhold 2>/dev/null | grep -c "^$p$"); [ "$h" = 1 ] && info "held: $p"; done
dpkg -s xserver-xorg-legacy 2>/dev/null | grep -q 'ok installed' && ok "xserver-xorg-legacy installed" || { d=$(ls /packages/xserver/xserver-xorg-legacy_*_arm64.deb 2>/dev/null | grep -v dbgsym | head -n1); [ -n "$d" ] && ok "xserver-xorg-legacy not installed, but WonderMaker's package is available: $(basename $d)" || bad "no xserver-xorg-legacy and none in /packages/xserver" "X would not start for a normal user"; }
command -v Xorg >/dev/null && ok "Xorg present" || bad "no Xorg"; command -v xinit >/dev/null && ok "xinit present" || info "xinit will be installed by apt"
info "Xwrapper.config: $(grep -v '^#' /etc/X11/Xwrapper.config 2>/dev/null | tr '\n' ' ')"; ls /etc/X11/xorg.conf.d 2>/dev/null | sed 's/^/[INFO] xorg.conf.d: /'
[ -f /etc/X11/xorg.conf.d/20-modesetting.conf ] && ok "Rockchip modesetting config present" || warn "no 20-modesetting.conf"

sec "6. Network: Pi, apt, GitHub, PyPI"
getent hosts "$PI_HOST" >/dev/null 2>&1 || echo "$PI_HOST" | grep -qE '^[0-9.]+$' && ok "the Pi name resolves ($PI_HOST)" || warn "cannot resolve $PI_HOST from the board" "use the Pi's IP address with --pi"
ping -c1 -W3 "$PI_HOST" >/dev/null 2>&1 && ok "ping to the Pi works" || warn "no ping reply from the Pi" "may just be blocked; the Moonraker test below decides"
inf=$(curlq "http://$PI_HOST:7125/server/info" 8)
echo "$inf" | grep -q '"klippy_connected": *true' && ok "the Pi's Moonraker answers and Klipper is connected" || { echo "$inf" | grep -q klippy && bad "Moonraker answers but Klipper is not connected" "start Klipper on the Pi (./installer.sh --first-start)" || bad "the Pi's Moonraker does not answer from this board" "check the Pi is on, the address, and trusted_clients in the Pi's moonraker.conf"; }
pst=$(curlq "http://$PI_HOST:7125/printer/objects/query?print_stats" 6 | tr -d ' \n'); case "$pst" in *'"state":"printing"'*|*'"state":"paused"'*) bad "the Pi is printing/paused" "wait";; *'"state"'*) ok "no print running on the Pi";; esac
lst=$(curlq "http://$PI_HOST:7125/printer/objects/list" 8); echo "$lst" | grep -q 'gcode_macro ZR_' && ok "ZR Tools macros are on the Pi" || warn "ZR Tools macros not found on the Pi" "install the Pi with --screen on (or run zr_tools/install_zr_tools.sh on the Pi), else some ZR pages will not work"
echo "$lst" | grep -q 'lis2dw' && info "Pi has the LIS2DW accelerometer object"
s=$(date +%s); skew=$(( s - ${MAC_EPOCH:-$s} )); [ "${skew#-}" -lt 86400 ] && ok "board clock is within a day of your computer (${skew}s)" || bad "board clock is off by ${skew}s" "HTTPS to GitHub/PyPI will fail; set the date (sudo date -s ...) or fix NTP"
grep -q archive.debian.org /etc/apt/sources.list 2>/dev/null && ok "apt sources use archive.debian.org" || warn "apt sources do not use archive.debian.org" "the installer will switch them (keeps a copy)"
[ -f /etc/apt/apt.conf.d/99no-check-valid-until ] && ok "apt date-check override present" || warn "no 99no-check-valid-until" "the installer will create it"
for u in https://github.com https://pypi.org/simple/ https://files.pythonhosted.org http://archive.debian.org/debian/dists/bullseye/Release; do
  curl -fsS -m 10 -o /dev/null -I "$u" 2>/dev/null || curl -fsS -m 10 -o /dev/null "$u" 2>/dev/null && ok "reachable: $u" || bad "NOT reachable: $u" "the installer downloads from here"; done

sec "7. apt dry run (nothing is installed)"
if [ "${PRECHECK_NO_APT:-0}" = 1 ]; then info "skipped"; else
  S apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Check-Date=false update >/tmp/.pre_apt_up 2>&1 && ok "apt-get update works" || { bad "apt-get update failed" "$(tail -n 3 /tmp/.pre_apt_up | tr '\n' ' ')"; }
  A="-o Acquire::Check-Valid-Until=false -o Acquire::Check-Date=false"
  apt-get $A -s install --no-upgrade $APT_PKGS >/tmp/.pre_apt_sim 2>&1; rc=$?
  [ $rc = 0 ] && ok "the package set resolves ($(grep -c '^Inst' /tmp/.pre_apt_sim) packages to install)" || bad "apt cannot resolve the package set" "$(grep -E '^E:|Depends|held' /tmp/.pre_apt_sim | head -n3 | tr '\n' ' ')"
  grep -q '^Remv' /tmp/.pre_apt_sim && bad "apt would REMOVE packages: $(grep '^Remv' /tmp/.pre_apt_sim | awk '{print $2}' | tr '\n' ' ')" "do not continue until this is understood"
  grep -E '^Inst (xserver|libgl1-mesa|libegl|libgbm|mesa)' /tmp/.pre_apt_sim | head -n5 | sed 's/^/[WARN] touches graphics packages: /'
  grep -q 'held' /tmp/.pre_apt_sim && warn "apt mentions held packages" "$(grep -i held /tmp/.pre_apt_sim | head -n2 | tr '\n' ' ')"
  info "download size: $(grep -E 'Need to get' /tmp/.pre_apt_sim)"; rm -f /tmp/.pre_apt_up /tmp/.pre_apt_sim; fi

sec "8. Backup size"
sz=$(du -sm --exclude=gcodes --exclude=logs --exclude=timelapse ~/printer_data 2>/dev/null | cut -f1); info "printer_data (without gcodes/logs/timelapse): ${sz:-?} MB"
echo; echo "SUMMARY pass=$PASS warn=$WARN fail=$FAIL"
REMOTE
}

scrub() { sed -E 's/((password|passwd|token|api_?key|secret|ssid|psk)[[:space:]]*[:=][[:space:]]*).*/\1<removed>/I; s/\b(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)\b/<private-ip>/g; s/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/<mac>/g'; }

echo "WonderMaker screen board pre-check (read-only)"
PW=""
if [ "$LOCAL" = 1 ]; then
    { printf 'PI_HOST=%q\nPRECHECK_NO_APT=1\nMAC_EPOCH=%q\nAPT_PKGS=%q\nSERVICES=%q\nPW=\n' "$PI" "$(date +%s)" "$APT_PKGS" "$SERVICES"; remote_script; } | bash -s > "$RAW" 2>&1
else
    command -v ssh >/dev/null || { echo "ssh not found"; exit 1; }
    DEFAULT_PW="TM88888"
    read -r -s -p "Board sudo password [Enter = WonderMaker default]: " PW; echo; PW="${PW:-$DEFAULT_PW}"
    SSHO="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath=/tmp/wm-pre-%r@%h:%p -o ControlPersist=180"
    echo "Connecting to $USER_NAME@$BOARD (type the board's ssh password if asked)..."
    { printf 'PI_HOST=%q\nMAC_EPOCH=%q\nAPT_PKGS=%q\nSERVICES=%q\nPW=%q\n' "$PI" "$(date +%s)" "$APT_PKGS" "$SERVICES" "$PW"; remote_script; } | ssh $SSHO "$USER_NAME@$BOARD" 'bash -s' > "$RAW" 2>&1
    rc=$?; [ $rc = 0 ] || { echo "ssh failed (exit $rc):"; scrub < "$RAW" | tail -n 8; rm -f "$RAW"; exit 1; }
    if [ "$BACKUP" = 1 ]; then
        BF="$PWD/screen_board_backup_$TS.tgz"; echo "Streaming a backup of the board's config to $BF ..."
        ssh $SSHO "$USER_NAME@$BOARD" 'cd ~ && tar czf - --exclude=printer_data/gcodes --exclude=printer_data/logs --exclude=printer_data/timelapse printer_data TM_T1/bin/*.ini 2>/dev/null' > "$BF" \
            && tar tzf "$BF" >/dev/null 2>&1 && echo "[PASS] backup saved and readable: $BF ($(du -h "$BF" | cut -f1))" >> "$RAW" || echo "[FAIL] backup could not be saved" >> "$RAW"
    fi
    ssh $SSHO -O exit "$USER_NAME@$BOARD" 2>/dev/null
fi
scrub < "$RAW" > "$REPORT"; rm -f "$RAW"
cat "$REPORT"
F=$(grep -c '^\[FAIL\]' "$REPORT"); W=$(grep -c '^\[WARN\]' "$REPORT")
echo; echo "=============================================="
if [ "$F" = 0 ]; then echo "READY: no blocking problems ($W warning(s))."; else echo "NOT READY: $F blocking problem(s). Fix them or send me $REPORT."; fi
cat <<'TXT'

Still to do by hand (this script cannot do it safely):
  1. On the board: bash scripts/screen_board.sh --pi <pi> --dry-run   (read every line)
  2. Optional X test before the real install: sudo systemctl stop makerbase-client; xinit /usr/bin/xterm -- :0
     (does the screen draw, does touch move the pointer?)  then: sudo systemctl start makerbase-client
TXT
echo "Report saved (private data removed): $REPORT"
[ "$F" = 0 ]
