#!/bin/bash
# Version: 1.4
# Update Time: 2025.06.03
# Author: C.R.Y.

HOME="/home/t13dp"

rm ${HOME}/TM_T1/bin/*.log -rf
rm ${HOME}/printer_data/logs/* -rf

logrotate -f /etc/logrotate.conf
journalctl --vacuum-size=1K
rm /var/log/rsyslog-rotate/* -rf
rm /var/log/journal/* -rf

sync