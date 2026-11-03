#!/bin/bash
# Takes the WonderMaker software out of a screen-board disk image (.img or .img.gz) without a printer.
# Needs: debugfs (package e2fsprogs), python3, tar, gzip. Needs free disk space of the image size
# if the image is compressed (it is unpacked first, then removed).
#
#   ./extract_from_image.sh <image.img[.gz]> [stage-dir]
#
# Result: <stage-dir>/{klipper,moonraker,data}.tgz   (same as pull_from_board.sh)
set -eu
IMG="${1:-}"; STAGE="${2:-./stage}"
[ -f "$IMG" ] || { echo "Usage: $0 <image.img[.gz]> [stage-dir]"; exit 1; }
for t in debugfs python3 tar; do command -v $t >/dev/null || { echo "Missing: $t (sudo apt install e2fsprogs python3)"; exit 1; }; done
mkdir -p "$STAGE"; WORK="$(mktemp -d "$STAGE/.work.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT

RAW="$IMG"
case "$IMG" in
  *.gz) need=$(( $(gzip -l "$IMG" | awk 'NR==2{print $2}') / 1048576 ))
        free=$(df -Pm "$WORK" | awk 'NR==2{print $4}')
        [ "$free" -gt "$((need + 500))" ] || { echo "Not enough free space: need about ${need} MB, have ${free} MB."; exit 1; }
        echo "Unpacking image (${need} MB)..."; RAW="$WORK/disk.img"; gzip -dc "$IMG" > "$RAW" ;;
esac

# The root file system is the biggest ext4 partition.
START="$(python3 - "$RAW" <<'PY'
import sys, struct
f = open(sys.argv[1], "rb"); f.seek(0); mbr = f.read(512)
parts = []
if mbr[450] == 0xEE:                       # GPT
    f.seek(512); h = f.read(92)
    lba, n, size = struct.unpack("<Q", h[72:80])[0], struct.unpack("<I", h[80:84])[0], struct.unpack("<I", h[84:88])[0]
    f.seek(lba * 512)
    for i in range(n):
        e = f.read(size)
        if len(e) < 128 or e[:16] == b"\0" * 16: continue
        first, last = struct.unpack("<QQ", e[32:48]); parts.append((last - first + 1, first))
else:                                      # MBR
    for i in range(4):
        e = mbr[446 + 16 * i: 462 + 16 * i]
        start, size = struct.unpack("<II", e[8:16])
        if e[4] not in (0, 5, 15) and size: parts.append((size, start))
if parts: print(sorted(parts)[-1][1])
PY
)"
[ -n "${START:-}" ] || { echo "Could not read the partition table of the image."; exit 1; }
FS="$RAW?offset=$((START * 512))"
debugfs -c -R "stat /home/t13dp/klipper" "$FS" >/dev/null 2>&1 || { echo "No /home/t13dp/klipper in the biggest partition: is this the WonderMaker screen-board image?"; exit 1; }

TREE="$WORK/home"; mkdir -p "$TREE"
dump() { echo "  $1"; debugfs -c -R "rdump /home/t13dp/$1 $TREE/$(dirname "$1" | sed 's#^\.$##')" "$FS" >/dev/null 2>&1 || true; }
mkdir -p "$TREE/printer_data" "$TREE/TM_T1"
dump klipper; dump moonraker; dump fluidd
for d in config database systemd; do dump printer_data/$d; done
for d in factory_settings scripts; do dump TM_T1/$d; done
[ -d "$TREE/klipper/klippy" ] && [ -d "$TREE/moonraker/moonraker" ] || { echo "Extraction failed (klippy or moonraker folder missing)."; exit 1; }
mkdir -p "$TREE/printer_data/gcodes" 
pack() { local n="$1"; shift; tar czf "$STAGE/$n.tgz" -C "$TREE" --exclude=__pycache__ "$@"; }
pack klipper klipper; pack moonraker moonraker
pack data printer_data fluidd $( [ -d "$TREE/TM_T1" ] && echo TM_T1 )
echo "Done: $(du -sh "$STAGE" | cut -f1) in $STAGE"
