#!/bin/bash
# Installs ZR Tools on the machine that runs Klipper + KlipperScreen.
# Run it from the folder that contains zr_tools.py and zr_tools.cfg:
#     bash install_zr_tools.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$HOME/printer_data/config"
KS="$HOME/KlipperScreen"
STAMP=$(date +%Y%m%d_%H%M%S)

[ -f "$CFG/printer.cfg" ] || { echo "No $CFG/printer.cfg - is this the printer host?"; exit 1; }

echo "1) Klipper macros"
if [ -f "$CFG/zr_tools.cfg" ] && ! cmp -s "$HERE/zr_tools.cfg" "$CFG/zr_tools.cfg"; then   # you may have edited it: keep a copy before it is replaced
  cp "$CFG/zr_tools.cfg" "$CFG/zr_tools.cfg.zrbak_$STAMP"
  echo "   zr_tools.cfg changed: your old copy is kept as zr_tools.cfg.zrbak_$STAMP"
fi
cp "$HERE/zr_tools.cfg" "$CFG/zr_tools.cfg"
if ! grep -q '^\[include zr_tools.cfg\]' "$CFG/printer.cfg"; then
  cp "$CFG/printer.cfg" "$CFG/printer.cfg.zrbak_$STAMP"
  sed -i '0,/^\[include /s//[include zr_tools.cfg]\n&/' "$CFG/printer.cfg"
  echo "   added [include zr_tools.cfg] to printer.cfg (backup: printer.cfg.zrbak_$STAMP)"
else
  echo "   printer.cfg already includes zr_tools.cfg"
fi

echo "2) change_macros.cfg: left untouched (pressure advance stays with the slicer)"

echo "3) KlipperScreen panel"
if [ -d "$KS/panels" ]; then
  cp "$HERE/zr_tools.py" "$HERE/zr_views.py" "$HERE/zr_logic.py" "$KS/panels/"
  [ -d "$KS/.git" ] && { mkdir -p "$KS/.git/info"; grep -qs '^panels/zr_' "$KS/.git/info/exclude" || echo 'panels/zr_*.py' >> "$KS/.git/info/exclude"; }
  KSC="$CFG/KlipperScreen.conf"
  touch "$KSC"
  if ! grep -q '^\[menu __main zr_tools\]' "$KSC"; then
    printf '\n[menu __main zr_tools]\nname: ZR Tools\nicon: extruder\npanel: zr_tools\n' >> "$KSC"
    echo "   added 'ZR Tools' to the KlipperScreen main menu"
  fi
else
  echo "   KlipperScreen not found in $KS - copy zr_tools.py to <KlipperScreen>/panels/ yourself"
fi

if [ "${ZR_NO_RESTART:-0}" = 1 ]; then echo "4) Not restarting (the caller does it)"; exit 0; fi
echo "4) Restarting Klipper and KlipperScreen"
sudo systemctl restart klipper
sudo systemctl restart KlipperScreen 2>/dev/null || true
echo "Done. Open 'ZR Tools' from the KlipperScreen main menu."
