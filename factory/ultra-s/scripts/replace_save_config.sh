#!/bin/bash

# 定义输入和输出文件路径
input_file="/home/t13dp/printer_data/config/printer.cfg"
replace_file="/home/t13dp/printer_data/config/save_config.cfg"

# 先判断挤出头个数，将other中正确的printer.cfg复制到printer_data/config/中
extruder_count=$(cat /home/t13dp/TM_T1/other/current_thr_number.txt)
echo "replace_save_config.sh 当前挤出头个数 $extruder_count"
if [ "$extruder_count" -eq 4 ]; then
    cp /home/t13dp/TM_T1/other/printer4.cfg /home/t13dp/printer_data/config/printer.cfg
elif [ "$extruder_count" -eq 3 ]; then
    cp /home/t13dp/TM_T1/other/printer3.cfg /home/t13dp/printer_data/config/printer.cfg
elif [ "$extruder_count" -eq 2 ]; then
    cp /home/t13dp/TM_T1/other/printer2.cfg /home/t13dp/printer_data/config/printer.cfg
elif [ "$extruder_count" -eq 1 ]; then
    cp /home/t13dp/TM_T1/other/printer1.cfg /home/t13dp/printer_data/config/printer.cfg
else
    echo "未知的挤出头个数 $extruder_count。"
    cp /home/t13dp/TM_T1/other/printer4.cfg /home/t13dp/printer_data/config/printer.cfg
fi

# 检查输入文件是否存在且可读
if [ ! -f "$input_file" ]; then
    echo "输入文件 $input_file 不存在。"
    exit 1
elif [ ! -r "$input_file" ]; then
    echo "输入文件 $input_file 不可读。"
    exit 1
fi

# 检查替换文件是否存在且可读
if [ ! -f "$replace_file" ]; then
    echo "替换文件 $replace_file 不存在。"
    exit 1
elif [ ! -r "$replace_file" ]; then
    echo "替换文件 $replace_file 不可读。"
    exit 1
fi


echo "删除多余挤出机节"
# ========== 从 replace_file 中删除多余挤出机节 ==========
# 需要删除的挤出机编号范围: [extruder_count] 到 [extruder3]
# 注意：如果 extruder_count >= 4，则不删除任何 extruder 节
if [ "$extruder_count" -lt 4 ]; then
    echo "正在删除挤出机节 (编号 $extruder_count 到 3)..."
    awk -v count="$extruder_count" '
    BEGIN {
        for (i = count; i <= 3; i++) {
            del_sections["[extruder" i "]"] = 1
        }
        skip = 0
    }
    /^#[*]# \[.*\]/ {   # 匹配 "#*# [任意节名]"
        # 提取节名：去掉开头的 "#*# " 和结尾的 "]"
        section_name = $0
        gsub(/^#[*]# /, "", section_name)
        sub(/\].*$/, "]", section_name)  # 得到如 "[extruder3]"
        skip = (section_name in del_sections)
    }
    !skip
    ' "$replace_file" > "${replace_file}.tmp" && mv "${replace_file}.tmp" "$replace_file"
fi




# 定义要删除的模式
delete_pattern='#\*\# <---------------------- SAVE_CONFIG ---------------------->'

# 使用 sed 删除特定行及其后的所有内容
sed -i "/$delete_pattern/,\$d" "$input_file"

# 将替换文件内容追加到输入文件
cat "$replace_file" >> "$input_file"

# 删除替换文件
rm -f "$replace_file"

echo "操作成功完成。"
