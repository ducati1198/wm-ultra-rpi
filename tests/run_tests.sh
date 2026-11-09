#!/bin/bash
# Tests for the installer and scripts. Uses fake homes. No sudo, no network, no services.
#   bash tests/run_tests.sh
set -u
if [ -z "${WM_TESTS_IN_COPY:-}" ]; then   # always test a throwaway copy of the repository, never the real folder
    CP="$(mktemp -d)"; cp -a "$(cd "$(dirname "$0")/.." && pwd)/." "$CP/"
    WM_TESTS_IN_COPY=1 bash "$CP/tests/run_tests.sh" "$@"; rc=$?; rm -rf "$CP"; exit $rc
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if eval "$2" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1"; fi; }

mkstage() {  # make a fake WonderMaker tree and stage folder
    local s="$1" h="$T/src_home"; rm -rf "$h"
    mkdir -p "$h/klipper/klippy/extras" "$h/moonraker/moonraker" "$h/moonraker/scripts" "$h/printer_data/config" "$h/printer_data/systemd" "$h/printer_data/gcodes" "$h/fluidd" "$h/TM_T1/factory_settings"
    echo "[mcu]" > "$h/printer_data/config/printer.cfg"; echo "x" > "$h/printer_data/gcodes/big.gcode"
    echo 'KLIPPER_ARGS="x"' > "$h/printer_data/systemd/klipper.env"; echo "aiohttp" > "$h/moonraker/scripts/moonraker-requirements.txt"
    echo "<html>old</html>" > "$h/fluidd/index.html"; echo '{"a":1}' > "$h/fluidd/config.json"
    mkdir -p "$s"
    tar czf "$s/klipper.tgz" -C "$h" klipper; tar czf "$s/moonraker.tgz" -C "$h" moonraker
    tar czf "$s/data.tgz" -C "$h" --exclude=printer_data/gcodes printer_data fluidd TM_T1
}
mkdir -p "$T/stubpanel"; python3 -c "import zipfile;z=zipfile.ZipFile('$T/stubpanel/fluidd-stub.zip','w');z.writestr('index.html','<html>fluidd panel</html>');z.close()"
inst() { local h="$1"; shift; WM_TEST_PANEL_DIR="${WM_TEST_PANEL_DIR:-$T/stubpanel}" WM_HOME="$h" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$ROOT/installer.sh" "$@" 2>&1; }

echo "== basics"
check "bash syntax installer" "bash -n $ROOT/installer.sh"
check "bash syntax scripts" "for f in $ROOT/scripts/*.sh $ROOT/zr_tools/install_zr_tools.sh; do bash -n \$f || exit 1; done"
check "--version prints" "bash $ROOT/installer.sh --version | grep -q wm-ultra-rpi"
check "--help prints" "bash $ROOT/installer.sh --help | grep -q from-board"
check "unknown option fails" "! bash $ROOT/installer.sh --nope"
check "no Fluidd zip kept in the repo" "[ ! -e $ROOT/fluidd ]"
check "no Claude mention in repo files" "! grep -rIl -i 'claude' $ROOT --exclude-dir=.git --exclude=tests --exclude=run_tests.sh --exclude=*.patch --exclude=*.zip"
check "no private addresses in repo files" "! grep -rIlE '10\.11\.88\.|192\.168\.1\.' $ROOT --exclude-dir=.git --exclude-dir=klipper --exclude-dir=moonraker --exclude=*.patch"
check "both service files can be enabled at boot" "grep -q 'WantedBy=multi-user.target' $ROOT/config/klipper.service && grep -q 'WantedBy=multi-user.target' $ROOT/config/moonraker.service"

echo "== install from stage folder"
mkstage "$T/stage"; H="$T/h1"; mkdir -p "$H"
OUT="$(inst "$H" --from-stage "$T/stage")"; RC=$?
check "install exits 0" "[ $RC = 0 ]"
check "klippy unpacked" "[ -d $H/klipper/klippy ]"
check "printer.cfg present" "[ -f $H/printer_data/config/printer.cfg ]"
check "gcodes dir created, big gcode not copied" "[ -d $H/printer_data/gcodes ] && [ ! -e $H/printer_data/gcodes/big.gcode ]"
check "panel replaced fluidd" "grep -q -i fluidd $H/fluidd/index.html"
check "fluidd config.json kept" "grep -q '\"a\":1' $H/fluidd/config.json"
check "old fluidd saved" "ls $H/wm-rpi-backup/fluidd-*/index.html"
check "sudo calls recorded" "grep -q 'systemctl enable moonraker' $H/.sudo.log"
check "klipper disabled during install, enabled only at the end" "grep -n 'systemctl disable klipper' $H/.sudo.log | head -1 | cut -d: -f1 | { read a; b=\$(grep -n 'systemctl enable klipper' $H/.sudo.log | head -1 | cut -d: -f1); [ \$a -lt \$b ]; }"
check "can0 rule installed" "grep -q 'install -m 644 .*99-wm-can0.rules' $H/.sudo.log"
check "manifest written" "grep -q 'FILE /etc/systemd/system/moonraker.service' $H/wm-rpi-backup/installed.manifest"

echo "== run again: existing folders are moved, not deleted"
echo "mine" > "$H/printer_data/config/mine.cfg"
inst "$H" --from-stage "$T/stage" >/dev/null
check "previous printer_data saved" "ls $H/wm-rpi-backup/old-*/printer_data/config/mine.cfg"

echo "== without the panel"
H2="$T/h2"; mkdir -p "$H2"; printf 'n\nn\nn\nn\ny\n' > "$T/ans"
WM_HOME="$H2" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --from-stage "$T/stage" < "$T/ans" >/dev/null 2>&1
check "panel declined: old fluidd kept" "grep -q old $H2/fluidd/index.html"

echo "== touchscreen"
H3="$T/h3"; mkdir -p "$H3"
WM_TEST_SCREEN=1024x600 WM_TEST_TOUCH=1 inst "$H3" --from-stage "$T/stage" > "$T/scr.out"
check "screen: panel files in KlipperScreen" "[ -f $H3/KlipperScreen/panels/zr_tools.py ] && [ -f $H3/KlipperScreen/panels/zr_views.py ] && [ -f $H3/KlipperScreen/panels/zr_logic.py ]"
check "screen: default layout tabs" "grep -q 'layout = tabs' $H3/printer_data/config/zr_screen.conf"
check "screen: default size is comfortable" "grep -q 'density = comfortable' $H3/printer_data/config/zr_screen.conf"
check "screen: macros included in printer.cfg" "grep -q 'include zr_tools.cfg' $H3/printer_data/config/printer.cfg && [ -f $H3/printer_data/config/zr_tools.cfg ]"
check "screen: KlipperScreen installed with x11" "grep -q 'KlipperScreen-install backend=x11' $H3/.sudo.log"
check "screen: pinned commit used" "grep -q 'fetch .*KlipperScreen @ 34610ceae31e12a10cc980e20a1dec9976f97dd4' $H3/.sudo.log"
check "screen: service enabled" "grep -q 'systemctl enable KlipperScreen' $H3/.sudo.log"
check "screen: answers saved" "grep -q WANT_SCREEN=1 $H3/wm-rpi-backup/install.conf && grep -q REPO_DIR= $H3/wm-rpi-backup/install.conf"
check "screen: found screen reported" "grep -q 'Screen found: 1024x600' $T/scr.out"
inst "$H3" --screen-layout grid >/dev/null; check "screen-layout grid rewrites the file" "grep -q 'layout = grid' $H3/printer_data/config/zr_screen.conf"
rm -f "$H3/KlipperScreen/panels/zr_views.py"; inst "$H3" --repair >/dev/null
check "repair puts the panel files back" "[ -f $H3/KlipperScreen/panels/zr_views.py ]"
rm -f "$H3/KlipperScreen/panels/zr_logic.py"; printf 'n\nn\nn\nn\n' | WM_HOME="$H3" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --doctor > "$T/doc.out" 2>&1
check "doctor notices missing panel file" "grep -q 'ZR Tools panel files are missing' $T/doc.out"
H5="$T/h5"; mkdir -p "$H5"; inst "$H5" --from-stage "$T/stage" --screen off --screen-backend weston >/dev/null
check "screen off: nothing installed" "[ ! -d $H5/KlipperScreen ] && grep -q WANT_SCREEN=0 $H5/wm-rpi-backup/install.conf"
H6="$T/h6"; mkdir -p "$H6"; inst "$H6" --from-stage "$T/stage" --screen on --screen-layout grid --screen-backend cage >/dev/null
check "options: grid + cage" "grep -q 'layout = grid' $H6/printer_data/config/zr_screen.conf && grep -q 'backend=cage' $H6/.sudo.log"
H7="$T/h7"; mkdir -p "$H7"; inst "$H7" --from-stage "$T/stage" --screen macros >/dev/null
check "screen macros: only the macros, no KlipperScreen" "[ ! -d $H7/KlipperScreen ] && ! grep -q 'KlipperScreen-install' $H7/.sudo.log && [ -f $H7/printer_data/config/zr_tools.cfg ] && grep -q '^\\[include zr_tools.cfg\\]' $H7/printer_data/config/printer.cfg && grep -q WANT_SCREEN=macros $H7/wm-rpi-backup/install.conf"
check "nginx step lets nginx reach the home folder (Fluidd 403 fix)" "grep -q 'chmod o+x' $H7/.sudo.log"
check "polkit rule step runs (Fluidd PolKit warning fix)" "grep -q 'polkit rules' $H7/.sudo.log"
check "screen: bad value fails" "! bash $ROOT/installer.sh --screen maybe"
check "--screen-test is read-only" "WM_TEST_SCREEN=800x480 WM_TEST_TOUCH=0 bash $ROOT/installer.sh --screen-test | grep -q 'compact'"
echo "== gcode shell command extension"
check "bundled gcode_shell_command.py compiles and registers RUN_SHELL_COMMAND" "python3 -m py_compile $ROOT/config/gcode_shell_command.py && grep -q RUN_SHELL_COMMAND $ROOT/config/gcode_shell_command.py"
check "--shell-command needs on or off" "! bash $ROOT/installer.sh --shell-command maybe"
mkstage "$T/stage_sc"; HS="$T/hs"; mkdir -p "$HS"
OUT="$(inst "$HS" --from-stage "$T/stage_sc" --screen off)"
check "shell command is installed by default, with no question" "cmp -s $ROOT/config/gcode_shell_command.py $HS/klipper/klippy/extras/gcode_shell_command.py"
check "the shell command install asks no question" "! echo \"$OUT\" | grep -qi 'Install the Klipper gcode shell'"
rm -f "$HS/klipper/klippy/extras/gcode_shell_command.py"
OUT="$(inst "$HS" --update --shell-command on)"
check "--update --shell-command on installs it" "cmp -s $ROOT/config/gcode_shell_command.py $HS/klipper/klippy/extras/gcode_shell_command.py"
printf 'y\n' | WM_HOME="$HS" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --uninstall >/dev/null 2>&1
check "--uninstall removes the shell command extension" "grep -q 'rm -f .*extras/gcode_shell_command.py' $HS/.sudo.log"
rm -f "$HS/wm-rpi-backup/"*.removed-* 2>/dev/null; OUT="$(inst "$HS" --update --shell-command on)"
check "the choice is saved for later updates" "grep -rq 'WANT_SHELLCMD=1' $HS --include='*.conf' --include='*answers*' 2>/dev/null || grep -rq 'WANT_SHELLCMD=1' $HS 2>/dev/null"
echo "# local edit" >> "$HS/klipper/klippy/extras/gcode_shell_command.py"
OUT="$(inst "$HS" --update)"
check "a plain --update puts the extension back (choice remembered)" "cmp -s $ROOT/config/gcode_shell_command.py $HS/klipper/klippy/extras/gcode_shell_command.py"
OUT="$(inst "$HS" --update --shell-command off)"
check "--shell-command off leaves the file alone and is remembered" "grep -rq 'WANT_SHELLCMD=0' $HS 2>/dev/null"
check "--help mentions --shell-command" "bash $ROOT/installer.sh --help | grep -q shell-command"

echo "== remote access add-ons (Obico, OctoApp, OctoEverywhere)"
check "--obico needs on or off" "! bash $ROOT/installer.sh --obico maybe"
check "--octoapp needs on or off" "! bash $ROOT/installer.sh --octoapp maybe"
check "--octoeverywhere needs on or off" "! bash $ROOT/installer.sh --octoeverywhere maybe"
mkstage "$T/stage_r"; HR="$T/hr"; mkdir -p "$HR"
OUT="$(inst "$HR" --from-stage "$T/stage_r" --screen off)"
check "none of the three is installed unless asked for" "[ ! -e $HR/octoapp ] && [ ! -e $HR/octoeverywhere ] && [ ! -e $HR/moonraker-obico ]"
printf '[server]\nport: 7125\n[authorization]\ntrusted_clients:\n    127.0.0.0/8\n' > "$HR/printer_data/config/moonraker.conf"
OUT="$(inst "$HR" --update --obico on --octoapp on --octoeverywhere on)"
check "--update --obico on downloads and installs Obico against this Moonraker" "[ -d $HR/moonraker-obico ] && grep -q 'obico install.sh' $HR/.sudo.log"
check "OctoApp is pointed at moonraker.conf and moonraker.service" "[ -d $HR/octoapp ] && grep -q 'octoapp install.sh $HR/printer_data/config/moonraker.conf moonraker.service' $HR/.sudo.log"
check "OctoEverywhere is pointed at moonraker.conf and moonraker.service" "[ -d $HR/octoeverywhere ] && grep -q 'octoeverywhere install.sh $HR/printer_data/config/moonraker.conf moonraker.service' $HR/.sudo.log"
check "the linking step is left to the user and explained" "grep -q 'cd ~/moonraker-obico && ./install.sh' $ROOT/installer.sh"
check "the choices are saved" "grep -rq 'WANT_OBICO=1' $HR && grep -rq 'WANT_OCTOAPP=1' $HR && grep -rq 'WANT_OCTOEVERYWHERE=1' $HR"
: > "$HR/.sudo.log"; OUT="$(inst "$HR" --update)"
check "a plain --update does not run the makers' installers again" "! grep -q 'install.sh' $HR/.sudo.log && echo \"$OUT\" | grep -q 'already installed'"
OUT="$(inst "$HR" --doctor)"
check "--doctor sees the add-ons" "echo \"$OUT\" | grep -q 'Obico is downloaded' && echo \"$OUT\" | grep -q 'OctoApp is downloaded'"
rm -rf "$HR/octoapp"; OUT="$(inst "$HR" --doctor)"
check "--doctor reports a missing add-on" "echo \"$OUT\" | grep -q 'OctoApp is missing'"
OUT="$(printf 'y\n' | WM_HOME="$HR" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --uninstall 2>&1)"
check "--uninstall leaves the add-ons and says how to remove them" "[ -d $HR/moonraker-obico ] && echo \"$OUT\" | grep -q 'NOT removed'"
check "the maker installers' own repos are the ones used" "grep -q 'TheSpaghettiDetective/moonraker-obico' $ROOT/installer.sh && grep -q 'crysxd/OctoApp-Plugin' $ROOT/installer.sh && grep -q 'QuinnDamerell/OctoPrint-OctoEverywhere' $ROOT/installer.sh"

echo "== menu and --remove"
M() { printf "$1" | WM_TEST_NO_FETCH=1 WM_HOME="$2" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" "${@:3}" 2>&1; }
check "--menu on a home with no install says not installed" "mkdir -p $T/mempty && M '0\n' $T/mempty --menu | grep -q 'Not installed yet'"
check "--menu shows every section" "M '0\n' $HR --menu | grep -q 'Install or reinstall' && M '0\n' $HR --menu | grep -q 'Backup and restore' && M '0\n' $HR --menu | grep -q 'Add-ons'"
check "--menu shows the version and service status" "M '0\n' $HR --menu | grep -q 'Klipper:' && M '0\n' $HR --menu | grep -q 'installer 1\\.'"
check "menu: exit with 0, and at end of input" "M '0\n' $HR --menu >/dev/null && M '' $HR --menu >/dev/null"
check "menu: a wrong choice is explained, not fatal" "M 'x\n9\n0\n' $HR --menu | grep -c 'Choose a number' | grep -q 2"
check "menu: add-ons page lists status of each add-on" "M '3\n0\n0\n' $HR --menu | grep -q 'Obico for Klipper.*installed' && M '3\n0\n0\n' $HR --menu | grep -q 'OctoEverywhere' && M '3\n0\n0\n' $HR --menu | grep -q 'gcode shell command'"
check "menu: check-and-fix runs the doctor" "M '4\n1\n0\n0\n' $HR --menu | grep -q 'Doctor\\|doctor\\|Check'"
check "menu: there is no touchscreen settings page any more" "! M '0\n' $HR --menu | grep -q 'Touchscreen settings'"
check "menu: Uninstall section lists everything that can be removed" "M '6\n0\n0\n' $HR --menu | grep -q 'Fluidd web page' && M '6\n0\n0\n' $HR --menu | grep -q 'Moonraker' && M '6\n0\n0\n' $HR --menu | grep -q 'My printer data' && M '6\n0\n0\n' $HR --menu | grep -q 'All programs'"
check "menu warns when KIAUH is on the Pi" "mkdir -p $HR/kiauh && M '0\n' $HR --menu | grep -q 'KIAUH'; rmdir $HR/kiauh"
check "menu: nothing is installed by merely opening and leaving it" "[ ! -e $HR/.menu-touched ]"
check "menu shows a print in progress" "WM_TEST_PRINT_STATE=printing M '0\n' $HR --menu | grep -q 'print is active'"
check "--install is accepted (skips the menu)" "bash $ROOT/installer.sh --help | grep -q -- '--install'"
check "--remove needs a known name" "! M 'y\n' $HR --remove nothing"
check "--remove asks first and keeps everything on no" "M 'n\n' $HR --remove obico | grep -q 'Nothing changed' && [ -d $HR/moonraker-obico ]"
check "--remove obico removes its folder and is remembered" "M 'y\n' $HR --remove obico | grep -q 'removed' && [ ! -e $HR/moonraker-obico ] && grep -q 'WANT_OBICO=0' $HR/wm-rpi-backup/install.conf"
inst "$HR" --update --shell-command on >/dev/null
mkdir -p "$HR/printer_data/config"; printf '[gcode_shell_command hi]\ncommand: echo hi\n' > "$HR/printer_data/config/x.cfg"
check "--remove shell-command refuses while printer.cfg still uses it" "! M 'y\n' $HR --remove shell-command"
rm -f "$HR/printer_data/config/x.cfg"
check "--remove shell-command removes the file" "M 'y\n' $HR --remove shell-command | grep -q 'Removed' && [ ! -e $HR/klipper/klippy/extras/gcode_shell_command.py ]"
check "--webcam off is accepted with --update" "inst $HR --update --webcam off | grep -q 'Update finished'"


echo "== PolKit warning (PackageKit)"
: > "$HR/.sudo.log"; rm -f "$HR/.polkit_fixed"
OUT="$(WM_TEST_POLKIT_WARN=1 M '0\n' $HR --menu)"
check "menu open: Moonraker's PolKit warning is detected and fixed" "echo \"$OUT\" | grep -q 'PolKit warning fixed' && grep -q 'apt-get install -y packagekit' $HR/.sudo.log && grep -q 'systemctl restart moonraker' $HR/.sudo.log"
: > "$HR/.sudo.log"
check "menu open: nothing is done when Moonraker reports nothing" "M '0\n' $HR --menu >/dev/null; ! grep -q packagekit $HR/.sudo.log"
rm -f "$HR/.polkit_fixed"; : > "$HR/.sudo.log"
OUT="$(WM_TEST_POLKIT_WARN=1 WM_TEST_PRINT_STATE=printing M '0\n' $HR --menu)"
check "menu open: during a print the warning is only mentioned" "echo \"$OUT\" | grep -q 'next time you open the menu' && ! grep -q packagekit $HR/.sudo.log"
rm -f "$HR/.polkit_fixed"; : > "$HR/.sudo.log"
check "PackageKit missing (even before Moonraker complains) is fixed" "WM_TEST_PACKAGEKIT=0 M '0\n' $HR --menu | grep -q 'PolKit warning fixed' && grep -q 'apt-get install -y packagekit' $HR/.sudo.log"
rm -f "$HR/.polkit_fixed"
OUT="$(WM_TEST_POLKIT_WARN=1 inst "$HR" --doctor)"
check "--doctor reports the PolKit warning and fixes it" "echo \"$OUT\" | grep -q 'PolKit warnings detected' && [ -f $HR/.polkit_fixed ]"
rm -f "$HR/.polkit_fixed"; : > "$HR/.sudo.log"
WM_TEST_POLKIT_WARN=1 inst "$HR" --repair >/dev/null
check "--repair installs PackageKit through the PolicyKit step" "grep -q 'apt-get install -y packagekit' $HR/.sudo.log"
rm -f "$HR/.polkit_fixed"
check "--check mentions it without changing anything" "WM_TEST_POLKIT_WARN=1 M '' $HR --check | grep -q 'PolKit' && [ ! -f $HR/.polkit_fixed ]"
check "install and update end with the PolKit look" "grep -q 'polkit_check_and_fix' $ROOT/installer.sh && sed -n '/^self_test()/,/^}/p' $ROOT/installer.sh | grep -q polkit_check_and_fix"

echo "== restore from a numbered list"
RS="$T/rs"; mkdir -p "$RS"; mkstage "$T/stage_rs"; inst "$RS" --from-stage "$T/stage_rs" --screen off >/dev/null
M '' "$RS" --backup >/dev/null; sleep 1; M '' "$RS" --backup >/dev/null
OUT="$(M '5\n2\n0\n0\n0\n' $RS --menu)"
check "restore page shows the folder and numbers the backups" "echo \"$OUT\" | grep -q 'kept in: .*wm-backups' && echo \"$OUT\" | grep -q '1) wm-backup-' && echo \"$OUT\" | grep -q '2) wm-backup-'"
check "restore page offers a file in another place" "echo \"$OUT\" | grep -q 'another place'"
check "choosing a number restores that backup" "M '5\n2\n1\ny\n0\n0\n' $RS --menu | grep -q 'Restored from .*wm-backup-'"
check "an unknown number is explained" "M '5\n2\n99\n0\n0\n' $RS --menu | grep -q 'Choose a number from the list'"
check "with no backups the page says so" "mkdir -p $T/rs0 && cp -a $RS/. $T/rs0/ && rm -rf $T/rs0/wm-backups && M '5\n2\n0\n0\n' $T/rs0 --menu | grep -q 'no backups in that folder'"

echo "== uninstall section (--remove)"
mkun() { local h="$1"; rm -rf "$h"; mkdir -p "$h"; mkstage "$T/stage_un"; inst "$h" --from-stage "$T/stage_un" --screen off --webcam on --timelapse on >/dev/null; printf '[server]\nport: 7125\n\n[timelapse]\noutput_path: ~/printer_data/timelapse\n\n[update_manager]\n' > "$h/printer_data/config/moonraker.conf"; }
UN="$T/un"; mkun "$UN"
check "uninstall: webcam asks first" "M 'n\n' $UN --remove webcam | grep -q 'Nothing changed' && [ -d $UN/crowsnest ]"
check "uninstall: webcam is removed and remembered" "M 'y\n' $UN --remove webcam | grep -q 'Webcam service removed' && [ ! -e $UN/crowsnest ] && grep -q 'systemctl stop crowsnest' $UN/.sudo.log && grep -q 'WANT_CROWSNEST=0' $UN/wm-rpi-backup/install.conf"
check "uninstall: timelapse is removed, [timelapse] commented out, copy kept" "M 'y\n' $UN --remove timelapse | grep -q 'Timelapse removed' && [ ! -e $UN/moonraker-timelapse ] && grep -q '^#\[timelapse\]' $UN/printer_data/config/moonraker.conf && grep -q '^#output_path' $UN/printer_data/config/moonraker.conf && grep -q '^\[update_manager\]' $UN/printer_data/config/moonraker.conf && ls $UN/printer_data/config/moonraker.conf.wm-before-timelapse-removal-*"
check "uninstall: Fluidd web page and nginx site" "M 'y\n' $UN --remove fluidd | grep -q 'Fluidd web page removed' && [ ! -e $UN/fluidd ] && grep -q 'rm -f /etc/nginx/sites-enabled/fluidd' $UN/.sudo.log"
check "uninstall: Moonraker" "M 'y\n' $UN --remove moonraker | grep -q 'moonraker removed' && [ ! -e $UN/moonraker ] && [ -d $UN/printer_data ] && grep -q 'rm -f /etc/systemd/system/moonraker.service' $UN/.sudo.log"
check "uninstall: Klipper" "M 'y\n' $UN --remove klipper | grep -q 'klipper removed' && [ ! -e $UN/klipper ] && [ -d $UN/printer_data ]"
check "uninstall: printer data needs the word DELETE" "M 'y\nno\n' $UN --remove data | grep -q 'Nothing changed' && [ -d $UN/printer_data ]"
check "uninstall: printer data (and TM_T1) is backed up, then deleted" "M 'y\nDELETE\n' $UN --remove data | grep -q 'Printer data deleted' && [ ! -e $UN/printer_data ] && [ ! -e $UN/TM_T1 ] && ls $UN/wm-backups/wm-backup-*.tgz"
check "uninstall: a name that is not installed is said so, not an error" "M '' $UN --remove klipper | grep -q 'not installed'"
UA="$T/ua"; mkun "$UA"
check "uninstall everything: wrong word changes nothing" "M 'nope\n' $UA --remove all | grep -q 'Nothing changed' && [ -d $UA/klipper ]"
mkdir -p "$UA/crowsnest-env" "$UA/wm-stage"; echo x > "$UA/octoapp-installer.log"
check "uninstall everything: shows what will be removed before asking, and removes nothing on a wrong word" "M 'nope\n' $UA --remove all | grep -q 'This is what will be removed' && M 'nope\n' $UA --remove all | grep -q -- '- fluidd'"
OUT="$(M 'REMOVE\n' $UA --remove all)"
check "uninstall everything: shows a progress bar that ends at 100 percent" "echo \"$OUT\" | grep -q 'Removing .* (step 1 of ' && echo \"$OUT\" | grep -q '100%  Done'"
check "uninstall everything: lists what is still on the Pi and how to remove it" "echo \"$OUT\" | grep -q 'Still on this Pi' && echo \"$OUT\" | grep -q 'wm-stage' && echo \"$OUT\" | grep -q 'printer_data'"
check "uninstall everything: removes the crowsnest environment too" "[ ! -e $UA/crowsnest-env ]"
check "uninstall everything: removes programs, keeps printer data and backups" "echo \"$OUT\" | grep -q 'programs were removed' && [ ! -e $UA/klipper ] && [ ! -e $UA/moonraker ] && [ ! -e $UA/fluidd ] && [ ! -e $UA/crowsnest ] && [ -d $UA/printer_data/config ] && [ -d $UA/wm-rpi-backup ]"
EX="$T/ex"; mkun "$EX"; M '' "$EX" --backup >/dev/null; echo x > "$EX/wm-support-1.tgz"; mkdir -p "$EX/wm-stage"; mkdir -p "$EX/wm-rpi-backup"; echo dhcpcd-was-enabled > "$EX/wm-rpi-backup/netmgr.state"; : > "$EX/.sudo.log"
check "erase: lists everything, says nothing is kept but the installer folder, and no backup is made" "M 'nope\n' $EX --remove erase | grep -q 'ERASE EVERYTHING' && M 'nope\n' $EX --remove erase | grep -q 'NO backup is made' && M 'nope\n' $EX --remove erase | grep -q 'Kept: the installer folder'"
check "erase: a wrong word changes nothing" "M 'nope\n' $EX --remove erase | grep -q 'Nothing changed' && [ -d $EX/klipper ] && [ -d $EX/printer_data ]"
OUT="$(M 'ERASE\n' $EX --remove erase)"
check "erase: shows a progress bar that ends at 100 percent" "echo \"$OUT\" | grep -q 'Removing .* (step 1 of ' && echo \"$OUT\" | grep -q '100%  Done'"
check "erase: removes programs, printer data, TM_T1, backups, bundles, the old-board copy and the records" "echo \"$OUT\" | grep -q 'Everything was erased' && for d in klipper moonraker fluidd crowsnest printer_data TM_T1 wm-backups wm-stage wm-rpi-backup wm-support-1.tgz; do [ ! -e $EX/\$d ] || { echo left \$d; exit 1; }; done"
check "erase: switches NetworkManager back (it was switched by the installer)" "grep -q 'systemctl enable dhcpcd' $EX/.sudo.log"
check "erase: keeps the installer folder" "[ -f $ROOT/installer.sh ]"
check "menu: the Uninstall page has All programs and Erase everything" "M '6\n0\n0\n' $EX --menu | grep -q 'All programs' && M '6\n0\n0\n' $EX --menu | grep -q 'Erase everything'"
check "uninstall: --help lists every name" "bash $ROOT/installer.sh --help | grep -q 'octoeverywhere, fluidd, moonraker, klipper, data, system'"


echo "== start Klipper again, and clean up installer files"
check "menu: Advanced has Start Klipper again" "M '7\n0\n0\n' $HR --menu | grep -q 'Start Klipper again'"
: > "$HR/.sudo.log"
check "menu: Start Klipper again enables it at boot and starts it" "M '7\n2\n0\n0\n' $HR --menu | grep -q 'Klipper enabled and started' && grep -q 'systemctl enable klipper' $HR/.sudo.log && grep -q 'systemctl restart klipper' $HR/.sudo.log"
check "--start-klipper is accepted on the command line" "M '' $HR --start-klipper | grep -q 'Start Klipper again'"
check "--start-klipper is refused during a print" "! WM_TEST_PRINT_STATE=printing M '' $HR --start-klipper"
CU="$T/cu"; mkun "$CU"; M '' "$CU" --backup >/dev/null; echo x > "$CU/wm-support-1.tgz"; echo x > "$CU/printer_data/config/printer.cfg.wm-model-bak"
check "uninstall menu lists the clean-up page" "M '6\n0\n0\n' $CU --menu | grep -q 'Clean up installer files'"
OUT="$(M '0\n' $CU --remove cleanup)"
check "clean-up page lists each group with its size" "echo \"$OUT\" | grep -q 'Settings backups.*item' && echo \"$OUT\" | grep -q 'Support bundles.*item' && echo \"$OUT\" | grep -q 'Config safety copies' && echo \"$OUT\" | grep -q 'installer folder itself'"
check "clean-up page never lists printer data" "! echo \"$OUT\" | grep -q 'Delete my printer data'"
check "clean-up: support bundles after y" "M '2\ny\n0\n' $CU --remove cleanup | grep -q 'Deleted: Support bundles' && [ ! -e $CU/wm-support-1.tgz ]"
check "clean-up: config safety copies after y" "M '7\ny\n0\n' $CU --remove cleanup | grep -q 'Deleted: Config safety' && [ ! -e $CU/printer_data/config/printer.cfg.wm-model-bak ] && [ -f $CU/printer_data/config/printer.cfg ]"
check "clean-up: backups need the word DELETE" "M '1\nno\n0\n' $CU --remove cleanup | grep -q 'Nothing changed' && ls $CU/wm-backups/wm-backup-*.tgz"
check "clean-up: backups deleted after DELETE" "M '1\nDELETE\n0\n' $CU --remove cleanup | grep -q 'Deleted: Settings backups' && [ ! -e $CU/wm-backups ]"
check "clean-up: nothing-to-delete groups say so" "M '1\n0\n' $CU --remove cleanup | grep -q 'Nothing to delete'"
OUT="$(M '9\nDELETE\n0\n' $CU --remove cleanup)"
check "clean-up: installer records need DELETE and leave printer data" "echo \"$OUT\" | grep -q 'Update and the menu will say so' && [ ! -e $CU/wm-rpi-backup ] && [ -d $CU/printer_data/config ]"
RC="$T/repocopy"; rm -rf "$RC"; cp -a "$ROOT" "$RC"
check "clean-up: the installer folder is deleted only after DELETE (on a copy)" "printf '10\nnope\n0\n' | WM_HOME=$CU WM_INSTALLER_TEST=1 bash $RC/installer.sh --remove cleanup >/dev/null 2>&1; [ -f $RC/installer.sh ] && printf '10\nDELETE\n' | WM_HOME=$CU WM_INSTALLER_TEST=1 bash $RC/installer.sh --remove cleanup | grep -q 'installer folder was deleted' && [ ! -e $RC ]"
check "clean-up: --help lists it" "bash $ROOT/installer.sh --help | grep -q 'cleanup (installer files'"

echo "== plan lists every optional program"
PO="$T/plan"; mkdir -p "$PO"; mkstage "$T/stage_plan"
OUT="$(WM_TEST_PANEL_DIR=$T/stubpanel WM_HOME=$PO WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --dry-run --from-stage $T/stage_plan --model ultra-s --obico on --octoapp on --octoeverywhere off --screen off 2>&1 </dev/null)"
check "plan names obico, octoapp and octoeverywhere with their answers" "echo \"$OUT\" | grep -q 'obico  *yes' && echo \"$OUT\" | grep -q 'octoapp  *yes' && echo \"$OUT\" | grep -q 'octoeverywhere  *no'"
check "plan names every other optional program" "for n in 'panel (Fluidd)' webcam timelapse 'shell command' touchscreen; do echo \"$OUT\" | grep -q \"\$n\" || exit 1; done"
check "every saved WANT_ answer is in the plan list (add new programs to PLAN_OPTIONS)" "for v in \$(sed -n '/^save_answers()/,/^}/p' $ROOT/installer.sh | grep -o 'WANT_[A-Z]*' | sort -u); do grep -q \"|\$v\\\"\" $ROOT/installer.sh || { echo missing \$v; exit 1; }; done"


echo "== NetworkManager option"
check "--network-manager needs on or off" "! bash $ROOT/installer.sh --network-manager maybe"
NM="$T/nm"; rm -rf "$NM"; mkdir -p "$NM"; mkstage "$T/stage_nm"; mkdir -p "$NM/.svc"; touch "$NM/.svc/dhcpcd.enabled"
inst "$NM" --from-stage "$T/stage_nm" --screen on >/dev/null
check "NetworkManager is off by default (asked, default no)" "! grep -q 'install -y network-manager' $NM/.sudo.log && grep -q 'WANT_NETMGR=0' $NM/wm-rpi-backup/install.conf"
check "the question warns that the connection can drop" "grep -q 'can DROP the network connection' $ROOT/installer.sh && grep -q 'update --network-manager on' $ROOT/installer.sh"
OUT="$(inst "$NM" --update --network-manager on)"
check "--update --network-manager on installs and enables it, without starting or rebooting" "grep -q 'apt-get install -y network-manager' $NM/.sudo.log && grep -q 'systemctl enable NetworkManager' $NM/.sudo.log && grep -q 'systemctl disable dhcpcd' $NM/.sudo.log && ! grep -q 'systemctl start NetworkManager\\|systemctl restart NetworkManager\\|reboot' $NM/.sudo.log && echo \"$OUT\" | grep -q 'next reboot'"
check "the choice is remembered and shown in the plan" "grep -q 'WANT_NETMGR=1' $NM/wm-rpi-backup/install.conf && WM_TEST_PANEL_DIR=$T/stubpanel WM_HOME=$T/nmplan WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --dry-run --from-stage $T/stage_nm --model ultra-s --screen on --network-manager on </dev/null 2>&1 | grep -q 'network manager  *yes'"
check "a saved dhcpcd state lets the user switch back" "[ -f $NM/wm-rpi-backup/netmgr.state ]"
check "--remove network-manager asks first" "M 'n\n' $NM --remove network-manager | grep -q 'Nothing changed' && [ -f $NM/wm-rpi-backup/netmgr.state ]"
: > "$NM/.sudo.log"
check "--remove network-manager switches back to dhcpcd at the next boot" "M 'y\n' $NM --remove network-manager | grep -q 'Reboot when you are ready' && grep -q 'systemctl enable dhcpcd' $NM/.sudo.log && grep -q 'systemctl disable NetworkManager' $NM/.sudo.log && [ ! -f $NM/wm-rpi-backup/netmgr.state ] && grep -q 'WANT_NETMGR=0' $NM/wm-rpi-backup/install.conf"
check "--remove network-manager does nothing when the installer did not switch it" "M 'y\n' $NM --remove network-manager | grep -q 'nothing to switch back'"
: > "$NM/.sudo.log"
check "NetworkManager already running: nothing is changed" "WM_TEST_NM=1 inst $NM --update --network-manager on | grep -q 'already running' && ! grep -q 'install -y network-manager' $NM/.sudo.log"
check "menu: Add-ons lists NetworkManager with its status" "M '3\n0\n0\n' $NM --menu | grep -q 'NetworkManager (Network panel)'"
check "menu: Uninstall lists the switch back" "M '6\n0\n0\n' $NM --menu | grep -q 'switch back to dhcpcd'"


echo "== Obico uses its own installer"
O2="$T/o2"; rm -rf "$O2"; mkdir -p "$O2"; mkstage "$T/stage_o2"; inst "$O2" --from-stage "$T/stage_o2" --screen off >/dev/null; printf "[server]\n" > "$O2/printer_data/config/moonraker.conf"; inst "$O2" --update --obico on >/dev/null
check "Obico is installed with its plain ./install.sh (no server flags, no server question)" "grep -q 'obico install.sh$' $O2/.sudo.log"
printf '[server]\nurl = http://x\n' > "$O2/printer_data/config/moonraker-obico.cfg"
check "--remove obico sets the settings file aside so a new install asks again" "M 'y\n' $O2 --remove obico | grep -q 'set aside' && [ ! -f $O2/printer_data/config/moonraker-obico.cfg ] && ls $O2/printer_data/config/moonraker-obico.cfg.wm-removed-*"

echo "== uninstall uses the add-on's own uninstaller"
UO="$T/uo"; mkun "$UO"; printf '\n[update_manager crowsnest]\ntype: git_repo\npath: ~/crowsnest\n\n[update_manager KlipperScreen]\ntype: git_repo\npath: ~/KlipperScreen\n\n[other]\nx: 1\n' >> "$UO/printer_data/config/moonraker.conf"
: > "$UO/.sudo.log"
M 'y\n' $UO --remove webcam >/dev/null
check "webcam: crowsnest's own 'make uninstall' runs first, before the installer's own cleanup" "grep -n 'official uninstall crowsnest: official_yes make uninstall' $UO/.sudo.log | head -1 | cut -d: -f1 | { read a; b=\$(grep -n 'systemctl stop crowsnest' $UO/.sudo.log | head -1 | cut -d: -f1); [ \$a -lt \$b ]; }"
check "webcam: its [update_manager crowsnest] section is removed, other sections stay, a copy is kept" "! grep -q 'update_manager crowsnest' $UO/printer_data/config/moonraker.conf && grep -q '^\[other\]' $UO/printer_data/config/moonraker.conf && ls $UO/printer_data/config/moonraker.conf.wm-before-crowsnest-removal-*"
M 'y\n' $UO --remove screen >/dev/null
check "touchscreen: KlipperScreen's own scripts/Uninstall.sh runs" "grep -q 'official uninstall KlipperScreen: bash scripts/Uninstall.sh' $UO/.sudo.log"
check "touchscreen: its [update_manager KlipperScreen] section is removed" "! grep -qi 'update_manager KlipperScreen' $UO/printer_data/config/moonraker.conf && grep -q '^\[other\]' $UO/printer_data/config/moonraker.conf"
OA="$T/oa"; rm -rf "$OA"; mkdir -p "$OA"; mkstage "$T/stage_oa"; inst "$OA" --from-stage "$T/stage_oa" --screen off >/dev/null; printf '[server]\nport: 7125\n' > "$OA/printer_data/config/moonraker.conf"
inst "$OA" --update --octoapp on --octoeverywhere on >/dev/null
M 'y\n' $OA --remove octoapp >/dev/null; M 'y\n' $OA --remove octoeverywhere >/dev/null
check "OctoApp and OctoEverywhere: their own ./uninstall.sh is the first step" "grep -q 'official uninstall octoapp: bash ./uninstall.sh' $OA/.sudo.log && grep -q 'official uninstall octoeverywhere: bash ./uninstall.sh' $OA/.sudo.log"
check "Obico: the steps from its own uninstall list are done (service, reset-failed, include lines)" "sed -n '/^do_remove_addon_core()/,/^}/p' $ROOT/installer.sh | grep -q 'reset-failed' && sed -n '/^do_remove_addon_core()/,/^}/p' $ROOT/installer.sh | grep -q 'include moonraker-obico-update.cfg' && sed -n '/^do_remove_addon_core()/,/^}/p' $ROOT/installer.sh | grep -q 'include moonraker_obico_macros.cfg'"


echo "== leftovers and administrator rights"
check "files that cannot be deleted as the user are deleted with sudo" "sed -n '/^rm_path()/,/^}/p' $ROOT/installer.sh | grep -q 'SUDO rm -rf'"
CS="$T/cs"; mkun "$CS"; mkdir -p "$CS/wm-stage"; echo x > "$CS/wm-stage/k.tgz"
check "clean-up lists the copy from the old board and needs DELETE for it" "M '4\nno\n0\n' $CS --remove cleanup | grep -q 'Nothing changed' && [ -d $CS/wm-stage ] && M '4\nDELETE\n0\n' $CS --remove cleanup | grep -q 'Deleted: Software copied from the old board' && [ ! -e $CS/wm-stage ]"
check "OctoApp removal also deletes its installer log and config files" "mkdir -p $OA/printer_data/config && touch $OA/octoeverywhere-installer.log $OA/printer_data/config/octoeverywhere.conf $OA/printer_data/config/octoeverywhere-system.cfg && mkdir -p $OA/octoeverywhere $OA/octoeverywhere-env && M 'y\n' $OA --remove octoeverywhere >/dev/null && [ ! -e $OA/octoeverywhere-installer.log ] && [ ! -e $OA/printer_data/config/octoeverywhere.conf ] && [ ! -e $OA/printer_data/config/octoeverywhere-system.cfg ] && [ ! -e $OA/octoeverywhere-env ]"


echo "== log of every run"
LG="$T/lg"; rm -rf "$LG"; mkdir -p "$LG"; mkstage "$T/stage_lg"
WM_FORCE_LOG=1 inst "$LG" --from-stage "$T/stage_lg" --screen off >/dev/null; sleep 1
LF="$(ls -1t $LG/wm-install-logs/installer-install-*.log 2>/dev/null | head -1)"
check "an install writes a log in ~/wm-install-logs" "[ -n \"$LF\" ] && grep -q 'Plan (nothing has been changed yet)' \"$LF\" && grep -q 'Self-test' \"$LF\""
check "the log has no colour codes and no leftover .raw file" "! grep -q \$'\\x1b' \"$LF\" && ! ls $LG/wm-install-logs/*.raw"
check "the log is private (600) and so is its folder" "[ \"\$(stat -c %a \"$LF\")\" = 600 ] && [ \"\$(stat -c %a $LG/wm-install-logs)\" = 700 ]"
check "--show-log says where the log is and shows its end" "M '' $LG --show-log | grep -q 'Newest log: .*installer-install-' "
check "the support bundle contains the newest run log" "M '' $LG --support-bundle >/dev/null; tar tzf \$(ls -1t $LG/wm-support-*.tgz | head -1) | grep -q 'logs/last-installer-run.log'"
rm -rf "$LG/wm-install-logs"; M '' $LG --check >/dev/null; M '0\n' $LG --menu >/dev/null; M '' $LG --check-updates >/dev/null 2>&1; inst "$LG" --dry-run --update >/dev/null 2>&1
check "read-only runs, the menu and --dry-run write no log" "[ ! -d $LG/wm-install-logs ] || [ -z \"\$(ls $LG/wm-install-logs)\" ]"
check "without WM_FORCE_LOG the test runs write no log" "inst $LG --update >/dev/null; [ ! -d $LG/wm-install-logs ] || [ -z \"\$(ls $LG/wm-install-logs)\" ]"
python3 - "$ROOT" "$LG" <<'PY'
import pty, os, sys, time, select
root, home = sys.argv[1], sys.argv[2]
env = dict(os.environ, WM_HOME=home, WM_INSTALLER_TEST="1", WM_FORCE_LOG="1")
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("bash", ["bash", root + "/installer.sh", "--backup"], env)
out = b""; t = time.time()
while time.time() - t < 15:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try: d = os.read(fd, 4096)
        except OSError: break
        if not d: break
        out += d
os.waitpid(pid, 0)
open(home + "/pty.out", "wb").write(out)
PY
check "at a terminal the run is recorded through script, shown normally, and the log path is printed" "grep -q 'Log of this run' $LG/pty.out && ls $LG/wm-install-logs/installer-backup-*.log && grep -q 'Backup of your printer settings' \$(ls $LG/wm-install-logs/installer-backup-*.log | head -1) && ! grep -q \$'\\x1b' \$(ls $LG/wm-install-logs/installer-backup-*.log | head -1)"
check "clean-up lists the logs with a y/n" "mkdir -p $LG/wm-install-logs && echo x > $LG/wm-install-logs/installer-x.log && M '3\nn\n0\n' $LG --remove cleanup | grep -q 'Installer logs' && M '3\ny\n0\n' $LG --remove cleanup | grep -q 'Deleted: Installer logs' && [ ! -e $LG/wm-install-logs ]"

echo "== one SSH password"
# one SSH connection for the whole pull from the old board (a fake ssh records its options)
mkdir -p "$T/fakebin"; cat > "$T/fakebin/ssh" <<'FAKE'
#!/bin/bash
echo "$*" >> "$FAKE_SSH_LOG"
case "$*" in *"-O exit"*) exit 0 ;; *"test -d"*) exit 0 ;; *"tar czf"*) printf 'x' ; exit 0 ;; esac
exit 0
FAKE
chmod +x "$T/fakebin/ssh"; : > "$T/ssh.log"
PATH="$T/fakebin:$PATH" FAKE_SSH_LOG="$T/ssh.log" bash "$ROOT/scripts/pull_from_board.sh" 192.0.2.5 "$T/pulled" >/dev/null 2>&1
check "board pull: every ssh call reuses one connection (ControlMaster/ControlPath)" "[ \$(grep -c 'ControlMaster=auto' $T/ssh.log) -ge 4 ] && ! grep -v 'ControlPath=' $T/ssh.log | grep -q ."
check "board pull: the shared connection is closed at the end" "grep -q -- '-O exit' $T/ssh.log"
check "board pull: still produces the three archives" "[ -f $T/pulled/klipper.tgz ] && [ -f $T/pulled/moonraker.tgz ] && [ -f $T/pulled/data.tgz ]"

echo "== check-updates and zr_tools.cfg backup"
mkdir -p "$T/cu"; ( cd "$T/cu" && git init -q --bare origin.git && git clone -q origin.git work 2>/dev/null && cd work && git config user.email t@t && git config user.name t && echo 1.0.0 > VERSION && git add -A && git commit -q -m first && git push -q origin HEAD:main 2>/dev/null; git branch -q -M main; git push -q -u origin main 2>/dev/null; cd .. && git clone -q origin.git copy && cd copy && git checkout -q main 2>/dev/null; cd ../work && echo 1.1.0 > VERSION && git commit -q -am "new thing" && git push -q origin main )
cp "$ROOT/installer.sh" "$T/cu/copy/installer.sh"
mkdir -p "$T/cu/copy/scripts"; cp "$ROOT/scripts/lib_free_space.sh" "$T/cu/copy/scripts/"
check "--check-updates lists new changes" "bash $T/cu/copy/installer.sh --check-updates | grep -q 'new thing'"
check "--check-updates shows the new version" "bash $T/cu/copy/installer.sh --check-updates | grep -q '1.1.0'"
( cd "$T/cu/copy" && git pull -q origin main 2>/dev/null; git checkout -q -- installer.sh 2>/dev/null; true )
check "--check-updates says latest when level" "cp $ROOT/installer.sh $T/cu/copy/installer.sh; mkdir -p $(dirname $T/cu/copy/installer.sh)/scripts; cp $ROOT/scripts/lib_free_space.sh $(dirname $T/cu/copy/installer.sh)/scripts/; bash $T/cu/copy/installer.sh --check-updates | grep -q 'latest version'"
check "--check-updates outside a git clone compares version numbers" "mkdir -p $T/nogit && cp $ROOT/installer.sh $ROOT/VERSION $T/nogit/; mkdir -p $T/nogit/scripts; cp $ROOT/scripts/lib_free_space.sh $T/nogit/scripts/ && WM_TEST_NEW_VERSION=99.0.0 bash $T/nogit/installer.sh --check-updates | grep -q \"On GitHub: *installer 99.0.0\""
ZH="$T/zrhome"; mkdir -p "$ZH/printer_data/config"; echo "[mcu]" > "$ZH/printer_data/config/printer.cfg"
HOME="$ZH" ZR_NO_RESTART=1 bash "$ROOT/zr_tools/install_zr_tools.sh" >/dev/null 2>&1
echo "# my edit" >> "$ZH/printer_data/config/zr_tools.cfg"
HOME="$ZH" ZR_NO_RESTART=1 bash "$ROOT/zr_tools/install_zr_tools.sh" >/dev/null 2>&1
check "an edited zr_tools.cfg is kept as a backup before being replaced" "grep -q 'my edit' $ZH/printer_data/config/zr_tools.cfg.zrbak_* && ! grep -q 'my edit' $ZH/printer_data/config/zr_tools.cfg"
HOME="$ZH" ZR_NO_RESTART=1 bash "$ROOT/zr_tools/install_zr_tools.sh" >/dev/null 2>&1
check "no extra backup when zr_tools.cfg is unchanged" "[ \$(ls $ZH/printer_data/config/zr_tools.cfg.zrbak_* | wc -l) = 1 ]"
check "bad --screen-layout value fails" "! bash $ROOT/installer.sh --screen-layout round"
check "screen python tests" "python3 -I -W ignore $ROOT/tests/test_screen.py"
check "python files compile" "for f in $ROOT/zr_tools/*.py; do python3 -I -m py_compile \$f || exit 1; done"

echo "== dry run changes nothing"
H4="$T/h4"; mkdir -p "$H4"
inst "$H4" --dry-run --from-stage "$T/stage" > "$T/dry.out"
check "dry run: nothing unpacked" "[ ! -d $H4/klipper ]"
check "dry run: says would run" "grep -q 'would run' $T/dry.out"
check "dry run: no sudo log" "[ ! -s $H4/.sudo.log ]"

echo "== check / enable / disable / uninstall"
check "--check passes on installed home" "WM_HOME=$H WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --check"
mkdir -p "$T/empty"; check "--check fails on empty home" "! WM_HOME=$T/empty WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --check"
inst "$H" --disable-klipper >/dev/null; check "--disable-klipper" "grep -q 'systemctl disable klipper' $H/.sudo.log"
: > "$H/.sudo.log"; printf 'n\n' | WM_HOME="$H" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --enable-klipper >/dev/null 2>&1
check "--enable-klipper asks first (default no)" "! grep -q 'systemctl enable klipper' $H/.sudo.log"
printf 'y\n' | WM_HOME="$H" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --uninstall >/dev/null 2>&1
check "uninstall removes service file" "grep -q 'rm -f /etc/systemd/system/klipper.service' $H/.sudo.log"
check "uninstall keeps user folders" "[ -d $H/klipper/klippy ] && [ -f $H/printer_data/config/printer.cfg ]"

echo "== missing / broken stage"
mkdir -p "$T/bad"; check "incomplete stage refused" "! inst $T/h5 --from-stage $T/bad"
check "wrong user refused outside test mode" "! WM_HOME=$T/h6 bash $ROOT/installer.sh --from-stage $T/stage </dev/null"

echo "== factory files from the repository (no printer)"
(cd "$ROOT/factory/ultra-s" && sha256sum -c SHA256SUMS >/dev/null) && echo "  ok   factory checksums" && PASS=$((PASS+1))
check "factory sources are plain folders, committed" "[ -f $ROOT/factory/ultra-s/klipper/klippy/klippy.py ] && [ -f $ROOT/factory/ultra-s/moonraker/moonraker/moonraker.py ] && ! git -C $ROOT check-ignore -q factory/ultra-s/klipper/klippy/klippy.py"
check "the 5 compiled modules are in the repo and match their factory checksums" "cd $ROOT/factory/ultra-s/klipper && sha256sum -c ../modules.sha256"
check "klipper archive has its license" "[ -f $ROOT/factory/ultra-s/klipper/COPYING ] && [ -f $ROOT/factory/ultra-s/moonraker/LICENSE ]"
check "factory config has the real CAN ids from the owner printer (main board, hub, extruder, T0-T3, load cell)" "grep -q aa157497ce9c $ROOT/factory/ultra-s/config/wm_zru_mcu.cfg && [ \$(cat $ROOT/factory/ultra-s/config/wm_zru_*.cfg | grep -ic \"canbus_uuid: [0-9a-f]\\{12\\}\") = 8 ]"
HG="$T/hg"; mkdir -p "$HG"
OUT="$(inst "$HG" --from-github --model ultra-s)"; echo "$OUT" > "$T/gh.out"
check "install from repo works" "[ -f $HG/klipper/klippy/klippy.py ] && [ -f $HG/printer_data/config/printer.cfg ]"
check "no missing-modules warning (they are bundled)" "! grep -q 'compiled modules were NOT installed' $T/gh.out && grep -q 'all 5 present' $T/gh.out"
check "bundled modules end up in ~/klipper" "ls $HG/klipper/klippy/extras/hx711.cpython-39-aarch64-linux-gnu.so"
check "web interface installed (factory data has none)" "[ -f $HG/fluidd/index.html ]"
check "env files in place" "grep -q KLIPPER_ARGS $HG/printer_data/systemd/klipper.env"
check "unknown model refused" "! inst $T/hg2 --from-github --model nope"
check "iso_version.txt (System version) is installed in the home folder, ultra-s and ultra" "grep -q Add.System_1.1.13 $HG/iso_version.txt"
check "ultra-s model enables zru-s.cfg" "grep -q '^\\[include zru-s.cfg\\]' $HG/printer_data/config/printer.cfg"
HU="$T/hu"; mkdir -p "$HU"; inst "$HU" --from-github --model ultra >/dev/null
check "ultra has its own factory folder" "[ -d $ROOT/factory/ultra/klipper/klippy ] && [ -f $ROOT/factory/ultra/config/printer.cfg ]"
check "ultra folder: zru-s.cfg off, ultra-s folder: on" "grep -q '^# \\[include zru-s.cfg\\]' $ROOT/factory/ultra/config/printer.cfg && grep -q '^\\[include zru-s.cfg\\]' $ROOT/factory/ultra-s/config/printer.cfg"
check "both folders pass their checksums" "(cd $ROOT/factory/ultra && sha256sum -c SHA256SUMS) && (cd $ROOT/factory/ultra-s && sha256sum -c SHA256SUMS)"
check "ultra gets iso_version.txt too" "grep -q Add.System_1.1.13 $HU/iso_version.txt"
check "ultra model leaves zru-s.cfg off" "grep -q '^# \\[include zru-s.cfg\\]' $HU/printer_data/config/printer.cfg && ! grep -q '^\\[include zru-s.cfg\\]' $HU/printer_data/config/printer.cfg"
check "rpi-cfg: wm_calibration.cfg is installed and included, ultra-s and ultra" "cmp $ROOT/rpi-cfg/wm_calibration.cfg $HG/printer_data/config/wm_calibration.cfg && grep -q '^\\[include wm_calibration.cfg\\]' $HG/printer_data/config/printer.cfg && cmp $ROOT/rpi-cfg/wm_calibration.cfg $HU/printer_data/config/wm_calibration.cfg && grep -q '^\\[include wm_calibration.cfg\\]' $HU/printer_data/config/printer.cfg"
check "rpi-cfg: exactly one include line, and printer.cfg was saved first" "[ \$(grep -c 'include wm_calibration.cfg' $HG/printer_data/config/printer.cfg) = 1 ] && ls $HG/printer_data/config/printer.cfg.wm-before-rpicfg-*"
check "rpi-cfg: the include sits before the SAVE_CONFIG block, not after it" "! sed -n '/SAVE_CONFIG/,\$p' $HG/printer_data/config/printer.cfg | grep -q 'include wm_calibration'"
check "rpi-cfg: the macros render and behave (jinja2)" "python3 $ROOT/tests/rpi_cfg_render.py; r=\$?; [ \$r = 0 ] || [ \$r = 77 ]"
check "rpi-cfg: every WonderMaker macro it calls exists in both factory folders" "for m in G29 PROBE_CALIBRATE CALIBRATE_OFFSET_ALL_RAPID_MODE CALIBRATE_OFFSET_ALL_FINE_MODE; do for d in ultra ultra-s; do grep -q \"^\\[gcode_macro \$m\\]\" $ROOT/factory/\$d/config/*.cfg || exit 1; done; done"
check "MCU firmware and flasher match their checksums" "cd $ROOT/factory/ultra-s/mcu && sha256sum -c binaries.sha256"
check "model variants of printer.cfg present" "[ -f $ROOT/factory/ultra-s/config-variants/printer4.cfg ]"
# modules: wrong files refused, right files accepted (use a copy of the repo with matching fake checksums)
mkdir -p "$T/mods"; for n in cs1237 heater_air_core heater_feng hx711 xy_offset_calibrator_core; do echo "fake $n" > "$T/mods/$n.cpython-39-aarch64-linux-gnu.so"; done
check "modules with wrong checksum refused" "! bash $ROOT/scripts/stage_from_repo.sh ultra-s $T/st_bad $T/mods"
RC2="$T/repocopy"; mkdir -p "$RC2"; cp -a "$ROOT/scripts" "$ROOT/config" "$ROOT/factory" "$RC2/"
( cd "$T/mods" && sha256sum *.so | sed 's#  #  klippy/extras/#' ) > "$RC2/factory/ultra-s/modules.sha256"
check "modules with matching checksum accepted" "bash $RC2/scripts/stage_from_repo.sh ultra-s $T/st_ok $T/mods && [ \"\$(cat $T/st_ok/modules_ok)\" = 1 ] && tar xzOf $T/st_ok/klipper.tgz klipper/klippy/extras/hx711.cpython-39-aarch64-linux-gnu.so | grep -q 'fake hx711'"
check "damaged repo files refused" "cp -a $ROOT/factory $T/damaged_f && echo x >> $T/damaged_f/ultra-s/moonraker/README.md && mkdir -p $T/dm && cp -a $ROOT/scripts $ROOT/config $T/dm/ && rm -rf $T/dm/factory && cp -a $T/damaged_f $T/dm/factory && ! bash $T/dm/scripts/stage_from_repo.sh ultra-s $T/st_dm"

echo "== crowsnest, timelapse, pinned environments"
check "addon pins are full commit ids" "grep -qE '^crowsnest\\|https://github.com/mainsail-crew/crowsnest\\|[0-9a-f]{40}\$' $ROOT/config/pins/addons.txt && grep -qE '^moonraker-timelapse\\|.*\\|[0-9a-f]{40}\$' $ROOT/config/pins/addons.txt"
check "klippy requirements all pinned" "! grep -vE '^#|==' $ROOT/config/klippy-requirements.txt | grep -q ."
check "moonraker requirements all pinned" "! grep -vE '^#|==' $ROOT/config/moonraker-requirements.txt | grep -q ."
check "timelapse.cfg shipped (printer.cfg includes it)" "[ -f $ROOT/factory/ultra-s/config/timelapse.cfg ] && grep -q 'include timelapse.cfg' $ROOT/factory/ultra-s/config/printer.cfg"
check "every include of the factory printer.cfg exists" "cd $ROOT/factory/ultra-s/config && for f in \$(grep -E '^\\[include ' printer.cfg | sed 's/\\[include //;s/\\]//'); do [ -f \$f ] || { echo missing \$f; exit 1; }; done"
check "crowsnest installed (unattended) in test log" "grep -q 'make install (crowsnest)' $HG/.sudo.log"
check "crowsnest.conf placed" "[ -f $HG/printer_data/config/crowsnest.conf ]"
check "ffmpeg requested for timelapse" "grep -q 'apt-get install -y ffmpeg' $HG/.sudo.log"
check "moonraker.asvc lists crowsnest" "grep -q crowsnest $HG/printer_data/moonraker.asvc"

echo "== model is applied to every source"
H8="$T/h8"; mkdir -p "$H8"; echo "[include zru-s.cfg]" >> "$T/src_home/printer_data/config/printer.cfg"; mkstage "$T/stage_s"; echo "[include zru-s.cfg]" >> "$T/src_home/printer_data/config/printer.cfg"; tar czf "$T/stage_s/data.tgz" -C "$T/src_home" --exclude=printer_data/gcodes printer_data fluidd TM_T1
inst "$H8" --from-stage "$T/stage_s" --model ultra > /dev/null
check "ultra chosen with a stage that has zru-s on: switched off, backup kept" "grep -q '^# \\[include zru-s.cfg\\]' $H8/printer_data/config/printer.cfg && [ -f $H8/printer_data/config/printer.cfg.wm-model-bak ]"
H9="$T/h9"; mkdir -p "$H9"; inst "$H9" --from-stage "$T/stage_s" --model ultra-s > /dev/null
check "ultra-s chosen: zru-s on" "grep -q '^\\[include zru-s.cfg\\]' $H9/printer_data/config/printer.cfg && [ \"\$(cat $H9/printer_data/wm-model)\" = ultra-s ]"
H10="$T/h10"; mkdir -p "$H10"; printf '1\ny\ny\ny\nn\ny\n' | WM_HOME="$H10" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --from-github > "$T/ask.out" 2>&1
check "installer asks for the model when not given" "grep -q 'Which printer do you have' $T/ask.out && [ \"\$(cat $H10/printer_data/wm-model)\" = ultra ]"

echo "== first start, checks, canbus_uuid"
printf 'Found canbus_uuid=aa157497ce9c, Application: Klipper\nFound canbus_uuid=ae2982cf97e9, Application: Klipper\n' > "$T/can_ok.txt"
printf 'Found canbus_uuid=bb1122334455, Application: Klipper\nFound canbus_uuid=ae2982cf97e9, Application: Klipper\n' > "$T/can_new.txt"
G1="$T/g1"; mkdir -p "$G1"; inst "$G1" --from-github --model ultra-s > "$T/g1.out"
check "install with no CAN answer: services still enabled and started, problem reported" "grep -q 'systemctl enable klipper' $G1/.sudo.log && grep -q 'systemctl restart klipper' $G1/.sudo.log && grep -q 'enabled anyway' $T/g1.out"
check "install says how to continue" "grep -q 'first-start' $T/g1.out"
check "klipper never started before the final step" "[ \$(grep -c 'restart klipper' $G1/.sudo.log) = 1 ]"
check "answers saved" "grep -q '^MODEL=ultra-s' $G1/wm-rpi-backup/install.conf && grep -q '^WANT_CROWSNEST=1' $G1/wm-rpi-backup/install.conf"
check "plan shown before changes" "grep -q 'Plan (nothing has been changed yet)' $T/g1.out"
check "pre-flight ran" "grep -q 'Pre-flight checks' $T/g1.out"
G2="$T/g2"; mkdir -p "$G2"; WM_TEST_CANQUERY="$T/can_ok.txt" inst "$G2" --from-github --model ultra-s > "$T/g2.out"
check "everything passes: klipper enabled and started" "grep -q 'systemctl enable klipper' $G2/.sudo.log && grep -q 'systemctl restart klipper' $G2/.sudo.log"
check "moonraker and nginx enabled at the end" "grep -q 'systemctl enable nginx' $G2/.sudo.log"
G3="$T/g3"; mkdir -p "$G3"; WM_TEST_CANQUERY="$T/can_ok.txt" inst "$G3" --from-github --model ultra-s --no-start > /dev/null
check "--no-start keeps klipper off" "! grep -Eq 'systemctl (start|restart|enable) klipper' $G3/.sudo.log"
G4="$T/g4"; mkdir -p "$G4"; WM_TEST_BRIDGE=0 WM_TEST_CANQUERY="$T/can_ok.txt" inst "$G4" --from-github --model ultra-s > "$T/g4.out"
check "no USB bridge: reason shown" "grep -q 'no main board on USB' $T/g4.out"
check "--first-start alone does not start klipper when a check fails" "! WM_TEST_BRIDGE=0 WM_TEST_CANQUERY=$T/can_ok.txt WM_HOME=$G3 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --first-start && ! grep -Eq 'systemctl (start|restart|enable) klipper' $G3/.sudo.log"
G5="$T/g5"; mkdir -p "$G5"; WM_TEST_CANQUERY="$T/can_new.txt" inst "$G5" --from-github --model ultra-s > "$T/g5.out"
check "new main board: canbus_uuid changed" "grep -q 'canbus_uuid: bb1122334455' $G5/printer_data/config/wm_zru_mcu.cfg"
check "old file kept before the change" "grep -q 'aa157497ce9c' $G5/wm-rpi-backup/uuid-*/wm_zru_mcu.cfg"
check "hub uuid left alone" "grep -q 'ae2982cf97e9' $G5/printer_data/config/wm_zru_hub.cfg"
check "klipper started after the uuid fix" "grep -q 'systemctl restart klipper' $G5/.sudo.log"
G6="$T/g6"; mkdir -p "$G6"; WM_TEST_CANQUERY="$T/can_ok.txt" inst "$G6" --from-github --model ultra-s --no-start >/dev/null
sed -i 's/^\[include zru-s.cfg\]/# [include zru-s.cfg]/' "$G6/printer_data/config/printer.cfg"
check "validator: ultra-s with zru-s off is an error" "! WM_TEST_CANQUERY=$T/can_ok.txt WM_HOME=$G6 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --first-start"
rm "$G6/printer_data/config/macros.cfg" 2>/dev/null; sed -i 's/^# \[include zru-s.cfg\]/[include zru-s.cfg]/' "$G6/printer_data/config/printer.cfg"
check "validator: missing include is an error" "! WM_TEST_CANQUERY=$T/can_ok.txt WM_HOME=$G6 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --first-start"
check "--hw-test changes nothing and lists the checks" "WM_TEST_CANQUERY=$T/can_ok.txt WM_HOME=$G2 WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --hw-test | grep -q 'main board found on USB'"

echo "== print guard"
check "update refused while printing" "! WM_TEST_PRINT_STATE=printing WM_HOME=$G2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --repair"
check "--force goes on" "WM_TEST_PRINT_STATE=printing WM_HOME=$G2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --repair --force"

echo "== backup, restore"
WM_HOME="$G2" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --backup "$T/bk" >/dev/null 2>&1
BK="$(ls $T/bk/wm-backup-*.tgz | head -1)"
check "backup file made, private" "[ -f $BK ] && [ \"\$(stat -c %a $BK)\" = 600 ]"
check "backup holds config" "tar tzf $BK | grep -q printer_data/config/printer.cfg"
check "backup holds no gcodes or logs" "! tar tzf $BK | grep -Eq 'gcodes|logs/'"
echo "# changed" >> "$G2/printer_data/config/printer.cfg"
printf 'y\n' | WM_HOME="$G2" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --restore "$BK" >/dev/null 2>&1
check "restore brings the config back" "! grep -q '^# changed' $G2/printer_data/config/printer.cfg"
check "restore made a safety copy" "ls $G2/wm-backups/wm-backup-*.tgz"
check "restore refuses a wrong file" "! WM_HOME=$G2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --restore $T/ans"

echo "== repair, update, undo"
rm -f "$G2/.sudo.log"
inst "$G2" --repair >/dev/null
check "repair reinstalls service, nginx and can0 files" "grep -q 'moonraker.service' $G2/.sudo.log && grep -q 'nginx' $G2/.sudo.log && grep -q '99-wm-can0.rules' $G2/.sudo.log"
check "repair does not touch klipper state" "! grep -Eq 'systemctl (disable|stop) klipper' $G2/.sudo.log"
sed -i 's/^VERSION=.*/VERSION=0.0.1/' "$G2/wm-rpi-backup/install.conf"
echo "mine" > "$G2/printer_data/config/mine.cfg"
inst "$G2" --update > "$T/up.out"
check "update keeps user config" "[ -f $G2/printer_data/config/mine.cfg ]"
check "update shows what changed" "grep -q 'What changed since 0.0.1' $T/up.out"
check "update records the new version" "grep -q \"^VERSION=$(cat $ROOT/VERSION)\" $G2/wm-rpi-backup/install.conf"
check "update without earlier install fails" "! inst $T/empty --update"
UH="$T/uh"; mkdir -p "$UH"; inst "$UH" --from-stage "$T/stage" >/dev/null; echo mine > "$UH/printer_data/config/mine.cfg"
inst "$UH" --from-stage "$T/stage" >/dev/null
check "second install moved mine.cfg away" "[ ! -f $UH/printer_data/config/mine.cfg ]"
printf 'y\ny\n' | WM_HOME="$UH" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --undo >/dev/null 2>&1
check "undo puts mine.cfg back" "[ -f $UH/printer_data/config/mine.cfg ]"
check "undo keeps what it replaced" "ls -d $UH/wm-rpi-backup/undone-*"

echo "== doctor and support bundle"
check "doctor passes on a good install" "WM_TEST_SCREEN=1024x600 WM_TEST_TOUCH=1 WM_TEST_CANQUERY=$T/can_ok.txt WM_HOME=$G2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --doctor"
D='WM_HOME='"$G2"' WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash '"$ROOT"'/installer.sh --doctor'
check "doctor shows the System version from iso_version.txt" "eval \"$D\" 2>&1 | grep -q 'iso_version.txt (System version: 1.1.13)'"
rm -f "$G2/iso_version.txt"
check "doctor reports a missing iso_version.txt" "eval \"$D\" 2>&1 | grep -q 'iso_version.txt (the System version) is missing'"
check "doctor fix puts the factory iso_version.txt back" "grep -q 'Add System_1.1.13' $G2/iso_version.txt"
echo 'KEEP ME System_9.9.9' > "$G2/iso_version.txt"; eval "$D" >/dev/null 2>&1
check "doctor never overwrites an existing iso_version.txt" "grep -q 'KEEP ME' $G2/iso_version.txt"
cp "$ROOT/factory/ultra-s/iso_version.txt" "$G2/iso_version.txt"
rm -f "$G2/iso_version.txt"; WM_HOME="$G2" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$ROOT/installer.sh" --doctor --fix-all >/dev/null 2>&1 </dev/null
check "Fix everything also restores a missing iso_version.txt" "grep -q 'Add System_1.1.13' $G2/iso_version.txt"
check "doctor: calibration macros are ok on a good install" "eval \"$D\" 2>&1 | grep -q 'calibration macros wm_calibration.cfg (included in printer.cfg, same as rpi-cfg)'"
rm -f "$G2/printer_data/config/wm_calibration.cfg"
check "doctor reports a missing wm_calibration.cfg" "eval \"$D\" 2>&1 | grep -q 'calibration macros file wm_calibration.cfg is missing'"
WM_HOME="$G2" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$ROOT/installer.sh" --doctor --fix-all >/dev/null 2>&1 </dev/null
check "Fix everything puts wm_calibration.cfg back" "cmp $ROOT/rpi-cfg/wm_calibration.cfg $G2/printer_data/config/wm_calibration.cfg"
sed -i '/include wm_calibration.cfg/d' "$G2/printer_data/config/printer.cfg"
check "doctor reports a missing include line" "eval \"$D\" 2>&1 | grep -q 'printer.cfg does not include wm_calibration.cfg'"
WM_HOME="$G2" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$ROOT/installer.sh" --doctor --fix-all >/dev/null 2>&1 </dev/null
check "Fix everything adds the include line back (once)" "[ \$(grep -c 'include wm_calibration.cfg' $G2/printer_data/config/printer.cfg) = 1 ]"
echo '# my edit' >> "$G2/printer_data/config/wm_calibration.cfg"
check "doctor notices an edited wm_calibration.cfg" "eval \"$D\" 2>&1 | grep -q 'wm_calibration.cfg differs from the one in rpi-cfg'"
WM_HOME="$G2" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$ROOT/installer.sh" --doctor --fix-all >/dev/null 2>&1 </dev/null
check "the fix keeps the edited copy and restores the repository one" "grep -q 'my edit' $G2/printer_data/config/wm_calibration.cfg.wm-before-rpicfg-* && cmp $ROOT/rpi-cfg/wm_calibration.cfg $G2/printer_data/config/wm_calibration.cfg"
NB1=$(ls "$G2/printer_data/config" | grep -c "wm_calibration.cfg.wm-before")
WM_HOME="$G2" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$ROOT/installer.sh" --rpi-cfg > "$T/rc.out" 2>&1 </dev/null
check "--rpi-cfg runs, is idempotent, adds no second include" "grep -q 'wm_calibration.cfg is installed (printer.cfg already includes it)' $T/rc.out && [ \$(grep -c 'include wm_calibration.cfg' $G2/printer_data/config/printer.cfg) = 1 ]"
check "--rpi-cfg with nothing changed makes no extra copy of wm_calibration.cfg" "[ \$(ls $G2/printer_data/config/ | grep -c 'wm_calibration.cfg.wm-before') = $NB1 ]"
check "--rpi-cfg dry run changes nothing" "rm -f $G2/printer_data/config/wm_calibration.cfg; WM_HOME=$G2 WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --rpi-cfg --dry-run >/dev/null 2>&1 </dev/null; [ ! -f $G2/printer_data/config/wm_calibration.cfg ]"
WM_HOME="$G2" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$ROOT/installer.sh" --rpi-cfg >/dev/null 2>&1 </dev/null
check "--rpi-cfg restores a deleted file" "cmp $ROOT/rpi-cfg/wm_calibration.cfg $G2/printer_data/config/wm_calibration.cfg"
check "nozzle: wm_nozzle.cfg is installed and included, with its helper script" "cmp $ROOT/rpi-cfg/wm_nozzle.cfg $G2/printer_data/config/wm_nozzle.cfg && [ \$(grep -c '^\\[include wm_nozzle.cfg\\]' $G2/printer_data/config/printer.cfg) = 1 ] && cmp $ROOT/scripts/wm_nozzle.py $G2/printer_data/wm-tools/wm_nozzle.py"
check "nozzle: the shell command extension is there too" "[ -f $G2/klipper/klippy/extras/gcode_shell_command.py ]"
check "nozzle: doctor is happy with the helper script" "eval \"$D\" 2>&1 | grep -q 'wm_nozzle.py (the helper behind WM_NOZZLE_TYPE) is in place'"
rm -f "$G2/printer_data/wm-tools/wm_nozzle.py"
check "nozzle: doctor notices a missing helper script" "yes n | WM_HOME=$G2 WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --doctor 2>&1 | grep -q 'wm_nozzle.py is missing or different'"
WM_HOME="$G2" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$ROOT/installer.sh" --rpi-cfg >/dev/null 2>&1 </dev/null
check "nozzle: --rpi-cfg puts the helper script back" "cmp $ROOT/scripts/wm_nozzle.py $G2/printer_data/wm-tools/wm_nozzle.py"
NZ="$T/nz"; mkdir -p "$NZ"; cp "$ROOT/factory/ultra-s/config/printer.cfg" "$ROOT/factory/ultra-s/config/tmt1.ini" "$NZ/"
check "nozzle script: show lists the four nozzles" "[ \$(python3 $ROOT/scripts/wm_nozzle.py --config $NZ show | grep -c '0.400000 mm') = 4 ]"
check "nozzle script: set changes only that nozzle's diameter and the type in tmt1.ini" "python3 $ROOT/scripts/wm_nozzle.py --config $NZ set 1 0.6 1 | grep -q 'Restart Klipper' && [ \$(diff $NZ/printer.cfg $ROOT/factory/ultra-s/config/printer.cfg | grep -c '^<') = 1 ] && python3 $ROOT/scripts/wm_nozzle.py --config $NZ show | grep -q 'Nozzle 2 (tool T1, \\[extruder1\\]): 0.600000' && grep -q '^type1=1' $NZ/tmt1.ini && grep -q '^type0=0' $NZ/tmt1.ini"
check "nozzle script: a copy of printer.cfg and tmt1.ini is kept first" "ls $NZ/printer.cfg.wm-before-nozzle-* $NZ/tmt1.ini.wm-before-nozzle-* && cmp \$(ls $NZ/printer.cfg.wm-before-nozzle-* | head -1) $ROOT/factory/ultra-s/config/printer.cfg"
check "nozzle script: refuses a tool, a diameter and a type that make no sense" "! python3 $ROOT/scripts/wm_nozzle.py --config $NZ set 4 0.4 && ! python3 $ROOT/scripts/wm_nozzle.py --config $NZ set 0 7 && ! python3 $ROOT/scripts/wm_nozzle.py --config $NZ set 0 0.4 5 && ! python3 $ROOT/scripts/wm_nozzle.py --config $NZ set 0 abc"
check "nozzle script: refuses a tool this printer does not have" "cp $ROOT/factory/ultra-s/config-variants/printer2.cfg $NZ/p2.cfg; mkdir -p $NZ/two; cp $NZ/p2.cfg $NZ/two/printer.cfg; ! python3 $ROOT/scripts/wm_nozzle.py --config $NZ/two set 3 0.4 | grep -v refused"
check "nozzle script: the SAVE_CONFIG block of printer.cfg is unchanged" "[ \"\$(sed -n '/SAVE_CONFIG/,\$p' $NZ/printer.cfg)\" = \"\$(sed -n '/SAVE_CONFIG/,\$p' $ROOT/factory/ultra-s/config/printer.cfg)\" ]"
NZ2="$T/nz2"; mkdir -p "$NZ2"; { cat "$ROOT/factory/ultra-s/config/printer.cfg" | sed '$d'; printf '#*# [extruder1]\n#*# nozzle_diameter = 0.400000\n'; } > "$NZ2/printer.cfg"
check "nozzle script: a nozzle_diameter that sits in the SAVE_CONFIG block is changed there too" "python3 $ROOT/scripts/wm_nozzle.py --config $NZ2 set 1 0.8 >/dev/null && grep -q '^#\\*# nozzle_diameter = 0.800000' $NZ2/printer.cfg"
HNZ="$T/hnz"; mkdir -p "$HNZ"; inst "$HNZ" --from-github --model ultra-s --shell-command off >/dev/null
check "nozzle: with the shell command extension off, wm_nozzle.cfg is not installed or included" "[ ! -f $HNZ/printer_data/config/wm_nozzle.cfg ] && ! grep -q 'wm_nozzle' $HNZ/printer_data/config/printer.cfg"
check "nozzle: and the doctor does not ask for it" "! yes n | WM_HOME=$HNZ WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --doctor 2>&1 | grep -q 'wm_nozzle'"
inst "$HNZ" --update --shell-command on >/dev/null
check "nozzle: turning the extension on installs wm_nozzle.cfg and includes it" "[ -f $HNZ/printer_data/config/wm_nozzle.cfg ] && grep -q '^\\[include wm_nozzle.cfg\\]' $HNZ/printer_data/config/printer.cfg && [ -f $HNZ/klipper/klippy/extras/gcode_shell_command.py ]"
check "nozzle: removing the shell command extension takes wm_nozzle.cfg out of printer.cfg first" "M 'y\n' $HNZ --remove shell-command | grep -q 'Removed' && ! grep -q 'wm_nozzle.cfg' $HNZ/printer_data/config/printer.cfg && ls $HNZ/printer_data/config/wm_nozzle.cfg.wm-removed-* && [ ! -e $HNZ/klipper/klippy/extras/gcode_shell_command.py ]"
rm -f "$G2"/klipper/klippy/extras/cs1237.*.so
check "doctor finds a missing module and restores it from the repo" "WM_HOME=$G2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --doctor; ls $G2/klipper/klippy/extras/cs1237.*.so"
check "doctor reports bad network clock/power as problems" "! WM_TEST_THROTTLED=0x50005 WM_HOME=$G2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --doctor"
printf '[update_manager]\npassword: hunter2\nhost: 192.168.7.44\n' >> "$G2/printer_data/config/moonraker.conf"
WM_HOME="$G2" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --support-bundle >/dev/null 2>&1
SB="$(ls $G2/wm-support-*.tgz | head -1)"
check "support bundle made" "[ -f $SB ]"
check "support bundle has no password or private IP" "! tar xzOf $SB | grep -Eq 'hunter2|192\\.168\\.7\\.44'"
check "support bundle report has the USB tree and serial port sections" "tar xzOf $SB | grep -q \"usb tree\" && tar xzOf $SB | grep -q \"serial ports Klipper's python sees\""
check "support bundle has no calibration database or gcodes" "! tar tzf $SB | grep -Eq 'database|gcodes|\\.gcode'"

echo "== pre-flight"
check "no internet: install refused before changing anything" "! WM_TEST_NO_NET=1 WM_HOME=$T/pf WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --from-github --model ultra && [ ! -d $T/pf/klipper ]"
check "under-voltage is reported" "WM_TEST_THROTTLED=0x50005 WM_TEST_CANQUERY=$T/can_ok.txt inst $T/pf2 --from-github --model ultra | grep -q 'under-voltage'"

echo "== panel comes from the panel repository"
mkdir -p "$T/pnl"; python3 - "$T/pnl/fluidd-new.zip" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w"); z.writestr("index.html", "<html>NEWEST-PANEL</html>"); z.close()
PY
P1="$T/p1"; mkdir -p "$P1"; WM_TEST_PANEL_DIR="$T/pnl" inst "$P1" --from-github --model ultra --no-start > "$T/p1.out"
check "newest panel from the panel repository is installed" "grep -q NEWEST-PANEL $P1/fluidd/index.html && grep -q 'panel repository' $T/p1.out"
P2="$T/p2"; mkdir -p "$P2"; inst "$P2" --from-github --model ultra --no-start > "$T/p2.out"
check "default test panel installed" "grep -q -i fluidd $P2/fluidd/index.html"
P3="$T/p3"; mkdir -p "$P3"; WM_TEST_PANEL_DIR="$T/nonexistent" WM_HOME="$P3" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$ROOT/installer.sh" --from-github --model ultra --no-start > "$T/p3.out" 2>&1
check "panel download fails: install goes on, tells how to retry" "[ -d $P3/klipper/klippy ] && [ ! -f $P3/fluidd/index.html ] && grep -q 'installer.sh --update' $T/p3.out"
inst "$P2" --update > "$T/p2u.out"
check "update: panel already latest, nothing replaced" "grep -q 'already the latest' $T/p2u.out"
WM_TEST_PANEL_DIR="$T/pnl" inst "$P2" --update > "$T/p2v.out"
check "update: a changed panel in the panel repository is installed" "grep -q NEWEST-PANEL $P2/fluidd/index.html"

echo "== screen removal on the Pi"
printf 'y\n' | WM_HOME="$H3" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --screen-remove > "$T/rm.out" 2>&1
check "screen-remove: folder and service gone" "[ ! -d $H3/KlipperScreen ] && grep -q 'systemctl disable KlipperScreen' $H3/.sudo.log"
check "screen-remove: answers keep only the macros" "grep -q WANT_SCREEN=macros $H3/wm-rpi-backup/install.conf"
check "screen-remove: Klipper stays (macros kept)" "[ -f $H3/printer_data/config/zr_tools.cfg ] && [ -d $H3/klipper ]"

echo "== screen board script (factory screen as KlipperScreen)"
SB="$ROOT/scripts/screen_board.sh"
sb() { local h="$1"; shift; WM_TEST_SERVICES="${WM_TEST_SERVICES-makerbase-client klipper moonraker nginx crowsnest janus hostapd klipper-mcu makerbase-webcam}" WM_HOME="$h" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$SB" "$@" 2>&1; }
check "board script syntax" "bash -n $SB"
B1="$T/b1"; mkdir -p "$B1/printer_data/config"
sb "$B1" --pi wmpi.local > "$T/b1.out"
check "board: factory services stopped and disabled" "[ ! -e $B1/.svc/makerbase-client.active ] && [ ! -e $B1/.svc/klipper.enabled ] && [ ! -e $B1/.svc/nginx.enabled ]"
check "board: ssh/network services untouched (not in list)" "! grep -q 'systemctl stop ssh' $B1/.sudo.log"
check "board: previous state saved" "grep -q 'makerbase-client enabled active' $B1/wm-screen-backup/disabled.list"
check "board: KlipperScreen config points at the Pi" "grep -q 'moonraker_host: wmpi.local' $B1/printer_data/config/KlipperScreen.conf"
check "board: printer is named WonderMaker and the size defaults to comfortable" "grep -q '^\[printer WonderMaker\]' $B1/printer_data/config/KlipperScreen.conf && grep -q 'density = comfortable' $B1/printer_data/config/zr_screen.conf"
check "board: ZR Tools files copied" "[ -f $B1/KlipperScreen/panels/zr_tools.py ] && [ -f $B1/KlipperScreen/panels/zr_logic.py ]"
check "board: uses pinned KlipperScreen commit" "grep -q '34610ceae31e12a10cc980e20a1dec9976f97dd4' $B1/.sudo.log"

echo "== menu: Update now reopens the menu on the new version"
UN="$T/un"; mkdir -p "$UN/new" "$UN/home/printer_data/config" "$UN/bh/printer_data/config" "$UN/bh/KlipperScreen"
cp -a "$ROOT/." "$UN/new/"; rm -rf "$UN/new/.git"; echo 9.9.9 > "$UN/new/VERSION"
cp -a "$UN/new" "$UN/oldpi"; echo "$(cat $ROOT/VERSION)" > "$UN/oldpi/VERSION"
check "Pi menu: Update now with nothing installed still reopens on the new version" "printf '2\n2\ny\n0\n0\n' | WM_TEST_NO_FETCH=1 WM_HOME=$UN/home WM_INSTALLER_TEST=1 WM_TEST_UPDATE_DIR=$UN/new bash $UN/oldpi/installer.sh --menu 2>&1 | grep -q 'installer 9.9.9'"
cp -a "$UN/new" "$UN/oldb"; echo "$(cat $ROOT/VERSION)" > "$UN/oldb/VERSION"
check "board menu: Update now reopens on the new version even when there is nothing to back up" "printf '2\n2\ny\n0\n0\n' | WM_TEST_REFRESH_REPO=1 WM_HOME=$UN/bh WM_INSTALLER_TEST=1 WM_TEST_UPDATE_DIR=$UN/new bash $UN/oldb/scripts/screen_board.sh --menu 2>&1 | grep -q 'installer 9.9.9'"

check "board menu: Update now with no KlipperScreen updates the installer files and reopens on the new version" "rm -rf $UN/oldb2; cp -a $UN/new $UN/oldb2; echo 1.0.0 > $UN/oldb2/VERSION; printf '2\n2\ny\n0\n0\n' | WM_TEST_NO_KS=1 WM_TEST_REFRESH_REPO=1 WM_HOME=$UN/bh WM_INSTALLER_TEST=1 WM_TEST_UPDATE_DIR=$UN/new bash $UN/oldb2/scripts/screen_board.sh --menu 2>&1 | tee $UN/nok.out | grep -q 'installer 9.9.9' && grep -q 'not installed on this board yet' $UN/nok.out && ! grep -q \"Can't continue\" $UN/nok.out"
echo "== free up disk space (screen board)"
FSB="$T/fsb"; FST="$T/fst"; mkdir -p "$FSB/.cache/pip" "$FSB/printer_data/config" "$FSB/printer_data/logs" "$FSB/printer_data/gcodes" "$FST/tmp.AAA/scripts" "$FST/tmp.keep" "$FSB/wm-ultra-rpi"
dd if=/dev/zero of="$FSB/.cache/pip/x" bs=1M count=3 2>/dev/null; dd if=/dev/zero of="$FST/tmp.AAA/pad" bs=1M count=3 2>/dev/null
echo 1.0.0 > "$FST/tmp.AAA/VERSION"; touch "$FST/tmp.AAA/scripts/screen_board.sh"; echo mine > "$FST/tmp.keep/file"; echo gcode > "$FSB/printer_data/gcodes/a.gcode"
fsb() { local ans="$1"; shift; printf "$ans" | WM_TEST_TMP="$FST" WM_HOME="$FSB" WM_INSTALLER_TEST=1 WM_TEST_APT_KB=204800 WM_TEST_JOURNAL_KB=102400 "$@" bash "$SB" --free-space 2>&1; }
check "free space: lists what can go, with warnings and sizes" "fsb '\n' env | grep -q 'Leftover installer downloads' && fsb '\n' env | grep -q 'apt package cache' && fsb '\n' env | grep -q 'never in this list'"
check "free space: Enter cancels and erases nothing" "fsb '\n' env >/dev/null; [ -d $FST/tmp.AAA ] && [ -d $FSB/.cache/pip ]"
check "free space: answering no at the confirmation erases nothing" "fsb '1\nn\n' env | grep -q 'This will ERASE'; [ -d $FST/tmp.AAA ]"
check "free space: the warning is shown before the confirmation" "fsb '1\nn\n' env | grep -q 'Copies of this installer'"
check "free space: erases only the chosen item after confirming" "printf '1\ny\n' | WM_TEST_TMP=$FST WM_HOME=$FSB WM_INSTALLER_TEST=1 bash $SB --free-space >/dev/null 2>&1; [ ! -d $FST/tmp.AAA ] && [ -d $FST/tmp.keep ] && [ -d $FSB/.cache/pip ] && [ -f $FSB/printer_data/gcodes/a.gcode ]"
check "free space: tests never offer the real repository's .git for erasing" "fsb '\n' env | grep -qv 'Git history'"
check "free space: the git history is offered (and erased) only on a copy of the installer folder" "rm -rf $T/gcopy; mkdir -p $T/gcopy/wm-ultra-rpi/scripts; cp $SB $ROOT/scripts/lib_free_space.sh $T/gcopy/wm-ultra-rpi/scripts/; cp $ROOT/VERSION $T/gcopy/wm-ultra-rpi/; mkdir -p $T/gcopy/wm-ultra-rpi/.git; dd if=/dev/zero of=$T/gcopy/wm-ultra-rpi/.git/pack bs=1M count=3 2>/dev/null; printf 'all\ny\n' | WM_TEST_REFRESH_REPO=1 WM_TEST_TMP=$FST WM_HOME=$FSB WM_INSTALLER_TEST=1 bash $T/gcopy/wm-ultra-rpi/scripts/screen_board.sh --free-space > $T/gcopy.out 2>&1; grep -q 'Git history' $T/gcopy.out && [ ! -d $T/gcopy/wm-ultra-rpi/.git ] && [ -d $ROOT/.git ]"
check "free space: sudo items go through sudo (apt clean, journal vacuum)" "printf 'all\ny\n' | WM_TEST_TMP=$FST WM_HOME=$FSB WM_INSTALLER_TEST=1 WM_TEST_APT_KB=204800 WM_TEST_JOURNAL_KB=102400 bash $SB --free-space >/dev/null 2>&1; grep -q 'apt-get clean' $FSB/.sudo.log && grep -q 'vacuum-size=50M' $FSB/.sudo.log && [ ! -d $FSB/.cache/pip ] && [ -f $FSB/printer_data/gcodes/a.gcode ]"
check "free space: --yes alone never erases (confirmation defaults to no)" "mkdir -p $FSB/.cache/pip; dd if=/dev/zero of=$FSB/.cache/pip/x bs=1M count=3 2>/dev/null; WM_ASSUME_YES=1 WM_TEST_TMP=$FST WM_HOME=$FSB WM_INSTALLER_TEST=1 bash $SB --free-space >/dev/null 2>&1; [ -d $FSB/.cache/pip ]"
check "board Uninstall menu has Free up disk space" "printf '9\n0\n0\n' | WM_HOME=$FSB WM_INSTALLER_TEST=1 bash $SB --menu 2>&1 | grep -q 'Free up disk space'"
FSI="$T/fsi"; mkdir -p "$FSI/.cache/pip" "$FSI/printer_data/config"; dd if=/dev/zero of="$FSI/.cache/pip/x" bs=1M count=3 2>/dev/null
printf 'y\n1\ny\ny\n' | WM_TEST_FREE_OFFER=1 WM_TEST_DISK_MB=1499 WM_TEST_TMP=$FST WM_HOME=$FSI WM_INSTALLER_TEST=1 bash $SB --install --pi 192.0.2.5 --no-reboot > $T/fsi.out 2>&1
check "install: not enough space offers the cleanup, warns, then goes on" "grep -q 'Only 1499 MB free' $T/fsi.out && grep -q 'This will ERASE' $T/fsi.out && grep -q 'disk space' $T/fsi.out"
check "board script never calls a missing helper" "! grep -q 'command not found' $T/fsi.out"
check "install: still too little space after the cleanup stops with the --free-space hint" "printf 'n\n' | WM_TEST_FREE_OFFER=1 WM_TEST_DISK_MB=1000 WM_TEST_TMP=$FST WM_HOME=$T/fsi2 WM_INSTALLER_TEST=1 bash $SB --install --pi 192.0.2.5 --no-reboot 2>&1 | grep -q 'free-space'"
check "install: no terminal and not enough space stops without asking" "! WM_TEST_DISK_MB=1000 WM_HOME=$T/fsi3 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB --install --pi 192.0.2.5 --no-reboot >/dev/null 2>&1"

echo "== free up disk space (Pi installer)"
PFB="$T/pfb"; PFT="$T/pft"; mkdir -p "$PFB/.cache/pip" "$PFB/printer_data/logs" "$PFB/printer_data/gcodes" "$PFT/tmp.AAA/scripts" "$PFT/tmp.keep"
dd if=/dev/zero of="$PFB/.cache/pip/x" bs=1M count=3 2>/dev/null; dd if=/dev/zero of="$PFT/tmp.AAA/pad" bs=1M count=3 2>/dev/null
echo 1.0.0 > "$PFT/tmp.AAA/VERSION"; touch "$PFT/tmp.AAA/scripts/screen_board.sh"; echo mine > "$PFT/tmp.keep/file"; echo gcode > "$PFB/printer_data/gcodes/a.gcode"; echo old > "$PFB/printer_data/logs/klippy.log.1"; dd if=/dev/zero of="$PFB/printer_data/logs/klippy.log.1" bs=1M count=2 2>/dev/null
pfs() { local ans="$1"; shift; printf "$ans" | WM_TEST_NO_FETCH=1 WM_TEST_TMP="$PFT" WM_HOME="$PFB" WM_INSTALLER_TEST=1 WM_TEST_APT_KB=204800 WM_TEST_JOURNAL_KB=102400 "$@" bash "$ROOT/installer.sh" --free-space 2>&1; }
pfs '\n' env > $T/pfs1.out
check "Pi free space: lists what can go, with sizes and warnings" "grep -q 'Leftover installer downloads' $T/pfs1.out && grep -q 'apt package cache' $T/pfs1.out && grep -q 'Old rotated printer logs' $T/pfs1.out && grep -q 'never in this list' $T/pfs1.out"
check "Pi free space: Enter cancels and erases nothing" "[ -d $PFT/tmp.AAA ] && [ -d $PFB/.cache/pip ] && [ -f $PFB/printer_data/logs/klippy.log.1 ]"
pfs '1\nn\n' env > $T/pfs2.out
check "Pi free space: the warning and 'This will ERASE' come before the confirmation, and 'no' erases nothing" "grep -q 'This will ERASE' $T/pfs2.out && grep -q 'Copies of this installer' $T/pfs2.out && [ -d $PFT/tmp.AAA ]"
check "Pi free space: erases only the chosen item after confirming" "printf '1\ny\n' | WM_TEST_TMP=$PFT WM_HOME=$PFB WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --free-space >/dev/null 2>&1; [ ! -d $PFT/tmp.AAA ] && [ -d $PFT/tmp.keep ] && [ -d $PFB/.cache/pip ] && [ -f $PFB/printer_data/gcodes/a.gcode ]"
check "Pi free space: all goes through sudo for apt and the journal and keeps gcode files" "printf 'all\ny\n' | WM_TEST_TMP=$PFT WM_HOME=$PFB WM_INSTALLER_TEST=1 WM_TEST_APT_KB=204800 WM_TEST_JOURNAL_KB=102400 bash $ROOT/installer.sh --free-space >/dev/null 2>&1; grep -q 'apt-get clean' $PFB/.sudo.log && grep -q 'vacuum-size=50M' $PFB/.sudo.log && [ ! -d $PFB/.cache/pip ] && [ ! -f $PFB/printer_data/logs/klippy.log.1 ] && [ -f $PFB/printer_data/gcodes/a.gcode ] && [ -d $ROOT/.git ]"
check "Pi free space: --yes alone never erases" "mkdir -p $PFB/.cache/pip; dd if=/dev/zero of=$PFB/.cache/pip/x bs=1M count=3 2>/dev/null; WM_ASSUME_YES=1 WM_TEST_TMP=$PFT WM_HOME=$PFB WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --free-space >/dev/null 2>&1; [ -d $PFB/.cache/pip ]"
check "Pi free space: the git history is offered only on a copy of the installer folder" "rm -rf $T/pgcopy; mkdir -p $T/pgcopy/wm-ultra-rpi/.git; cp $ROOT/installer.sh $ROOT/VERSION $T/pgcopy/wm-ultra-rpi/; mkdir -p $T/pgcopy/wm-ultra-rpi/scripts; cp $ROOT/scripts/lib_free_space.sh $T/pgcopy/wm-ultra-rpi/scripts/; dd if=/dev/zero of=$T/pgcopy/wm-ultra-rpi/.git/pack bs=1M count=3 2>/dev/null; printf 'all\ny\n' | WM_TEST_REFRESH_REPO=1 WM_TEST_TMP=$PFT WM_HOME=$PFB WM_INSTALLER_TEST=1 bash $T/pgcopy/wm-ultra-rpi/installer.sh --free-space > $T/pgcopy.out 2>&1; grep -q 'Git history' $T/pgcopy.out && [ ! -d $T/pgcopy/wm-ultra-rpi/.git ] && [ -d $ROOT/.git ]; ! pfs '\n' env | grep -q 'Git history'"
check "Pi Uninstall menu has Free up disk space" "printf '6\n0\n0\n' | WM_TEST_NO_FETCH=1 WM_HOME=$PFB WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --menu 2>&1 | grep -q 'Free up disk space'"
check "Pi install: no terminal and not enough space stops with the --free-space hint" "WM_TEST_DISK_MB=1000 WM_HOME=$T/pfi1 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --from-github --model ultra-s 2>&1 </dev/null | grep -q 'free-space'"
mkdir -p "$T/pfi2/.cache/pip"; dd if=/dev/zero of="$T/pfi2/.cache/pip/x" bs=1M count=3 2>/dev/null
printf 'y\n1\ny\n' | WM_TEST_FREE_OFFER=1 WM_TEST_DISK_MB=2499 WM_TEST_TMP=$PFT WM_HOME=$T/pfi2 WM_INSTALLER_TEST=1 timeout 100 bash $ROOT/installer.sh --from-github --model ultra-s > $T/pfi2.out 2>&1
check "Pi install: not enough space offers the cleanup, warns, then goes on" "grep -q 'Only 2499 MB free' $T/pfi2.out && grep -q 'This will ERASE' $T/pfi2.out && grep -q 'Disk space ok' $T/pfi2.out"

echo "== ZR Tools on the Pi, and the clock fix"
mkpi() { local h="$1"; mkdir -p "$h/printer_data/config"; printf '[include mainsail.cfg]\n\n[save_variables]\nfilename: /tmp/v.cfg\n\n#*# <---- SAVE_CONFIG ---->\n' > "$h/printer_data/config/printer.cfg"; }
PZ="$T/pz"; mkpi "$PZ"
zr() { WM_TEST_NO_FETCH=1 WM_HOME="$PZ" WM_INSTALLER_TEST=1 "$@" bash "$ROOT/installer.sh" --zr-tools 2>&1; }
check "Pi --zr-tools: installs the macros when they are missing" "env | true; zr env | grep -q 'installed and configured' && [ -f $PZ/printer_data/config/zr_tools.cfg ] && grep -q '^\[include zr_tools.cfg\]' $PZ/printer_data/config/printer.cfg"
check "Pi --zr-tools: second run says already installed and changes nothing" "zr env | grep -q 'already installed' && [ \$(grep -c 'include zr_tools.cfg' $PZ/printer_data/config/printer.cfg) = 1 ]"
check "Pi --zr-tools: an edited zr_tools.cfg with every macro counts as installed and is kept" "echo '# mine' >> $PZ/printer_data/config/zr_tools.cfg; zr env | grep -q 'already installed' && grep -q '^# mine' $PZ/printer_data/config/zr_tools.cfg"
check "Pi --zr-tools: a zr_tools.cfg that lost a macro is replaced (old copy kept)" "sed -i '0,/^\\[gcode_macro ZR_/s//[gcode_macro NOT_ZR_/' $PZ/printer_data/config/zr_tools.cfg; zr env | grep -q 'installed and configured' && ls $PZ/printer_data/config/ | grep -q 'zr_tools.cfg.zrbak_'"
check "Pi --zr-tools: ZR_REPLACE=1 replaces an edited file with the bundled copy" "echo '# mine2' >> $PZ/printer_data/config/zr_tools.cfg; zr env ZR_REPLACE=1 | grep -q 'installed and configured' && ! grep -q '^# mine2' $PZ/printer_data/config/zr_tools.cfg"
PZ2="$T/pz2"; mkpi "$PZ2"; sed -i '/save_variables/,/^$/d' "$PZ2/printer_data/config/printer.cfg"
check "Pi --zr-tools: adds [save_variables] when no config file has one" "WM_TEST_NO_FETCH=1 WM_HOME=$PZ2 WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --zr-tools >/dev/null 2>&1; grep -q '^\[save_variables\]' $PZ2/printer_data/config/printer.cfg"
PZ3="$T/pz3"; mkpi "$PZ3"
check "Pi --zr-tools: refuses during a print and changes nothing" "WM_TEST_NO_FETCH=1 WM_TEST_PRINT_STATE=printing WM_HOME=$PZ3 WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --zr-tools 2>&1 | grep -q 'print is running'; [ ! -f $PZ3/printer_data/config/zr_tools.cfg ]"
check "Pi --zr-tools: without printer.cfg it explains and fails" "! WM_TEST_NO_FETCH=1 WM_HOME=$T/nopz WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --zr-tools >/dev/null 2>&1"
check "Pi --zr-tools --dry-run changes nothing" "PZ4=$T/pz4; mkdir -p \$PZ4/printer_data/config; cp $PZ3/printer_data/config/printer.cfg \$PZ4/printer_data/config/; WM_HOME=\$PZ4 WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --zr-tools --dry-run >/dev/null 2>&1; [ ! -f \$PZ4/printer_data/config/zr_tools.cfg ]"
check "Pi Add-ons menu lists the ZR Tools macros" "printf '3\n0\n0\n' | WM_TEST_NO_FETCH=1 WM_HOME=$PZ3 WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --menu 2>&1 | grep -q 'ZR Tools macros'"

BP="$T/bzp"; PIH="$T/pih"; mkpi "$PIH"; mkdir -p "$BP/printer_data/config"
zrp() { WM_TEST_PI_HOME="$PIH" WM_HOME="$BP" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 "$@" bash "$SB" --zr-pi --pi 192.0.2.5 2>&1; }
check "board --zr-pi: installs the macros on the Pi when missing" "zrp env | grep -q 'installed and configured on the Pi' && [ -f $PIH/printer_data/config/zr_tools.cfg ]"
check "board --zr-pi: second run says already installed" "zrp env | grep -q 'already installed on the Pi'"
check "board --zr-pi: Klipper on the Pi is restarted only after a change" "rm -f $BP/.sudo.log; zrp env >/dev/null; ! grep -q 'restart klipper on' $BP/.sudo.log"
check "board --zr-pi: a wrong password is explained" "zrp env WM_TEST_PI_PASS=wrong | grep -q 'refused the user name or password'"
check "board --zr-pi: a print on the Pi blocks it" "rm -rf $PIH/printer_data/config/zr_tools.cfg; zrp env WM_TEST_PI_PRINT_STATE=printing | grep -q 'not installed there'; [ ! -f $PIH/printer_data/config/zr_tools.cfg ]"
check "board --zr-pi: the password is never written to a file" "rm -f $PIH/printer_data/config/zr_tools.cfg; zrp env WM_TEST_PI_PASS=s3cretPW >/dev/null; ! grep -rqF s3cretPW $BP"
# install: the question defaults to no, yes runs it
BQ="$T/bq"; mkdir -p "$BQ/printer_data/config"; PIQ="$T/piq"; mkpi "$PIQ"
check "board install: the ZR Tools question defaults to no" "sb $BQ --pi 192.0.2.5 | grep -q 'ZR Tools page needs its macros on the Pi' && [ ! -f $PIQ/printer_data/config/zr_tools.cfg ]"
BQ2="$T/bq2"; mkdir -p "$BQ2/printer_data/config"
check "board install: answering yes sets up the macros on the Pi" "printf 'y\ny\ny\ny\ny\n' | WM_TEST_PI_HOME=$PIQ WM_HOME=$BQ2 WM_INSTALLER_TEST=1 bash $SB --install --pi 192.0.2.5 --no-reboot 2>&1 | grep -q 'installed and configured on the Pi' && [ -f $PIQ/printer_data/config/zr_tools.cfg ]"
check "board install --dry-run mentions ZR Tools on the Pi and changes nothing" "BQ3=$T/bq3; mkdir -p \$BQ3; sb \$BQ3 --pi 192.0.2.5 --dry-run | grep -q 'ZR Tools macros on the Pi'; [ ! -f $T/bq3/.sudo.log ] || ! grep -q 'timedatectl' $T/bq3/.sudo.log"
check "board install: turns on automatic time sync when the clock is not synced" "grep -q 'timedatectl set-ntp true' $B1/.sudo.log"
BC="$T/bc"; mkdir -p "$BC/printer_data/config"
check "free space: one shared file, loaded by both the Pi installer and the board" "[ -f $ROOT/scripts/lib_free_space.sh ] && grep -q 'lib_free_space.sh' $ROOT/installer.sh && grep -q 'lib_free_space.sh' $ROOT/scripts/screen_board.sh && ! grep -q '^fs_scan()' $ROOT/installer.sh $ROOT/scripts/screen_board.sh"
check "board clock: no curl -k anywhere" "! grep -q 'curl -sIk' $ROOT/scripts/screen_board.sh"
NB="$T/ntp1"; mkdir -p "$NB"
check "board clock: asks, remembers the yes, and does not ask again within the hour" "WM_HOME=$NB WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB --fix-clock >/dev/null 2>&1; [ -f $NB/.wm-ntp-asked ] && WM_HOME=$NB WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB --fix-clock 2>&1 | grep -q 'Not asking again'"
check "board clock: asks again after an hour" "echo 1 > $NB/.wm-ntp-asked; WM_HOME=$NB WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB --fix-clock 2>&1 | grep -q 'Automatic time sync is on'"
check "board --fix-clock: nothing to do when NTP is already synchronised" "WM_TEST_NTP_SYNCED=yes WM_HOME=$BC WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB --fix-clock 2>&1 | grep -q 'set automatically'; ! grep -q 'timedatectl' $BC/.sudo.log 2>/dev/null"
check "board --fix-clock: falls back to GitHub's date when NTP finds no server" "WM_TEST_NTP_FAIL=1 WM_HOME=$BC WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB --fix-clock >/dev/null 2>&1; grep -q 'date -s' $BC/.sudo.log"
check "board Settings menu has the ZR Tools and clock entries" "printf '5\n0\n0\n' | WM_HOME=$BC WM_INSTALLER_TEST=1 bash $SB --menu 2>&1 | grep -q 'Set up ZR Tools on the Pi' && printf '5\n0\n0\n' | WM_HOME=$BC WM_INSTALLER_TEST=1 bash $SB --menu 2>&1 | grep -q 'Fix the clock'"
check "board: installs with apt-get install --no-upgrade, never upgrade" "grep -q 'apt-get install -y --no-upgrade' $B1/.sudo.log && ! grep -q -E 'apt(-get)? (dist-)?upgrade' $B1/.sudo.log"
check "board: factory mode button prepared" "[ -f $B1/wm-screen-backup/board_mode ] && grep -q sudoers $B1/.sudo.log"
check "board: KlipperScreen service enabled and started" "[ -e $B1/.svc/KlipperScreen.enabled ] && [ -e $B1/.svc/KlipperScreen.active ]"
check "board: --status runs" "WM_HOME=$B1 WM_INSTALLER_TEST=1 bash $SB --status | grep -q 'Mode: KlipperScreen'"
sb "$B1" --factory-restore > "$T/b1r.out"
check "restore: factory services back (enabled)" "[ -e $B1/.svc/makerbase-client.enabled ] && [ -e $B1/.svc/klipper.enabled ] && [ -e $B1/.svc/nginx.enabled ]"
check "restore: KlipperScreen gone" "[ ! -d $B1/KlipperScreen ] && [ ! -e $B1/.svc/KlipperScreen.enabled ] && [ ! -f $B1/wm-screen-backup/board_mode ]"
check "restore: reboots" "grep -q 'systemctl reboot' $B1/.sudo.log"
check "restore: list archived" "ls $B1/wm-screen-backup/disabled.list.restored-* >/dev/null"
B2="$T/b2"; mkdir -p "$B2"
check "board: never contacts the Pi (no Pi check in the script)" "! grep -q 'pi_ok\|klippy_connected' $SB"
check "board: refuses while printing" "! WM_TEST_PRINTING=1 WM_TEST_SERVICES='klipper' WM_HOME=$B2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB --pi wmpi.local"
check "board: refuses when apt is broken" "! WM_TEST_APT_OK=0 WM_TEST_SERVICES='klipper' WM_HOME=$B2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB --pi wmpi.local"
check "board: temporary swap added when RAM is small, none when RAM is big" "grep -q wm-tmp-swap $B1/.sudo.log && WM_TEST_MEM_MB=2000 WM_TEST_SERVICES=klipper WM_HOME=$T/b7 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB --pi x >/dev/null 2>&1; ! grep -q wm-tmp-swap $T/b7/.sudo.log"
check "board: --set-pi rewrites the address and restarts KlipperScreen" "mkdir -p $T/b8/printer_data/config && printf '[printer wmpi]\nmoonraker_host: old.local\n' > $T/b8/printer_data/config/KlipperScreen.conf && WM_HOME=$T/b8 WM_INSTALLER_TEST=1 bash $SB --set-pi 192.0.2.7 >/dev/null 2>&1 && grep -q 'moonraker_host: 192.0.2.7' $T/b8/printer_data/config/KlipperScreen.conf && grep -q 'restart KlipperScreen' $T/b8/.sudo.log"
check "board: --set-pi refuses a bad address" "! WM_HOME=$T/b8 WM_INSTALLER_TEST=1 bash $SB --set-pi 'a b;rm' >/dev/null 2>&1"
check "board: Wi-Fi panel replaces the stock Network panel (wpa_cli, no NetworkManager)" "grep -q wifi_panel.py $SB && grep -q wpa_cli $ROOT/zr_tools/wifi_panel.py && ! grep -q sdbus $ROOT/zr_tools/wifi_panel.py"
check "board: with no --pi and no terminal it stops and asks for the Pi address" "! WM_HOME=$B2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB --dry-run >$T/nopi.out 2>&1 </dev/null && grep -q 'no Pi address' $T/nopi.out"
check "board: Pi address and Wi-Fi pages are installed and in the menus" "grep -q pi_address_panel.py $SB && grep -q 'menu __splashscreen pi_address' $SB && grep -q 'menu __main more pi_address' $SB"
B3="$T/b3"; mkdir -p "$B3/printer_data/config"
WM_TEST_KS_OK=fbdev sb "$B3" --pi 10.0.0.5 > "$T/b3.out"
check "board: X falls back to fbdev when modesetting does not start" "[ -e $B3/.fbdev ] && grep -q 'fbdev' $T/b3.out"
B4="$T/b4"; mkdir -p "$B4/printer_data/config"; sb "$B4" --pi wmpi.local --dry-run > "$T/b4.out"
check "board: dry run changes nothing" "[ ! -d $B4/KlipperScreen ] && [ ! -s $B4/.sudo.log ] && grep -q 'would run' $T/b4.out"
B5="$T/b5"; mkdir -p "$B5/printer_data/config"; sb "$B5" --pi wmpi.local >/dev/null; printf 'y\n' | WM_HOME="$B5" WM_INSTALLER_TEST=1 bash "$SB" --uninstall-klipperscreen > "$T/b5u.out" 2>&1
check "board uninstall-klipperscreen: removes it AND re-enables the factory services" "[ ! -d $B5/KlipperScreen ] && [ -e $B5/.svc/makerbase-client.enabled ] && [ -e $B5/.svc/klipper.enabled ] && [ -e $B5/.svc/moonraker.enabled ]"

echo "== screen rescue tool (window after 3 failed starts, USB flag)"
RS="$ROOT/screen_rescue/wm-screen-rescue"
check "rescue: scripts have valid syntax" "bash -n $RS && python3 -m py_compile $ROOT/screen_rescue/wm-rescue-window.py; rm -rf $ROOT/screen_rescue/__pycache__"
check "rescue: KlipperScreen unit stops retrying after 3 starts in 2 minutes and opens the rescue window" "grep -q 'StartLimitIntervalSec=120' $SB && grep -q 'StartLimitBurst=3' $SB && grep -q 'OnFailure=wm-screen-rescue.service' $SB"
check "rescue: the rescue unit replaces KlipperScreen (Conflicts)" "grep -q 'Conflicts=KlipperScreen.service' $SB"
RB="$T/rb"; mkdir -p "$RB/home/wm-screen-backup" "$RB/home/printer_data/config" "$RB/usb"
touch "$RB/wm-factory-restore"; chmod +x "$RB/wm-factory-restore"
rs() { WM_FACTORY_BIN="${FB:-$RB/wm-factory-restore}" WM_HOME="$RB/home" WM_RESCUE_LOG="$RB/log" WM_RESCUE_DRY=1 WM_RESCUE_TEST=1 WM_RESCUE_REASON_FILE="$RB/reason" WM_RESCUE_MEDIA_DIR="$RB/usb" bash "$RS" "$@" 2>&1; }
printf '[printer wmpi]\nmoonraker_host: 192.0.2.50\n' > "$RB/home/printer_data/config/KlipperScreen.conf"
touch "$RB/usb/WM-FACTORY"; rs usb-check >/dev/null
check "rescue usb: in factory mode (KlipperScreen not installed) the stick is ignored" "[ -f $RB/usb/WM-FACTORY ] && ! grep -q 'USB: WM' $RB/log"
echo "KlipperScreen on screen board" > "$RB/home/wm-screen-backup/board_mode"
rs usb-check >/dev/null
check "rescue usb: WM-FACTORY without a saved service list still restores (built-in list), flag renamed, reason written to the stick" "[ -f $RB/usb/WM-FACTORY.done ] && grep -q 'built-in list' $RB/usb/WM-RESCUE-LOG.txt && grep -q 'starting the factory restore' $RB/log"
rm -f "$RB/usb/"*; echo "makerbase-client enabled active" > "$RB/home/wm-screen-backup/disabled.list"; touch "$RB/usb/wm-factory"
rs usb-check >/dev/null
check "rescue usb: WM-FACTORY (any letter case) with a saved list starts the restore, renames the flag, writes a log, saves the settings" "[ -f $RB/usb/wm-factory.done ] && grep -q 'factory restore starts now' $RB/usb/WM-RESCUE-LOG.txt && grep -q 'starting the factory restore' $RB/log && grep -q 'factory-restore --yes --detach' $RB/log && ls $RB/home/wm-screen-backup/rescue-snapshots/*/KlipperScreen.conf >/dev/null"
rm -f "$RB/usb/"*; touch "$RB/usb/WM-RESCUE"; rs usb-check >/dev/null
check "rescue usb: WM-RESCUE opens the window (reason usb) and is renamed" "[ -f $RB/usb/WM-RESCUE.done ] && grep -q 'systemctl start --no-block wm-screen-rescue.service' $RB/log && [ \"\$(cat $RB/reason)\" = usb ]"
rm -f "$RB/usb/"* "$RB/log"; touch "$RB/usb/readme.txt"; rs usb-check >/dev/null
check "rescue usb: a stick without a flag does nothing" "[ ! -s $RB/log ] || ! grep -q 'USB: starting\|USB: opening' $RB/log"
check "rescue act: factory restore without the restore script restores the 8 factory services itself" "rm -f $RB/home/wm-screen-backup/disabled.list; FB=/nonexistent rs act factory > $T/rsf.out; for u in makerbase-client moonraker nginx klipper-mcu crowsnest makerbase-webcam; do grep -q \"systemctl enable \$u\" $RB/log || exit 1; done; ! grep -q 'systemctl enable klipper\$' $RB/log && ! grep -q 'enable hostapd' $RB/log && grep -q 'systemctl reboot' $RB/log"
check "rescue: the built-in factory list is identical in the installer and in the rescue tool" "[ \"\$(sed -n '/^FACTORY_DEFAULT=/,/\"\$/p' $SB | sed 's/^FACTORY_DEFAULT=//')\" = \"\$(sed -n '/^FACTORY_DEFAULT=/,/\"\$/p' $RS | sed 's/^FACTORY_DEFAULT=//')\" ]"
BM="$T/bm"; mkdir -p "$BM/printer_data/config"; sb "$BM" --pi wmpi.local >/dev/null; rm -f "$BM/wm-screen-backup/disabled.list"; sb "$BM" --factory-restore > "$T/bm.out"
check "board restore without a saved list uses the built-in factory list and turns the services back on" "grep -q 'built-in list' $T/bm.out && [ -e $BM/.svc/makerbase-client.enabled ] && [ -e $BM/.svc/moonraker.enabled ] && [ ! -d $BM/KlipperScreen ]"
echo "makerbase-client enabled active" > "$RB/home/wm-screen-backup/disabled.list"
check "rescue act: factory restore keeps the Pi address first and runs the detached restore" "rs act factory | grep -q 'Pi address: 192.0.2.50' && grep -q 'wm-factory-restore --factory-restore --yes --detach' $RB/log"
check "rescue act: restart clears the failed state and starts KlipperScreen" "rs act restart-ks >/dev/null; grep -q 'systemctl reset-failed KlipperScreen' $RB/log && grep -q 'systemctl start KlipperScreen' $RB/log"
check "rescue act: reset settings needs the saved defaults, keeps the Pi address" "rs act reset-settings | grep -q 'No saved default'; mkdir -p $RB/home/wm-screen-backup/known-good && cp $RB/home/printer_data/config/KlipperScreen.conf $RB/home/wm-screen-backup/known-good/ && rs act reset-settings | grep -q 'Pi address'"
check "rescue act: reinstall needs the saved copy" "rs act reinstall-files | grep -q 'No saved copy'"
check "rescue act: factory restore reports its steps for the progress bar" "rs act factory | grep -q '^STEP 1/4 Saving' && rs act factory | grep -q '^STEP 4/4'"
check "rescue act: reset settings and reinstall report their steps" "mkdir -p $RB/home/wm-screen-backup/known-good && cp $RB/home/printer_data/config/KlipperScreen.conf $RB/home/wm-screen-backup/known-good/ && rs act reset-settings | grep -q '^STEP 4/4 Restarting' && rs act reinstall-files | grep -q '^STEP 1/4 Checking'"
check "rescue window: every action asks first, and the long ones show a progress bar" "W=$ROOT/screen_rescue/wm-rescue-window.py; for a in 'restart-ks' 'reboot' 'factory' 'reset-settings' 'reinstall-files'; do grep -q \"\\\"\$a\\\"\" \$W || exit 1; done; grep -c 'self.ask(' \$W | grep -q '^[4-9]' && grep -q 'run_with_progress(\"factory\"' \$W && grep -q 'run_with_progress(\"reset-settings\"' \$W && grep -q 'run_with_progress(\"reinstall-files\"' \$W && grep -q 'Gtk.ProgressBar' \$W"
check "rescue: snapshots are handed to the board user" "grep -q 'chown -R \"\$WM_USER:\" \"\$SNAP\"' $ROOT/screen_rescue/wm-screen-rescue"
check "rescue act: reason texts" "rs act reason manual | grep -q 'by hand' && rs act reason usb | grep -q WM-RESCUE && rs act reason failed | grep -q '3 times'"
check "rescue: manual open writes the reason and starts the window" "rs open >/dev/null; grep -q manual $RB/reason && grep -q 'wm-screen-rescue.service' $RB/log"
BR="$T/br"; mkdir -p "$BR/printer_data/config"; sb "$BR" --pi wmpi.local > "$T/br.out"
F="$ROOT/usb_flags"
check "usb_flags folder: both flag files empty, each zip holds exactly one file, README links it" "[ -e $F/WM-FACTORY ] && [ ! -s $F/WM-FACTORY ] && [ -e $F/WM-RESCUE ] && [ ! -s $F/WM-RESCUE ] && [ \"\$(unzip -Z1 $F/wm-factory-flag.zip)\" = WM-FACTORY ] && [ \"\$(unzip -Z1 $F/wm-rescue-flag.zip)\" = WM-RESCUE ] && grep -q '(usb_flags/)' $ROOT/README.md"
BX="$T/bx"; mkdir -p "$BX/printer_data/config"; sb "$BX" --pi wmpi.local --no-reboot > "$T/bx.out"
check "board install: reboots at the end, unless --no-reboot" "grep -q 'systemctl reboot' $BR/.sudo.log && ! grep -q 'systemctl reboot' $BX/.sudo.log"
check "board install: rescue tool installed (defaults saved, program copy, units)" "grep -q 'rescue tool' $BR/.sudo.log && [ -f $BR/wm-screen-backup/known-good/KlipperScreen.conf ] && [ -s $BR/wm-screen-backup/ks-program.tar.gz ]"
check "board --status shows the rescue tool" "WM_HOME=$BR WM_INSTALLER_TEST=1 bash $SB --status | grep -q 'Rescue tool: installed'"
sb "$BR" --factory-restore >/dev/null
check "board restore removes the rescue tool and its copies (only the backup list stays archived)" "grep -q 'remove rescue tool' $BR/.sudo.log && [ ! -d $BR/wm-screen-backup/known-good ] && [ ! -e $BR/wm-screen-backup/ks-program.tar.gz ]"
BN="$T/bn"; mkdir -p "$BN/printer_data/config"; sb "$BN" --pi wmpi.local --no-rescue > "$T/bn.out"
check "board install --no-rescue: no rescue tool" "! grep -q 'rescue tool' $BN/.sudo.log && [ ! -d $BN/wm-screen-backup/known-good ]"
check "rescue: the ZR Tools System page has a Rescue tile on the board" "grep -q '_sys_rescue' $ROOT/zr_tools/zr_views.py && grep -q 'sudoers' $SB"
B6="$T/b6"; mkdir -p "$B6/printer_data/config"; sb "$B6" --pi wmpi.local >/dev/null; sb "$B6" --pi wmpi.local >/dev/null
check "board: running twice keeps the ORIGINAL saved state" "grep -q 'makerbase-client enabled active' $B6/wm-screen-backup/disabled.list"

echo "== screen board pre-check (runs on the Mac)"
PC="$ROOT/scripts/screen_board_precheck.sh"; mkdir -p "$T/pc"
check "precheck syntax" "bash -n $PC"
check "precheck reads package and service lists from screen_board.sh" "(cd $T/pc && bash $PC --local-test | grep -q SUMMARY)"
check "precheck writes a scrubbed report" "ls $T/pc/screen_board_precheck_*.txt >/dev/null && ! grep -q TM88888 $T/pc/screen_board_precheck_*.txt"
check "precheck is read-only (no sudo, no service changes in its code)" "! grep -E 'systemctl (stop|start|disable|enable|restart)|apt-get (install|upgrade|remove)[^|]*[^s] ' $PC | grep -v -E '^[[:space:]]*#|-s install|Still to do|sudo systemctl' | grep -q ."
check "precheck needs a board address" "! bash $PC"
echo "== Mac preflight script"
PF="$ROOT/scripts/screen_board_preflight_mac.sh"
check "preflight syntax" "bash -n $PF"
check "preflight needs the board address" "! bash $PF"
WM_REPORT="$T/pf2.txt" bash "$PF" --local-test > "$T/pf2.out" 2>&1
check "preflight has no Pi checks" "! grep -qi 'Pi Moonraker\\|Pi checks' $T/pf2.out"
WM_REPORT="$T/pf3.txt" bash "$PF" --local-test --pi 127.0.0.1 > "$T/pf3.out" 2>&1
WM_REPORT="$T/pf.txt" bash "$PF" --local-test --pi 127.0.0.1 > "$T/pf.out" 2>&1; PFRC=$?
check "preflight runs all sections and gives a verdict" "grep -q 'On the screen board' $T/pf.out && grep -q 'Verdict' $T/pf.out && [ -s $T/pf.txt ]"
check "preflight says NOT READY on a machine that is not the board" "[ $PFRC = 1 ] && grep -q 'NOT READY' $T/pf.out"
remote_part() { awk '/read -r -d .. REMOTE/{f=1} f{print} /^RSH/{f=0}' "$PF" | grep -v 'apt-get -s'; }
check "preflight read-only part has no write/install commands" "! remote_part | grep -E 'apt-get (install|upgrade)|rm -rf|systemctl (stop|disable|start|enable)|dpkg -i'"
check "preflight read-only part is not empty" "[ \$(remote_part | wc -l) -gt 50 ]"

# --- Klippain Shake&Tune add-on and remote-access questions removed from the install ---
mkstage "$T/stage_hk"; HK="$T/hk"; mkdir -p "$HK"; inst "$HK" --from-stage "$T/stage_hk" --screen off >/dev/null
check "--shaketune needs on or off" "! bash $ROOT/installer.sh --shaketune maybe"
check "--help mentions --shaketune" "bash $ROOT/installer.sh --help | grep -q shaketune"
check "shaketune is pinned" "grep -q '^shaketune|https://github.com/Frix-x/klippain-shaketune|[0-9a-f]\\{40\\}' $ROOT/config/pins/addons.txt"
printf "[server]\n" > "$HK/printer_data/config/moonraker.conf"; : > "$HK/.sudo.log"
OUT="$(inst "$HK" --update --shaketune on)"
check "--shaketune on installs the extension link and config" "[ -L $HK/klipper/klippy/extras/shaketune ] && [ -f $HK/printer_data/config/shaketune.cfg ]"
check "--shaketune on adds include and update manager, with a printer.cfg copy" "grep -q 'include shaketune.cfg' $HK/printer_data/config/printer.cfg && grep -q 'Klippain-ShakeTune' $HK/printer_data/config/moonraker.conf && ls $HK/printer_data/config/printer.cfg.wm-before-shaketune-* >/dev/null"
check "--shaketune on restarts klipper (once) at the end, because it was running" "[ \$(grep -c 'restart klipper' $HK/.sudo.log) -eq 1 ]"
check "--shaketune is remembered" "grep -rq 'WANT_SHAKETUNE=1' $HK/wm-rpi-backup"
check "--remove shaketune removes it" "M 'y\\n' $HK --remove shaketune | grep -q 'removed' && [ ! -e $HK/klipper/klippy/extras/shaketune ] && ! grep -q 'shaketune.cfg' $HK/printer_data/config/printer.cfg"
OUT="$(inst "$T/hq" --dry-run --from-stage "$T/stage_hk" --model ultra-s --screen off)"
check "the plan shows Shake&Tune" "echo \"\$OUT\" | grep -qi 'shake&tune'"
check "the install does not ask about Obico, OctoApp or OctoEverywhere" "! M '\\n\\n\\n\\n\\n' $T/hq2 --dry-run | grep -qi 'Do you want.*\\(obico\\|octoapp\\|octoeverywhere\\)'"

# --- empty canbus_uuid (factory files) must not cause "Duplicate canbus_uuid" ---
mkstage "$T/stage_cu"; CUU="$T/cuu"; mkdir -p "$CUU"; inst "$CUU" --from-stage "$T/stage_cu" --screen off >/dev/null
for n in 0 1 2 3; do printf '[mcu T%s]\ncanbus_uuid:%s\n' $n "$([ $n = 1 ] && echo ' ')" > "$CUU/printer_data/config/wm_zru_thr$n.cfg"; done
printf '[mcu CELL]\ncanbus_uuid:\n' > "$CUU/printer_data/config/wm_zru_load_cell.cfg"
printf '[mcu]\ncanbus_uuid: aa0000000000\n' > "$CUU/printer_data/config/wm_zru_mcu.cfg"
M '\n' $CUU --first-start >/dev/null 2>&1
dups() { cat $CUU/printer_data/config/wm_zru_*.cfg | grep -i canbus_uuid | sed 's/ //g' | sort | uniq -d; }
check "empty canbus_uuid in T0-T3 and the load cell get unique placeholders" "[ -z \"\$(dups)\" ] && grep -q 'canbus_uuid: b20000000000' $CUU/printer_data/config/wm_zru_thr2.cfg && grep -q 'canbus_uuid: b40000000000' $CUU/printer_data/config/wm_zru_load_cell.cfg"
check "the old files are kept" "ls $CUU/wm-rpi-backup/uuid-*/wm_zru_thr0.cfg"
check "a real uuid is never overwritten" "grep -q 'aa0000000000' $CUU/printer_data/config/wm_zru_mcu.cfg"

# --- add-on install from the menu touches only that add-on ---
OA="$T/oa"; mkdir -p "$OA"; inst "$OA" --from-stage "$T/stage_hk" --screen off >/dev/null; : > "$OA/.sudo.log"
OUT="$(inst "$OA" --update --only-addon shaketune --shaketune on)"
check "add-on only: Shake&Tune is installed" "[ -L $OA/klipper/klippy/extras/shaketune ]"
check "add-on only: no system packages, nginx, can0 rule or panel work" "! grep -E 'nginx|can0|python3-|klippy-requirements' $OA/.sudo.log"
check "add-on only says so" "echo \"\$OUT\" | grep -q 'Only this add-on'"
check "full update still updates everything" "inst $OA --update | grep -q 'Updated: services, nginx'"

# --- backup before update, Status, Network and system, Spoolman ---
echo "== 1.15.1 fixes"
HR="$G1"; mkdir -p "$HR/crowsnest"
OUT="$(inst "$HR" --doctor)"
check "doctor: no camera means the webcam service waits, not a problem" "echo \"$OUT\" | grep -q 'waiting for a camera'"
OUT="$(WM_TEST_CAMERA=1 inst "$HR" --doctor)"
check "doctor: camera plugged in but service not running is a problem" "echo \"$OUT\" | grep -q 'camera is plugged in but the webcam service is not running'"
check "status: webcam row says waiting for a camera" "inst $HR --status | grep -q 'waiting for a camera'"
check "menu: Check and fix has Fix everything" "M '4\n0\n0\n' $HR --menu | grep -q 'Fix everything'"
check "--doctor --fix-all explains and asks once" "inst $HR --doctor --fix-all | grep -q 'Fix everything: every problem'"
check "hostname: /etc/hosts is changed before hostnamectl" "awk '/^do_set_hostname/,/^}/' $ROOT/installer.sh | grep -n 'sed -i\|hostnamectl' | head -2 | head -1 | grep -q 'sed -i'"
check "klipper wait stops early on error" "grep -qF -e '-ge 2' $ROOT/installer.sh"
check "system files are removed quietly" "grep -q 'not loaded' $ROOT/installer.sh"
check "info line mentions Spoolman" "grep -q 'Shake&Tune and Spoolman are not part' $ROOT/installer.sh"

echo "== backup before update / status / system page / Spoolman"
mkstage "$T/stage_ns"; NS="$T/ns"; mkdir -p "$NS"; inst "$NS" --from-stage "$T/stage_ns" --screen off >/dev/null
printf "[server]\n" > "$NS/printer_data/config/moonraker.conf"; printf "klippy_apis/printer/restart\nSpoolman_x\n" > "$NS/printer_data/moonraker.asvc"
inst "$NS" --update >/dev/null
check "--update saves a backup first" "ls $NS/wm-backups/wm-backup-*-before-update-*.tgz"
check "the backup holds the config" "tar tzf \$(ls $NS/wm-backups/*before-update*.tgz | head -1) | grep -q printer_data/config/printer.cfg"
check "the backup before an update holds TM_T1/factory_settings" "tar tzf \$(ls $NS/wm-backups/*before-update*.tgz | head -1) | grep -q TM_T1/factory_settings"
for i in 1 2 3 4 5 6 7; do touch -d "2020-01-0$i" "$NS/wm-backups/wm-backup-ultra-s-before-update-2020010$i.tgz"; done
inst "$NS" --update >/dev/null
check "only the newest 5 automatic backups are kept" "[ \$(ls $NS/wm-backups/*before-update*.tgz | wc -l) -le 5 ]"
rm -f $NS/wm-backups/*; inst "$NS" --update --no-backup >/dev/null
check "--no-backup skips it" "[ -z \"\$(ls $NS/wm-backups 2>/dev/null)\" ]"
inst "$NS" --update --only-addon shaketune --shaketune on >/dev/null
check "an add-on install saves a backup too" "ls $NS/wm-backups/*before-update*.tgz"
OUT="$(inst "$NS" --status)"
check "--status shows services, add-ons and CAN ids" "echo \"$OUT\" | grep -q 'Status (changes nothing)' && echo \"$OUT\" | grep -q 'Add-ons:' && echo \"$OUT\" | grep -q 'CAN ids in the config' && echo \"$OUT\" | grep -q 'spoolman'"
check "--status changes nothing" "[ -z \"\$(ls $NS/wm-install-logs 2>/dev/null)\" ]"
check "--system-info shows host name and time zone" "inst $NS --system-info | grep -q 'Host name' && inst $NS --system-info | grep -q 'Time zone'"
check "--set-hostname refuses a bad name" "! inst $NS --set-hostname 'Bad Name!'"
: > "$NS/.sudo.log"; M 'n\n' $NS --set-hostname newname >/dev/null; check "--set-hostname asks first (default no)" "! grep -q hostnamectl $NS/.sudo.log"
M 'y\n' $NS --set-hostname newname >/dev/null; check "--set-hostname changes it after yes" "grep -q 'hostnamectl set-hostname newname' $NS/.sudo.log"
M 'y\n' $NS --set-timezone America/Toronto >/dev/null; check "--set-timezone changes it after yes" "grep -q 'timedatectl set-timezone America/Toronto' $NS/.sudo.log"
check "menu: Check and fix has Status, Advanced has Network and system, Add-ons has Spoolman" "M '4\n0\n0\n' $NS --menu | grep -q 'Status' && M '7\n0\n0\n' $NS --menu | grep -q 'Network and system' && M '3\n0\n0\n' $NS --menu | grep -q 'Spoolman'"
check "--help mentions the new options" "bash $ROOT/installer.sh --help | grep -q -- '--spoolman' && bash $ROOT/installer.sh --help | grep -q -- '--status' && bash $ROOT/installer.sh --help | grep -q -- '--set-timezone'"
check "--spoolman needs on or off" "! bash $ROOT/installer.sh --spoolman maybe"
inst "$NS" --update --only-addon spoolman --spoolman on >/dev/null
check "Spoolman: folder, service step, [spoolman] and update entry, service name in asvc" "[ -d $NS/Spoolman ] && grep -q '^\[spoolman\]' $NS/printer_data/config/moonraker.conf && grep -q 'update_manager Spoolman' $NS/printer_data/config/moonraker.conf && grep -qx Spoolman $NS/printer_data/moonraker.asvc && grep -q 'spoolman install.sh' $NS/.sudo.log"
check "Spoolman is remembered and shown in the plan" "grep -q 'WANT_SPOOLMAN=1' $NS/wm-rpi-backup/install.conf && inst $NS --dry-run --update | grep -qi spoolman"
mkdir -p "$NS/.local/share/spoolman"; echo db > "$NS/.local/share/spoolman/spoolman.db"
check "--remove spoolman asks first and keeps everything on no" "M 'n\n' $NS --remove spoolman | grep -q 'Nothing changed' && [ -d $NS/Spoolman ]"
check "--remove spoolman removes it, drops its config sections, keeps the database" "M 'y\nn\n' $NS --remove spoolman | grep -q 'Spoolman removed' && [ ! -e $NS/Spoolman ] && ! grep -q 'spoolman' $NS/printer_data/config/moonraker.conf && ! grep -qx Spoolman $NS/printer_data/moonraker.asvc && [ -f $NS/.local/share/spoolman/spoolman.db ]"

echo "== ACE Pro (install question, add-on, doctor, removal)"
STUBACE="$T/acestub"; mkdir -p "$STUBACE/extras/ace" "$STUBACE/config"; echo VERSION > /dev/null; echo 9.9.9 > "$STUBACE/VERSION"; mkdir -p "$STUBACE/.git"
cat > "$STUBACE/installer.sh" <<'STUBEOF'
#!/bin/bash
# stands in for wm-ultra-fluidd-acepro-panel's installer.sh (same options and files, no questions beyond the uninstall one)
echo "$1 home=$ACE_INSTALL_HOME test=$ACE_INSTALLER_TEST" >> "$ACE_INSTALL_HOME/.ace-stub.log"
cfg="$ACE_CONFIG_DIR"; x="$ACE_KLIPPER_DIR/klippy/extras"; here="$(cd "$(dirname "$0")" && pwd)"
case "$1" in
  --install|--update)
    for f in wm_ace_driver wm_ace wm_endless wm_stats; do echo "# $f" > "$cfg/$f.cfg"; grep -q "^\[include $f.cfg\]" "$cfg/printer.cfg" || sed -i "1i [include $f.cfg]" "$cfg/printer.cfg"; done
    echo 'VERSION="9.9.9"' > "$cfg/wm-ultra-install.conf"; ln -sfn "$here/extras/ace" "$x/ace"; mkdir -p "$ACE_INSTALL_HOME/acepro-backup/wm-1" ;;
  --uninstall)
    read -r a; [ "$a" = y ] || exit 0
    sed -i -E '/^\[include wm_(ace_driver|ace|endless|stats)\.cfg\]/d' "$cfg/printer.cfg"; rm -f "$cfg"/wm_ace_driver.cfg "$cfg"/wm_ace.cfg "$cfg"/wm_endless.cfg "$cfg"/wm_stats.cfg "$cfg/wm-ultra-install.conf" "$x/ace" ;;
esac
STUBEOF
chmod +x "$STUBACE/installer.sh"; export WM_TEST_ACEPRO_SRC="$STUBACE"
check "--acepro needs on or off" "! bash $ROOT/installer.sh --acepro maybe"
check "--help mentions --acepro" "bash $ROOT/installer.sh --help | grep -q -- '--acepro'"
OUTA="$(inst "$T/hqa" --dry-run --from-stage "$T/stage_hk" --model ultra-s --screen off)"
check "the install plan lists the ACE Pro as not chosen (default no) and the install asks about it" "grep -q 'Do you have an Anycubic ACE Pro to connect' $ROOT/installer.sh && echo \"\$OUTA\" | grep -E 'ace pro +no \\(add later'"
OUTA="$(inst "$T/hqa2" --dry-run --from-stage "$T/stage_hk" --model ultra-s --screen off --acepro on)"
check "the plan says yes with --acepro on, and the step would download the project" "echo \"\$OUTA\" | grep -E 'ace pro +yes'"
check "the question is asked in the install and a yes answer is used" "printf 'y\\ny\\ny\\ny\\ny\\ny\\ny\\ny\\ny\\ny\\n' | WM_TEST_NO_FETCH=1 WM_HOME=$T/hqa3 WM_INSTALLER_TEST=1 WM_TEST_PANEL_DIR=$T/stubpanel bash $ROOT/installer.sh --dry-run --from-stage $T/stage_hk --model ultra-s --screen off 2>&1 | grep -E 'ace pro +yes'"
check "without --acepro the ACE project is not touched" "[ ! -e $NS/wm-ultra-fluidd-acepro-panel ] && [ ! -e $NS/.ace-stub.log ]"
check "ACE Pro is not installed to start with, shown in the add-on list" "M '3\n0\n0\n' $NS --menu | grep -q 'Anycubic ACE Pro.*not installed'"
inst "$NS" --update --only-addon acepro --acepro on > "$T/ace1.out"
check "ACE Pro: the project is downloaded and its installer runs as an install, for this home, in test mode" "[ -f $NS/wm-ultra-fluidd-acepro-panel/installer.sh ] && grep -q -- '--install home=$NS test=1' $NS/.ace-stub.log"
check "ACE Pro: config files, include lines and the Klipper link are in place" "for f in wm_ace_driver wm_ace wm_endless wm_stats; do [ -f $NS/printer_data/config/\$f.cfg ] && grep -q \"^\\[include \$f.cfg\\]\" $NS/printer_data/config/printer.cfg || exit 1; done; [ -L $NS/klipper/klippy/extras/ace ]"
check "ACE Pro: remembered, in the plan, in --status" "grep -q 'WANT_ACEPRO=1' $NS/wm-rpi-backup/install.conf && inst $NS --status | grep -E 'acepro +installed'"
check "ACE Pro: the next --update runs the project's installer as an update, no second include line" "inst $NS --update --only-addon acepro >/dev/null; grep -q -- '--update home=' $NS/.ace-stub.log && [ \$(grep -c 'include wm_ace.cfg' $NS/printer_data/config/printer.cfg) = 1 ]"
printf '[server]\nport: 7125\n\n[update_manager]\n' > "$NS/printer_data/config/moonraker.conf"
inst "$NS" --update --only-addon acepro >/dev/null; inst "$NS" --update --only-addon acepro >/dev/null
check "Fluidd update entries: the panel repo and this installer's repo are added to moonraker.conf once, other sections stay, a copy is kept" "grep -c '^\[update_manager wm-ultra-fluidd-acepro-panel\]' $NS/printer_data/config/moonraker.conf | grep -qx 1 && grep -c '^\[update_manager wm-ultra-rpi\]' $NS/printer_data/config/moonraker.conf | grep -qx 1 && grep -q 'origin: https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel.git' $NS/printer_data/config/moonraker.conf && grep -q 'path: $NS/wm-ultra-fluidd-acepro-panel' $NS/printer_data/config/moonraker.conf && grep -q '^\[update_manager\]' $NS/printer_data/config/moonraker.conf && ls $NS/printer_data/config/moonraker.conf.wm-before-updatemgr-*"
check "ACE Pro: doctor is happy" "yes n | WM_HOME=$NS WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --doctor 2>&1 | grep -q 'ACE Pro driver and config are in place'"
rm -f "$NS/klipper/klippy/extras/ace"
check "ACE Pro: doctor notices the missing link and offers the fix" "yes n | WM_HOME=$NS WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --doctor 2>&1 | grep -q 'ACE Pro driver or its config is not set up'"
WM_HOME="$NS" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$ROOT/installer.sh" --doctor --fix-all >/dev/null 2>&1 </dev/null
check "ACE Pro: Fix everything puts the link back" "[ -L $NS/klipper/klippy/extras/ace ]"
check "--remove acepro asks first and keeps everything on no" "M 'n\n' $NS --remove acepro | grep -q 'Nothing changed' && [ -f $NS/printer_data/config/wm_ace.cfg ] && [ -d $NS/wm-ultra-fluidd-acepro-panel ]"
check "--remove acepro removes configs, include lines, link and the project, keeps a copy of printer.cfg and the saved copies on no" "M 'y\nn\n' $NS --remove acepro | grep -q 'ACE Pro removed' && ! ls $NS/printer_data/config/wm_ace*.cfg $NS/printer_data/config/wm_endless.cfg $NS/printer_data/config/wm_stats.cfg $NS/printer_data/config/wm-ultra-install.conf 2>/dev/null && ! grep -q 'wm_ace\\|wm_endless\\|wm_stats' $NS/printer_data/config/printer.cfg && [ ! -e $NS/klipper/klippy/extras/ace ] && [ ! -e $NS/wm-ultra-fluidd-acepro-panel ] && [ -d $NS/acepro-backup ] && grep -q 'WANT_ACEPRO=0' $NS/wm-rpi-backup/install.conf"
check "--remove acepro also takes its Fluidd update entry out (the installer's own entry stays)" "! grep -q 'update_manager wm-ultra-fluidd-acepro-panel' $NS/printer_data/config/moonraker.conf && grep -q '^\[update_manager wm-ultra-rpi\]' $NS/printer_data/config/moonraker.conf"
check "--remove acepro again says it is not installed" "M 'y\n' $NS --remove acepro | grep -q 'not installed'"
inst "$NS" --update --only-addon acepro --acepro on >/dev/null
rm -f "$NS/wm-ultra-fluidd-acepro-panel/installer.sh"
check "--remove acepro still works when the project's installer is gone, and can delete the saved copies" "M 'y\ny\n' $NS --remove acepro | grep -q 'ACE Pro removed' && ! ls $NS/printer_data/config/wm_ace*.cfg 2>/dev/null && ! grep -q 'wm_ace' $NS/printer_data/config/printer.cfg && [ ! -L $NS/klipper/klippy/extras/ace ] && [ ! -e $NS/acepro-backup ] && [ ! -e $NS/wm-ultra-fluidd-acepro-panel ]"
unset WM_TEST_ACEPRO_SRC

echo "== screen board menu"
MB="$T/mb"; mkdir -p "$MB"
mb() { local in="$1"; shift; printf "$in" | WM_TEST_SERVICES="makerbase-client klipper moonraker nginx" WM_HOME="$MB" WM_INSTALLER_TEST=1 bash "$SB" "$@" 2>&1; }
check "board menu: lists every entry and exits with 0" "mb '0\n' --menu | grep -q 'Install KlipperScreen' && mb '0\n' --menu | grep -q 'Backup and restore' && mb '0\n' --menu | grep -q 'Dry run'"
check "board menu: settings page has the Pi address and network entries, and no screen driver entry" "mb '5\n0\n0\n' --menu | grep -q 'Change the Pi address' && mb '5\n0\n0\n' --menu | grep -q 'Network and system' && ! mb '5\n0\n0\n' --menu | grep -q 'Change the screen driver'"
check "board menu: check and fix page" "mb '3\n0\n0\n' --menu | grep -q 'Fix everything' && mb '3\n0\n0\n' --menu | grep -q 'Restart the screen'"
check "board menu: the header shows the installer version" "mb '0\n' --menu | grep -q \"installer $(tr -d '[:space:]' < $ROOT/VERSION)\""
check "board menu: a wrong choice is explained" "mb 'x\n0\n' --menu | grep -q 'Choose a number'"
check "board menu: status is read-only" "mb '3\n3\n0\n0\n' --menu | grep -q 'Screen board status' && [ ! -e $MB/.sudo.log ]"
check "board menu: dry run changes nothing" "mb '7\n192.0.2.10\n\n0\n' --menu | grep -q 'DRY RUN' && [ ! -e $MB/wm-screen-backup/disabled.list ]"
check "board menu: install from the menu asks for the Pi address" "mb '1\n192.0.2.10\n\n0\n' --menu | grep -q 'Connects to: http://192.0.2.10:7125'"
check "board --set-driver fbdev and back" "mb '' --set-driver fbdev | grep -q 'driver is now fbdev' && [ -e $MB/.fbdev ] && mb '' --set-driver modesetting | grep -q 'driver is now modesetting' && [ ! -e $MB/.fbdev ]"
check "board --set-driver refuses a wrong name" "! mb '' --set-driver nope"

MY="$T/my"; mkdir -p "$MY/printer_data/config"
myb() { WM_ASSUME_YES=1 WM_TEST_SERVICES="makerbase-client klipper moonraker nginx" WM_HOME="$MY" WM_INSTALLER_TEST=1 bash "$SB" "$@" 2>&1 </dev/null; }
myb --pi 192.0.2.10 --no-reboot >/dev/null
check "board --doctor passes on a fresh install" "myb --doctor | grep -q 'No problems found'"
check "board --doctor finds a missing ZR Tools file" "rm -f $MY/KlipperScreen/panels/zr_tools.py; myb --doctor | grep -q 'ZR Tools file missing'"
check "board --backup writes a tgz with the config and the service list" "myb --backup | grep -q Saved && tar tzf \$(ls $MY/wm-screen-backups/*.tgz | head -1) | grep -q KlipperScreen.conf && tar tzf \$(ls $MY/wm-screen-backups/*.tgz | head -1) | grep -q disabled.list"
check "board --restore-backup restores and makes a safety copy" "echo changed > $MY/printer_data/config/zr_screen.conf; myb --restore-backup 1 | grep -q 'Settings restored' && ! grep -q changed $MY/printer_data/config/zr_screen.conf && [ \$(ls $MY/wm-screen-backups/*.tgz | wc -l) -ge 2 ]"
check "board --support-bundle has the config and a system page" "myb --support-bundle | grep -q Saved && tar tzf \$(ls $MY/wm-screen-support-*.tgz | head -1) | grep -q KlipperScreen.conf && tar tzf \$(ls $MY/wm-screen-support-*.tgz | head -1) | grep -q system.txt"
UPD="$T/upd"; mkdir -p "$UPD/zr_tools" "$UPD/scripts"; echo 99.0.0 > "$UPD/VERSION"; for f in zr_tools zr_views zr_logic pi_address_panel; do echo new > "$UPD/zr_tools/$f.py"; done; cp "$SB" "$ROOT/scripts/lib_free_space.sh" "$UPD/scripts/"
check "board --update copies the new panels after a backup" "WM_TEST_UPDATE_DIR=$UPD myb --update | grep -q 'Updated to 99.0.0' && grep -q new $MY/KlipperScreen/panels/zr_views.py"
check "board --update backup is named before-update and only the newest 5 stay (own backups kept)" "for i in 1 2 3 4 5 6 7; do touch -d 2020-01-0\$i $MY/wm-screen-backups/screen-backup-old\$i-before-update.tgz; done; touch $MY/wm-screen-backups/screen-backup-mine.tgz; sed -i 's/^99.0.0$/99.0.1/' $UPD/VERSION; WM_TEST_UPDATE_DIR=$UPD myb --update >/dev/null 2>&1; [ \$(ls $MY/wm-screen-backups/*before-update.tgz | wc -l) -le 5 ] && [ -f $MY/wm-screen-backups/screen-backup-mine.tgz ]"
check "board --system shows host name and sets a time zone" "myb --system | grep -q 'Host name' && myb --system tz:America/Toronto | grep -q 'Time zone is America/Toronto' && ! myb --system tz:'bad zone!'"
check "board --log and --restart-screen run" "myb --log | grep -q 'Last log' && myb --restart-screen | grep -q restarted"

MU="$T/mu"; mkdir -p "$MU/printer_data/config"; FK="$T/wm-ultra-rpi-fake"; mkdir -p "$FK/scripts"; cp "$SB" "$ROOT/scripts/lib_free_space.sh" "$FK/scripts/"; echo 1.0.0 > "$FK/VERSION"
muf() { WM_ASSUME_YES=1 WM_TEST_SERVICES="makerbase-client klipper moonraker nginx" WM_HOME="$MU" WM_INSTALLER_TEST=1 bash "$FK/scripts/screen_board.sh" "$@" 2>&1 </dev/null; }
muf --pi 192.0.2.10 --no-reboot >/dev/null; muf --backup >/dev/null; muf --support-bundle >/dev/null
check "board --remove restoredata is refused while KlipperScreen is installed" "! muf --remove restoredata && [ -d $MU/wm-screen-backup ]"
check "board --remove rescue removes the rescue tool and the Factory mode button, KlipperScreen stays" "muf --remove rescue | grep -q 'Rescue tool and Factory mode button removed' && grep -q 'remove factory button' $MU/.sudo.log && [ -d $MU/KlipperScreen ]"
check "board --remove backups deletes backups and bundles" "muf --remove backups | grep -q 'deleted' && [ ! -d $MU/wm-screen-backups ] && ! ls $MU/wm-screen-support-*.tgz"
check "board --remove with a wrong name is refused" "! muf --remove nope"
check "board --remove installer refuses a folder that is not a wm-ultra-rpi copy" "mkdir -p $T/other/scripts && cp $SB $ROOT/scripts/lib_free_space.sh $T/other/scripts/ && echo 1 > $T/other/VERSION && WM_ASSUME_YES=1 WM_HOME=$MU WM_INSTALLER_TEST=1 bash $T/other/scripts/screen_board.sh --remove installer </dev/null | grep -q 'not removing' && [ -d $T/other ]"
check "board menu: uninstall page lists the four entries" "mb '9\n0\n0\n' --menu | grep -q 'Rescue tool + Factory mode button' && mb '9\n0\n0\n' --menu | grep -q 'Downloaded installer folder'"
muf --factory-restore --no-reboot >/dev/null
check "board --remove restoredata works once KlipperScreen is gone" "muf --remove restoredata | grep -q 'deleted' && [ ! -d $MU/wm-screen-backup ]"
check "board --remove installer deletes the downloaded folder" "muf --remove installer | grep -q 'Installer folder deleted' && [ ! -d $FK ]"

check "board: no options at a terminal opens the menu" "printf '0\n' | WM_TEST_MENU_DEFAULT=1 WM_HOME=$MB WM_INSTALLER_TEST=1 bash $SB 2>&1 | grep -q 'Install KlipperScreen + ZR Tools'"
check "board: --install skips the menu" "! printf '0\n' | WM_TEST_MENU_DEFAULT=1 WM_HOME=$MB WM_INSTALLER_TEST=1 bash $SB --install --yes 2>&1 | grep -q 'Choose:'"

echo "== update without git / dry run in the menu"
GL="$T/gl"; mkdir -p "$GL"; cp -a "$ROOT"/. "$GL"/ 2>/dev/null; rm -rf "$GL/.git"; echo 99.0.0 > "$T/gl_new_version"
GN="$T/gl_new"; rm -rf "$GN"; mkdir -p "$GN"; cp -a "$ROOT"/. "$GN"/ 2>/dev/null; rm -rf "$GN/.git"; echo 99.0.0 > "$GN/VERSION"; echo marker > "$GN/NEWFILE"
GH="$T/glh"; mkdir -p "$GH"
glx() { WM_ASSUME_YES=1 WM_TEST_UPDATE_DIR="$GN" WM_TEST_NO_FETCH=1 WM_HOME="$GH" WM_INSTALLER_TEST=1 bash "$GL/installer.sh" "$@" 2>&1 </dev/null; }
check "--get-latest in a folder without git replaces the files" "glx --get-latest | grep -q 'updated to 99.0.0' && [ -f $GL/NEWFILE ] && grep -q 99.0.0 $GL/VERSION"
check "--get-latest says up to date when the version is the same" "glx --get-latest | grep -q 'Already up to date'"
GL2="$T/gl2"; mkdir -p "$GL2"; cp -a "$ROOT"/. "$GL2"/; rm -rf "$GL2/.git"
check "--get-latest --dry-run changes nothing" "WM_ASSUME_YES=1 WM_TEST_UPDATE_DIR=$GN WM_HOME=$GH WM_INSTALLER_TEST=1 bash $GL2/installer.sh --get-latest --dry-run </dev/null 2>&1 | grep -q 'would copy' && [ ! -f $GL2/NEWFILE ]"
check "--check-updates works without git (version compare)" "WM_TEST_NEW_VERSION=99.0.0 WM_HOME=$GH WM_INSTALLER_TEST=1 bash $GL2/installer.sh --check-updates </dev/null 2>&1 | grep -q 'On GitHub:   installer 99.0.0'"
check "menu: main page has Dry run of the install" "M '0\n' $HR --menu | grep -q 'Dry run of the install'"
check "menu: dry run entry shows the plan and changes nothing" "rm -rf $T/dr; mkdir -p $T/dr; M '8\n\n0\n' $T/dr --menu | grep -q 'DRY RUN' && [ ! -d $T/dr/klipper ]"

echo "== damaged factory files"
RF="$T/rf"; rm -rf "$RF"; mkdir -p "$RF"; git clone -q "$ROOT" "$RF" 2>/dev/null && cp "$ROOT/installer.sh" "$RF/installer.sh" 2>/dev/null && mkdir -p "$RF/scripts" && cp "$ROOT/scripts/lib_free_space.sh" "$RF/scripts/"
rm -f "$RF"/factory/ultra-s/klipper/klippy/extras/air.py
RFH="$T/rfh"; mkdir -p "$RFH"
check "install notices missing factory files, restores them and goes on" "WM_ASSUME_YES=1 WM_HOME=$RFH WM_INSTALLER_TEST=1 bash $RF/installer.sh --from-github --model ultra-s </dev/null 2>&1 | grep -q 'Factory files restored' && [ -f $RF/factory/ultra-s/klipper/klippy/extras/air.py ]"

check "menu: Update now on an empty Pi explains instead of failing" "rm -rf $T/ue; mkdir -p $T/ue; M '2\n2\n\n0\n0\n' $T/ue --menu | grep -q 'Nothing is installed on this Pi yet' "
check "--update on an empty Pi says what to do" "WM_HOME=$T/ue WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --update </dev/null 2>&1 | grep -q 'nothing is installed by this installer yet'"

echo "== progress bars"
PB="$T/pb"; rm -rf "$PB"; mkdir -p "$PB"
OUT="$(inst "$PB" --from-github --model ultra-s)"
check "pi install: every step shows a bar with its number and percent" "echo \"$OUT\" | grep -q 'Step 1 of 14' && echo \"$OUT\" | grep -q 'Step 7 of 14' && echo \"$OUT\" | grep -q '  0%' && echo \"$OUT\" | grep -qE '█.*░.*[0-9]+%'"
check "pi install: ends with a full bar" "echo \"$OUT\" | grep -q '100%  All 14 steps finished'"
OUT="$(inst "$PB" --update)"
check "pi update shows its bar from 0 to 100 percent" "echo \"$OUT\" | grep -q 'Update step 1 of 8' && echo \"$OUT\" | grep -q '100%  Update finished'"
OUT="$(WM_HOME=$T/pb2 WM_TEST_SERVICES='makerbase-client klipper' WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB --pi 192.0.2.10 --no-reboot 2>&1 </dev/null)"
check "board install: bar from step 1 of 7 to 100 percent" "echo \"$OUT\" | grep -q 'Install step 1 of 7' && echo \"$OUT\" | grep -q 'Install step 7 of 7' && echo \"$OUT\" | grep -q '100%  All 7 steps finished'"

echo "== board update page and reboot question"
UP="$T/upn"; mkdir -p "$UP/zr_tools" "$UP/scripts"; echo 99.0.0 > "$UP/VERSION"; printf '# Changelog\n\n## 99.0.0\n\n- brand new thing\n\n## %s\n\n- old thing\n' "$(cat $ROOT/VERSION)" > "$UP/CHANGELOG.md"
UPH="$T/uph"; mkdir -p "$UPH"
check "board --check-updates lists what is new and stops at the installed version" "O=\$(WM_TEST_UPDATE_DIR=$UP WM_HOME=$UPH WM_INSTALLER_TEST=1 bash $SB --check-updates 2>&1 </dev/null); echo \"\$O\" | grep -q 'brand new thing' && ! echo \"\$O\" | grep -q 'old thing' && echo \"\$O\" | grep -q 'Newest: 99.0.0'"
check "board menu: Update page has See what is new and Update now" "mb '2\n0\n0\n' --menu | grep -q 'See what is new' && mb '2\n0\n0\n' --menu | grep -q 'Update now'"
RB="$T/rbq"; mkdir -p "$RB"
check "board install asks before rebooting; yes reboots" "WM_ASSUME_YES=1 WM_TEST_SERVICES='makerbase-client klipper' WM_HOME=$RB WM_INSTALLER_TEST=1 bash $SB --pi 192.0.2.10 </dev/null 2>&1 | grep -q 'Reboot the board now' || grep -q 'systemctl reboot' $RB/.sudo.log"
check "board install: the reboot is in the log when the answer is the default (yes)" "grep -q 'systemctl reboot' $RB/.sudo.log"
check "board install: --no-reboot asks nothing and does not reboot" "! WM_ASSUME_YES=1 WM_TEST_SERVICES='makerbase-client klipper' WM_HOME=$T/rbq2 WM_INSTALLER_TEST=1 bash $SB --pi 192.0.2.10 --no-reboot </dev/null 2>&1 | grep -q 'Reboot the board now'"

check "board factory restore shows its bar from step 1 of 3 to 100 percent" "O=\$(WM_ASSUME_YES=1 WM_TEST_SERVICES='makerbase-client klipper' WM_HOME=$T/fr WM_INSTALLER_TEST=1 bash $SB --pi 192.0.2.10 --no-reboot 2>&1 </dev/null >/dev/null; WM_ASSUME_YES=1 WM_TEST_SERVICES='makerbase-client klipper' WM_HOME=$T/fr WM_INSTALLER_TEST=1 bash $SB --factory-restore --no-reboot 2>&1 </dev/null); echo \"\$O\" | grep -q 'Factory restore step 1 of 3' && echo \"\$O\" | grep -q 'Factory restore step 2 of 3' && echo \"\$O\" | grep -q '100%  Factory restore finished'"

RFD="$T/wm-ultra-rpi-board"; rm -rf "$RFD"; mkdir -p "$RFD/scripts" "$T/rfh"; cp "$SB" "$ROOT/scripts/lib_free_space.sh" "$RFD/scripts/"; echo 1.0.0 > "$RFD/VERSION"; mkdir -p "$T/rfn/zr_tools" "$T/rfn/scripts"; echo 99.0.0 > "$T/rfn/VERSION"; echo x > "$T/rfn/NEWFILE"; for f in zr_tools zr_views zr_logic pi_address_panel; do echo n > "$T/rfn/zr_tools/$f.py"; done; cp "$SB" "$T/rfn/scripts/"
check "board --update also refreshes the installer folder itself (so the menu shows the new version)" "WM_TEST_REFRESH=1 WM_ASSUME_YES=1 WM_TEST_UPDATE_DIR=$T/rfn WM_TEST_SERVICES='makerbase-client klipper' WM_HOME=$T/rfh WM_INSTALLER_TEST=1 bash $RFD/scripts/screen_board.sh --pi 192.0.2.10 --no-reboot >/dev/null 2>&1 </dev/null; WM_TEST_REFRESH=1 WM_ASSUME_YES=1 WM_TEST_UPDATE_DIR=$T/rfn WM_HOME=$T/rfh WM_INSTALLER_TEST=1 bash $RFD/scripts/screen_board.sh --update </dev/null 2>&1 | grep -q 'Updated to 99.0.0' && grep -q 99.0.0 $RFD/VERSION && [ -f $RFD/NEWFILE ]"

RUF="$T/ruf"; rm -rf "$RUF"; mkdir -p "$RUF/scripts" "$RUF/zr_tools"; cp "$SB" "$ROOT/scripts/lib_free_space.sh" "$RUF/scripts/"; echo 1.0.0 > "$RUF/VERSION"; RUH="$T/ruh"; mkdir -p "$RUH/printer_data/config" "$RUH/KlipperScreen/panels"
echo "[x]" > "$RUH/printer_data/config/KlipperScreen.conf"
check "board --update also refreshes the installer folder it runs from" "WM_TEST_REFRESH_REPO=1 WM_ASSUME_YES=1 WM_TEST_UPDATE_DIR=$UP WM_HOME=$RUH WM_INSTALLER_TEST=1 bash $RUF/scripts/screen_board.sh --update </dev/null 2>&1 | grep -q 'Updated to 99.0.0' && grep -q 99.0.0 $RUF/VERSION"

echo "== klipper restart after install and update"
KR="$T/kr"; mkstage "$T/stage_kr"; mkdir -p "$KR"; inst "$KR" --from-stage "$T/stage_kr" --screen off >/dev/null
: > "$KR/.sudo.log"; touch "$KR/.svc/klipper.active"
OUT="$(inst "$KR" --update)"
check "update restarts klipper at the end when it is running" "echo \"$OUT\" | grep -q 'Restarting Klipper' && [ \$(grep -c 'restart klipper' $KR/.sudo.log) -ge 1 ]"
rm -f "$KR/.svc/klipper.active"; : > "$KR/.sudo.log"
OUT="$(inst "$KR" --update)"
check "update does not start klipper when it is off (first start does that)" "echo \"$OUT\" | grep -q 'Klipper is not running, so it was not restarted' && ! grep -q 'restart klipper' $KR/.sudo.log"
check "update --dry-run restarts nothing" "touch $KR/.svc/klipper.active; : > $KR/.sudo.log; inst $KR --update --dry-run >/dev/null; ! grep -q 'restart klipper' $KR/.sudo.log"
BK2="$T/bk2"; mkdir -p "$BK2"
check "board install restarts klipper on the Pi through moonraker" "WM_ASSUME_YES=1 WM_TEST_SERVICES='makerbase-client klipper' WM_HOME=$BK2 WM_INSTALLER_TEST=1 bash $SB --pi 192.0.2.10 --no-reboot </dev/null 2>&1 | grep -q 'Klipper on the Pi restarted' && grep -q 'restart klipper on 192.0.2.10 via moonraker' $BK2/.sudo.log && grep -q 'restart KlipperScreen' $BK2/.sudo.log"
: > "$BK2/.sudo.log"
check "board update restarts klipper on the Pi and KlipperScreen" "WM_TEST_UPDATE_DIR=$UPD WM_ASSUME_YES=1 WM_HOME=$BK2 WM_INSTALLER_TEST=1 bash $SB --update </dev/null 2>&1 | grep -q 'Klipper on the Pi restarted' && grep -q 'restart klipper on' $BK2/.sudo.log && grep -q 'restart KlipperScreen' $BK2/.sudo.log"
check "board --dry-run restarts nothing on the Pi" "WM_ASSUME_YES=1 WM_HOME=$T/bk3 WM_INSTALLER_TEST=1 bash $SB --pi 192.0.2.10 --dry-run </dev/null 2>&1 | grep -qv 'Klipper on the Pi restarted'"

echo "== bars: weights, update, uninstall; doctor waits and re-checks"
check "pi install: bar percent grows and never goes backwards" "echo \"$(inst $T/pbw --from-github --model ultra-s)\" | grep -o '[0-9]*%' | tr -d '%' | awk 'NR>1 && \$1<prev {bad=1} {prev=\$1} END{exit bad}'"
PW="$T/pw"; rm -rf "$PW"; mkdir -p "$PW/KlipperScreen/panels" "$PW/printer_data/config"; echo "[x]" > "$PW/printer_data/config/KlipperScreen.conf"
check "board update shows its bar from 0 to 100 percent" "O=\$(WM_TEST_UPDATE_DIR=$UPD WM_ASSUME_YES=1 WM_HOME=$PW WM_INSTALLER_TEST=1 bash $SB --update </dev/null 2>&1); echo \"\$O\" | grep -q 'Update step 1 of 6' && echo \"\$O\" | grep -q '100%  Update finished'"
check "board doctor says how many problems were fixed" "WM_ASSUME_YES=1 WM_TEST_SERVICES='makerbase-client klipper' WM_HOME=$PW WM_INSTALLER_TEST=1 bash $SB --pi 192.0.2.10 --no-reboot </dev/null >/dev/null 2>&1; rm -f $PW/.svc/KlipperScreen.active; O=\$(WM_ASSUME_YES=1 WM_HOME=$PW WM_INSTALLER_TEST=1 bash $SB --doctor </dev/null 2>&1); echo \"\$O\" | grep -q 'KlipperScreen is not running' && echo \"\$O\" | grep -q 'fixed'"
UB="$T/ub"; mkdir -p "$UB/printer_data/config"; touch "$UB/Spoolman" 2>/dev/null; rm -f "$UB/Spoolman"; mkdir -p "$UB/Spoolman"
OUT="$(printf 'y\nn\n' | WM_HOME=$UB WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --remove spoolman 2>&1)"
check "single removal shows a bar that ends at 100 percent" "echo \"$OUT\" | grep -q '100%  spoolman removed' && echo \"$OUT\" | grep -q 'Removing the files'"
check "board --remove installer files show a bar at 100 percent" "mkdir -p $T/wm-ultra-rpi-pb/scripts && cp $SB $ROOT/scripts/lib_free_space.sh $T/wm-ultra-rpi-pb/scripts/ && echo 1 > $T/wm-ultra-rpi-pb/VERSION && WM_ASSUME_YES=1 WM_HOME=$PW WM_INSTALLER_TEST=1 bash $T/wm-ultra-rpi-pb/scripts/screen_board.sh --remove installer </dev/null 2>&1 | grep -q '100%  Done'"


echo "Progress bar never gets in the way of a question"
bar_check() {   # script-with-progress_bar : the bar is printed once, never redrawn, and no background job is started
    local LB; LB="$(mktemp -d)"
    cat > "$LB/lt.sh" <<EOT
GREEN=; NC=; TESTING=0; DRY=0
eval "\$(sed -n '/^prog_repeat()/p;/^progress_bar()/,/^}/p' $1)"
progress_bar 1 5 "Step 2 of 5"; read -r -p "question? " a; echo "[\$a]"; sleep 2; jobs -p | wc -l
EOT
    python3 - "$LB/lt.sh" <<'EOP'
import pty,os,struct,fcntl,termios,time,sys
pid,fd=pty.fork()
if pid==0: os.execvp('bash',['bash',sys.argv[1]])
fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
out=b''; t=time.time(); sent=False
while time.time()-t<6:
    try: d=os.read(fd,4096)
    except OSError: break
    if not d: break
    out+=d
    if b'question?' in out and not sent: time.sleep(1.2); os.write(fd,b'hello\n'); sent=True
sys.exit(0 if out.count(b'Step 2 of 5')==1 and b'\x1b[' not in out.replace(b'\x1b[0m',b'').replace(b'\x1b[0;32m',b'') and b'[hello]' in out and b'\n0' in out.replace(b'\r',b'') else 1)
EOP
}
check "Pi installer: the bar is printed once and a question after it stays clean" "bar_check $ROOT/installer.sh"
check "screen board: the bar is printed once and a question after it stays clean" "bar_check $ROOT/scripts/screen_board.sh"
check "bars: Check, Doctor, support bundle and backup all end at 100 percent" "M '' $LG --check | grep -q '100%  Check finished' && M '' $LG --doctor | grep -q '100%  Doctor finished' && M '' $LG --support-bundle | grep -q '100%  Done' && M '' $LG --backup | grep -q '100%  Done'"
# ---- PID settings where SAVE_CONFIG can store them (scripts/wm_pidcfg.py, installer step 4d, --pid-cfg, Doctor)
G3="$T/g3"; rm -rf "$G3"; mkdir -p "$G3/printer_data"; cp -r "$ROOT/factory/ultra-s/config" "$G3/printer_data/config"; echo ultra-s > "$G3/printer_data/wm-model"
P3="$G3/printer_data/config"
check "pid-cfg: the factory Ultra-S files have the chamber conflict (what the check must find)" "python3 $ROOT/scripts/wm_pidcfg.py check $P3 | grep -q 'CONFLICT zru-s.cfg \\[heater_generic chamber\\] control pid_Kp pid_Ki pid_Kd'"
check "pid-cfg: the factory hotends are pid (the SAVE_CONFIG block has control = pid), so no hotend problem" "! python3 $ROOT/scripts/wm_pidcfg.py check $P3 | grep -q HOTEND"
D3="WM_HOME=$G3 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh"
DR3="yes n 2>/dev/null | WM_HOME=$G3 WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --doctor"   # answers n to every fix: report only
check "doctor reports the chamber PID conflict (and changes nothing when the fix is declined)" "eval \"$DR3\" > $T/dr1.out 2>&1; grep -q 'problem.*PID settings: CONFLICT zru-s.cfg' $T/dr1.out && grep -q '^pid_Kp=63.418' $P3/zru-s.cfg"
WM_HOME="$G3" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --pid-cfg --dry-run >/dev/null 2>&1 </dev/null
check "--pid-cfg dry run changes nothing" "grep -q '^pid_Kp=63.418' $P3/zru-s.cfg && ! ls $P3/*.wm-before-pidcfg-* "
WM_HOME="$G3" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$ROOT/installer.sh" --pid-cfg > "$T/pid.out" 2>&1 </dev/null
check "--pid-cfg moves the chamber values into printer.cfg" "! grep -qE '^(control|pid_K)' $P3/zru-s.cfg && sed -n '1,/SAVE_CONFIG ---/p' $P3/printer.cfg | grep -A5 '^\\[heater_generic chamber\\]' | grep -q 'pid_Kp: 63.418'"
check "--pid-cfg keeps every value and the rest of zru-s.cfg" "grep -q '^heater_pin:PA4' $P3/zru-s.cfg && grep -q 'pid_Kd: 749.125' $P3/printer.cfg && grep -q 'pid_Ki: 1.342' $P3/printer.cfg"
check "--pid-cfg keeps a copy of each changed file" "ls $P3/zru-s.cfg.wm-before-pidcfg-* $P3/printer.cfg.wm-before-pidcfg-* && grep -q '^pid_Kp=63.418' $P3/zru-s.cfg.wm-before-pidcfg-*"
check "--pid-cfg leaves the SAVE_CONFIG block alone" "diff <(sed -n '/SAVE_CONFIG ---/,\$p' $ROOT/factory/ultra-s/config/printer.cfg) <(sed -n '/SAVE_CONFIG ---/,\$p' $P3/printer.cfg)"
check "the pid check is clean after the fix" "python3 $ROOT/scripts/wm_pidcfg.py check $P3 | grep -qx OK"
NBP=$(ls $P3 | grep -c 'wm-before-pidcfg')
WM_HOME="$G3" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$ROOT/installer.sh" --pid-cfg > "$T/pid2.out" 2>&1 </dev/null
check "--pid-cfg is idempotent: second run says fine and makes no new copy" "grep -q 'PID settings are where SAVE_CONFIG can store them' $T/pid2.out && [ \$(ls $P3 | grep -c 'wm-before-pidcfg') = $NBP ]"
check "doctor is happy after the fix" "$D3 --doctor 2>&1 </dev/null | grep -q 'ok.*PID settings of the hotends, bed and chamber heater'"
python3 - "$P3/printer.cfg" <<'PY'
import re,sys
f=sys.argv[1]; s=open(f).read()
s=re.sub(r"#\*# \[extruder\d?\]\n(#\*# (control|pid_k.) = .*\n)+#\*#\n","",s)
s=s.replace("[heater_generic chamber]\n# moved here from zru-s.cfg: Klipper's SAVE_CONFIG cannot save a value that an included file sets\n","[heater_generic chamber]\n")
open(f,"w").write(s)
PY
check "pid-cfg: hotends without control: pid and without a saved value are found" "python3 $ROOT/scripts/wm_pidcfg.py check $P3 | grep -c '^HOTEND' | grep -qx 4"
cp "$P3/printer.cfg" "$T/pid-before.cfg"
WM_HOME="$G3" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$ROOT/installer.sh" --doctor --fix-all >/dev/null 2>&1 </dev/null
check "Fix everything gives the 4 hotends control: pid (6 lines with bed and chamber) and keeps their old (commented) values" "[ \$(sed -n '1,/SAVE_CONFIG ---/p' $P3/printer.cfg | grep -c '^control: pid') = 6 ] && grep -q '^pid_Kp: 25.788' $P3/printer.cfg && grep -q '^pid_Kd: 14.291' $P3/printer.cfg"
check "pid check is clean again (hotends and chamber)" "python3 $ROOT/scripts/wm_pidcfg.py check $P3 | grep -qx OK"
check "the hotend fix saved printer.cfg first" "ls $P3/printer.cfg.wm-before-pidcfg-* >/dev/null && grep -q '^#control: pid' $P3/printer.cfg.wm-before-pidcfg-*"
check "the Ultra (no zru-s.cfg include, no chamber) is not touched" "R=$T/g4; rm -rf \$R; mkdir -p \$R/printer_data; cp -r $ROOT/factory/ultra/config \$R/printer_data/config; ! grep -q 'heater_generic chamber' \$R/printer_data/config/printer.cfg && python3 $ROOT/scripts/wm_pidcfg.py check \$R/printer_data/config | grep -qx OK"
# ---- WonderMaker's printer.cfg changes merged into the Pi's printer.cfg (scripts/wm_cfgmerge.py, installer step 4e, --cfg-merge)
check "doctor says when the WonderMaker printer.cfg starting point is not recorded" "grep -q 'problem.*printer.cfg this Pi was set up from is not recorded' $T/dr1.out"
RP="$T/repo5"; rm -rf "$RP"; mkdir -p "$RP/factory/ultra-s/config" "$RP/scripts" "$RP/rpi-cfg"; cp "$ROOT/installer.sh" "$ROOT/VERSION" "$RP/"; cp "$ROOT"/scripts/* "$RP/scripts/"; cp "$ROOT"/rpi-cfg/* "$RP/rpi-cfg/"
cp "$ROOT/factory/ultra-s/config/printer.cfg" "$T/pc-old.cfg"
python3 - "$T/pc-old.cfg" "$RP/factory/ultra-s/config/printer.cfg" <<'PY'
import sys
s=open(sys.argv[1]).read()
n=s.replace("pressure_advance: 0.032","pressure_advance: 0.040",1).replace("max_extrude_cross_section:5000","max_extrude_cross_section:6000",1)
n=n.replace("#*# <---------------------- SAVE_CONFIG","[output_pin wm_new_pin]\npin: PB9\n\n#*# <---------------------- SAVE_CONFIG",1)
open(sys.argv[2],"w").write(n)
PY
G5="$T/g5"; rm -rf "$G5"; mkdir -p "$G5/printer_data"; cp -r "$ROOT/factory/ultra-s/config" "$G5/printer_data/config"; echo ultra-s > "$G5/printer_data/wm-model"; P5="$G5/printer_data/config"
python3 "$ROOT/scripts/wm_pidcfg.py" fix "$P5" T0 >/dev/null; rm -f "$P5"/*.wm-before-pidcfg-*   # a Pi whose PID settings are already fine
sed -i 's/^pressure_advance: 0.032/pressure_advance: 0.045/; s/^#\*# pid_kp = 26.638/#*# pid_kp = 99.999/' "$P5/printer.cfg"
sed -i 's|^#\*# <---------------------- SAVE_CONFIG|[output_pin my_led]\npin: PB1\n\n&|' "$P5/printer.cfg"
sed -i '1i [include wm_calibration.cfg]' "$P5/printer.cfg"
cp "$P5/printer.cfg" "$T/pc5.mine"
WM_HOME="$G5" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$RP/installer.sh" --cfg-merge > "$T/cm0.out" 2>&1 </dev/null
check "--cfg-merge with no record only records the starting point and changes nothing" "cmp $P5/printer.cfg $T/pc5.mine && cmp $G5/printer_data/wm-baseline/printer.cfg $RP/factory/ultra-s/config/printer.cfg && grep -q 'Recorded this repository' $T/cm0.out"
cp "$T/pc-old.cfg" "$G5/printer_data/wm-baseline/printer.cfg"   # the Pi was set up from the old WonderMaker file
WM_HOME="$G5" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$RP/installer.sh" --cfg-merge --dry-run >/dev/null 2>&1 </dev/null
check "--cfg-merge dry run changes nothing" "cmp $P5/printer.cfg $T/pc5.mine"
WM_HOME="$G5" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$RP/installer.sh" --cfg-merge > "$T/cm1.out" 2>&1 </dev/null
check "merge: WonderMaker's new setting and new section arrive" "grep -q '^max_extrude_cross_section:6000' $P5/printer.cfg && grep -q '^\\[output_pin wm_new_pin\\]' $P5/printer.cfg"
check "merge: my value (a conflict, assume-yes keeps mine), my section and my include stay" "grep -q '^pressure_advance: 0.045' $P5/printer.cfg && grep -q '^\\[output_pin my_led\\]' $P5/printer.cfg && head -1 $P5/printer.cfg | grep -qx '\\[include wm_calibration.cfg\\]'"
check "merge: the SAVE_CONFIG block is mine, byte for byte" "diff <(sed -n '/SAVE_CONFIG ---/,\$p' $T/pc5.mine) <(sed -n '/SAVE_CONFIG ---/,\$p' $P5/printer.cfg)"
check "merge: a copy of my printer.cfg is kept and the starting point moves to the new version" "cmp $T/pc5.mine $P5/printer.cfg.wm-before-cfgmerge-* && cmp $G5/printer_data/wm-baseline/printer.cfg $RP/factory/ultra-s/config/printer.cfg"
NBC=$(ls $P5 | grep -c 'wm-before-cfgmerge')
WM_HOME="$G5" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$RP/installer.sh" --cfg-merge > "$T/cm2.out" 2>&1 </dev/null
check "merge: a second run finds nothing to do and makes no new copy" "grep -q 'already has everything' $T/cm2.out && [ \$(ls $P5 | grep -c 'wm-before-cfgmerge') = $NBC ]"
check "the merge keeps the PID settings in a place SAVE_CONFIG can store them" "python3 $ROOT/scripts/wm_pidcfg.py check $P5 | grep -qx OK || python3 $ROOT/scripts/wm_pidcfg.py check $P5 | grep -q CONFLICT"
check "backup and auto backup include the recorded starting point" "[ \$(grep -c 'printer_data/wm-baseline' $ROOT/installer.sh) -ge 3 ]"
python3 - "$ROOT/scripts/wm_cfgmerge.py" <<'PY'
import importlib.util,sys
sp=importlib.util.spec_from_file_location("m",sys.argv[1]); m=importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
base="[mcu T0]\ncanbus_uuid: aaaa\n[extruder]\nrotation_distance: 21.0\n"
rel="[mcu T0]\ncanbus_uuid: bbbb\n[extruder]\nrotation_distance: 22.0\nnew_opt: 1\n[gone]\nx: 1\n"
live="[mcu T0]\ncanbus_uuid: cccc\n[extruder]\nrotation_distance: 21.0\nmy_opt: 2\n"
t,c,n=m.merge_cfg(base,rel,live)
ok = "canbus_uuid: cccc" in t and "bbbb" not in t and "rotation_distance: 22.0" in t and "new_opt: 1" in t and "my_opt: 2" in t and not c
sys.exit(0 if ok else 1)
PY
check "merge unit: canbus_uuid stays the Pi's, WonderMaker's change and new setting arrive, my setting stays" "[ $? = 0 ]"
check "pip is told not to check for a newer pip (no warning on slow links)" "grep -q '^export PIP_DISABLE_PIP_VERSION_CHECK=1' $ROOT/installer.sh && grep -q '^export PIP_DISABLE_PIP_VERSION_CHECK=1' $ROOT/scripts/screen_board.sh"
check "board update: waits at most 60 s for Klipper on the Pi, says it is still waiting, and cleans /tmp on Ctrl-C" "grep -q 'still waiting: Klipper on the Pi' $ROOT/scripts/screen_board.sh && grep -q 'rm -rf \"\${LATEST_TMP:-}\"; exit 130' $ROOT/scripts/screen_board.sh && ! grep -q 'for i in \$(seq 1 30); do' <(sed -n '/^restart_pi_klipper/,/^}/p' $ROOT/scripts/screen_board.sh)"
check "board lib error message names an option that exists" "! grep -q 'screen_board.sh --get-latest' $ROOT/scripts/screen_board.sh"
check "Pi installer: Klipper wait prints progress; the download in /tmp is removed on Ctrl-C" "grep -q 'still waiting: Klipper is' $ROOT/installer.sh && grep -q \"trap '_rmw; exit 130' INT TERM\" $ROOT/installer.sh"
check "dev box: tool and simulation unit tests" "python3 -I -W ignore $ROOT/tests/test_devbox.py"
check "dev box: the README has no banner and links the tool" "! head -3 $ROOT/README.md | grep -qi 'dev box branch' && grep -q 'tools/devbox/' $ROOT/README.md && [ -f $ROOT/README-DEVBOX.md ]"
DBH="$T/dbh"; mkdir -p "$DBH/printer_data/config" "$DBH/printer_data/systemd"; cp "$ROOT/factory/ultra-s/config/printer.cfg" "$DBH/printer_data/config/"
check "dev box: no notice from the Doctor, --cfg-merge or --pid-cfg while it is off" "! (yes n | WM_HOME=$DBH WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --doctor 2>&1; WM_HOME=$DBH WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --pid-cfg 2>&1 </dev/null) | grep -q 'Dev box mode is ON'"
echo 'KLIPPER_ARGS="/k/klippy.py '"$DBH"'/printer_data/devbox/config/printer.cfg -I /c/klippy.serial"' > "$DBH/printer_data/systemd/klipper.env"
check "dev box: the Doctor says dev mode is on" "yes n | WM_HOME=$DBH WM_INSTALLER_TEST=1 bash $ROOT/installer.sh --doctor 2>&1 | grep -q 'Dev box mode is ON'"
check "dev box: --pid-cfg and --cfg-merge say it too" "WM_HOME=$DBH WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --pid-cfg 2>&1 </dev/null | grep -q 'Dev box mode is ON' && WM_HOME=$DBH WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --cfg-merge 2>&1 </dev/null | grep -q 'Dev box mode is ON'"
echo; echo "passed: $PASS  failed: $FAIL"; [ "$FAIL" = 0 ]
