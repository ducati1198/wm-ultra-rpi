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
# ./installer.sh --model ultra|ultra-s printer model for --from-github (default ultra-s)
# ./installer.sh --modules DIR         folder with WonderMaker's 5 compiled modules (needed for --from-github)
# ./installer.sh --check               report problems, change nothing
# ./installer.sh --enable-klipper      start Klipper now and at every boot (do this when the main board is connected)
# ./installer.sh --disable-klipper     stop Klipper and stop it from starting at boot
# ./installer.sh --uninstall           remove what the installer added to the system (your files in ~ stay)
# ./installer.sh --dry-run             go through the questions, show what would change, change nothing
# ./installer.sh --help | --version
#
# What this installer never does:
#   - It never flashes any board (main board, toolheads, hub, screen). No firmware is touched.
#   - It never starts Klipper unless you run --enable-klipper yourself.
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
WANT_PANEL=1; WANT_ZRTOOLS=0
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="$HOME_DIR/wm-rpi-backup"
STATE="$BACKUP_ROOT/installed.manifest"
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
    if [ "$TESTING" = 1 ]; then echo "[test] sudo $*" >> "$HOME_DIR/.sudo.log"; return 0; fi
    sudo "$@"
}
record() { [ "$DRY" = 1 ] && return 0; mkdir -p "$BACKUP_ROOT"; echo "$1" >> "$STATE"; }

usage() { sed -n '4,25p' "$0" | sed 's/^# \{0,1\}//'; }

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
        --enable-klipper)  MODE=enable ;;
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

service_state() { systemctl is-active "$1" 2>/dev/null || true; }

# ============================================================================
# Source of the WonderMaker software
# ============================================================================
choose_source() {
    print_header "Where is the WonderMaker software?"
    echo "The Pi runs WonderMaker's own Klipper, Moonraker and your settings. They are not in this repo."
    echo "They are copied from your own printer: from the old board, from an image of it, or from a folder."
    if [ -z "$SRC_KIND" ]; then
        echo "  1) The old board is still reachable on the network (SSH)"
        echo "  2) I have a disk image of its SD card / eMMC"
        echo "  3) I already have a stage folder (klipper.tgz, moonraker.tgz, data.tgz)"
        echo "  4) I have nothing: use the factory files inside this repository (needs the 5 compiled modules, see below)"
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
            if [ -z "${MODEL_SET:-}" ] && [ "${WM_ASSUME_YES:-0}" != 1 ]; then
                read -r -p "  Which printer? 1) ZR Ultra  2) ZR Ultra-S [2]: " m || m=""; [ "$m" = 1 ] && MODEL=ultra || MODEL=ultra-s
            fi
            case "$MODEL" in ultra|ultra-s) ;; *) die_with_fix "unknown model '$MODEL'." "use --model ultra or --model ultra-s." ;; esac
            print_info "Using the factory files of the $MODEL in this repository (Klipper and Moonraker are GPL; see factory/README.md)."
            echo "  The 5 compiled WonderMaker modules (heaters, load cells, calibration) are not in the repo: no license to publish them."
            if [ -z "$MODULES_DIR" ] && [ "$DRY" != 1 ] && [ "${WM_ASSUME_YES:-0}" != 1 ]; then
                echo "  They come from your printer or its image. Folder with the *.so files (empty = add later):"
                read -r -p "  Modules folder: " MODULES_DIR || MODULES_DIR=""
            fi
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

step_venvs() {
    print_header "Step 5: Python environments"
    why "Klipper and Moonraker each get their own environment with the package versions WonderMaker used."
    [ "$TESTING" = 1 ] && { echo "[test] venvs skipped"; return; }
    [ "$DRY" = 1 ] && { echo -e "  ${DIM}would create ~/klippy-env and ~/moonraker-env with Python 3.9${NC}"; return; }
    "$PY39" -m venv "$HOME_DIR/klippy-env" || die_with_fix "could not create klippy-env." "run again."
    "$HOME_DIR/klippy-env/bin/pip" install -q -U pip wheel "setuptools<66" || die_with_fix "pip failed." "check the internet connection."
    "$HOME_DIR/klippy-env/bin/pip" install -q -r "$SCRIPT_DIR/config/klippy-requirements.txt" || die_with_fix "Klipper's packages did not install." "see the message above."
    "$PY39" -m venv "$HOME_DIR/moonraker-env"
    "$HOME_DIR/moonraker-env/bin/pip" install -q -U pip wheel "setuptools<66"
    local req="$HOME_DIR/moonraker/scripts/moonraker-requirements.txt"
    [ -f "$req" ] || req="$(ls "$HOME_DIR"/moonraker/scripts/*requirements*.txt 2>/dev/null | head -1)"
    [ -n "$req" ] && "$HOME_DIR/moonraker-env/bin/pip" install -q -r "$req" || die_with_fix "Moonraker's packages did not install." "see the message above."
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

step_services() {
    print_header "Step 7: Klipper and Moonraker services"
    why "Moonraker (the web API) starts at boot. Klipper is installed but NOT enabled and NOT started: the main board is not connected yet."
    SUDO install -m 644 "$SCRIPT_DIR/config/moonraker.service" /etc/systemd/system/moonraker.service
    SUDO install -m 644 "$SCRIPT_DIR/config/klipper.service"   /etc/systemd/system/klipper.service
    record "FILE /etc/systemd/system/moonraker.service"; record "FILE /etc/systemd/system/klipper.service"
    SUDO systemctl daemon-reload
    SUDO systemctl enable moonraker
    SUDO systemctl disable klipper
    SUDO systemctl stop klipper
    print_success "Services installed (Klipper stays off)"
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

step_panel() {
    [ -f "$HOME_DIR/fluidd/index.html" ] || [ "$DRY" = 1 ] || WANT_PANEL=1   # factory files carry no web interface: the panel build is the web interface
    [ "$WANT_PANEL" = 1 ] || return 0
    print_header "Step 10: Fluidd with the WonderMaker Toolheads panel"
    why "The Fluidd that came with the printer has no toolhead panel for the Ultra-S. This build adds it (toolheads, chamber, air filter, colours, filament mapping)."
    local zip="$SCRIPT_DIR/fluidd/fluidd-v1.37.7-zr-ace.zip"
    ( cd "$SCRIPT_DIR/fluidd" && sha256sum -c fluidd-v1.37.7-zr-ace.zip.sha256 >/dev/null 2>&1 ) || { print_warning "Checksum of the Fluidd zip does not match: panel skipped."; warn_later "Fluidd panel skipped (checksum)."; return; }
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
    print_success "Fluidd panel installed. Hard-refresh the browser (Ctrl/Cmd+Shift+R)."
}

step_zrtools() {
    [ "$WANT_ZRTOOLS" = 1 ] || return 0
    print_header "Step 11: ZR Tools (KlipperScreen panel)"
    why "Only for a touchscreen on the Pi that runs KlipperScreen. It adds tool, chamber and air-filter pages and macros."
    run mkdir -p "$HOME_DIR/zr_tools"
    run cp "$SCRIPT_DIR"/zr_tools/{zr_tools.py,zr_tools.cfg,install_zr_tools.sh,INSTALL.md} "$HOME_DIR/zr_tools/"
    print_info "Copied to ~/zr_tools. Klipper is off, so the script is not run for you. When Klipper is running: cd ~/zr_tools && bash install_zr_tools.sh"
    record "HOMEDIR zr_tools"
}

step_start() {
    print_header "Step 12: start Moonraker"
    SUDO systemctl restart moonraker
    if [ "$TESTING" != 1 ] && [ "$DRY" != 1 ]; then
        sleep 4
        curl -fsS -m 5 http://127.0.0.1:7125/server/info >/dev/null 2>&1 && print_success "Moonraker answers on port 7125" || warn_later "Moonraker did not answer yet. Look at: journalctl -u moonraker -n 50"
    fi
}

questions() {
    print_header "A few questions"
    ask_yn "Install the Fluidd with the WonderMaker Toolheads panel (recommended)?" y || WANT_PANEL=0
    ask_yn "Copy the ZR Tools KlipperScreen panel too? (only if you plan a touchscreen on the Pi)" n && WANT_ZRTOOLS=1
    echo; echo "  The installer will: install packages, add Python 3.9, unpack WonderMaker's software into ~,"
    echo "  install the Moonraker + nginx services and a can0 rule. Klipper stays OFF."
    [ "$DRY" = 1 ] || ask_yn "Go ahead?" y || { echo "Nothing changed."; exit 0; }
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

do_enable() {
    print_header "Start Klipper"
    echo "Do this only with the replacement main board connected and powered, and the toolhead hub on the CAN bus."
    ls /dev/serial/by-id 2>/dev/null | sed 's/^/  found: /'
    lsusb 2>/dev/null | grep -qi 1d50:606f || print_warning "The USB-CAN bridge (1d50:606f) is not visible: is the main board connected?"
    grep -n 'canbus_uuid' "$HOME_DIR/printer_data/config/"*.cfg 2>/dev/null | sed 's/^/  config: /'
    print_info "canbus_uuid in the config belongs to the OLD main board. A new board has a new uuid: find it with 'scripts/board_check.sh' (Klipper stopped) and edit the cfg first."
    local m missing=0
    for m in "${COMPILED_MODULES[@]}"; do ls "$HOME_DIR/klipper/klippy/extras/$m".*.so >/dev/null 2>&1 || ls "$HOME_DIR/klipper/klippy/extras/$m.py" >/dev/null 2>&1 || { print_error "missing WonderMaker module: $m"; missing=1; }; done
    if [ "$missing" = 1 ] && [ "$TESTING" != 1 ]; then die_with_fix "WonderMaker's compiled modules are not installed." "copy the unmodified *.so files into ~/klipper/klippy/extras/ (from your printer or its image)."; fi
    ask_yn "Enable and start Klipper now?" n || { echo "Not started."; exit 0; }
    SUDO systemctl enable klipper; SUDO systemctl restart klipper
    print_success "Klipper started. Watch: journalctl -u klipper -f"
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
    check)     do_check; exit 0 ;;
    enable)    do_enable; exit 0 ;;
    disable)   do_disable; exit 0 ;;
    uninstall) do_uninstall; exit 0 ;;
esac

check_system
choose_source
questions
step_packages; step_groups; step_python; step_unpack; step_venvs; step_modules
step_services; step_nginx; step_can; step_panel; step_zrtools; step_start

print_header "Done"
if [ ${#WARNINGS[@]} -gt 0 ]; then for w in "${WARNINGS[@]}"; do print_warning "$w"; done; fi
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
print_success "Open Fluidd at http://${IP:-<pi-address>}/ (Klipper is off, so it shows 'Klippy disconnected' until the main board is in)."
echo "Next: connect the main board, run scripts/board_check.sh, fix canbus_uuid, then ./installer.sh --enable-klipper"
