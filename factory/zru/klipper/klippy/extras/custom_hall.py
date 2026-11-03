# Support for scaling ADC values based on measured VREF and VSSA
#
# Copyright (C) 2020  Kevin O'Connor <kevin@koconnor.net>
#
# This file may be distributed under the terms of the GNU GPLv3 license.

ADC_SAMPLE_TIME = 0.001
ADC_SAMPLE_COUNT = 8
ADC_REPORT_TIME = 0.100


class CustomHall:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.last_adc_value_raw = 0
        self.last_adc_time = 0
        self.last_adc_value = 0
        # Configure adc pin
        self.adc_pin = config.get('adc_pin')
        # Start adc
        self.mcu_adc = None
        self.ppins = self.printer.lookup_object('pins')
        self.mcu_adc = self.ppins.setup_pin('adc', self.adc_pin)
        self.mcu_adc.setup_adc_sample(ADC_SAMPLE_TIME, ADC_SAMPLE_COUNT)
        self.mcu_adc.setup_adc_callback(ADC_REPORT_TIME, self.adc_callback)
        smooth_time = config.getfloat('smooth_time', 2., above=0.)
        self.inv_smooth_time = 1. / smooth_time
        self.mcu = self.mcu_adc.get_mcu()
        self.last_toolhead_position = [0., 0., 0.]

        self.gcode = self.printer.lookup_object('gcode')
        self.gcode.register_command('GET_T_POSITION',
                            self.cmd_GET_T_POSITION,
                            desc=self.cmd_GET_T_POSITION_help)

    cmd_GET_T_POSITION_help = (
        "Return information on the current location of the toolhead")
    def cmd_GET_T_POSITION(self, gcmd):
        toolhead = self.printer.lookup_object('toolhead', None)
        if toolhead is None:
            raise gcmd.error("Printer not ready")
        kin = toolhead.get_kinematics()
        steppers = kin.get_steppers()
        mcu_pos = " ".join(["%s:%d" % (s.get_name(), s.get_mcu_position())
                            for s in steppers])
        for s in steppers:
            if s.get_name() == 'stepper_x':
                origin_mcu_x = s.get_mcu_position()
                x_rotation_dist, x_steps_per_rotation = s.get_rotation_distance()
            if s.get_name() == 'stepper_y':
                origin_mcu_y = s.get_mcu_position() #get_step_dist()
                y_rotation_dist, y_steps_per_rotation = s.get_rotation_distance()

        gcmd.respond_info("origin mcu: %s\n"
                          % (mcu_pos))
        gcode = self.printer.lookup_object('gcode')
        self.gcode.run_script_from_command("BED_MESH_CLEAR")
        self.gcode.run_script_from_command("SET_GCODE_OFFSET X=0.0 Y=0.0 Z=0.0 MOVE=0")
        self.gcode.run_script_from_command("G28 X Y")
        mcu_pos = " ".join(["%s:%d" % (s.get_name(), s.get_mcu_position())
                            for s in steppers])
        gcmd.respond_info("origin mcu: %s\n"
                          % (mcu_pos))
        for s in steppers:
            if s.get_name() == 'stepper_x':
                home_mcu_x = s.get_mcu_position()
            if s.get_name() == 'stepper_y':
                home_mcu_y = s.get_mcu_position() #get_step_dist()
        stepper_x_steps = home_mcu_x - origin_mcu_x
        stepper_y_steps = home_mcu_y - origin_mcu_y
        # printer.configfile.settings['printer'].max_accel
        configfile = self.printer.lookup_object('configfile', None)
        endsotp_position_x = configfile.read_main_config().getsection('stepper_x').getfloat('position_endstop', 300)
        endsotp_position_y = configfile.read_main_config().getsection('stepper_y').getfloat('position_endstop', 0)
        position_x = endsotp_position_x - (stepper_x_steps + stepper_y_steps) / 2 / (x_steps_per_rotation / x_rotation_dist)
        position_y = endsotp_position_y - (stepper_x_steps - stepper_y_steps) / 2 / (x_steps_per_rotation / x_rotation_dist)
        gcmd.respond_info("x: %.6f, y: %.6f\n"
                          % (position_x, position_y))
        self.gcode.run_script_from_command("G0 X150 Y150 F6000")
        self.gcode.run_script_from_command("M84")
        self.last_toolhead_position = [position_x, position_y, 0.]

    def calc_smooth(self, read_time, read_value, last_time, last_value):
        time_diff = read_time - last_time
        value_diff = read_value - last_value
        adj_time = min(time_diff * self.inv_smooth_time, 1.)
        smoothed_value = last_value + value_diff * adj_time
        return (read_time, smoothed_value)
    def adc_callback(self, read_time, read_value):
        # read sensor value
        read_value = round(read_value * 10000)
        self.last_adc_value_raw = read_value
        # self.last_adc_value = self.calc_smooth(read_time, read_value, self.last_adc_time, self.last_adc_value)
        # self.last_adc_time = read_time

    def get_status(self, eventtime):
        return {'Raw':(self.last_adc_value_raw),
                'Raw_smooth':(self.last_adc_value),
                'last_toolhead_position': self.last_toolhead_position}

def load_config(config):
    return CustomHall(config)
