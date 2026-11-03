#!/bin/bash
# =============================================================================
# Pre-flight check for KlipperScreen on the WonderMaker screen board.  Run it on your MAC.
# READ-ONLY: it logs in to the screen board over SSH and only reads. It installs nothing, stops nothing, writes nothing on the
# board or the Pi (the report is saved on your Mac). Works with the stock macOS bash 3.2.
#
#   bash scripts/screen_board_preflight_mac.sh BOARD_IP [--pi PI_ADDRESS] [--user t13dp] [--with-apt-update]
#
# BOARD_IP  the screen board's IP (the original WonderMaker screen board, login t13dp / TM88888 by default)
# --pi      ignored (kept so old command lines still work); the Pi is not checked
# --xtest   ALSO try to start an X server on the board (NOT read-only: stops the factory screen app for about a minute, then starts it again; asks for the sudo password)
# --with-apt-update  also run "sudo apt-get update" on the board (only refreshes the package lists; asks for the sudo password)
# You type the SSH password once (the connection is reused).
# Result: PASS / WARN / FAIL for every check and a READY / NOT READY verdict. Send me the report file if anything is not PASS.
# =============================================================================
set -u
BOARD=""; PI=""; BUSER="t13dp"; APTUP=0; LOCAL=0; XTEST=0
KS_SHA="34610ceae31e12a10cc980e20a1dec9976f97dd4"
while [ $# -gt 0 ]; do
    case "$1" in
        --pi) PI="${2:-}"; shift ;;
        --user) BUSER="${2:-}"; shift ;;
        --with-apt-update) APTUP=1 ;;
        --xtest) XTEST=1 ;;
        --local-test) LOCAL=1 ;;                     # tests only: run the board checks on this computer instead of over SSH
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
        *) BOARD="$1" ;;
    esac
    shift
done
[ "$LOCAL" = 1 ] || [ -n "$BOARD" ] || { echo "Missing the board's IP address. Try: bash $0 <board-ip> --pi wmpi.local"; exit 1; }

REPORT="${WM_REPORT:-$HOME/Desktop/wm_screen_preflight_$(date +%Y%m%d-%H%M%S).txt}"
mkdir -p "$(dirname "$REPORT")" 2>/dev/null || REPORT="/tmp/wm_screen_preflight_$$.txt"
NPASS=0; NWARN=0; NFAIL=0; TMP="$(mktemp)"
trap 'rm -f "$TMP"; [ "$LOCAL" = 1 ] || ssh -O exit -o ControlPath="/tmp/wmpf-%r@%h" "$BUSER@$BOARD" 2>/dev/null' EXIT

C_G=$'\033[0;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[0;31m'; C_B=$'\033[0;34m'; C_N=$'\033[0m'
show() {   # status key detail
    local c="$C_N"
    case "$1" in
        PASS) c="$C_G"; NPASS=$((NPASS+1)) ;; WARN) c="$C_Y"; NWARN=$((NWARN+1)) ;; FAIL) c="$C_R"; NFAIL=$((NFAIL+1)) ;; INFO) c="$C_B" ;;
    esac
    printf '%s%-5s%s %-34s %s\n' "$c" "$1" "$C_N" "$2" "$3"
    printf '%-5s %-34s %s\n' "$1" "$2" "$3" >> "$TMP"
}
head_() { printf '\n== %s ==\n' "$1"; printf '\n== %s ==\n' "$1" >> "$TMP"; }

# ------------------------------------------------------------------ checks that run ON the board (read-only)
read -r -d '' REMOTE <<'RSH'
r() { printf '@@|%s|%s|%s\n' "$1" "$2" "$3"; }
have() { command -v "$1" >/dev/null 2>&1; }
r SECTION "On the screen board" ""
r INFO "login" "$(id -un)@$(hostname), $(uname -sr), $(uname -m)"
[ "$(id -un)" = "t13dp" ] && r PASS "user is t13dp" "" || r WARN "user is not t13dp" "the scripts expect t13dp"
. /etc/os-release 2>/dev/null
[ "${VERSION_ID:-}" = "11" ] && r PASS "Debian 11 (bullseye)" "${PRETTY_NAME:-}" || r FAIL "OS is not Debian 11" "${PRETTY_NAME:-unknown}: the installer is written for the factory image"
[ "$(uname -m)" = aarch64 ] && r PASS "64-bit ARM" "" || r FAIL "not aarch64" "$(uname -m)"
cat /home/t13dp/iso_version.txt 2>/dev/null | head -n1 | while read -r l; do r INFO "factory image" "$l"; done
pv="$(python3 -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null)"
python3 -c 'import sys;sys.exit(0 if sys.version_info>=(3,9) else 1)' 2>/dev/null && r PASS "Python >= 3.9" "$pv" || r FAIL "Python too old or missing" "${pv:-none} (KlipperScreen needs 3.9+)"
python3 -c 'import venv,ensurepip' 2>/dev/null && r PASS "python3 venv + ensurepip" "" || r WARN "python3-venv not installed yet" "the installer apt-installs it"
free_mb="$(df -Pm /home 2>/dev/null | awk 'NR==2{print $4}')"
[ "${free_mb:-0}" -gt 1500 ] && r PASS "disk space" "${free_mb} MB free" || r FAIL "disk space low" "${free_mb:-?} MB free, need > 1500 MB"
mem="$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)"; swap="$(awk '/SwapTotal/{printf "%d",$2/1024}' /proc/meminfo)"
if [ "${mem:-0}" -ge 900 ]; then r PASS "RAM" "${mem} MB (swap ${swap} MB)"
elif [ "${swap:-0}" -ge 512 ]; then r WARN "RAM is low" "${mem} MB + swap ${swap} MB: the Python build will be slow"
else
    { [ -x /sbin/mkswap ] && [ -x /sbin/swapon ] && [ "${free_mb:-0}" -gt 1800 ]; } && r WARN "RAM is low and there is no swap" "${mem} MB: the installer adds a temporary 768 MB swap file for the Python build and removes it afterwards" || r FAIL "RAM low, no swap and no room/tools to add one" "${mem} MB, ${free_mb} MB free disk"
fi
temp="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"; [ -n "$temp" ] && r INFO "CPU temperature" "$((temp/1000)) C"
r SECTION "Display and touch" ""
[ -e /dev/fb0 ] && r PASS "/dev/fb0 (framebuffer)" "$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)" || r FAIL "no /dev/fb0" "the screen is not initialised"
[ -e /dev/dri/card0 ] && r PASS "/dev/dri/card0 (needed for modesetting)" "" || r WARN "no /dev/dri/card0" "X will have to use the fbdev driver"
[ -e /dev/tty0 ] && r PASS "/dev/tty0 (virtual console)" "" || r WARN "no /dev/tty0: the kernel has no virtual console" "stock KlipperScreen service and X need a VT; run with --xtest to see whether X starts without one"
vs="$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"; case "$vs" in 800,480) r PASS "screen size 800x480" "" ;; "") : ;; *) r WARN "screen size is $vs" "expected 800,480; ZR Tools will adapt" ;; esac
ls /sys/class/backlight/* >/dev/null 2>&1 && r PASS "backlight device" "$(ls /sys/class/backlight | tr '\n' ' ')" || r WARN "no /sys/class/backlight" "screen dimming from KlipperScreen would not work"
if grep -qi goodix /proc/bus/input/devices 2>/dev/null; then r PASS "touch: Goodix GT911 found" "$(grep -i -A3 'goodix' /proc/bus/input/devices | grep -o 'event[0-9]*' | head -n1)"
else r FAIL "touch: no Goodix device in /proc/bus/input/devices" "the touch panel is not detected by the kernel"; fi
ls /sys/bus/i2c/drivers 2>/dev/null | grep -qi goodix && r PASS "goodix driver loaded" "" || r WARN "goodix driver not listed" "touch may still work (built in)"
r SECTION "X server (WonderMaker's own build is held)" ""
[ -x /usr/bin/Xorg ] && r PASS "/usr/bin/Xorg" "" || r FAIL "no Xorg" "xserver-xorg-core is missing"
for p in xserver-common xserver-xorg-core; do dpkg -s $p 2>/dev/null | grep -q "ok installed" && r PASS "$p installed" "$(dpkg -s $p | awk '/^Version/{print $2}')" || r FAIL "$p missing" ""; done
if dpkg -s xserver-xorg-legacy 2>/dev/null | grep -q "ok installed"; then r PASS "xserver-xorg-legacy installed" ""
else ls /packages/xserver/xserver-xorg-legacy_*_arm64.deb >/dev/null 2>&1 && r PASS "xserver-xorg-legacy: not installed, matching .deb is in /packages/xserver" "the installer installs it from there" || r FAIL "xserver-xorg-legacy missing and no .deb in /packages/xserver" "X cannot start for a normal user"; fi
r INFO "held packages" "$(apt-mark showhold 2>/dev/null | tr '\n' ' ')"
[ -f /etc/X11/xorg.conf.d/20-modesetting.conf ] && r PASS "Rockchip modesetting config" "" || r WARN "20-modesetting.conf missing" "X would pick a driver by itself"
dpkg -s xserver-xorg-video-fbdev 2>/dev/null | grep -q "ok installed" && r PASS "fbdev driver installed (fallback)" "" || r INFO "fbdev driver not installed yet" "the installer adds it"
r SECTION "Services" ""
for u in makerbase-client klipper moonraker nginx crowsnest makerbase-webcam janus klipper-mcu hostapd moonraker-obico octoapp; do
    if systemctl cat "$u.service" >/dev/null 2>&1; then r INFO "service $u" "$(systemctl is-enabled $u 2>/dev/null), $(systemctl is-active $u 2>/dev/null)"; fi
done
systemctl is-active --quiet makerbase-client && r PASS "factory screen app is running (will be stopped)" "" || r WARN "makerbase-client not running" "the screen may be blank or in another state"
r INFO "default boot target" "$(systemctl get-default 2>/dev/null)"
[ -d /home/t13dp/KlipperScreen ] && r WARN "~/KlipperScreen already exists" "an earlier attempt? the installer reuses it"
[ -d /home/t13dp/wm-screen-backup ] && r WARN "~/wm-screen-backup already exists" "the original saved state is kept, not overwritten"
ps=$(curl -fsS -m 4 "http://127.0.0.1:7125/printer/objects/query?print_stats" 2>/dev/null)
if echo "$ps" | grep -Eq '"state": ?"(printing|paused)"'; then r FAIL "a print is running on the board" "wait until it is done"
elif [ -n "$ps" ]; then r PASS "board: no print running" ""; else r INFO "board's Moonraker did not answer" "fine if the printer runs from the Pi"; fi
r SECTION "Permissions" ""
[ -u /usr/bin/sudo ] && r PASS "sudo is installed" "(you type the password when you run the installer; --xtest checks it works)" || r FAIL "sudo missing" "the installer needs sudo"
[ -x /usr/sbin/visudo ] && r PASS "visudo present" "" || r WARN "no visudo" "the Factory mode button would be skipped"
[ -x /sbin/mkswap ] && [ -x /usr/bin/fallocate ] && r PASS "swap tools present (mkswap, fallocate)" "" || r WARN "no mkswap/fallocate" "cannot add temporary swap"
have systemd-run && r PASS "systemd-run present" "" || r WARN "no systemd-run" "the Factory mode button would not detach"
[ -d /etc/sudoers.d ] && r PASS "/etc/sudoers.d exists" "" || r WARN "no /etc/sudoers.d" ""
r SECTION "Network from the board" ""
now=$(date +%s); skew=$(( now - ${MAC_EPOCH:-$now} )); [ "$skew" -lt 0 ] && skew=$(( -skew ))
[ "$skew" -lt 86400 ] && r PASS "board clock matches your Mac" "off by ${skew}s" || r WARN "board clock is off by $((skew/86400)) day(s)" "TLS downloads (GitHub, pip) can fail; fix the date first"
getent hosts github.com >/dev/null 2>&1 && r PASS "DNS works" "" || r FAIL "DNS does not resolve github.com" "check the board's network / DNS"
for u in https://github.com https://pypi.org/simple/pip/ https://files.pythonhosted.org/; do
    c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$u" 2>/dev/null)   # files.pythonhosted.org answers 404 on its front page: only "no answer at all" is a failure
    case "$c" in 000|"") r FAIL "cannot reach $u" "needed to download KlipperScreen / Python packages" ;; *) r PASS "reach $u" "HTTP $c" ;; esac
done
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://github.com/KlipperScreen/KlipperScreen/commit/${KS_SHA}" 2>/dev/null)
[ "$code" = 200 ] && r PASS "pinned KlipperScreen commit exists on GitHub" "${KS_SHA:0:7}" || r FAIL "pinned commit not reachable (HTTP $code)" "${KS_SHA:0:7}"
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://archive.debian.org/debian/dists/bullseye/Release 2>/dev/null)
[ "$code" = 200 ] && r PASS "archive.debian.org bullseye reachable" "" || r FAIL "archive.debian.org not reachable (HTTP $code)" "apt cannot fetch packages"
grep -hE '^deb ' /etc/apt/sources.list 2>/dev/null | grep -q archive.debian.org && r PASS "sources.list uses archive.debian.org" "" || r WARN "sources.list does not use archive.debian.org" "the installer rewrites it (original saved)"
grep -rqs 'Check-Valid-Until "false"' /etc/apt/apt.conf.d && r PASS "apt date check disabled" "" || r WARN "apt date check is on" "the installer adds /etc/apt/apt.conf.d/99no-check-valid-until"
r SECTION "Can the packages be installed without damage? (simulation, changes nothing)" ""
PK="xinit xinput x11-xserver-utils xserver-xorg-input-evdev xserver-xorg-input-libinput xserver-xorg-video-fbdev libgirepository1.0-dev gcc libcairo2-dev pkg-config python3-dev gir1.2-gtk-3.0 librsvg2-common libopenjp2-7 libdbus-glib-1-dev autoconf python3-venv libsystemd-dev git curl"
if [ -n "$(ls /var/lib/apt/lists/*Packages* 2>/dev/null | head -n1)" ]; then
    sim="$(apt-get -s install --no-upgrade $PK 2>&1)"
    echo "$sim" | grep -q "^E:" && r FAIL "apt simulation reports errors" "$(echo "$sim" | grep '^E:' | head -n2 | tr '\n' ' ')" || r PASS "apt simulation: packages resolve" "$(echo "$sim" | grep -E '^[0-9]+ upgraded' | head -n1)"
    echo "$sim" | grep -q "will be REMOVED" && r FAIL "apt would REMOVE packages" "$(echo "$sim" | grep -A3 'will be REMOVED' | tr '\n' ' ')" || r PASS "apt would remove nothing" ""
    echo "$sim" | grep -Eq '^[0-9]+ upgraded' && { n="$(echo "$sim" | grep -Eo '^[0-9]+ upgraded' | grep -Eo '^[0-9]+')"; [ "${n:-0}" = 0 ] && r PASS "apt would upgrade nothing already installed" "" || r WARN "apt would upgrade $n installed package(s)" "$(echo "$sim" | grep -A2 'will be upgraded' | tr '\n' ' ' | cut -c1-200)"; }
    echo "$sim" | grep -Eq 'xserver-(xorg-core|common)' && echo "$sim" | grep -E '^(Inst|Remv) xserver-(xorg-core|common)' >/dev/null 2>&1 && r FAIL "apt would change the held Rockchip X server" "$(echo "$sim" | grep -E '^(Inst|Remv) xserver-' | head -n3 | tr '\n' ' ')"
else r WARN "apt package lists are empty" "re-run with --with-apt-update (refreshes the lists only) so the simulation can run"; fi
r DONE "" ""
RSH

read -r -d '' XREMOTE <<'XSH'
r() { printf '@@|%s|%s|%s\n' "$1" "$2" "$3"; }
trap 'systemctl start makerbase-client 2>/dev/null' EXIT
r SECTION "X server test on the board (the factory screen app is stopped for this and started again)" ""
r PASS "sudo works with the password you typed" "$(id -un)"
[ -x /usr/lib/xorg/Xorg ] || { r FAIL "no /usr/lib/xorg/Xorg" ""; r DONE "" ""; exit 0; }
systemctl stop makerbase-client; sleep 2
printf 'Section "Device"\n  Identifier "d"\n  Driver "modesetting"\nEndSection\n' > /tmp/xt-ms.conf
printf 'Section "Device"\n  Identifier "d"\n  Driver "fbdev"\n  Option "fbdev" "/dev/fb0"\nEndSection\n' > /tmp/xt-fb.conf
try() {   # name config flags
    rm -f /tmp/xt.log; /usr/lib/xorg/Xorg :9 -config "$2" -logfile /tmp/xt.log -nolisten tcp -noreset $3 >/tmp/xt.out 2>&1 &
    pid=$!; sleep 7
    if kill -0 $pid 2>/dev/null; then
        mode="$(grep -E 'Modeline|Output .* using|Virtual screen size|Setting screen' /tmp/xt.log | head -n1)"; r PASS "X starts: $1" "${mode:-running after 7 s}"
        ok=1; kill $pid 2>/dev/null; sleep 1; kill -9 $pid 2>/dev/null
    else
        r FAIL "X does not start: $1" "$(grep -E 'Fatal|Cannot open|no screens|parse_vt' /tmp/xt.log 2>/dev/null | head -n2 | sed 's/^\[[ 0-9.]*\] //' | tr '\n' ' ' | cut -c1-300)"
    fi
}
try "modesetting, plain" /tmp/xt-ms.conf ""
try "modesetting, no VT switch" /tmp/xt-ms.conf "-novtswitch -sharevts -keeptty"
try "fbdev, plain" /tmp/xt-fb.conf ""
try "fbdev, no VT switch" /tmp/xt-fb.conf "-novtswitch -sharevts -keeptty"
r INFO "Xorg log of the last try (tail)" "$(tail -n 4 /tmp/xt.log 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
rm -f /tmp/xt-ms.conf /tmp/xt-fb.conf /tmp/xt.log /tmp/xt.out
systemctl start makerbase-client; sleep 2
systemctl is-active --quiet makerbase-client && r PASS "factory screen app started again" "" || r WARN "factory screen app is not running" "run: sudo systemctl start makerbase-client (or reboot the board)"
trap - EXIT
r DONE "" ""
XSH

head_ "On your Mac"
[ "$LOCAL" = 1 ] || { command -v ssh >/dev/null && show PASS "ssh available" "" || { show FAIL "ssh missing" ""; }; }
command -v curl >/dev/null && show PASS "curl available" "" || show FAIL "curl missing" ""
if [ "$LOCAL" != 1 ]; then
    if ping -c1 -t3 "$BOARD" >/dev/null 2>&1; then show PASS "board answers ping" "$BOARD"; else show WARN "board does not answer ping" "$BOARD (ping may be blocked; trying SSH)"; fi
fi
tmpcode=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://github.com/KlipperScreen/KlipperScreen/commit/${KS_SHA}" 2>/dev/null)
[ "$tmpcode" = 200 ] && show PASS "pinned KlipperScreen commit reachable from your Mac" "${KS_SHA:0:7}" || show WARN "could not check the pinned commit from your Mac" "HTTP $tmpcode"

head_ "Connecting to the screen board"
if [ "$LOCAL" = 1 ]; then
    OUT="$(PI="$PI" KS_SHA="$KS_SHA" MAC_EPOCH="$(date +%s)" bash -s <<<"$REMOTE" 2>&1)"
else
    SSHO="-o ControlMaster=auto -o ControlPath=/tmp/wmpf-%r@%h -o ControlPersist=300 -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
    echo "Type the board's SSH password once (default for the WonderMaker image: TM88888)."
    if ! ssh -n $SSHO "$BUSER@$BOARD" true; then show FAIL "SSH to the board failed" "$BUSER@$BOARD (check IP, that SSH is on, user and password)"; OUT=""
    else
        if [ "$APTUP" = 1 ]; then echo "Refreshing the package lists on the board (sudo apt-get update; nothing is installed)..."; ssh -t $SSHO "$BUSER@$BOARD" 'sudo apt-get update' || show WARN "apt-get update failed" "see above"; fi
        OUT="$(ssh $SSHO "$BUSER@$BOARD" "PI='$PI' KS_SHA='$KS_SHA' MAC_EPOCH='$(date +%s)' bash -s" <<<"$REMOTE" 2>&1)"
    fi
fi
if [ "$XTEST" = 1 ] && [ "$LOCAL" != 1 ] && [ -n "$OUT" ]; then
    echo; echo "X server test: this stops the factory screen app for about a minute and starts it again."
    printf 'Board sudo password for %s: ' "$BUSER"; read -r -s SPW; echo
    ssh $SSHO "$BUSER@$BOARD" 'cat > /tmp/wm_xtest.sh' <<<"$XREMOTE"
    XOUT="$(printf '%s\n' "$SPW" | ssh $SSHO "$BUSER@$BOARD" "sudo -S -p '' bash /tmp/wm_xtest.sh" 2>&1)"
    ssh -n $SSHO "$BUSER@$BOARD" 'rm -f /tmp/wm_xtest.sh' 2>/dev/null; SPW=""
    echo "$XOUT" | grep -q '^@@|DONE' || XOUT="@@|FAIL|X test did not run|$(echo "$XOUT" | head -n2 | tr '\n' ' ')
@@|DONE||"
    OUT="$OUT
$XOUT"
fi

GOT=0
while IFS='|' read -r tag st key detail; do
    [ "$tag" = "@@" ] || continue
    case "$st" in SECTION) head_ "$key" ;; DONE) GOT=$((GOT+1)) ;; *) show "$st" "$key" "$detail" ;; esac
done <<EOF2
$OUT
EOF2
[ "$GOT" -ge 1 ] || { [ -n "$OUT" ] && show FAIL "the checks on the board did not finish" "$(echo "$OUT" | tail -n 2 | tr '\n' ' ')"; }

head_ "Verdict"
if [ "$NFAIL" = 0 ] && [ "$GOT" -ge 1 ]; then V="READY (with $NWARN warning(s))"; RC=0; else V="NOT READY ($NFAIL problem(s), $NWARN warning(s))"; RC=1; fi
echo "$V   -  pass: $NPASS  warn: $NWARN  fail: $NFAIL"
{ echo "wm-ultra-rpi screen board preflight $(date)"; sed -E 's/((password|passwd|token|secret|psk)[[:space:]]*[:=][[:space:]]*).*/\1<removed>/I; s/\b(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)\b/<private-ip>/g' "$TMP"; echo; echo "$V"; } > "$REPORT"
echo "Report saved: $REPORT"
[ "$RC" = 0 ] && echo "Nothing blocks the install. Next: bash scripts/screen_board.sh --dry-run (on the board)." || echo "Fix the FAIL lines (or send me the report), then run this again."
exit $RC
