#!/bin/bash
# Tests for the installer and scripts. Uses fake homes and a synthetic disk image. No sudo, no network, no services.
#   bash tests/run_tests.sh
set -u
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
check "--help prints" "bash $ROOT/installer.sh --help | grep -q from-image"
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
check "--screen-test is read-only" "WM_TEST_SCREEN=800x480 WM_TEST_TOUCH=0 bash $ROOT/installer.sh --screen-test | grep -q 'compact'"
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

echo "== extract from a disk image"
if command -v mke2fs >/dev/null && command -v python3 >/dev/null && command -v debugfs >/dev/null; then
    R="$T/rootfs/home/t13dp"; mkdir -p "$R/klipper/klippy" "$R/moonraker/moonraker" "$R/printer_data/config" "$R/printer_data/systemd" "$R/printer_data/gcodes" "$R/fluidd" "$R/TM_T1/factory_settings" "$R/TM_T1/scripts"
    echo "[mcu]" > "$R/printer_data/config/printer.cfg"; echo hi > "$R/fluidd/index.html"; echo "x" > "$R/printer_data/gcodes/big.gcode"
    mke2fs -q -t ext4 -d "$T/rootfs" "$T/part.img" 20M
    truncate -s 30M "$T/disk.img"
    python3 - "$T/disk.img" <<'PY'
import sys, struct
f = open(sys.argv[1], "r+b")
mbr = bytearray(512); mbr[450] = 0xEE; mbr[510:512] = b"\x55\xaa"; f.seek(0); f.write(mbr)
hdr = bytearray(92); hdr[0:8] = b"EFI PART"; struct.pack_into("<QII", hdr, 72, 2, 128, 128)
f.seek(512); f.write(hdr)
def ent(first, last):
    e = bytearray(128); e[0:16] = b"\x01" * 16; struct.pack_into("<QQ", e, 32, first, last); return e
f.seek(1024); f.write(ent(2048, 6143)); f.write(ent(8192, 8192 + 40960 - 1))
PY
    dd if="$T/part.img" of="$T/disk.img" bs=512 seek=8192 conv=notrunc status=none
    gzip -k "$T/disk.img"
    bash "$ROOT/scripts/extract_from_image.sh" "$T/disk.img" "$T/st_img" >/dev/null 2>&1
    check "image: klipper.tgz made" "tar tzf $T/st_img/klipper.tgz | grep -q klippy"
    check "image: printer.cfg in data.tgz" "tar tzf $T/st_img/data.tgz | grep -q printer_data/config/printer.cfg"
    check "image: gcodes not in data.tgz" "! tar tzf $T/st_img/data.tgz | grep -q big.gcode"
    bash "$ROOT/scripts/extract_from_image.sh" "$T/disk.img.gz" "$T/st_gz" >/dev/null 2>&1
    check "image .gz works" "[ -s $T/st_gz/moonraker.tgz ]"
    H7="$T/h7"; mkdir -p "$H7"; inst "$H7" --from-image "$T/disk.img" >/dev/null
    check "install straight from image" "[ -f $H7/printer_data/config/printer.cfg ]"
    echo junk > "$T/notimg.img"; check "non-image refused" "! bash $ROOT/scripts/extract_from_image.sh $T/notimg.img $T/st_bad"
else echo "  (skipped: mke2fs/debugfs missing)"; fi

echo "== factory files from the repository (no printer)"
(cd "$ROOT/factory/ultra-s" && sha256sum -c SHA256SUMS >/dev/null) && echo "  ok   factory checksums" && PASS=$((PASS+1))
check "factory sources are plain folders, committed" "[ -f $ROOT/factory/ultra-s/klipper/klippy/klippy.py ] && [ -f $ROOT/factory/ultra-s/moonraker/moonraker/moonraker.py ] && ! git -C $ROOT check-ignore -q factory/ultra-s/klipper/klippy/klippy.py"
check "the 5 compiled modules are in the repo and match their factory checksums" "cd $ROOT/factory/ultra-s/klipper && sha256sum -c ../modules.sha256"
check "klipper archive has its license" "[ -f $ROOT/factory/ultra-s/klipper/COPYING ] && [ -f $ROOT/factory/ultra-s/moonraker/LICENSE ]"
check "factory config has placeholder CAN ids only" "grep -q aa0000000000 $ROOT/factory/ultra-s/config/wm_zru_mcu.cfg"
HG="$T/hg"; mkdir -p "$HG"
OUT="$(inst "$HG" --from-github --model ultra-s)"; echo "$OUT" > "$T/gh.out"
check "install from repo works" "[ -f $HG/klipper/klippy/klippy.py ] && [ -f $HG/printer_data/config/printer.cfg ]"
check "no missing-modules warning (they are bundled)" "! grep -q 'compiled modules were NOT installed' $T/gh.out && grep -q 'all 5 present' $T/gh.out"
check "bundled modules end up in ~/klipper" "ls $HG/klipper/klippy/extras/hx711.cpython-39-aarch64-linux-gnu.so"
check "web interface installed (factory data has none)" "[ -f $HG/fluidd/index.html ]"
check "env files in place" "grep -q KLIPPER_ARGS $HG/printer_data/systemd/klipper.env"
check "unknown model refused" "! inst $T/hg2 --from-github --model nope"
check "ultra-s model enables zru-s.cfg" "grep -q '^\\[include zru-s.cfg\\]' $HG/printer_data/config/printer.cfg"
HU="$T/hu"; mkdir -p "$HU"; inst "$HU" --from-github --model ultra >/dev/null
check "ultra has its own factory folder" "[ -d $ROOT/factory/ultra/klipper/klippy ] && [ -f $ROOT/factory/ultra/config/printer.cfg ]"
check "ultra folder: zru-s.cfg off, ultra-s folder: on" "grep -q '^# \\[include zru-s.cfg\\]' $ROOT/factory/ultra/config/printer.cfg && grep -q '^\\[include zru-s.cfg\\]' $ROOT/factory/ultra-s/config/printer.cfg"
check "both folders pass their checksums" "(cd $ROOT/factory/ultra && sha256sum -c SHA256SUMS) && (cd $ROOT/factory/ultra-s && sha256sum -c SHA256SUMS)"
check "ultra model leaves zru-s.cfg off" "grep -q '^# \\[include zru-s.cfg\\]' $HU/printer_data/config/printer.cfg && ! grep -q '^\\[include zru-s.cfg\\]' $HU/printer_data/config/printer.cfg"
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
printf 'Found canbus_uuid=aa0000000000, Application: Klipper\nFound canbus_uuid=ae0000000000, Application: Klipper\n' > "$T/can_ok.txt"
printf 'Found canbus_uuid=bb1122334455, Application: Klipper\nFound canbus_uuid=ae0000000000, Application: Klipper\n' > "$T/can_new.txt"
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
check "old file kept before the change" "grep -q 'aa0000000000' $G5/wm-rpi-backup/uuid-*/wm_zru_mcu.cfg"
check "hub uuid left alone" "grep -q 'ae0000000000' $G5/printer_data/config/wm_zru_hub.cfg"
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
rm -f "$G2"/klipper/klippy/extras/cs1237.*.so
check "doctor finds a missing module and restores it from the repo" "WM_HOME=$G2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --doctor; ls $G2/klipper/klippy/extras/cs1237.*.so"
check "doctor reports bad network clock/power as problems" "! WM_TEST_THROTTLED=0x50005 WM_HOME=$G2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $ROOT/installer.sh --doctor"
printf '[update_manager]\npassword: hunter2\nhost: 192.168.7.44\n' >> "$G2/printer_data/config/moonraker.conf"
WM_HOME="$G2" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --support-bundle >/dev/null 2>&1
SB="$(ls $G2/wm-support-*.tgz | head -1)"
check "support bundle made" "[ -f $SB ]"
check "support bundle has no password or private IP" "! tar xzOf $SB | grep -Eq 'hunter2|192\\.168\\.7\\.44'"
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
check "screen-remove: answers say no screen" "grep -q WANT_SCREEN=0 $H3/wm-rpi-backup/install.conf"
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
check "board: ZR Tools files copied" "[ -f $B1/KlipperScreen/panels/zr_tools.py ] && [ -f $B1/KlipperScreen/panels/zr_logic.py ]"
check "board: uses pinned KlipperScreen commit" "grep -q '34610ceae31e12a10cc980e20a1dec9976f97dd4' $B1/.sudo.log"
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
check "board: refuses when the Pi does not answer, changes nothing" "! WM_TEST_PI_OK=0 WM_TEST_SERVICES='klipper' WM_HOME=$B2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB --pi wmpi.local && [ ! -f $B2/wm-screen-backup/disabled.list ] && ! grep -q 'systemctl stop' $B2/.sudo.log"
check "board: refuses while printing" "! WM_TEST_PRINTING=1 WM_TEST_SERVICES='klipper' WM_HOME=$B2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB --pi wmpi.local"
check "board: refuses when apt is broken" "! WM_TEST_APT_OK=0 WM_TEST_SERVICES='klipper' WM_HOME=$B2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB --pi wmpi.local"
check "board: needs --pi" "! WM_HOME=$B2 WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash $SB"
B3="$T/b3"; mkdir -p "$B3/printer_data/config"
WM_TEST_KS_OK=fbdev sb "$B3" --pi 10.0.0.5 > "$T/b3.out"
check "board: X falls back to fbdev when modesetting does not start" "[ -e $B3/.fbdev ] && grep -q 'fbdev' $T/b3.out"
B4="$T/b4"; mkdir -p "$B4/printer_data/config"; sb "$B4" --pi wmpi.local --dry-run > "$T/b4.out"
check "board: dry run changes nothing" "[ ! -d $B4/KlipperScreen ] && [ ! -s $B4/.sudo.log ] && grep -q 'would run' $T/b4.out"
B5="$T/b5"; mkdir -p "$B5/printer_data/config"; sb "$B5" --pi wmpi.local >/dev/null; printf 'y\n' | WM_HOME="$B5" WM_INSTALLER_TEST=1 bash "$SB" --uninstall-klipperscreen > "$T/b5u.out" 2>&1
check "board uninstall-klipperscreen: removes it AND re-enables the factory services" "[ ! -d $B5/KlipperScreen ] && [ -e $B5/.svc/makerbase-client.enabled ] && [ -e $B5/.svc/klipper.enabled ] && [ -e $B5/.svc/moonraker.enabled ]"
B6="$T/b6"; mkdir -p "$B6/printer_data/config"; sb "$B6" --pi wmpi.local >/dev/null; sb "$B6" --pi wmpi.local >/dev/null
check "board: running twice keeps the ORIGINAL saved state" "grep -q 'makerbase-client enabled active' $B6/wm-screen-backup/disabled.list"

echo; echo "passed: $PASS  failed: $FAIL"; [ "$FAIL" = 0 ]
