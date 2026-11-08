#!/bin/bash
# Makes sure the ZR Tools macros are on the machine that runs Klipper (the Pi): checks first, installs only what is missing.
# Runs ON the Pi: by the Pi installer (Add-ons) and, over ssh, by the screen board installer.
#   bash ensure_zr_tools_pi.sh            (zr_tools.cfg and install_zr_tools.sh must be next to this script, or in $ZR_SRC)
# Result lines the caller can read:  ZR_RESULT=already | installed | printing | missing-printer-cfg
# ZR_NO_RESTART=1: do not restart Klipper (the caller does it).
set -u
SRC="${ZR_SRC:-$(cd "$(dirname "$0")" && pwd)}"
CFG="${ZR_CFG_DIR:-$HOME/printer_data/config}"
STAMP=$(date +%Y%m%d_%H%M%S)
MR="${ZR_MOONRAKER:-http://127.0.0.1:7125}"

say() { echo "  $*"; }
[ -f "$SRC/zr_tools.cfg" ] && [ -f "$SRC/install_zr_tools.sh" ] || { say "The ZR Tools files are missing next to this script ($SRC)."; echo "ZR_RESULT=error"; exit 1; }
[ -f "$CFG/printer.cfg" ] || { say "No $CFG/printer.cfg: this is not the Klipper machine."; echo "ZR_RESULT=missing-printer-cfg"; exit 2; }

has_include()  { grep -qE '^[[:space:]]*\[include[[:space:]]+zr_tools\.cfg\]' "$CFG/printer.cfg"; }
has_save_vars(){ grep -rqE '^[[:space:]]*\[save_variables\]' "$CFG" --include='*.cfg' 2>/dev/null; }
same_as_bundled(){ [ -f "$CFG/zr_tools.cfg" ] && cmp -s "$SRC/zr_tools.cfg" "$CFG/zr_tools.cfg"; }
# An edited zr_tools.cfg is yours: it counts as installed as long as every macro the screen needs is still in it.
has_all_macros(){ local m; [ -f "$CFG/zr_tools.cfg" ] || return 1; for m in $(grep -oE '^\[gcode_macro +[A-Za-z0-9_]+' "$SRC/zr_tools.cfg" | awk '{print $2}'); do grep -qE "^\[gcode_macro +$m\]" "$CFG/zr_tools.cfg" || return 1; done; }
macros_current(){ if [ "${ZR_REPLACE:-0}" = 1 ]; then same_as_bundled; else has_all_macros; fi; }

echo "Checking the ZR Tools macros on this machine"
if [ ! -f "$CFG/zr_tools.cfg" ]; then say "zr_tools.cfg: missing"
elif same_as_bundled; then say "zr_tools.cfg: present, up to date"
elif has_all_macros && [ "${ZR_REPLACE:-0}" != 1 ]; then say "zr_tools.cfg: present, differs from the bundled copy (edited or older) but has every macro: kept as it is (replace it with ZR_REPLACE=1)"
else say "zr_tools.cfg: present, but macros are missing or you asked to replace it"; fi
has_include   && say "printer.cfg includes zr_tools.cfg: yes" || say "printer.cfg includes zr_tools.cfg: no"
has_save_vars && say "[save_variables] (stores the toolhead info): yes" || say "[save_variables]: missing"

if macros_current && has_include && has_save_vars; then
    echo "ZR Tools macros are already installed and configured on this machine. Nothing was changed."
    echo "ZR_RESULT=already"; exit 0
fi

# A running print must not be interrupted by a Klipper restart: do nothing then.
st="$(curl -fsS -m 5 "$MR/printer/objects/query?print_stats" 2>/dev/null | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p' | head -1)"
case "${ZR_PRINT_STATE:-$st}" in printing|paused) echo "A print is running or paused. Nothing was changed; try again when it is done."; echo "ZR_RESULT=printing"; exit 3 ;; esac

echo "Installing what is missing"
ZR_MACROS_ONLY=1 ZR_NO_RESTART=1 bash "$SRC/install_zr_tools.sh" || { say "install_zr_tools.sh failed."; echo "ZR_RESULT=error"; exit 1; }

# The macros keep the toolhead info in [save_variables]. WonderMaker's printer.cfg has it; add it only when no file in the config folder does.
if ! has_save_vars; then
    cp "$CFG/printer.cfg" "$CFG/printer.cfg.zrbak_${STAMP}_sv"
    printf '\n[save_variables]\nfilename: %s/saved_variables.cfg\n' "$CFG" > "$CFG/.zr_sv_block"
    if grep -q '^#\*# <-* SAVE_CONFIG' "$CFG/printer.cfg"; then
        python3 - "$CFG" <<'PY'
import sys,re
c=sys.argv[1]; p=c+'/printer.cfg'; s=open(p).read(); b=open(c+'/.zr_sv_block').read()
m=re.search(r'^#\*# <-* SAVE_CONFIG',s,re.M); open(p,'w').write(s[:m.start()]+b.lstrip('\n')+'\n'+s[m.start():])
PY
    else cat "$CFG/.zr_sv_block" >> "$CFG/printer.cfg"; fi
    rm -f "$CFG/.zr_sv_block"
    say "added [save_variables] to printer.cfg (backup: printer.cfg.zrbak_${STAMP}_sv)"
fi

if [ "${ZR_NO_RESTART:-0}" = 1 ]; then echo "ZR_RESULT=installed"; exit 0; fi
if curl -fsS -m 15 -X POST "$MR/machine/services/restart?service=klipper" >/dev/null 2>&1; then
    for i in $(seq 1 30); do sleep 2
        s="$(curl -fsS -m 4 "$MR/printer/info" 2>/dev/null | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p' | head -1)"
        [ "$s" = ready ] && { say "Klipper restarted and is ready."; break; }
        [ "$s" = error ] || [ "$s" = shutdown ] && { say "Klipper restarted but reports '$s'. Look at the message in Fluidd."; break; }
    done
else say "Could not restart Klipper by itself: restart it from Fluidd to load the macros."; fi
echo "ZR Tools macros installed and configured."
echo "ZR_RESULT=installed"
