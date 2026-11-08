#!/bin/bash
# =============================================================================
# KlipperScreen on the WonderMaker screen board (WM-ZR-M, RK3308B)
# =============================================================================
# Run ON the screen board (Debian 11, user t13dp), from a clone of this repository:
#   curl -fsSL https://codeload.github.com/ducati1198/wm-ultra-rpi/tar.gz/refs/heads/main | tar xz && cd wm-ultra-rpi-main
#   bash scripts/screen_board.sh                            install (asks for the Pi IP address)
#
# bash scripts/screen_board.sh --pi HOST [--screen-driver modesetting|fbdev] [--dry-run] [--yes]   install
# bash scripts/screen_board.sh                               at a terminal with no options: opens the menu (--install goes straight to the install)
# bash scripts/screen_board.sh --menu                        numbered menu: install, update, check and fix, backup, settings, support bundle, factory restore, uninstall
# Also: --update  --doctor [--fix-all]  --backup  --restore-backup [N]  --support-bundle  --log  --restart-screen  --system [tz:Zone|host:name]  --remove installer|backups|rescue|restoredata  --set-driver modesetting|fbdev
# bash scripts/screen_board.sh --zr-pi --pi HOST            check the ZR Tools macros on the Pi (asks its user name and password), install them when missing
# bash scripts/screen_board.sh --fix-clock                   turn on automatic time sync (NTP), fix apt's date check
# bash scripts/screen_board.sh --free-space                  list what is safe to erase (sizes, warnings), erase what you pick and confirm
# bash scripts/screen_board.sh --status                      read-only: what is installed / disabled
# bash scripts/screen_board.sh --uninstall-klipperscreen     same as --factory-restore (KlipperScreen is never removed without turning the factory services back on)
# bash scripts/screen_board.sh --factory-restore             remove KlipperScreen, turn the factory services back on, reboot
#                                                            (also the "Factory mode" button on the screen: ZR Tools > More > System)
# Options: --no-reboot (install and restore reboot the board at the end), --force (ignore a running print), --yes, --no-rescue (skip the rescue window and the USB flag, see screen_rescue/)
#
# What it does: stops and DISABLES the factory screen app and the services that now run on the Pi (nothing is deleted, the list
# is saved in ~/wm-screen-backup), installs KlipperScreen (the pinned commit) + ZR Tools, and points it at the Pi's Moonraker.
# What it never does: flash anything, run "apt upgrade", touch the factory printer_data or the printer's MCUs.
# =============================================================================
set -u
export PIP_DISABLE_PIP_VERSION_CHECK=1   # pip must not ask PyPI for a newer pip (slow links print a warning)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; DIM='\033[2m'; NC='\033[0m'
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WM_USER="t13dp"
TESTING="${WM_INSTALLER_TEST:-0}"
if [ -n "${WM_HOME:-}" ]; then HOME_DIR="$WM_HOME"; elif [ "$(id -u)" = 0 ]; then HOME_DIR="/home/$WM_USER"; else HOME_DIR="$HOME"; fi
BK="$HOME_DIR/wm-screen-backup"
KS_DIR="$HOME_DIR/KlipperScreen"; KS_ENV="$HOME_DIR/.KlipperScreen-env"
CFG_DIR="$HOME_DIR/printer_data/config"
NOARGS=0; [ $# -eq 0 ] && NOARGS=1
FIXALL=0; ARG1=""; ARG_BACKUP=""; MODE=install; RESCUE=1; DRY=0; PI_HOST=""; DRIVER=modesetting; REBOOT=1; FORCE=0; DETACH=0
STAMP="$(date +%Y%m%d-%H%M%S)"
# Services stopped and disabled, in this order (restore starts them in reverse order). Only those that exist are touched.
SERVICES=(makerbase-client klipper moonraker nginx crowsnest makerbase-webcam janus klipper-mcu hostapd moonraker-obico octoapp)
XDIR="/etc/X11/xorg.conf.d"
# The factory board's service state, used when ~/wm-screen-backup/disabled.list is missing (so a restore can never leave the board stuck).
# Same 8 services as on a factory WM-ZR-M board. Keep identical to FACTORY_DEFAULT in screen_rescue/wm-screen-rescue (a test checks it).
FACTORY_DEFAULT="makerbase-client enabled active
klipper disabled active
moonraker enabled active
nginx enabled active
crowsnest enabled inactive
makerbase-webcam enabled inactive
klipper-mcu enabled active
hostapd disabled inactive"
declare -a WARNINGS=()

sb_cum() {   # step weight... : the percent finished when step K starts (the weights are how long each step takes, roughly)
    local k="$1" i=1 sum=0 w; shift
    for w in "$@"; do [ "$i" -lt "$k" ] && sum=$((sum+w)); i=$((i+1)); done
    echo "$sum"
}
print_header()  {
    echo -e "\n${BLUE}── $1 ──────────────────────────────────────────${NC}"
    if [ "${SB_PROG:-0}" = 2 ]; then   # back to factory mode
        local r=""; case "$1" in "Removing KlipperScreen") r=1 ;; "Turning the factory services back on") r=2 ;; esac
        [ -n "$r" ] && progress_bar "$(sb_cum "$r" 60 30 10)" 100 "Factory restore step $r of 3"; return 0
    fi
    [ "${SB_PROG:-0}" = 1 ] || return 0
    local k=""; case "$1" in "Checking this board") k=1 ;; "Installing packages"*) k=2 ;; "Installing KlipperScreen"*) k=3 ;; "Stopping the factory services"*) k=4 ;; "Factory mode button") k=5 ;; "Rescue tool"*) k=6 ;; "Starting KlipperScreen") k=7 ;; esac
    [ -n "$k" ] && progress_bar "$(sb_cum "$k" 2 25 50 3 2 3 15)" 100 "Install step $k of 7"
    return 0
}
PROG_STEPS=0
prog_repeat() { local s="" i; for ((i=0;i<$2;i++)); do s+="$1"; done; printf '%s' "$s"; }
progress_bar() {   # steps-done total label : a bar like [██████░░░░░░]  42%  label
    local n="$1" t="$2" label="${3:-}" w=24 f pct
    [ "$t" -gt 0 ] 2>/dev/null || return 0
    [ "$n" -gt "$t" ] && n="$t"; [ "$n" -lt 0 ] && n=0
    pct=$((n*100/t)); f=$((n*w/t))
    printf '  %b[%s%s]%b %3d%%  %s\n' "$GREEN" "$(prog_repeat '█' "$f")" "$(prog_repeat '░' $((w-f)))" "$NC" "$pct" "$label"
    local txt; txt="$(printf '%b[%s%s]%b %3d%%  %s' "$GREEN" "$(prog_repeat '█' "$f")" "$(prog_repeat '░' $((w-f)))" "$NC" "$pct" "$label")"
    if [ "$n" -ge "$t" ]; then live_bar_stop; else live_bar_start "$txt"; fi
}
live_bar_stop() {   # stop the "still running" bar lines
    [ -n "${LIVE_PID:-}" ] || return 0
    kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null; LIVE_PID=""
}
live_bar_start() {   # text : while a slow step runs, print the same bar again on its own line every 15 s with the time so far (works in every terminal)
    live_bar_stop
    [ -t 1 ] && [ "${TESTING:-0}" != 1 ] && [ "${DRY:-0}" != 1 ] || return 0
    local main=$$ text="$1" every="${LIVE_BAR_EVERY:-15}"
    ( local t0 s; t0="$(date +%s)"
      while sleep "$every" && kill -0 "$main" 2>/dev/null; do
          s=$(( $(date +%s) - t0 ))
          printf '  %s  | %dm%02ds\n' "$text" $((s/60)) $((s%60))
      done ) &
    LIVE_PID=$!
}
heartbeat_start() {   # slow command ahead: say "still working" every 30 s so it does not look frozen
    [ "$TESTING" = 1 ] || [ "$DRY" = 1 ] && return 0
    local t0 label="$1"; t0="$(date +%s)"
    ( while sleep 30 && kill -0 $$ 2>/dev/null; do echo -e "  ${DIM}... still working: $label ($(( ($(date +%s)-t0)/60 )) min $(( ($(date +%s)-t0)%60 )) s)${NC}"; done ) &
    HB_PID=$!
}
heartbeat_stop() { [ -n "${HB_PID:-}" ] && { kill "$HB_PID" 2>/dev/null; wait "$HB_PID" 2>/dev/null; HB_PID=""; }; return 0; }

print_info()    { echo -e "${BLUE}ℹ ${1}${NC}"; }
print_success() { echo -e "${GREEN}✓ ${1}${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ ${1}${NC}"; }
print_error()   { echo -e "${RED}✗ ${1}${NC}"; }
warn_later()    { WARNINGS+=("$1"); }
die_with_fix()  { live_bar_stop; print_error "Can't continue: $1"; echo -e "  Fix: $2"; rm -rf "${LATEST_TMP:-}"; exit 1; }
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
        --menu) MODE=menu ;;
        --free-space) MODE=freespace ;;
        --fix-clock) MODE=fixclock ;;
        --zr-pi) MODE=zrpi ;;
        --install) MODE=install; NOARGS=0 ;;
        --update) MODE=update ;;
        --check-updates|--whats-new) MODE=whatsnew ;;
        --remove) MODE=removefiles; ARG1="${2:-}"; shift ;;
        --doctor) MODE=doctor ;;
        --fix-all) FIXALL=1 ;;
        --backup) MODE=backup ;;
        --restore-backup) MODE=restorebk; case "${2:-}" in [0-9]*) ARG_BACKUP="$2"; shift ;; esac ;;
        --support-bundle) MODE=bundle ;;
        --log) MODE=log ;;
        --restart-screen) MODE=restartks ;;
        --system) MODE=system; case "${2:-}" in tz:*|host:*) ARG1="$2"; shift ;; esac ;;
        --set-driver) MODE=setdriver; case "${2:-}" in modesetting|fbdev) DRIVER="$2" ;; *) print_error "--set-driver needs modesetting or fbdev"; exit 1 ;; esac; shift ;;
        --status) MODE=status ;;
        --uninstall-klipperscreen) MODE=uninstall ;;
        --factory-restore) MODE=restore ;;
        --no-rescue) RESCUE=0 ;;
        --no-reboot) REBOOT=0 ;;
        --force) FORCE=1 ;;
        --detach) DETACH=1 ;;
        --dry-run) DRY=1 ;;
        --yes) WM_ASSUME_YES=1 ;;
        -h|--help) sed -n '3,/^# What it never does/p' "$0" | sed '1,2d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# No options at a terminal: open the menu (use --install to go straight to the install)
[ "$NOARGS" = 1 ] && { [ -t 0 ] || [ "${WM_TEST_MENU_DEFAULT:-0}" = 1 ]; } && MODE=menu

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
fix_clock() {   # automatic time sync (NTP): with a wrong date HTTPS downloads and apt fail. Asks once; nothing else on the board is changed.
    print_header "Date and time"
    progress_bar 0 2 "Date and time 1 of 2: looking at the clock"
    local synced now
    if [ "$TESTING" = 1 ]; then synced="${WM_TEST_NTP_SYNCED:-no}"
    else synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"; fi
    now="$(date '+%Y-%m-%d %H:%M %Z')"
    if [ "$synced" = yes ]; then print_success "The clock is set automatically (NTP): $now"; return 0; fi
    echo "  The board's clock is not synchronised automatically. Now: $now"
    echo -e "  ${DIM}Why: a wrong date makes HTTPS downloads and apt fail. Automatic time sync (systemd-timesyncd) keeps it right whenever the board is online.${NC}"
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: sudo timedatectl set-ntp true (and set the date from GitHub's reply if NTP cannot reach a server)${NC}"; return 0; fi
    local stamp="$HOME_DIR/.wm-ntp-asked" age
    if [ -f "$stamp" ]; then age=$(( $(date +%s) - $(cat "$stamp" 2>/dev/null || echo 0) )); if [ "$age" -ge 0 ] && [ "$age" -lt 3600 ]; then print_info "Automatic time sync was turned on a few minutes ago; the clock can take a little while to catch up. Not asking again."; return 0; fi; fi
    ask_yn "Turn on automatic time sync (NTP)?" y || { print_info "Left as it is. If downloads fail with certificate errors, run: bash scripts/screen_board.sh --fix-clock"; return 0; }
    date +%s > "$stamp"
    if [ "$TESTING" = 1 ]; then
        echo "[test] sudo timedatectl set-ntp true" >> "$HOME_DIR/.sudo.log"
        if [ "${WM_TEST_NTP_FAIL:-0}" = 1 ]; then echo "[test] sudo date -s (from the GitHub Date header)" >> "$HOME_DIR/.sudo.log"; print_success "Clock set from GitHub's reply (test)"; else print_success "Automatic time sync is on (test)"; fi
        return 0
    fi
    command -v timedatectl >/dev/null 2>&1 || SUDO apt-get install -y systemd-timesyncd >/dev/null 2>&1
    SUDO timedatectl set-ntp true 2>/dev/null || SUDO systemctl enable --now systemd-timesyncd 2>/dev/null
    progress_bar 1 2 "Date and time 2 of 2: waiting for a time server"
    local i; for i in $(seq 1 15); do [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && break; sleep 2; done
    progress_bar 2 2 "Done"
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; then print_success "Automatic time sync is on: $(date '+%Y-%m-%d %H:%M %Z')"; return 0; fi
    # No NTP server reachable (some networks block port 123): take the time from the Date header of a web server, once
    local d; d="$(curl -sI -m 8 http://github.com 2>/dev/null | sed -n 's/^[Dd]ate: *//p' | tr -d '\r' | head -1)"
    if [ -n "$d" ] && sudo date -u -s "$d" >/dev/null 2>&1; then print_success "NTP is on but no time server answered yet; the clock was set once from GitHub's reply: $(date '+%Y-%m-%d %H:%M %Z')"
    else warn_later "Could not set the clock. Set it by hand: sudo date -s 'YYYY-MM-DD HH:MM:SS'"; fi
}

ZR_SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no)
ZR_PI_USER=""; ZR_PI_PASS=""; WANT_ZR_PI=0
zr_pi_ask() {   # the Pi login for this run only. The password is kept in a variable until the end and is never written to a file or a command line.
    local u
    if [ "$TESTING" = 1 ]; then ZR_PI_USER="${WM_TEST_PI_USER:-$WM_USER}"; ZR_PI_PASS="${WM_TEST_PI_PASS:-x}"; return 0; fi
    read -r -p "$(echo -e "${YELLOW}?${NC} User name on the Pi [$WM_USER]: ")" u || u=""; ZR_PI_USER="${u:-$WM_USER}"
    [[ "$ZR_PI_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { print_warning "'$ZR_PI_USER' is not a valid user name."; return 1; }
    read -r -s -p "$(echo -e "${YELLOW}?${NC} Password of $ZR_PI_USER on the Pi (not shown, not saved): ")" ZR_PI_PASS || ZR_PI_PASS=""; echo
    [ -n "$ZR_PI_PASS" ] || { print_warning "No password typed."; return 1; }
}
zr_on_pi() {   # check the ZR Tools macros on the Pi; install what is missing; "already installed" when nothing is. Needs PI_HOST, ZR_PI_USER, ZR_PI_PASS
    print_header "ZR Tools macros on the Pi ($PI_HOST)"
    echo -e "  ${DIM}Why: the ZR Tools page on this board sends macros such as ZR_LOAD to Klipper on the Pi. They must be installed there too.${NC}"
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would log in to ${ZR_PI_USER:-$WM_USER}@$PI_HOST, check zr_tools.cfg, the include line and [save_variables], and add what is missing${NC}"; return 0; fi
    local out rc src="$REPO_DIR/zr_tools"
    [ -f "$src/ensure_zr_tools_pi.sh" ] || { warn_later "ZR Tools on the Pi: $src/ensure_zr_tools_pi.sh is missing. Update this installer and try again."; return 1; }
    if [ "$TESTING" = 1 ]; then
        [ -n "${WM_TEST_PI_HOME:-}" ] || { warn_later "ZR Tools on the Pi: no test Pi."; return 1; }
        [ "${WM_TEST_PI_PASS:-x}" = wrong ] && { print_error "The Pi refused the user name or password."; return 1; }
        out="$(HOME="$WM_TEST_PI_HOME" ZR_SRC="$src" ZR_NO_RESTART=1 ZR_PRINT_STATE="${WM_TEST_PI_PRINT_STATE:-standby}" bash "$src/ensure_zr_tools_pi.sh" 2>&1)"
    else
        command -v sshpass >/dev/null 2>&1 || { print_info "Installing sshpass (it lets this script type the password for you)."; SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y sshpass >/dev/null 2>&1 || true; }
        command -v sshpass >/dev/null 2>&1 || { warn_later "ZR Tools on the Pi: sshpass could not be installed. On the Pi run: ./installer.sh --zr-tools"; return 1; }
        export SSHPASS="$ZR_PI_PASS"
        sshpass -e ssh "${ZR_SSH_OPTS[@]}" "$ZR_PI_USER@$PI_HOST" true 2>/dev/null; rc=$?
        if [ "$rc" = 5 ]; then unset SSHPASS; print_error "The Pi refused the user name or password."; return 1
        elif [ "$rc" != 0 ]; then unset SSHPASS; print_error "Could not reach $ZR_PI_USER@$PI_HOST over ssh (is ssh on, is the address right?)."; return 1; fi
        out="$(tar -C "$src" -cf - zr_tools.cfg install_zr_tools.sh ensure_zr_tools_pi.sh | sshpass -e ssh "${ZR_SSH_OPTS[@]}" "$ZR_PI_USER@$PI_HOST" \
              'd=$(mktemp -d) && tar -xf - -C "$d" && ZR_SRC="$d" ZR_NO_RESTART=1 bash "$d/ensure_zr_tools_pi.sh"; r=$?; rm -rf "$d"; exit $r' 2>&1)"
        unset SSHPASS
    fi
    echo "$out" | grep -v '^ZR_RESULT=' | sed 's/^/  /'
    case "$out" in
        *ZR_RESULT=already*) print_success "ZR Tools macros are already installed on the Pi. Nothing was changed."; ZR_PI_CHANGED=0 ;;
        *ZR_RESULT=installed*) print_success "ZR Tools macros installed and configured on the Pi."; ZR_PI_CHANGED=1 ;;
        *ZR_RESULT=printing*) warn_later "The Pi is printing, so the ZR Tools macros were not installed there. Try again after the print."; return 1 ;;
        *) warn_later "ZR Tools macros could not be installed on the Pi (see above). On the Pi run: ./installer.sh --zr-tools"; return 1 ;;
    esac
}
ZR_PI_CHANGED=0
do_zr_pi() {   # --zr-pi: only this
    progress_bar 0 3 "ZR Tools on the Pi 1 of 3: Pi login"
    ask_pi; zr_pi_ask || die_with_fix "no Pi login." "run it again and type the user name and password."
    progress_bar 1 3 "ZR Tools on the Pi 2 of 3: checking and installing on the Pi"
    zr_on_pi && [ "$ZR_PI_CHANGED" = 1 ] && { progress_bar 2 3 "ZR Tools on the Pi 3 of 3: restarting Klipper"; restart_pi_klipper; }
    progress_bar 3 3 "Done"
    ZR_PI_PASS=""
    [ ${#WARNINGS[@]} -gt 0 ] && { local w; for w in "${WARNINGS[@]}"; do print_warning "$w"; done; return 1; }
    return 0
}

disk_free_mb() { [ "$TESTING" = 1 ] && { echo "${WM_TEST_DISK_MB:-4000}"; return; }; df -Pm "$HOME_DIR" | awk 'NR==2{print $4}'; }

# ---------------------------------------------------------------- free up disk space
FREE_NEED_MB=1500
FS_LOGS_DIR="$CFG_DIR/../logs"
# shared with installer.sh
# shellcheck source=scripts/lib_free_space.sh
. "$SCRIPT_DIR/lib_free_space.sh" || { echo "scripts/lib_free_space.sh is missing; run: bash scripts/screen_board.sh --update"; exit 1; }

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
    local free; free="$(disk_free_mb)"
    if [ "${free:-0}" -le "$FREE_NEED_MB" ] && { [ -t 0 ] || [ "${WM_TEST_FREE_OFFER:-0}" = 1 ]; } && [ "${WM_ASSUME_YES:-0}" != 1 ]; then
        print_warning "Only ${free} MB free; the install needs about $FREE_NEED_MB MB."
        echo "  I can look for files that are safe to erase and show you each one before anything is deleted."
        ask_yn "Look for files to erase now?" y && { do_free_space; free="$(disk_free_mb)"; }
    fi
    [ "${free:-0}" -gt "$FREE_NEED_MB" ] && print_success "disk space ${free} MB free" || die_with_fix "only ${free} MB free." "free space first: bash scripts/screen_board.sh --free-space  (it shows what is safe to erase and asks before deleting)."
    apt_fix; fix_clock; apt_ok && print_success "apt works (archive.debian.org)" || die_with_fix "apt update fails." "check the board's internet access and date; see README 'Screen board'. Nothing was changed."
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
    # This board's kernel has no swap support (no /proc/swaps): do not promise or try it
    if [ "$TESTING" != 1 ] && [ ! -e /proc/swaps ]; then print_info "Only ${mem} MB RAM and this kernel has no swap: the Python build is slow but works."; return 0; fi
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would add a temporary 768 MB swap file ($SWAPFILE)${NC}"; return 0; fi
    if [ "$TESTING" = 1 ]; then echo "[test] swapfile $SWAPFILE" >> "$HOME_DIR/.sudo.log"; return 0; fi
    sudo fallocate -l 768M "$SWAPFILE" && sudo chmod 600 "$SWAPFILE" && sudo mkswap "$SWAPFILE" >/dev/null && sudo swapon "$SWAPFILE" && { print_info "Temporary swap added (removed at the end)"; trap drop_swap EXIT; } \
        || { sudo rm -f "$SWAPFILE"; warn_later "Could not add swap: the Python build may run out of memory."; }
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
    heartbeat_start "installing packages"
    SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-upgrade $APT_PKGS || { heartbeat_stop; die_with_fix "apt could not install the packages." "see the messages above; rerun this script after fixing. The factory services are still running (nothing was disabled yet)."; }
    heartbeat_stop
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
        heartbeat_start "building KlipperScreen's Python packages (can take 15 minutes on this board)"
        "$KS_ENV/bin/pip" --disable-pip-version-check install -r "$KS_DIR/scripts/KlipperScreen-requirements.txt" \
            || { "$KS_ENV/bin/pip" install --upgrade pip setuptools wheel && "$KS_ENV/bin/pip" install --prefer-binary -r "$KS_DIR/scripts/KlipperScreen-requirements.txt"; } \
            || { heartbeat_stop; die_with_fix "pip could not install KlipperScreen's Python packages." "see the messages above (PyGObject needs the packages that were just installed). The factory services are still running."; }
        heartbeat_stop
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
[printer WonderMaker]
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
    [ -f "$CFG_DIR/zr_screen.conf" ] || printf '# Written by screen_board.sh and the ZR Tools Settings page\n[screen]\nlayout = tabs\ndensity = comfortable\ntheme = dark\n' > "$CFG_DIR/zr_screen.conf"
}

# The board's kernel has no virtual console (/dev/tty0), so stock KlipperScreen cannot start. Verified on the board (Nov 3, 2026):
# X starts when it runs on its OWN seat (-seat seat1, no VT needed) with the display, framebuffer and touch assigned to that seat.
KS_START=/usr/local/sbin/wm-ks-start; KS_CLIENT=/usr/local/sbin/wm-ks-client; XINPUT=/etc/X11/wm-ks-input.conf; TOUCH_RULE=/etc/udev/rules.d/72-wm-touch-seat1.rules
write_service() {
    local svc=/etc/systemd/system/KlipperScreen.service
    # 3 failed starts within 2 minutes: stop retrying and open the rescue window (wm-screen-rescue.service)
    local RESCUE_UNIT_LINES=""; [ "$RESCUE" = 1 ] && RESCUE_UNIT_LINES=$'StartLimitIntervalSec=120\nStartLimitBurst=3\nOnFailure=wm-screen-rescue.service'
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
$RESCUE_UNIT_LINES

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

# ---------------------------------------------------------------- rescue tool (window after 3 failed starts, USB flag at boot)
RESCUE_BIN=/usr/local/sbin/wm-screen-rescue; RESCUE_WIN=/usr/local/sbin/wm-rescue-window.py
step_rescue() {
    [ "$RESCUE" = 1 ] || { print_info "Rescue tool skipped (--no-rescue)."; return 0; }
    print_header "Rescue tool (window if KlipperScreen fails, USB stick flag)"
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would install $RESCUE_BIN, $RESCUE_WIN, two systemd units and a saved copy of KlipperScreen in $BK${NC}"; return 0; fi
    mkdir -p "$BK/known-good"
    cp -p "$CFG_DIR/KlipperScreen.conf" "$CFG_DIR/zr_screen.conf" "$BK/known-good/" 2>/dev/null
    tar czf "$BK/ks-program.tar.gz" -C "$HOME_DIR" KlipperScreen 2>/dev/null || warn_later "Could not save a copy of KlipperScreen: the rescue window's 'Reinstall files' will not be available."
    if [ "$TESTING" = 1 ]; then echo "[test] rescue tool: scripts, units, sudoers, usb check" >> "$HOME_DIR/.sudo.log"; return 0; fi
    sudo install -o root -g root -m 755 "$REPO_DIR/screen_rescue/wm-screen-rescue" "$RESCUE_BIN"
    sudo install -o root -g root -m 755 "$REPO_DIR/screen_rescue/wm-rescue-window.py" "$RESCUE_WIN"
    sudo tee /etc/X11/wm-rescue-fbdev.conf >/dev/null <<'E'
Section "Device"
    Identifier "wm-rescue-fb"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
EndSection
Section "InputClass"
    Identifier "wm touchscreen"
    MatchIsTouchscreen "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection
E
    sudo tee /etc/systemd/system/wm-screen-rescue.service >/dev/null <<E
[Unit]
Description=WonderMaker screen rescue window (own X server)
Conflicts=KlipperScreen.service
After=systemd-udevd.service systemd-logind.service

[Service]
Type=simple
ExecStart=$RESCUE_BIN window
E
    sudo tee /etc/systemd/system/wm-screen-usb.service >/dev/null <<E
[Unit]
Description=Look for WM-FACTORY or WM-RESCUE on a USB stick (boot only)
After=local-fs.target systemd-udevd.service

[Service]
Type=oneshot
ExecStart=$RESCUE_BIN usb-check

[Install]
WantedBy=multi-user.target
E
    printf '%s ALL=(root) NOPASSWD: %s open\n' "$WM_USER" "$RESCUE_BIN" | sudo tee /etc/sudoers.d/wm-screen-rescue >/dev/null
    sudo chmod 440 /etc/sudoers.d/wm-screen-rescue; sudo visudo -cf /etc/sudoers.d/wm-screen-rescue >/dev/null || { sudo rm -f /etc/sudoers.d/wm-screen-rescue; warn_later "The Rescue entry in ZR Tools was not enabled (sudoers check failed)."; }
    sudo systemctl daemon-reload; sudo systemctl enable wm-screen-usb.service >/dev/null 2>&1
    print_success "Rescue tool installed. USB stick: an empty file WM-FACTORY (restore) or WM-RESCUE (window), checked at boot."
}
remove_rescue() {
    SUDO systemctl stop wm-screen-rescue.service; SUDO systemctl disable wm-screen-usb.service
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would remove the rescue tool${NC}"; return 0; fi
    if [ "$TESTING" = 1 ]; then echo "[test] remove rescue tool" >> "$HOME_DIR/.sudo.log"
    else
        sudo rm -f /etc/systemd/system/wm-screen-rescue.service /etc/systemd/system/wm-screen-usb.service /etc/sudoers.d/wm-screen-rescue \
                   "$RESCUE_BIN" "$RESCUE_WIN" /etc/X11/wm-rescue-fbdev.conf /run/wm-rescue.reason; sudo systemctl daemon-reload
    fi
    rm -rf "$BK/known-good" "$BK/ks-program.tar.gz"      # the rescue snapshots of your settings stay in $BK/rescue-snapshots
}

do_install() {
    SB_PROG=1
    echo -e "${BLUE}KlipperScreen on the WonderMaker screen board${NC}"
    [ "$DRY" = 1 ] && print_info "DRY RUN: nothing will be changed."
    preflight
    print_header "Plan (nothing has been changed yet)"
    echo "  Stops and disables (restored later): $(for u in "${SERVICES[@]}"; do svc_exists "$u" && printf '%s ' "$u"; done)"
    echo "  Installs: X11 + KlipperScreen packages, KlipperScreen (pinned) in ~/KlipperScreen, ZR Tools, a Factory-mode button$([ "$RESCUE" = 1 ] && echo ', a rescue window and USB-stick flag')"
    echo "  Connects to: $(pi_url)   Graphics driver: $DRIVER (falls back to fbdev if X does not start)"
    echo "  Go back any time: bash $BK/screen_board.sh --factory-restore"
    if [ "$DRY" = 1 ]; then echo "  Optional: set up the ZR Tools macros on the Pi $PI_HOST too (asks for the Pi user name and password, default no)"
    else
        echo "  The ZR Tools page needs its macros on the Pi. If they are not there yet, this script can install them for you."
        if ask_yn "Also check and set up the ZR Tools macros on the Pi $PI_HOST now? (asks for its password; nothing is saved)" n; then zr_pi_ask && WANT_ZR_PI=1 || print_warning "Skipping ZR Tools on the Pi. Later: bash scripts/screen_board.sh --zr-pi --pi $PI_HOST"; fi
    fi
    [ "$DRY" = 1 ] || ask_yn "Go ahead?" y || { echo "Nothing changed."; exit 0; }
    save_state
    add_swap
    step_packages
    step_klipperscreen          # everything that can fail comes BEFORE the factory app is stopped
    drop_swap
    step_disable_factory
    step_restore_button
    step_rescue
    step_start
    print_header "Done"; progress_bar 100 100 "All 7 steps finished"
    if [ ${#WARNINGS[@]} -gt 0 ]; then local w; for w in "${WARNINGS[@]}"; do print_warning "$w"; done; fi
    print_success "KlipperScreen is set up. Go back: ZR Tools > More > System > Factory mode, or bash $BK/screen_board.sh --factory-restore"
    if [ "$WANT_ZR_PI" = 1 ] || [ "$DRY" = 1 ]; then zr_on_pi || true; ZR_PI_PASS=""; fi
    restart_pi_klipper
    if [ "$DRY" != 1 ] && [ "$REBOOT" = 1 ]; then      # a clean start: every service, the screen server and the touch rules come up together
        echo "  A reboot starts every service, the screen server and the touch rules together. It is recommended."
        if ask_yn "Reboot the board now?" y; then
            print_info "Rebooting in 10 seconds (Ctrl+C cancels)."
            [ "$TESTING" = 1 ] || sleep 10
            SUDO systemctl reboot
        else print_info "Not rebooting. Reboot when you are ready: sudo reboot"; fi
    fi
}

# ---------------------------------------------------------------- uninstall / restore
remove_klipperscreen() {
    print_header "Removing KlipperScreen"
    remove_rescue
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
    if [ -d "$KS_DIR" ] || [ -f /etc/systemd/system/KlipperScreen.service ]; then do_restore; return; fi   # no saved list: the built-in factory list is used
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
    SB_PROG=2
    print_header "Back to the WonderMaker factory software"
    if [ ! -s "$BK/disabled.list" ]; then
        print_warning "No saved service list ($BK/disabled.list): using the built-in list of the factory services."
        if [ "$DRY" != 1 ]; then mkdir -p "$BK"; printf '%s\n' "$FACTORY_DEFAULT" > "$BK/disabled.list"; fi
    fi
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
    progress_bar 100 100 "Factory restore finished"
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
    if [ "$TESTING" = 1 ]; then [ -f "$BK/known-good/KlipperScreen.conf" ] && echo "  Rescue tool: installed"; else [ -x "$RESCUE_BIN" ] && echo "  Rescue tool: installed (window after 3 failed starts; USB stick: WM-FACTORY / WM-RESCUE)" || echo "  Rescue tool: not installed"; fi
    [ -d "$KS_DIR" ] && echo "  KlipperScreen: installed ($KS_DIR)" || echo "  KlipperScreen: not installed"
    [ -f "$BK/board_mode" ] && echo "  Mode: KlipperScreen ($(cat "$BK/board_mode"))" || echo "  Mode: factory"
    [ -f "$BK/disabled.list" ] && echo "  Saved list for restore: $BK/disabled.list ($(wc -l < "$BK/disabled.list") services)"
}

restart_pi_klipper() {   # after an install or update: restart Klipper on the Pi through its Moonraker, then check it comes back
    [ "$DRY" = 1 ] && return 0
    local h="${PI_HOST:-}" u r st i
    [ -z "$h" ] && [ -f "$CFG_DIR/KlipperScreen.conf" ] && h="$(sed -n 's/^moonraker_host: *//p' "$CFG_DIR/KlipperScreen.conf" | head -1)"
    [ -n "$h" ] || { print_info "No Pi address known, so Klipper on the Pi was not restarted."; return 0; }
    u="http://$h:7125"
    if [ "$TESTING" = 1 ]; then echo "[test] restart klipper on $h via moonraker" >> "$HOME_DIR/.sudo.log"; print_success "Klipper on the Pi restarted through Moonraker (test)"; return 0; fi
    r="$(curl -fsS -m 6 "$u/printer/objects/query?print_stats" 2>/dev/null)" || { print_info "The Pi ($h) does not answer, so Klipper there was not restarted. Restart it from Fluidd when the Pi is on."; return 0; }
    if echo "$r" | grep -q '"state": *"\(printing\|paused\)"'; then print_warning "The Pi is printing, so Klipper there was not restarted."; return 0; fi
    curl -fsS -m 15 -X POST "$u/machine/services/restart?service=klipper" >/dev/null 2>&1 || { print_warning "The Pi refused the restart. Its moonraker.conf must trust this board's address (trusted_clients). Restart Klipper from Fluidd."; return 0; }
    local t0 el last=0; t0="$(date +%s)"
    print_info "Waiting for Klipper on the Pi to start (up to 60 seconds) ..."
    while :; do
        el=$(( $(date +%s) - t0 )); [ "$el" -lt 60 ] || break
        sleep 2; st="$(curl -fsS -m 4 "$u/printer/info" 2>/dev/null | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p' | head -1)"
        [ $(( el / 15 )) -gt "$last" ] && { last=$(( el / 15 )); echo -e "  ${DIM}... still waiting: Klipper on the Pi is '${st:-not answering}' (${el} s)${NC}"; }
        [ "$st" = ready ] && { print_success "Klipper on the Pi restarted and is ready."; return 0; }
        [ "$st" = error ] || [ "$st" = shutdown ] && { print_warning "Klipper on the Pi restarted but reports '$st'. Look at the message in Fluidd."; return 0; }
    done
    print_warning "Klipper on the Pi restarted but is not ready yet. Check Fluidd."
}
do_setdriver() {   # switch the graphics driver of an installed KlipperScreen without reinstalling
    [ -d "$KS_DIR" ] || [ "$TESTING" = 1 ] || die_with_fix "KlipperScreen is not installed here." "run the installer first."
    guard_printing
    if [ "$DRIVER" = fbdev ]; then use_fbdev
    elif [ "$DRY" = 1 ]; then echo -e "  ${DIM}would switch X back to the modesetting driver${NC}"
    elif [ "$TESTING" = 1 ]; then echo "[test] modesetting driver" >> "$HOME_DIR/.sudo.log"; rm -f "$HOME_DIR/.fbdev"
    else
        [ -f "$XDIR/10-wm-fbdev.conf" ] && sudo rm -f "$XDIR/10-wm-fbdev.conf"
        [ -f "$XDIR/20-modesetting.conf.wm-disabled" ] && sudo mv "$XDIR/20-modesetting.conf.wm-disabled" "$XDIR/20-modesetting.conf"
    fi
    SUDO systemctl restart KlipperScreen
    print_success "Graphics driver is now $DRIVER. If the screen stays black, switch back: bash scripts/screen_board.sh --set-driver $([ "$DRIVER" = fbdev ] && echo modesetting || echo fbdev)"
}
guard_printing() { [ "$FORCE" = 1 ] || ! printing_now || die_with_fix "a print is running on this board." "wait for it to finish, or add --force."; }

# ---------------------------------------------------------------- more tools for the menu
BKDIR="$HOME_DIR/wm-screen-backups"
board_scrub() { sed -E 's/((password|passwd|token|api_?key|secret|ssid|psk|key)[[:space:]]*[:=][[:space:]]*).*/\1<removed>/I; s/\b(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)\b/<private-ip>/g; s/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/<mac>/g'; }
need_ks() { [ -d "$KS_DIR" ] || [ "$TESTING" = 1 ] || die_with_fix "KlipperScreen is not installed here." "run the installer first (menu: Install)."; }

do_backup_board() {
    print_header "Backup of the screen settings"
    local out="$BKDIR/screen-backup-$STAMP.tgz" items=() i
    mkdir -p "$BKDIR"
    for i in printer_data/config/KlipperScreen.conf printer_data/config/zr_screen.conf wm-screen-backup/disabled.list wm-screen-backup/board_mode; do [ -e "$HOME_DIR/$i" ] && items+=("$i"); done
    [ "${#items[@]}" -gt 0 ] || die_with_fix "nothing to back up (KlipperScreen is not installed here)." "install first."
    tar czf "$out" -C "$HOME_DIR" "${items[@]}" 2>/dev/null || die_with_fix "could not write the backup." "free disk space."
    chmod 600 "$out"
    print_success "Saved $out"
    echo "  It holds the KlipperScreen and ZR Tools settings and the list of factory services to turn back on."
}
do_restore_board() {
    print_header "Restore a screen backup"
    local list=() f n=0 pick
    for f in $(ls -1t "$BKDIR"/screen-backup-*.tgz 2>/dev/null); do list+=("$f"); done
    [ "${#list[@]}" -gt 0 ] || die_with_fix "no backups in $BKDIR." "make one first (menu: Backup and restore)."
    for f in "${list[@]}"; do n=$((n+1)); echo "   $n) $(basename "$f")"; done
    if [ -n "${ARG_BACKUP:-}" ]; then pick="$ARG_BACKUP"
    else read -r -p "  Number to restore (Enter cancels): " pick || pick=""; fi
    [ -n "$pick" ] || { echo "Nothing changed."; return 0; }
    [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#list[@]}" ] || die_with_fix "'$pick' is not in the list." "choose one of the numbers."
    f="${list[$((pick-1))]}"
    ask_yn "Restore $(basename "$f")? A safety copy of the current settings is made first." y || { echo "Nothing changed."; return 0; }
    STAMP="$STAMP-safety" do_backup_board >/dev/null 2>&1 || true
    tar xzf "$f" -C "$HOME_DIR" || die_with_fix "could not unpack the backup." "the file may be damaged."
    SUDO systemctl restart KlipperScreen
    print_success "Settings restored from $(basename "$f")"
}
fetch_latest() {   # sets LATEST_DIR to a folder with the newest version from GitHub (no git needed)
    if [ "$TESTING" = 1 ]; then LATEST_DIR="${WM_TEST_UPDATE_DIR:-}"; [ -d "$LATEST_DIR" ]; return; fi
    LATEST_DIR="$(mktemp -d)"; LATEST_TMP="$LATEST_DIR"; trap 'rm -rf "${LATEST_TMP:-}"; exit 130' INT TERM; print_info "Downloading the newest version from GitHub ..."
    curl -fsSL -m 120 https://codeload.github.com/ducati1198/wm-ultra-rpi/tar.gz/refs/heads/main | tar -xz --strip-components=1 -C "$LATEST_DIR" || return 1
}
do_whatsnew_board() {   # reads only two small text files (VERSION and CHANGELOG.md); nothing is downloaded or saved
    print_header "What is new (read-only, changes nothing)"
    local old new base="https://raw.githubusercontent.com/ducati1198/wm-ultra-rpi/main" log
    old="$(cat "$REPO_DIR/VERSION" 2>/dev/null)"
    if [ "$TESTING" = 1 ]; then new="$(cat "${WM_TEST_UPDATE_DIR:-/nonexistent}/VERSION" 2>/dev/null)"; log="$(cat "${WM_TEST_UPDATE_DIR:-/nonexistent}/CHANGELOG.md" 2>/dev/null)"
    else new="$(curl -fsSL -m 20 "$base/VERSION" 2>/dev/null | head -1)"; log="$(curl -fsSL -m 20 "$base/CHANGELOG.md" 2>/dev/null)"; fi
    [ -n "$new" ] || die_with_fix "could not read the newest version from GitHub." "check the internet connection."
    echo "  Installed: ${old:-unknown}    Newest: $new"
    if [ "$new" = "$old" ]; then print_success "You have the latest version."; return 0; fi
    echo "  Changes since $old:"
    echo "$log" | awk -v cur="$old" '/^## /{ if ($2==cur) exit; n++ } n>0 && NF' | sed 's/^/    /' | cut -c1-170 | head -40
    echo "  To update: menu > Update > Update now (or: bash scripts/screen_board.sh --update)"
}
refresh_installer_folder() {   # the folder this script runs from must be the new version too, or the menu keeps showing the old one
    local w="$1"
    [ "$DRY" = 1 ] && return 0
    [ "$TESTING" = 1 ] && [ "${WM_TEST_REFRESH:-0}" != 1 ] && return 0   # tests must never overwrite the real repository
    if [ -d "$REPO_DIR/.git" ] && command -v git >/dev/null 2>&1 && [ "$TESTING" != 1 ]; then
        git -C "$REPO_DIR" pull --ff-only -q 2>/dev/null && return 0
        print_warning "git pull failed in $REPO_DIR (local changes?): copying the new files over it instead."
    fi
    case "$(basename "$REPO_DIR")" in wm-ultra-rpi*) ;; *) return 0 ;; esac
    [ -f "$REPO_DIR/scripts/screen_board.sh" ] && cp -a "$w"/. "$REPO_DIR"/ 2>/dev/null
    return 0
}
do_update_board() { do_update_board_core; local rc=$?; rm -rf "${LATEST_TMP:-}"; trap - INT TERM; return $rc; }   # the downloaded copy (about 50 MB) never stays in /tmp
do_update_board_core() {
    print_header "Update the ZR Tools screen files"
    local new old w; old="$(cat "$REPO_DIR/VERSION" 2>/dev/null)"
    if [ "$TESTING" = 1 ] && [ -z "${WM_TEST_UPDATE_DIR:-}" ]; then print_info "Test: no update folder."; return 0; fi
    progress_bar 0 100 "Update step 1 of 6: downloading"
    fetch_latest || die_with_fix "could not download the update." "check the internet connection."
    w="$LATEST_DIR"
    new="$(cat "$w/VERSION" 2>/dev/null)"
    [ -n "$new" ] || die_with_fix "the download has no VERSION file." "try again later."
    echo "  Installed: ${old:-unknown}    Newest: $new"
    if [ "$new" = "$old" ]; then print_success "Already up to date."; return 0; fi
    if { [ "$TESTING" != 1 ] && [ ! -d "$KS_DIR" ]; } || [ "${WM_TEST_NO_KS:-0}" = 1 ]; then   # nothing to update on the screen yet: only the installer folder is made current
        print_info "KlipperScreen is not installed on this board yet, so there are no screen files to update."
        if [ "$DRY" != 1 ] && ask_yn "Update the installer files in $REPO_DIR to $new?" y; then
            if [ "$TESTING" = 1 ] && [ "${WM_TEST_REFRESH_REPO:-0}" = 1 ]; then cp -a "$w"/. "$REPO_DIR"/ 2>/dev/null
            else refresh_installer_folder "$w"; fi
            print_success "The installer files are now version $new. Choose 1 (Install) from the menu to set up KlipperScreen."
        fi
        return 0
    fi
    need_ks; guard_printing
    echo "  This copies the new ZR Tools panels and this script's copies. KlipperScreen itself, your settings and the factory services are not touched."
    ask_yn "Update now?" y || { echo "Nothing changed."; return 0; }
    progress_bar 35 100 "Update step 2 of 6: backup of your settings"
    ( do_backup_board ) >/dev/null 2>&1 || true   # in a subshell: a failed backup (die) must not end the update
    progress_bar 40 100 "Update step 3 of 6: copying the new files"
    if [ "$DRY" != 1 ]; then
        mkdir -p "$KS_DIR/panels"; cp "$w"/zr_tools/{zr_tools.py,zr_views.py,zr_logic.py} "$KS_DIR/panels/"
        [ -f "$w/zr_tools/pi_address_panel.py" ] && cp "$w/zr_tools/pi_address_panel.py" "$KS_DIR/panels/pi_address.py"
        [ -f "$KS_DIR/panels/network.py" ] && grep -q wpa_cli "$KS_DIR/panels/network.py" 2>/dev/null && [ -f "$w/zr_tools/wifi_panel.py" ] && cp "$w/zr_tools/wifi_panel.py" "$KS_DIR/panels/network.py"
        mkdir -p "$BK"; cp "$w/scripts/screen_board.sh" "$BK/screen_board.sh"
        # the installer folder this script runs from is refreshed too, so the menu itself is the new version (tests: only with WM_TEST_REFRESH_REPO=1, on a copy)
        if [ "$TESTING" != 1 ] || [ "${WM_TEST_REFRESH_REPO:-0}" = 1 ]; then
            if [ -d "$REPO_DIR/.git" ] && command -v git >/dev/null 2>&1 && [ "$TESTING" != 1 ]; then git -C "$REPO_DIR" pull -q --ff-only 2>/dev/null || cp -a "$w"/. "$REPO_DIR"/ 2>/dev/null || warn_later "Could not refresh $REPO_DIR; run: cd $REPO_DIR && git pull"
            else cp -a "$w"/. "$REPO_DIR"/ 2>/dev/null || warn_later "Could not refresh $REPO_DIR."; fi
        fi
        [ "$TESTING" = 1 ] || { [ -f /usr/local/sbin/wm-factory-restore ] && sudo install -o root -g root -m 755 "$w/scripts/screen_board.sh" /usr/local/sbin/wm-factory-restore; }
    fi
    refresh_installer_folder "$w"
    progress_bar 55 100 "Update step 4 of 6: restarting KlipperScreen"
    SUDO systemctl restart KlipperScreen
    progress_bar 70 100 "Update step 5 of 6: restarting Klipper on the Pi"
    restart_pi_klipper
    progress_bar 100 100 "Update finished"
    print_success "Updated to $new. A backup of your settings was made first."
}
do_doctor_board() {
    print_header "Screen board doctor (asks before changing anything)"
    local bad=0 fixed=0 u f
    ok()  { echo -e "  ${GREEN}[ok]${NC}      $1"; }
    pb()  { echo -e "  ${RED}[problem]${NC} $1"; echo -e "            ${DIM}$2${NC}"; bad=$((bad+1)); }
    fixit() { if [ "${FIXALL:-0}" = 1 ] || ask_yn "  Fix: $1?" y; then shift; if "$@"; then print_success "fixed"; fixed=$((fixed+1)); else print_warning "the fix did not work"; fi; fi; }
    wait_ks() {   # up to 60 s for KlipperScreen to be running (the board is slow: the screen server starts first)
        [ "$TESTING" = 1 ] && return 0
        local i; for i in $(seq 1 30); do svc_active KlipperScreen && return 0; sleep 2; done; return 1
    }
    start_ks() {
        SUDO systemctl restart KlipperScreen; print_info "Waiting for KlipperScreen to start (up to 60 s) ..."
        wait_ks && return 0
        echo -e "  ${DIM}Last lines of its log:${NC}"; [ "$TESTING" = 1 ] || journalctl -u KlipperScreen -n 8 --no-pager 2>/dev/null | cut -c1-150 | sed 's/^/    /'
        return 1
    }
    [ "$TESTING" = 1 ] || [ "$(id -un)" = "$WM_USER" ] || [ "$(id -u)" = 0 ] && ok "user is $(id -un)" || pb "user is $(id -un), not $WM_USER" "log in as $WM_USER."
    if [ -d "$KS_DIR" ] || [ "$TESTING" = 1 ]; then ok "KlipperScreen folder"; else pb "KlipperScreen is not installed" "menu: Install."; fi
    if [ -f "$BK/board_mode" ]; then
        svc_enabled KlipperScreen && ok "KlipperScreen starts at boot" || { pb "KlipperScreen will not start at boot" "the screen would stay black after a restart."; fixit "enable it" SUDO systemctl enable KlipperScreen; }
        if [ "$TESTING" != 1 ] && [ "$(systemctl is-active KlipperScreen 2>/dev/null)" = activating ]; then print_info "KlipperScreen is still starting, waiting up to 60 s ..."; wait_ks; fi
        if svc_active KlipperScreen; then ok "KlipperScreen is running"
        else pb "KlipperScreen is not running" "journalctl -u KlipperScreen -n 40"; fixit "start it" start_ks; fi
        for f in zr_tools.py zr_views.py zr_logic.py; do
            [ -f "$KS_DIR/panels/$f" ] && continue
            pb "ZR Tools file missing: $f" "a KlipperScreen update may have removed it."
            fixit "copy the ZR Tools files again" bash -c "mkdir -p '$KS_DIR/panels' && cp '$REPO_DIR'/zr_tools/{zr_tools.py,zr_views.py,zr_logic.py} '$KS_DIR/panels/'"; break
        done
        [ -f "$CFG_DIR/KlipperScreen.conf" ] && ok "KlipperScreen.conf exists" || pb "KlipperScreen.conf is missing" "restore a backup (menu: Backup and restore)."
        for u in "${SERVICES[@]}"; do svc_exists "$u" && svc_enabled "$u" && { pb "factory service $u is still enabled" "it would start at the next boot and fight with KlipperScreen."; fixit "disable $u" SUDO systemctl disable "$u"; }; done
        if [ "$TESTING" != 1 ]; then
            [ -x "$RESCUE_BIN" ] && ok "rescue tool installed" || print_info "rescue tool not installed (optional)"
            [ -f /usr/local/sbin/wm-factory-restore ] && ok "Factory mode button installed" || pb "Factory mode button is missing" "bash $BK/screen_board.sh --factory-restore still works."
        fi
        local h; h="$(sed -n 's/^moonraker_host: *//p' "$CFG_DIR/KlipperScreen.conf" 2>/dev/null | head -1)"
        if [ -n "$h" ]; then
            if [ "$TESTING" = 1 ] || curl -fsS -m 5 "http://$h:7125/server/info" >/dev/null 2>&1; then ok "the Pi answers at $h"; else pb "the Pi does not answer at $h" "wrong address, or the Pi is off. Change it: menu Settings > Pi address."; fi
        fi
    else
        print_info "This board is in factory mode (KlipperScreen is not installed). Nothing more to check."
    fi
    local free; free="$(disk_free_mb)"; [ "${free:-0}" -gt 300 ] && ok "disk space (${free} MB free)" || pb "only ${free} MB free" "free space before updating."
    [ -f /swapfile.wm ] && pb "a temporary swap file was left behind" "it is only needed during the install."
    echo
    if [ "$bad" = 0 ]; then print_success "No problems found."
    elif [ "$fixed" -ge "$bad" ]; then print_success "$bad problem(s) found and fixed."
    else print_warning "$bad problem(s) found, $fixed fixed, $((bad-fixed)) still open. For a report to share: bash scripts/screen_board.sh --support-bundle"; fi
}
do_bundle_board() {
    print_header "Support bundle (screen board)"
    progress_bar 0 4 "Bundle 1 of 4: system report"
    local w out="$HOME_DIR/wm-screen-support-$STAMP.tgz"; w="$(mktemp -d)"; mkdir -p "$w/b/config" "$w/b/logs"
    { echo "screen_board $(cat "$REPO_DIR/VERSION" 2>/dev/null) $(date -u +%FT%TZ) user=$(id -un)"; uname -a; grep PRETTY /etc/os-release 2>/dev/null; free -m | sed -n 2p; df -h "$HOME_DIR" | tail -1
      do_status 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; } | board_scrub > "$w/b/system.txt"
    progress_bar 1 4 "Bundle 2 of 4: settings"
    local f; for f in KlipperScreen.conf zr_screen.conf; do [ -f "$CFG_DIR/$f" ] && board_scrub < "$CFG_DIR/$f" > "$w/b/config/$f"; done
    [ -f "$BK/disabled.list" ] && cp "$BK/disabled.list" "$w/b/config/"
    progress_bar 2 4 "Bundle 3 of 4: logs"
    if [ "$TESTING" != 1 ]; then
        journalctl -u KlipperScreen -n 150 --no-pager 2>/dev/null | board_scrub > "$w/b/logs/journal-KlipperScreen.txt"
        tail -n 150 "$HOME_DIR/.local/share/xorg/Xorg.0.log" 2>/dev/null | board_scrub > "$w/b/logs/Xorg.0.log"
        tail -n 150 /tmp/KlipperScreen.log "$HOME_DIR/printer_data/logs/KlipperScreen.log" 2>/dev/null | board_scrub > "$w/b/logs/KlipperScreen.log"
    fi
    progress_bar 3 4 "Bundle 4 of 4: packing the file"
    tar czf "$out" -C "$w" b && chmod 600 "$out" && rm -rf "$w"
    progress_bar 4 4 "Done"
    print_success "Saved $out"
    echo "  Passwords, tokens, Wi-Fi names, private IP and MAC addresses are removed. Look inside before you send it."
}
do_log_board() {
    print_header "Last log lines"
    if [ "$TESTING" = 1 ]; then echo "  (test) no log"; return 0; fi
    echo "--- KlipperScreen (journal)"; journalctl -u KlipperScreen -n 25 --no-pager 2>/dev/null || sudo journalctl -u KlipperScreen -n 25 --no-pager 2>/dev/null
    echo "--- X server"; tail -n 15 "$HOME_DIR/.local/share/xorg/Xorg.0.log" 2>/dev/null
}
do_restartks() { need_ks; SUDO systemctl restart KlipperScreen; print_success "KlipperScreen restarted."; }
do_system_board() {
    print_header "Network and system (screen board)"
    echo "  Host name:  $(hostname)"
    echo "  Time zone:  $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)"
    echo "  Clock:      $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "  Addresses:  $(hostname -I 2>/dev/null)"
    command -v wpa_cli >/dev/null 2>&1 && wpa_cli -i wlan0 status 2>/dev/null | sed -n 's/^\(ssid\|wpa_state\)=/  Wi-Fi \1: /p'
    if [ -n "${ARG1:-}" ]; then
        case "$ARG1" in
            tz:*) local tz="${ARG1#tz:}"; [[ "$tz" =~ ^[A-Za-z0-9_+/-]+$ ]] || die_with_fix "'$tz' is not a time zone name." "for example America/Toronto"
                  ask_yn "Set the time zone to $tz?" y && { SUDO timedatectl set-timezone "$tz"; print_success "Time zone is $tz"; } ;;
            host:*) local h="${ARG1#host:}"; echo "$h" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$' || die_with_fix "'$h' is not a valid host name." "lower-case letters, digits and '-'."
                  ask_yn "Change the host name to $h? (takes full effect after a reboot)" n && {
                      [ "$DRY" = 1 ] || [ "$TESTING" = 1 ] || SUDO sed -i "s/^\(127\.0\.1\.1[[:space:]]\+\).*/\1$h/" /etc/hosts
                      SUDO hostnamectl set-hostname "$h"; print_success "Host name is $h"; } ;;
        esac
    fi
}
do_remove_files() {   # installer-file removal; never touches KlipperScreen itself (use --factory-restore for that)
    local what="${ARG1:-}"
    case "$what" in
        installer)
            local d="$REPO_DIR"
            case "$(basename "$d")" in wm-ultra-rpi*) ;; *) print_info "The installer folder ($d) does not look like a downloaded copy of wm-ultra-rpi: not removing it."; return 0 ;; esac
            [ "$d" != "$HOME_DIR" ] && [ "$d" != / ] && [ -f "$d/scripts/screen_board.sh" ] || { print_info "No installer folder to remove."; return 0; }
            echo "  This deletes the downloaded installer folder $d. KlipperScreen and your settings stay. A copy of this script stays in $BK (when KlipperScreen is installed)."
            ask_yn "Delete $d?" y || { echo "Nothing changed."; return 0; }
            [ "$DRY" = 1 ] && { echo -e "  ${DIM}would delete $d${NC}"; return 0; }
            cd "$HOME_DIR" 2>/dev/null || cd /
            progress_bar 1 2 "Deleting the installer folder"
            rm -rf "$d"; rm -f /tmp/screen_board_report.txt; progress_bar 100 100 "Done"; print_success "Installer folder deleted." ;;
        backups)
            local list=() f; for f in "$BKDIR" "$HOME_DIR"/wm-screen-support-*.tgz /tmp/screen_board_report.txt; do [ -e "$f" ] && list+=("$f"); done
            [ "${#list[@]}" -gt 0 ] || { print_info "No screen backups or support bundles."; return 0; }
            echo "  This deletes:"; for f in "${list[@]}"; do echo "    - $f"; done
            echo "  After this a screen-settings backup cannot be restored. Copy them off the board first if you want to keep them."
            ask_yn "Delete them?" y || { echo "Nothing changed."; return 0; }
            [ "$DRY" = 1 ] && { echo -e "  ${DIM}would delete them${NC}"; return 0; }
            progress_bar 1 2 "Deleting backups and bundles"
            rm -rf "${list[@]}"; progress_bar 100 100 "Done"; print_success "Backups and bundles deleted." ;;
        rescue)
            [ -x "$RESCUE_BIN" ] || [ -f /usr/local/sbin/wm-factory-restore ] || [ -f "$BK/known-good/KlipperScreen.conf" ] || [ "$TESTING" = 1 -a -d "$BK" ] || { print_info "The rescue tool and the Factory mode button are not installed."; return 0; }
            echo "  This removes the rescue tool (rescue window, USB stick flag) and the on-screen Factory mode button (the sudoers line and /usr/local/sbin/wm-factory-restore)."
            [ -f "$BK/board_mode" ] && echo "  KlipperScreen stays. To go back to factory mode afterwards, use: bash $BK/screen_board.sh --factory-restore"
            ask_yn "Remove them?" y || { echo "Nothing changed."; return 0; }
            progress_bar 1 3 "Removing the rescue tool"
            remove_rescue
            progress_bar 2 3 "Removing the Factory mode button"
            if [ "$DRY" != 1 ]; then
                if [ "$TESTING" = 1 ]; then echo "[test] remove factory button" >> "$HOME_DIR/.sudo.log"; else sudo rm -f /etc/sudoers.d/wm-factory-restore /usr/local/sbin/wm-factory-restore; fi
            fi
            progress_bar 100 100 "Done"; print_success "Rescue tool and Factory mode button removed." ;;
        restoredata)
            [ -d "$BK" ] || { print_info "No saved restore data ($BK)."; return 0; }
            if [ -f "$BK/board_mode" ] && [ "$FORCE" != 1 ]; then
                die_with_fix "KlipperScreen is still installed, and $BK is what a factory restore needs." "go back to factory mode first (menu: Back to factory mode), or add --force if you really want to lose the way back."
            fi
            echo "  This deletes $BK: the saved service list, the saved copy of this script, the original KlipperScreen.conf and the rescue snapshots."
            ask_yn "Delete $BK?" y || { echo "Nothing changed."; return 0; }
            [ "$DRY" = 1 ] && { echo -e "  ${DIM}would delete $BK${NC}"; return 0; }
            progress_bar 1 2 "Deleting the saved restore data"
            rm -rf "$BK"; progress_bar 100 100 "Done"; print_success "Saved restore data deleted." ;;
        *) die_with_fix "unknown name '${what}'." "use one of: installer, backups, rescue, restoredata." ;;
    esac
}
menu_uninstall() {
    while true; do
        echo; echo "  Uninstall installer files (KlipperScreen itself is not removed here; for that use Back to factory mode)"
        menu_item 1 "Rescue tool + Factory mode button" "rescue window, USB flag, on-screen button"
        menu_item 2 "My backups and bundles" "screen backups, support bundles, board report"
        menu_item 3 "Saved restore data" "only possible when KlipperScreen is gone"
        menu_item 4 "Downloaded installer folder" "the folder you ran this script from"
        menu_item 5 "Free up disk space" "shows what is safe to erase (with sizes and warnings), erases only what you pick"
        menu_item 0 "Back" ""
        menu_read "Choose:" || return 0
        case "$REPLY_MENU" in 1) menu_sub --remove rescue ;; 2) menu_sub --remove backups ;; 3) menu_sub --remove restoredata ;; 4) menu_sub --remove installer; return 0 ;; 5) menu_sub --free-space ;; 0|"") return 0 ;; *) echo "  Choose a number from the list." ;; esac
    done
}
menu_item() { printf '   %s) %-34s %b%s%b\n' "$1" "$2" "$DIM" "$3" "$NC"; }
menu_sub() {   # run this script again with options; pause so the output can be read
    echo; bash "$0" "$@"; local rc=$?; echo; [ -t 0 ] && read -r -p "  Press Enter to go back to the menu " _ || true; return $rc
}
menu_sub_script() { local f="$1"; shift; echo; bash "$SCRIPT_DIR/$f" "$@"; echo; [ -t 0 ] && read -r -p "  Press Enter to go back to the menu " _ || true; }
menu_read() { local a; read -r -p "  $1 " a || return 1; REPLY_MENU="$(echo "$a" | tr -d '[:space:]')"; return 0; }
menu_ask_pi() {   # sets PI_HOST (keeps a known one when Enter is pressed)
    local cur="$PI_HOST"; [ -z "$cur" ] && [ -f "$CFG_DIR/KlipperScreen.conf" ] && cur="$(sed -n 's/^moonraker_host: *//p' "$CFG_DIR/KlipperScreen.conf" | head -1)"
    local a; while :; do read -r -p "  IP address of your Raspberry Pi${cur:+ [$cur]}: " a || return 1
        a="${a:-$cur}"; valid_host "$a" && { PI_HOST="$a"; return 0; }; echo "  Type the Pi's IP address, for example 192.168.0.50."; done
}
menu_update() {
    while true; do
        echo; echo "  Update"
        menu_item 1 "See what is new" "reads GitHub, changes nothing"
        menu_item 2 "Update now" "downloads the newest version (backup first), then reopens the menu"
        menu_item 0 "Back" ""
        menu_read "Choose:" || return 0
        case "$REPLY_MENU" in 1) menu_sub --check-updates ;; 2) menu_sub --update; exec bash "$SCRIPT_DIR/screen_board.sh" --menu ;; 0|"") return 0 ;; *) echo "  Choose a number from the list." ;; esac
    done
}
menu_fix() {
    while true; do
        echo; echo "  Check and fix"
        menu_item 1 "Doctor" "finds problems, offers a fix for each (asks first)"
        menu_item 2 "Fix everything" "Doctor, then applies every safe fix after one question"
        menu_item 3 "Status" "read-only"
        menu_item 4 "Show the last log" "KlipperScreen and X server log lines"
        menu_item 5 "Restart the screen" "restarts KlipperScreen"
        menu_item 6 "Board report (read-only)" "writes /tmp/screen_board_report.txt to send for help"
        menu_item 7 "Pre-check (READY / NOT READY)" "read-only"
        menu_item 0 "Back" ""
        menu_read "Choose:" || return 0
        case "$REPLY_MENU" in 1) menu_sub --doctor ;; 2) menu_sub --doctor --fix-all ;; 3) menu_sub --status ;; 4) menu_sub --log ;; 5) menu_sub --restart-screen ;;
            6) menu_sub_script screen_board_inspect.sh ;; 7) menu_sub_script screen_board_precheck.sh --local-test ;; 0|"") return 0 ;; *) echo "  Choose a number from the list." ;; esac
    done
}
menu_backup() {
    while true; do
        echo; echo "  Backup and restore"
        menu_item 1 "Back up my screen settings" "saves KlipperScreen.conf, ZR Tools settings and the factory-services list"
        menu_item 2 "Restore a backup" "pick one from the list; a safety copy is made first"
        menu_item 0 "Back" ""
        menu_read "Choose:" || return 0
        case "$REPLY_MENU" in 1) menu_sub --backup ;; 2) menu_sub --restore-backup ;; 0|"") return 0 ;; *) echo "  Choose a number from the list." ;; esac
    done
}
menu_settings() {
    while true; do
        echo; echo "  Settings"
        menu_item 1 "Change the Pi address" "for an installed KlipperScreen"
        menu_item 2 "Network and system" "host name, time zone, clock, addresses"
        menu_item 3 "Set up ZR Tools on the Pi" "checks the Pi (asks its password), installs the macros if missing"
        menu_item 4 "Fix the clock" "turns on automatic time sync (NTP) so downloads and apt work"
        menu_item 0 "Back" ""
        menu_read "Choose:" || return 0
        case "$REPLY_MENU" in
            1) menu_ask_pi || return 0; menu_sub --set-pi "$PI_HOST" ;;
            2) menu_system ;;
            3) menu_ask_pi || return 0; menu_sub --zr-pi --pi "$PI_HOST" ;;
            4) menu_sub --fix-clock ;;
            0|"") return 0 ;; *) echo "  Choose a number from the list." ;;
        esac
    done
}
menu_system() {
    while true; do
        echo; echo "  Network and system"
        menu_item 1 "Show" "host name, time zone, clock, addresses, Wi-Fi"
        menu_item 2 "Set the time zone" "for example America/Toronto"
        menu_item 3 "Change the host name" "asks first"
        menu_item 0 "Back" ""
        menu_read "Choose:" || return 0
        case "$REPLY_MENU" in
            1) menu_sub --system ;;
            2) local z; read -r -p "  Time zone (for example America/Toronto): " z || z=""; [ -n "$z" ] && menu_sub --system "tz:$z" ;;
            3) local n; read -r -p "  New host name: " n || n=""; [ -n "$n" ] && menu_sub --system "host:$n" ;;
            0|"") return 0 ;; *) echo "  Choose a number from the list." ;;
        esac
    done
}
menu_main() {
    [ -t 0 ] || [ "$TESTING" = 1 ] || die_with_fix "the menu needs a terminal." "run it in an ssh session, or use the options (--help)."
    while true; do
        echo; echo -e "${BLUE}KlipperScreen on the WonderMaker screen board${NC}   installer $(tr -d '[:space:]' < "$REPO_DIR/VERSION" 2>/dev/null || echo dev)"
        echo "  Mode: $([ -f "$BK/board_mode" ] && echo "KlipperScreen" || echo factory)"
        menu_item 1 "Install KlipperScreen + ZR Tools" "asks for the Pi address, shows the plan, then asks"
        menu_item 2 "Update" "see what is new, then update the ZR Tools screen files (backup first)"
        menu_item 3 "Check and fix" "doctor, status, logs, restart the screen, board report"
        menu_item 4 "Backup and restore" "screen settings"
        menu_item 5 "Settings" "Pi address, network and system, ZR Tools on the Pi, clock"
        menu_item 6 "Support bundle" "scrubbed .tgz of logs and config to share when asking for help"
        menu_item 7 "Dry run of the install" "shows what would happen, changes nothing"
        menu_item 8 "Back to factory mode" "removes KlipperScreen, factory services return, reboot"
        menu_item 9 "Uninstall installer files" "rescue tool, backups, saved restore data, the installer folder, free up disk space"
        menu_item 0 "Exit" ""
        menu_read "Choose:" || return 0
        case "$REPLY_MENU" in
            1) menu_ask_pi || return 0; menu_sub --pi "$PI_HOST" ;;
            2) menu_update ;;
            3) menu_fix ;;
            4) menu_backup ;;
            5) menu_settings ;;
            6) menu_sub --support-bundle ;;
            7) menu_ask_pi || return 0; menu_sub --pi "$PI_HOST" --dry-run ;;
            8) menu_sub --factory-restore ;;
            9) menu_uninstall ;;
            0|"") return 0 ;;
            *) echo "  Choose a number from the list." ;;
        esac
    done
}

case "$MODE" in
    menu) menu_main ;;
    freespace) do_free_space ;;
    fixclock) apt_fix; fix_clock ;;
    zrpi) do_zr_pi ;;
    setdriver) do_setdriver ;;
    update) do_update_board ;;
    whatsnew) do_whatsnew_board ;;
    removefiles) do_remove_files ;;
    doctor) do_doctor_board ;;
    backup) do_backup_board ;;
    restorebk) do_restore_board ;;
    bundle) do_bundle_board ;;
    log) do_log_board ;;
    restartks) do_restartks ;;
    system) do_system_board ;;
    install) do_install ;;
    status) do_status ;;
    setpi) do_setpi ;;
    uninstall) do_uninstall ;;
    restore) do_restore ;;
esac
