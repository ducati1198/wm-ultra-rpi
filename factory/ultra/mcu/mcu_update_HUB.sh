#!/bin/bash
set -e #遇到错误就退出

KLIPPER_BIN="/home/t13dp/mcu_update/klipper_HUB.bin"
CANBUS_UUID=$(awk -F': ' '/\[mcu HUB\]/{found=1;next} found && /canbus_uuid/{print $2; exit}' /home/t13dp/printer_data/config/wm_zru_hub.cfg)

/home/t13dp/klippy-env/bin/python /home/t13dp/klipper/scripts/flashtool.py -i can0 -f $KLIPPER_BIN -u $CANBUS_UUID
# curl http://127.0.0.1/printer/firmware_restart -d 0
