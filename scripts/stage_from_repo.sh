#!/bin/bash
# Builds a stage folder from the factory files that are inside this repository (no printer needed).
#
#   ./stage_from_repo.sh <model> <stage-dir> [modules-dir]
#
#   model        ultra-s   (ultra: not available yet, see factory/README.md)
#   modules-dir  folder holding WonderMaker's 5 compiled modules (*.so). They are NOT in this repo
#                (no source, no license to redistribute). Without it the stage is built anyway,
#                but heaters, load cells and tool calibration will not work.
#
# Every file is checked against checksums before it is used. Modules that do not match the
# factory checksums are refused.
set -eu
MODEL="${1:-}"; STAGE="${2:-}"; MODS="${3:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"; SRC="$HERE/factory/$MODEL"
[ -n "$MODEL" ] && [ -n "$STAGE" ] || { echo "Usage: $0 <model> <stage-dir> [modules-dir]"; exit 1; }
[ -d "$SRC" ] || { echo "No factory files for model '$MODEL' in this repository (see factory/README.md)."; exit 1; }
( cd "$SRC" && sha256sum -c SHA256SUMS >/dev/null ) || { echo "Checksum of the factory files does not match: the repository copy is damaged or changed."; exit 1; }

mkdir -p "$STAGE"; W="$(mktemp -d "$STAGE/.work.XXXXXX")"; trap 'rm -rf "$W"' EXIT
tar xzf "$SRC/klipper.tgz" -C "$W"; tar xzf "$SRC/moonraker.tgz" -C "$W"

MODULES_OK=0
if [ -n "$MODS" ]; then
  [ -d "$MODS" ] || { echo "Modules folder not found: $MODS"; exit 1; }
  while read -r sum path; do
    f="$(basename "$path")"
    [ -f "$MODS/$f" ] || { echo "Missing module: $f"; exit 1; }
    [ "$(sha256sum "$MODS/$f" | cut -d' ' -f1)" = "$sum" ] || { echo "$f is not the factory file (checksum differs). Refused."; exit 1; }
    cp "$MODS/$f" "$W/klipper/$path"
  done < "$SRC/modules.sha256"
  MODULES_OK=1; echo "Compiled modules: all 5 match the factory checksums."
else
  echo "Compiled modules: NOT included. Klipper will not run the heaters, load cells or calibration until they are added."
fi

mkdir -p "$W/printer_data/config" "$W/printer_data/systemd" "$W/printer_data/gcodes" "$W/fluidd" "$W/TM_T1/factory_settings"
cp "$SRC/config/"* "$W/printer_data/config/"
cp "$SRC/config/"* "$W/TM_T1/factory_settings/"
cp "$HERE/config/env/"*.env "$W/printer_data/systemd/"
tar czf "$STAGE/klipper.tgz"   -C "$W" klipper
tar czf "$STAGE/moonraker.tgz" -C "$W" moonraker
tar czf "$STAGE/data.tgz"      -C "$W" printer_data fluidd TM_T1
echo "$MODULES_OK" > "$STAGE/modules_ok"
echo "Done: factory files for '$MODEL' in $STAGE"
