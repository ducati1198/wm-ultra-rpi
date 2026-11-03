#!/usr/bin/env python3
"""
配置文件合并工具
功能：将文件2中的新配置项合并到文件1中，保持文件1原有值不变
特点：
  - 仅添加文件1中不存在的新配置项
  - 保留文件1所有现有键值
  - 支持添加新section和现有section中的新键
  - 保持原始键的大小写格式
"""

import configparser
import sys

def merge_configs(file1_path, file2_path):
    """
    合并两个配置文件
    :param file1_path: 主配置文件路径（将被更新）
    :param file2_path: 新配置来源文件路径
    """
    # 创建配置解析器对象 - 保留原始键的大小写格式
    # 默认情况下configparser会将键转换为小写，这里通过重写optionxform方法保持原始大小写
    config1 = configparser.ConfigParser()
    config1.optionxform = lambda option: option  # 保持键的大小写不变
    
    config2 = configparser.ConfigParser()
    config2.optionxform = lambda option: option  # 保持键的大小写不变
    
    # 读取配置文件内容
    config1.read(file1_path)
    config2.read(file2_path)
    
    # 标志位：记录是否进行了修改
    changes_made = False
    
    # 遍历文件2中的所有section
    for section in config2.sections():
        # 情况1：文件1中不存在该section
        if not config1.has_section(section):
            # 添加整个新section
            config1.add_section(section)
            changes_made = True
            print(f"添加新section: [{section}]")
        
        # 遍历当前section中的所有键值对
        for key, value in config2.items(section):
            # 情况2：section存在但键不存在于文件1
            if not config1.has_option(section, key):
                # 添加新键值对到文件1的对应section
                config1.set(section, key, value)
                changes_made = True
                print(f"在 [{section}] 下添加新项: {key}={value}")
    
    # 如果有修改，则写回文件1
    if changes_made:
        # 写入文件，不添加额外的空格（保持原始格式）
        with open(file1_path, 'w') as configfile:
            config1.write(configfile, space_around_delimiters=False)
        print(f"文件 {file1_path} 已成功更新")
    else:
        print("未检测到需要添加的新配置项")

if __name__ == "__main__":
    # 合并saved_variables
    target_file = "/home/t13dp/printer_data/config/saved_variables.cfg"     # 文件1（将被修改）
    source_file = "/home/t13dp/TM_T1/factory_settings/saved_variables.cfg"         # 文件2（新配置来源）
    # 执行合并操作
    merge_configs(target_file, source_file)

    # 合并tmt1.ini
    target_file = "/home/t13dp/printer_data/config/tmt1.ini"  # 文件1（将被修改）
    source_file = "/home/t13dp/TM_T1/factory_settings/tmt1.ini"  # 文件2（新配置来源）
    # 执行合并操作
    merge_configs(target_file, source_file)