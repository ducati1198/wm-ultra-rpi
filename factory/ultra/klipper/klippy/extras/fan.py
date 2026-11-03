# Printer cooling fan
#
# Copyright (C) 2016-2020  Kevin O'Connor <kevin@koconnor.net>
#
# This file may be distributed under the terms of the GNU GPLv3 license.
from . import pulse_counter
import logging

FAN_MIN_TIME = 0.100

class Fan:
    def __init__(self, config, default_shutdown_speed=0.):
        self.fan_name = config.get_name().split()[-1]
        self.printer = config.get_printer()
        self.gcode = self.printer.lookup_object('gcode')
        self.reactor = self.printer.get_reactor()
        self.fan_check_handle = None
        self.last_fan_value = 0.
        self.last_fan_value_back = 0.
        self.last_fan_time = 0.
        self.need_check = False  # 是否需要检测转速
        # Read config
        self.max_power = config.getfloat('max_power', 1., above=0., maxval=1.)
        self.kick_start_time = config.getfloat('kick_start_time', 0.1,
                                               minval=0.)
        self.off_below = config.getfloat('off_below', default=0.,
                                         minval=0., maxval=1.)
        cycle_time = config.getfloat('cycle_time', 0.010, above=0.)
        hardware_pwm = config.getboolean('hardware_pwm', False)
        shutdown_speed = config.getfloat(
            'shutdown_speed', default_shutdown_speed, minval=0., maxval=1.)
        # Setup pwm object
        ppins = self.printer.lookup_object('pins')
        self.mcu_fan = ppins.setup_pin('pwm', config.get('pin'))
        self.mcu_fan.setup_max_duration(0.)
        self.mcu_fan.setup_cycle_time(cycle_time, hardware_pwm)
        shutdown_power = max(0., min(self.max_power, shutdown_speed))
        self.mcu_fan.setup_start_value(0., shutdown_power)

        self.enable_pin = None
        enable_pin = config.get('enable_pin', None)
        if enable_pin is not None:
            self.enable_pin = ppins.setup_pin('digital_out', enable_pin)
            self.enable_pin.setup_max_duration(0.)

        # Setup tachometer
        self.tachometer = FanTachometer(config)

        # Register callbacks
        self.printer.register_event_handler("gcode:request_restart",
                                            self._handle_request_restart)
        self.printer.register_event_handler("klippy:disconnect", 
                                       self._handle_disconnect)
        self.printer.register_event_handler("klippy:ready", 
                                       self._handle_ready)
        
    
    def get_mcu(self):
        return self.mcu_fan.get_mcu()
    
    def set_speed(self, print_time, value):

        if self.fan_name == "auxiliary_fan":
            #读取风扇是否开启
            import os
            import configparser
            # 配置文件路径 - 根据实际情况调整
            CONFIG_PATH = '/home/t13dp/printer_data/config/tmt1.ini'
            # 检查配置文件是否存在
            if os.path.exists(CONFIG_PATH):
                # 读取配置文件
                config = configparser.ConfigParser()
                config.read(CONFIG_PATH)
                
                # 获取auxiliary_fan值（默认为0）
                auxiliary_installed = config.getint('system', 'auxiliary_fan', fallback=0) == 1
                logging.info(f"auxiliary_installed: {auxiliary_installed}")
                if auxiliary_installed == False:
                    return
            else:
                logging.error(f"Config file not found: {CONFIG_PATH}")
                auxiliary_installed = False
                return
            
        if self.fan_name == "air_fan":
            #读取风扇是否开启
            import os
            import configparser
            # 配置文件路径 - 根据实际情况调整
            CONFIG_PATH = '/home/t13dp/printer_data/config/tmt1.ini'
            # 检查配置文件是否存在
            if os.path.exists(CONFIG_PATH):
                # 读取配置文件
                config = configparser.ConfigParser()
                config.read(CONFIG_PATH)
                
                # 获取camera值（默认为0）
                air_fan_installed = config.getint('system', 'air_filter', fallback=0) == 1
                logging.info(f"air_fan_installed: {air_fan_installed}")
                if air_fan_installed == False:
                    return
            else:
                logging.error(f"Config file not found: {CONFIG_PATH}")
                air_fan_installed = False
                return

        if value > 0. and value < self.off_below:
            value = self.off_below
            # value = 0.
        value = max(0., min(self.max_power, value * self.max_power))
        if value == self.last_fan_value:
            return
        print_time = max(self.last_fan_time + FAN_MIN_TIME, print_time)
        if self.enable_pin:
            if value > 0 and self.last_fan_value == 0:
                self.enable_pin.set_digital(print_time, 1)
            elif value == 0 and self.last_fan_value > 0:
                self.enable_pin.set_digital(print_time, 0)
        if (value and value < self.max_power and self.kick_start_time
            and (not self.last_fan_value or value - self.last_fan_value > .5)):
            # Run fan at full speed for specified kick_start_time
            self.mcu_fan.set_pwm(print_time, self.max_power)
            print_time += self.kick_start_time
        self.mcu_fan.set_pwm(print_time, value)
        self.last_fan_time = print_time
        self.last_fan_value = value
        
        # 转速检测
        if self.fan_check_handle is not None and value > 0.:
            self.need_check = True
            if self.fan_name == "fan":
                # logging.info("开始延时30s")
                self.reactor.update_timer(self.fan_check_handle, self.reactor.monotonic() + 30.0)
                
            elif self.fan_name == "auxiliary_fan" and auxiliary_installed == True:
                self.reactor.update_timer(self.fan_check_handle, self.reactor.monotonic() + 30.0)


    def set_speed_from_command(self, value):
        toolhead = self.printer.lookup_object('toolhead')
        toolhead.register_lookahead_callback((lambda pt:
                                              self.set_speed(pt, value)))
    def _handle_request_restart(self, print_time):
        self.set_speed(print_time, 0.)

    def get_status(self, eventtime):
        tachometer_status = self.tachometer.get_status(eventtime)
        return {
            'speed': self.last_fan_value,
            'rpm': tachometer_status['rpm'],
        }
    
    # 断开时关闭定时器
    def _handle_disconnect(self):
        if self.fan_check_handle:
            self.reactor.unregister_timer(self.fan_check_handle)
            self.fan_check_handle = None
        self.need_check = False

    # ready时注册定时器
    def _handle_ready(self):
        # 只有尚未注册定时器时才注册
        if self.fan_check_handle is None:
            self.fan_check_handle = self.reactor.register_timer(
                self._delayed_fan_check, self.reactor.NEVER)
        

    # 新增延迟检测回调函数
    def _delayed_fan_check(self, eventtime):
        # logging.info("延时30s结束, 开始判断转速")

        if self.last_fan_value <= 0.:
            logging.info("风扇速度为0，不进行检测")
            self.need_check = False
            return self.reactor.NEVER
        
        # 检测阶段
        current_status = self.tachometer.get_status(eventtime)
        current_rpm = current_status['rpm']
        # 报错条件：需要检测、风扇速度大于0但检测到的转速为0
        if (self.need_check and 
            self.last_fan_value > 0 and 
            current_rpm is not None and 
            current_rpm == 0):

            logging.error(f"当前风扇为: {self.fan_name}")
            logging.error(f"当前转速为: {current_rpm}")

            self.need_check = False
            if self.fan_name == "fan":
                self.gcode._respond_error("ZRU-T009: Fan speed too low. Power off, check for debris and cable connection.")
            else:
                self.gcode._respond_error("ZRU-A002: Auxiliary fan error. Power off, check for debris and cable connection.")
            # 是否暂停
            print_stats = self.printer.lookup_object("print_stats")
            is_printing = print_stats.get_status(eventtime)["state"] == "printing"
            if is_printing:
                pause_resume = self.printer.lookup_object('pause_resume')
                pause_resume.send_pause_command()
                self.gcode.run_script("PAUSE\n")
                logging.info("发送暂停指令")

        # 返回NEVER表示不再调用，除非通过update_timer重新安排
        return self.reactor.NEVER

class FanTachometer:
    def __init__(self, config):
        self.printer = config.get_printer()
        printer = config.get_printer()
        self._freq_counter = None

        pin = config.get('tachometer_pin', None)
        if pin is not None:
            self.ppr = config.getint('tachometer_ppr', 2, minval=1)
            poll_time = config.getfloat('tachometer_poll_interval',
                                        0.0015, above=0.)
            sample_time = 1.
            self._freq_counter = pulse_counter.FrequencyCounter(
                printer, pin, sample_time, poll_time)

    def get_status(self, eventtime):
        if self._freq_counter is not None:
            rpm = self._freq_counter.get_frequency() * 30. / self.ppr
        else:
            rpm = None
        return {'rpm': rpm}

class PrinterFan:
    def __init__(self, config):
        self.fan = Fan(config)
        # Register commands
        gcode = config.get_printer().lookup_object('gcode')
        gcode.register_command("M106", self.cmd_M106)
        gcode.register_command("M107", self.cmd_M107)
    def get_status(self, eventtime):
        return self.fan.get_status(eventtime)
    def cmd_M106(self, gcmd):
        # Set fan speed
        value = gcmd.get_float('S', 255., minval=0.) / 255.
        self.fan.set_speed_from_command(value)
    def cmd_M107(self, gcmd):
        # Turn fan off
        self.fan.set_speed_from_command(0.)

def load_config(config):
    return PrinterFan(config)
