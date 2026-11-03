#!/bin/bash

# 定义输入和输出文件路径
input_file="/home/t13dp/printer_data/config/printer.cfg"
output_file="/home/t13dp/printer_data/config/save_config.cfg"

# 检查输入文件是否存在
if [ ! -f "$input_file" ]; then
    echo "输入文件 $input_file 不存在。"
    exit 1
fi


# 使用 awk 查找特定行并将其后的所有内容输出到新文件
awk '/#\*\# <---------------------- SAVE_CONFIG ---------------------->/{flag=1} flag' "$input_file" > "$output_file"

# 检查 awk 命令是否成功
if [ $? -eq 0 ]; then
    echo "成功将内容保存到 $output_file"
else
    echo "发生错误，未能保存内容。"
    exit 1
fi


