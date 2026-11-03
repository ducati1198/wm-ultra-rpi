#!/bin/bash

# 参数检查
if [ "$#" -ne 1 ]; then
    echo "用法: $0 <mp4文件>"
    exit 1
fi

mp4_file="$1"
original_jpg="${mp4_file%.*}.jpg"          # 原始图片
resized_jpg="${mp4_file%.*}_120_90.jpg"    # 新缩略图
target_width=120
target_height=90

# 检查是否已存在缩略图
if [ -f "$resized_jpg" ]; then
    echo "缩略图已存在: $resized_jpg" >> /home/t13dp/TM_T1/bin/client_log.txt
    exit 0
fi

# 检查原始图片是否存在，如果不存在则从MP4提取
if [ ! -f "$original_jpg" ]; then
    echo "原始图片不存在，从MP4文件中提取: $mp4_file"
    
    # 从MP4文件中提取第一帧作为JPG
    ffmpeg -i "$mp4_file" -vframes 1 -q:v 2 -y "$original_jpg"
    
    if [ $? -ne 0 ] || [ ! -f "$original_jpg" ]; then
        echo "错误: 无法从MP4提取图片帧"
        exit 1
    fi
    
    echo "已从MP4提取原始图片: $original_jpg"
fi

# 生成兼容LVGL的缩略图 (使用标准YUV420格式)
echo "正在生成LVGL兼容缩略图: $resized_jpg" >> /home/t13dp/TM_T1/bin/client_log.txt
ffmpeg -i "$original_jpg" \
       -vf "scale=$target_width:$target_height,format=yuvj420p" \
       -q:v 2 \
       -preset fast \
       -y \
       "$resized_jpg"

# 验证生成的图片
if [ $? -eq 0 ] && [ -f "$resized_jpg" ]; then
    echo "缩略图生成成功" >> /home/t13dp/TM_T1/bin/client_log.txt
    
    # 可选: 检查图片格式
    if file "$resized_jpg" | grep -q "JPEG"; then
        echo "图片验证通过: $(file -b "$resized_jpg")" >> /home/t13dp/TM_T1/bin/client_log.txt
    else
        echo "警告: 生成的图片可能无效" >> /home/t13dp/TM_T1/bin/client_log.txt
        exit 1
    fi
else
    echo "错误: 缩略图生成失败" >> /home/t13dp/TM_T1/bin/client_log.txt
    exit 1
fi