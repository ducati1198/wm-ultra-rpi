import os
import shutil
import pyudev
import configparser
import logging

import tempfile

logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')

def monitor_serial_by_id(context, config_mcu_serial, dst_box_cfg, src_box_cfg_with_0,
                         src_box_cfg_with_1, src_box_cfg_with_2,
                         is_config_file_empty, update_config_file):
    try:
        # 获取当前 tty 设备
        current_devices = {
            device.device_node: next(
                (link for link in device.get('DEVLINKS', '').split() 
                 if '/dev/serial/by-id/' in link and 'QIDI_MAX4-BOX' in link), 
                None
            )
            for device in context.list_devices(subsystem='tty')
        }
        current_devices = {k: v for k, v in current_devices.items() if v is not None}

        device_count = len(current_devices)
        logging.info(f"Detected {device_count} devices: {current_devices}")

        # 根据设备数量更新配置文件
        if device_count == 0:
            if not is_config_file_empty(dst_box_cfg):
                shutil.copy(src_box_cfg_with_0, dst_box_cfg)
        elif device_count == 1:
            update_config_file("box0.cfg", current_devices, box_index=0)
            shutil.copy(src_box_cfg_with_1, dst_box_cfg)
        elif device_count == 2:
            update_config_file("box0.cfg", current_devices, box_index=0)
            update_config_file("box1.cfg", current_devices, box_index=1)
            shutil.copy(src_box_cfg_with_2, dst_box_cfg)
        else:
            logging.warning("Unexpected device count or mismatch detected.")
    except Exception as e:
        logging.error(f"Error monitoring serial devices: {e}")

def _update_config_file(config_file, current_devices, box_index=0):
    config_path = f"/home/t13dp/printer_data/config/{config_file}"
    box_name = f"box{box_index}"
    current_device_path = list(current_devices.values())[box_index]
    config = configparser.ConfigParser()
    config.read(config_path)
    section_name = f"mcu {box_name}"
    # if not config.has_section(section_name):
    #     config.add_section(section_name)
    config.set(section_name, 'serial', current_device_path)

    # 写入更新后的配置
    with open(config_path, 'w') as configfile:
        config.write(configfile)
    logging.info(f"Updated {config_file} with new device path: {current_device_path}")

def is_config_file_empty(file_path):
    config = configparser.ConfigParser()
    
    # 如果文件存在，读取文件内容
    if os.path.exists(file_path):
        config.read(file_path)
        # 检查是否有任何 section
        if not config.sections():
            logging.info("配置文件为空或没有任何配置项。")
            return True
        else:
            logging.info("配置文件包含配置项。")
            return False
    else:
        logging.info("配置文件不存在。")
        return None

'''
# 临时文件和目录
dst_box_cfg = tempfile.NamedTemporaryFile(delete=False).name
src_box_cfg_with_0 = tempfile.NamedTemporaryFile(delete=False).name
src_box_cfg_with_1 = tempfile.NamedTemporaryFile(delete=False).name
src_box_cfg_with_2 = tempfile.NamedTemporaryFile(delete=False).name

# 模拟依赖方法
def is_config_file_empty(file_path):
    return os.stat(file_path).st_size == 0

def update_config_file(config_file, current_devices, box_index=0):
    logging.info(f"Updating {config_file} with devices: {current_devices}")

# 写入模拟配置文件
with open(src_box_cfg_with_0, 'w') as f:
    f.write("[include box0.cfg]\n")
with open(src_box_cfg_with_1, 'w') as f:
    f.write("[include box0.cfg]\n[include box1.cfg]\n")
with open(src_box_cfg_with_2, 'w') as f:
    f.write("[include box0.cfg]\n[include box1.cfg]\n[include box2.cfg]\n")

# 创建 pyudev 上下文
context = pyudev.Context()


# 测试函数
config_mcu_serial = {}
monitor_serial_by_id(
    context=context,
    config_mcu_serial=config_mcu_serial,
    dst_box_cfg=dst_box_cfg,
    src_box_cfg_with_0=src_box_cfg_with_0,
    src_box_cfg_with_1=src_box_cfg_with_1,
    src_box_cfg_with_2=src_box_cfg_with_2,
    is_config_file_empty=is_config_file_empty,
    update_config_file=update_config_file
)

# 清理临时文件
os.remove(dst_box_cfg)
os.remove(src_box_cfg_with_0)
os.remove(src_box_cfg_with_1)
os.remove(src_box_cfg_with_2)

'''
