import os
import logging
import glob
import configparser
from ..confighelper import ConfigHelper
from tornado.ioloop import IOLoop

class StorageMonitor:
    def __init__(self, config):
        self.server = config.get_server()
        self.storage_interval = 30  # 存储检测间隔 30秒
        self.camera_interval = 30   # 摄像头检测间隔 30秒
        self.warning_threshold = 95  # 默认 95% 告警
        self.error_threshold = 98  # 默认 98% 错误
        self._storage_warning_sent = False
        self._storage_error_sent = False 
        self._camera_warning_sent = False  # 新增摄像头警告状态跟踪
        self.ioloop = IOLoop.current()
        
        # 初始化配置路径
        self.CONFIG_PATH = '/home/t13dp/printer_data/config/tmt1.ini'
        
        # 启动两个独立的检测任务
        self._check_storage()  # 立即执行存储检测
        self._check_camera()   # 立即执行摄像头检测

    def _check_storage(self):
        """独立存储空间检测任务"""
        try:
            statvfs = os.statvfs('/')
            total_blocks = statvfs.f_blocks
            free_blocks = statvfs.f_bavail
            used_blocks = total_blocks - free_blocks
            usage_percent = (used_blocks / total_blocks) * 100

            # 检测状态变化：从正常 -> 超过警告阈值
            if usage_percent >= self.warning_threshold:
                logging.info(f"Storage usage: {usage_percent:.2f}%")
                if not self._storage_warning_sent:  # 首次超过阈值
                    warning_msg = (
                        f"!! ZRU-X003: Storage reached 95%. Please clean up remaining files."
                    )
                    self.server.send_event("server:gcode_response", warning_msg)
                    self._storage_warning_sent = True  # 标记已发送警告
            else:
                # 空间恢复到正常时重置标记
                self._storage_warning_sent = False

            # 检测状态变化：从正常 -> 超过错误阈值
            if usage_percent >= self.error_threshold:
                logging.info(f"Storage usage: {usage_percent:.2f}%")
                if not self._storage_error_sent:  # 首次超过阈值
                    warning_msg = (
                        f"!! ZRU-X004: Storage reached 98%. Print disabled. Clean up immediately!"
                    )
                    self.server.send_event("server:gcode_response", warning_msg)
                    self._storage_error_sent = True  # 标记已发送警告
            else:
                # 空间恢复到正常时重置标记
                self._storage_error_sent = False

        except Exception as e:
            logging.error(f"Storage check failed: {str(e)}")
        
        # 设置下一次存储检测
        self.ioloop.call_later(self.storage_interval, self._check_storage)

    def _check_camera(self):
        """独立摄像头检测任务（添加状态跟踪）"""
        try:
            # 检查配置文件是否存在
            if os.path.exists(self.CONFIG_PATH):
                # 读取配置文件
                config = configparser.ConfigParser()
                config.read(self.CONFIG_PATH)
                
                # 获取camera值（默认为0）
                camera_enabled = config.getint('system', 'camera', fallback=0) == 1
                # logging.info(f"camera_enabled: {camera_enabled}")
            else:
                logging.error(f"Config file not found: {self.CONFIG_PATH}")
                camera_enabled = False

            # 仅当camera=1时执行检测
            if camera_enabled:
                cams = glob.glob('/dev/v4l/by-id/usb*')
                # logging.info(f"CAMERA DETECTION: Found {len(cams)} devices: {cams}")
                
                if not cams:  # 未检测到摄像头
                    if not self._camera_warning_sent:  # 尚未发送警告
                        logging.info("No camera detected - sending warning")
                        self.server.send_event("server:gcode_response", 
                                             "!! ZRU-A001: Camera connection error. Power off and check camera cable connection.")
                        self._camera_warning_sent = True  # 标记已发送警告
                else:  # 检测到摄像头
                    if self._camera_warning_sent:  # 之前发送过警告但现在正常
                        logging.info("Camera detected - issue resolved")
                        self.server.send_event("server:gcode_response", 
                                             "Camera connection restored.")
                        self._camera_warning_sent = False  # 重置警告状态
            else:  # 摄像头功能未启用
                # 重置警告状态（以防之前发送过警告）
                self._camera_warning_sent = False
        
        except Exception as e:
            logging.error(f"Camera check failed: {str(e)}")
        
        # 设置下一次摄像头检测
        self.ioloop.call_later(self.camera_interval, self._check_camera)

def load_component(config: ConfigHelper) -> StorageMonitor:
    return StorageMonitor(config)
