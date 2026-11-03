#!/bin/bash


# 定义文件路径
file1="/home/t13dp/printer_data/config/wm_zru_thr1.cfg"
file2="/home/t13dp/printer_data/config/wm_zru_thr0.cfg"

# 检查源文件是否存在
if [ ! -f "$file1" ]; then
    echo "错误: 源文件 $file1 不存在"
    exit 1
fi

# 检查目标文件是否存在
if [ ! -f "$file2" ]; then
    echo "错误: 目标文件 $file2 不存在"
    exit 1
fi

# 从源文件提取UUID
uuid=$(grep -E '^canbus_uuid:' "$file1" | cut -d: -f2 | tr -d ' ')

# 检查是否成功提取到UUID
if [ -z "$uuid" ]; then
    echo "错误: 无法从 $file1 中提取UUID"
    exit 1
fi

echo "提取到的UUID: $uuid"

# 创建临时文件
temp_file=$(mktemp)

# 使用awk替换目标文件中的UUID
awk -v new_uuid="$uuid" '
    /^\[mcu T0\]/ { in_t0_section=1 }
    /^\[/ && !/^\[mcu T0\]/ { in_t0_section=0 }
    in_t0_section && /^canbus_uuid:/ { 
        print "canbus_uuid:" new_uuid
        next
    }
    { print }
' "$file2" > "$temp_file"

# 检查替换是否成功
if [ $? -eq 0 ]; then
    # 备份原文件并替换
    mv "$temp_file" "$file2"
    chown -R t13dp:netdev "$file2"
    echo "成功: UUID已替换"
else
    echo "错误: 替换UUID失败"
    rm "$temp_file"
    exit 1
fi




