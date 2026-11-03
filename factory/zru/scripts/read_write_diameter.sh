#!/bin/bash

# 检查参数数量
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "使用方法: $0 <0~3> <0|1> [<nozzle_diameter>]"
    echo "       <0~3> 挤出头编号"
    echo "       <0|1> 0 - 读取当前喷嘴直径，1 - 修改喷嘴直径为指定值"
    exit 1
fi

# 检查挤出头编号
if [ "$1" -lt 0 ] || [ "$1" -gt 3 ]; then
    echo "错误: 挤出头编号必须在0~3之间"
    exit 1
fi

# 检查操作模式
if [ "$2" -ne 0 ] && [ "$2" -ne 1 ]; then
    echo "错误: 操作模式必须为0或1"
    exit 1
fi

# 定义配置文件路径
CONFIG_FILE="/home/t13dp/printer_data/config/printer.cfg"

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误: 配置文件 $CONFIG_FILE 不存在"
    exit 1
fi

# 根据挤出头编号确定配置块
if [ "$1" -eq 0 ]; then
    SECTION="extruder"
else
    SECTION="extruder$1"
fi

# 操作模式，0表示读取，1表示修改
MODE=$2

if [ "$MODE" -eq 0 ]; then
    # 读取当前喷嘴直径
    # 使用awk在特定配置块中查找nozzle_diameter
    NOZZLE_DIAMETER=$(awk -v section="$SECTION" '
        BEGIN { in_section = 0 }
        /^\[.*\]$/ {
            if ($0 == "[" section "]") {
                in_section = 1
            } else {
                in_section = 0
            }
        }
        in_section && /^nozzle_diameter:/ {
            print $2
            exit 0
        }
    ' "$CONFIG_FILE")
    
    if [ -n "$NOZZLE_DIAMETER" ]; then
        echo "$NOZZLE_DIAMETER"
    else
        cat $CONFIG_FILE | grep $SECTION
        echo "错误: 在[$SECTION]块中未找到喷嘴直径设置"
        exit 1
    fi
elif [ "$MODE" -eq 1 ]; then
    if [ "$#" -ne 3 ]; then
        echo "当选择模式为1时，必须提供新的喷嘴直径值"
        exit 1
    fi

    # 获取新的喷嘴直径并验证
    NEW_NOZZLE_DIAMETER=$3
    if ! [[ "$NEW_NOZZLE_DIAMETER" =~ ^[0-9.]+$ ]]; then
        echo "错误: 喷嘴直径必须是数字"
        exit 1
    fi

    # 使用sed在特定配置块中修改nozzle_diameter
    sed -i "/^\[$SECTION\]/,/^\[/ s/^\(nozzle_diameter: \).*/\1$NEW_NOZZLE_DIAMETER/" "$CONFIG_FILE"

    # 检查操作结果
    if [ $? -eq 0 ]; then
        echo "已成功将 [$SECTION] 的 nozzle_diameter 修改为 $NEW_NOZZLE_DIAMETER"
    else
        echo "修改失败，请检查文件路径和权限"
        exit 1
    fi
fi
