#!/bin/bash


HOME="/home/t13dp"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")              # 获取当前时间戳
# TEMP_DIR="${HOME}/log_${TIMESTAMP}.tar.gz"      # 临时文件
TEMP_DIR="${HOME}/log_${TIMESTAMP}.zip"      # 临时文件


# 定义要打包的文件列表
FILE1="${HOME}/TM_T1/bin/"
FILE2="${HOME}/printer_data/config/"
FILE3="${HOME}/printer_data/logs/"
FILE4="/var/log/"


for file in "${FILE1}" "${FILE2}" "${FILE3}" "${FILE4}"; do
    if [ ! -e "$file" ]; then
        echo "Warning: $file does not exist."
    fi
done


#echo "Start export log ${TIMESTAMP}"


#打包
# tar -czf "${TEMP_DIR}" "${FILE1}" "${FILE2}" "${FILE3}" "${FILE4}"
zip -r -P TM88888 "${TEMP_DIR}" "${FILE1}" "${FILE2}" "${FILE3}" "${FILE4}" 
sync

# 移动到 U 盘
USB_DIR="${HOME}/printer_data/gcodes/USB/"

if [ -d "${USB_DIR}" ]; then
    # echo "USB exists."
    mv "${TEMP_DIR}" "${USB_DIR}"
else
    echo "USB does not exist."
    rm -f "${TEMP_DIR}"
fi
sync

# 判断是否成功
if [ -f "${USB_DIR}$(basename ${TEMP_DIR})" ]; then
    # echo "Export log success."
    printf "${USB_DIR}$(basename ${TEMP_DIR})"
    exit 0
else
    printf "Export log failed."
    exit 1
fi