#!/bin/bash
# set -e

# 配置
KLIPPER_BIN="/home/t13dp/mcu_update/klipper_THR.bin"
CONFIG_DIR="/home/t13dp/printer_data/config"
PYTHON_ENV="/home/t13dp/klippy-env/bin/python"
FLASH_TOOL="/home/t13dp/klipper/scripts/flashtool.py"

# 错误处理
error_exit() {
    echo "[ERROR] $1" >&2
    exit 1
}

# 检查前置条件
check_prerequisites() {
    if [ ! -f "$KLIPPER_BIN" ]; then
        error_exit "固件文件不存在: $KLIPPER_BIN"
    fi
    
    if [ ! -f "$PYTHON_ENV" ]; then
        error_exit "Python环境不存在: $PYTHON_ENV"
    fi
    
    if [ ! -f "$FLASH_TOOL" ]; then
        error_exit "刷写工具不存在: $FLASH_TOOL"
    fi
}

# 刷写单个设备
flash_device() {
    local device_index=$1
    local mcu_name="T${device_index}"
    local config_file="${CONFIG_DIR}/wm_zru_thr${device_index}.cfg"
    
    echo "=== 处理设备 $mcu_name ==="
    
    # 检查配置文件是否存在
    if [ ! -f "$config_file" ]; then
        echo "[跳过] 配置文件不存在: $config_file"
        return 1
    fi
    
    # 提取CANBUS UUID
    local canbus_uuid=$(awk -F': ' '/\['"mcu $mcu_name"'\]/{found=1;next} found && /canbus_uuid/{print $2; exit}' "$config_file")
    
    if [ -z "$canbus_uuid" ]; then
        echo "[跳过] 在配置文件中未找到CANBUS UUID"
        return 1
    fi
    
    echo "设备: $mcu_name"
    echo "配置文件: $config_file"
    echo "CANBUS UUID: $canbus_uuid"
    
    # 执行刷写
    if "$PYTHON_ENV" "$FLASH_TOOL" -i can0 -f "$KLIPPER_BIN" -u "$canbus_uuid"; then
        echo "[成功] 设备 $mcu_name 刷写完成"
        return 0
    else
        echo "[失败] 设备 $mcu_name 刷写失败"
        return 1
    fi
}

# 批量刷写函数
batch_flash_devices() {
    local success_count=0
    local total_count=4
    
    echo "开始批量刷写设备 (T0-T3)..."
    echo "固件文件: $KLIPPER_BIN"
    echo "========================================"
    
    for i in 0 1 2 3; do
        if flash_device "$i"; then
            ((success_count++))
        fi
        
        # 设备间延时（可选）
        # if [ $i -lt 3 ]; then
        #     echo "等待 2 秒后处理下一个设备..."
        #     sleep 2
        # fi
        echo
    done
    
    echo "========================================"
    echo "批量刷写完成!"
    echo "成功: $success_count/$total_count 个设备"
    
    if [ $success_count -eq 0 ]; then
        error_exit "所有设备刷写均失败"
    elif [ $success_count -lt $total_count ]; then
        echo "[警告] 部分设备刷写失败"
        exit 2
    fi
}

# 主函数
main() {
    check_prerequisites
    batch_flash_devices
}

# 运行主函数
main "$@"