#!/bin/bash
# Version: 1.2
# Update Time: 2025.05.30
# Author: C.R.Y.

HOME="/home/t13dp"

CLIENT_LOG="${HOME}/TM_T1/bin/*.log"
PRINT_LOG="${HOME}/printer_data/logs/*"
ROTATE_LOG="/var/log/rsyslog-rotate/*"
JOURNAL_LOG="/var/log/journal/*"

find ${CLIENT_LOG} ${PRINT_LOG} ${ROTATE_LOG} ${JOURNAL_LOG} -type f -printf "%s\n" | awk '{sum+=$1} END {printf "%.2fMB", sum/1024/1024}'