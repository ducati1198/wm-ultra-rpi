# Filament Motion Sensor Module
#
# Copyright (C) 2021 Joshua Wherrett <thejoshw.code@gmail.com>
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import logging
from . import filament_switch_sensor

CHECK_RUNOUT_TIMEOUT = .25

class EncoderSensor:
    def __init__(self, config):
        # Read config
        self.printer = config.get_printer()
        self.gcode = self.printer.lookup_object('gcode')
        switch_pin = config.get('switch_pin')
        self.extruder_name = config.get('extruder')
        self.detection_length = config.getfloat(
                'detection_length', 7., above=0.)
        # Configure pins
        buttons = self.printer.load_object(config, 'buttons')
        buttons.register_buttons([switch_pin], self.encoder_event)
        # Get printer objects
        self.reactor = self.printer.get_reactor()
        self.runout_helper = filament_switch_sensor.RunoutHelper(config)
        self.get_status = self.runout_helper.get_status
        self.sensor_enabled = True
        self.update_flag = True
        self.gcode.register_mux_command(
            "UPDATE_FILAMENT_SENSOR", "SENSOR", self.runout_helper.name,
            self.cmd_update_filament_runout_pos,
            desc="update filament runout pos")
        self.extruder = None
        self.estimated_print_time = None
        # Initialise internal state
        self.filament_runout_pos = None
        # Register commands and event handlers
        self.printer.register_event_handler('klippy:ready',
                self._handle_ready)
        self.printer.register_event_handler('idle_timeout:printing',
                self._handle_printing)
        self.printer.register_event_handler('idle_timeout:ready',
                self._handle_not_printing)
        self.printer.register_event_handler('idle_timeout:idle',
                self._handle_not_printing)
    def _update_filament_runout_pos(self, eventtime=None):
        if eventtime is None:
            eventtime = self.reactor.monotonic()
        self.filament_runout_pos = (
                self._get_extruder_pos(eventtime) +
                self.detection_length)
    def _handle_ready(self):
        self.extruder = self.printer.lookup_object(self.extruder_name)
        self.estimated_print_time = (
                self.printer.lookup_object('mcu').estimated_print_time)
        self._update_filament_runout_pos()
        self._extruder_pos_update_timer = self.reactor.register_timer(
                self._extruder_pos_update_event)
    def _handle_printing(self, print_time):
        self.reactor.update_timer(self._extruder_pos_update_timer,
                self.reactor.NOW)
    def _handle_not_printing(self, print_time):
        self.reactor.update_timer(self._extruder_pos_update_timer,
                self.reactor.NEVER)
        
    def _get_extruder_pos(self, eventtime=None):
        if eventtime is None:
            eventtime = self.reactor.monotonic()
        print_time = self.estimated_print_time(eventtime)
        return self.extruder.find_past_position(print_time)
    
    # 定时判断是否超过了比较值
    def _extruder_pos_update_event(self, eventtime):
        if self.sensor_enabled == False or self.update_flag == False:
            return eventtime + CHECK_RUNOUT_TIMEOUT
    
        extruder_pos = self._get_extruder_pos(eventtime)
        # logging.info("extruder pos: %s filament runout pos: %s is_filament: %d", extruder_pos, self.filament_runout_pos, extruder_pos < self.filament_runout_pos)
       
        # 判断是否无料
        self.runout_helper.note_filament_present(extruder_pos < self.filament_runout_pos)
        return eventtime + CHECK_RUNOUT_TIMEOUT
    
    # 码盘码盘转动更新比较值
    def encoder_event(self, eventtime, state):
        if self.extruder is not None and self.sensor_enabled == True:
            self._update_filament_runout_pos(eventtime)
            self.runout_helper.note_filament_present(True)
            self.update_flag = True
            # logging.info(f"{self.runout_helper.name}码盘转动更新比较值")

    # 使能指令
    def cmd_SET_FILAMENT_MOTION_SENSOR(self, gcmd):
        self.sensor_enabled = gcmd.get_int("ENABLE", 1)
        self.runout_helper.sensor_enabled = self.sensor_enabled
        if self.sensor_enabled == 0:
            return
        self._update_filament_runout_pos()
        self.runout_helper.note_filament_present(True)
        self.update_flag = True
        # logging.info(f"{self.runout_helper.name}使能传感器更新比较值")
    
    #手动点击恢复后重置比较值
    def cmd_update_filament_runout_pos(self, gcmd):
        if self.sensor_enabled == 0:
            return
        self._update_filament_runout_pos()
        self.runout_helper.note_filament_present(True)
        self.update_flag = True
        # logging.info(f"{self.runout_helper.name}恢复打印更新比较值")

def load_config_prefix(config):
    return EncoderSensor(config)
