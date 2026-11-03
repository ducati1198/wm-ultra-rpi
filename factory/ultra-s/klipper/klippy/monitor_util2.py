import os
import shutil
import configparser
import logging
import pyudev

# 日志配置
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

def monitor_serial_devices():
    """监控设备路径是否与配置匹配并更新配置文件"""

    # 文件路径定义
    DST_BOX_CFG = '/home/t13dp/printer_data/config/box.cfg'
    SRC_BOX_CFG_WITH_0 = '/home/t13dp/cfg_with_0'
    SRC_BOX_CFG_WITH_1 = '/home/t13dp/cfg_with_1'
    SRC_BOX_CFG_WITH_2 = '/home/t13dp/cfg_with_2'

    # 初始化 pyudev
    context = pyudev.Context()
    current_devices = {}

    try:
        # 遍历 tty 设备，获取 /dev/serial/by-id/ 路径
        for device in context.list_devices(subsystem='tty'):
            device_node = device.device_node
            devlinks = device.get('DEVLINKS', '').split()
            serial_by_id = next(
                (link for link in devlinks if '/dev/serial/by-id/' in link and 'QIDI_MAX4-BOX' in link),
                None
            )
            if serial_by_id:
                current_devices[device_node] = serial_by_id

        device_count = len(current_devices)
        logging.info(f"Detected {device_count} devices: {current_devices}")

        # 配置文件操作
        if device_count == 0:
            if not _is_config_file_empty(DST_BOX_CFG):
                shutil.copy(SRC_BOX_CFG_WITH_0, DST_BOX_CFG)
                _request_restart()
        elif device_count == 1:
            _update_config_file(f"/home/t13dp/printer_data/config/box0.cfg", current_devices, box_index=0)
            shutil.copy(SRC_BOX_CFG_WITH_1, DST_BOX_CFG)
            _request_restart()
        elif device_count == 2:
            _update_config_file(f"/home/t13dp/printer_data/config/box0.cfg", current_devices, box_index=0)
            _update_config_file(f"/home/t13dp/printer_data/config/box1.cfg", current_devices, box_index=1)
            shutil.copy(SRC_BOX_CFG_WITH_2, DST_BOX_CFG)
            _request_restart()
        else:
            logging.warning("Unexpected device count or mismatch detected.")
    except Exception as e:
        logging.error(f"Error monitoring serial devices: {e}")


def _is_config_file_empty(file_path):
    """检查配置文件是否为空"""
    config = configparser.ConfigParser()
    if os.path.exists(file_path):
        config.read(file_path)
        return not config.sections()
    return True


def _update_config_file(config_path, current_devices, box_index=0):
    """更新配置文件的 serial 路径"""
    box_name = f"box{box_index}"
    current_device_path = list(current_devices.values())[box_index]

    config = configparser.ConfigParser()
    if os.path.exists(config_path):
        config.read(config_path)

    section_name = f"mcu {box_name}"
    if not config.has_section(section_name):
        config.add_section(section_name)
    config.set(section_name, 'serial', current_device_path)

    with open(config_path, 'w') as configfile:
        config.write(configfile)
    logging.info(f"Updated {config_path} with new device path: {current_device_path}")


def _request_restart():
    """请求系统重启（此处为占位实现，实际调用重启逻辑可替换）"""
    logging.info("Requesting system restart...")
    # 具体的重启实现可按需求替换，如发信号或调用脚本
    pass


if __name__ == "__main__":
    monitor_serial_devices()
