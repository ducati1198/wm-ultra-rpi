#!/bin/bash
# Tests for wm_release.py on throwaway folders. Run: bash tools/wm-release/test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"; PY="$HERE/wm_release.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"; [ -n "${SRV:-}" ] && kill $SRV 2>/dev/null' EXIT
export WMR_HOME="$T/data" WMR_LIVE_HOME="$T/live" WMR_MOONRAKER="http://127.0.0.1:1"
pass=0; fail=0
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "  ok   $d"; else fail=$((fail+1)); echo "  FAIL $d"; fi; }
R() { python3 "$PY" "$@" 2>&1; }

mkdir -p "$T/live"
R init-baseline > "$T/o1"
check "init-baseline records 1.1.13" grep -q "Baseline 1.1.13 recorded" "$T/o1"
check "init-baseline refuses to overwrite" bash -c "! python3 $PY init-baseline >/dev/null 2>&1"
# live = baseline + local edits
cp -a "$WMR_HOME/baseline/1.1.13/." "$T/live/"
C="$T/live/printer_data/config"
echo "# my note" | cat - "$C/macros.cfg" > "$T/m" && mv "$T/m" "$C/macros.cfg"
sed -i 's/^\(trusted_clients:\)/\1/' "$C/moonraker.conf"; echo "# my moonraker line" >> "$C/moonraker.conf"
echo "[include mine.cfg]" >> "$C/printer.cfg"
# release 1.1.14 = baseline + WonderMaker edits
mkdir -p "$T/rel"; cp -a "$WMR_HOME/baseline/1.1.13/." "$T/rel/"
RC="$T/rel/printer_data/config"
echo "# wm change at the end" >> "$RC/macros.cfg"                     # merges clean (mine is at the top)
echo "# wm line" >> "$RC/moonraker.conf"                              # same place as mine -> conflict
echo "# wm changed" >> "$RC/change_macros.cfg"                        # I did not touch -> TAKE
echo "[gcode_macro NEWTHING]" > "$RC/new.cfg"; echo "gcode:" >> "$RC/new.cfg"   # ADD
echo "# wm printer" >> "$RC/printer.cfg"                              # PROTECTED
rm -f "$RC/extruder3.cfg"                                            # REMOVED
printf 'x' >> "$T/rel/klipper/klippy/chelper/c_helper.so" 2>/dev/null || true
echo "2026-11-20 10:00:00: Add System_1.1.14" > "$T/rel/iso_version.txt"
sed -i 's/20260408_185504/20261120_101010/' "$T/rel/mcu_update/mcu_info.ini"
R fetch --from-dir "$T/rel" > "$T/o2"
check "fetch reads the version from iso_version.txt" grep -q "Release 1.1.14 copied" "$T/o2"
R diff 1.1.14 > "$T/o3"
for c in "TAKE (" "ADD (" "MERGE (" "CONFLICT (" "PROTECTED (" "REMOVED ("; do check "diff: category $c" grep -q "^== $c" "$T/o3"; done
check "diff: macros.cfg merges cleanly" bash -c "sed -n '/^== MERGE/,/^==/p' $T/o3 | grep -q 'macros.cfg'"
check "diff: moonraker.conf is a conflict" bash -c "sed -n '/^== CONFLICT/,/^==/p' $T/o3 | grep -q 'moonraker.conf'"
check "diff: printer.cfg is protected" bash -c "sed -n '/^== PROTECTED/,/^==/p' $T/o3 | grep -q 'printer.cfg'"
check "diff: tells to restart for compiled modules" grep -q "Compiled modules" "$T/o3"
check "diff: report file saved" bash -c "ls $WMR_HOME/reports/1.1.14-*.txt"
# apply: dry run changes nothing
( cd "$T/live" && find . -type f | sort | xargs sha256sum ) > "$T/before"
R apply 1.1.14 > "$T/o4"
( cd "$T/live" && find . -type f | sort | xargs sha256sum ) > "$T/after_dry"
check "apply without --apply is a dry run" cmp -s "$T/before" "$T/after_dry"
check "apply plan lists TAKE, ADD, MERGE and the conflict" bash -c "grep -q 'TAKE   printer_data/config/change_macros.cfg' $T/o4 && grep -q 'ADD    printer_data/config/new.cfg' $T/o4 && grep -q 'MERGE  printer_data/config/macros.cfg' $T/o4 && grep -q 'HAND   printer_data/config/moonraker.conf' $T/o4"
WMR_TEST_TYPED=nope R apply 1.1.14 --apply > "$T/o5"
( cd "$T/live" && find . -type f | sort | xargs sha256sum ) > "$T/after_no"
check "apply without typing APPLY changes nothing" cmp -s "$T/before" "$T/after_no"
WMR_TEST_TYPED=APPLY R apply 1.1.14 --apply > "$T/o6"
check "apply: took the new change_macros.cfg" grep -q "# wm changed" "$C/change_macros.cfg"
check "apply: added new.cfg" test -f "$C/new.cfg"
check "apply: merged macros.cfg keeps my line and adds theirs" bash -c "grep -q '# my note' $C/macros.cfg && grep -q '# wm change at the end' $C/macros.cfg"
check "apply: printer.cfg untouched" bash -c "grep -q 'include mine.cfg' $C/printer.cfg && ! grep -q '# wm printer' $C/printer.cfg"
check "apply: conflicting moonraker.conf untouched, theirs saved aside" bash -c "grep -q '# my moonraker line' $C/moonraker.conf && ! grep -q '# wm line' $C/moonraker.conf && ls $WMR_HOME/conflicts/1.1.14/printer_data/config/moonraker.conf.theirs"
check "apply: nothing deleted for the removed extruder3.cfg" test -f "$C/extruder3.cfg"
check "apply: backup written" bash -c "ls $WMR_HOME/backups/1.1.14-*.tgz"
check "log has the apply" bash -c "python3 $PY log | grep -q apply"
WMR_TEST_TYPED=ROLLBACK R rollback > "$T/o7"
( cd "$T/live" && find . -type f | sort | xargs sha256sum ) > "$T/after_rb"
check "rollback restores every file exactly (and removes new.cfg)" cmp -s "$T/before" "$T/after_rb"
# print guard
cat > "$T/srv.py" <<'PY'
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200); s.send_header("Content-Type","application/json"); s.end_headers()
        s.wfile.write(json.dumps({"result":{"status":{"print_stats":{"state":"printing"}}}}).encode())
    def log_message(*a): pass
http.server.HTTPServer(("127.0.0.1",18765),H).serve_forever()
PY
python3 "$T/srv.py" & SRV=$!; sleep 1
WMR_MOONRAKER=http://127.0.0.1:18765 WMR_TEST_TYPED=APPLY R apply 1.1.14 --apply > "$T/o8"
( cd "$T/live" && find . -type f | sort | xargs sha256sum ) > "$T/after_pr"
check "apply refuses while a print is running" bash -c "grep -q 'a print is running' $T/o8"
check "...and changed nothing" cmp -s "$T/before" "$T/after_pr"
# MCU
mkdir -p "$T/mcu_ok"; cp "$REPO/factory/ultra-s/mcu/"* "$T/mcu_ok/"
R mcu "$T/mcu_ok" > "$T/o9"
check "mcu: same package -> nothing new" grep -q "Nothing new to flash" "$T/o9"
check "mcu: md5 of every part ok" bash -c "grep -c ' ok ' $T/o9 | grep -q 4"
R mcu "$T/rel/mcu_update" > "$T/o10"
check "mcu: new main MCU version noticed, never flashes" bash -c "grep -q 'New firmware for: MCU' $T/o10 && grep -q 'never flashes' $T/o10"
check "mcu: warns when can0 is missing" bash -c "[ -d /sys/class/net/can0 ] || grep -q 'can0 is not up' $T/o10"
cp "$T/rel/mcu_update/klipper.bin" "$T/bad.bin"; mkdir -p "$T/mcu_bad"; cp "$T/rel/mcu_update/"* "$T/mcu_bad/"; echo corrupt >> "$T/mcu_bad/klipper.bin"
R mcu "$T/mcu_bad" > "$T/o11"
check "mcu: a damaged .bin is flagged and not offered" bash -c "grep -q 'BAD' $T/o11 && grep -q 'do NOT flash' $T/o11 && ! grep -q 'New firmware for: MCU' $T/o11"
R checklist 1.1.14 > "$T/o12"
check "checklist: base items and ones from the diff (macros)" bash -c "grep -q 'Homing' $T/o12 && grep -q 'Macros changed' $T/o12"
R notes 1.1.14 --add "re-check offsets" > "$T/o13"
check "notes: saved" grep -q "re-check offsets" "$T/o13"

# ---- board-wide snapshot: baseline = the version before, promote, every .py
export WMR_HOME="$T/data2" WMR_LIVE_HOME="$T/live2"; mkdir -p "$T/live2"
mk() { # dir version
    mkdir -p "$1"/klipper/klippy/extras "$1"/moonraker/moonraker "$1"/printer_data/config "$1"/mcu_update "$1"/TM_T1/scripts "$1"/TM_T1/bin "$1"/fluidd/assets "$1"/etc/systemd/system "$1"/etc/udev/rules.d "$1"/_meta
    echo "x = 1" > "$1/klipper/klippy/extras/a.py"; echo "y = 1" > "$1/moonraker/moonraker/b.py"; echo "[mcu]" > "$1/printer_data/config/c.cfg"
    echo "app" > "$1/TM_T1/bin/client"; echo "state 1" > "$1/TM_T1/bin/plr.ini"; echo "js" > "$1/fluidd/assets/app.js"; echo "[Service]" > "$1/etc/systemd/system/klipper.service"
    echo "r" > "$1/etc/udev/rules.d/99-wm-can0.rules"; echo "r" > "$1/etc/udev/rules.d/70-other.rules"
    echo "2026-10-16 03:15:03: Add System_$2" > "$1/iso_version.txt"
    printf 'pyserial==3.4\njinja2==2.11.3\n' > "$1/_meta/klippy-env.txt"; printf 'tornado==6.1\n' > "$1/_meta/moonraker-env.txt"
}
mk "$T/b1" 1.1.13; mk "$T/b2" 1.1.14
echo "x = 2" > "$T/b2/klipper/klippy/extras/a.py"; echo "z = 1" > "$T/b2/klipper/klippy/extras/newmod.py"
echo "app2" > "$T/b2/TM_T1/bin/client"; echo "state 2" > "$T/b2/TM_T1/bin/plr.ini"; echo "js2" > "$T/b2/fluidd/assets/app.js"
echo "[Service]
Restart=always" > "$T/b2/etc/systemd/system/klipper.service"; echo "r2" > "$T/b2/etc/udev/rules.d/70-other.rules"; echo "r2" > "$T/b2/etc/udev/rules.d/99-wm-can0.rules"
printf 'pyserial==3.5\njinja2==2.11.3\n' > "$T/b2/_meta/klippy-env.txt"
R init-baseline --from-dir "$T/b1" > "$T/p1"
check "baseline from a snapshot: version read from iso_version.txt" grep -q "Baseline 1.1.13 recorded" "$T/p1"
cp -a "$T/b1/klipper" "$T/b1/moonraker" "$T/b1/printer_data" "$T/live2/"; mkdir -p "$T/live2/printer_data"; cp -a "$T/b1/printer_data" "$T/live2/"
R fetch --from-dir "$T/b2" > "$T/p2"
check "fetch records checksums of the rest of the board" grep -q "other files by checksum\|by checksum" "$T/p2"
R diff 1.1.14 > "$T/p3"
check "diff covers every .py (changed and new, printer and board folders)" bash -c "sed -n '/^== Python files/,/^==/p' $T/p3 | grep -q 'klippy/extras/a.py' && sed -n '/^== Python files/,/^==/p' $T/p3 | grep -q 'newmod.py'"
check "diff covers the screen app, Fluidd, services and udev rules (checksums)" bash -c "grep -q 'TM_T1/bin/client' $T/p3 && grep -q 'fluidd/assets/app.js' $T/p3 && grep -q 'etc/systemd/system/klipper.service' $T/p3 && grep -q 'etc/udev/rules.d/99-wm-can0.rules' $T/p3"
check "diff ignores runtime data (plr.ini) and unrelated udev rules" bash -c "! grep -q 'plr.ini' $T/p3 && ! grep -q '70-other' $T/p3"
check "diff shows changed pip packages" grep -q "pyserial *3.4 -> 3.5" "$T/p3"
check "diff of the board-wide folders never applies anything" bash -c "R() { python3 $PY \"\$@\" 2>&1; }; R apply 1.1.14 | grep -qv 'fluidd/assets'"
# the baseline is the version BEFORE the release being compared
mk "$T/b3" 1.1.15; echo "x = 3" > "$T/b3/klipper/klippy/extras/a.py"
R promote 1.1.14 > "$T/p4"
R fetch --from-dir "$T/b3" > "$T/p5"
R diff 1.1.15 > "$T/p6"
check "promote: 1.1.14 becomes a baseline" grep -q "now a baseline" "$T/p4"
check "diff 1.1.15 compares with 1.1.14 (the version before), not 1.1.13" bash -c "head -1 $T/p6 | grep -q 'baseline 1.1.14'"
check "diff 1.1.14 still uses 1.1.13 as its baseline" bash -c "head -1 $T/p3 | grep -q 'baseline 1.1.13'"
check "no baseline older than the release -> clear message" bash -c "python3 $PY diff 1.1.13 2>&1 | grep -q 'no baseline older than 1.1.13'"
echo; echo "passed: $pass  failed: $fail"; [ "$fail" = 0 ]
