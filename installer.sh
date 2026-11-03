#!/bin/bash

# =============================================================================
# WonderMaker ZR Ultra / Ultra-S  -  Raspberry Pi replacement installer
# =============================================================================
# Sets up a Raspberry Pi (64-bit Raspberry Pi OS Bookworm, user t13dp) to run WonderMaker's own
# Klipper / Moonraker / Fluidd in place of the failed screen/host board.
#
# ./installer.sh                       install (asks a few plain questions first)
# ./installer.sh --from-board IP       take the software from the old board over SSH
# ./installer.sh --from-image FILE     take it from a disk image of the old board (.img / .img.gz)
# ./installer.sh --from-stage DIR      take it from a folder made by scripts/pull_from_board.sh
# ./installer.sh --from-github         take the factory files that are inside this repository (no printer needed)
# ./installer.sh --model ultra|ultra-s your printer (asked if not given; sets up printer.cfg for it)
# ./installer.sh --modules DIR         optional: your own copies of the 5 compiled modules (replace the bundled ones)
# ./installer.sh --check               report problems, change nothing
# ./installer.sh --first-start         checks with the main board connected; fixes canbus_uuid; then starts Klipper and the other services
# ./installer.sh --hw-test             read-only live test: USB bridge, can0, CAN devices, camera, services
# ./installer.sh --doctor              find problems, explain them, offer a fix for each (asks first)
# ./installer.sh --repair              put back services, nginx files, can0 rule and groups (data untouched)
# ./installer.sh --update              update after you pulled a new version of this repository (your printer_data is not touched)
# ./installer.sh --undo [DIR]          put back the folders the installer moved aside (latest, or DIR)
# ./installer.sh --backup [DIR]        save your config, calibration and database to a .tgz (only when you run it)
# ./installer.sh --restore FILE        restore such a backup (a safety copy is made first)
# ./installer.sh --support-bundle      make a scrubbed .tgz of logs and config to share when asking for help
# ./installer.sh --enable-klipper      same as --first-start
# ./installer.sh --disable-klipper     stop Klipper and stop it from starting at boot
# ./installer.sh --uninstall           remove what the installer added to the system (your files in ~ stay)
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
WANT_PANEL=1; WANT_SCREEN=ask; WANT_TIMELAPSE=1; WANT_CROWSNEST=1
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
while [ $# -gt 0 ]; do
    case "$1" in
        --from-board)   SRC_KIND=board; SRC_ARG="${2:-}"; shift ;;
        --from-image)   SRC_KIND=image; SRC_ARG="${2:-}"; shift ;;
        --from-stage)   SRC_KIND=stage; SRC_ARG="${2:-}"; shift ;;
        --from-github|--from-repo) SRC_KIND=repo; SRC_ARG="repo" ;;
        --model)        MODEL="${2:-}"; MODEL_SET=1; shift ;;
        --modules)      MODULES_DIR="${2:-}"; shift ;;
        --check)        MODE=check ;;
        --first-start|--enable-klipper) MODE=firststart ;;
        --hw-test)      MODE=hwtest ;;
        --doctor)       MODE=doctor ;;
        --repair)       MODE=repair ;;
        --update)       MODE=update ;;
        --undo)         MODE=undo; case "${2:-}" in ""|--*) ;; *) ARG1="$2"; shift ;; esac ;;
        --backup)       MODE=backup; case "${2:-}" in ""|--*) ;; *) ARG1="$2"; shift ;; esac ;;
        --restore)      MODE=restore; ARG1="${2:-}"; shift ;;
        --support-bundle) MODE=bundle ;;
        --screen)       case "${2:-}" in on|yes|1) WANT_SCREEN=1 ;; off|no|0) WANT_SCREEN=0 ;; macros) WANT_SCREEN=macros ;; *) print_error "--screen needs on, off or macros"; exit 1 ;; esac; shift ;;
        --screen-layout) case "${2:-}" in tabs|grid) SCREEN_LAYOUT="$2" ;; *) print_error "--screen-layout needs tabs or grid"; exit 1 ;; esac; shift ;;
        --screen-backend) case "${2:-}" in x11|weston|cage) SCREEN_BACKEND="$2" ;; *) print_error "--screen-backend needs x11, weston or cage"; exit 1 ;; esac; shift ;;
        --screen-test)  MODE=screentest ;;
        --screen-remove) MODE=screenremove ;;
        --no-start)     AUTOSTART=0 ;;
        --force)        FORCE=1 ;;
        --disable-klipper) MODE=disable ;;
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
        echo "  2) I have a disk image of its SD card / eMMC"
        echo "  3) I already have a stage folder (klipper.tgz, moonraker.tgz, data.tgz)"
        echo "  4) I have nothing: use the factory files inside this repository (factory defaults, not your own settings)"
        local c; read -r -p "$(echo -e "${YELLOW}?${NC} Choose 1, 2, 3 or 4: ")" c || c=""
        case "$c" in
            1) SRC_KIND=board; read -r -p "  Old board IP address: " SRC_ARG ;;
            2) SRC_KIND=image; read -r -p "  Path of the image file: " SRC_ARG ;;
            3) SRC_KIND=stage; read -r -p "  Stage folder: " SRC_ARG ;;
            4) SRC_KIND=repo; SRC_ARG=repo ;;
            *) die_with_fix "no source chosen." "run again and pick 1 to 4 (or use --from-board / --from-image / --from-stage / --from-github)." ;;
        esac
    fi
    [ -n "$SRC_ARG" ] || die_with_fix "no value given for the source." "see ./installer.sh --help"
    STAGE="$HOME_DIR/wm-stage"
    case "$SRC_KIND" in
        board)
            print_info "Reading from $SRC_ARG over SSH (read-only). The default WonderMaker login is user t13dp, password TM88888."
            why "the board's Klipper, Moonraker, config and calibration are copied once, then the Pi is on its own."
            run bash "$SCRIPT_DIR/scripts/pull_from_board.sh" "$SRC_ARG" "$STAGE" || die_with_fix "could not read the old board." "check the IP, that it is on, and the password. Or use --from-image." ;;
        image)
            [ -f "$SRC_ARG" ] || die_with_fix "image not found: $SRC_ARG" "give the full path."
            run bash "$SCRIPT_DIR/scripts/extract_from_image.sh" "$SRC_ARG" "$STAGE" || die_with_fix "could not read the image." "needs e2fsprogs and fdisk, and free space about the image size." ;;
        repo)
            FROM_FACTORY=1
            case "$MODEL" in ultra|ultra-s) ;; *) die_with_fix "unknown model '$MODEL'." "use --model ultra or --model ultra-s." ;; esac
            print_info "Using the factory files of the $MODEL in this repository (Klipper and Moonraker are GPL; see factory/README.md)."
            echo "  The repository includes WonderMaker's 5 compiled modules (heaters, load cells, calibration), checked against factory checksums."
            run bash "$SCRIPT_DIR/scripts/stage_from_repo.sh" "$MODEL" "$STAGE" $MODULES_DIR || die_with_fix "could not build the factory stage." "see the message above. A modules folder must hold the unmodified factory *.so files." ;;
        stage)
            [ -d "$SRC_ARG" ] || die_with_fix "stage folder not found: $SRC_ARG" "give the full path."
            STAGE="$SRC_ARG" ;;
    esac
    if [ "$FROM_FACTORY" = 1 ] && [ "$DRY" != 1 ] && [ "$(cat "$STAGE/modules_ok" 2>/dev/null)" != 1 ]; then
        warn_later "WonderMaker's 5 compiled modules were NOT installed. Without them Klipper cannot start the heaters, load cells or calibration. Copy them (from your printer or image) into ~/klipper/klippy/extras/ before ./installer.sh --enable-klipper."
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

step_modules() {
    print_header "Step 6: WonderMaker's compiled modules"
    why "These binary modules decide whether the heaters, load cells and tool calibration work. They must import on this Pi."
    [ "$TESTING" = 1 ] || [ "$DRY" = 1 ] && { echo "[skipped in test/dry-run]"; return; }
    local m bad=0
    for m in "${COMPILED_MODULES[@]}"; do
        if (cd "$HOME_DIR/klipper/klippy/extras" && "$HOME_DIR/klippy-env/bin/python" -c "import $m" 2>/dev/null); then print_success "$m"; else print_warning "$m does not import"; bad=1; fi
    done
    [ "$bad" = 0 ] || warn_later "Some WonderMaker modules did not import. Klipper may stop with an error about them. Check: cd ~/klipper/klippy/extras && ~/klippy-env/bin/python -c 'import <module>'"
}

step_services_files() {
    SUDO install -m 644 "$SCRIPT_DIR/config/moonraker.service" /etc/systemd/system/moonraker.service
    SUDO install -m 644 "$SCRIPT_DIR/config/klipper.service"   /etc/systemd/system/klipper.service
    record "FILE /etc/systemd/system/moonraker.service"; record "FILE /etc/systemd/system/klipper.service"
    SUDO systemctl daemon-reload
    SUDO systemctl enable moonraker
}
step_services() {
    print_header "Step 7: Klipper and Moonraker services"
    why "Moonraker (the web API) starts at boot. Klipper is installed but NOT enabled and NOT started until the final checks pass: the main board may not be connected yet."
    step_services_files
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

screen_density_hint() {  # WIDTHxHEIGHT -> compact|comfortable
    local w="${1%%x*}"; [[ "$w" =~ ^[0-9]+$ ]] || { echo compact; return; }
    [ "$w" -le 900 ] && echo compact || echo comfortable
}

do_screen_test() {
    print_header "Screen test (read-only)"
    local r t; read -r r t < <(detect_screen)
    if [ -n "$r" ]; then print_success "Screen found: $r (ZR Tools density: $(screen_density_hint "$r"))"; else print_warning "No screen found on the Pi's video output."; fi
    [ "$t" = touch ] && print_success "Touch device found." || print_warning "No touch device found (a USB touch cable, or the screen has no touch)."
    echo "  Rotation is an operating-system setting, see README 'Touchscreen'."
}

write_screen_conf() {  # layout from --screen-layout, else keep, else default tabs; density stays 'auto'
    local layout="$SCREEN_LAYOUT" theme=dark density=auto
    if [ -f "$ZR_CONF" ]; then
        [ -n "$layout" ] || layout="$(sed -n 's/^layout *= *//p' "$ZR_CONF" | head -n1)"
        theme="$(sed -n 's/^theme *= *//p' "$ZR_CONF" | head -n1)"; density="$(sed -n 's/^density *= *//p' "$ZR_CONF" | head -n1)"
    fi
    case "$layout" in tabs|grid) ;; *) layout=tabs ;; esac
    case "$theme" in dark|light) ;; *) theme=dark ;; esac
    case "$density" in auto|compact|comfortable) ;; *) density=auto ;; esac
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
    [ -n "$r" ] && print_info "Screen found: $r, density $(screen_density_hint "$r")" || print_warning "No screen detected now. KlipperScreen is installed anyway."
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

do_screen_remove() {
    print_header "Remove the touchscreen (KlipperScreen)"
    load_answers || true
    [ -d "$KS_DIR" ] || [ "$TESTING" = 1 ] || [ -f /etc/systemd/system/KlipperScreen.service ] || die_with_fix "KlipperScreen is not installed on this Pi." "nothing to remove."
    echo "Removes the KlipperScreen service, ~/KlipperScreen and its Python environment. Klipper, Moonraker, Fluidd and the ZR Tools macros stay."
    ask_yn "Continue?" n || exit 0
    SUDO systemctl stop KlipperScreen; SUDO systemctl disable KlipperScreen
    SUDO rm -f /etc/systemd/system/KlipperScreen.service; SUDO systemctl daemon-reload
    if [ "$DRY" != 1 ]; then
        rm -rf "$KS_DIR" "$HOME_DIR/.KlipperScreen-env"
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
    if [ "$WANT_SCREEN" = ask ]; then
        local r t; read -r r t < <(detect_screen)
        [ -n "$r" ] && print_info "A screen is connected: $r"
        if ask_yn "Add a touchscreen (KlipperScreen with the ZR Tools page) on this Pi?" y; then WANT_SCREEN=1
        elif ask_yn "Add only the ZR Tools macros (needed if the WonderMaker screen board is your screen)?" y; then WANT_SCREEN=macros
        else WANT_SCREEN=0; fi
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
            WANT_PANEL|WANT_SCREEN|WANT_TIMELAPSE|WANT_CROWSNEST) printf -v "$k" '%s' "$v" ;;
            SCREEN_BACKEND) printf -v "$k" '%s' "$v" ;; KS_PIN) OLD_KS_PIN="$v" ;;
        esac
    done < "$CONF"
}
show_plan() {
    print_header "Plan (nothing has been changed yet)"
    echo "  Printer model:   $MODEL"
    echo "  Software from:   $SRC_KIND ${SRC_ARG:+($SRC_ARG)}"
    local d moved=""; for d in klipper moonraker printer_data fluidd TM_T1; do [ -e "$HOME_DIR/$d" ] && moved="$moved ~/$d"; done
    [ -n "$moved" ] && echo "  Moved to backup (~/wm-rpi-backup/old-*):$moved"
    echo "  Installs:        system packages, Python 3.9, Klipper/Moonraker environments, Moonraker + nginx services, can0 rule"
    echo "  Optional:        panel=$([ "$WANT_PANEL" = 1 ] && echo yes || echo no)  webcam=$([ "$WANT_CROWSNEST" = 1 ] && echo yes || echo no)  timelapse=$([ "$WANT_TIMELAPSE" = 1 ] && echo yes || echo no)  touchscreen=$([ "$WANT_SCREEN" = 1 ] && echo yes || { [ "$WANT_SCREEN" = macros ] && echo "macros only" || echo no; })"
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
        local m bad=""; for m in "${COMPILED_MODULES[@]}"; do (cd "$HOME_DIR/klipper/klippy/extras" && "$HOME_DIR/klippy-env/bin/python" -c "import $m" 2>/dev/null) || bad="$bad $m"; done
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
    if [ "$WANT_TIMELAPSE" = 1 ]; then step_timelapse; fi
    if [ "$WANT_CROWSNEST" = 1 ] && [ "$(addon_pin crowsnest | cut -d'|' -f2)" != "${OLD_CN_PIN:-}" ]; then step_crowsnest; fi
    save_answers
    SUDO systemctl restart moonraker; SUDO systemctl restart nginx
    [ "$(service_state klipper)" = active ] && print_info "Klipper keeps running. Restart it from Fluidd when you are ready (config reload)."
    self_test
    print_success "Update finished (installer $VERSION)."
}
do_repair() {
    print_header "Repair"
    why "Restores groups, service files, nginx and the can0 rule. Your data and the enabled/disabled state of Klipper are not touched."
    guard_not_printing
    load_answers || true
    step_groups; step_services_files; step_nginx; step_can
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
    [ "$bad" = 0 ] && print_success "All good." || { print_error "Problems found."; exit 1; }
}

do_disable() { SUDO systemctl disable klipper; SUDO systemctl stop klipper; print_success "Klipper stopped and disabled."; }

do_uninstall() {
    print_header "Uninstall"
    [ -f "$STATE" ] || die_with_fix "no install record at $STATE." "nothing to remove."
    echo "This removes the services, nginx files and can0 rule the installer added. Your files in ~ are left in place."
    ask_yn "Continue?" n || exit 0
    SUDO systemctl stop klipper; SUDO systemctl stop moonraker
    SUDO systemctl disable klipper; SUDO systemctl disable moonraker
    local k v
    while read -r k v; do
        case "$k" in
            FILE|LINK) SUDO rm -f "$v" ;;
        esac
    done < "$STATE"
    SUDO systemctl daemon-reload; SUDO udevadm control --reload-rules
    SUDO nginx -t >/dev/null 2>&1 && SUDO systemctl reload nginx
    mv "$STATE" "$STATE.removed-$STAMP"
    print_success "Removed. Folders in your home (klipper, moonraker, printer_data, fluidd, environments) are untouched; delete them yourself if you want."
}

# ============================================================================
# Main
# ============================================================================
echo -e "${BLUE}WonderMaker Ultra Raspberry Pi replacement - installer $VERSION${NC}"
[ "$DRY" = 1 ] && print_info "DRY RUN: nothing will be changed."
case "$MODE" in
    check)      do_check; exit 0 ;;
    firststart) do_first_start ask; exit $? ;;
    hwtest)     do_hw_test; exit 0 ;;
    doctor)     do_doctor; exit $? ;;
    repair)     do_repair; exit 0 ;;
    update)     do_update; exit 0 ;;
    undo)       do_undo; exit 0 ;;
    backup)     do_backup; exit 0 ;;
    restore)    do_restore; exit 0 ;;
    bundle)     do_support_bundle; exit 0 ;;
    disable)    do_disable; exit 0 ;;
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
step_services; step_nginx; step_can; step_panel; step_screen; step_timelapse; step_crowsnest; step_start
save_answers
self_test
if [ "$AUTOSTART" = 1 ] && [ "$DRY" != 1 ]; then do_first_start auto || true; fi

print_header "Done"
if [ ${#WARNINGS[@]} -gt 0 ]; then for w in "${WARNINGS[@]}"; do print_warning "$w"; done; fi
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
print_success "Open Fluidd at http://${IP:-<pi-address>}/"
[ "$(service_state klipper)" = active ] || echo "Klipper is off. When the main board is connected: ./installer.sh --first-start"
