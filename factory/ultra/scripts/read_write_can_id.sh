#!/bin/bash

# 检查参数数量
if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    echo "使用方法: $0 <0~3> <0|1> [<can_id>]"
    echo "       0~3 - 要操作的喷嘴"
    echo "       0 - 读取当前喷嘴can_id  1 - 修改喷嘴can_id"
    echo "       can_id - 要设置的新id"
    exit 1
fi

# 定义配置文件路径
CONFIG_FILE="/home/t13dp/printer_data/config/wm_zru_thr$1.cfg"

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误: 配置文件 $CONFIG_FILE 不存在"
    exit 1
fi

# 操作模式，0表示读取，1表示修改
MODE=$2

if [ "$MODE" -eq 0 ]; then
    # 读取当前can_id，支持多种格式的canbus_uuid行
    # 匹配：canbus_uuid: 后面可能有0个或多个空格，然后捕获实际的值
    CAN_ID=$(grep -E '^[[:space:]]*canbus_uuid:' "$CONFIG_FILE" | sed -n 's/^[[:space:]]*canbus_uuid:[[:space:]]*//p')
    if [ -n "$CAN_ID" ]; then
        echo "$CAN_ID"
    else
        echo "未找到喷嘴can_id设置"
        exit 1
    fi
elif [ "$MODE" -eq 1 ]; then
    if [ "$#" -ne 3 ]; then
        echo "当选择模式为1时，必须提供新的CAN_ID"
        exit 1
    fi

    # 获取新的can_id
    NEW_CAN_ID=$3

    # 使用sed命令修改配置文件，支持多种格式
    # 匹配以任意空格开头的canbus_uuid:行
    sed -i "s/^[[:space:]]*canbus_uuid:[[:space:]]*.*/canbus_uuid: $NEW_CAN_ID/" "$CONFIG_FILE"
    sync
    
    # 输出结果
    if [ $? -eq 0 ]; then
        echo "已成功将 $1 的can_id修改为 $NEW_CAN_ID"
    else
        echo "修改失败，请检查文件路径和权限"
        exit 1
    fi
else
    echo "无效的模式选择，必须为0或1"
    exit 1
fi