#!/bin/bash
# Builds a stage folder from the factory files that are inside this repository (no printer needed).
#
#   ./stage_from_repo.sh <model> <stage-dir> [modules-dir]
#
#   model        ultra-s  or  ultra   (each has its own folder in factory/)
#   modules-dir  optional: folder with your own copies of WonderMaker's 5 compiled modules (*.so).
#                The repository already contains them; yours replace them if they match the checksums.
#
# Every file is checked against checksums before it is used. Modules that do not match the
# factory checksums are refused.
set -eu
MODEL="${1:-}"; STAGE="${2:-}"; MODS="${3:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"; SRC="$HERE/factory/$MODEL"
case "$MODEL" in ultra|ultra-s) ;; *) echo "Unknown model '$MODEL' (use ultra or ultra-s)."; exit 1 ;; esac
[ -n "$MODEL" ] && [ -n "$STAGE" ] || { echo "Usage: $0 <model> <stage-dir> [modules-dir]"; exit 1; }
( cd "$SRC" && sha256sum -c SHA256SUMS >/dev/null ) || { echo "Checksum of the factory files does not match: the repository copy is damaged or changed."; exit 1; }

mkdir -p "$STAGE"; W="$(mktemp -d "$STAGE/.work.XXXXXX")"; trap 'rm -rf "$W"' EXIT
cp -a "$SRC/klipper" "$SRC/moonraker" "$W/"

# The 5 compiled modules ship inside factory/$MODEL/klipper. Optionally replace them with your own copies.
if [ -n "$MODS" ]; then
  [ -d "$MODS" ] || { echo "Modules folder not found: $MODS"; exit 1; }
  while read -r sum path; do
    f="$(basename "$path")"
    [ -f "$MODS/$f" ] || { echo "Missing module: $f"; exit 1; }
    [ "$(sha256sum "$MODS/$f" | cut -d' ' -f1)" = "$sum" ] || { echo "$f is not the factory file (checksum differs). Refused."; exit 1; }
    cp "$MODS/$f" "$W/klipper/$path"
  done < "$SRC/modules.sha256"
fi
MODULES_OK=1
while read -r sum path; do
  [ -f "$W/klipper/$path" ] && [ "$(sha256sum "$W/klipper/$path" | cut -d' ' -f1)" = "$sum" ] || { MODULES_OK=0; echo "Compiled module missing or not factory: $(basename "$path")"; }
done < "$SRC/modules.sha256"
[ "$MODULES_OK" = 1 ] && echo "Compiled modules: all 5 present and match the factory checksums."

mkdir -p "$W/printer_data/config" "$W/printer_data/systemd" "$W/printer_data/gcodes" "$W/fluidd" "$W/TM_T1/factory_settings"
cp "$SRC/config/"* "$W/printer_data/config/"
cp "$SRC/config/"* "$W/TM_T1/factory_settings/"
cp "$HERE/config/env/"*.env "$W/printer_data/systemd/"
cp "$HERE/config/moonraker.asvc" "$W/printer_data/moonraker.asvc"
tar czf "$STAGE/klipper.tgz"   -C "$W" klipper
tar czf "$STAGE/moonraker.tgz" -C "$W" moonraker
tar czf "$STAGE/data.tgz"      -C "$W" printer_data fluidd TM_T1
echo "$MODULES_OK" > "$STAGE/modules_ok"
echo "Done: factory files for '$MODEL' in $STAGE"
