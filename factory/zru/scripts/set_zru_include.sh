#!/bin/bash

# 脚本名称: toggle_zru_include.sh
# 功能: 根据传入参数控制是否屏蔽printer.cfg中的[include zru-s.cfg]
# 使用方法: ./toggle_zru_include.sh <0或1>
#   0 - 屏蔽（确保有#注释）
#   1 - 启用（确保没有#注释）

# 配置文件路径
CONFIG_FILE="/home/t13dp/printer_data/config/printer.cfg"

# 检查参数
if [ $# -ne 1 ]; then
    echo "错误: 需要传入一个参数 (0或1)"
    echo "用法: $0 <0或1>"
    echo "  0 - 屏蔽 [include zru-s.cfg]"
    echo "  1 - 启用 [include zru-s.cfg]"
    exit 1
fi

# 检查参数是否为0或1
if [[ $1 != "0" && $1 != "1" ]]; then
    echo "错误: 参数必须是0或1"
    echo "  0 - 屏蔽 [include zru-s.cfg]"
    echo "  1 - 启用 [include zru-s.cfg]"
    exit 1
fi

# 根据参数处理文件
if [ $1 -eq 0 ]; then
    # 屏蔽（确保有#注释）
    # 将任意形式的[include zru-s.cfg]（无论是否有注释）统一为 "# [include zru-s.cfg]"
    sed -E -i 's/^[[:space:]]*#*[[:space:]]*\[include zru-s.cfg\]/# [include zru-s.cfg]/' "$CONFIG_FILE"
    echo "已屏蔽 [include zru-s.cfg]"
else
    # 启用（确保没有#注释，且为"[include zru-s.cfg]"格式）
    # 先移除所有前导#和空格，然后确保格式正确
    sed -E -i 's/^[[:space:]]*#+[[:space:]]*\[include zru-s.cfg\]/[include zru-s.cfg]/' "$CONFIG_FILE"
    # 处理原本就没有注释但可能有空格的情况
    sed -E -i 's/^[[:space:]]+\[include zru-s.cfg\]/[include zru-s.cfg]/' "$CONFIG_FILE"
    echo "已启用 [include zru-s.cfg]"
fi

