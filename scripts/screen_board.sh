#!/bin/bash
# =============================================================================
# KlipperScreen on the WonderMaker screen board (WM-ZR-M, RK3308B)            NOT YET TESTED ON HARDWARE
# =============================================================================
# Run ON the screen board (Debian 11, user t13dp), from a clone of this repository:
#   curl -fsSL https://codeload.github.com/ducati1198/wm-ultra-rpi/tar.gz/refs/heads/main | tar xz && cd wm-ultra-rpi-main
#   bash scripts/screen_board.sh                            install (asks for the Pi IP address)
#
# bash scripts/screen_board.sh --pi HOST [--screen-driver modesetting|fbdev] [--dry-run] [--yes]   install
# bash scripts/screen_board.sh --status                      read-only: what is installed / disabled
# bash scripts/screen_board.sh --uninstall-klipperscreen     same as --factory-restore (KlipperScreen is never removed without turning the factory services back on)
# bash scripts/screen_board.sh --factory-restore             remove KlipperScreen, turn the factory services back on, reboot
#                                                            (also the "Factory mode" button on the screen: ZR Tools > More > System)
# Options: --no-reboot, --force (ignore a running print), --yes
#
# What it does: stops and DISABLES the factory screen app and the services that now run on the Pi (nothing is deleted, the list
# is saved in ~/wm-screen-backup), installs KlipperScreen (the pinned commit) + ZR Tools, and points it at the Pi's Moonraker.
# What it never does: flash anything, run "apt upgrade", touch the factory printer_data or the printer's MCUs.
# =============================================================================
set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; DIM='\033[2m'; NC='\033[0m'
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WM_USER="t13dp"
TESTING="${WM_INSTALLER_TEST:-0}"
if [ -n "${WM_HOME:-}" ]; then HOME_DIR="$WM_HOME"; elif [ "$(id -u)" = 0 ]; then HOME_DIR="/home/$WM_USER"; else HOME_DIR="$HOME"; fi
BK="$HOME_DIR/wm-screen-backup"
KS_DIR="$HOME_DIR/KlipperScreen"; KS_ENV="$HOME_DIR/.KlipperScreen-env"
CFG_DIR="$HOME_DIR/printer_data/config"
MODE=install; DRY=0; PI_HOST=""; DRIVER=modesetting; REBOOT=1; FORCE=0; DETACH=0
STAMP="$(date +%Y%m%d-%H%M%S)"
# Services stopped and disabled, in this order (restore starts them in reverse order). Only those that exist are touched.
SERVICES=(makerbase-client klipper moonraker nginx crowsnest makerbase-webcam janus klipper-mcu hostapd moonraker-obico octoapp)
XDIR="/etc/X11/xorg.conf.d"
declare -a WARNINGS=()

print_header()  { echo -e "\n${BLUE}── $1 ──────────────────────────────────────────${NC}"; }
print_info()    { echo -e "${BLUE}ℹ ${1}${NC}"; }
print_success() { echo -e "${GREEN}✓ ${1}${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ ${1}${NC}"; }
print_error()   { echo -e "${RED}✗ ${1}${NC}"; }
warn_later()    { WARNINGS+=("$1"); }
die_with_fix()  { print_error "Can't continue: $1"; echo -e "  Fix: $2"; exit 1; }
ask_yn() { local p="$1" d="${2:-y}" a; if [ "${WM_ASSUME_YES:-0}" = 1 ]; then [ "$d" = y ]; return; fi
    read -r -p "$(echo -e "${YELLOW}?${NC} $p [${d}] ")" a || a=""; a="${a:-$d}"; [[ "$a" =~ ^[Yy] ]]; }
SUDO() {
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: sudo $*${NC}"; return 0; fi
    if [ "$TESTING" = 1 ]; then echo "[test] sudo $*" >> "$HOME_DIR/.sudo.log"; test_systemctl "$@"; return 0; fi
    if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}
run() { if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: $*${NC}"; return 0; fi; "$@"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --pi) PI_HOST="${2:-}"; shift ;;
        --screen-driver) case "${2:-}" in modesetting|fbdev) DRIVER="$2" ;; *) print_error "--screen-driver needs modesetting or fbdev"; exit 1 ;; esac; shift ;;
        --set-pi) MODE=setpi; PI_HOST="${2:-}"; shift ;;
        --status) MODE=status ;;
        --uninstall-klipperscreen) MODE=uninstall ;;
        --factory-restore) MODE=restore ;;
        --no-reboot) REBOOT=0 ;;
        --force) FORCE=1 ;;
        --detach) DETACH=1 ;;
        --dry-run) DRY=1 ;;
        --yes) WM_ASSUME_YES=1 ;;
        -h|--help) sed -n '2,/^# =====.*$/p' "$0" | sed -n '2,22p' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------- service state (fakeable in tests)
test_systemctl() {
    [ "$1" = systemctl ] || return 0
    local v="${2:-}" u="${3:-}"; u="${u%.service}"; mkdir -p "$HOME_DIR/.svc"
    case "$v" in
        enable) touch "$HOME_DIR/.svc/$u.enabled" ;; disable) rm -f "$HOME_DIR/.svc/$u.enabled" ;;
        start|restart) touch "$HOME_DIR/.svc/$u.active" ;; stop) rm -f "$HOME_DIR/.svc/$u.active" ;;
    esac
}
test_init_services() {
    [ "$TESTING" = 1 ] && [ ! -e "$HOME_DIR/.svc/.init" ] || return 0
    mkdir -p "$HOME_DIR/.svc"; local u; for u in ${WM_TEST_SERVICES:-}; do touch "$HOME_DIR/.svc/$u.exists" "$HOME_DIR/.svc/$u.enabled" "$HOME_DIR/.svc/$u.active"; done
    touch "$HOME_DIR/.svc/.init"
}
svc_exists()  { test_init_services; if [ "$TESTING" = 1 ]; then [ -e "$HOME_DIR/.svc/$1.exists" ]; else systemctl cat "$1.service" >/dev/null 2>&1; fi; }
svc_enabled() { if [ "$TESTING" = 1 ]; then [ -e "$HOME_DIR/.svc/$1.enabled" ]; else [ "$(systemctl is-enabled "$1" 2>/dev/null)" = enabled ]; fi; }
svc_active()  { if [ "$TESTING" = 1 ]; then [ -e "$HOME_DIR/.svc/$1.active" ]; else systemctl is-active --quiet "$1" 2>/dev/null; fi; }

# ---------------------------------------------------------------- checks
pi_url() { echo "http://${PI_HOST}:7125"; }
printing_now() {   # the factory Moonraker on this board
    if [ "$TESTING" = 1 ]; then [ "${WM_TEST_PRINTING:-0}" = 1 ]; return; fi
    local u s; for u in "http://127.0.0.1:7125"; do
        [ -n "$u" ] || continue
        s="$(curl -fsS -m 4 "$u/printer/objects/query?print_stats" 2>/dev/null)"
        echo "$s" | grep -q '"state": *"printing"\|"state":"printing"\|"state": *"paused"\|"state":"paused"' && return 0
    done; return 1
}
valid_host() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [ "${#1}" -le 253 ]; }
ask_pi() {   # the Pi's IP address or name; asked unless --pi was given (no default)
    if [ -z "$PI_HOST" ]; then
        if [ "${WM_ASSUME_YES:-0}" = 1 ] || [ ! -t 0 ]; then die_with_fix "no Pi address." "add --pi <the Pi's IP address>."; fi
        while :; do read -r -p "$(echo -e "${YELLOW}?${NC} IP address of your Raspberry Pi: ")" PI_HOST || PI_HOST=""
            valid_host "$PI_HOST" && break; print_warning "Type the Pi's IP address (digits and dots), for example 192.168.0.50."; PI_HOST=""; done
    fi
    valid_host "$PI_HOST" || die_with_fix "'$PI_HOST' is not a valid address." "use the Pi's IP address."
}
apt_fix() {   # Debian 11 is archived: point apt at archive.debian.org and ignore the old dates (same fix as on the original board)
    local sl=/etc/apt/sources.list conf=/etc/apt/apt.conf.d/99no-check-valid-until
    [ "$TESTING" = 1 ] && { SUDO apt-archive-fix; return 0; }
    if grep -qE '^deb .*(mirrors|deb\.debian|security\.debian|ftp\.)' $sl 2>/dev/null; then
        mkdir -p "$BK"; [ -f "$BK/sources.list.orig" ] || run cp $sl "$BK/sources.list.orig"
        SUDO sed -i -E 's#https?://[^ /]+/debian-security#http://archive.debian.org/debian-security#; t; s#https?://[^ /]+/debian/?#http://archive.debian.org/debian/#' $sl
    fi
    [ -f "$conf" ] || printf 'Acquire::Check-Valid-Until "false";\nAcquire::Check-Date "false";\n' | SUDO tee "$conf" >/dev/null
}
apt_ok() {
    if [ "$TESTING" = 1 ]; then [ "${WM_TEST_APT_OK:-1}" = 1 ]; return; fi
    [ "$DRY" = 1 ] && return 0
    sudo apt-get update 2>&1 | tail -n 6; [ "${PIPESTATUS[0]}" = 0 ]
}
disk_free_mb() { [ "$TESTING" = 1 ] && { echo "${WM_TEST_DISK_MB:-4000}"; return; }; df -Pm "$HOME_DIR" | awk 'NR==2{print $4}'; }

preflight() {
    print_header "Checking this board"
    if [ "$TESTING" != 1 ]; then
        [ "$(id -un)" = "$WM_USER" ] || [ "$(id -u)" = 0 ] || die_with_fix "user is $(id -un), not $WM_USER." "log in as $WM_USER."
        grep -q 'VERSION_ID="11"' /etc/os-release 2>/dev/null || die_with_fix "this is not Debian 11." "this script is written for the WonderMaker screen board image (Debian 11)."
        [ "$(uname -m)" = aarch64 ] || die_with_fix "not a 64-bit ARM board." "run it on the WonderMaker screen board."
        [ -e /dev/fb0 ] || print_warning "/dev/fb0 not found: the screen may not be initialised."
    fi
    ask_pi   # only written into KlipperScreen.conf; the Pi is not contacted
    if printing_now && [ "$FORCE" != 1 ]; then die_with_fix "a print is running or paused." "wait until it finishes (or --force)."; fi
    local free; free="$(disk_free_mb)"; [ "${free:-0}" -gt 1500 ] && print_success "disk space ${free} MB free" || die_with_fix "only ${free} MB free." "free space (old logs, ~/printer_data/gcodes) first."
    apt_fix; apt_ok && print_success "apt works (archive.debian.org)" || die_with_fix "apt update fails." "check the board's internet access and date; see README 'Screen board'. Nothing was changed."
    if [ "$TESTING" != 1 ]; then curl -fsS -m 8 -o /dev/null https://github.com 2>/dev/null && print_success "GitHub reachable" || die_with_fix "GitHub is not reachable." "KlipperScreen is downloaded from GitHub."; fi
}

# ---------------------------------------------------------------- state saved for the restore
save_state() {
    [ "$DRY" = 1 ] && return 0
    mkdir -p "$BK"
    if [ ! -s "$BK/disabled.list" ]; then   # keep the ORIGINAL state if the script runs twice
        : > "$BK/disabled.list"; local u
        for u in "${SERVICES[@]}"; do svc_exists "$u" || continue
            echo "$u $(svc_enabled "$u" && echo enabled || echo disabled) $(svc_active "$u" && echo active || echo inactive)" >> "$BK/disabled.list"; done
        [ "$TESTING" = 1 ] || systemctl get-default > "$BK/default.target" 2>/dev/null
        [ ! -f /etc/X11/Xwrapper.config ] || [ -f "$BK/Xwrapper.config.orig" ] || cp /etc/X11/Xwrapper.config "$BK/Xwrapper.config.orig" 2>/dev/null
    fi
    cp "$SCRIPT_DIR/screen_board.sh" "$BK/screen_board.sh"
}

step_disable_factory() {
    print_header "Stopping the factory services (nothing is deleted)"
    local u; for u in "${SERVICES[@]}"; do
        svc_exists "$u" || continue
        if svc_active "$u" || svc_enabled "$u"; then SUDO systemctl stop "$u"; SUDO systemctl disable "$u"; echo "  stopped and disabled: $u"; fi
    done
    [ "$DRY" = 1 ] || print_success "Saved the previous state in $BK/disabled.list"
}

# ---------------------------------------------------------------- KlipperScreen
APT_PKGS="git curl xinit xinput x11-xserver-utils xserver-xorg-input-evdev xserver-xorg-input-libinput xserver-xorg-video-fbdev libgirepository1.0-dev gcc libcairo2-dev pkg-config python3-dev gir1.2-gtk-3.0 librsvg2-common libopenjp2-7 libdbus-glib-1-dev autoconf python3-venv libsystemd-dev"
addon_pin() { grep "^$1|" "$REPO_DIR/config/pins/addons.txt" | cut -d'|' -f2,3; }

SWAPFILE=/wm-tmp-swap
add_swap() {   # the board has 487 MB RAM and no swap: the PyGObject/pycairo build needs more. Temporary, removed afterwards.
    local mem; mem="$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null)"
    [ "$TESTING" = 1 ] && mem="${WM_TEST_MEM_MB:-487}"
    [ "${mem:-9999}" -lt 900 ] || return 0
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would add a temporary 768 MB swap file ($SWAPFILE)${NC}"; return 0; fi
    if [ "$TESTING" = 1 ]; then echo "[test] swapfile $SWAPFILE" >> "$HOME_DIR/.sudo.log"; return 0; fi
    sudo fallocate -l 768M "$SWAPFILE" && sudo chmod 600 "$SWAPFILE" && sudo mkswap "$SWAPFILE" >/dev/null && sudo swapon "$SWAPFILE" && { print_info "Temporary swap added (removed at the end)"; trap drop_swap EXIT; } \
        || warn_later "Could not add swap: the Python build may run out of memory."
}
drop_swap() {
    [ "$DRY" = 1 ] && return 0
    [ "$TESTING" = 1 ] && return 0
    [ -f "$SWAPFILE" ] && { sudo swapoff "$SWAPFILE" 2>/dev/null; sudo rm -f "$SWAPFILE"; }
}

step_packages() {
    print_header "Installing packages (apt install only, never apt upgrade)"
    # WonderMaker holds its own build of the X server. The matching xserver-xorg-legacy (Xorg wrapper) is in /packages/xserver on the board.
    if [ "$TESTING" != 1 ] && ! dpkg -s xserver-xorg-legacy 2>/dev/null | grep -q "ok installed"; then
        local deb; deb="$(ls /packages/xserver/xserver-xorg-legacy_*_arm64.deb 2>/dev/null | grep -v dbgsym | head -n1)"
        if [ -n "$deb" ]; then SUDO dpkg -i "$deb" || warn_later "Could not install $deb (X may not start for a normal user)."
        else warn_later "xserver-xorg-legacy is missing and /packages/xserver has no copy. KlipperScreen's X may not start."; fi
    fi
    SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-upgrade $APT_PKGS || die_with_fix "apt could not install the packages." "see the messages above; rerun this script after fixing. The factory services are still running (nothing was disabled yet)."
    # The factory image has /usr/share/X11 removed (X cannot build a keymap or find its input config): put it back
    SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall xkb-data xserver-xorg-input-libinput xserver-xorg-input-evdev || warn_later "Could not restore the X keyboard data (xkb-data): X may not start."
    SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-upgrade libmpv-dev fonts-nanum fonts-ipafont >/dev/null 2>&1 || print_info "Optional packages (libmpv, CJK fonts) skipped."
    print_success "Packages installed"
}

fetch_ks() {
    local pin url sha; pin="$(addon_pin klipperscreen)"; url="${pin%|*}"; sha="${pin#*|}"
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: git clone $url $KS_DIR @ ${sha:0:7}${NC}"; return 0; fi
    if [ "$TESTING" = 1 ]; then mkdir -p "$KS_DIR/panels" "$KS_DIR/scripts"; echo "[test] fetch $url @ $sha" >> "$HOME_DIR/.sudo.log"; return 0; fi
    if command -v git >/dev/null 2>&1; then   # git if the board has it, otherwise the plain tarball of the pinned commit (no git needed)
        [ -d "$KS_DIR/.git" ] || git clone -q "$url" "$KS_DIR" || return 1
        git -C "$KS_DIR" checkout -q "$sha"
    else
        rm -rf "$KS_DIR"; mkdir -p "$KS_DIR"
        curl -fsSL "https://codeload.github.com/${url#https://github.com/}/tar.gz/$sha" | tar -xz --strip-components=1 -C "$KS_DIR" || return 1
    fi
}

step_klipperscreen() {
    print_header "Installing KlipperScreen (pinned commit) + ZR Tools"
    fetch_ks || die_with_fix "could not download KlipperScreen." "check the internet, rerun."
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would create $KS_ENV and pip install the requirements${NC}"
    elif [ "$TESTING" = 1 ]; then echo "[test] venv + pip install" >> "$HOME_DIR/.sudo.log"
    else
        rm -rf "$KS_ENV"; python3 -m venv "$KS_ENV" || die_with_fix "python3 -m venv failed." "apt install python3-venv."
        "$KS_ENV/bin/pip" --disable-pip-version-check install -r "$KS_DIR/scripts/KlipperScreen-requirements.txt" \
            || { "$KS_ENV/bin/pip" install --upgrade pip setuptools wheel && "$KS_ENV/bin/pip" install --prefer-binary -r "$KS_DIR/scripts/KlipperScreen-requirements.txt"; } \
            || die_with_fix "pip could not install KlipperScreen's Python packages." "see the messages above (PyGObject needs the packages that were just installed). The factory services are still running."
    fi
    # ZR Tools panel files
    if [ "$DRY" != 1 ]; then
        mkdir -p "$KS_DIR/panels"; cp "$REPO_DIR"/zr_tools/{zr_tools.py,zr_views.py,zr_logic.py} "$KS_DIR/panels/"
        # The stock Network panel needs NetworkManager. This board uses wpa_supplicant (WonderMaker's setup), so use a wpa_cli panel instead.
        if [ -S /run/wpa_supplicant/wlan0 ] || systemctl is-active --quiet makerbase-wlan0 2>/dev/null; then cp "$REPO_DIR/zr_tools/wifi_panel.py" "$KS_DIR/panels/network.py"; fi
        cp "$REPO_DIR/zr_tools/pi_address_panel.py" "$KS_DIR/panels/pi_address.py"
        [ -d "$KS_DIR/.git" ] && { mkdir -p "$KS_DIR/.git/info"; grep -qs '^panels/zr_' "$KS_DIR/.git/info/exclude" || echo 'panels/zr_*.py' >> "$KS_DIR/.git/info/exclude"; }
    fi
    write_ks_conf
    write_service
    step_seat
    step_x_config
    print_success "KlipperScreen installed in $KS_DIR"
}

write_ks_conf() {
    [ "$DRY" = 1 ] && { echo -e "  ${DIM}would write KlipperScreen.conf (Pi: $PI_HOST) and zr_screen.conf${NC}"; return 0; }
    mkdir -p "$CFG_DIR"
    local f="$CFG_DIR/KlipperScreen.conf"; [ -f "$f" ] && [ ! -f "$BK/KlipperScreen.conf.orig" ] && cp "$f" "$BK/KlipperScreen.conf.orig"
    cat > "$f" <<E
# Written by wm-ultra-rpi scripts/screen_board.sh (the Pi runs Klipper and Moonraker)
[printer wmpi]
moonraker_host: $PI_HOST
moonraker_port: 7125

[menu __main zr_tools]
name: ZR Tools
icon: extruder
panel: zr_tools

[menu __main more pi_address]
name: Pi address
icon: network
panel: pi_address

[menu __splashscreen pi_address]
name: Pi address
icon: network
panel: pi_address
E
    [ -f "$CFG_DIR/zr_screen.conf" ] || printf '# Written by screen_board.sh and the ZR Tools Settings page\n[screen]\nlayout = tabs\ndensity = compact\ntheme = dark\n' > "$CFG_DIR/zr_screen.conf"
}

# The board's kernel has no virtual console (/dev/tty0), so stock KlipperScreen cannot start. Verified on the board (Nov 3, 2026):
# X starts when it runs on its OWN seat (-seat seat1, no VT needed) with the display, framebuffer and touch assigned to that seat.
KS_START=/usr/local/sbin/wm-ks-start; KS_CLIENT=/usr/local/sbin/wm-ks-client; XINPUT=/etc/X11/wm-ks-input.conf; TOUCH_RULE=/etc/udev/rules.d/72-wm-touch-seat1.rules
write_service() {
    local svc=/etc/systemd/system/KlipperScreen.service
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would write $svc, $KS_START, $KS_CLIENT, $XINPUT (X on its own seat, no tty0 needed)${NC}"
    elif [ "$TESTING" = 1 ]; then echo "[test] write service (seat1, no tty0)" >> "$HOME_DIR/.sudo.log"
    else
        sudo tee "$XINPUT" >/dev/null <<'E'
Section "InputClass"
    Identifier "wm touchscreen"
    MatchIsTouchscreen "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection
E
        sudo tee "$KS_CLIENT" >/dev/null <<E
#!/bin/bash
# KlipperScreen itself runs as $WM_USER; the X server (started by xinit) runs as root on seat1
exec runuser -u $WM_USER -- env HOME=$HOME_DIR DISPLAY=:0 $KS_ENV/bin/python $KS_DIR/screen.py
E
        sudo tee "$KS_START" >/dev/null <<E
#!/bin/bash
exec /usr/bin/xinit $KS_CLIENT -- /usr/lib/xorg/Xorg :0 -seat seat1 -novtswitch -sharevts -nolisten tcp -noreset -config $XINPUT
E
        sudo chmod 755 "$KS_CLIENT" "$KS_START"
        sudo tee "$svc" >/dev/null <<E
[Unit]
Description=KlipperScreen on the WonderMaker screen board (own X seat, no virtual console)
After=systemd-udevd.service systemd-logind.service network-online.target

[Service]
Type=simple
ExecStart=$KS_START
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
E
        sudo adduser "$WM_USER" video >/dev/null 2>&1; sudo adduser "$WM_USER" input >/dev/null 2>&1
    fi
    SUDO systemctl daemon-reload
}

step_seat() {   # put the display, framebuffer and touch on seat1 (udev rules; recorded so the uninstall removes exactly these)
    print_header "Display and touch on their own seat"
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: loginctl attach seat1 (card0, fb0) and add $TOUCH_RULE${NC}"; return 0; fi
    mkdir -p "$BK"
    if [ "$TESTING" = 1 ]; then echo "[test] seat1 attach + touch rule" >> "$HOME_DIR/.sudo.log"; echo "72-wm-touch-seat1.rules" > "$BK/udev_rules.created"; return 0; fi
    local before after d p f
    before="$(ls /etc/udev/rules.d 2>/dev/null)"
    for d in /dev/dri/card0 /dev/fb0; do
        p="$(udevadm info -q path -n "$d" 2>/dev/null)"; [ -n "$p" ] && sudo loginctl attach seat1 "/sys$p" || warn_later "Could not put $d on seat1."
    done
    printf 'SUBSYSTEM=="input", ENV{ID_INPUT_TOUCHSCREEN}=="1", TAG+="seat", ENV{ID_SEAT}="seat1"\n' | sudo tee "$TOUCH_RULE" >/dev/null
    sudo udevadm control --reload; sudo udevadm trigger; sudo udevadm settle
    after="$(ls /etc/udev/rules.d 2>/dev/null)"
    diff <(echo "$before") <(echo "$after") | sed -n 's/^> //p' > "$BK/udev_rules.created"
    print_success "seat1 has: $(sudo loginctl seat-status seat1 2>/dev/null | grep -c -E 'drm:card0$|graphics:fb0|input:event') device(s)"
}

step_x_config() {
    [ "$DRIVER" = fbdev ] && use_fbdev
}
use_fbdev() {   # plain framebuffer driver instead of Rockchip modesetting (moved aside, restored on uninstall)
    [ "$DRY" = 1 ] && { echo -e "  ${DIM}would switch X to the fbdev driver${NC}"; return 0; }
    if [ "$TESTING" = 1 ]; then echo "[test] fbdev driver" >> "$HOME_DIR/.sudo.log"; : > "$HOME_DIR/.fbdev"; return 0; fi
    [ -f "$XDIR/20-modesetting.conf" ] && sudo mv "$XDIR/20-modesetting.conf" "$XDIR/20-modesetting.conf.wm-disabled"
    printf 'Section "Device"\n    Identifier "WM fbdev"\n    Driver "fbdev"\n    Option "fbdev" "/dev/fb0"\nEndSection\n' | sudo tee "$XDIR/10-wm-fbdev.conf" >/dev/null
}
ks_running() {
    if [ "$TESTING" = 1 ]; then
        case "${WM_TEST_KS_OK:-1}" in 0) return 1 ;; fbdev) [ -e "$HOME_DIR/.fbdev" ]; return ;; *) return 0 ;; esac
    fi
    local i; for i in 1 2 3 4 5 6 7 8; do sleep 3; systemctl is-active --quiet KlipperScreen && pgrep -f "KlipperScreen/screen.py" >/dev/null && return 0; done; return 1
}
step_start() {
    print_header "Starting KlipperScreen"
    SUDO systemctl enable KlipperScreen; SUDO systemctl restart KlipperScreen
    [ "$DRY" = 1 ] && return 0
    if ks_running; then print_success "KlipperScreen is running ($DRIVER driver)"; return 0; fi
    if [ "$DRIVER" = modesetting ]; then
        print_warning "KlipperScreen did not start with the modesetting driver. Switching to the plain framebuffer (fbdev) driver..."
        DRIVER=fbdev; use_fbdev; SUDO systemctl restart KlipperScreen
        ks_running && { print_success "KlipperScreen is running with the fbdev driver."; return 0; }
    fi
    warn_later "KlipperScreen did not start. Look at: journalctl -u KlipperScreen -n 50 and ~/.local/share/xorg/Xorg.0.log. To go back: bash $BK/screen_board.sh --factory-restore"
}
step_restore_button() {   # root-owned copy + sudoers line for the one command the on-screen "Factory mode" button runs
    print_header "Factory mode button"
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would install /usr/local/sbin/wm-factory-restore and a sudoers entry${NC}"; return 0; fi
    mkdir -p "$BK"; echo "KlipperScreen on screen board, installed $STAMP, Pi $PI_HOST" > "$BK/board_mode"
    if [ "$TESTING" = 1 ]; then echo "[test] sudoers + wm-factory-restore" >> "$HOME_DIR/.sudo.log"; return 0; fi
    sudo install -o root -g root -m 755 "$SCRIPT_DIR/screen_board.sh" /usr/local/sbin/wm-factory-restore
    printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/wm-factory-restore --factory-restore --yes --detach\n' "$WM_USER" | sudo tee /etc/sudoers.d/wm-factory-restore >/dev/null
    sudo chmod 440 /etc/sudoers.d/wm-factory-restore; sudo visudo -cf /etc/sudoers.d/wm-factory-restore >/dev/null || { sudo rm -f /etc/sudoers.d/wm-factory-restore; warn_later "The Factory mode button was not enabled (sudoers check failed). Use the command line."; }
    print_success "Open ZR Tools > More > System > Factory mode to go back to the factory software."
}

do_install() {
    echo -e "${BLUE}KlipperScreen on the WonderMaker screen board (not yet tested on hardware)${NC}"
    [ "$DRY" = 1 ] && print_info "DRY RUN: nothing will be changed."
    preflight
    print_header "Plan (nothing has been changed yet)"
    echo "  Stops and disables (restored later): $(for u in "${SERVICES[@]}"; do svc_exists "$u" && printf '%s ' "$u"; done)"
    echo "  Installs: X11 + KlipperScreen packages, KlipperScreen (pinned) in ~/KlipperScreen, ZR Tools, a Factory-mode button"
    echo "  Connects to: $(pi_url)   Graphics driver: $DRIVER (falls back to fbdev if X does not start)"
    echo "  Go back any time: bash $BK/screen_board.sh --factory-restore"
    [ "$DRY" = 1 ] || ask_yn "Go ahead?" y || { echo "Nothing changed."; exit 0; }
    save_state
    add_swap
    step_packages
    step_klipperscreen          # everything that can fail comes BEFORE the factory app is stopped
    drop_swap
    step_disable_factory
    step_restore_button
    step_start
    print_header "Done"
    if [ ${#WARNINGS[@]} -gt 0 ]; then local w; for w in "${WARNINGS[@]}"; do print_warning "$w"; done; fi
    print_success "KlipperScreen is set up. Go back: ZR Tools > More > System > Factory mode, or bash $BK/screen_board.sh --factory-restore"
}

# ---------------------------------------------------------------- uninstall / restore
remove_klipperscreen() {
    print_header "Removing KlipperScreen"
    SUDO systemctl stop KlipperScreen; SUDO systemctl disable KlipperScreen
    SUDO rm -f /etc/systemd/system/KlipperScreen.service; SUDO systemctl daemon-reload
    if [ "$DRY" != 1 ]; then
        [ -f "$BK/default.target" ] && SUDO systemctl set-default "$(cat "$BK/default.target")"
        if [ "$TESTING" != 1 ]; then
            local rf; if [ -f "$BK/udev_rules.created" ]; then while read -r rf; do [ -n "$rf" ] && sudo rm -f "/etc/udev/rules.d/$rf"; done < "$BK/udev_rules.created"; rm -f "$BK/udev_rules.created"; fi
            sudo rm -f "$TOUCH_RULE" "$KS_START" "$KS_CLIENT" "$XINPUT"; sudo udevadm control --reload; sudo udevadm trigger; sudo udevadm settle
            [ -f "$XDIR/10-wm-fbdev.conf" ] && sudo rm -f "$XDIR/10-wm-fbdev.conf"
            [ -f "$XDIR/20-modesetting.conf.wm-disabled" ] && sudo mv "$XDIR/20-modesetting.conf.wm-disabled" "$XDIR/20-modesetting.conf"
            sudo rm -f /etc/sudoers.d/wm-factory-restore /usr/local/sbin/wm-factory-restore
        else echo "[test] remove seat rules, X conf, sudoers" >> "$HOME_DIR/.sudo.log"; rm -f "$HOME_DIR/.fbdev" "$BK/udev_rules.created"; fi
        rm -rf "$KS_DIR" "$KS_ENV"; rm -f "$BK/board_mode"
        [ -f "$BK/KlipperScreen.conf.orig" ] && cp "$BK/KlipperScreen.conf.orig" "$CFG_DIR/KlipperScreen.conf" || rm -f "$CFG_DIR/KlipperScreen.conf"
        rm -f "$CFG_DIR/zr_screen.conf"
    else echo -e "  ${DIM}would delete $KS_DIR and $KS_ENV${NC}"; fi
    print_success "KlipperScreen removed. The installed apt packages and your factory files are left alone."
}

do_uninstall() {   # removing KlipperScreen must never leave the screen black: the factory services come back too
    if [ -f "$BK/disabled.list" ]; then do_restore; return; fi
    [ -d "$KS_DIR" ] || [ -f /etc/systemd/system/KlipperScreen.service ] || [ "$TESTING" = 1 ] || die_with_fix "KlipperScreen is not installed here." "nothing to remove."
    print_warning "No saved service list found: only KlipperScreen is removed. Enable the factory services by hand if the screen stays black."
    ask_yn "Continue?" n || exit 0
    remove_klipperscreen
}

do_restore() {
    if [ "$DETACH" = 1 ] && [ "$TESTING" != 1 ]; then   # stopping KlipperScreen would kill us: run as a separate systemd unit
        local args="--factory-restore --yes"; [ "$REBOOT" = 0 ] && args="$args --no-reboot"
        exec systemd-run --no-block --unit=wm-factory-restore-run "$(readlink -f "$0")" $args
    fi
    print_header "Back to the WonderMaker factory software"
    [ -f "$BK/disabled.list" ] || die_with_fix "no saved service list ($BK/disabled.list)." "enable the factory services by hand: sudo systemctl enable --now makerbase-client moonraker klipper nginx"
    ask_yn "Remove KlipperScreen, turn the factory services back on and reboot?" y || exit 0
    remove_klipperscreen
    print_header "Turning the factory services back on"
    local lines=() u e a i
    while read -r u e a; do [ -n "$u" ] && lines+=("$u $e $a"); done < "$BK/disabled.list"
    for (( i=${#lines[@]}-1; i>=0; i-- )); do
        read -r u e a <<<"${lines[$i]}"
        svc_exists "$u" || continue
        [ "$e" = enabled ] && SUDO systemctl enable "$u"
        [ "$a" = active ] && [ "$REBOOT" = 0 ] && SUDO systemctl start "$u"
        echo "  restored: $u ($e, $a)"
    done
    [ "$DRY" = 1 ] || mv "$BK/disabled.list" "$BK/disabled.list.restored-$STAMP"
    print_success "Factory mode restored."
    if [ "$REBOOT" = 1 ]; then print_info "Rebooting..."; SUDO systemctl reboot; fi
}

do_setpi() {   # change the Pi address of an installed KlipperScreen
    valid_host "$PI_HOST" || die_with_fix "'$PI_HOST' is not a valid address." "bash scripts/screen_board.sh --set-pi 192.0.2.10"
    local f="$CFG_DIR/KlipperScreen.conf"; [ -f "$f" ] || die_with_fix "KlipperScreen is not installed here." "run the installer first."
    run sed -i -E "s/^moonraker_host:.*/moonraker_host: $PI_HOST/" "$f"
    SUDO systemctl restart KlipperScreen
    print_success "KlipperScreen now connects to $PI_HOST"
}

do_status() {
    print_header "Screen board status (read-only)"
    local u; for u in "${SERVICES[@]}" KlipperScreen; do svc_exists "$u" || continue
        echo "  $u: $(svc_enabled "$u" && echo enabled || echo disabled), $(svc_active "$u" && echo running || echo stopped)"; done
    [ -d "$KS_DIR" ] && echo "  KlipperScreen: installed ($KS_DIR)" || echo "  KlipperScreen: not installed"
    [ -f "$BK/board_mode" ] && echo "  Mode: KlipperScreen ($(cat "$BK/board_mode"))" || echo "  Mode: factory"
    [ -f "$BK/disabled.list" ] && echo "  Saved list for restore: $BK/disabled.list ($(wc -l < "$BK/disabled.list") services)"
}

case "$MODE" in
    install) do_install ;;
    status) do_status ;;
    setpi) do_setpi ;;
    uninstall) do_uninstall ;;
    restore) do_restore ;;
esac
