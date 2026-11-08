#!/bin/bash
# Tests for wm_release.py on throwaway folders. Run: bash tools/wm-release/test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; PY="$HERE/wm_release.py"
# repo root, however deep this folder sits
REPO="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO" ] && [ -d "$REPO/factory/ultra-s" ] || { d="$HERE"; for _ in 1 2 3 4 5; do [ -d "$d/factory/ultra-s" ] && REPO="$d" && break; d="$(dirname "$d")"; done; }
T="$(mktemp -d)"; trap 'rm -rf "$T"; [ -n "${SRV:-}" ] && kill $SRV 2>/dev/null' EXIT
mkdir -p "$T/wiki"; printf '<a href="/tm_t1_soc(1.1.08).zip">V1.1.08</a><a href="/tm_t1_soc(1.1.13).zip">V1.1.13</a><a href="/tm_t1_soc(1.1.12).zip">x</a><a href="/1.0.71.zip">old</a>' > "$T/wiki/page.html"
export WMR_WIKI_URL="file://$T/wiki/page.html"
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
R check > "$T/ck1"
check "check: finds the newest published version (1.1.13, not by text order)" grep -q "Newest published:      1.1.13" "$T/ck1"
check "check: up to date against the saved baseline" grep -q "up to date" "$T/ck1"
printf '<a href="/tm_t1_soc(1.1.15).zip">V1.1.15</a><a href="/tm_t1_soc(1.1.9).zip">x</a>' > "$T/wiki/page.html"
R check > "$T/ck2"
check "check: reports a NEW version when the page lists a newer one" grep -q "NEW: WonderMaker published 1.1.15" "$T/ck2"
check "menu banner shows the new version" bash -c "printf '0\n' | python3 $PY menu 2>&1 | grep -q 'WonderMaker page:.*NEW'"
check "menu has the check item" bash -c "printf 'c\n0\n' | python3 $PY menu 2>&1 | grep -q 'Newest published:      1.1.15'"
WMR_WIKI_URL="file://$T/wiki/missing.html" R check > "$T/ck3"; 
check "check: unreadable page gives a clear message" grep -q "could not read" "$T/ck3"
check "menu still works when the page cannot be read" bash -c "printf '0\n' | WMR_WIKI_URL=file://$T/wiki/missing.html python3 $PY menu 2>&1 | grep -q 'could not be read'"
printf '<a href="/tm_t1_soc(1.1.13).zip">V1.1.13</a>' > "$T/wiki/page.html"
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

# ---- menu
printf 's\nboardx\n\n0\n' | python3 "$PY" > "$T/m1" 2>&1
check "menu opens with no command and shows the status" bash -c "grep -q 'Baseline (version before):  1.1.13, 1.1.14' $T/m1 && grep -q 'Fetched new version:        1.1.14, 1.1.15' $T/m1"
check "menu remembers the board address" bash -c "grep -q boardx $WMR_HOME/config.json && printf '0\n' | python3 $PY | grep -q 'Board address:              boardx'"
printf '4\n1.1.14\n\n0\n' | python3 "$PY" > "$T/m2" 2>&1
check "menu: show the differences for a chosen release" grep -q "Python files changed or new" "$T/m2"
printf '6\n1.1.14\nno\n\n0\n' | python3 "$PY" > "$T/m3" 2>&1
check "menu: apply shows the plan and does not apply unless you type yes" bash -c "grep -q 'Plan for release 1.1.14' $T/m3 && grep -q 'Dry run' $T/m3"
printf '3\n\n0\n' | WMR_HOME="$T/empty" python3 "$PY" > "$T/m4" 2>&1
check "menu: a step that cannot run explains and returns to the menu (no address)" bash -c "grep -q 'which board' -i $T/m4 && grep -q 'Choose' $T/m4"
printf '4\n\n0\n' | WMR_HOME="$T/empty" python3 "$PY" > "$T/m5" 2>&1
check "menu: differences before any fetch says what to do first" grep -q "use step 2 first" "$T/m5"
printf '' | python3 "$PY" > "$T/m6" 2>&1; check "menu: closing the input ends it cleanly" test $? -eq 0
# ---- line endings: a CRLF copy of an unchanged file is harmless; a real WonderMaker change still merges
export WMR_HOME="$T/data3" WMR_LIVE_HOME="$T/live3"; mkdir -p "$T/live3"
mk "$T/c1" 1.1.13; mk "$T/c2" 1.1.14
printf 'a = 1\nb = 2\nc = 3\n' > "$T/c1/klipper/klippy/extras/a.py"; printf 'a = 1\nb = 2\nc = 3\n' > "$T/c2/klipper/klippy/extras/a.py"
printf 'one\ntwo\n' > "$T/c1/printer_data/config/c.cfg"; printf 'one\ntwo\n' > "$T/c2/printer_data/config/c.cfg"
printf '[mcu]\nx: 1\n' > "$T/c1/printer_data/config/d.cfg"; printf '[mcu]\nx: 1\ny: 2\n' > "$T/c2/printer_data/config/d.cfg"
R init-baseline --from-dir "$T/c1" >/dev/null; R fetch --from-dir "$T/c2" >/dev/null
cp -a "$T/c1/klipper" "$T/c1/printer_data" "$T/live3/"
printf 'a = 1\r\nb = 2\r\nc = 3\r\n' > "$T/live3/klipper/klippy/extras/a.py"; printf 'one  \ntwo' > "$T/live3/printer_data/config/c.cfg"; printf '[mcu]\r\nx: 1\r\n' > "$T/live3/printer_data/config/d.cfg"
R diff 1.1.14 > "$T/w1"
check "CRLF / trailing-space copies are WHITESPACE, not a change of yours" bash -c "sed -n '/^== WHITESPACE/,/^==/p' $T/w1 | grep -q 'klippy/extras/a.py' && sed -n '/^== WHITESPACE/,/^==/p' $T/w1 | grep -q 'c.cfg'"
check "a WonderMaker change on top of a CRLF copy is TAKE, not a conflict" bash -c "sed -n '/^== TAKE/,/^==/p' $T/w1 | grep -q 'd.cfg' && ! grep -q '^== CONFLICT' $T/w1"
WMR_TEST_TYPED=APPLY R apply 1.1.14 --apply >/dev/null
check "...and it is applied" grep -q "y: 2" "$T/live3/printer_data/config/d.cfg"
check "dup-macro list skips printer-<date>.cfg backups" bash -c "! grep -q 'printer-2026' $T/w1"

# ---- option 1 (all steps) and the board login (fake ssh and rsync; the password must never be on a command line or saved)
mkdir -p "$T/bin" "$T/tmp"
cat > "$T/bin/ssh" <<'FS'
#!/bin/bash
echo "ssh $*" >> "$FAKE_LOG"
a="$*"
[[ "$a" == *"-O exit"* ]] && { echo "closed" >> "$FAKE_LOG"; exit 0; }
if [[ "$a" == *" -M "* ]]; then
  if [[ "$a" == *"BatchMode=yes"* ]]; then [ "${FAKE_PASSWORDLESS:-0}" = 1 ] && exit 0; echo "Permission denied" >&2; exit 255; fi
  pw=$("$SSH_ASKPASS"); echo "askpass-env:${WMR_ASKPASS_PW:+set} force:${SSH_ASKPASS_REQUIRE:-}" >> "$FAKE_LOG"
  [ "$pw" = "$FAKE_PW" ] && exit 0; echo "Permission denied (password)" >&2; exit 255
fi
cmd="${@: -1}"
case "$cmd" in
  *iso_version*) cat "$FAKE_BOARD/iso_version.txt" ;;
  *"pip freeze"*) f="$FAKE_BOARD/_meta/klippy-env.txt"; [[ "$cmd" == *moonraker-env* ]] && f="$FAKE_BOARD/_meta/moonraker-env.txt"; cat "$f" 2>/dev/null ;;
esac
exit 0
FS
cat > "$T/bin/rsync" <<'FS'
#!/bin/bash
src="${@: -2:1}"; dst="${@: -1}"; rel="${src#*:~/}"; rel="${rel%/}"
[ -d "$FAKE_BOARD/$rel" ] && cp -a "$FAKE_BOARD/$rel/." "$dst"; exit 0
FS
chmod +x "$T/bin/ssh" "$T/bin/rsync"
export FAKE_LOG="$T/fake.log" FAKE_PW=secret123 TMPDIR="$T/tmp"
export WMR_SOURCE=board   # these option-1 tests cover the board path
export WMR_HOME="$T/data4" WMR_LIVE_HOME="$T/live4"; mkdir -p "$T/live4"; cp -a "$T/b1/klipper" "$T/b1/moonraker" "$T/b1/printer_data" "$T/b1/mcu_update" "$T/b1/TM_T1" "$T/live4/" 2>/dev/null
run() { PATH="$T/bin:$PATH" setsid -w python3 "$PY" "$@"; }   # setsid: no terminal, so the hidden password prompt reads the piped line
# A: nothing saved yet, the board needs a password (first one wrong)
: > "$FAKE_LOG"
printf '1\n10.9.9.9\npi_user\nwrong-one\nsecret123\ny\n\n0\n' | FAKE_BOARD="$T/b1" run > "$T/a1" 2>&1
check "option 1: asks the board address, user name and password, and saves the baseline" bash -c "grep -q 'wants a login' $T/a1 && grep -q 'Login failed' $T/a1 && grep -q 'Baseline 1.1.13 recorded' $T/a1 && test -d $WMR_HOME/baseline/1.1.13"
check "the password never appears on a command line or in the saved files" bash -c "! grep -q 'secret123\|wrong-one' $T/fake.log && ! grep -rq 'secret123\|wrong-one' $WMR_HOME"
check "the password goes to ssh only through the one-shot helper (SSH_ASKPASS, env), and the helper is removed" bash -c "grep -q 'askpass-env:set force:force' $T/fake.log && ! ls $T/tmp/wmr-*/askpass.sh 2>/dev/null"
check "the user name is remembered, the connection is closed and its temp folder removed" bash -c "grep -q pi_user $WMR_HOME/config.json && grep -q '^closed' $T/fake.log && [ -z \"\$(ls $T/tmp)\" ]"
check "one login serves every step (only one master connection was opened)" bash -c "[ \$(grep -c ' -M ' $T/fake.log) -ge 1 ] && [ \$(grep -c 'BatchMode=no' $T/fake.log) -eq 2 ]"
# B: board still on 1.1.13 = same as the baseline
printf '1\n\n\n0\n' | FAKE_PASSWORDLESS=1 FAKE_BOARD="$T/b1" run > "$T/a2" 2>&1
check "option 1: same version as the baseline -> nothing new, no password asked" bash -c "grep -q 'nothing new to bring over' $T/a2 && ! grep -q 'wants a login' $T/a2"
# C: the board was updated to 1.1.14: fetch, diff, MCU, plan, then answer no
printf '1\n\nno\n\n0\n' | FAKE_PASSWORDLESS=1 FAKE_BOARD="$T/b2" run > "$T/a3" 2>&1
check "option 1: new version -> fetch, compare, MCU check, plan" bash -c "grep -q '\[3/6\] Fetching System 1.1.14' $T/a3 && grep -q 'Python files changed or new' $T/a3 && grep -q 'MCU firmware' $T/a3 && grep -q 'Plan for release 1.1.14' $T/a3 && test -d $WMR_HOME/releases/1.1.14"
check "...and answering no applies nothing" bash -c "grep -q 'Nothing applied' $T/a3 && ! test -f $T/live4/klipper/klippy/extras/newmod.py"
# D: answer yes
printf '1\n\nyes\nn\n\n0\n' | WMR_TEST_TYPED=APPLY FAKE_PASSWORDLESS=1 FAKE_BOARD="$T/b2" run > "$T/a4" 2>&1
check "option 1: yes -> backup, apply, test list, and the baseline is kept until you say so" bash -c "test -f $T/live4/klipper/klippy/extras/newmod.py && ls $WMR_HOME/backups/1.1.14-*.tgz && grep -q 'Test list after WonderMaker 1.1.14' $T/a4 && ! test -d $WMR_HOME/baseline/1.1.14"
printf 'all\n' >/dev/null
check "option 1 always asks for the board address (shows the saved one; Enter keeps it)" bash -c "grep -q 'Board address (the WonderMaker screen board' $T/a2 && grep -q '10.9.9.9' $T/a2"
check "...and a different address typed there is used and remembered" bash -c "printf '10.8.8.8\n' | FAKE_PASSWORDLESS=1 FAKE_BOARD=$T/b1 PATH=$T/bin:\$PATH setsid -w python3 $PY all > $T/a6 2>&1; grep -q 'Logging in to the board 10.8.8.8' $T/a6 && grep -q 10.8.8.8 $WMR_HOME/config.json"
printf '\n' | FAKE_PASSWORDLESS=1 FAKE_BOARD="$T/b1" run all > "$T/a5" 2>&1
check "the command line has it too: wm_release.py all" grep -q "Board runs System" "$T/a5"

# ---- TM_T1_SOC on the Pi: --from-soc, --from-web, firmware archive, compare, settings, option 1 web path, flash
# a tiny but real System package, encrypted exactly like WonderMaker's: .deb -> openssl AES-256-CBC "tmt1-mks" -> XOR "tmt1-mks"
unset WMR_SOURCE
cat > "$T/mksoc.py" <<'PYEOF'
import io, os, subprocess, sys, tarfile, zipfile
ver, macros, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
def tgz(files):
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode="w:gz") as t:
        for name, data in files.items():
            ti = tarfile.TarInfo(name); ti.size = len(data); t.addfile(ti, io.BytesIO(data))
    return b.getvalue()
ctl = tgz({"./control": ("Package: TM-T1-System\nVersion: %s\nArchitecture: arm64\n" % ver).encode()})
data = {"./home/t13dp/printer_data/config/macros.cfg": macros.encode(),
        "./home/t13dp/printer_data/config/printer.cfg": b"[include macros.cfg]\n",
        "./home/t13dp/klipper/klippy/x.py": b"print(1)\n",
        "./home/t13dp/TM_T1/scripts/s.sh": b"echo hi\n",
        "./home/t13dp/boot.img": b"ANDROID!fake-kernel",
        "./etc/systemd/system/makerbase-ap.service": b"[Unit]\n"}
if ver != "1.2.0": data["./home/t13dp/printer_data/config/new_%s.cfg" % ver.replace(".", "")] = b"# new\n"
dat = tgz(data)
def member(name, blob):
    h = "%-16s%-12s%-6s%-6s%-8s%-10s`\n" % (name, "0", "0", "0", "100644", len(blob))
    return h.encode() + blob + (b"\n" if len(blob) % 2 else b"")
deb = b"!<arch>\n" + member("debian-binary", b"2.0\n") + member("control.tar.gz", ctl) + member("data.tar.gz", dat)
enc = subprocess.run(["openssl", "enc", "-aes-256-cbc", "-md", "sha256", "-salt", "-k", "tmt1-mks"],
                     input=deb, capture_output=True, check=True).stdout
k = b"tmt1-mks"; soc = bytes(b ^ k[i % 8] for i, b in enumerate(enc))
open(os.path.join(out_dir, "TM_T1_SOC_%s" % ver), "wb").write(soc)
with zipfile.ZipFile(os.path.join(out_dir, "tm_t1_soc(%s).zip" % ver), "w") as z:
    z.writestr("TM_T1_SOC", soc); z.writestr("boot.img", b"x")
PYEOF
mkdir -p "$T/web"
python3 "$T/mksoc.py" 1.2.0 "# macros v120" "$T/web"
python3 "$T/mksoc.py" 1.2.1 "# macros v121" "$T/web"
printf '<a href="tm_t1_soc(1.2.0).zip">1.2.0</a> <a href="tm_t1_soc(1.2.1).zip">1.2.1</a>' > "$T/web/fw.html"
export WMR_WIKI_URL="file://$T/web/fw.html" WMR_FIRMWARE_DIR="$T/fwstore"
export WMR_HOME="$T/data5" WMR_LIVE_HOME="$T/live5"; mkdir -p "$T/live5"

R fetch --from-soc "$T/web/TM_T1_SOC_1.2.0" > "$T/s1"
check "fetch --from-soc decrypts a TM_T1_SOC and records the release" bash -c "grep -q 'Release 1.2.0 copied' $T/s1 && grep -q 'v120' $WMR_HOME/releases/1.2.0/printer_data/config/macros.cfg"
check "...the SoC boot.img is never part of the release" bash -c "! find $WMR_HOME/releases/1.2.0 -name boot.img | grep -q ."
check "...a wrong key is refused clearly" bash -c "WMR_SOC_KEY=wrong python3 $PY fetch --from-soc $T/web/TM_T1_SOC_1.2.0 2>&1 | grep -q 'does not look like a TM_T1_SOC'"
R fetch --from-web > "$T/s2"
check "fetch --from-web takes the newest version from the firmware page" bash -c "grep -q 'Downloading System 1.2.1' $T/s2 && grep -q 'v121' $WMR_HOME/releases/1.2.1/printer_data/config/macros.cfg"
check "...and keeps the zip in the firmware archive" test -f "$T/fwstore/tm_t1_soc(1.2.1).zip"
R firmware > "$T/s3"
check "firmware lists the saved versions" grep -q "1.2.1" "$T/s3"
rm -rf "$WMR_HOME/releases/1.2.1"; R fetch --from-web 1.2.1 > "$T/s4"
check "a second download of the same version uses the archived copy (no network)" grep -q "Using the archived copy of System 1.2.1" "$T/s4"
check "fetch --from-archive refuses a version that is not saved" bash -c "python3 $PY fetch --from-archive 9.9.9 2>&1 | grep -q 'no archived firmware for 9.9.9'"
rm -rf "$WMR_HOME/releases/1.2.1"; R fetch --from-archive 1.2.1 > "$T/s5"
check "fetch --from-archive reinstalls a saved version offline" bash -c "grep -q 'Using archived System 1.2.1' $T/s5 && test -d $WMR_HOME/releases/1.2.1"
R compare 1.2.0 1.2.1 > "$T/s6"
check "compare shows what WonderMaker changed between two versions" bash -c "grep -q 'CHANGED  printer_data/config/macros.cfg' $T/s6 && grep -q 'ADDED    printer_data/config/new_121.cfg' $T/s6"
check "...and changes nothing in your live files" bash -c "[ -z \"\$(ls -A $WMR_LIVE_HOME)\" ]"
R settings > "$T/s7"
check "settings shows the decrypt key, firmware URL and firmware store" bash -c "grep -q 'decrypt key   : tmt1-mks' $T/s7 && grep -q 'fw.html' $T/s7 && grep -q 'fwstore' $T/s7"
python3 -c "import json,os; p=os.environ['WMR_HOME']+'/config.json'; c=json.load(open(p)) if os.path.exists(p) else {}; c['soc_key']='badkey'; json.dump(c,open(p,'w'))"
check "a decrypt key saved in settings is used" bash -c "python3 $PY fetch --from-soc $T/web/TM_T1_SOC_1.2.0 2>&1 | grep -q 'does not look like a TM_T1_SOC'"
python3 -c "import json,os; p=os.environ['WMR_HOME']+'/config.json'; c=json.load(open(p)); c.pop('soc_key'); json.dump(c,open(p,'w'))"

# option 1, website path
export WMR_HOME="$T/data6" WMR_LIVE_HOME="$T/live6"; mkdir -p "$T/live6"
printf 'web\ny\n' | python3 "$PY" all > "$T/w1" 2>&1
check "option 1 asks where from, and on the website path with no baseline offers to record one" bash -c "grep -q 'old screen board, or WonderMaker' $T/w1 && grep -q 'Baseline 1.2.1 recorded' $T/w1"
printf '' | WMR_SOURCE=web python3 "$PY" all > "$T/w2" 2>&1
check "...then says up to date while nothing newer is published" grep -q "Up to date: newest published is 1.2.1" "$T/w2"
export WMR_HOME="$T/data7" WMR_LIVE_HOME="$T/live7"; mkdir -p "$T/live7"
R init-baseline --from-web 1.2.0 > /dev/null
cp -a "$WMR_HOME/baseline/1.2.0/." "$T/live7/"; rm -f "$T/live7/_manifest.json" "$T/live7/iso_version.txt"
echo "# my own line" >> "$T/live7/TM_T1/scripts/s.sh"
printf 'no\n' | WMR_SOURCE=web python3 "$PY" all > "$T/w3" 2>&1
check "option 1 web: downloads the newer version, compares, shows the plan" bash -c "grep -q 'Downloading System 1.2.1' $T/w3 && grep -q 'TAKE   printer_data/config/macros.cfg' $T/w3 && grep -q 'ADD    printer_data/config/new_121.cfg' $T/w3"
check "...your own change is kept, and answering no applies nothing" bash -c "grep -q 'Nothing applied' $T/w3 && grep -q 'v120' $T/live7/printer_data/config/macros.cfg"
printf 'yes\ny\n' | WMR_SOURCE=web WMR_TEST_TYPED=APPLY python3 "$PY" all > "$T/w4" 2>&1
check "option 1 web: yes -> backup, apply (your edit kept), baseline promoted" bash -c "grep -q 'v121' $T/live7/printer_data/config/macros.cfg && grep -q 'my own line' $T/live7/TM_T1/scripts/s.sh && test -d $WMR_HOME/baseline/1.2.1 && ls $WMR_HOME/backups/*.tgz"
check "apply writes ~/iso_version.txt with the applied version" bash -c "grep -qx System_1.2.1 $T/live7/iso_version.txt"
R status > "$T/st9"
check "status shows the machine's version" grep -q "iso_version.txt says: 1.2.1" "$T/st9"
check "rollback puts the old iso_version.txt back" bash -c "WMR_TEST_TYPED=ROLLBACK python3 $PY rollback >/dev/null 2>&1; ! grep -q System_1.2.1 $T/live7/iso_version.txt"
echo System_1.2.1 > "$T/live7/iso_version.txt"

# guarded MCU flash
mkdir -p "$T/live7/mcu_update"; printf '#!/bin/bash\necho flashed > "%s/flashed"\n' "$T" > "$T/live7/mcu_update/mcu_update.sh"
R flash > "$T/f1"
check "flash is a dry run unless --run, and names what it would run" bash -c "grep -q 'Dry run: nothing was flashed' $T/f1 && grep -q 'mcu_update.sh' $T/f1 && ! test -f $T/flashed"
check "flash --run does nothing unless you type FLASH" bash -c "WMR_TEST_TYPED=nope python3 $PY flash --run | grep -q 'Nothing flashed' && ! test -f $T/flashed"
check "flash --run + FLASH runs the board's own flash script" bash -c "WMR_TEST_TYPED=FLASH python3 $PY flash --run >/dev/null && test -f $T/flashed"
check "flash refuses an unknown board name" bash -c "python3 $PY flash nosuch 2>&1 | grep -q 'unknown target'"

# clean: delete everything the tool created, nothing else
mkdir -p "$T/fw"; export WMR_FIRMWARE_DIR="$T/fw"; echo z > "$T/fw/tm_t1_soc(9.9.9).zip"
R clean > "$T/clean.out"
check "clean is a dry run: lists data + archive, deletes nothing" bash -c "grep -q 'Dry run - nothing deleted' $T/clean.out && test -d $WMR_HOME/baseline && test -f '$T/fw/tm_t1_soc(9.9.9).zip'"
check "clean --run does nothing unless you type DELETE" bash -c "WMR_TEST_TYPED=nope python3 $PY clean --run >/dev/null 2>&1; test -d $WMR_HOME/baseline"
check "clean --run + DELETE removes the data folder and the archive, not the live files" bash -c "WMR_TEST_TYPED=DELETE python3 $PY clean --run >/dev/null && ! test -e $WMR_HOME && ! test -e $T/fw && test -f $T/live7/printer_data/config/macros.cfg"
check "clean again says already clean" bash -c "python3 $PY clean | grep -q 'already clean'"
mkdir -p "$WMR_HOME/baseline/x" "$T/fw"; echo z > "$T/fw/a.zip"
check "clean --keep-firmware keeps the archive" bash -c "WMR_TEST_TYPED=DELETE python3 $PY clean --run --keep-firmware >/dev/null && test -f $T/fw/a.zip && ! test -e $WMR_HOME"
check "clean refuses a protected location" bash -c "WMR_HOME=$T/live WMR_LIVE_HOME=$T/live python3 $PY clean --run 2>&1 | grep -q refusing; test -d $T/live"

check "the tool has a version: --version, the menu title, status and the history" bash -c "python3 $PY --version | grep -q 'wm_release.py [0-9]' && printf '0\n' | python3 $PY | grep -q 'WonderMaker release tool [0-9]' && python3 $PY status | grep -q 'Tool version: [0-9]' && grep -q '(version 1.4.0)' $HERE/README.md"

echo; echo "passed: $pass  failed: $fail"; [ "$fail" = 0 ]
