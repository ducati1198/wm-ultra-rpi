import logging, math, bisect
import mcu
import pins

from . import cs1237, probe, manual_probe
OUT_OF_RANGE = 0b11111111

class WeighCalibration:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.name = config.get_name()
        self.dritf_comp = WeighDriftCompensation()
    def set_target_adc_value(self, target_adc_value):
        self.target_adc_value = target_adc_value
        return self.target_adc_value
    def is_calibrated(self):
        pass
    def load_calibration(self, cal):
        pass
    def apply_calibration(self, samples):
        pass
    def freq_to_height(self, freq):
        pass
    def height_to_freq(self, height):
        pass
    def do_calibration_moves(self, move_speed):
        toolhead = self.printer.lookup_object('toolhead')
        kin = toolhead.get_kinematics()
        move = toolhead.manual_move
        # Start data collection
        msgs = []
        is_finished = False
        def handle_batch(msg):
            if is_finished:
                return False
            msgs.append(msg)
            return True
        self.printer.lookup_object(self.name).add_client(handle_batch)
        toolhead.dwell(1.)
        self.dritf_comp.note_z_calibration_start()
        # Move to each 40um position
        max_z = 4.0 
        samp_dist = 0.040
        req_zpos = [i*samp_dist for i in range(int(max_z / samp_dist) + 1)]
        start_pos = toolhead.get_position()
        times = []
        for zpos in req_zpos:
            # Move to next position (always descending to reduce backlash)
            hop_pos = list(start_pos)
            hop_pos[2] += zpos + 0.500
            move(hop_pos, move_speed)
            next_pos = list(start_pos)
            next_pos[2] += zpos
            move(next_pos, move_speed)
            # Note sample timing
            start_query_time = toolhead.get_last_move_time() + 0.050
            end_query_time = start_query_time + 0.100
            toolhead.dwell(0.200)
            # Find Z position based on actual commanded stepper position
            toolhead.flush_step_generation()
            kin_spos = {s.get_name(): s.get_commanded_position()
                        for s in kin.get_steppers()}
            kin_pos = kin.calc_position(kin_spos)
            times.append((start_query_time, end_query_time, kin_pos[2]))
        toolhead.dwell(1.0)
        toolhead.wait_moves()
        self.dritf_comp.note_z_calibration_finish()
        # Finish data collection
        is_finished = True
        # Correlate query responses
        cal = {}
        step = 0
        for msg in msgs:
            for query_time, freq, old_z in msg['data']:
                # Add to step tracking
                while step < len(times) and query_time > times[step][1]:
                    step += 1
                if step < len(times) and query_time >= times[step][0]:
                    cal.setdefault(times[step][2], []).append(freq)
        if len(cal) != len(times):
            raise self.printer.commad_error(
                "Failed calibration - incomplete sensor data"
            )
        return cal

    def calc_freqs(self, meas):
        total_count = total_variance = 0
        positions = {}
        for pos, freqs in meas.items():
            count = len(freqs)
            freq_avg = float(sum(freqs)) / count
            positions[pos] = freq_avg
            total_count += count
            total_variance += sum([(f - freq_avg)**2 for f in freqs])
        
        return positions, math.sqrt(total_variance / total_count), total_count
    def post_manual_probe(self, kin_pos):
        if kin_pos in None:
            return
        curpos = list(kin_pos)
        move = self.printer.lookup_object('toolhead').manual_move
        probe_calibrate_z = curpos[2]
        curpos[2] += 5.
        move(curpos, self.probe_speed)
        pprobe = self.printer.lookup_object("probe")
        x_offset, y_offset, z_offset = pprobe.get_offsets()
        curpos[0] -= x_offset
        curpos[1] -= y_offset
        move(curpos, self.probe_speed)
        curpos[2] -= 5. - 0.050
        move(curpos, self.probe_speed)
        cal = self.do_calibration_moves(self.probe_speed)
        positions, std, total = self.calc_freqs(cal)
        last_freq = 0.
        for pos, freq in reversed(sorted(positions.items())):
            if freq <= last_freq:
                raise self.printer.command_error(
                    "Failed calibration - frequency not increasing each step"
                )
            last_freq = freq
        gcode = self.printer.lookup_object("gcode")
        gcode.respond_info(
            "probe_weigh"
        )

    cmd_WEIGH_CALIBRATE_help = "Calibrate weigh probe"
    def cmd_WEIGH_CALIBRATE(self, gcmd):
        self.probe_speed = gcmd.get_float("PROBE_SPEED", 5., above=0.)
        # Start manual probe
    def register_drift_compensation(self, comp):
        self.dritf_comp = comp

class WeighGatherSamples:
    def __init__(self, printer, sensor_helper, calibration):
        self._printer = printer
        self._sensor_helper = sensor_helper
        self._calibration = calibration
        self._samples = []
        self._probe_times = []
        self._need_stop = False

    def _add_measurement(self, msg):
        if self._need_stop:
            del self._samples[:]
            return False
        self._samples.append(msg)
    def finish(self):
        self._need_stop = True
    def _await_samples(self):
        reactor = self._printer.get_reactor()
        mcu = self._sensor_helper.get_mcu()
        while self._probe_times:
            start_time, end_time, pos_time, toolhead_pos = self._probe_times[0]
            systime = reactor.monotonic()
            est_print_time = mcu.estimated_print_time(systime)
            if est_print_time > end_time + 1.0:
                raise self._printer.command_error(
                    "probe_weigh sensor outage")
            reactor.pause(systime + 0.010)
    def _lookup_toolhead_pos(self, pos_time):
        toolhead = self._printer.lookup_object('toolhead')
        kin = toolhead.get_kinematics()
        kin_spos = {s.get_name(): s.mcu_to_commanded_position(
                                      s.get_past_mcu_position(pos_time))
                    for s in kin.get_steppers()}
        return kin.calc_position(kin_spos)
    def note_probe(self, start_time, end_time, toolhead_pos):
        self._probe_times.append((start_time, end_time, None, toolhead_pos))
    def note_probe_and_position(self, start_time, end_time, pos_time):
        self._probe_times.append((start_time, end_time, pos_time, None))

class WeighEndstopWrapper:
    REASON_SENSOR_ERROR = mcu.MCU_trsync.REASON_COMMS_TIMEOUT + 1
    def __init__(self, config, sensor_helper, calibration):
        self._printer = config.get_printer()
        self._sensor_helper = sensor_helper
        self._calibration = calibration
        self._z_offset = config.getfloat('z offset', 0.)
        
        # 为每个MCU创建独立的TriggerDispatch实例
        self._dispatch1 = mcu.TriggerDispatch(self._sensor_helper.mcu)
        logging.info("ENDSTOPS:dispatch1: %s" % self._dispatch1)
        logging.info("ENDSTOPS:sensor_helper.mcu: %s" % self._sensor_helper.mcu)

        # 检查并初始化第二个MCU
        if hasattr(self._sensor_helper, 'mcu2') and self._sensor_helper.mcu2 is not None:
            self._dispatch2 = mcu.TriggerDispatch(self._sensor_helper.mcu2)
            logging.info("ENDSTOPS:dispatch2: %s" % self._dispatch2)
            logging.info("ENDSTOPS:sensor_helper.mcu2: %s" % self._sensor_helper.mcu2)
        else:
            self._dispatch2 = None
            logging.info("ENDSTOPS:No second MCU available")

        # 检查并初始化第三个MCU
        if hasattr(self._sensor_helper, 'mcu3') and self._sensor_helper.mcu3 is not None:
            self._dispatch3 = mcu.TriggerDispatch(self._sensor_helper.mcu3)
            logging.info("ENDSTOPS:dispatch3: %s" % self._dispatch3)
            logging.info("ENDSTOPS:sensor_helper.mcu3: %s" % self._sensor_helper.mcu3)
        else:
            self._dispatch3 = None
            logging.info("ENDSTOPS:No third MCU available")

        # 检查并初始化第四个MCU
        if hasattr(self._sensor_helper, 'mcu4') and self._sensor_helper.mcu4 is not None:
            self._dispatch4 = mcu.TriggerDispatch(self._sensor_helper.mcu4)
            logging.info("ENDSTOPS:dispatch4: %s" % self._dispatch4)
            logging.info("ENDSTOPS:sensor_helper.mcu4: %s" % self._sensor_helper.mcu4)
        else:
            self._dispatch4 = None
            logging.info("ENDSTOPS:No fourth MCU available")
        # 检查并初始化第五个MCU
        if hasattr(self._sensor_helper, 'mcu5') and self._sensor_helper.mcu5 is not None:
            self._dispatch5 = mcu.TriggerDispatch(self._sensor_helper.mcu5)
            logging.info("ENDSTOPS:dispatch5: %s" % self._dispatch5)
            logging.info("ENDSTOPS:sensor_helper.mcu5: %s" % self._sensor_helper.mcu5)
        else:
            self._dispatch5 = None
            logging.info("ENDSTOPS:No fifth MCU available")
        # 检查并初始化第六个MCU
        if hasattr(self._sensor_helper, 'mcu6') and self._sensor_helper.mcu6 is not None:
            self._dispatch6 = mcu.TriggerDispatch(self._sensor_helper.mcu6)
            logging.info("ENDSTOPS:dispatch6: %s" % self._dispatch6)
            logging.info("ENDSTOPS:sensor_helper.mcu6: %s" % self._sensor_helper.mcu6)
        else:
            self._dispatch6 = None
            logging.info("ENDSTOPS:No sixth MCU available")

        self._trigger_time = 0.

        # z加速度配置
        self.gcode = self._printer.lookup_object('gcode')
        self.probe_accel = config.getfloat('probe_accel', 0., minval=0.)

        # 这里是影响传感器采样的频率，为什么设置这个值，是因为用逻辑分析仪
        # 补抓可以针对传感器完整采样
        self.freq_clock = .00005    
        self._gather = None

    def get_mcu(self):
        return self._sensor_helper.get_mcu()

    def _get_current_dispatch(self):
        # logging.info("ENDSTOPS:_get_current_dispatch")
        current_mcu = self.get_mcu()
        logging.info("ENDSTOPS:current_mcu: %s" % current_mcu)
        # logging.info("ENDSTOPS:_get_current_dispatch.mcu: %s" % current_mcu)
        
        if current_mcu == self._sensor_helper.mcu:
            # logging.info("ENDSTOPS:current_mcu == self._sensor_helper.mcu")
            return self._dispatch1
        elif self._dispatch2 is not None and current_mcu == self._sensor_helper.mcu2:
            # logging.info("ENDSTOPS:current_mcu == self._sensor_helper.mcu2")
            return self._dispatch2
        elif self._dispatch3 is not None and current_mcu == self._sensor_helper.mcu3:
            # logging.info("ENDSTOPS:current_mcu == self._sensor_helper.mcu3")
            return self._dispatch3
        elif self._dispatch4 is not None and current_mcu == self._sensor_helper.mcu4:
            # logging.info("ENDSTOPS:current_mcu == self._sensor_helper.mcu4")
            return self._dispatch4
        elif self._dispatch5 is not None and current_mcu == self._sensor_helper.mcu5:
            # logging.info("ENDSTOPS:current_mcu == self._sensor_helper.mcu5")
            return self._dispatch5
        elif self._dispatch6 is not None and current_mcu == self._sensor_helper.mcu6:
            # logging.info("ENDSTOPS:current_mcu == self._sensor_helper.mcu6")
            return self._dispatch6
        else:
            # logging.info("ENDSTOPS:Using default dispatch (dispatch1)")
            return self._dispatch1

    def add_stepper(self, stepper):
        # 为所有存在的dispatch添加stepper
        self._dispatch1.add_stepper(stepper)
        if self._dispatch2 is not None:
            self._dispatch2.add_stepper(stepper)
        if self._dispatch3 is not None:
            self._dispatch3.add_stepper(stepper)
        if self._dispatch4 is not None:
            self._dispatch4.add_stepper(stepper)
        if self._dispatch5 is not None:
            self._dispatch5.add_stepper(stepper)
        if self._dispatch6 is not None:
            self._dispatch6.add_stepper(stepper)

    def get_steppers(self):
        # 返回当前dispatch的steppers
        return self._get_current_dispatch().get_steppers()

    def home_start(self, print_time, sample_time, sample_count, rest_time,
                    triggered=True):
        self._trigger_time = 0.
        # logging.info("ENDSTOPS:home_start")
        current_dispatch = self._get_current_dispatch()
        trigger_completion = current_dispatch.start(print_time)
        # logging.info("ENDSTOPS:home_start_end")
        self._sensor_helper.setup_home(
            print_time, current_dispatch.get_oid(),
            mcu.MCU_trsync.REASON_ENDSTOP_HIT, self.REASON_SENSOR_ERROR, 
            self.freq_clock
        )
        # logging.info("ENDSTOPS:home_start_end_end")
        return trigger_completion

    def home_wait(self, home_end_time):
        # logging.info("ENDSTOPS:home_wait")
        current_dispatch = self._get_current_dispatch()
        current_dispatch.wait_end(home_end_time)
        trigger_time = self._sensor_helper.clear_home()
        res = current_dispatch.stop()
        if res >= mcu.MCU_trsync.REASON_COMMS_TIMEOUT:
            if res == mcu.MCU_trsync.REASON_COMMS_TIMEOUT:
                raise
                # raise self._printer.command_error(
                #     "Communication timeout during homing"
                # )
            raise self._printer.command_error("Weigh sensor error")
        if res != mcu.MCU_trsync.REASON_ENDSTOP_HIT:
            return 0.
        if self._sensor_helper.get_mcu().is_fileoutput():
            return home_end_time
        self._trigger_time = trigger_time
        return trigger_time
    def home_zero(self):
        self._sensor_helper.zero_home()
    def home_check(self):
        self._sensor_helper.check_cs1237_zero()
    def query_endstop(self, print_time):
        return False  # xxx
    def probing_move(self, pos, speed):
        # 检查传感器是否正常/配置是否正确
        # self.home_check()
        phoming = self._printer.lookup_object('homing')
        return phoming.probing_move(self, pos, speed)
    def multi_probe_begin(self):
        self._gather = WeighGatherSamples(self._printer, self._sensor_helper,
                                            self._calibration)
    def multi_probe_end(self):
        self._gather.finish()
        self._gather = None
    def probe_prepare(self, hmove):
        toolhead = self._printer.lookup_object('toolhead')
        logging.info("WEIGHT-probe_accel:%s" % self.probe_accel)
        if self.probe_accel:
            logging.info("WEIGHT-enter probe_accel")
            systime = self._printer.get_reactor().monotonic()
            toolhead_info = toolhead.get_status(systime)
            self.old_max_accel = toolhead_info['max_accel']
            self.gcode.run_script_from_command(
                    "M204 S%.3f" % (self.probe_accel,))
        # pass
    def probe_finish(self, hmove):
        logging.info("WEIGHT-probe_accel:%s" % self.probe_accel)
        if self.probe_accel:
            logging.info("WEIGHT-exit probe_accel")
            self.gcode.run_script_from_command(
                    "M204 S%.3f" % (self.old_max_accel,))
        # pass
    def get_position_endstop(self):
        return self._z_offset
    
# Homing via probe_air:z_virtual_endstop
class HomingViaProbeHelper:
    def __init__(self, config, mcu_probe):
        self.printer = config.get_printer()
        self.mcu_probe = mcu_probe
        self.multi_probe_pending = False
        # Register z_virtual_endstop pin
        self.printer.lookup_object('pins').register_chip('probe_air', self)
        # Register event handlers
        self.printer.register_event_handler('klippy:mcu_identify',
                                            self._handle_mcu_identify)
        self.printer.register_event_handler("homing:homing_move_begin",
                                            self._handle_homing_move_begin)
        self.printer.register_event_handler("homing:homing_move_end",
                                            self._handle_homing_move_end)
        self.printer.register_event_handler("homing:home_rails_begin",
                                            self._handle_home_rails_begin)
        self.printer.register_event_handler("homing:home_rails_end",
                                            self._handle_home_rails_end)
        self.printer.register_event_handler("gcode:command_error",
                                            self._handle_command_error)
    def _handle_mcu_identify(self):
        kin = self.printer.lookup_object('toolhead').get_kinematics()
        for stepper in kin.get_steppers():
            if stepper.is_active_axis('z'):
                self.mcu_probe.add_stepper(stepper)
    def _handle_homing_move_begin(self, hmove):
        if self.mcu_probe in hmove.get_mcu_endstops():
            self.mcu_probe.probe_prepare(hmove)
    def _handle_homing_move_end(self, hmove):
        if self.mcu_probe in hmove.get_mcu_endstops():
            self.mcu_probe.probe_finish(hmove)
    def _handle_home_rails_begin(self, homing_state, rails):
        endstops = [es for rail in rails for es, name in rail.get_endstops()]
        if self.mcu_probe in endstops:
            self.mcu_probe.multi_probe_begin()
            self.multi_probe_pending = True
    def _handle_home_rails_end(self, homing_state, rails):
        endstops = [es for rail in rails for es, name in rail.get_endstops()]
        if self.multi_probe_pending and self.mcu_probe in endstops:
            self.multi_probe_pending = False
            self.mcu_probe.multi_probe_end()
    def _handle_command_error(self):
        if self.multi_probe_pending:
            self.multi_probe_pending = False
            try:
                self.mcu_probe.multi_probe_end()
            except:
                logging.exception("Homing multi-probe end")
    def setup_pin(self, pin_type, pin_params):
        if pin_type != 'endstop' or pin_params['pin'] != 'z_virtual_endstop':
            raise pins.error("Probe virtual endstop only useful as endstop pin")
        if pin_params['invert'] or pin_params['pullup']:
            raise pins.error("Can not pullup/invert probe virtual endstop")
        return self.mcu_probe
    
# Main "printer object"
class PrinterAirProbe:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.calibration = WeighCalibration(config)
        # sensors = {"hx711": hx711.HX711, "cs1237": cs1237.CS1237}
        # sensors = {"hx711": hx711.HX711, "c_sensor": cs1237.CS1237}
        sensors = {"c_sensor": cs1237.CS1237}
        sensor_type = config.getchoice('sensor_type', {s: s for s in sensors})
        self.register_probe = config.getboolean('register_probe', True)
        self.sensor_helper = sensors[sensor_type](config, self.calibration)
        # # Probe interface
        self.mcu_probe = WeighEndstopWrapper(config, self.sensor_helper,
                                                self.calibration)

        if self.register_probe:
            self.cmd_helper = probe.ProbeCommandHelper(config, self, self.mcu_probe.query_endstop)
            self.probe_offsets = probe.ProbeOffsetsHelper(config)
            self.probe_session = probe.ProbeSessionHelper(config, self.mcu_probe)
            self.printer.add_object('probe', self)
        else:
            self.homing_helper = HomingViaProbeHelper(config, self.mcu_probe)

    def add_client(self, cb):
        pass
    def get_probe_params(self, gcmd=None):
        if self.register_probe:
            return self.probe_session.get_probe_params(gcmd)
        else:
            return {}
    def get_offsets(self):
        if self.register_probe:
            return self.probe_offsets.get_offsets()
        else:   
            return {}
    def get_status(self, eventtime):
        if self.register_probe:
            return self.cmd_helper.get_status(eventtime)
        else:
            return {}
    def start_probe_session(self, gcmd):
        if self.register_probe:
            return self.probe_session.start_probe_session(gcmd)
        else:
            return {}
    def register_drift_compensation(self, comp):
        self.calibration.register_drift_compensation(comp)

class WeighDriftCompensation:
    def get_temperature(self):
        return 0.
    def note_z_calibration_start(self):
        pass
    def note_z_calibration_finish(self):
        pass
    def adjust_freq(self, freq, temp=None):
        return freq
    def unadjust_freq(self, freq, temp=None):
        return freq

