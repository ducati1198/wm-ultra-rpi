#!/bin/bash
# Version: 1.3
# Update Time: 2025.06.03
# Author: C.R.Y.

HOME="/home/t13dp"

bash "${HOME}/TM_T1/scripts/clear_log.sh"
rm ${HOME}/printer_data/config/*.bak
rm ${HOME}/printer_data/config/printer-*.cfg
rm ${HOME}/printer_data/gcodes/*.gcode
rm ${HOME}/printer_data/gcodes/.thumbs -rf

rm ${HOME}/TM_T1_OTA -rf
rm ${HOME}/just_updated -rf

# clean console history & viminfo
rm ${HOME}/.bash_history -rf
rm ${HOME}/.viminfo -rf
rm /root/.bash_history -rf
rm /root/.viminfo -rf
history -c