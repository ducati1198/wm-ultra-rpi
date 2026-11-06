#!/bin/bash

# =============================================================================
# WonderMaker ZR Ultra / Ultra-S  -  Raspberry Pi replacement installer
# =============================================================================
# Sets up a Raspberry Pi (64-bit Raspberry Pi OS Bookworm, user t13dp) to run WonderMaker's own
# Klipper / Moonraker / Fluidd in place of the failed screen/host board.
#
# ./installer.sh                       install (asks a few plain questions first)
# ./installer.sh --from-board IP       take the software from the old board over SSH
# ./installer.sh --from-github         take the factory files that are inside this repository (no printer needed)
# ./installer.sh --model ultra|ultra-s your printer (asked if not given; sets up printer.cfg for it)
# ./installer.sh --modules DIR         optional: your own copies of the 5 compiled modules (replace the bundled ones)
# ./installer.sh --check               report problems, change nothing
# ./installer.sh --first-start         checks with the main board connected; fixes canbus_uuid; then starts Klipper and the other services
# ./installer.sh --hw-test             read-only live test: USB bridge, can0, CAN devices, camera, services
# ./installer.sh --doctor              find problems, explain them, offer a fix for each (asks first)
# ./installer.sh --repair              put back services, nginx files, can0 rule and groups (data untouched)
# ./installer.sh --update              update after you pulled a new version of this repository (your printer_data is not touched)
# ./installer.sh --check-updates       read-only: list what is new on GitHub since your copy of this repository (then: git pull, ./installer.sh --update)
# ./installer.sh --undo [DIR]          put back the folders the installer moved aside (latest, or DIR)
# ./installer.sh --backup [DIR]        save your config, calibration and database to a .tgz (only when you run it)
# ./installer.sh --restore FILE        restore such a backup (a safety copy is made first)
# ./installer.sh --show-log            where the log of the last run is, and its last lines. Every run that changes something is logged to ~/wm-install-logs/ (passwords and tokens removed)
# ./installer.sh --support-bundle      make a scrubbed .tgz of logs and config to share when asking for help
# ./installer.sh --enable-klipper      same as --first-start
# ./installer.sh --start-klipper       undo --disable-klipper: start Klipper now and at every boot, without the hardware checks
# ./installer.sh --disable-klipper     stop Klipper and stop it from starting at boot
# ./installer.sh --uninstall           remove what the installer added to the system (your files in ~ stay)
# ./installer.sh --shell-command on|off   the Klipper "gcode shell command" extension (RUN_SHELL_COMMAND CMD=name runs a Linux command from G-code). Installed automatically; off skips it
# ./installer.sh --menu                numbered menu (install, update, add-ons, check and fix, backup, screen, advanced). Opens by itself when you run ./installer.sh with no options on a Pi that is already installed
# ./installer.sh --install             the normal install (skips the menu)
# ./installer.sh --remove NAME         remove something after asking: screen, network-manager, webcam, timelapse, shell-command, obico, octoapp, octoeverywhere, fluidd, moonraker, klipper, data, system, cleanup (installer files: old backups, support bundles, saved copies, the installer folder), or all (everything except your printer data, backups and installer files)
# ./installer.sh --webcam on|off       crowsnest webcam service;  --timelapse on|off   Moonraker timelapse (both used with --update)
# ./installer.sh --obico-server URL    which Obico to connect to: https://app.obico.io (Obico's website, the default) or your own self-hosted server. Asked when you choose Obico
# ./installer.sh --network-manager on|off   NetworkManager for KlipperScreen's Network panel (default off: it can drop the network connection until the Pi is restarted). Add it later with: ./installer.sh --update --network-manager on
# ./installer.sh --obico on|off        optional remote access: Obico for Klipper (moonraker-obico). Also --octoapp on|off and --octoeverywhere on|off. Each is asked (default no)
# ./installer.sh --screen on|off|macros   KlipperScreen on the Pi (on), nothing (off), or only the ZR Tools macros (macros: for the WonderMaker screen board). Asked if not given; default on
# ./installer.sh --screen-layout tabs|grid   touch layout: tabs = big buttons + bottom tabs (default), grid = card grid
# ./installer.sh --screen-backend x11|weston|cage   graphics stack for KlipperScreen (default x11)
# ./installer.sh --screen-remove       remove KlipperScreen from this Pi (Klipper, Moonraker and Fluidd stay)
# ./installer.sh --screen-test         read-only: show the screen and touch device found on this Pi
# ./installer.sh --no-start            at the end of an install do not enable or start Klipper
# ./installer.sh --force               continue even if a print is active (not recommended)
# ./installer.sh --dry-run             go through the questions, show what would change, change nothing
# ./installer.sh --help | --version
#
# What this installer never does:
#   - It never flashes any board (main board, toolheads, hub, screen). No firmware is touched.
#   - At the very end it enables and starts Klipper, Moonraker, nginx and crowsnest. With --no-start it starts nothing
#     (--first-start does it later, and then stops if a check fails).
#   - It never writes to the old board.
#
# Needs bash, sudo and internet access (apt, and the Python 3.9 download from astral.sh/GitHub).
# =============================================================================

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; DIM='\033[2m'; NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION" 2>/dev/null || true)"; VERSION="${VERSION:-dev}"

WM_USER="t13dp"
HOME_DIR="${WM_HOME:-$HOME}"
TESTING="${WM_INSTALLER_TEST:-0}"        # 1 = no sudo, no apt, no systemctl, no network, no Python download
MODE="install"
DRY=0
SRC_KIND=""; SRC_ARG=""; MODEL="ultra-s"; MODULES_DIR=""; FROM_FACTORY=0
WANT_PANEL=1; WANT_SCREEN=ask; WANT_TIMELAPSE=1; WANT_CROWSNEST=1; CLI_REMOTE=""; WANT_SHELLCMD=1; OBICO_SERVER=""; CLI_OBICO_SERVER=""; WANT_OBICO=ask; WANT_OCTOAPP=ask; WANT_OCTOEVERYWHERE=ask; WANT_NETMGR=ask
SCREEN_LAYOUT=""; SCREEN_BACKEND="x11"; REPO_DIR="$SCRIPT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="$HOME_DIR/wm-rpi-backup"
STATE="$BACKUP_ROOT/installed.manifest"
CONF="$BACKUP_ROOT/install.conf"
PANEL_REPO="ducati1198/wm-ultra-fluidd-acepro-panel"; PANEL_ZIP=""; PANEL_FROM=""
FORCE=0; AUTOSTART=1; ARG1=""; OLD_VERSION=""
STAGE=""
declare -a WARNINGS=()

APT_PACKAGES=(nginx can-utils build-essential libffi-dev libssl-dev libjpeg-dev zlib1g-dev libsodium23 liblmdb0 curl git python3-venv python3-pip iproute2 dbus usbutils)
COMPILED_MODULES=(cs1237 hx711 heater_air_core heater_feng xy_offset_calibrator_core heater_air xy_offset_calibrator tools_calibrate echelon_stepper custom_hall)

print_header()  { echo -e "\n${BLUE}── $1 ──────────────────────────────────────────${NC}"; }
print_info()    { echo -e "${BLUE}ℹ ${1}${NC}"; }
print_success() { echo -e "${GREEN}✓ ${1}${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ ${1}${NC}"; }
print_error()   { echo -e "${RED}✗ ${1}${NC}"; }
why()           { echo -e "  ${DIM}Why: $1${NC}"; }
warn_later()    { WARNINGS+=("$1"); }
die_with_fix()  { print_error "Can't continue: $1"; echo -e "  Fix: $2"; exit 1; }

ask_yn() {  # prompt default(y/n)
    local p="$1" d="${2:-y}" a
    if [ "${REMOVE_CONFIRMED:-0}" = 1 ]; then return 0; fi   # only set by "--remove all", after the typed confirmation
    if [ "${WM_ASSUME_YES:-0}" = 1 ]; then [ "$d" = y ]; return; fi
    read -r -p "$(echo -e "${YELLOW}?${NC} $p [${d}] ")" a || a=""
    a="${a:-$d}"; [[ "$a" =~ ^[Yy] ]]
}
run() {  # run a change; in --dry-run only show it
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: $*${NC}"; return 0; fi
    "$@"
}
SUDO() {
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: sudo $*${NC}"; return 0; fi
    if [ "$TESTING" = 1 ]; then echo "[test] sudo $*" >> "$HOME_DIR/.sudo.log"; test_systemctl "$@"; return 0; fi
    sudo "$@"
}
record() { [ "$DRY" = 1 ] && return 0; mkdir -p "$BACKUP_ROOT"; echo "$1" >> "$STATE"; }

usage() { sed -n '4,/^# What this/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# ============================================================================
# Arguments
# ============================================================================
ORIG_ARGC=$#; ORIG_ARGS=("$@"); EXPLICIT_INSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --from-board)   SRC_KIND=board; SRC_ARG="${2:-}"; shift ;;
        --from-stage)   SRC_KIND=stage; SRC_ARG="${2:-}"; shift ;;
        --from-github|--from-repo) SRC_KIND=repo; SRC_ARG="repo" ;;
        --model)        MODEL="${2:-}"; MODEL_SET=1; shift ;;
        --modules)      MODULES_DIR="${2:-}"; shift ;;
        --check)        MODE=check ;;
        --menu)         MODE=menu ;;
        --install)      MODE=install; EXPLICIT_INSTALL=1 ;;
        --remove)       MODE=remove; ARG1="${2:-}"; shift ;;
        --webcam)       case "${2:-}" in on|yes|1) WANT_CROWSNEST=1 ;; off|no|0) WANT_CROWSNEST=0 ;; *) print_error "--webcam needs on or off"; exit 1 ;; esac; CLI_REMOTE="$CLI_REMOTE webcam"; CLI_WEBCAM="$WANT_CROWSNEST"; shift ;;
        --timelapse)    case "${2:-}" in on|yes|1) WANT_TIMELAPSE=1 ;; off|no|0) WANT_TIMELAPSE=0 ;; *) print_error "--timelapse needs on or off"; exit 1 ;; esac; CLI_REMOTE="$CLI_REMOTE timelapse"; CLI_TIMELAPSE="$WANT_TIMELAPSE"; shift ;;
        --first-start|--enable-klipper) MODE=firststart ;;
        --hw-test)      MODE=hwtest ;;
        --doctor)       MODE=doctor ;;
        --repair)       MODE=repair ;;
        --update)       MODE=update ;;
        --check-updates) MODE=checkupdates ;;
        --undo)         MODE=undo; case "${2:-}" in ""|--*) ;; *) ARG1="$2"; shift ;; esac ;;
        --backup)       MODE=backup; case "${2:-}" in ""|--*) ;; *) ARG1="$2"; shift ;; esac ;;
        --restore)      MODE=restore; ARG1="${2:-}"; shift ;;
        --support-bundle) MODE=bundle ;;
        --show-log)     MODE=showlog ;;
        --obico-server) case "${2:-}" in http://*|https://*) OBICO_SERVER="${2%/}"; CLI_OBICO_SERVER="$OBICO_SERVER" ;; *) print_error "--obico-server needs a web address such as https://app.obico.io or http://obico.local:3334"; exit 1 ;; esac; shift ;;
        --shell-command) case "${2:-}" in on|yes|1) WANT_SHELLCMD=1 ;; off|no|0) WANT_SHELLCMD=0 ;; *) print_error "--shell-command needs on or off"; exit 1 ;; esac; CLI_SHELLCMD="$WANT_SHELLCMD"; shift ;;
        --obico)        case "${2:-}" in on|yes|1) WANT_OBICO=1 ;; off|no|0) WANT_OBICO=0 ;; *) print_error "--obico needs on or off"; exit 1 ;; esac; CLI_REMOTE="$CLI_REMOTE obico"; CLI_OBICO="$WANT_OBICO"; shift ;;
        --octoapp)      case "${2:-}" in on|yes|1) WANT_OCTOAPP=1 ;; off|no|0) WANT_OCTOAPP=0 ;; *) print_error "--octoapp needs on or off"; exit 1 ;; esac; CLI_REMOTE="$CLI_REMOTE octoapp"; CLI_OCTOAPP="$WANT_OCTOAPP"; shift ;;
        --network-manager) case "${2:-}" in on|yes|1) WANT_NETMGR=1 ;; off|no|0) WANT_NETMGR=0 ;; *) print_error "--network-manager needs on or off"; exit 1 ;; esac; CLI_REMOTE="$CLI_REMOTE netmgr"; CLI_NETMGR="$WANT_NETMGR"; shift ;;
        --octoeverywhere) case "${2:-}" in on|yes|1) WANT_OCTOEVERYWHERE=1 ;; off|no|0) WANT_OCTOEVERYWHERE=0 ;; *) print_error "--octoeverywhere needs on or off"; exit 1 ;; esac; CLI_REMOTE="$CLI_REMOTE octoeverywhere"; CLI_OCTOEVERYWHERE="$WANT_OCTOEVERYWHERE"; shift ;;
        --screen)       case "${2:-}" in on|yes|1) WANT_SCREEN=1 ;; off|no|0) WANT_SCREEN=0 ;; macros) WANT_SCREEN=macros ;; *) print_error "--screen needs on, off or macros"; exit 1 ;; esac; shift ;;
        --screen-layout) case "${2:-}" in tabs|grid) SCREEN_LAYOUT="$2" ;; *) print_error "--screen-layout needs tabs or grid"; exit 1 ;; esac; shift ;;
        --screen-backend) case "${2:-}" in x11|weston|cage) SCREEN_BACKEND="$2" ;; *) print_error "--screen-backend needs x11, weston or cage"; exit 1 ;; esac; shift ;;
        --screen-test)  MODE=screentest ;;
        --screen-remove) MODE=screenremove ;;
        --no-start)     AUTOSTART=0 ;;
        --force)        FORCE=1 ;;
        --disable-klipper) MODE=disable ;;
        --start-klipper) MODE=startklipper ;;
        --uninstall)    MODE=uninstall ;;
        --dry-run)      DRY=1 ;;
        --yes)          WM_ASSUME_YES=1 ;;
        --version)      echo "wm-ultra-rpi installer $VERSION"; exit 0 ;;
        -h|--help)      usage; exit 0 ;;
        *) print_error "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

# ============================================================================
# Checks
# ============================================================================
check_system() {
    print_header "Checking this computer"
    [ "$(id -un)" = "$WM_USER" ] || [ "$TESTING" = 1 ] || die_with_fix "you are user '$(id -un)', WonderMaker's software only works for user '$WM_USER' (its paths are fixed to /home/$WM_USER)." \
        "create the user when you write the SD card with Raspberry Pi Imager (set username to $WM_USER), or: sudo adduser $WM_USER && sudo usermod -aG sudo $WM_USER, then log in as $WM_USER."
    print_success "User is $WM_USER"
    [ "$HOME_DIR" = "/home/$WM_USER" ] || [ "$TESTING" = 1 ] || die_with_fix "home is $HOME_DIR, expected /home/$WM_USER" "log in as $WM_USER."
    if [ "$TESTING" != 1 ]; then
        [ "$(uname -m)" = "aarch64" ] || die_with_fix "this is $(uname -m), not 64-bit ARM." "use the 64-bit image of Raspberry Pi OS (Bookworm)."
        print_success "64-bit ARM"
        if [ -r /etc/os-release ] && ! grep -q 'VERSION_CODENAME=bookworm' /etc/os-release; then
            warn_later "This is not Raspberry Pi OS Bookworm. It is tested only on Bookworm."
        fi
        sudo -n true 2>/dev/null || print_info "sudo will ask for your password."
        local free; free=$(df -Pm "$HOME_DIR" | awk 'NR==2{print $4}')
        [ "${free:-0}" -gt 2500 ] || die_with_fix "only ${free} MB free." "use a bigger SD card (16 GB or more)."
        print_success "Disk space ok (${free} MB free)"
    fi
}


# ============================================================================
# Source of the WonderMaker software
# ============================================================================
ask_model() {
    case "$MODEL" in ultra|ultra-s) ;; *) die_with_fix "unknown model '$MODEL'." "use --model ultra or --model ultra-s." ;; esac
    [ -n "${MODEL_SET:-}" ] || [ "${WM_ASSUME_YES:-0}" = 1 ] && { print_info "Printer model: $MODEL"; return; }
    print_header "Which printer do you have?"
    echo "  1) WonderMaker ZR Ultra"
    echo "  2) WonderMaker ZR Ultra-S (chamber heater, air filter, door sensors)"
    local m; read -r -p "$(echo -e "${YELLOW}?${NC} Choose 1 or 2 [2]: ")" m || m=""
    [ "$m" = 1 ] && MODEL=ultra || MODEL=ultra-s
    print_success "Model: $MODEL"
}

choose_source() {
    print_header "Where is the WonderMaker software?"
    echo "The Pi runs WonderMaker's own Klipper, Moonraker and your settings."
    echo -e "${GREEN}Recommended: option 1.${NC} If the old WonderMaker screen board still starts and is on your network, copy everything from it over SSH:"
    echo "  your printer_data (config, calibration, saved variables), klipper, moonraker, fluidd and the factory settings."
    echo "  That is exactly what your printer ran, with your own settings. The old board is only read, nothing is written to it."
    echo "  Use the other options only if the old board will not start."
    if [ -z "$SRC_KIND" ]; then
        echo -e "  1) The old board is still reachable on the network (SSH)  ${GREEN}<- recommended${NC}"
        echo "  2) I have nothing: use the factory files inside this repository (factory defaults, not your own settings)"
        local c; read -r -p "$(echo -e "${YELLOW}?${NC} Choose 1 or 2: ")" c || c=""
        case "$c" in
            1) SRC_KIND=board; read -r -p "  Old board IP address: " SRC_ARG ;;
            2) SRC_KIND=repo; SRC_ARG=repo ;;
            *) die_with_fix "no source chosen." "run again and pick 1 or 2 (or use --from-board / --from-github)." ;;
        esac
    fi
    [ -n "$SRC_ARG" ] || die_with_fix "no value given for the source." "see ./installer.sh --help"
    STAGE="$HOME_DIR/wm-stage"
    case "$SRC_KIND" in
        board)
            print_info "Reading from $SRC_ARG over SSH (read-only). The default WonderMaker login is user t13dp, password TM88888."
            why "the board's Klipper, Moonraker, config and calibration are copied once, then the Pi is on its own."
            run bash "$SCRIPT_DIR/scripts/pull_from_board.sh" "$SRC_ARG" "$STAGE" || die_with_fix "could not read the old board." "check the IP, that it is on, and the password. Or use --from-github." ;;
        repo)
            FROM_FACTORY=1
            case "$MODEL" in ultra|ultra-s) ;; *) die_with_fix "unknown model '$MODEL'." "use --model ultra or --model ultra-s." ;; esac
            print_info "Using the factory files of the $MODEL in this repository (Klipper and Moonraker are GPL; see factory/README.md)."
            echo "  The repository includes WonderMaker's 5 compiled modules (heaters, load cells, calibration), checked against factory checksums."
            run bash "$SCRIPT_DIR/scripts/stage_from_repo.sh" "$MODEL" "$STAGE" $MODULES_DIR || die_with_fix "could not build the factory stage." "see the message above. A modules folder must hold the unmodified factory *.so files." ;;
        stage)   # not documented: used by the tests
            [ -d "$SRC_ARG" ] || die_with_fix "stage folder not found: $SRC_ARG" "give the full path."
            STAGE="$SRC_ARG" ;;
    esac
    if [ "$FROM_FACTORY" = 1 ] && [ "$DRY" != 1 ] && [ "$(cat "$STAGE/modules_ok" 2>/dev/null)" != 1 ]; then
        warn_later "WonderMaker's 5 compiled modules were NOT installed. Without them Klipper cannot start the heaters, load cells or calibration. Copy them (from your printer) into ~/klipper/klippy/extras/ before ./installer.sh --enable-klipper."
    fi
    if [ "$DRY" != 1 ]; then
        for f in klipper moonraker data; do
            [ -s "$STAGE/$f.tgz" ] || die_with_fix "$STAGE/$f.tgz is missing or empty." "pull again."
        done
        print_success "Software found in $STAGE"
    fi
}

# ============================================================================
# Steps
# ============================================================================
step_packages() {
    print_header "Step 1: system packages"
    why "nginx serves Fluidd; can-utils and iproute2 talk to the CAN bus; the rest builds the Python environments."
    [ "$TESTING" = 1 ] && { SUDO apt-get install -y "${APT_PACKAGES[@]}"; return; }
    SUDO apt-get update -qq
    SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}" || die_with_fix "apt could not install the packages." "check the internet connection, then run the installer again."
    print_success "Packages installed"
}

step_groups() {
    print_header "Step 2: groups"
    why "Moonraker needs its own admin group; dialout/plugdev let Klipper open USB and serial devices."
    getent group moonraker-admin >/dev/null 2>&1 || { SUDO groupadd moonraker-admin; record "GROUP moonraker-admin"; }
    SUDO usermod -aG dialout,plugdev,moonraker-admin "$WM_USER"
    print_success "Groups ready"
}

step_python() {
    print_header "Step 3: Python 3.9"
    why "WonderMaker's compiled modules (cs1237, hx711, heater_air_core, ...) only load in Python 3.9. Bookworm has 3.11, so 3.9 is installed next to it."
    PY39="$(ls "$HOME_DIR"/.pythons/cpython-3.9*/bin/python3.9 2>/dev/null | head -1)"
    if [ -n "$PY39" ]; then print_success "Python 3.9 already there: $PY39"; return; fi
    if [ "$TESTING" = 1 ]; then PY39="$(command -v python3)"; return; fi
    [ "$DRY" = 1 ] && { echo -e "  ${DIM}would install uv and Python 3.9 into ~/.pythons${NC}"; PY39="~/.pythons/.../python3.9"; return; }
    python3 -m venv "$HOME_DIR/uvtool" && "$HOME_DIR/uvtool/bin/pip" install -q uv || die_with_fix "could not install uv." "check the internet connection."
    UV_PYTHON_INSTALL_DIR="$HOME_DIR/.pythons" "$HOME_DIR/uvtool/bin/uv" python install 3.9 || die_with_fix "could not download Python 3.9." "check the internet connection (github.com must be reachable)."
    PY39="$(ls "$HOME_DIR"/.pythons/cpython-3.9*/bin/python3.9 | head -1)"
    record "DIR $HOME_DIR/uvtool"; record "DIR $HOME_DIR/.pythons"
    print_success "Python 3.9 installed"
}

step_unpack() {
    print_header "Step 4: unpack the WonderMaker software"
    why "klipper, moonraker, your printer_data (config, calibration), the Fluidd build and the factory settings go to the same places as on the old board."
    local d keep="$BACKUP_ROOT/old-$STAMP"
    for d in klipper moonraker printer_data fluidd TM_T1; do
        if [ -e "$HOME_DIR/$d" ]; then
            run mkdir -p "$keep"; run mv "$HOME_DIR/$d" "$keep/$d"; print_info "Existing ~/$d moved to $keep/"
        fi
    done
    for f in klipper moonraker data; do run tar xzf "$STAGE/$f.tgz" -C "$HOME_DIR"; done
    run mkdir -p "$HOME_DIR/printer_data/gcodes" "$HOME_DIR/printer_data/logs" "$HOME_DIR/printer_data/comms" "$HOME_DIR/printer_data/systemd"
    for d in klipper moonraker printer_data fluidd; do record "HOMEDIR $d"; done
    [ -d "$HOME_DIR/klipper/klippy" ] || [ "$DRY" = 1 ] || die_with_fix "~/klipper/klippy is missing after unpacking." "the stage folder is incomplete: pull again."
    print_success "Unpacked"
}

step_model() {
    print_header "Step 4b: set up for the $MODEL"
    why "The Ultra-S has a chamber heater, air filter fan and door sensors (zru-s.cfg). The Ultra does not. printer.cfg must include it only on the Ultra-S."
    local cfg="$HOME_DIR/printer_data/config/printer.cfg"
    if [ "$DRY" = 1 ] || [ ! -f "$cfg" ]; then echo -e "  ${DIM}would set the zru-s.cfg include for the $MODEL${NC}"; return 0; fi
    local want; [ "$MODEL" = ultra-s ] && want='[include zru-s.cfg]' || want='# [include zru-s.cfg]'
    if grep -qxF "$want" "$cfg"; then print_success "printer.cfg already matches the $MODEL"; else
        cp "$cfg" "$cfg.wm-model-bak"
        if grep -qE '^[#[:space:]]*\[include zru-s.cfg\]' "$cfg"; then sed -i "s/^[#[:space:]]*\[include zru-s.cfg\]/$want/" "$cfg"
        elif [ "$MODEL" = ultra-s ]; then printf '\n[include zru-s.cfg]\n' >> "$cfg"; fi
        print_success "printer.cfg set for the $MODEL (copy of the old one: printer.cfg.wm-model-bak)"
    fi
    echo "$MODEL" > "$HOME_DIR/printer_data/wm-model"
}

step_venvs() {
    print_header "Step 5: Python environments"
    why "Klipper and Moonraker each get their own environment with the exact package versions of WonderMaker's image (config/*-requirements.txt)."
    [ "$TESTING" = 1 ] && { echo "[test] venvs skipped"; return; }
    [ "$DRY" = 1 ] && { echo -e "  ${DIM}would create ~/klippy-env and ~/moonraker-env with Python 3.9${NC}"; return; }
    "$PY39" -m venv "$HOME_DIR/klippy-env" || die_with_fix "could not create klippy-env." "run again."
    "$HOME_DIR/klippy-env/bin/pip" install -q -U pip wheel "setuptools<66" || die_with_fix "pip failed." "check the internet connection."
    "$HOME_DIR/klippy-env/bin/pip" install -q -r "$SCRIPT_DIR/config/klippy-requirements.txt" || die_with_fix "Klipper's packages did not install." "see the message above."
    "$PY39" -m venv "$HOME_DIR/moonraker-env"
    "$HOME_DIR/moonraker-env/bin/pip" install -q -U pip wheel "setuptools<66"
    "$HOME_DIR/moonraker-env/bin/pip" install -q -r "$SCRIPT_DIR/config/moonraker-requirements.txt" || die_with_fix "Moonraker's packages did not install." "see the message above."
    record "HOMEDIR klippy-env"; record "HOMEDIR moonraker-env"
    print_success "Environments ready"
}

# Klipper loads these as "extras.<name>" with the klippy folder on the path (they use "from . import ..." and "import pins").
# Importing them from inside the extras folder fails for a good module too, so test them the way Klipper does.
module_imports() { (cd "$HOME_DIR/klipper/klippy" && "$HOME_DIR/klippy-env/bin/python" -c "import sys; sys.path.insert(0, '.'); import extras.$1" 2>/dev/null); }

step_modules() {
    print_header "Step 6: WonderMaker's compiled modules"
    why "These binary modules decide whether the heaters, load cells and tool calibration work. They must import on this Pi."
    [ "$TESTING" = 1 ] || [ "$DRY" = 1 ] && { echo "[skipped in test/dry-run]"; return; }
    local m bad=0
    for m in "${COMPILED_MODULES[@]}"; do
        if module_imports "$m"; then print_success "$m"; else print_warning "$m does not import"; bad=1; fi
    done
    [ "$bad" = 0 ] || warn_later "Some WonderMaker modules did not import. Klipper may stop with an error about them. Check: cd ~/klipper/klippy && ~/klippy-env/bin/python -c 'import sys; sys.path.insert(0, \".\"); import extras.<module>'"
}

step_services_files() {
    SUDO install -m 644 "$SCRIPT_DIR/config/moonraker.service" /etc/systemd/system/moonraker.service
    SUDO install -m 644 "$SCRIPT_DIR/config/klipper.service"   /etc/systemd/system/klipper.service
    record "FILE /etc/systemd/system/moonraker.service"; record "FILE /etc/systemd/system/klipper.service"
    SUDO systemctl daemon-reload
    SUDO systemctl enable moonraker
}
polkit_rule_present() {   # rules.d is root/polkitd-only (mode 700), so a plain test as the user cannot see the file
    SUDO test -f /etc/polkit-1/rules.d/moonraker.rules || SUDO test -f /usr/share/polkit-1/rules.d/moonraker.rules || SUDO test -f /etc/polkit-1/localauthority/50-local.d/10-moonraker.pkla
}
packagekit_present() {   # Moonraker's update manager asks PolicyKit about org.freedesktop.packagekit.*; those actions only exist when PackageKit is installed
    if [ "$TESTING" = 1 ]; then [ -f "$HOME_DIR/.polkit_fixed" ] || { [ "${WM_TEST_PACKAGEKIT:-1}" = 1 ] && [ "${WM_TEST_POLKIT_WARN:-0}" != 1 ]; }; return; fi
    [ -f /usr/share/polkit-1/actions/org.freedesktop.packagekit.policy ]
}
polkit_warnings() {   # what Moonraker itself reports about PolicyKit (one line each); empty when it reports nothing or does not answer
    if [ "$TESTING" = 1 ]; then [ "${WM_TEST_POLKIT_WARN:-0}" = 1 ] && [ ! -f "$HOME_DIR/.polkit_fixed" ] && echo "Action org.freedesktop.packagekit.system-update is not registered"; return 0; fi
    api_get /server/info | python3 -c 'import sys,json
try:
    for w in json.load(sys.stdin)["result"].get("warnings", []):
        if "olkit" in w.lower() or "polkit" in w.lower() or "is not registered" in w: print(w.strip().splitlines()[0][:160])
except Exception: pass' 2>/dev/null
}
moonraker_no_system_updates() {   # last resort when PackageKit cannot be installed: tell Moonraker not to manage Debian packages
    local d f; d="$(cfg_dir)"; f="$(grep -l '^\[update_manager\]' "$d"/*.conf 2>/dev/null | head -n1)"
    if [ -z "$f" ]; then f="$d/moonraker.conf"; [ -f "$f" ] || return 1; cp "$f" "$f.wm-before-polkit-fix-$STAMP"; printf '\n[update_manager]\nenable_system_updates: False\n' >> "$f"
    elif grep -q '^enable_system_updates' "$f"; then return 0
    else cp "$f" "$f.wm-before-polkit-fix-$STAMP"; sed -i '0,/^\[update_manager\]/s//[update_manager]\nenable_system_updates: False/' "$f"; fi
    print_info "Set enable_system_updates: False in $(basename "$f") (copy: $(basename "$f").wm-before-polkit-fix-$STAMP): Moonraker no longer manages Debian packages."
}
step_packagekit() {
    packagekit_present && return 0
    why "Fluidd's update manager checks PackageKit's PolicyKit actions. Without the packagekit package Moonraker says 'PolKit warnings detected'."
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: sudo apt-get install -y packagekit${NC}"; return 0; fi
    if [ "$TESTING" = 1 ]; then SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y packagekit; touch "$HOME_DIR/.polkit_fixed"; return 0; fi
    SUDO apt-get update -qq >/dev/null 2>&1
    if SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y packagekit >/dev/null 2>&1 && packagekit_present; then print_success "PackageKit installed (the PolKit warning source)"; return 0; fi
    print_warning "PackageKit could not be installed (no internet, or this Debian's package list is old)."
    moonraker_no_system_updates || warn_later "Could not stop Moonraker's PolKit warning. Run: sudo apt install packagekit, then restart Moonraker."
}
polkit_fix() {   # PackageKit + Moonraker's rule, restart Moonraker, look again. Returns 0 when Moonraker no longer complains.
    step_polkit
    [ "$DRY" = 1 ] && return 0
    SUDO systemctl restart moonraker
    [ "$TESTING" = 1 ] || sleep 6
    [ -z "$(polkit_warnings)" ]
}
polkit_check_and_fix() {   # looked at after every install, update, repair and when the menu opens; changes nothing while a print is active
    local w; w="$(polkit_warnings)"
    if [ -z "$w" ] && packagekit_present; then return 0; fi
    case "$(print_state)" in printing|paused) print_warning "Moonraker reports a PolicyKit problem (Fluidd: 'PolKit warnings detected'). It will be fixed the next time you open the menu or run --repair when no print is active."; return 0 ;; esac
    print_warning "${w:-PackageKit is missing, so Fluidd would show 'PolKit warnings detected'.}"
    if polkit_fix; then print_success "PolKit warning fixed. Reload the Fluidd page."; else warn_later "Moonraker still reports a PolicyKit problem. Run ./installer.sh --doctor, or: sudo apt install packagekit && sudo systemctl restart moonraker"; fi
}
step_polkit() {   # without this rule Moonraker may not restart services (Fluidd shows "PolKit warnings detected")
    why "Moonraker needs a PolicyKit rule to start, stop and restart services (Klipper, crowsnest, KlipperScreen) from Fluidd. WonderMaker's own image has it; a fresh Pi does not."
    step_packagekit
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: moonraker/scripts/set-policykit-rules.sh${NC}"; return 0; fi
    if [ "$TESTING" = 1 ]; then echo "[test] polkit rules" >> "$HOME_DIR/.sudo.log"; return 0; fi
    if [ -f "$HOME_DIR/moonraker/scripts/set-policykit-rules.sh" ]; then
        if polkit_rule_present; then return 0; fi
        bash "$HOME_DIR/moonraker/scripts/set-policykit-rules.sh" >/dev/null 2>&1 && polkit_rule_present && { record "FILE /etc/polkit-1/rules.d/moonraker.rules"; print_success "PolicyKit rule for Moonraker installed"; return 0; }
    fi
    warn_later "Could not install Moonraker's PolicyKit rule: Fluidd will show a PolKit warning and cannot restart services. Run: ./installer.sh --repair"
}

step_services() {
    print_header "Step 7: Klipper and Moonraker services"
    why "Moonraker (the web API) starts at boot. Klipper is installed but NOT enabled and NOT started until the final checks pass: the main board may not be connected yet."
    step_services_files
    step_polkit
    SUDO systemctl disable klipper
    SUDO systemctl stop klipper
    print_success "Services installed (Klipper stays off for now)"
}

step_nginx() {
    print_header "Step 8: web server (Fluidd)"
    why "Fluidd opens at http://<this Pi>/ and talks to Moonraker through nginx, as on the old board."
    SUDO install -m 644 "$SCRIPT_DIR/config/nginx_common_vars.conf" /etc/nginx/conf.d/common_vars.conf
    SUDO install -m 644 "$SCRIPT_DIR/config/nginx_upstreams.conf"   /etc/nginx/conf.d/upstreams.conf
    SUDO install -m 644 "$SCRIPT_DIR/config/nginx_fluidd.conf"      /etc/nginx/sites-available/fluidd
    SUDO ln -sf /etc/nginx/sites-available/fluidd /etc/nginx/sites-enabled/fluidd
    SUDO rm -f /etc/nginx/sites-enabled/default
    # Debian 12 makes the home folder private (700), so nginx (www-data) cannot reach ~/fluidd and answers "403 Forbidden".
    # o+x lets other users pass through the folder to a path they already know; it does not let them list or read your files.
    SUDO chmod o+x "$HOME_DIR"
    for f in /etc/nginx/conf.d/common_vars.conf /etc/nginx/conf.d/upstreams.conf /etc/nginx/sites-available/fluidd; do record "FILE $f"; done
    record "LINK /etc/nginx/sites-enabled/fluidd"
    SUDO nginx -t && SUDO systemctl enable nginx && SUDO systemctl restart nginx
    print_success "nginx ready"
}

step_can() {
    print_header "Step 9: CAN bus"
    why "The main board shows up as can0 (1 Mbit). This rule brings it up when the board is plugged in."
    SUDO install -m 644 "$SCRIPT_DIR/config/99-wm-can0.rules" /etc/udev/rules.d/99-wm-can0.rules
    record "FILE /etc/udev/rules.d/99-wm-can0.rules"
    SUDO udevadm control --reload-rules
    print_success "can0 rule installed"
}

panel_get() {  # sets PANEL_ZIP and PANEL_FROM: the newest panel from the panel repository, else the copy in this repository
    [ -n "$PANEL_ZIP" ] && return 0
    local tmp="$BACKUP_ROOT/.panel-dl"; local name="" api raw
    if [ "$TESTING" = 1 ]; then
        if [ -n "${WM_TEST_PANEL_DIR:-}" ]; then name="$(ls "$WM_TEST_PANEL_DIR"/*.zip 2>/dev/null | head -1)"; [ -n "$name" ] && PANEL_ZIP="$name" && PANEL_FROM="the panel repository (test)" && return 0; fi
    elif [ "$DRY" != 1 ]; then
        mkdir -p "$tmp"; rm -f "$tmp"/*
        api="https://api.github.com/repos/$PANEL_REPO/contents/fluidd?ref=main"
        raw="https://raw.githubusercontent.com/$PANEL_REPO/main/fluidd"
        name="$(curl -fsS -m 15 "$api" 2>/dev/null | python3 -c 'import sys,json
try: print(next(f["name"] for f in json.load(sys.stdin) if f["name"].endswith(".zip")))
except Exception: pass' 2>/dev/null)"
        if [ -n "$name" ] && curl -fsSL -m 120 -o "$tmp/$name" "$raw/$name" && curl -fsSL -m 20 -o "$tmp/$name.sha256" "$raw/$name.sha256" \
           && ( cd "$tmp" && sha256sum -c "$name.sha256" >/dev/null 2>&1 ) \
           && python3 -c 'import sys,zipfile;z=zipfile.ZipFile(sys.argv[1]);assert "index.html" in z.namelist()' "$tmp/$name" 2>/dev/null; then
            PANEL_ZIP="$tmp/$name"; PANEL_FROM="github.com/$PANEL_REPO ($name)"
            print_success "Latest Fluidd panel downloaded from $PANEL_REPO (checksum ok)"; return 0
        fi
        print_warning "Could not get a verified panel from $PANEL_REPO."
    fi
    print_error "The Fluidd panel could not be downloaded from $PANEL_REPO."
    echo "  Without internet the web page cannot be installed. Connect the Pi to the network, then run: ./installer.sh --update"
    return 1
}

step_panel() {
    [ -f "$HOME_DIR/fluidd/index.html" ] || [ "$DRY" = 1 ] || WANT_PANEL=1   # factory files carry no web interface: the panel build is the web interface
    [ "$WANT_PANEL" = 1 ] || return 0
    print_header "Step 10: Fluidd with the WonderMaker Toolheads panel"
    why "The Fluidd that came with the printer has no toolhead panel for the Ultra-S. This build adds it (toolheads, chamber, air filter, colours, filament mapping)."
    panel_get || { warn_later "The Fluidd web page was NOT installed (panel download failed). Connect to the internet, then run ./installer.sh --update."; return; }
    local zip="$PANEL_ZIP"
    if [ "$DRY" != 1 ]; then
        python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1])" "$zip" 2>/dev/null || { print_warning "Zip unreadable: panel skipped."; return; }
        local keep="$BACKUP_ROOT/fluidd-$STAMP"; mkdir -p "$keep"
        [ -d "$HOME_DIR/fluidd" ] && cp -a "$HOME_DIR/fluidd/." "$keep/"
        local cfg="$HOME_DIR/fluidd/config.json"; [ -f "$cfg" ] && cp "$cfg" "$keep/config.json.keep"
        rm -rf "$HOME_DIR/fluidd"; mkdir -p "$HOME_DIR/fluidd"
        python3 - "$zip" "$HOME_DIR/fluidd" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
        [ -f "$keep/config.json.keep" ] && cp "$keep/config.json.keep" "$HOME_DIR/fluidd/config.json"
    else echo -e "  ${DIM}would replace ~/fluidd with the panel build (old one saved)${NC}"; fi
    print_success "Fluidd panel installed (from $PANEL_FROM). Hard-refresh the browser (Ctrl/Cmd+Shift+R)."
}

# ---------------------------------------------------------------------------
# NetworkManager for KlipperScreen's Network panel. KlipperScreen's own script reboots the Pi when it installs this, so it is done here
# instead: install, enable, switch dhcpcd off, and leave the actual switch to the next reboot.
# ---------------------------------------------------------------------------
NETMGR_STATE="$BACKUP_ROOT/netmgr.state"
nm_active() { [ "$(service_state NetworkManager)" = active ] || { [ "$TESTING" = 1 ] && [ "${WM_TEST_NM:-0}" = 1 ]; }; }
step_netmgr() {
    [ "$WANT_NETMGR" = 1 ] || return 0
    print_header "NetworkManager (for KlipperScreen's Network panel)"
    why "KlipperScreen's Network panel talks to NetworkManager. Without it the panel does not appear."
    if nm_active; then print_success "NetworkManager is already running: nothing to change."; return 0; fi
    print_warning "The network may drop when the Pi restarts with NetworkManager. After the reboot, if it does not come back: connect a cable, or use the screen's Network panel, or run: sudo nmtui"
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: apt-get install network-manager; disable dhcpcd; enable NetworkManager (no restart)${NC}"; return 0; fi
    if [ "$(service_enabled dhcpcd)" = enabled ]; then mkdir -p "$BACKUP_ROOT"; echo "dhcpcd-was-enabled" > "$NETMGR_STATE"; fi
    SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y network-manager || { warn_later "NetworkManager could not be installed (network?). Run ./installer.sh --update --network-manager on to retry."; return 0; }
    SUDO mkdir -p /etc/NetworkManager/conf.d
    SUDO systemctl disable dhcpcd 2>/dev/null
    SUDO systemctl enable NetworkManager
    warn_later "NetworkManager is installed and starts at the next reboot (sudo reboot). Until then nothing changed. If the network does not come back: cable, or sudo nmtui, or ./installer.sh --remove network-manager from the screen's keyboard."
    print_success "NetworkManager installed and enabled. It takes over at the next reboot."
}

# ---------------------------------------------------------------------------
# Touchscreen (KlipperScreen + ZR Tools). NOT YET TESTED ON HARDWARE.
# ---------------------------------------------------------------------------
KS_DIR="$HOME_DIR/KlipperScreen"
ZR_CONF="$HOME_DIR/printer_data/config/zr_screen.conf"

detect_screen() {  # prints "WIDTHxHEIGHT touch|notouch" (size empty when no screen is found)
    local res="" touch=notouch f m
    if [ -n "${WM_TEST_SCREEN+x}" ]; then res="$WM_TEST_SCREEN"; [ "${WM_TEST_TOUCH:-0}" = 1 ] && touch=touch
    else
        for f in /sys/class/drm/card*-*/status; do
            [ -r "$f" ] && [ "$(cat "$f" 2>/dev/null)" = connected ] || continue
            m="$(head -n1 "$(dirname "$f")/modes" 2>/dev/null)"; [ -n "$m" ] && { res="$m"; break; }
        done
        local e; for e in /sys/class/input/event*; do
            [ -e "$e" ] && udevadm info -q property -p "$e" 2>/dev/null | grep -q '^ID_INPUT_TOUCHSCREEN=1' && { touch=touch; break; }
        done
    fi
    echo "${res:-} $touch"
}

screen_density_hint() {  # WIDTHxHEIGHT -> compact|comfortable (short side <= 520 or long side <= 900 is compact)
    local w="${1%%x*}" h="${1##*x}"
    [[ "$w" =~ ^[0-9]+$ ]] || { echo compact; return; }
    if ! [[ "$h" =~ ^[0-9]+$ ]]; then [ "$w" -le 900 ] && echo compact || echo comfortable; return; fi
    local s=$w l=$h; [ "$h" -lt "$w" ] && { s=$h; l=$w; }
    if [ "$s" -le 520 ] || [ "$l" -le 900 ]; then echo compact; else echo comfortable; fi
}

screen_orientation() {  # WIDTHxHEIGHT -> wide|tall
    local w="${1%%x*}" h="${1##*x}"
    [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] && [ "$h" -gt "$w" ] && echo tall || echo wide
}

do_screen_test() {
    print_header "Screen test (read-only)"
    local r t; read -r r t < <(detect_screen)
    if [ -n "$r" ]; then print_success "Screen found: $r (ZR Tools size: comfortable by default; Auto would pick $(screen_density_hint "$r"))"
        print_success "Orientation: $(screen_orientation "$r") (ZR Tools lays itself out for wide and tall screens)"; else print_warning "No screen found on the Pi's video output."; fi
    [ "$t" = touch ] && print_success "Touch device found." || print_warning "No touch device found (a USB touch cable, or the screen has no touch)."
    echo "  Rotation is an operating-system setting, see README 'Touchscreen'."
}

write_screen_conf() {  # layout from --screen-layout, else keep, else default tabs; density comfortable
    local layout="$SCREEN_LAYOUT" theme=dark density=comfortable
    if [ -f "$ZR_CONF" ]; then
        [ -n "$layout" ] || layout="$(sed -n 's/^layout *= *//p' "$ZR_CONF" | head -n1)"
        theme="$(sed -n 's/^theme *= *//p' "$ZR_CONF" | head -n1)"; density="$(sed -n 's/^density *= *//p' "$ZR_CONF" | head -n1)"
    fi
    case "$layout" in tabs|grid) ;; *) layout=tabs ;; esac
    case "$theme" in dark|light) ;; *) theme=dark ;; esac
    case "$density" in auto|compact|comfortable) ;; *) density=comfortable ;; esac
    [ "$DRY" = 1 ] && { echo -e "  ${DIM}would write $ZR_CONF (layout=$layout)${NC}"; return 0; }
    mkdir -p "$(dirname "$ZR_CONF")"
    printf '# Written by ./installer.sh and the ZR Tools Settings page\n[screen]\nlayout = %s\ndensity = %s\ntheme = %s\n' "$layout" "$density" "$theme" > "$ZR_CONF"
}

copy_zr_panel() {  # (re)copy the panel files into KlipperScreen
    [ "$DRY" = 1 ] && { echo -e "  ${DIM}would copy zr_tools/*.py into ~/KlipperScreen/panels${NC}"; return 0; }
    mkdir -p "$KS_DIR/panels"
    cp "$REPO_DIR"/zr_tools/{zr_tools.py,zr_views.py,zr_logic.py} "$KS_DIR/panels/"
    if [ -d "$KS_DIR/.git" ]; then   # KlipperScreen updates must not delete our files
        mkdir -p "$KS_DIR/.git/info"
        grep -qs '^panels/zr_' "$KS_DIR/.git/info/exclude" || echo 'panels/zr_*.py' >> "$KS_DIR/.git/info/exclude"
    fi
}

step_macros() {   # only the ZR Tools macros in printer.cfg: for people whose screen is the WonderMaker screen board (its KlipperScreen sends these macros to this Pi)
    print_header "Step 11: ZR Tools macros (no KlipperScreen on this Pi)"
    why "The ZR Tools page on the WonderMaker screen board sends commands such as ZR_SET_TOOL_INFO and ZR_LOAD to Klipper. They are macros in zr_tools.cfg, which printer.cfg must include. KlipperScreen itself is not installed on this Pi."
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would copy zr_tools.cfg and add [include zr_tools.cfg] to printer.cfg${NC}"; return 0; fi
    mkdir -p "$HOME_DIR/printer_data/config"
    if [ -f "$HOME_DIR/printer_data/config/printer.cfg" ]; then
        HOME="$HOME_DIR" ZR_NO_RESTART=1 bash "$REPO_DIR/zr_tools/install_zr_tools.sh" >/dev/null && print_success "ZR Tools macros added to printer.cfg" \
            || warn_later "Could not add the ZR Tools macros. Run ./installer.sh --update."
    else warn_later "printer.cfg not found: ZR Tools macros not installed. Run ./installer.sh --update."; fi
}

step_screen() {
    [ "$WANT_SCREEN" = macros ] && { step_macros; return 0; }
    [ "$WANT_SCREEN" = 1 ] || return 0
    print_header "Step 11: touchscreen (KlipperScreen + ZR Tools)"
    why "A screen connected to the Pi shows KlipperScreen with a ZR Tools page: toolheads, filament, climate, calibration, ACE Pro (if present). Not yet tested on hardware."
    local r t; read -r r t < <(detect_screen)
    [ -n "$r" ] && print_info "Screen found: $r, size comfortable by default" || print_warning "No screen detected now. KlipperScreen is installed anyway."
    [ "$t" = touch ] || print_warning "No touch device detected now."
    local pin url sha; pin="$(addon_pin klipperscreen)"; url="${pin%|*}"; sha="${pin#*|}"
    fetch_addon "$url" "$sha" "$KS_DIR" || { warn_later "Could not download KlipperScreen (network?). Run ./installer.sh --update later."; return 0; }
    local be=X comp=""
    case "$SCREEN_BACKEND" in weston) be=W; comp=weston ;; cage) be=W; comp=cage ;; esac
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: KlipperScreen-install.sh (backend $SCREEN_BACKEND, service on, NetworkManager off)${NC}"
    elif [ "$TESTING" = 1 ]; then echo "[test] KlipperScreen-install backend=$SCREEN_BACKEND" >> "$HOME_DIR/.sudo.log"
    else
        ( cd "$KS_DIR" && BACKEND="$be" COMPOSITOR="$comp" SERVICE=y START=0 NETWORK=n bash scripts/KlipperScreen-install.sh ) \
            || { warn_later "KlipperScreen install failed (see output above). Run ./installer.sh --update to retry."; return 0; }
    fi
    copy_zr_panel
    write_screen_conf
    if [ "$DRY" != 1 ]; then
        mkdir -p "$HOME_DIR/printer_data/config"
        [ -f "$HOME_DIR/printer_data/config/printer.cfg" ] && \
            HOME="$HOME_DIR" ZR_NO_RESTART=1 bash "$REPO_DIR/zr_tools/install_zr_tools.sh" >/dev/null || warn_later "printer.cfg not found: ZR Tools macros not installed. Run ./installer.sh --update."
    fi
    record "HOMEDIR KlipperScreen"; record "FILE /etc/systemd/system/KlipperScreen.service"
    SUDO systemctl enable KlipperScreen
    [ "$AUTOSTART" = 1 ] && SUDO systemctl restart KlipperScreen
    print_success "Touchscreen installed (layout: $(sed -n 's/^layout *= *//p' "$ZR_CONF" 2>/dev/null | head -n1)). Change it with ./installer.sh --screen-layout tabs|grid or on the ZR Tools Settings page."
    [ "$SCREEN_BACKEND" = x11 ] && echo "  Rotate: add 'xrandr --output <name> --rotate left' to an X11 autostart (README, 'Touchscreen')."
}

rm_path() {   # delete files or folders; when the Pi user may not (an uninstaller ran as root and left root-owned files), retry with sudo
    local p
    for p in "$@"; do
        [ -e "$p" ] || [ -L "$p" ] || continue
        rm -rf "$p" 2>/dev/null
        if [ -e "$p" ] || [ -L "$p" ]; then print_info "Needs administrator rights: $p"; SUDO rm -rf "$p"; fi
        if [ "$TESTING" != 1 ] && { [ -e "$p" ] || [ -L "$p" ]; }; then print_warning "Could not delete $p. Try: sudo rm -rf '$p'"; fi
    done
}
leftover_report() {   # what of this installer is still on the Pi, and how to remove it
    local f n=0 list=()
    for f in "$HOME_DIR/printer_data" "$HOME_DIR/TM_T1" "$HOME_DIR/wm-stage" "$HOME_DIR/wm-backups" "$HOME_DIR/wm-install-logs" "$BACKUP_ROOT" "$HOME_DIR"/wm-support-*.tgz "$REPO_DIR"; do [ -e "$f" ] && list+=("$f"); done
    [ "${#list[@]}" = 0 ] && return 0
    echo "  Still on this Pi (kept on purpose, or not part of the removal):"
    for f in "${list[@]}"; do
        case "$f" in
            "$HOME_DIR/printer_data"|"$HOME_DIR/TM_T1") echo "    $f   -> Uninstall: My printer data" ;;
            "$REPO_DIR") echo "    $f   -> Uninstall: Clean up installer files (the installer folder)" ;;
            *) echo "    $f   -> Uninstall: Clean up installer files" ;;
        esac
    done
}
run_official_uninstall() {   # name dir command... : the add-on's OWN uninstaller, run first. Returns 0 when it ran and succeeded.
    local name="$1" dir="$2"; shift 2
    if [ "$TESTING" = 1 ]; then echo "[test] official uninstall $name: $*" >> "$HOME_DIR/.sudo.log"; return 0; fi
    [ -d "$dir" ] || return 1
    print_info "Running $name's own uninstaller ($*) ..."
    if ( cd "$dir" && "$@" ); then return 0; fi
    print_warning "$name's own uninstaller did not finish cleanly; the installer finishes the removal itself below."; return 1
}
official_with_answers() {   # command... : at a terminal the maker's uninstaller asks you its own questions; otherwise it is answered with yes
    if remote_interactive; then "$@"; else yes y 2>/dev/null | "$@"; fi
}
moonraker_drop_update_section() {   # name : remove [update_manager NAME] from moonraker.conf (copy kept), so Fluidd stops listing a removed add-on
    local f="$HOME_DIR/printer_data/config/moonraker.conf"
    [ -f "$f" ] || return 0
    grep -qiE "^\[update_manager +$1\]" "$f" || return 0
    cp "$f" "$f.wm-before-$1-removal-$STAMP"
    python3 - "$f" "$1" <<'PY'
import sys, re
p, name = sys.argv[1], sys.argv[2].lower()
out = []; skip = False
for l in open(p).read().split("\n"):
    m = re.match(r"\s*\[(.+?)\]", l)
    if m: skip = m.group(1).strip().lower() == "update_manager " + name
    if not skip: out.append(l)
open(p, "w").write("\n".join(out))
PY
    print_info "Removed [update_manager $1] from moonraker.conf (copy: moonraker.conf.wm-before-$1-removal-$STAMP)"
}
do_screen_remove() {
    print_header "Remove the touchscreen (KlipperScreen)"
    load_answers || true
    [ -d "$KS_DIR" ] || [ "$TESTING" = 1 ] || [ -f /etc/systemd/system/KlipperScreen.service ] || die_with_fix "KlipperScreen is not installed on this Pi." "nothing to remove."
    echo "Removes the KlipperScreen service, ~/KlipperScreen and its Python environment. Klipper, Moonraker, Fluidd and the ZR Tools macros stay."
    ask_yn "Continue?" n || exit 0
    run_official_uninstall KlipperScreen "$KS_DIR" bash scripts/Uninstall.sh
    SUDO systemctl stop KlipperScreen; SUDO systemctl disable KlipperScreen
    SUDO rm -f /etc/systemd/system/KlipperScreen.service; SUDO systemctl daemon-reload
    if [ "$DRY" != 1 ]; then
        rm_path "$KS_DIR" "$HOME_DIR/.KlipperScreen-env"
        moonraker_drop_update_section KlipperScreen
        local f="$HOME_DIR/printer_data/config/KlipperScreen.conf"
        [ -f "$f" ] && sed -i '/^\[menu __main zr_tools\]/,/^$/d' "$f"
        WANT_SCREEN=macros; save_answers     # the ZR Tools macros stay in printer.cfg
    fi
    print_success "KlipperScreen removed. The ZR Tools macros and your settings file zr_screen.conf were kept. Add KlipperScreen again with: ./installer.sh --screen on --update"
}

do_screen_layout() {
    print_header "Screen layout"
    write_screen_conf
    SUDO systemctl restart KlipperScreen
    print_success "Layout set to $SCREEN_LAYOUT."
}

fetch_addon() {  # url sha dir : clone once, then pin to the version WonderMaker ships
    local url="$1" sha="$2" dir="$3"
    [ "$DRY" = 1 ] && { echo -e "  ${DIM}would run: git clone $url $dir @ ${sha:0:7}${NC}"; return 0; }
    if [ "$TESTING" = 1 ]; then mkdir -p "$dir/component" "$dir/klipper_macro"; echo "[test] fetch $url @ $sha" >> "$HOME_DIR/.sudo.log"; return 0; fi
    [ -d "$dir/.git" ] || git clone -q "$url" "$dir" || return 1
    git -C "$dir" checkout -q "$sha"
}
addon_pin() { grep "^$1|" "$SCRIPT_DIR/config/pins/addons.txt" | cut -d'|' -f2,3; }

step_timelapse() {
    [ "$WANT_TIMELAPSE" = 1 ] || return 0
    print_header "Step 12: Moonraker timelapse"
    why "WonderMaker's config includes timelapse.cfg and a [timelapse] section; the component and ffmpeg make them work."
    SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y ffmpeg
    local pin url sha; pin="$(addon_pin moonraker-timelapse)"; url="${pin%|*}"; sha="${pin#*|}"
    fetch_addon "$url" "$sha" "$HOME_DIR/moonraker-timelapse" || { warn_later "Could not download moonraker-timelapse (network?)."; return 0; }
    run mkdir -p "$HOME_DIR/printer_data/timelapse" "$HOME_DIR/moonraker/moonraker/components"
    [ -f "$HOME_DIR/moonraker/moonraker/components/timelapse.py" ] || run ln -sf "$HOME_DIR/moonraker-timelapse/component/timelapse.py" "$HOME_DIR/moonraker/moonraker/components/timelapse.py"
    [ -f "$HOME_DIR/printer_data/config/timelapse.cfg" ] || run cp "$HOME_DIR/moonraker-timelapse/klipper_macro/timelapse.cfg" "$HOME_DIR/printer_data/config/timelapse.cfg"
    record "HOMEDIR moonraker-timelapse"
    print_success "Timelapse ready"
}

step_shellcmd() {   # Arksine's gcode_shell_command module (GPLv3), copied from config/. It does nothing until printer.cfg has a [gcode_shell_command name] section.
    [ "$WANT_SHELLCMD" = 1 ] || return 0
    print_header "Step 12b: Klipper gcode shell command"
    why "Adds RUN_SHELL_COMMAND CMD=name. Each command is defined by you in printer.cfg as [gcode_shell_command name] with a command: line. Klipper loads it only after you restart Klipper."
    local src="$SCRIPT_DIR/config/gcode_shell_command.py" dst="$HOME_DIR/klipper/klippy/extras/gcode_shell_command.py"
    [ -f "$src" ] || { warn_later "gcode_shell_command.py is missing from this repository ($src)."; return 0; }
    [ "$DRY" = 1 ] || [ -d "$HOME_DIR/klipper/klippy/extras" ] || { warn_later "~/klipper/klippy/extras not found: the shell command extension was not installed. Run ./installer.sh --update."; return 0; }
    if [ "$DRY" != 1 ] && cmp -s "$src" "$dst" 2>/dev/null; then print_success "gcode_shell_command is already up to date"; return 0; fi
    run cp "$src" "$dst"
    record "FILE $dst"
    print_success "gcode_shell_command installed. Add a section like this to printer.cfg, then restart Klipper:"
    echo "      [gcode_shell_command hello]"
    echo "      command: echo hello"
    echo "      timeout: 2.0"
    echo "      verbose: True"
    echo "    and run it with:  RUN_SHELL_COMMAND CMD=hello   (extra words: PARAMS=\"a b\")"
}

# ---------------------------------------------------------------------------
# Remote access add-ons: Obico, OctoApp, OctoEverywhere. Each is the maker's own project, cloned into ~ and installed with
# the maker's own installer, pointed at WonderMaker's Moonraker (127.0.0.1:7125, ~/printer_data/config/moonraker.conf, moonraker.service).
# Linking to your account always needs you (a code or a link shown on screen), so that last step is left to you.
# ---------------------------------------------------------------------------
remote_interactive() { [ "${WM_ASSUME_YES:-0}" != 1 ] && [ -t 0 ] && [ -t 1 ] && [ "$TESTING" != 1 ]; }
remote_moonraker_port() { local p; p="$(awk -F'[: ]+' '/^\[server\]/{s=1;next} /^\[/{s=0} s&&$1=="port"{print $2; exit}' "$HOME_DIR/printer_data/config/moonraker.conf" 2>/dev/null)"; echo "${p:-7125}"; }

remote_clone() {   # url dir : clone once; later runs only fast-forward
    local url="$1" dir="$2"
    [ "$DRY" = 1 ] && { echo -e "  ${DIM}would run: git clone $url $dir${NC}"; return 0; }
    if [ "$TESTING" = 1 ]; then mkdir -p "$dir"; : > "$dir/install.sh"; echo "[test] clone $url" >> "$HOME_DIR/.sudo.log"; return 0; fi
    if [ -d "$dir/.git" ]; then git -C "$dir" pull -q --ff-only 2>/dev/null || print_warning "Could not update $dir (kept as it is)."; return 0; fi
    git clone -q "$url" "$dir"
}

remote_precheck() {   # the facts these add-ons need from WonderMaker's Moonraker; returns 1 and says why when something is missing
    local conf="$HOME_DIR/printer_data/config/moonraker.conf" ok=0
    [ "$DRY" = 1 ] && return 0
    [ -f "$conf" ] || { warn_later "Remote access add-ons need $conf. Run ./installer.sh first."; ok=1; }
    [ "$TESTING" = 1 ] || [ -f /etc/systemd/system/moonraker.service ] || { warn_later "Remote access add-ons need /etc/systemd/system/moonraker.service. Run ./installer.sh --repair."; ok=1; }
    command -v git >/dev/null 2>&1 || [ "$TESTING" = 1 ] || { warn_later "git is missing: sudo apt-get install git"; ok=1; }
    grep -q '^\[authorization\]' "$conf" 2>/dev/null && ! grep -q '127\.0\.0\.' "$conf" && print_warning "moonraker.conf has an [authorization] section without 127.0.0.0/8 in trusted_clients: the add-ons connect from this Pi and may be refused."
    return $ok
}

remote_note_update_manager() {
    print_info "The add-on adds an [update_manager ...] section to moonraker.conf so Fluidd can update it. Fluidd may then also list Klipper and Moonraker as not updatable (they are not git clones here): do not press update on those two; use ./installer.sh --update."
}

obico_choose_server() {   # Obico's website or your own server; asked once and remembered
    [ -n "$OBICO_SERVER" ] && return 0
    OBICO_SERVER="https://app.obico.io"
    [ "${WM_ASSUME_YES:-0}" = 1 ] && return 0
    echo "  Obico can connect to:"
    echo "    1) Obico's own website (app.obico.io, free account)   <- default"
    echo "    2) My own self-hosted Obico server"
    local c u tries=0; read -r -p "$(echo -e "${YELLOW}?${NC} Choose 1 or 2 [1]: ")" c || c=1
    [ "$c" = 2 ] || { print_success "Obico: app.obico.io"; return 0; }
    while [ "$tries" -lt 3 ]; do
        read -r -p "  Address of your Obico server (for example http://obico.local:3334): " u || break
        u="${u%/}"
        case "$u" in http://?*|https://?*) case "$u" in *" "*) ;; *) OBICO_SERVER="$u"; print_success "Obico server: $OBICO_SERVER"; return 0 ;; esac ;; esac
        print_warning "That is not a web address (it must start with http:// or https:// and have no spaces)."; tries=$((tries+1))
    done
    print_warning "No valid server address given: using app.obico.io. To change it later: ./installer.sh --remove obico, then ./installer.sh --update --obico on --obico-server <address>"
}

obico_cfg_url() {   # the server written in moonraker-obico.cfg ([server] url), without a trailing slash
    sed -n '/^\[server\]/,/^\[/{s/^url *= *//p}' "$HOME_DIR/printer_data/config/moonraker-obico.cfg" 2>/dev/null | head -n1 | tr -d '[:space:]' | sed 's#/*$##'
}
obico_set_server() {   # point an installed Obico at $OBICO_SERVER (the printer has to be linked again on the new server)
    local f="$HOME_DIR/printer_data/config/moonraker-obico.cfg" have; have="$(obico_cfg_url)"
    [ -f "$f" ] || return 0
    [ "$have" = "$OBICO_SERVER" ] && return 0
    cp "$f" "$f.wm-before-server-change-$STAMP"
    python3 - "$f" "$OBICO_SERVER" <<'PY'
import sys, re
p, url = sys.argv[1], sys.argv[2]
lines = open(p).read().split("\n"); out = []; sect = ""; done = False
for l in lines:
    m = re.match(r"\s*\[(.+?)\]", l)
    if m: sect = m.group(1)
    if sect == "server" and re.match(r"\s*url\s*=", l) and not done: l = "url = " + url; done = True
    elif sect == "server" and re.match(r"\s*auth_token\s*=", l): l = "# " + l + "   # linked to the previous server"
    out.append(l)
open(p, "w").write("\n".join(out))
PY
    SUDO systemctl restart moonraker-obico
    print_success "Obico now points to $OBICO_SERVER (was: ${have:-unknown}). A copy of the old settings: $(basename "$f").wm-before-server-change-$STAMP"
    echo "    Link the printer again on the new server (a 6-digit code):  ~/moonraker-obico/scripts/link.sh -c ~/printer_data/config/moonraker-obico.cfg"
}
step_obico() {
    [ "$WANT_OBICO" = 1 ] || return 0
    print_header "Step 12c: Obico for Klipper"
    why "moonraker-obico connects Moonraker to Obico (app.obico.io, or your own Obico server): remote view, notifications and failure detection. It uses WonderMaker's [pause_resume], PAUSE/RESUME/CANCEL_PRINT and [exclude_object], which are already in printer.cfg."
    remote_precheck || return 0
    obico_choose_server
    local dir="$HOME_DIR/moonraker-obico" conf="$HOME_DIR/printer_data/config" port fflag="" have; port="$(remote_moonraker_port)"
    # Obico's installer keeps an existing moonraker-obico.cfg and ignores -S then, so an old file would silently keep the old server.
    if [ -f "$conf/moonraker-obico.cfg" ]; then
        have="$(obico_cfg_url)"
        if [ "$have" != "$OBICO_SERVER" ]; then fflag="-f"; print_warning "An older Obico settings file points to ${have:-an unknown server}. It is reset to $OBICO_SERVER (Obico keeps a dated copy) and you link the printer again."; fi
    fi
    remote_clone https://github.com/TheSpaghettiDetective/moonraker-obico.git "$dir" || { warn_later "Could not download moonraker-obico (network?)."; return 0; }
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: $dir/install.sh -H 127.0.0.1 -p $port -C $conf/moonraker.conf -l ~/printer_data/logs -S $OBICO_SERVER -L${fflag:+ $fflag}${NC}"
    elif [ "$TESTING" = 1 ]; then echo "[test] obico install.sh -H 127.0.0.1 -p $port -C $conf/moonraker.conf -S $OBICO_SERVER -L${fflag:+ $fflag}" >> "$HOME_DIR/.sudo.log"
    else
        [ -f "$conf/printer.cfg" ] && cp "$conf/printer.cfg" "$conf/printer.cfg.wm-before-obico-$STAMP" && print_info "Obico adds one include line to printer.cfg. A copy was saved as printer.cfg.wm-before-obico-$STAMP"
        ( cd "$dir" && bash ./install.sh -H 127.0.0.1 -p "$port" -C "$conf/moonraker.conf" -l "$HOME_DIR/printer_data/logs" -S "$OBICO_SERVER" -L $fflag ) \
            || { warn_later "The Obico installer failed (see the output above). Run it again later: cd ~/moonraker-obico && ./install.sh"; return 0; }
    fi
    record "HOMEDIR moonraker-obico"
    if [ "$DRY" != 1 ] && [ "$TESTING" != 1 ] && [ "$(obico_cfg_url)" != "$OBICO_SERVER" ]; then obico_set_server; fi
    remote_note_update_manager
    print_success "Obico installed (server: $OBICO_SERVER). Link your printer to your account (it shows a 6-digit code to type at $OBICO_SERVER):"
    echo "      ~/moonraker-obico/scripts/link.sh -c ~/printer_data/config/moonraker-obico.cfg"
    echo "    Then restart Klipper from Fluidd (it adds moonraker_obico_macros.cfg to printer.cfg)."
}

step_octoapp() {
    [ "$WANT_OCTOAPP" = 1 ] || return 0
    print_header "Step 12d: OctoApp"
    why "OctoApp's own installer (method 1c on its wiki: git clone + ./install.sh) is pointed at this Pi's Moonraker. It creates ~/octoapp, ~/octoapp-env and the octoapp service."
    remote_precheck || return 0
    local dir="$HOME_DIR/octoapp" conf="$HOME_DIR/printer_data/config/moonraker.conf"
    remote_clone https://github.com/crysxd/OctoApp-Plugin.git "$dir" || { warn_later "Could not download OctoApp (network?)."; return 0; }
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: $dir/install.sh $conf moonraker.service${NC}"; return 0
    elif [ "$TESTING" = 1 ]; then echo "[test] octoapp install.sh $conf moonraker.service" >> "$HOME_DIR/.sudo.log"
    elif remote_interactive; then
        echo "  OctoApp's installer asks a few questions; answer them on screen."
        ( cd "$dir" && bash ./install.sh "$conf" moonraker.service ) || { warn_later "The OctoApp installer did not finish. Run it again: cd ~/octoapp && ./install.sh $conf moonraker.service"; return 0; }
    else
        print_info "OctoApp's installer asks questions, so it was not started. It is downloaded; finish it in a terminal:"
        echo "      cd ~/octoapp && ./install.sh $conf moonraker.service"
        return 0
    fi
    record "HOMEDIR octoapp"; record "HOMEDIR octoapp-env"
    remote_note_update_manager
    print_success "OctoApp installed. Open the OctoApp phone app on the same network; it registers by itself."
}

step_octoeverywhere() {
    [ "$WANT_OCTOEVERYWHERE" = 1 ] || return 0
    print_header "Step 12e: OctoEverywhere"
    why "OctoEverywhere's own installer is pointed at this Pi's Moonraker. It creates ~/octoeverywhere, ~/octoeverywhere-env and the octoeverywhere service, then prints a link to connect it to your free account."
    remote_precheck || return 0
    local dir="$HOME_DIR/octoeverywhere" conf="$HOME_DIR/printer_data/config/moonraker.conf"
    remote_clone https://github.com/QuinnDamerell/OctoPrint-OctoEverywhere.git "$dir" || { warn_later "Could not download OctoEverywhere (network?)."; return 0; }
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: $dir/install.sh $conf moonraker.service${NC}"; return 0
    elif [ "$TESTING" = 1 ]; then echo "[test] octoeverywhere install.sh $conf moonraker.service" >> "$HOME_DIR/.sudo.log"
    elif remote_interactive; then
        echo "  OctoEverywhere's installer asks a few questions and shows a link for your account; follow it on screen."
        ( cd "$dir" && bash ./install.sh "$conf" moonraker.service ) || { warn_later "The OctoEverywhere installer did not finish. Run it again: cd ~/octoeverywhere && ./install.sh $conf moonraker.service"; return 0; }
    else
        print_info "OctoEverywhere's installer asks questions, so it was not started. It is downloaded; finish it in a terminal:"
        echo "      cd ~/octoeverywhere && ./install.sh $conf moonraker.service"
        return 0
    fi
    record "HOMEDIR octoeverywhere"; record "HOMEDIR octoeverywhere-env"
    remote_note_update_manager
    print_success "OctoEverywhere installed. Open the link it printed to connect your account."
}

step_remote() { step_obico; step_octoapp; step_octoeverywhere; }
step_remote_update() {   # --update: never run the makers' installers again for something already there (Fluidd's update manager updates them)
    local pair name var dir
    for pair in "obico:WANT_OBICO:moonraker-obico" "octoapp:WANT_OCTOAPP:octoapp" "octoeverywhere:WANT_OCTOEVERYWHERE:octoeverywhere"; do
        IFS=: read -r name var dir <<< "$pair"
        [ "${!var}" = 1 ] || continue
        if [ -d "$HOME_DIR/$dir" ]; then
            print_success "$name is already installed (update it from Fluidd's update manager, or: cd ~/$dir && git pull)"
            [ "$name" = obico ] && [ -n "$OBICO_SERVER" ] && obico_set_server
        else "step_${name}"; fi
    done
}

step_crowsnest() {
    [ "$WANT_CROWSNEST" = 1 ] || return 0
    print_header "Step 13: webcam service (crowsnest)"
    why "Streams USB cameras on ports 8080-8083, where the nginx config looks for them. Built from the version WonderMaker ships."
    local pin url sha; pin="$(addon_pin crowsnest)"; url="${pin%|*}"; sha="${pin#*|}"
    fetch_addon "$url" "$sha" "$HOME_DIR/crowsnest" || { warn_later "Could not download crowsnest (network?)."; return 0; }
    [ -f "$HOME_DIR/printer_data/config/crowsnest.conf" ] || run cp "$SCRIPT_DIR/config/crowsnest.conf" "$HOME_DIR/printer_data/config/crowsnest.conf"
    if [ "$DRY" = 1 ]; then echo -e "  ${DIM}would run: sudo make install in ~/crowsnest (unattended; builds ustreamer, installs crowsnest.service)${NC}"
    elif [ "$TESTING" = 1 ]; then echo "[test] sudo make install (crowsnest)" >> "$HOME_DIR/.sudo.log"
    else
        local conf="$HOME_DIR/printer_data/config/crowsnest.conf"; cp "$conf" "$conf.wm-keep"   # crowsnest's installer replaces the file with its own default
        ( cd "$HOME_DIR/crowsnest" && sudo env CROWSNEST_UNATTENDED=1 CROWSNEST_ADD_CROWSNEST_MOONRAKER=0 make install ) || { warn_later "crowsnest install failed. See the output above; webcams are optional."; cp "$conf.wm-keep" "$conf"; return 0; }
        cp "$conf.wm-keep" "$conf"; rm -f "$conf.wm-keep"
    fi
    record "HOMEDIR crowsnest"; record "FILE /etc/systemd/system/crowsnest.service"
    print_success "crowsnest installed. Set your camera in ~/printer_data/config/crowsnest.conf (ls /dev/v4l/by-id/), then: sudo systemctl restart crowsnest"
}

step_start() {
    print_header "Step 14: start Moonraker"
    SUDO systemctl restart moonraker
    if [ "$TESTING" != 1 ] && [ "$DRY" != 1 ]; then
        sleep 4
        curl -fsS -m 5 http://127.0.0.1:7125/server/info >/dev/null 2>&1 && print_success "Moonraker answers on port 7125" || warn_later "Moonraker did not answer yet. Look at: journalctl -u moonraker -n 50"
    fi
}

questions() {
    print_header "A few questions"
    ask_yn "Install the Fluidd with the WonderMaker Toolheads panel (recommended)?" y || WANT_PANEL=0
    ask_yn "Install webcam support (crowsnest, as WonderMaker uses)?" y || WANT_CROWSNEST=0
    ask_yn "Install timelapse support (Moonraker timelapse + ffmpeg)?" y || WANT_TIMELAPSE=0
    local rname rvar rtext
    for rname in obico octoapp octoeverywhere; do
        case "$rname" in
            obico)          rvar=WANT_OBICO;          rtext="Obico for Klipper (remote view and print-failure detection; account at obico.io or your own server)" ;;
            octoapp)        rvar=WANT_OCTOAPP;        rtext="OctoApp (phone app notifications and remote control)" ;;
            octoeverywhere) rvar=WANT_OCTOEVERYWHERE; rtext="OctoEverywhere (remote access, webcam and notifications; free account)" ;;
        esac
        if [ "${!rvar}" = ask ]; then
            if ask_yn "Install $rtext?" n; then printf -v "$rvar" 1; else printf -v "$rvar" 0; fi
        fi
    done
    [ "$WANT_OBICO" = 1 ] && obico_choose_server
    if [ "$WANT_SCREEN" = ask ]; then
        local r t; read -r r t < <(detect_screen)
        [ -n "$r" ] && print_info "A screen is connected: $r"
        if ask_yn "Add a touchscreen (KlipperScreen with the ZR Tools page) on this Pi?" y; then WANT_SCREEN=1
        elif ask_yn "Add only the ZR Tools macros (needed if the WonderMaker screen board is your screen)?" y; then WANT_SCREEN=macros
        else WANT_SCREEN=0; fi
    fi
    if [ "$WANT_NETMGR" = ask ]; then
        if [ "$WANT_SCREEN" != 1 ]; then WANT_NETMGR=0
        elif nm_active; then print_info "NetworkManager is already running here, so KlipperScreen's Network panel will work."; WANT_NETMGR=0
        else
            echo "  KlipperScreen has a Network panel (pick a Wi-Fi network on the screen). It needs NetworkManager."
            echo -e "  ${YELLOW}Note:${NC} switching this Pi to NetworkManager can DROP the network connection (your SSH session and Fluidd) and you may have to enter the Wi-Fi password again on the screen or with nmtui."
            echo "  Nothing is restarted by the installer: the change starts at the next reboot. You can add it later with: ./installer.sh --update --network-manager on"
            if ask_yn "Install NetworkManager for the Network panel?" n; then WANT_NETMGR=1; else WANT_NETMGR=0; fi
        fi
    fi
}

# ============================================================================
# Checks and state (all of these can be faked in tests with WM_TEST_* variables)
# ============================================================================
test_systemctl() {  # fake service state for tests
    [ "$1" = systemctl ] || return 0
    local v="${2:-}" u="${3:-}"; mkdir -p "$HOME_DIR/.svc"
    case "$v" in
        enable) touch "$HOME_DIR/.svc/$u.enabled" ;;
        disable) rm -f "$HOME_DIR/.svc/$u.enabled" ;;
        start|restart) touch "$HOME_DIR/.svc/$u.active" ;;
        stop) rm -f "$HOME_DIR/.svc/$u.active" ;;
    esac
}
service_state() {
    if [ "$TESTING" = 1 ]; then [ -f "$HOME_DIR/.svc/$1.active" ] && echo active || echo inactive; return; fi
    systemctl is-active "$1" 2>/dev/null || true
}
service_enabled() {
    if [ "$TESTING" = 1 ]; then [ -f "$HOME_DIR/.svc/$1.enabled" ] && echo enabled || echo disabled; return; fi
    systemctl is-enabled "$1" 2>/dev/null || true
}
net_ok()   { [ "$TESTING" = 1 ] && { [ "${WM_TEST_NO_NET:-0}" != 1 ]; return; }; curl -fsI -m 8 "$1" >/dev/null 2>&1; }
usb_bridge_present() { [ "$TESTING" = 1 ] && { [ "${WM_TEST_BRIDGE:-1}" = 1 ]; return; }; lsusb 2>/dev/null | grep -qi '1d50:606f'; }
can_exists()  { [ "$TESTING" = 1 ] && { [ "${WM_TEST_CAN:-1}" != none ]; return; }; ip link show can0 >/dev/null 2>&1; }
can_is_up()   { [ "$TESTING" = 1 ] && { [ "${WM_TEST_CAN:-1}" = 1 ]; return; }; [ "$(ip -br link show can0 2>/dev/null | awk '{print $2}')" = UP ]; }
can_query_raw() {
    if [ "$TESTING" = 1 ]; then cat "${WM_TEST_CANQUERY:-/dev/null}" 2>/dev/null; return 0; fi
    "$HOME_DIR/klippy-env/bin/python" "$HOME_DIR/klipper/scripts/canbus_query.py" can0 2>&1
}
power_flags() { [ "$TESTING" = 1 ] && { echo "${WM_TEST_THROTTLED:-0x0}"; return; }; vcgencmd get_throttled 2>/dev/null | sed 's/.*=//'; }
ntp_ok()      { [ "$TESTING" = 1 ] && { return 0; }; [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; }
api_get() {  # path -> body (empty on failure)
    if [ "$TESTING" = 1 ]; then [ "${WM_TEST_MOONRAKER:-1}" = 1 ] && echo '{"result":{"klippy_state":"'"${WM_TEST_KLIPPY:-ready}"'","moonraker_version":"test"}}'; return 0; fi
    curl -fsS -m 4 "http://127.0.0.1:7125$1" 2>/dev/null
}
klippy_state() { api_get /server/info | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["klippy_state"])' 2>/dev/null; }
print_state() {
    [ "$TESTING" = 1 ] && { echo "${WM_TEST_PRINT_STATE:-}"; return; }
    api_get '/printer/objects/query?print_stats=state' | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["status"]["print_stats"]["state"])' 2>/dev/null
}
guard_not_printing() {
    local s; s="$(print_state)"
    case "$s" in printing|paused)
        if [ "$FORCE" = 1 ]; then print_warning "A print is active ($s) but --force was given."
        else die_with_fix "a print is active ($s)." "wait until it ends, or use --force (not recommended)."; fi ;;
    esac
}
cfg_dir() { echo "$HOME_DIR/printer_data/config"; }
cfg_uuids() {  # prints "file uuid" for every non-empty canbus_uuid in the config
    local f; for f in "$(cfg_dir)"/*.cfg; do [ -f "$f" ] || continue
        awk -F: 'tolower($1) ~ /^[ \t]*canbus_uuid[ \t]*$/ {v=$2; sub(/#.*/,"",v); gsub(/[ \t\r]/,"",v); if (v!="") print FILENAME" "tolower(v)}' "$f"
    done
}
found_uuids() { can_query_raw | grep -oiE 'canbus_uuid=[0-9a-f]{12}' | cut -d= -f2 | tr 'A-F' 'a-f' | sort -u; }
model_now() { cat "$HOME_DIR/printer_data/wm-model" 2>/dev/null || echo "$MODEL"; }

modules_present() {  # prints missing module names
    local m d="$HOME_DIR/klipper/klippy/extras"
    for m in "${COMPILED_MODULES[@]}"; do
        ls "$d/$m".*.so >/dev/null 2>&1 || [ -f "$d/$m.py" ] || echo "$m"
    done
}
restore_modules_from_repo() {  # copies the bundled factory modules, each checked against its checksum
    local src="$SCRIPT_DIR/factory/$(model_now)" sum path f n=0
    [ -f "$src/modules.sha256" ] || { print_error "no factory modules for $(model_now) in the repository"; return 1; }
    while read -r sum path; do
        f="$src/klipper/$path"
        [ -f "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$sum" ] || { print_error "$(basename "$path"): repository copy missing or damaged"; return 1; }
        run cp "$f" "$HOME_DIR/klipper/$path"; n=$((n+1))
    done < "$src/modules.sha256"
    print_success "$n compiled modules restored from the repository (checksums match)"
}

validate_config() {  # prints problems; returns the number of errors. Warnings do not count.
    local cfg="$(cfg_dir)/printer.cfg" errs=0 f inc
    [ -f "$cfg" ] || { print_error "printer.cfg not found in $(cfg_dir)"; return 1; }
    while read -r inc; do
        case "$inc" in *'*'*) continue ;; esac
        [ -f "$(cfg_dir)/$inc" ] || { print_error "printer.cfg includes $inc, but the file does not exist"; errs=$((errs+1)); }
    done < <(grep -E '^[[:space:]]*\[include ' "$cfg" | sed -E 's/^[[:space:]]*\[include +//; s/\].*//')
    local want have; have=off; grep -qE '^\[include zru-s.cfg\]' "$cfg" && have=on
    [ "$(model_now)" = ultra-s ] && want=on || want=off
    if [ "$have" != "$want" ]; then print_error "printer.cfg has zru-s.cfg $have, but the model is $(model_now) (needs $want)"; errs=$((errs+1)); fi
    [ -d "$HOME_DIR/printer_data/gcodes" ] || { print_warning "~/printer_data/gcodes is missing"; }
    return $errs
}

# ============================================================================
# Pre-flight, plan and saved answers
# ============================================================================
preflight() {
    print_header "Pre-flight checks"
    local bad=0
    if net_ok https://github.com; then print_success "Internet: github.com reachable"; else print_error "github.com is not reachable"; bad=1; fi
    if net_ok https://pypi.org; then print_success "Internet: pypi.org reachable"; else print_error "pypi.org is not reachable"; bad=1; fi
    local p; p="$(power_flags)"
    if [ -n "$p" ] && [ "$p" != 0x0 ]; then
        if [ $(( p & 0x1 )) -ne 0 ]; then print_warning "The Pi reports under-voltage right now ($p). Use the official 5 V / 3 A power supply."; warn_later "Under-voltage reported by the Pi ($p)."
        else print_warning "The Pi reported power or heat problems since boot ($p)."; fi
    else print_success "Power supply: no under-voltage reported"; fi
    ntp_ok && print_success "Clock is synchronized" || print_warning "The clock is not synchronized: HTTPS downloads can fail. Check the date or the network."
    [ "$bad" = 0 ] || die_with_fix "no internet access to the download servers." "check the network, then run the installer again."
}

save_answers() {
    [ "$DRY" = 1 ] && return 0
    mkdir -p "$BACKUP_ROOT"
    cat > "$CONF" <<E
VERSION=$VERSION
MODEL=$MODEL
SRC_KIND=$SRC_KIND
WANT_PANEL=$WANT_PANEL
WANT_SCREEN=$WANT_SCREEN
SCREEN_BACKEND=$SCREEN_BACKEND
REPO_DIR=$REPO_DIR
KS_PIN=$(addon_pin klipperscreen | cut -d'|' -f2)
WANT_TIMELAPSE=$WANT_TIMELAPSE
WANT_CROWSNEST=$WANT_CROWSNEST
WANT_SHELLCMD=$WANT_SHELLCMD
OBICO_SERVER=$OBICO_SERVER
WANT_OBICO=$WANT_OBICO
WANT_OCTOAPP=$WANT_OCTOAPP
WANT_OCTOEVERYWHERE=$WANT_OCTOEVERYWHERE
WANT_NETMGR=$WANT_NETMGR
CROWSNEST_PIN=$(addon_pin crowsnest | cut -d'|' -f2)
TIMELAPSE_PIN=$(addon_pin moonraker-timelapse | cut -d'|' -f2)
PANEL_SHA=$([ -n "$PANEL_ZIP" ] && sha256sum "$PANEL_ZIP" 2>/dev/null | cut -d' ' -f1)
E
}
load_answers() {
    [ -f "$CONF" ] || return 1
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            VERSION) OLD_VERSION="$v" ;; CROWSNEST_PIN) OLD_CN_PIN="$v" ;; TIMELAPSE_PIN) OLD_TL_PIN="$v" ;; PANEL_SHA) OLD_PANEL_SHA="$v" ;;
            MODEL) [ -n "${MODEL_SET:-}" ] || MODEL="$v" ;; SRC_KIND) : ;;
            WANT_PANEL|WANT_SCREEN|WANT_TIMELAPSE|WANT_CROWSNEST|WANT_SHELLCMD|WANT_OBICO|WANT_OCTOAPP|WANT_OCTOEVERYWHERE|WANT_NETMGR|OBICO_SERVER) printf -v "$k" '%s' "$v" ;;
            SCREEN_BACKEND) printf -v "$k" '%s' "$v" ;; KS_PIN) OLD_KS_PIN="$v" ;;
        esac
    done < "$CONF"
    local r; for r in ${CLI_REMOTE:-}; do case "$r" in obico) WANT_OBICO="$CLI_OBICO" ;; octoapp) WANT_OCTOAPP="$CLI_OCTOAPP" ;; octoeverywhere) WANT_OCTOEVERYWHERE="$CLI_OCTOEVERYWHERE" ;; netmgr) WANT_NETMGR="$CLI_NETMGR" ;; webcam) WANT_CROWSNEST="$CLI_WEBCAM" ;; timelapse) WANT_TIMELAPSE="$CLI_TIMELAPSE" ;; esac; done
    [ -n "${CLI_OBICO_SERVER:-}" ] && OBICO_SERVER="$CLI_OBICO_SERVER"
    [ -n "${CLI_SHELLCMD:-}" ] && WANT_SHELLCMD="$CLI_SHELLCMD"    # --shell-command on|off given now wins over the saved answer
    return 0
}
# Every optional program the installer can add. show_plan prints this list, so a new program (add its WANT_ variable here)
# appears in the plan; a test fails when a WANT_ variable is saved but missing from this list.
PLAN_OPTIONS=(
    "panel (Fluidd)|WANT_PANEL"
    "webcam|WANT_CROWSNEST"
    "timelapse|WANT_TIMELAPSE"
    "shell command|WANT_SHELLCMD"
    "touchscreen|WANT_SCREEN"
    "obico|WANT_OBICO"
    "octoapp|WANT_OCTOAPP"
    "octoeverywhere|WANT_OCTOEVERYWHERE"
    "network manager|WANT_NETMGR"
)
show_plan() {
    print_header "Plan (nothing has been changed yet)"
    echo "  Printer model:   $MODEL"
    echo "  Software from:   $SRC_KIND ${SRC_ARG:+($SRC_ARG)}"
    local d moved=""; for d in klipper moonraker printer_data fluidd TM_T1; do [ -e "$HOME_DIR/$d" ] && moved="$moved ~/$d"; done
    [ -n "$moved" ] && echo "  Moved to backup (~/wm-rpi-backup/old-*):$moved"
    echo "  Installs:        system packages, Python 3.9, Klipper/Moonraker environments, Moonraker + nginx services, can0 rule"
    echo "  Optional programs (yes = installed in this run, no = skipped):"
    local o name var val
    for o in "${PLAN_OPTIONS[@]}"; do
        name="${o%%|*}"; var="${o##*|}"; val="${!var:-}"
        case "$val" in
            1) val=yes ;; macros) val="only the ZR Tools macros" ;; ask) val="not chosen" ;; *) val=no ;;
        esac
        [ "$var" = WANT_OBICO ] && [ "$val" = yes ] && val="yes (server: ${OBICO_SERVER:-https://app.obico.io})"
        printf '      %-16s %s\n' "$name" "$val"
    done
    [ "$AUTOSTART" = 1 ] && echo "  At the end:      Klipper, Moonraker, nginx and crowsnest are enabled and started (checks are shown; failures are reported)" \
                         || echo "  At the end:      Klipper stays off (--no-start)"
}
update_notice() {  # show what changed since the version that was installed
    [ -n "${OLD_VERSION:-}" ] && [ "$OLD_VERSION" != "$VERSION" ] || return 0
    print_header "What changed since $OLD_VERSION"
    awk -v old="## $OLD_VERSION" '$0==old{exit} {print}' "$SCRIPT_DIR/CHANGELOG.md" | sed -n '2,40p'
}

# ============================================================================
# Hardware checks, first start, hardware test
# ============================================================================
CHK_FAIL=0; CHK_WARN=0
chk_ok()   { echo -e "  ${GREEN}[ok]${NC}   $1"; }
chk_fail() { echo -e "  ${RED}[FAIL]${NC} $1"; [ -n "${2:-}" ] && echo -e "         ${DIM}$2${NC}"; CHK_FAIL=$((CHK_FAIL+1)); }
chk_warn() { echo -e "  ${YELLOW}[warn]${NC} $1"; [ -n "${2:-}" ] && echo -e "         ${DIM}$2${NC}"; CHK_WARN=$((CHK_WARN+1)); }

fix_main_uuid() {  # the main board's uuid in wm_zru_mcu.cfg does not match the bus
    local f="$(cfg_dir)/wm_zru_mcu.cfg" have="$1" found="$2" cand=() u c
    local configured; configured="$(cfg_uuids | awk '{print $2}' | sort -u)"
    for u in $found; do echo "$configured" | grep -qx "$u" || cand+=("$u"); done
    if [ ${#cand[@]} -eq 0 ]; then chk_fail "wm_zru_mcu.cfg has uuid $have, which is not on the CAN bus, and the bus has no unknown device" "Check the USB cable, that the main board is powered, and that it runs the Klipper USB-CAN bridge firmware."; return 1; fi
    if [ ${#cand[@]} -gt 1 ]; then
        echo "  Several unknown devices are on the bus: ${cand[*]}"
        [ "${WM_ASSUME_YES:-0}" = 1 ] && { chk_fail "cannot tell which one is the main board" "Run ./installer.sh --first-start and choose one."; return 1; }
        local i=1; for c in "${cand[@]}"; do echo "    $i) $c"; i=$((i+1)); done
        read -r -p "  Which one is the MAIN board (number, empty = none): " c || c=""
        [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#cand[@]} ] || { chk_fail "no main board chosen"; return 1; }
        u="${cand[$((c-1))]}"
    else u="${cand[0]}"; fi
    echo "  The config says the main board is $have; the bus has an unknown device $u."
    if ask_yn "  Change canbus_uuid in wm_zru_mcu.cfg to $u (a copy is saved first)?" y; then
        mkdir -p "$BACKUP_ROOT/uuid-$STAMP"; cp "$f" "$BACKUP_ROOT/uuid-$STAMP/wm_zru_mcu.cfg"
        sed -i -E "s/^([[:space:]]*canbus_uuid[[:space:]]*:)[[:space:]]*[0-9a-fA-F]*/\1 $u/" "$f"
        chk_ok "wm_zru_mcu.cfg now uses canbus_uuid $u (old file: $BACKUP_ROOT/uuid-$STAMP/)"; return 0
    fi
    chk_fail "main board uuid not changed"; return 1
}

hw_checks() {  # $1 = quiet header flag
    CHK_FAIL=0; CHK_WARN=0
    print_header "Checks before starting Klipper"
    local miss; miss="$(modules_present | tr '\n' ' ')"
    [ -z "$miss" ] && chk_ok "WonderMaker's compiled modules are present" || chk_fail "missing WonderMaker modules: $miss" "Run ./installer.sh --doctor to restore them from the repository."
    if [ "$TESTING" != 1 ] && [ -x "$HOME_DIR/klippy-env/bin/python" ]; then
        local m bad=""; for m in "${COMPILED_MODULES[@]}"; do module_imports "$m" || bad="$bad $m"; done
        [ -z "$bad" ] && chk_ok "the modules import with Python 3.9" || chk_fail "modules that do not import:$bad" "They must be the factory files for aarch64 and Python 3.9."
    fi
    local nerr; validate_config >/tmp/.wm_val.$$ 2>&1; nerr=$?; cat /tmp/.wm_val.$$ | sed 's/^/  /'; rm -f /tmp/.wm_val.$$
    [ "$nerr" = 0 ] && chk_ok "printer.cfg and its includes are consistent" || chk_fail "printer.cfg has $nerr problem(s) (listed above)"
    if usb_bridge_present; then chk_ok "main board found on USB (1d50:606f)"; else chk_fail "no main board on USB (1d50:606f)" "Cable: docs/WIRING.md. The printer must be powered."; fi
    if ! can_exists; then chk_fail "no can0 interface" "It appears when the main board is connected. Check the udev rule (./installer.sh --repair)."
    elif can_is_up; then chk_ok "can0 is up"
    else
        print_info "can0 exists but is down: bringing it up at 1 Mbit"
        SUDO ip link set can0 up type can bitrate 1000000; SUDO ip link set can0 txqueuelen 1024
        can_is_up && chk_ok "can0 is up now" || chk_fail "can0 would not come up"
    fi
    if [ "$(service_state klipper)" = active ]; then chk_warn "Klipper is already running: the CAN query is skipped (Klipper uses the bus)"
    elif can_exists && can_is_up; then
        local found; found="$(found_uuids)"
        if [ -z "$found" ]; then chk_fail "nothing answers on the CAN bus" "Main board powered? Toolhead hub powered? CAN cable?"
        else
            chk_ok "CAN devices answering: $(echo $found | tr ' ' ',')"
            local mcu="$(cfg_dir)/wm_zru_mcu.cfg" have
            have="$(awk '{print $2}' < <(cfg_uuids | grep "/wm_zru_mcu.cfg "))"
            if [ -z "$have" ]; then chk_warn "wm_zru_mcu.cfg has no canbus_uuid"
            elif echo "$found" | grep -qx "$have"; then chk_ok "main board uuid $have matches the config"
            else fix_main_uuid "$have" "$found"; fi
            local f u; while read -r f u; do
                case "$f" in */wm_zru_mcu.cfg) continue ;; esac
                echo "$found" | grep -qx "$u" && chk_ok "$(basename "$f"): $u is on the bus" || chk_warn "$(basename "$f"): $u is not on the bus" "Toolhead or hub not powered, or its uuid differs: see WonderMaker's scripts/read_write_can_id.sh."
            done < <(cfg_uuids)
        fi
    fi
    local p; p="$(power_flags)"; [ -z "$p" ] || [ "$p" = 0x0 ] && chk_ok "Pi power: no under-voltage" || chk_warn "Pi power/heat flags: $p" "Use the official power supply."
    [ -n "$(api_get /server/info)" ] && chk_ok "Moonraker answers" || chk_fail "Moonraker does not answer" "journalctl -u moonraker -n 50"
    [ "$(service_state nginx)" = active ] && chk_ok "nginx is running" || chk_fail "nginx is not running" "./installer.sh --repair"
    return $CHK_FAIL
}

start_all_services() {
    print_header "Enabling and starting the services"
    local s
    for s in moonraker nginx; do SUDO systemctl enable "$s"; done
    [ -f /etc/systemd/system/crowsnest.service ] || [ "$TESTING" = 1 ] && [ "$WANT_CROWSNEST" = 1 ] && { SUDO systemctl enable crowsnest; SUDO systemctl restart crowsnest; }
    SUDO systemctl enable klipper; SUDO systemctl restart klipper
    if [ "$TESTING" = 1 ] || [ "$DRY" = 1 ]; then print_success "Klipper enabled and started (test)"; return 0; fi
    local i st=""; for i in $(seq 1 30); do st="$(klippy_state)"; [ "$st" = ready ] && break; sleep 2; done
    case "$st" in
        ready) print_success "Klipper is ready: the printer is connected." ;;
        startup|"") print_warning "Klipper is still starting (state: ${st:-unknown}). Watch: journalctl -u klipper -f" ;;
        *) print_warning "Klipper reports '$st'. Look at Fluidd or: journalctl -u klipper -n 40"; warn_later "Klipper state after start: $st" ;;
    esac
}

do_first_start() {
    guard_not_printing
    print_header "First start"
    echo "The main board must be connected (docs/WIRING.md) and powered."
    if hw_checks; then
        print_success "All checks passed."
        if [ "${1:-ask}" = auto ] || ask_yn "Enable Klipper and the other services and start them now?" y; then start_all_services; fi
    elif [ "${1:-ask}" = auto ]; then
        print_warning "$CHK_FAIL check(s) failed (listed above). The services are enabled anyway, as you asked; Klipper will report the problem until it is fixed."
        warn_later "$CHK_FAIL check(s) failed at the end of the install. Fix them, then run ./installer.sh --first-start or ./installer.sh --doctor."
        start_all_services
    else
        print_error "$CHK_FAIL check(s) failed, so Klipper was NOT started."
        echo "Fix the points above, then run: ./installer.sh --first-start    (./installer.sh --doctor explains and fixes common problems)"
        return 1
    fi
}

do_hw_test() {
    print_header "Hardware test (read-only)"
    hw_checks || true
    print_header "Camera"
    if ls /dev/v4l/by-id/*index0 >/dev/null 2>&1; then
        local d; for d in /dev/v4l/by-id/*index0; do chk_ok "camera device: $d"; done
        if [ "$(service_state crowsnest)" = active ]; then
            local code; code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' 'http://127.0.0.1:8080/?action=snapshot' 2>/dev/null)"
            [ "$code" = 200 ] && chk_ok "crowsnest delivers a picture on port 8080" || chk_warn "crowsnest answered $code on port 8080" "Check the device line in ~/printer_data/config/crowsnest.conf"
        else chk_warn "crowsnest is not running" "sudo systemctl start crowsnest"; fi
    else chk_warn "no USB camera found in /dev/v4l/by-id" "Optional. Plug a camera in and run again."; fi
    print_header "Serial devices"; ls /dev/serial/by-id 2>/dev/null | sed 's/^/  /' || true
    echo; echo "Result: $CHK_FAIL failed, $CHK_WARN warnings. Nothing was changed except bringing can0 up."
}

# ============================================================================
# Backup and restore of your printer settings
# ============================================================================
do_backup() {
    local dir="${ARG1:-$HOME_DIR/wm-backups}" out
    mkdir -p "$dir"; out="$dir/wm-backup-$(model_now)-$STAMP.tgz"
    print_header "Backup of your printer settings"
    why "Your calibration and config live only on this SD card. SD cards fail."
    local items=() i
    for i in printer_data/config printer_data/database printer_data/wm-model TM_T1/factory_settings; do [ -e "$HOME_DIR/$i" ] && items+=("$i"); done
    tar czf "$out" -C "$HOME_DIR" "${items[@]}" 2>/dev/null || die_with_fix "could not write the backup." "free disk space, or choose another folder: ./installer.sh --backup /path"
    chmod 600 "$out"
    print_success "Saved $out ($(du -h "$out" | cut -f1))"
    echo "  Copy it off the Pi (scp or a USB stick). It holds your private settings: do not publish it."
}
do_restore() {
    local f="${ARG1:-}"; [ -f "$f" ] || die_with_fix "backup file not found: '$f'" "./installer.sh --restore /path/wm-backup-....tgz"
    tar tzf "$f" 2>/dev/null | grep -q '^printer_data/config/printer.cfg$' || die_with_fix "this is not a backup made by --backup." "choose the right file."
    guard_not_printing
    print_header "Restore"
    echo "This replaces ~/printer_data/config and the Moonraker database with the ones in the backup."
    echo "A safety copy of the current ones is made first."
    ask_yn "Continue?" n || { echo "Nothing changed."; return 0; }
    ARG1="$HOME_DIR/wm-backups"; do_backup >/dev/null
    local was_k=0; [ "$(service_state klipper)" = active ] && was_k=1
    SUDO systemctl stop klipper; SUDO systemctl stop moonraker
    tar xzf "$f" -C "$HOME_DIR" || die_with_fix "could not unpack the backup." "the safety copy is in ~/wm-backups"
    SUDO systemctl start moonraker; [ "$was_k" = 1 ] && SUDO systemctl start klipper
    print_success "Restored from $f. The previous settings are in ~/wm-backups (newest file)."
}

# ============================================================================
# Update, repair, undo
# ============================================================================
do_update() {
    print_header "Update"
    load_answers || die_with_fix "no earlier install found ($CONF)." "run ./installer.sh first."
    guard_not_printing
    check_system; preflight; update_notice
    [ -d "$HOME_DIR/klipper" ] || die_with_fix "~/klipper is missing." "run ./installer.sh --doctor"
    echo "Your printer_data (config, calibration) is not touched. Updated: services, nginx, can0 rule, Python packages, panel, add-ons."
    ask_yn "Go ahead?" y || exit 0
    step_packages; step_groups; step_python
    if [ "$TESTING" != 1 ] && [ "$DRY" != 1 ]; then
        "$HOME_DIR/klippy-env/bin/pip" install -q -r "$SCRIPT_DIR/config/klippy-requirements.txt" || warn_later "klippy-env packages did not update."
        "$HOME_DIR/moonraker-env/bin/pip" install -q -r "$SCRIPT_DIR/config/moonraker-requirements.txt" || warn_later "moonraker-env packages did not update."
    fi
    step_services_files; step_nginx; step_can
    if [ "$WANT_PANEL" = 1 ]; then
        local sha=""; panel_get && sha="$(sha256sum "$PANEL_ZIP" | cut -d' ' -f1)"
        if [ -n "$sha" ] && [ "$sha" != "${OLD_PANEL_SHA:-}" ]; then step_panel; else print_success "Fluidd panel is already the latest"; fi
    fi
    if [ "$WANT_SCREEN" = 1 ]; then
        if [ "$(addon_pin klipperscreen | cut -d'|' -f2)" != "${OLD_KS_PIN:-}" ] || [ ! -d "$KS_DIR" ]; then step_screen; else copy_zr_panel; print_success "ZR Tools screen files refreshed"; fi
    fi
    if [ "$WANT_SCREEN" = macros ]; then step_macros; fi
    if [ "$WANT_NETMGR" = 1 ]; then step_netmgr; fi
    if [ "$WANT_TIMELAPSE" = 1 ]; then step_timelapse; fi
    if [ "$WANT_SHELLCMD" = 1 ]; then step_shellcmd; fi
    step_remote_update
    if [ "$WANT_CROWSNEST" = 1 ] && { [ "$(addon_pin crowsnest | cut -d'|' -f2)" != "${OLD_CN_PIN:-}" ] || [ ! -d "$HOME_DIR/crowsnest" ]; }; then step_crowsnest; fi
    save_answers
    SUDO systemctl restart moonraker; SUDO systemctl restart nginx
    [ "$(service_state klipper)" = active ] && print_info "Klipper keeps running. Restart it from Fluidd when you are ready (config reload)."
    self_test
    print_success "Update finished (installer $VERSION)."
}
do_check_updates() {   # read-only: compares this copy of the repository with GitHub
    print_header "Check for updates (read-only, changes nothing)"
    command -v git >/dev/null 2>&1 || die_with_fix "git is not installed." "sudo apt-get install git"
    [ -d "$REPO_DIR/.git" ] || die_with_fix "this folder is not a git clone, so it cannot be compared with GitHub." "download the new version again, or clone it: git clone https://github.com/ducati1198/wm-ultra-rpi"
    local g=(git -C "$REPO_DIR") up
    if [ -n "${WM_TEST_NO_FETCH:-}" ]; then :; else
        timeout 60 "${g[@]}" fetch --quiet 2>/dev/null || die_with_fix "could not reach GitHub." "connect the Pi to the internet and try again."
    fi
    up="$("${g[@]}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"
    [ -n "$up" ] || up="origin/main"
    "${g[@]}" rev-parse --verify -q "$up" >/dev/null || die_with_fix "no remote branch '$up' to compare with." "git -C $REPO_DIR remote -v"
    local behind newv
    behind="$("${g[@]}" rev-list --count "HEAD..$up" 2>/dev/null)"
    newv="$("${g[@]}" show "$up:VERSION" 2>/dev/null | head -1)"
    echo "  Your copy:   installer $VERSION"
    [ -n "$newv" ] && echo "  On GitHub:   installer $newv"
    if [ "${behind:-0}" = 0 ]; then print_success "You have the latest version."; return 0; fi
    print_info "$behind new change(s) on GitHub:"
    "${g[@]}" --no-pager log --no-color --format='    %h  %s' -n 15 "HEAD..$up"
    [ "$behind" -gt 15 ] && echo "    ... and $((behind - 15)) more"
    if [ -n "$("${g[@]}" status --porcelain 2>/dev/null)" ]; then print_warning "You have local changes in $REPO_DIR; git pull may refuse until you save or discard them."; fi
    echo "  To update:   cd $REPO_DIR && git pull && ./installer.sh --update"
    return 0
}
do_repair() {
    print_header "Repair"
    why "Restores groups, service files, nginx and the can0 rule. Your data and the enabled/disabled state of Klipper are not touched."
    guard_not_printing
    load_answers || true
    step_groups; step_services_files; step_polkit; step_nginx; step_can
    [ "$WANT_SCREEN" = 1 ] && [ -d "$KS_DIR" ] && copy_zr_panel
    SUDO systemctl restart moonraker
    self_test; print_success "Repaired."
}
do_undo() {
    print_header "Undo"
    local dir="${ARG1:-$(ls -d "$BACKUP_ROOT"/old-* 2>/dev/null | sort | tail -1)}"
    [ -n "$dir" ] && [ -d "$dir" ] || die_with_fix "no saved folders found in $BACKUP_ROOT." "nothing to undo."
    local stampname; stampname="$(basename "$dir" | sed 's/^old-//')"
    echo "This puts back the folders that the installer moved aside on $stampname:"; ls "$dir" | sed 's/^/  ~\//'
    echo "The folders that are there now are moved to $BACKUP_ROOT/undone-$STAMP/."
    echo "System services and nginx files are not changed (use --uninstall for those)."
    guard_not_printing
    ask_yn "Continue?" n || { echo "Nothing changed."; return 0; }
    SUDO systemctl stop klipper; SUDO systemctl stop moonraker
    local d; mkdir -p "$BACKUP_ROOT/undone-$STAMP"
    for d in $(ls "$dir"); do
        [ -e "$HOME_DIR/$d" ] && mv "$HOME_DIR/$d" "$BACKUP_ROOT/undone-$STAMP/$d"
        mv "$dir/$d" "$HOME_DIR/$d"; print_success "~/$d restored"
    done
    local fl="$BACKUP_ROOT/fluidd-$stampname"
    if [ -d "$fl" ] && [ ! -e "$dir/fluidd" ] && ask_yn "Also put back the Fluidd that was replaced?" y; then
        [ -e "$HOME_DIR/fluidd" ] && mv "$HOME_DIR/fluidd" "$BACKUP_ROOT/undone-$STAMP/fluidd"
        mkdir -p "$HOME_DIR/fluidd"; cp -a "$fl/." "$HOME_DIR/fluidd/"; print_success "~/fluidd restored"
    fi
    SUDO systemctl start moonraker
    print_success "Done. To go forward again, the folders from this undo are in $BACKUP_ROOT/undone-$STAMP/."
}

self_test() {
    print_header "Self-test"
    [ -n "$(api_get /server/info)" ] && print_success "Moonraker answers on port 7125" || print_warning "Moonraker did not answer"
    if [ "$TESTING" = 1 ]; then print_success "web page answers (test)"; else
        local c; c="$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1/ 2>/dev/null)"
        [ "$c" = 200 ] && print_success "Fluidd answers on port 80" || print_warning "Fluidd/nginx answered '$c' on port 80"
        c="$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1/server/info 2>/dev/null)"
        [ "$c" = 200 ] && print_success "nginx forwards the API to Moonraker" || print_warning "the API through nginx answered '$c'"
    fi
    local k; k="$(klippy_state)"; print_info "Klipper state: ${k:-not running}"
    polkit_check_and_fix
}

# ============================================================================
# Doctor and support bundle
# ============================================================================
offer_fix() {  # description, command...
    local d="$1"; shift
    if ask_yn "  Fix: $d?" y; then "$@" && print_success "done" || print_warning "the fix did not work"; fi
}
doc_ok()  { echo -e "  ${GREEN}[ok]${NC}      $1"; }
doc_bad() { echo -e "  ${RED}[problem]${NC} $1"; echo -e "            ${DIM}$2${NC}"; DOC_PROBLEMS=$((DOC_PROBLEMS+1)); }
do_doctor() {
    DOC_PROBLEMS=0
    load_answers || true
    print_header "Doctor (asks before changing anything)"
    [ "$(id -un)" = "$WM_USER" ] || [ "$TESTING" = 1 ] && doc_ok "user is $WM_USER" || doc_bad "user is $(id -un), not $WM_USER" "WonderMaker's paths are fixed to /home/$WM_USER. Log in as $WM_USER."
    local d dl="klipper moonraker printer_data fluidd klippy-env moonraker-env"; [ "$TESTING" = 1 ] && dl="klipper moonraker printer_data fluidd"
    for d in $dl; do
        [ -d "$HOME_DIR/$d" ] && doc_ok "~/$d" || doc_bad "~/$d is missing" "Run ./installer.sh (or ./installer.sh --undo if a run was interrupted)."
    done
    if [ "$TESTING" != 1 ] && [ -x "$HOME_DIR/klippy-env/bin/python" ]; then
        "$HOME_DIR/klippy-env/bin/python" -c 'import can,serial,cffi,greenlet,jinja2,numpy' 2>/dev/null && doc_ok "Klipper's Python packages import" \
            || { doc_bad "Klipper's Python packages do not import" "The environment is damaged or incomplete."; offer_fix "rebuild ~/klippy-env" bash -c "rm -rf '$HOME_DIR/klippy-env'; true"; step_python; step_venvs; }
    fi
    if [ "$WANT_SHELLCMD" = 1 ]; then
        cmp -s "$SCRIPT_DIR/config/gcode_shell_command.py" "$HOME_DIR/klipper/klippy/extras/gcode_shell_command.py" 2>/dev/null && doc_ok "gcode_shell_command extension is installed" \
            || { doc_bad "gcode_shell_command extension is missing or different" "RUN_SHELL_COMMAND will not work (Klipper stops at start if printer.cfg has a [gcode_shell_command] section)."; offer_fix "copy it again" step_shellcmd; }
    fi
    local rp rn rv rdir rsvc
    for rp in "Obico:WANT_OBICO:moonraker-obico:moonraker-obico" "OctoApp:WANT_OCTOAPP:octoapp:octoapp" "OctoEverywhere:WANT_OCTOEVERYWHERE:octoeverywhere:octoeverywhere"; do
        IFS=: read -r rn rv rdir rsvc <<< "$rp"
        [ "${!rv}" = 1 ] || continue
        if [ ! -d "$HOME_DIR/$rdir" ]; then doc_bad "$rn is missing (~/$rdir)" "Run ./installer.sh --update --$(echo "$rn" | tr 'A-Z' 'a-z') on."
        elif [ "$TESTING" = 1 ]; then doc_ok "$rn is downloaded"
        elif [ "$(service_state "$rsvc")" = active ]; then doc_ok "$rn is running"
        else doc_bad "$rn is downloaded but its service is not running" "Finish its installer: cd ~/$rdir && ./install.sh   (Obico: ~/moonraker-obico/scripts/link.sh -c ~/printer_data/config/moonraker-obico.cfg)"; fi
    done
    local miss; miss="$(modules_present | tr '\n' ' ')"
    if [ -z "$miss" ]; then doc_ok "WonderMaker's compiled modules are present"
    else doc_bad "missing modules: $miss" "Klipper cannot run the heaters, load cells or calibration without them."; offer_fix "copy the factory modules from this repository (checksums are verified)" restore_modules_from_repo; fi
    local nerr=0; validate_config > /tmp/.wm_d.$$ 2>&1 || nerr=$?; sed 's/^/        /' /tmp/.wm_d.$$; rm -f /tmp/.wm_d.$$
    if [ "$nerr" = 0 ]; then doc_ok "printer.cfg and includes"; else
        doc_bad "printer.cfg has $nerr problem(s) (listed above)" "A missing include stops Klipper at start. A wrong zru-s.cfg line means the chamber/air-filter settings do not match your model."
        grep -q 'zru-s.cfg' < <(validate_config 2>&1) && offer_fix "set printer.cfg for the $(model_now)" step_model
    fi
    local s; for s in moonraker nginx; do
        [ "$(service_state $s)" = active ] && doc_ok "$s is running" || { doc_bad "$s is not running" "journalctl -u $s -n 30"; offer_fix "restart $s" bash -c "sudo systemctl restart $s"; }
        [ "$(service_enabled $s)" = enabled ] && doc_ok "$s starts at boot" || { doc_bad "$s will not start at boot" "The Pi would come up without the web page."; offer_fix "enable $s" bash -c "sudo systemctl enable $s"; }
    done
    if [ "$TESTING" != 1 ]; then sudo nginx -t >/dev/null 2>&1 && doc_ok "nginx configuration is valid" || { doc_bad "nginx configuration is invalid" "sudo nginx -t shows why."; offer_fix "reinstall the nginx files" step_nginx; }; fi
    [ -f /etc/udev/rules.d/99-wm-can0.rules ] || [ "$TESTING" = 1 ] && doc_ok "can0 rule installed" || { doc_bad "can0 rule missing" "can0 would not come up by itself."; offer_fix "install it" step_can; }
    if usb_bridge_present; then doc_ok "main board on USB"; else doc_bad "no main board (1d50:606f) on USB" "Cable (docs/WIRING.md), printer power, D+/D- not swapped."; fi
    if can_exists; then
        can_is_up && doc_ok "can0 is up" || { doc_bad "can0 is down" "Klipper cannot reach the toolheads."; offer_fix "bring can0 up (1 Mbit)" bash -c "sudo ip link set can0 up type can bitrate 1000000"; }
    else doc_bad "no can0 interface" "It appears when the main board is connected."; fi
    if [ -n "$(polkit_warnings)" ] || ! packagekit_present; then doc_bad "Moonraker reports 'PolKit warnings detected' (PackageKit is missing)" "Fluidd's update manager cannot check or install updates."; offer_fix "install PackageKit and restart Moonraker" polkit_fix; else doc_ok "no PolKit warnings from Moonraker"; fi
    if [ "$TESTING" != 1 ]; then
        polkit_rule_present && doc_ok "Moonraker's PolicyKit rule is installed" || { doc_bad "Moonraker's PolicyKit rule is missing" "Fluidd shows a PolKit warning and cannot restart services."; offer_fix "install it" step_polkit; }
        local hc; hc="$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1/ 2>/dev/null)"
        [ "$hc" = 200 ] && doc_ok "Fluidd page opens" || { doc_bad "Fluidd page answers HTTP ${hc:-none}" "403 means nginx cannot read your home folder (Debian 12 makes it private)."; offer_fix "let nginx pass through the home folder" bash -c "chmod o+x '$HOME_DIR' && sudo systemctl reload nginx"; }
    fi
    [ -n "$(api_get /server/info)" ] && doc_ok "Moonraker API answers" || doc_bad "Moonraker API does not answer" "Last log lines: $(tail -n 3 "$HOME_DIR/printer_data/logs/moonraker.log" 2>/dev/null | tr '\n' ' ')"
    local free; free=$(df -Pm "$HOME_DIR" | awk 'NR==2{print $4}'); [ "${free:-0}" -gt 800 ] && doc_ok "disk space (${free} MB free)" || doc_bad "only ${free} MB free" "Old backups: ~/wm-rpi-backup and ~/wm-backups. Gcode files: ~/printer_data/gcodes."
    local p; p="$(power_flags)"; if [ -z "$p" ] || [ "$p" = 0x0 ]; then doc_ok "no power problems reported"; else doc_bad "the Pi reported power/heat flags $p" "Use the official 5 V / 3 A supply and a short cable."; fi
    if [ "$WANT_SCREEN" = 1 ]; then
        [ -d "$KS_DIR" ] && doc_ok "KlipperScreen is installed" || doc_bad "KlipperScreen is missing" "Run ./installer.sh --update."
        if [ -d "$KS_DIR" ]; then
            [ -f "$KS_DIR/panels/zr_tools.py" ] && [ -f "$KS_DIR/panels/zr_views.py" ] && [ -f "$KS_DIR/panels/zr_logic.py" ] && doc_ok "ZR Tools panel files" \
                || { doc_bad "ZR Tools panel files are missing in KlipperScreen" "A KlipperScreen update may have removed them."; offer_fix "copy them again" copy_zr_panel; }
        fi
        [ "$(service_enabled KlipperScreen)" = enabled ] && doc_ok "KlipperScreen starts at boot" || { doc_bad "KlipperScreen will not start at boot" "The screen stays black after a restart."; offer_fix "enable KlipperScreen" bash -c "sudo systemctl enable KlipperScreen"; }
        local r t; read -r r t < <(detect_screen); [ -n "$r" ] && doc_ok "screen found ($r)" || doc_bad "no screen detected" "Check the video cable and power."
        [ "$t" = touch ] && doc_ok "touch device found" || doc_bad "no touch device detected" "Check the USB touch cable."
    fi
    if [ "$WANT_SCREEN" = macros ]; then
        local c="$HOME_DIR/printer_data/config"
        { [ -f "$c/zr_tools.cfg" ] && grep -q '^\[include zr_tools.cfg\]' "$c/printer.cfg" 2>/dev/null; } && doc_ok "ZR Tools macros are in printer.cfg" || doc_bad "ZR Tools macros are missing from printer.cfg" "Run ./installer.sh --update."
    fi
    ntp_ok && doc_ok "clock is synchronized" || doc_bad "clock is not synchronized" "HTTPS downloads and file times go wrong. Check the network."
    echo; [ "$DOC_PROBLEMS" = 0 ] && print_success "No problems found." || { print_warning "$DOC_PROBLEMS problem(s) found. For a report to share: ./installer.sh --support-bundle"; return 1; }
}

scrub() {  # remove secrets and private addresses from a stream
    sed -E 's/((password|passwd|token|api_?key|secret|ssid|psk|key)[[:space:]]*[:=][[:space:]]*).*/\1<removed>/I;
            s/\b(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)\b/<private-ip>/g;
            s/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/<mac>/g'
}
do_support_bundle() {
    print_header "Support bundle"
    local w; w="$(mktemp -d)"; local out="$HOME_DIR/wm-support-$STAMP.tgz" b="$w/wm-support"; mkdir -p "$b"
    {
        echo "wm-ultra-rpi installer $VERSION   model: $(model_now)   date: $(date -u +%FT%TZ)"
        uname -a; [ -r /etc/os-release ] && grep PRETTY /etc/os-release
        echo "python3: $(python3 --version 2>&1)"; [ -x "$HOME_DIR/klippy-env/bin/python" ] && echo "klippy-env: $("$HOME_DIR/klippy-env/bin/python" --version 2>&1)"
        echo "power flags: $(power_flags)"; df -h "$HOME_DIR" | tail -1; free -m | sed -n 2p
        echo "--- services"; local s; for s in klipper moonraker nginx crowsnest; do printf '%-10s active=%s enabled=%s\n' $s "$(service_state $s)" "$(service_enabled $s)"; done
        echo "--- usb"; lsusb 2>/dev/null; echo "--- can0"; ip -details link show can0 2>&1 | head -8
        echo "--- missing modules: $(modules_present | tr '\n' ' ')"
        echo "--- config check"; validate_config 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
        echo "--- canbus uuids in config"; cfg_uuids | sed "s#$HOME_DIR#~#"
    } 2>&1 | scrub > "$b/system.txt"
    cp "$CONF" "$b/install.conf" 2>/dev/null; cp "$STATE" "$b/installed.manifest" 2>/dev/null
    local f; mkdir -p "$b/config"
    for f in "$(cfg_dir)"/*.cfg "$(cfg_dir)"/moonraker.conf "$(cfg_dir)"/crowsnest.conf; do [ -f "$f" ] && scrub < "$f" > "$b/config/$(basename "$f")"; done
    mkdir -p "$b/logs"
    local lf; lf="$(ls -1t "$LOG_DIR"/installer-*.log 2>/dev/null | head -n1)"; [ -n "$lf" ] && scrub < "$lf" > "$b/logs/last-installer-run.log"
    for f in klippy moonraker crowsnest; do [ -f "$HOME_DIR/printer_data/logs/$f.log" ] && tail -n 400 "$HOME_DIR/printer_data/logs/$f.log" | scrub > "$b/logs/$f.log"; done
    for s in klipper moonraker nginx crowsnest; do (journalctl -u $s -n 120 --no-pager 2>/dev/null || sudo -n journalctl -u $s -n 120 --no-pager 2>/dev/null) | scrub > "$b/logs/journal-$s.txt"; done
    cat > "$b/README.txt" <<E
This bundle was made by ./installer.sh --support-bundle. Passwords, tokens, keys, Wi-Fi names, private IP and MAC addresses
were removed from the text files. Gcode files, calibration databases and backups are NOT included.
Please look through it before sharing.
E
    tar czf "$out" -C "$w" wm-support; rm -rf "$w"; chmod 600 "$out"
    print_success "Saved $out ($(du -h "$out" | cut -f1)). Look through it, then send it along with your question."
}

# ============================================================================
# Modes
# ============================================================================
do_check() {
    print_header "Check (changes nothing)"
    local bad=0
    local dirs="klipper moonraker printer_data fluidd klippy-env moonraker-env"; [ "$TESTING" = 1 ] && dirs="klipper moonraker printer_data fluidd"
    for d in $dirs; do
        [ -d "$HOME_DIR/$d" ] && print_success "~/$d" || { print_error "~/$d missing"; bad=1; }
    done
    [ -f "$HOME_DIR/printer_data/config/printer.cfg" ] && print_success "printer.cfg" || { print_error "printer.cfg missing"; bad=1; }
    [ "$TESTING" = 1 ] || {
        print_info "moonraker: $(service_state moonraker)   nginx: $(service_state nginx)   klipper: $(service_state klipper) (enabled: $(systemctl is-enabled klipper 2>/dev/null))"
        [ "$(service_state moonraker)" = active ] || { print_error "Moonraker is not running"; bad=1; }
        [ -x "$SCRIPT_DIR/scripts/board_check.sh" ] && bash "$SCRIPT_DIR/scripts/board_check.sh"
    }
    if [ -n "$(polkit_warnings)" ] || ! packagekit_present; then print_warning "Fluidd shows 'PolKit warnings detected' (PackageKit missing). Fix: ./installer.sh --repair"; fi
    [ "$bad" = 0 ] && print_success "All good." || { print_error "Problems found."; exit 1; }
}

do_start_klipper() {
    print_header "Start Klipper again"
    why "Undoes 'Stop Klipper': Klipper starts now and at every boot. No hardware checks (First start does those)."
    guard_not_printing
    usb_bridge_present || print_warning "No main board (1d50:606f) on USB. Klipper starts anyway and reports an error until the board is connected."
    SUDO systemctl enable klipper; SUDO systemctl restart klipper
    if [ "$TESTING" = 1 ] || [ "$DRY" = 1 ]; then print_success "Klipper enabled and started (test)"; return 0; fi
    local i st=""; for i in $(seq 1 30); do st="$(klippy_state)"; [ "$st" = ready ] && break; sleep 2; done
    case "$st" in
        ready) print_success "Klipper is enabled at boot and ready." ;;
        startup|"") print_warning "Klipper is enabled and still starting (state: ${st:-unknown}). Watch: journalctl -u klipper -f" ;;
        *) print_warning "Klipper is enabled but reports '$st'. Look at Fluidd or: journalctl -u klipper -n 40" ;;
    esac
}
do_disable() { SUDO systemctl disable klipper; SUDO systemctl stop klipper; print_success "Klipper stopped and disabled."; }

do_uninstall() {
    print_header "Uninstall"
    [ -f "$STATE" ] || die_with_fix "no install record at $STATE." "nothing to remove."
    echo "This removes the services, nginx files and can0 rule the installer added. Your files in ~ are left in place."
    ask_yn "Continue?" n || exit 0
    uninstall_system_files
}
uninstall_system_files() {
    SUDO systemctl stop klipper; SUDO systemctl stop moonraker
    SUDO systemctl disable klipper; SUDO systemctl disable moonraker
    local k v
    while read -r k v; do
        case "$k" in
            FILE|LINK) SUDO rm -f "$v" ;;
        esac
    done < "$STATE"
    local rd; for rd in moonraker-obico octoapp octoeverywhere; do
        [ -d "$HOME_DIR/$rd" ] && print_warning "~/$rd is a remote-access add-on linked to your account and is NOT removed. Remove it with its own uninstaller: $([ "$rd" = moonraker-obico ] && echo "see Uninstall in ~/moonraker-obico/README.md" || echo "cd ~/$rd && ./uninstall.sh")"
    done
    SUDO systemctl daemon-reload; SUDO udevadm control --reload-rules
    SUDO nginx -t >/dev/null 2>&1 && SUDO systemctl reload nginx
    mv "$STATE" "$STATE.removed-$STAMP"
    print_success "Removed. Folders in your home (klipper, moonraker, printer_data, fluidd, environments) are untouched; delete them yourself if you want."
}


# ============================================================================
# Remove an add-on (asks first; uses the makers' own uninstallers)
# ============================================================================
cleanup_paths() {   # group -> the paths that exist (one per line)
    local cfgd d; cfgd="$(cfg_dir)"
    case "$1" in
        backups) [ -d "$HOME_DIR/wm-backups" ] && echo "$HOME_DIR/wm-backups" ;;
        bundles) ls -1d "$HOME_DIR"/wm-support-*.tgz 2>/dev/null ;;
        logs)    [ -d "$LOG_DIR" ] && echo "$LOG_DIR" ;;
        stage)   [ -d "$HOME_DIR/wm-stage" ] && echo "$HOME_DIR/wm-stage" ;;
        moved)   ls -1d "$BACKUP_ROOT"/old-* 2>/dev/null ;;
        fluiddcopies) ls -1d "$BACKUP_ROOT"/fluidd-* 2>/dev/null ;;
        cfgcopies) ls -1d "$cfgd"/*.wm-* 2>/dev/null ;;
        downloads)
            [ -d "$BACKUP_ROOT/.panel-dl" ] && echo "$BACKUP_ROOT/.panel-dl"
            for d in moonraker-obico octoapp octoeverywhere; do [ -d "$HOME_DIR/$d" ] && [ ! -f "/etc/systemd/system/$d.service" ] && echo "$HOME_DIR/$d"; done ;;
        records) [ -d "$BACKUP_ROOT" ] && echo "$BACKUP_ROOT" ;;
        repo)    [ -f "$REPO_DIR/installer.sh" ] && [ -f "$REPO_DIR/VERSION" ] && [ "$REPO_DIR" != "$HOME_DIR" ] && [ "$REPO_DIR" != / ] && echo "$REPO_DIR" ;;
    esac
}
do_cleanup() {   # a page of installer-made files you can delete; your printer data is never in it
    local groups=(backups bundles logs stage moved fluiddcopies cfgcopies downloads records repo) g n paths sz cnt word
    declare -A label=([backups]="Settings backups (~/wm-backups)" [bundles]="Support bundles (~/wm-support-*.tgz)" [logs]="Installer logs (~/wm-install-logs)" [stage]="Software copied from the old board (~/wm-stage)" [moved]="Folders moved aside by installs" [fluiddcopies]="Old Fluidd copies" [cfgcopies]="Config safety copies (*.wm-*)" [downloads]="Add-on download copies" [records]="Installer records (~/wm-rpi-backup)" [repo]="The installer folder itself")
    declare -A help=([backups]="backup .tgz files and safety copies made before restores" [bundles]="logs bundles made for help requests" [logs]="the log of each run that changed something" [stage]="the copy of klipper, moonraker and data an install made from the old board; pull it again if you need it" [moved]="old klipper, moonraker, printer_data folders in ~/wm-rpi-backup/old-*" [fluiddcopies]="Fluidd saved before each panel update" [cfgcopies]="files like printer.cfg.wm-model-bak in your config folder" [downloads]="panel download cache, add-on sources that are not installed" [records]="saved answers and install record; after this the installer no longer knows what is installed" [repo]="$REPO_DIR (this script)")
    while true; do
        echo; echo "  Clean up installer files"; echo "  Files made by or for this installer. Your printer data (~/printer_data) is never in this list."
        n=0; for g in "${groups[@]}"; do
            n=$((n+1)); paths="$(cleanup_paths "$g")"
            if [ -z "$paths" ]; then menu_item "$n" "${label[$g]}" "[nothing to delete]"
            else cnt="$(echo "$paths" | wc -l)"; sz="$(echo "$paths" | tr '\n' '\0' | du -shc --files0-from=- 2>/dev/null | tail -1 | cut -f1)"; menu_item "$n" "${label[$g]}" "[${sz:-?}, $cnt item(s)] ${help[$g]}"; fi
        done
        menu_item 0 "Back" ""
        menu_read "Choose what to delete:" || return 0
        [ "$REPLY_MENU" = 0 ] || [ -z "$REPLY_MENU" ] && return 0
        if ! [[ "$REPLY_MENU" =~ ^[0-9]+$ ]] || [ "$REPLY_MENU" -lt 1 ] || [ "$REPLY_MENU" -gt "${#groups[@]}" ]; then echo "  Choose a number from the list."; continue; fi
        g="${groups[$((REPLY_MENU-1))]}"; paths="$(cleanup_paths "$g")"
        [ -z "$paths" ] && { echo "  Nothing to delete there."; continue; }
        echo "  This deletes:"; echo "$paths" | sed 's/^/    /'
        case "$g" in
            backups|stage|moved|fluiddcopies|records|repo)
                echo "  These may be the only copy of your settings or of older versions. Copy anything you want to keep off the Pi first."
                read -r -p "  Type DELETE (capital letters) to confirm, anything else cancels: " word || word=""
                [ "$word" = DELETE ] || { echo "  Nothing changed."; continue; } ;;
            *) ask_yn "Delete these?" n || { echo "  Nothing changed."; continue; } ;;
        esac
        echo "$paths" | while IFS= read -r p; do rm_path "$p"; done
        case "$g" in
            records) print_warning "The installer no longer knows what is installed: Update and the menu will say so. To use it again run ./installer.sh --install." ;;
            repo) cd "$HOME_DIR" || true; print_success "The installer folder was deleted. Run it again by downloading the repository."; exit 0 ;;
        esac
        print_success "Deleted: ${label[$g]}"
    done
}
do_remove_addon() {
    local name="$ARG1" dir env svc cfgd; cfgd="$(cfg_dir)"
    load_answers || true
    guard_not_printing
    case "$name" in
        shell-command)
            local ef="$HOME_DIR/klipper/klippy/extras/gcode_shell_command.py" users
            [ -f "$ef" ] || { print_info "The shell command extension is not installed."; return 0; }
            users="$(grep -rl '^\[gcode_shell_command' "$cfgd" 2>/dev/null | tr '\n' ' ')"
            if [ -n "$users" ] && [ "$FORCE" != 1 ]; then die_with_fix "printer.cfg still has [gcode_shell_command ...] sections (in: $users). Klipper would not start without the extension." "remove those sections first, then try again."; fi
            ask_yn "Remove the Klipper gcode shell command extension?" n || { echo "Nothing changed."; return 0; }
            rm -f "$ef"; WANT_SHELLCMD=0; save_answers
            print_success "Removed. Restart Klipper from Fluidd when you are ready." ;;
        obico|octoapp|octoeverywhere)
            case "$name" in obico) dir=moonraker-obico; env=moonraker-obico-env; svc=moonraker-obico ;; octoapp) dir=octoapp; env=octoapp-env; svc=octoapp ;; *) dir=octoeverywhere; env=octoeverywhere-env; svc=octoeverywhere ;; esac
            [ -d "$HOME_DIR/$dir" ] || [ -d "$HOME_DIR/$env" ] || { print_info "$name is not installed."; return 0; }
            echo "  This removes $name from this Pi (its service, ~/$dir and ~/$env). Your account on their website stays; remove the printer there yourself."
            ask_yn "Remove $name?" n || { echo "Nothing changed."; return 0; }
            if [ "$TESTING" = 1 ]; then echo "[test] remove $name" >> "$HOME_DIR/.sudo.log"; [ "$name" != obico ] && run_official_uninstall "$name" "$HOME_DIR/$dir" bash ./uninstall.sh
            else
                # OctoApp and OctoEverywhere ship ./uninstall.sh. Obico's own uninstall (./install.sh -u) only lists the steps below, which are done here exactly as it lists them.
                if [ "$name" != obico ] && [ -f "$HOME_DIR/$dir/uninstall.sh" ]; then run_official_uninstall "$name" "$HOME_DIR/$dir" official_with_answers bash ./uninstall.sh; fi
                SUDO systemctl stop "$svc" 2>/dev/null; SUDO systemctl disable "$svc" 2>/dev/null
                SUDO rm -f "/etc/systemd/system/$svc.service"; SUDO systemctl daemon-reload; SUDO systemctl reset-failed 2>/dev/null
                if [ "$name" = obico ]; then   # Klipper would not start with the include pointing at a deleted file
                    rm -f "$cfgd/moonraker_obico_macros.cfg"
                    if grep -q 'include moonraker_obico_macros.cfg' "$cfgd/printer.cfg" 2>/dev/null; then
                        cp "$cfgd/printer.cfg" "$cfgd/printer.cfg.wm-before-obico-removal-$STAMP"; sed -i '/include moonraker_obico_macros.cfg/d' "$cfgd/printer.cfg"
                        print_info "Removed the Obico include from printer.cfg (copy: printer.cfg.wm-before-obico-removal-$STAMP)"
                    fi
                    if grep -q 'include moonraker-obico-update.cfg' "$cfgd/moonraker.conf" 2>/dev/null; then sed -i '/include moonraker-obico-update.cfg/d' "$cfgd/moonraker.conf"; rm -f "$cfgd/moonraker-obico-update.cfg"; fi
                fi
            fi
            if [ "$name" = obico ] && [ -f "$cfgd/moonraker-obico.cfg" ]; then mv "$cfgd/moonraker-obico.cfg" "$cfgd/moonraker-obico.cfg.wm-removed-$STAMP"; print_info "Obico's settings file was set aside as moonraker-obico.cfg.wm-removed-$STAMP, so a new install asks for the server again."; fi
            rm_path "$HOME_DIR/$dir" "$HOME_DIR/$env"
            [ "$name" != obico ] && { rm_path "$HOME_DIR/$name-installer.log"; local lf; for lf in "$cfgd/$name".* "$cfgd/$name"-*; do [ -e "$lf" ] && case "$lf" in *.wm-*) ;; *) rm_path "$lf" ;; esac; done; }
            case "$name" in obico) WANT_OBICO=0 ;; octoapp) WANT_OCTOAPP=0 ;; *) WANT_OCTOEVERYWHERE=0 ;; esac; save_answers
            print_success "$name removed."
            [ "$name" != obico ] && moonraker_drop_update_section "$name"
            print_info "Restart Moonraker$([ "$name" = obico ] && echo " and Klipper") from Fluidd when you are ready." ;;
        screen) do_screen_remove ;;
        network-manager)
            if [ ! -f "$NETMGR_STATE" ]; then print_info "This installer did not switch the Pi to NetworkManager (it was already in use, or never installed), so there is nothing to switch back. Not touching your network setup."; return 0; fi
            echo "  This switches the Pi back to dhcpcd: dhcpcd is enabled and NetworkManager is disabled. It takes effect at the next reboot; nothing restarts now. The network-manager package stays installed. KlipperScreen's Network panel stops working."
            ask_yn "Switch back to dhcpcd?" n || { echo "Nothing changed."; return 0; }
            SUDO systemctl enable dhcpcd; SUDO systemctl disable NetworkManager
            rm -f "$NETMGR_STATE"; WANT_NETMGR=0; save_answers
            print_success "Done. Reboot when you are ready (sudo reboot). Install NetworkManager again any time: ./installer.sh --update --network-manager on" ;;
        webcam)
            [ -d "$HOME_DIR/crowsnest" ] || [ -f /etc/systemd/system/crowsnest.service ] || { print_info "The webcam service is not installed."; return 0; }
            echo "  This removes the webcam service (crowsnest) and ~/crowsnest. Your camera settings file crowsnest.conf stays in your config folder."
            ask_yn "Remove the webcam service?" n || { echo "Nothing changed."; return 0; }
            run_official_uninstall crowsnest "$HOME_DIR/crowsnest" official_with_answers make uninstall
            SUDO systemctl stop crowsnest; SUDO systemctl disable crowsnest
            SUDO rm -f /etc/systemd/system/crowsnest.service /usr/local/bin/crowsnest /etc/logrotate.d/crowsnest; SUDO systemctl daemon-reload
            rm_path "$HOME_DIR/crowsnest" "$HOME_DIR/crowsnest-env"; moonraker_drop_update_section crowsnest; WANT_CROWSNEST=0; save_answers
            print_success "Webcam service removed. crowsnest asks for a reboot after its uninstall: sudo reboot when you are ready." ;;
        timelapse)
            [ -d "$HOME_DIR/moonraker-timelapse" ] || { print_info "Timelapse is not installed."; return 0; }
            echo "  This removes the timelapse component and ~/moonraker-timelapse. ffmpeg, timelapse.cfg and finished videos stay. The [timelapse] section in moonraker.conf is commented out (a copy is kept)."
            ask_yn "Remove timelapse?" n || { echo "Nothing changed."; return 0; }
            local comp="$HOME_DIR/moonraker/moonraker/components/timelapse.py" mc="$cfgd/moonraker.conf"
            [ -L "$comp" ] && rm -f "$comp"
            if grep -q '^\[timelapse\]' "$mc" 2>/dev/null; then
                cp "$mc" "$mc.wm-before-timelapse-removal-$STAMP"
                python3 - "$mc" <<'PY'
import sys
p = sys.argv[1]; out = []; inside = False
for line in open(p).read().split("\n"):
    if line.startswith("["): inside = line.startswith("[timelapse]")
    out.append("#" + line if inside and line.strip() and not line.startswith("#") else line)
open(p, "w").write("\n".join(out))
PY
                print_info "Commented out [timelapse] in moonraker.conf (copy: moonraker.conf.wm-before-timelapse-removal-$STAMP)"
            fi
            moonraker_drop_update_section timelapse
            rm_path "$HOME_DIR/moonraker-timelapse"; WANT_TIMELAPSE=0; save_answers
            print_success "Timelapse removed. Restart Moonraker from Fluidd when you are ready." ;;
        fluidd)
            [ -d "$HOME_DIR/fluidd" ] || [ -e /etc/nginx/sites-enabled/fluidd ] || { print_info "The Fluidd web page is not installed."; return 0; }
            echo "  This removes the Fluidd web page (~/fluidd, with the WonderMaker Toolheads panel) and its nginx site. Klipper and Moonraker keep running."
            echo "  You cannot open the printer in a browser until you run ./installer.sh --update (it puts the page back)."
            ask_yn "Remove the Fluidd web page?" n || { echo "Nothing changed."; return 0; }
            SUDO rm -f /etc/nginx/sites-enabled/fluidd /etc/nginx/sites-available/fluidd /etc/nginx/conf.d/common_vars.conf /etc/nginx/conf.d/upstreams.conf
            SUDO nginx -t >/dev/null 2>&1 && SUDO systemctl reload nginx
            rm_path "$HOME_DIR/fluidd"
            print_success "Fluidd web page removed." ;;
        moonraker|klipper)
            local pre; pre="$name"
            [ -d "$HOME_DIR/$pre" ] || [ -f /etc/systemd/system/$pre.service ] || { print_info "$name is not installed."; return 0; }
            if [ "$name" = moonraker ]; then echo "  This removes Moonraker (its service, ~/moonraker and ~/moonraker-env). Fluidd, KlipperScreen and the remote-access add-ons need it. ~/printer_data stays."
            else echo "  This removes Klipper (its service, ~/klipper and ~/klippy-env). The printer will not run without it. ~/printer_data stays."; fi
            ask_yn "Remove $name?" n || { echo "Nothing changed."; return 0; }
            SUDO systemctl stop "$name"; SUDO systemctl disable "$name"
            SUDO rm -f "/etc/systemd/system/$name.service"; SUDO systemctl daemon-reload
            rm_path "$HOME_DIR/$name" "$HOME_DIR/$([ "$name" = klipper ] && echo klippy-env || echo moonraker-env)"
            print_success "$name removed. Put it back with ./installer.sh --update or --install." ;;
        data)
            [ -d "$HOME_DIR/printer_data" ] || [ -d "$HOME_DIR/TM_T1" ] || { print_info "There is no ~/printer_data."; return 0; }
            echo "  This DELETES ~/printer_data and ~/TM_T1 (WonderMaker's factory settings): printer.cfg and all your config, calibration, the Moonraker database (history and settings), gcode files and logs."
            echo "  A backup of your config and database is saved first in ~/wm-backups."
            ask_yn "Delete my printer data?" n || { echo "Nothing changed."; return 0; }
            local word; read -r -p "  Type DELETE (capital letters) to confirm, anything else cancels: " word || word=""
            [ "$word" = DELETE ] || { echo "Nothing changed."; return 0; }
            ARG1="$HOME_DIR/wm-backups"; do_backup >/dev/null
            SUDO systemctl stop klipper; SUDO systemctl stop moonraker
            rm_path "$HOME_DIR/printer_data" "$HOME_DIR/TM_T1"
            print_success "Printer data deleted. The backup is in ~/wm-backups (newest file): copy it off the Pi." ;;
        cleanup) do_cleanup ;;
        system)
            [ -f "$STATE" ] || { print_info "Nothing recorded to remove."; return 0; }
            do_uninstall ;;
        all)
            local word c any=0
            echo "  This is what will be removed (what is installed now):"
            for c in screen webcam timelapse shell-command obico octoapp octoeverywhere fluidd moonraker klipper; do
                [ "$(addon_status "$c")" = "not installed" ] && continue
                echo "    - $c  [$(addon_status "$c")]"; any=1
            done
            [ -f "$STATE" ] && { echo "    - the system files the installer added (services, nginx files, can0 rule)"; any=1; }
            [ "$any" = 0 ] && { echo "    (nothing is installed)"; return 0; }
            echo "  Each add-on's own uninstaller runs first and may ask its own questions."
            echo "  Your printer data (~/printer_data), your backups and the installer files are NOT touched; remove them separately."
            read -r -p "  Type REMOVE (capital letters) to confirm, anything else cancels: " word || word=""
            [ "$word" = REMOVE ] || { echo "Nothing changed."; return 0; }
            for c in screen webcam timelapse shell-command obico octoapp octoeverywhere fluidd moonraker klipper; do
                [ "$(addon_status "$c")" = "not installed" ] && continue
                ( ARG1="$c"; REMOVE_CONFIRMED=1; FORCE=1; do_remove_addon )
            done
            [ -f "$STATE" ] && uninstall_system_files
            print_success "The programs were removed."
            leftover_report ;;
        *) die_with_fix "unknown name '${name}'." "use one of: screen, network-manager, webcam, timelapse, shell-command, obico, octoapp, octoeverywhere, fluidd, moonraker, klipper, data, system, cleanup, all." ;;
    esac
}

# ============================================================================
# Menu (plain numbered lists). Every entry runs the same installer options you can type yourself.
# ============================================================================
menu_pause() { [ -t 0 ] && { read -r -p "  Press Enter to go back... " _ || true; }; return 0; }
menu_run() { echo; bash "$SCRIPT_DIR/installer.sh" "$@"; local rc=$?; echo; menu_pause; return $rc; }
menu_read() {   # prompt -> sets REPLY_MENU; returns 1 at end of input
    local a; read -r -p "  $1 " a || return 1; REPLY_MENU="$(echo "$a" | tr -d '[:space:]')"; return 0
}
menu_item() { if [ -n "$3" ]; then printf '   %s) %-28s %b%s%b\n' "$1" "$2" "$DIM" "$3" "$NC"; else printf '   %s) %s\n' "$1" "$2"; fi; }

addon_status() {   # name -> installed|running|not installed
    case "$1" in
        screen)   [ -d "$KS_DIR" ] && { [ "$(service_state KlipperScreen)" = active ] && echo running || echo installed; } || echo "not installed" ;;
        network-manager) [ "$(service_state NetworkManager)" = active ] && echo running || { [ "$(service_enabled NetworkManager)" = enabled ] && echo installed || echo "not installed"; } ;;
        webcam)   [ -d "$HOME_DIR/crowsnest" ] && { [ "$(service_state crowsnest)" = active ] && echo running || echo installed; } || echo "not installed" ;;
        timelapse) [ -d "$HOME_DIR/moonraker-timelapse" ] && echo installed || echo "not installed" ;;
        shell-command) [ -f "$HOME_DIR/klipper/klippy/extras/gcode_shell_command.py" ] && echo installed || echo "not installed" ;;
        fluidd)   [ -d "$HOME_DIR/fluidd" ] && echo installed || echo "not installed" ;;
        moonraker) [ -d "$HOME_DIR/moonraker" ] && echo installed || echo "not installed" ;;
        klipper)  [ -d "$HOME_DIR/klipper" ] && echo installed || echo "not installed" ;;
        data)     [ -d "$HOME_DIR/printer_data" ] && echo "present" || echo "not present" ;;
        system)   [ -f "$STATE" ] && echo installed || echo "nothing recorded" ;;
        obico|octoapp|octoeverywhere)
            local d=$1 sv=$1; [ "$1" = obico ] && { d=moonraker-obico; sv=moonraker-obico; }
            [ -d "$HOME_DIR/$d" ] && { if [ "$TESTING" = 1 ]; then echo installed; elif [ "$(service_state "$sv")" = active ]; then echo running; else echo "downloaded, not running"; fi; } || echo "not installed" ;;
    esac
}

menu_status() {
    if [ -d "$HOME_DIR/kiauh" ]; then print_warning "KIAUH was found on this Pi. Do not use it for Klipper or Moonraker here: it installs the stock versions and would break WonderMaker's compiled modules. This installer manages the WonderMaker versions."; fi
    if [ ! -f "$CONF" ]; then print_info "Not installed yet. Choose 1 to install."; return 0; fi
    echo "  Klipper: $(service_state klipper)   Moonraker: $(service_state moonraker)   nginx: $(service_state nginx)"
    local ps; ps="$(print_state)"; case "$ps" in printing|paused) print_warning "A print is active ($ps): changes are blocked until it ends." ;; esac
    if [ -d "$REPO_DIR/.git" ] && command -v git >/dev/null 2>&1; then
        [ -n "${WM_TEST_NO_FETCH:-}" ] || timeout 6 git -C "$REPO_DIR" fetch --quiet 2>/dev/null
        local up behind; up="$(git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; [ -n "$up" ] || up=origin/main
        behind="$(git -C "$REPO_DIR" rev-list --count "HEAD..$up" 2>/dev/null)"
        if [ "${behind:-0}" -gt 0 ] 2>/dev/null; then print_info "$behind new change(s) on GitHub (version $(git -C "$REPO_DIR" show "$up:VERSION" 2>/dev/null | head -1)). Choose 2 to see them and update."; fi
    fi
}

menu_updates() {
    while true; do
        echo; echo "  Update"
        menu_item 1 "See what is new" "Reads GitHub, changes nothing"
        menu_item 2 "Update now" "git pull, then update services, packages, panel and add-ons (printer_data is kept)"
        menu_item 0 "Back" ""
        menu_read "Choose:" || return 0
        case "$REPLY_MENU" in
            1) menu_run --check-updates ;;
            2) if [ -d "$REPO_DIR/.git" ]; then
                   git -C "$REPO_DIR" pull --ff-only || { print_error "git pull failed. Save or discard local changes in $REPO_DIR and try again."; menu_pause; continue; }
               else print_warning "This folder is not a git clone: skipping the download step."; fi
               bash "$SCRIPT_DIR/installer.sh" --update; echo; menu_pause
               exec bash "$SCRIPT_DIR/installer.sh" --menu ;;   # restart the menu so the new version is the one running
            0|"") return 0 ;;
            *) echo "  Choose a number from the list." ;;
        esac
    done
}

menu_addons() {
    local k items=(screen network-manager webcam timelapse shell-command obico octoapp octoeverywhere)
    declare -A label=([screen]="Touchscreen (KlipperScreen)" [network-manager]="NetworkManager (Network panel)" [webcam]="Webcam (crowsnest)" [timelapse]="Timelapse" [shell-command]="Klipper gcode shell command" [obico]="Obico for Klipper" [octoapp]="OctoApp" [octoeverywhere]="OctoEverywhere")
    declare -A help=([network-manager]="Wi-Fi choice on the screen. Can drop the network until a reboot" [screen]="Screen plugged into the Pi, with the ZR Tools page" [webcam]="USB camera streams for Fluidd" [timelapse]="Moonraker timelapse + ffmpeg" [shell-command]="RUN_SHELL_COMMAND: run Linux commands from G-code" [obico]="Remote view and failure detection (obico.io account)" [octoapp]="Phone app notifications and control" [octoeverywhere]="Remote access, webcam and notifications (free account)")
    while true; do
        echo; echo "  Add-ons"
        local n=0; for k in "${items[@]}"; do n=$((n+1)); menu_item "$n" "${label[$k]}" "[$(addon_status "$k")] ${help[$k]}"; done
        menu_item 0 "Back" ""
        menu_read "Choose one to install or remove:" || return 0
        [ "$REPLY_MENU" = 0 ] || [ -z "$REPLY_MENU" ] && return 0
        if ! [[ "$REPLY_MENU" =~ ^[0-9]+$ ]] || [ "$REPLY_MENU" -lt 1 ] || [ "$REPLY_MENU" -gt "${#items[@]}" ]; then echo "  Choose a number from the list."; continue; fi
        k="${items[$((REPLY_MENU-1))]}"; local st; st="$(addon_status "$k")"
        if [ "$st" = "not installed" ]; then
            ask_yn "Install ${label[$k]}?" n || continue
            case "$k" in
                screen) menu_run --update --screen on ;;
                network-manager) echo "  This can drop the network connection (SSH, Fluidd) when the Pi restarts. Nothing restarts by itself."; ask_yn "Still install it?" n && menu_run --update --network-manager on ;;
                webcam) menu_run --update --webcam on ;;
                timelapse) menu_run --update --timelapse on ;;
                *) menu_run --update "--$k" on ;;
            esac
        else
            case "$k" in
                *) menu_run --remove "$k" ;;
            esac
        fi
    done
}

menu_fix() {
    while true; do
        echo; echo "  Check and fix"
        menu_item 1 "Doctor" "Finds problems, explains them, offers a fix for each (asks first)"
        menu_item 2 "Repair" "Puts back services, nginx files, the can0 rule and groups (data untouched)"
        menu_item 3 "Hardware test" "Read-only live test: USB bridge, can0, CAN devices, camera, services"
        menu_item 4 "Quick check" "Report problems, change nothing"
        menu_item 0 "Back" ""
        menu_read "Choose:" || return 0
        case "$REPLY_MENU" in 1) menu_run --doctor ;; 2) menu_run --repair ;; 3) menu_run --hw-test ;; 4) menu_run --check ;; 0|"") return 0 ;; *) echo "  Choose a number from the list." ;; esac
    done
}

menu_backup() {
    while true; do
        echo; echo "  Backup and restore"
        menu_item 1 "Back up my settings" "Saves config, calibration and database to ~/wm-backups (copy it off the Pi)"
        menu_item 2 "Restore a backup" "Pick one from the list; a safety copy is made first"
        menu_item 3 "Undo the last install" "Puts back the folders the installer moved aside"
        menu_item 0 "Back" ""
        menu_read "Choose:" || return 0
        case "$REPLY_MENU" in
            1) menu_run --backup ;;
            2) menu_restore ;;
            3) menu_run --undo ;;
            0|"") return 0 ;; *) echo "  Choose a number from the list." ;;
        esac
    done
}

menu_restore() {   # shows where the backups are kept and lets you choose one by number
    local dir="$HOME_DIR/wm-backups" files=() f n i extra
    echo; echo "  Restore a backup"
    echo "  Backups made by this installer are kept in: $dir"
    mapfile -t files < <(ls -1t "$dir"/wm-backup-*.tgz 2>/dev/null)
    if [ "${#files[@]}" = 0 ]; then echo "  There are no backups in that folder yet. Use 'Back up my settings' first, or copy a backup file there."
    else
        i=0; for f in "${files[@]}"; do i=$((i+1)); printf '   %s) %s   %s   %s\n' "$i" "$(basename "$f")" "$(du -h "$f" | cut -f1)" "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null)"; done
    fi
    extra=$(( ${#files[@]} + 1 ))
    menu_item "$extra" "A backup file in another place" "You type its path"
    menu_item 0 "Back" ""
    menu_read "Choose a backup:" || return 0
    case "$REPLY_MENU" in
        0|"") return 0 ;;
        *[!0-9]*) echo "  Choose a number from the list."; return 0 ;;
    esac
    n="$REPLY_MENU"
    if [ "$n" = "$extra" ]; then
        menu_read "Path of the .tgz file (Enter to cancel):" || return 0
        [ -n "$REPLY_MENU" ] && menu_run --restore "$REPLY_MENU"
    elif [ "$n" -ge 1 ] && [ "$n" -le "${#files[@]}" ]; then menu_run --restore "${files[$((n-1))]}"
    else echo "  Choose a number from the list."; fi
}

menu_uninstall() {
    local k n items=(screen network-manager webcam timelapse shell-command obico octoapp octoeverywhere fluidd moonraker klipper data system cleanup all)
    declare -A label=([screen]="Touchscreen (KlipperScreen)" [network-manager]="NetworkManager (switch back to dhcpcd)" [webcam]="Webcam (crowsnest)" [timelapse]="Timelapse" [shell-command]="Klipper gcode shell command" [obico]="Obico for Klipper" [octoapp]="OctoApp" [octoeverywhere]="OctoEverywhere" [fluidd]="Fluidd web page" [moonraker]="Moonraker" [klipper]="Klipper" [data]="My printer data" [system]="System files" [cleanup]="Clean up installer files" [all]="Everything above")
    declare -A help=([network-manager]="Only if this installer switched you to it" [fluidd]="The page you open in the browser, with its nginx site" [moonraker]="The web API Fluidd and the add-ons use" [klipper]="The printer firmware host" [data]="printer.cfg, calibration, database, gcode files (a backup is made first)" [system]="Services, nginx files and the can0 rule the installer added" [cleanup]="Old backups, support bundles, moved-aside folders, saved copies, the installer folder" [all]="Everything except my printer data, my backups and the installer files")
    while true; do
        echo; echo "  Uninstall"; echo "  Choose what to remove. Each choice explains what goes and asks before it changes anything."
        n=0; for k in "${items[@]}"; do n=$((n+1)); case "$k" in all|cleanup) menu_item "$n" "${label[$k]}" "${help[$k]}" ;; *) menu_item "$n" "${label[$k]}" "[$(addon_status "$k")] ${help[$k]:-}" ;; esac; done
        menu_item 0 "Back" ""
        menu_read "Choose:" || return 0
        [ "$REPLY_MENU" = 0 ] || [ -z "$REPLY_MENU" ] && return 0
        if ! [[ "$REPLY_MENU" =~ ^[0-9]+$ ]] || [ "$REPLY_MENU" -lt 1 ] || [ "$REPLY_MENU" -gt "${#items[@]}" ]; then echo "  Choose a number from the list."; continue; fi
        menu_run --remove "${items[$((REPLY_MENU-1))]}"
        [ -f "$SCRIPT_DIR/installer.sh" ] || { echo "  The installer folder was removed, so the menu closes."; exit 0; }
    done
}

menu_advanced() {
    while true; do
        echo; echo "  Advanced"
        menu_item 1 "First start" "With the main board connected: checks, then starts Klipper"
        menu_item 2 "Start Klipper again" "Undoes Stop Klipper: starts it now and at every boot, no checks"
        menu_item 3 "Stop Klipper" "Stops Klipper and keeps it from starting at boot"
        menu_item 4 "Support bundle" "A scrubbed .tgz of logs and config to share when asking for help"
        menu_item 5 "Show the last log" "Where the log of the last run is, and its last lines"
        menu_item 0 "Back" ""
        menu_read "Choose:" || return 0
        case "$REPLY_MENU" in
            1) menu_run --first-start ;; 2) menu_run --start-klipper ;; 3) menu_run --disable-klipper ;; 4) menu_run --support-bundle ;; 5) menu_run --show-log ;;
            0|"") return 0 ;; *) echo "  Choose a number from the list." ;;
        esac
    done
}

do_menu() {
    load_answers || true
    [ -f "$CONF" ] && [ "${WM_MENU_NO_POLKIT:-0}" != 1 ] && polkit_check_and_fix
    while true; do
        echo; menu_status; echo
        menu_item 1 "Install or reinstall" "Sets up Klipper, Moonraker and Fluidd; asks a few plain questions"
        menu_item 2 "Update" "See what is new, then update (your printer_data is kept)"
        menu_item 3 "Add-ons" "Touchscreen, webcam, timelapse, shell command, Obico, OctoApp, OctoEverywhere"
        menu_item 4 "Check and fix" "Doctor, repair, hardware test"
        menu_item 5 "Backup and restore" "Save and restore config, calibration and database"
        menu_item 6 "Uninstall" "Remove any add-on, Fluidd, Moonraker, Klipper or everything"
        menu_item 7 "Advanced" "First start, start or stop Klipper, support bundle"
        menu_item 0 "Exit" ""
        menu_read "Choose:" || { echo; return 0; }
        case "$REPLY_MENU" in
            1) ask_yn "Run the install now? It asks its own questions first." y && menu_run --install ;;
            2) menu_updates ;; 3) menu_addons ;; 4) menu_fix ;; 5) menu_backup ;; 6) menu_uninstall ;; 7) menu_advanced ;;
            0|q|Q|"") return 0 ;;
            *) echo "  Choose a number from the list." ;;
        esac
    done
}

# ============================================================================
# Main
# ============================================================================
# ----------------------------------------------------------------------------
# Log of every run that changes something: ~/wm-install-logs/installer-MODE-DATE.log
# At a terminal the installer re-runs itself inside `script`, so the terminal behaves exactly as before (colours, prompts, the add-ons'
# own questions) and everything shown is recorded. Without a terminal the output is copied with tee. Passwords and tokens are removed,
# colour codes are removed, progress bars are reduced to their last line. The newest 20 logs are kept.
# ----------------------------------------------------------------------------
LOG_DIR="$HOME_DIR/wm-install-logs"; LOG_FILE=""
scrub_secrets() { sed -E 's/((password|passwd|token|api_?key|secret|ssid|psk)[[:space:]]*[:=][[:space:]]*).*/\1<removed>/I'; }
clean_log() {
    [ -f "$LOG_FILE.raw" ] || return 0
    python3 - "$LOG_FILE.raw" <<'PY' 2>/dev/null | scrub_secrets > "$LOG_FILE" || scrub_secrets < "$LOG_FILE.raw" > "$LOG_FILE"
import re, sys
ansi = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][A-Z0-9]|\x1b[=>]")
for raw in open(sys.argv[1], errors="replace").read().split("\n"):
    if raw.startswith("Script started on") or raw.startswith("Script done on"): continue
    line = ansi.sub("", raw)
    parts = [x for x in line.split("\r") if x.strip() != ""]
    line = parts[-1] if parts else ""
    line = re.sub(r".\x08", "", line).replace("\x08", "")
    print(line.rstrip())
PY
    rm -f "$LOG_FILE.raw"; chmod 600 "$LOG_FILE" 2>/dev/null
    ls -1t "$LOG_DIR"/installer-*.log 2>/dev/null | tail -n +21 | while IFS= read -r f; do rm -f "$f"; done
}
start_logging() {
    [ "${WM_LOGGING:-0}" = 1 ] && return 0
    [ "$DRY" = 1 ] && return 0
    [ "$TESTING" = 1 ] && [ "${WM_FORCE_LOG:-0}" != 1 ] && return 0
    case " install update repair remove restore undo uninstall firststart startklipper disable doctor hwtest backup screenlayout screenremove " in *" $MODE "*) ;; *) return 0 ;; esac
    [ "$MODE" = install ] && [ "$ORIG_ARGC" = 0 ] && [ -t 0 ] && [ -t 1 ] && [ "${WM_ASSUME_YES:-0}" != 1 ] && return 0   # that opens the menu
    mkdir -p "$LOG_DIR" 2>/dev/null && chmod 700 "$LOG_DIR" 2>/dev/null || return 0
    LOG_FILE="$LOG_DIR/installer-$MODE-$STAMP.log"
    if [ -t 0 ] && [ -t 1 ] && [ "${WM_NO_SCRIPT:-0}" != 1 ] && command -v script >/dev/null 2>&1; then
        local rc; WM_LOGGING=1 script -q -f -e -c "$(printf '%q ' bash "$0" "${ORIG_ARGS[@]}")" "$LOG_FILE.raw"; rc=$?
        clean_log; echo "Log of this run: $LOG_FILE"; exit $rc
    fi
    exec > >(tee -a "$LOG_FILE.raw") 2>&1
    trap 'sleep 0.5; clean_log' EXIT
}
do_show_log() {
    local f; f="$(ls -1t "$LOG_DIR"/installer-*.log 2>/dev/null | head -n1)"
    [ -n "$f" ] || { print_info "No log yet. Runs that change something write one to $LOG_DIR."; return 0; }
    echo "  Newest log: $f"; echo "  All logs:   $LOG_DIR"; echo "  ---- last 40 lines ----"; tail -n 40 "$f"
}
start_logging
echo -e "${BLUE}WonderMaker Ultra Raspberry Pi replacement - installer $VERSION${NC}"
[ "$DRY" = 1 ] && print_info "DRY RUN: nothing will be changed."
# No options, at a terminal: open the menu (also on an empty Pi; choose 1 there to install).
if [ "$ORIG_ARGC" = 0 ] && [ "$MODE" = install ] && [ -t 0 ] && [ -t 1 ] && [ "${WM_ASSUME_YES:-0}" != 1 ]; then MODE=menu; fi
case "$MODE" in
    menu)       do_menu; exit 0 ;;
    remove)     do_remove_addon; exit $? ;;
    check)      do_check; exit 0 ;;
    firststart) do_first_start ask; exit $? ;;
    hwtest)     do_hw_test; exit 0 ;;
    doctor)     do_doctor; exit $? ;;
    repair)     do_repair; exit 0 ;;
    update)     do_update; exit 0 ;;
    checkupdates) do_check_updates; exit $? ;;
    undo)       do_undo; exit 0 ;;
    backup)     do_backup; exit 0 ;;
    restore)    do_restore; exit 0 ;;
    bundle)     do_support_bundle; exit 0 ;;
    showlog)    do_show_log; exit 0 ;;
    disable)    do_disable; exit 0 ;;
    startklipper) do_start_klipper; exit $? ;;
    uninstall)  do_uninstall; exit 0 ;;
    screentest) do_screen_test; exit 0 ;;
    screenlayout) do_screen_layout; exit 0 ;;
    screenremove) do_screen_remove; exit 0 ;;
esac

if [ -n "$SCREEN_LAYOUT" ] && [ "$MODE" = install ] && [ "$WANT_SCREEN" = ask ] && [ -f "$CONF" ]; then do_screen_layout; exit 0; fi
check_system
preflight
ask_model
choose_source
questions
show_plan
[ "$DRY" = 1 ] || ask_yn "Go ahead?" y || { echo "Nothing changed."; exit 0; }
guard_not_printing
save_answers
step_packages; step_groups; step_python; step_unpack; step_model; step_venvs; step_modules
step_services; step_nginx; step_can; step_panel; step_screen; step_netmgr; step_timelapse; step_shellcmd; step_remote; step_crowsnest; step_start
save_answers
self_test
if [ "$AUTOSTART" = 1 ] && [ "$DRY" != 1 ]; then do_first_start auto || true; fi

print_header "Done"
if [ ${#WARNINGS[@]} -gt 0 ]; then for w in "${WARNINGS[@]}"; do print_warning "$w"; done; fi
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
print_success "Open Fluidd at http://${IP:-<pi-address>}/"
[ "$(service_state klipper)" = active ] || echo "Klipper is off. When the main board is connected: ./installer.sh --first-start"
