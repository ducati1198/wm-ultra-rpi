#!/bin/sh
set -e

IMG="$1"                                # 传入 boot.img 路径
DEV="/dev/block/by-name/boot"           # 目标分区

[ -f "$IMG" ] || { echo "no image"; exit 1; }
[ -e "$DEV" ] || { echo "no boot partition"; exit 1; }

# 1) 备份（可回滚）
echo "[*] backup current boot..."
dd if="$DEV" of=/root/boot.backup.img bs=4M status=progress
sync

# 2) 写入（直写+落盘）
echo "[*] write new boot..."
dd if="$IMG" of="$DEV" bs=4M oflag=direct conv=fsync
sync

# 3) 直接逐字节比较对比
imgsz=$(stat -c%s "$IMG")
echo "[*] verify with cmp..."
if cmp -n "$imgsz" -s "$IMG" "$DEV"; then
  echo "[OK] boot partition matches image"
  #reboot
else
  echo "[!!] mismatch, rollback..."
  dd if=/root/boot.backup.img of="$DEV" bs=4M oflag=direct conv=fsync
  sync
  if cmp -n "$(stat -c%s /root/boot.backup.img)" -s /root/boot.backup.img "$DEV"; then
    echo "[OK] rolled back"
  else
    echo "[ERR] rollback failed, check storage/power"
  fi
fi
