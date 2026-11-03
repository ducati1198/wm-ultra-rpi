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
inst() { local h="$1"; shift; WM_HOME="$h" WM_INSTALLER_TEST=1 WM_ASSUME_YES=1 bash "$ROOT/installer.sh" "$@" 2>&1; }

echo "== basics"
check "bash syntax installer" "bash -n $ROOT/installer.sh"
check "bash syntax scripts" "for f in $ROOT/scripts/*.sh $ROOT/zr_tools/install_zr_tools.sh; do bash -n \$f || exit 1; done"
check "--version prints" "bash $ROOT/installer.sh --version | grep -q wm-ultra-rpi"
check "--help prints" "bash $ROOT/installer.sh --help | grep -q from-image"
check "unknown option fails" "! bash $ROOT/installer.sh --nope"
check "fluidd zip checksum" "cd $ROOT/fluidd && sha256sum -c fluidd-v1.37.7-zr-ace.zip.sha256"
check "no Claude mention in repo files" "! grep -rIl -i 'claude' $ROOT --exclude-dir=.git --exclude=tests --exclude=run_tests.sh --exclude=*.patch --exclude=*.zip"
check "no private addresses in repo files" "! grep -rIlE '10\.11\.88\.|192\.168\.1\.' $ROOT --exclude-dir=.git --exclude=*.patch"
check "service files do not enable klipper" "! grep -q 'WantedBy' $ROOT/config/klipper.service"

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
check "klipper disabled, never enabled" "grep -q 'systemctl disable klipper' $H/.sudo.log && ! grep -q 'systemctl enable klipper' $H/.sudo.log"
check "klipper never started" "! grep -Eq 'systemctl (start|restart) klipper' $H/.sudo.log"
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

echo "== zr_tools option"
H3="$T/h3"; mkdir -p "$H3"; printf 'y\ny\ny\ny\ny\n' > "$T/ans3"
WM_HOME="$H3" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --from-stage "$T/stage" < "$T/ans3" >/dev/null 2>&1
check "zr_tools copied" "[ -f $H3/zr_tools/zr_tools.py ]"

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
printf 'n\n' | WM_HOME="$H" WM_INSTALLER_TEST=1 bash "$ROOT/installer.sh" --enable-klipper >/dev/null 2>&1
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
(cd "$ROOT/factory/zru" && sha256sum -c SHA256SUMS >/dev/null) && echo "  ok   factory checksums" && PASS=$((PASS+1))
check "no compiled module in the repo" "! find $ROOT/factory -name '*.so' | grep -q . && ! tar tzf $ROOT/factory/zru/klipper.tgz | grep -q '\.so$'"
check "klipper archive has its license" "tar tzf $ROOT/factory/zru/klipper.tgz | grep -q klipper/COPYING"
check "factory config has placeholder CAN ids only" "grep -q aa0000000000 $ROOT/factory/zru/config/wm_zru_mcu.cfg"
HG="$T/hg"; mkdir -p "$HG"
OUT="$(inst "$HG" --from-github --model ultra-s)"; echo "$OUT" > "$T/gh.out"
check "install from repo works without modules" "[ -f $HG/klipper/klippy/klippy.py ] && [ -f $HG/printer_data/config/printer.cfg ]"
check "warns that modules are missing" "grep -q 'compiled modules were NOT installed' $T/gh.out"
check "web interface installed (factory data has none)" "[ -f $HG/fluidd/index.html ]"
check "env files in place" "grep -q KLIPPER_ARGS $HG/printer_data/systemd/klipper.env"
check "unknown model refused" "! inst $T/hg2 --from-github --model nope"
check "ultra-s model enables zru-s.cfg" "grep -q '^\\[include zru-s.cfg\\]' $HG/printer_data/config/printer.cfg"
HU="$T/hu"; mkdir -p "$HU"; inst "$HU" --from-github --model ultra >/dev/null
check "ultra model leaves zru-s.cfg off" "grep -q '^# \\[include zru-s.cfg\\]' $HU/printer_data/config/printer.cfg && ! grep -q '^\\[include zru-s.cfg\\]' $HU/printer_data/config/printer.cfg"
check "no MCU binary or flasher in the repo" "! find $ROOT/factory -name '*.bin' -o -name hid-flash | grep -q ."
check "model variants of printer.cfg present" "[ -f $ROOT/factory/zru/config-variants/printer4.cfg ]"
# modules: wrong files refused, right files accepted (use a copy of the repo with matching fake checksums)
mkdir -p "$T/mods"; for n in cs1237 heater_air_core heater_feng hx711 xy_offset_calibrator_core; do echo "fake $n" > "$T/mods/$n.cpython-39-aarch64-linux-gnu.so"; done
check "modules with wrong checksum refused" "! bash $ROOT/scripts/stage_from_repo.sh ultra-s $T/st_bad $T/mods"
RC2="$T/repocopy"; mkdir -p "$RC2"; cp -a "$ROOT/scripts" "$ROOT/config" "$ROOT/factory" "$RC2/"
( cd "$T/mods" && sha256sum *.so | sed 's#  #  klippy/extras/#' ) > "$RC2/factory/zru/modules.sha256"
check "modules with matching checksum accepted" "bash $RC2/scripts/stage_from_repo.sh ultra-s $T/st_ok $T/mods && [ \"\$(cat $T/st_ok/modules_ok)\" = 1 ] && tar xzOf $T/st_ok/klipper.tgz klipper/klippy/extras/hx711.cpython-39-aarch64-linux-gnu.so | grep -q 'fake hx711'"
check "damaged repo files refused" "cp -a $ROOT/factory $T/damaged_f && echo x >> $T/damaged_f/zru/moonraker.tgz && mkdir -p $T/dm && cp -a $ROOT/scripts $ROOT/config $T/dm/ && rm -rf $T/dm/factory && cp -a $T/damaged_f $T/dm/factory && ! bash $T/dm/scripts/stage_from_repo.sh ultra-s $T/st_dm"

echo "== crowsnest, timelapse, pinned environments"
check "addon pins are full commit ids" "grep -qE '^crowsnest\\|https://github.com/mainsail-crew/crowsnest\\|[0-9a-f]{40}\$' $ROOT/config/pins/addons.txt && grep -qE '^moonraker-timelapse\\|.*\\|[0-9a-f]{40}\$' $ROOT/config/pins/addons.txt"
check "klippy requirements all pinned" "! grep -vE '^#|==' $ROOT/config/klippy-requirements.txt | grep -q ."
check "moonraker requirements all pinned" "! grep -vE '^#|==' $ROOT/config/moonraker-requirements.txt | grep -q ."
check "timelapse.cfg shipped (printer.cfg includes it)" "[ -f $ROOT/factory/zru/config/timelapse.cfg ] && grep -q 'include timelapse.cfg' $ROOT/factory/zru/config/printer.cfg"
check "every include of the factory printer.cfg exists" "cd $ROOT/factory/zru/config && for f in \$(grep -E '^\\[include ' printer.cfg | sed 's/\\[include //;s/\\]//'); do [ -f \$f ] || { echo missing \$f; exit 1; }; done"
check "crowsnest installed (unattended) in test log" "grep -q 'make install (crowsnest)' $HG/.sudo.log"
check "crowsnest.conf placed" "[ -f $HG/printer_data/config/crowsnest.conf ]"
check "ffmpeg requested for timelapse" "grep -q 'apt-get install -y ffmpeg' $HG/.sudo.log"
check "moonraker.asvc lists crowsnest" "grep -q crowsnest $HG/printer_data/moonraker.asvc"

echo; echo "passed: $PASS  failed: $FAIL"; [ "$FAIL" = 0 ]
