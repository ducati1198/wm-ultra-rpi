# Nozzle alignment module for 3d kinematic probes.
#
# This module has been adapted from code written by Kevin O'Connor <kevin@koconnor.net> and Martin Hierholzer <martin@hierholzer.info>
# Sourced from https://github.com/ben5459/Klipper_ToolChanger/blob/master/probe_multi_axis.py

import logging

direction_types = {'x+': [0, +1], 'x-': [0, -1], 'y+': [1, +1], 'y-': [1, -1],
                   'z+': [2, +1], 'z-': [2, -1]}
HINT_TIMEOUT = """
If the probe did not move far enough to trigger, then
consider reducing/increasing the axis minimum/maximum
position so the probe can travel further (the minimum
position can be negative).
"""

class ToolsCalibrate:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.name = config.get_name()
        self.gcode_move = self.printer.load_object(config, "gcode_move")
        self.probe_multi_axis = PrinterProbeMultiAxis(config,
                                                      ProbeEndstopWrapper(
                                                          config, 'x'),
                                                      ProbeEndstopWrapper(
                                                          config, 'y'),
                                                      ProbeEndstopWrapper(
                                                          config, 'z'))
        self.probe_name = config.get('probe', 'probe')
        self.travel_speed = config.getfloat('travel_speed', 10.0, above=0.)
        self.spread = config.getfloat('spread', 5.0)
        self.lower_z = config.getfloat('lower_z', 0.5)
        self.lift_z = config.getfloat('lift_z', 1.0)
        self.trigger_to_bottom_z = config.getfloat('trigger_to_bottom_z',
                                                   default=0.0)
        self.lift_speed = config.getfloat('lift_speed',
                                          self.probe_multi_axis.lift_speed)
        self.final_lift_z = config.getfloat('final_lift_z', 4.0)
        self.sample_count = config.getint('samples', 1, minval=1)
        atypes = {'median': 'median', 'average': 'average'}
        self.samples_result = config.getchoice('samples_result', atypes,
                                               'average')
        self.probe_position = config.getfloatlist('probe_position', (0.0, 0.0, 0.0, 0.0, 0.0,))
        self.offset_tolerance = config.getfloat('offset_tolerance', 0.1)
        self.offset_tolerance_retries = config.getint('offset_tolerance_retries', 3)
        self.sensor_location = None
        self.last_result = [0., 0., 0.]
        self.last_probe_offset = 0.
        self.calibration_probe_inactive = True
        self.last_toolhead_position = [0., 0., 0.]
        self.tools_offsets = {}

        # Register commands
        self.gcode = self.printer.lookup_object('gcode')
        self.gcode.register_command('TOOL_LOCATE_SENSOR',
                                    self.cmd_TOOL_LOCATE_SENSOR,
                                    desc=self.cmd_TOOL_LOCATE_SENSOR_help)
        self.gcode.register_command('TOOL_CALIBRATE_TOOL_OFFSET',
                                    self.cmd_TOOL_CALIBRATE_TOOL_OFFSET,
                                    desc=self.cmd_TOOL_CALIBRATE_TOOL_OFFSET_help)
        self.gcode.register_command('TOOL_CALIBRATE_SAVE_TOOL_OFFSET',
                                    self.cmd_TOOL_CALIBRATE_SAVE_TOOL_OFFSET,
                                    desc=self.cmd_TOOL_CALIBRATE_SAVE_TOOL_OFFSET_help)
        self.gcode.register_command('TOOL_CALIBRATE_PROBE_OFFSET',
                                    self.cmd_TOOL_CALIBRATE_PROBE_OFFSET,
                                    desc=self.cmd_TOOL_CALIBRATE_PROBE_OFFSET_help)
        self.gcode.register_command('TOOL_CALIBRATE_QUERY_PROBE',
                                    self.cmd_TOOL_CALIBRATE_QUERY_PROBE,
                                    desc=self.cmd_TOOL_CALIBRATE_QUERY_PROBE_help)
        self.gcode.register_command('TOOL_CALIBRATE_Z_OFFSET',
                                    self.cmd_TOOL_CALIBRATE_Z_OFFSET,
                                    desc=self.cmd_TOOL_CALIBRATE_Z_OFFSET_help)
        self.gcode.register_command('TOOL_CALIBRATE_CHECK_DATA',
                                    self.cmd_TOOL_CALIBRATE_CHECK_DATA,
                                    desc=self.cmd_TOOL_CALIBRATE_CHECK_DATA_help)

        self.printer.register_event_handler("klippy:ready", self._handle_ready)

    def _disable_collision_detect(self):
        """无论校准成功或失败，发生异常时强制关闭加速度计碰撞监测"""
        collision_obj = self.printer.lookup_object('collision_detect', None)
        if collision_obj is not None:
            try:
                collision_obj.cmd_disable()
                self.gcode.respond_info("[ToolsCalibrate] 异常兜底：已自动禁用碰撞检测。")
            except Exception as e:
                logging.error(f"[ToolsCalibrate] 自动禁用碰撞检测失败: {str(e)}")

    def _handle_ready(self):
        save_vars = self.printer.lookup_object('save_variables', None)
        if save_vars:
            var_probe_position = save_vars.allVariables.get('probe_position', None)
            if var_probe_position is None:
                self.gcode.run_script_from_command("SAVE_VARIABLE VARIABLE=probe_position VALUE=%s,%s,%s,%s,%s" %
                                                        (self.probe_position[0], self.probe_position[1], self.probe_position[2], self.probe_position[3], self.probe_position[4],))

    def _get_probe_position_var(self):
        save_vars = self.printer.lookup_object('save_variables', None)
        if save_vars:
            val = save_vars.allVariables.get('probe_position', None)
            if val is not None:
                if isinstance(val, str):
                    return [float(x.strip()) for x in val.split(',')]
                elif isinstance(val, (list, tuple)):
                    return [float(x) for x in val]
        return list(self.probe_position)

    def _safe_move(self, toolhead, coord, speed):
        self.probe_multi_axis.verify_no_crash()
        toolhead.manual_move(coord, speed)

    def probe_xy(self, toolhead, top_pos, direction, gcmd, samples=None):
        offset = direction_types[direction]
        gcmd.respond_info("x: %.6f, y: %.6f, dir: %s\n"
                          % (top_pos[0], top_pos[1], direction))
        self._safe_move(toolhead, [top_pos[0], top_pos[1], None], self.travel_speed)
        self._safe_move(toolhead, [None, None, top_pos[2] + self.last_probe_offset], self.lift_speed)
        result = self.probe_multi_axis.run_probe(direction, gcmd, samples=samples,
                                               max_distance=self.spread * 3)[offset[0]]
        toolhead.manual_move([None, None, top_pos[2] + self.last_probe_offset + self.lift_z],
                             self.lift_speed)
        return result

    def calibrate_xy(self, toolhead, top_pos, gcmd, samples=None):
        probe_pos = (top_pos[0], top_pos[1], top_pos[2])
        near_y = self.probe_xy(toolhead, probe_pos, 'y+', gcmd, samples=samples)
        probe_pos = (top_pos[0], near_y + self.spread, top_pos[2])
        far_y = self.probe_xy(toolhead, probe_pos, 'y-', gcmd, samples=samples)
        probe_pos = (top_pos[0], top_pos[1], top_pos[2])
        left_x = self.probe_xy(toolhead, probe_pos, 'x+', gcmd, samples=samples)
        probe_pos = (left_x + self.spread, top_pos[1], top_pos[2])
        right_x = self.probe_xy(toolhead, probe_pos, 'x-', gcmd, samples=samples)
        dy = (far_y - near_y)
        dx = (right_x - left_x)
        
        if dx <= 0 or dy <= 0:
            raise gcmd.error("Crash detected: sensor abnormal geometry dx: %.6f, dy: %.6f" % (dx, dy))

        center_x = (left_x + right_x) / 2
        center_y = (near_y + far_y) / 2
        dydx = dy / dx if dx != 0 else 0.0
        gcmd.respond_info(f"Calibrated XY: {center_x:.6f}, {center_y:.6f}, dx: {dx:.6f}, dy: {dy:.6f}, dydx: {dydx:.6f}")
        return [center_x, center_y]

    def _calc_mean_position(self, positions):
        count = float(len(positions))
        return [sum([pos[i] for pos in positions]) / count
                for i in range(3)]

    def _calc_median_axis(self, values):
        ordered = sorted(values)
        middle = len(ordered) // 2
        if (len(ordered) & 1) == 1:
            return ordered[middle]
        return (ordered[middle - 1] + ordered[middle]) / 2.

    def _calc_median_position(self, positions):
        return [self._calc_median_axis([pos[i] for pos in positions])
                for i in range(3)]

    def _aggregate_positions(self, positions, samples_result):
        if samples_result == 'median':
            return self._calc_median_position(positions)
        return self._calc_mean_position(positions)

    def locate_sensor(self, gcmd):
        toolhead = self.printer.lookup_object('toolhead')
        cur_position = toolhead.get_position()
        var_probe_position = self._get_probe_position_var()
        if cur_position[2] < var_probe_position[2] + self.lift_z + self.last_probe_offset:
            safe_z = var_probe_position[2] + self.lift_z + self.last_probe_offset
        else:
            safe_z = cur_position[2]
        
        self._safe_move(toolhead, [None, None, safe_z], self.lift_speed)
        self._safe_move(toolhead, [var_probe_position[0], None, None], self.travel_speed)
        self._safe_move(toolhead, [None, var_probe_position[1], None], self.travel_speed)
        self._safe_move(toolhead, [None, None, var_probe_position[2] + self.last_probe_offset], self.lift_speed)
        
        center_x, center_y = self.calibrate_xy(toolhead, var_probe_position, gcmd,
                                               samples=2)
        self._safe_move(toolhead, [center_x - var_probe_position[3], center_y - var_probe_position[4], None], self.travel_speed)
        self._safe_move(toolhead, [None, None, var_probe_position[2] + self.last_probe_offset], self.lift_speed)

        position = toolhead.get_position()
        center_x, center_y, center_z = position[0], position[1], var_probe_position[2]
        center_x, center_y = self.calibrate_xy(toolhead,
                                               [center_x, center_y, center_z],
                                               gcmd)

        position[0] = center_x
        position[1] = center_y
        position[2] = center_z + self.final_lift_z
        toolhead.manual_move([None, None, position[2]], self.lift_speed)
        toolhead.manual_move([position[0], position[1], None],
                             self.travel_speed)
        toolhead.set_position(position)
        return [center_x, center_y, center_z]

    cmd_TOOL_LOCATE_SENSOR_help = "Locate the tool calibration sensor, use with tool 0."
    def cmd_TOOL_LOCATE_SENSOR(self, gcmd):
        try:
            sample_count = self.sample_count
            samples_result = gcmd.get("SAMPLES_RESULT", self.samples_result)
            locations = [self.locate_sensor(gcmd) for _ in range(sample_count)]
            self.last_result = self._aggregate_positions(locations, samples_result)
            self.sensor_location = self.last_result
            gcmd.respond_info("Samples: %d, result: %s" % (sample_count,
                                                           samples_result))
            self.gcode.respond_info("Sensor location at %.6f, %.6f, %.6f"
                                    % (self.last_result[0], self.last_result[1],
                                       self.last_result[2]))
        except Exception:
            self._disable_collision_detect()
            raise

    cmd_TOOL_CALIBRATE_TOOL_OFFSET_help = "Calibrate current tool offset relative to tool 0"
    def cmd_TOOL_CALIBRATE_TOOL_OFFSET(self, gcmd):
        try:
            sample_count = self.sample_count
            samples_result = gcmd.get("SAMPLES_RESULT", self.samples_result)
            if not self.sensor_location:
                raise gcmd.error(
                    "No recorded sensor location, please run TOOL_LOCATE_SENSOR first")
            locations = [self.locate_sensor(gcmd) for _ in range(sample_count)]
            location = self._aggregate_positions(locations, samples_result)
            gcmd.respond_info("Samples: %d, result: %s" % (sample_count,
                                                           samples_result))
            self.last_result = [location[i] - self.sensor_location[i] for i in
                                range(3)]
            self.gcode.respond_info("Tool offset is %.6f, %.6f, %.6f"
                                    % (self.last_result[0], self.last_result[1],
                                       self.last_result[2]))
        except Exception:
            self._disable_collision_detect()
            raise

    cmd_TOOL_CALIBRATE_SAVE_TOOL_OFFSET_help = "Save tool offset calibration to config"
    def cmd_TOOL_CALIBRATE_SAVE_TOOL_OFFSET(self, gcmd):
        if not self.last_result:
            gcmd.error(
                "No offset result, please run TOOL_CALIBRATE_TOOL_OFFSET first")
            return
        section_name = gcmd.get("SECTION")
        param_name = gcmd.get("ATTRIBUTE")
        template = gcmd.get("VALUE", "{x:0.6f}, {y:0.6f}, {z:0.6f}")
        value = template.format(x=self.last_result[0], y=self.last_result[1],
                                z=self.last_result[2])
        configfile = self.printer.lookup_object('configfile')
        configfile.set(section_name, param_name, value)

    cmd_TOOL_CALIBRATE_PROBE_OFFSET_help = "Calibrate the tool probe offset to nozzle tip"
    def cmd_TOOL_CALIBRATE_PROBE_OFFSET(self, gcmd):
        try:
            toolhead = self.printer.lookup_object('toolhead')
            probe = self.printer.lookup_object(self.probe_name)
            start_pos = toolhead.get_position()
            nozzle_z = self.probe_multi_axis.run_probe("z-", gcmd, speed_ratio=0.5)[2]
            
            probe_session = probe.start_probe_session(gcmd)
            probe_session.run_probe(gcmd)
            probe_z = probe_session.pull_probed_results()[0][2]
            probe_session.end_probe_session()

            z_offset = probe_z - nozzle_z + self.trigger_to_bottom_z
            self.last_probe_offset = z_offset
            self.gcode.respond_info(
                "%s: z_offset: %.3f\n"
                "The SAVE_CONFIG command will update the printer config file\n"
                "with the above and restart the printer." % (
                self.probe_name, z_offset))
            config_name = gcmd.get("PROBE", default=self.probe_name)
            if config_name:
                configfile = self.printer.lookup_object('configfile')
                configfile.set(config_name, 'z_offset', "%.6f" % (z_offset,))
            
            toolhead.move(start_pos, self.travel_speed)
            toolhead.set_position(start_pos)
        except Exception:
            self._disable_collision_detect()
            raise

    def get_status(self, eventtime):
        return {'last_result': self.last_result,
                'last_probe_offset': self.last_probe_offset,
                'calibration_probe_inactive': self.calibration_probe_inactive,
                'last_x_result': self.last_result[0],
                'last_y_result': self.last_result[1],
                'last_z_result': self.last_result[2],
                'last_toolhead_position': self.last_toolhead_position}

    cmd_TOOL_CALIBRATE_QUERY_PROBE_help = "Return the state of calibration probe"
    def cmd_TOOL_CALIBRATE_QUERY_PROBE(self, gcmd):
        toolhead = self.printer.lookup_object('toolhead')
        print_time = toolhead.get_last_move_time()
        endstop_states = [probe.query_endstop(print_time) for probe in self.probe_multi_axis.mcu_probe]
        self.calibration_probe_inactive = any(endstop_states)
        gcmd.respond_info("Calibration Probe: %s" % (["open", "TRIGGERED"][any(endstop_states)]))

    cmd_TOOL_CALIBRATE_Z_OFFSET_help = "Set the Z offset for the calibration probe"
    def cmd_TOOL_CALIBRATE_Z_OFFSET(self, gcmd):
        z_offset = gcmd.get_float('Z_OFFSET')
        self.last_probe_offset = z_offset
        self.gcode.respond_info("Z offset set to %.6f" % (z_offset,))

    cmd_TOOL_CALIBRATE_CHECK_DATA_help = "Check the data for the calibration probe"
    def cmd_TOOL_CALIBRATE_CHECK_DATA(self, gcmd):
        pass

class PrinterProbeMultiAxis:
    def __init__(self, config, mcu_probe_x, mcu_probe_y, mcu_probe_z):
        self.printer = config.get_printer()
        self.name = config.get_name()
        self.mcu_probe = [mcu_probe_x, mcu_probe_y, mcu_probe_z]
        self.speed = config.getfloat('speed', 5.0, above=0.)
        self.lift_speed = config.getfloat('lift_speed', self.speed, above=0.)
        self.max_travel = config.getfloat("max_travel", 4, above=0)
        self.last_state = False
        self.last_result = [0., 0., 0.]
        self.last_x_result = 0.
        self.last_y_result = 0.
        self.last_z_result = 0.
        self.gcode = self.printer.lookup_object('gcode')
        self.gcode_move = self.printer.load_object(config, "gcode_move")

        self.sample_count = config.getint('samples', 1, minval=1)
        self.sample_retract_dist = config.getfloat('sample_retract_dist', 2.,
                                                   above=0.)
        atypes = {'median': 'median', 'average': 'average'}
        self.samples_result = config.getchoice('samples_result', atypes,
                                               'average')
        self.samples_tolerance = config.getfloat('samples_tolerance', 0.100,
                                                 minval=0.)
        self.samples_retries = config.getint('samples_tolerance_retries', 0,
                                             minval=0)
        self.printer.lookup_object('pins').register_chip('probe_multi_axis',
                                                         self)

    def setup_pin(self, pin_type, pin_params):
        return self.mcu_probe

    def query_probes_triggered(self):
        toolhead = self.printer.lookup_object('toolhead')
        print_time = toolhead.get_last_move_time()
        states = [probe.query_endstop(print_time) for probe in self.mcu_probe]
        return any(states)

    def verify_no_crash(self):
        if self.query_probes_triggered():
            raise self.printer.command_error("Crash detected: Probe is already TRIGGERED before movement!")

    def get_lift_speed(self, gcmd=None):
        if gcmd is not None:
            return gcmd.get_float("LIFT_SPEED", self.lift_speed, above=0.)
        return self.lift_speed

    def _probe(self, speed, axis, sense, max_distance):
        phoming = self.printer.lookup_object('homing')
        pos = self._get_target_position(axis, sense, max_distance)
        try:
            epos = phoming.probing_move(self.mcu_probe[axis], pos, speed)
        except self.printer.command_error as e:
            reason = str(e)
            if "Timeout during endstop homing" in reason:
                reason += HINT_TIMEOUT
            raise self.printer.command_error(reason)
        self.gcode.respond_info("Probe made contact at %.6f, %.6f, %.6f"
                                % (epos[0], epos[1], epos[2]))
        return epos[:3]

    def _get_target_position(self, axis, sense, max_distance):
        toolhead = self.printer.lookup_object('toolhead')
        curtime = self.printer.get_reactor().monotonic()
        if 'x' not in toolhead.get_status(curtime)['homed_axes'] or \
                'y' not in toolhead.get_status(curtime)['homed_axes'] or \
                'z' not in toolhead.get_status(curtime)['homed_axes']:
            raise self.printer.command_error("Must home before probe")
        pos = list(toolhead.get_position())
        kin_status = toolhead.get_kinematics().get_status(curtime)
        if 'axis_minimum' not in kin_status or 'axis_maximum' not in kin_status:
            raise self.printer.command_error(
                "Tools calibrate only works with cartesian / corexy kinematics")
        if sense > 0:
            pos[axis] = min(pos[axis] + max_distance,
                            kin_status['axis_maximum'][axis])
        else:
            pos[axis] = max(pos[axis] - max_distance,
                            kin_status['axis_minimum'][axis])
        return pos

    def _move(self, coord, speed):
        self.printer.lookup_object('toolhead').manual_move(coord, speed)

    def _calc_mean(self, positions):
        count = float(len(positions))
        return [sum([pos[i] for pos in positions]) / count
                for i in range(3)]

    def _calc_median(self, positions, axis):
        axis_sorted = sorted(positions, key=(lambda p: p[axis]))
        middle = len(positions) // 2
        if (len(positions) & 1) == 1:
            return axis_sorted[middle]
        return self._calc_mean(axis_sorted[middle - 1:middle + 1])

    def run_probe(self, direction, gcmd, speed_ratio=1.0, samples=None,
                  max_distance=100.0):
        speed = gcmd.get_float("PROBE_SPEED", self.speed,
                               above=0.) * speed_ratio
        if direction not in direction_types:
            raise self.printer.command_error("Wrong value for DIRECTION.")

        (axis, sense) = direction_types[direction]
        lift_speed = self.get_lift_speed(gcmd)
        sample_count = gcmd.get_int("SAMPLES",
                                    samples if samples else self.sample_count,
                                    minval=1)
        sample_retract_dist = gcmd.get_float("SAMPLE_RETRACT_DIST",
                                             self.sample_retract_dist, above=0.)
        samples_tolerance = gcmd.get_float("SAMPLES_TOLERANCE",
                                           self.samples_tolerance, minval=0.)
        samples_retries = gcmd.get_int("SAMPLES_TOLERANCE_RETRIES",
                                       self.samples_retries, minval=0)
        samples_result = gcmd.get("SAMPLES_RESULT", self.samples_result)

        toolhead = self.printer.lookup_object('toolhead')
        probe_start = list(toolhead.get_position())
        retries = 0
        positions = []

        self.mcu_probe[axis].multi_probe_begin()
        toolhead.dwell(0.75)
        self.mcu_probe[axis].home_zero()

        self.verify_no_crash()

        while len(positions) < sample_count:
            pos = self._probe(speed, axis, sense, max_distance)
            positions.append(pos)
            
            axis_positions = [p[axis] for p in positions]
            if max(axis_positions) - min(axis_positions) > samples_tolerance:
                if retries >= samples_retries:
                    self.mcu_probe[axis].multi_probe_end()
                    # 发生公差超限时，先调用 _disable_collision_detect 关闭加速度监听
                    coll = self.printer.lookup_object('collision_detect', None)
                    if coll is not None:
                        try:
                            coll.cmd_disable()
                        except Exception:
                            pass
                    raise gcmd.error("Probe samples exceed samples_tolerance")
                gcmd.respond_info("Probe samples exceed tolerance. Retrying...")
                toolhead.dwell(0.75)
                self.mcu_probe[axis].home_zero()
                retries += 1
                positions = []
                self._move(probe_start, lift_speed)
                continue

            if len(positions) < sample_count:
                liftpos = list(probe_start)
                liftpos[axis] = pos[axis] - sense * sample_retract_dist
                self._move(liftpos, lift_speed)

        self.mcu_probe[axis].multi_probe_end()

        if samples_result == 'median':
            return self._calc_median(positions, axis)
        return self._calc_mean(positions)

class ProbeEndstopWrapper:
    def __init__(self, config, axis):
        self.printer = config.get_printer()
        self.axis = axis
        self.idex = config.has_section('dual_carriage')
        ppins = self.printer.lookup_object('pins')
        pin = config.get('pin')
        ppins.allow_multi_use_pin(pin.replace('^', '').replace('!', ''))
        pin_params = ppins.lookup_pin(pin, can_invert=True, can_pullup=True)
        mcu = pin_params['chip']
        self.mcu_endstop = mcu.setup_pin('endstop', pin_params)
        self.printer.register_event_handler('klippy:mcu_identify',
                                            self._handle_mcu_identify)
        
        self.get_mcu = self.mcu_endstop.get_mcu
        self.add_stepper = self.mcu_endstop.add_stepper
        self.get_steppers = self._get_steppers
        self.home_start = self.mcu_endstop.home_start
        self.home_wait = self.mcu_endstop.home_wait
        self.query_endstop = self.mcu_endstop.query_endstop
        self.home_zero = self.mcu_endstop.home_zero
        self.home_check = self.mcu_endstop.home_check
        self.multi_probe_begin = self.mcu_endstop.multi_probe_begin
        self.multi_probe_end = self.mcu_endstop.multi_probe_end
        self.probe_prepare = self.mcu_endstop.probe_prepare
        self.probe_finish = self.mcu_endstop.probe_finish

    def _get_steppers(self):
        if self.idex and self.axis == 'x':
            dual_carriage = self.printer.lookup_object('dual_carriage')
            prime_rail = dual_carriage.get_primary_rail()
            return prime_rail.get_rail().get_steppers()
        else:
            return self.mcu_endstop.get_steppers()

    def _handle_mcu_identify(self):
        kin = self.printer.lookup_object('toolhead').get_kinematics()
        for stepper in kin.get_steppers():
            if stepper.is_active_axis(self.axis) or self.axis in ['x', 'y']:
                self.add_stepper(stepper)

    def get_position_endstop(self):
        return 0.

def load_config(config):
    return ToolsCalibrate(config)
