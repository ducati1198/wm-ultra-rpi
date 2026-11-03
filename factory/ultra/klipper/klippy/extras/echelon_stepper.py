import stepper, chelper
from . import force_move

from kinematics import extruder

import logging

import json

class DripModeEndSignal(Exception):
    pass

class EchelonStepper:
    def __init__(self, config):
        self.name = stepper_name = config.get_name().split()[-1]
        self.printer = printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.all_mcus = [
            m for n, m in self.printer.lookup_objects(module='mcu')]

        self.can_home = False
        self.rail = stepper.PrinterRail(
                config, need_position_minmax=False, default_position_endstop=0.)
        self.steppers = self.rail.get_steppers()
        
        self.velocity = config.getfloat('velocity', 5., above=0.)
        #self.color_feeder = config.get('color_feeder')
        self.accel = self.homing_accel = config.getfloat('accel', 0., minval=0.)
        self.next_cmd_time = 0.
        self.print_time = 0.
        self.last_flush_time = 0.
        self.last_extruder_dir = 1
        self.last_feed_dir = 1
        # Setup iterative solver
        ffi_main, ffi_lib = chelper.get_ffi()
        self.trapq = ffi_main.gc(ffi_lib.trapq_alloc(), ffi_lib.trapq_free)
        self.trapq_append = ffi_lib.trapq_append
        self.trapq_finalize_moves = ffi_lib.trapq_finalize_moves
        self.rail.setup_itersolve('cartesian_stepper_alloc', b'x')
        self.rail.set_trapq(self.trapq)
        self.gcode = gcode = self.printer.lookup_object('gcode')

        # self.endstop_state = self._query_endstop()
        # self.endstop_state = "No Busy"
        
        gcode.register_mux_command('ECHELON_SP', "STEPPER", 
                                    stepper_name, self.cmd_ECHELON_SP)
        gcode.register_mux_command('ECHELON_QUERY', "STEPPER", 
                                    stepper_name, self.cmd_ECHELON_STEPPER_QUERY)
        gcode.register_mux_command('ECHELON_STEPPER', "STEPPER", 
                                    stepper_name, self.cmd_ECHELON_STEPPER)
        gcode.register_mux_command('ECHELON_STEPPER_HOMING', "STEPPER",
                                    stepper_name, self.cmd_ECHELON_STEPPER_HOMING)
        gcode.register_mux_command('ECHELON_INVERT', "STEPPER",
                                    stepper_name, self.cmd_ECHELON_ENDSTOP_INVERT)

        gcode.register_mux_command("ECH_SYNC_EXTRUDER_MOTION", "STEPPER",
                                    self.name, self.cmd_ECH_SYNC_EXTRUDER_MOTION,
                                    desc=self.cmd_ECH_SYNC_EXTRUDER_MOTION_help)

        gcode.register_mux_command('ECHELON_STEPPER_INVERT_DIR', "STEPPER",
                                    stepper_name, self.cmd_ECHELON_STEPPER_INVERT_DIR)
        
        gcode.register_mux_command('ECHELON_PRINT_DIR', "STEPPER",
                                    stepper_name, self.cmd_ECHELON_PRINT_DIR)
        
        gcode.register_mux_command('ECHELON_STEPPER_DISABLE', "STEPPER",
                                    stepper_name, self.cmd_ECHELON_STEPPER_DISABLE)
        
                                    


    def sync_print_time(self):
        toolhead = self.printer.lookup_object('toolhead')
        print_time = toolhead.get_last_move_time()
        if self.next_cmd_time > print_time:
            toolhead.dwell(self.next_cmd_time - print_time)
        else:
            self.next_cmd_time = print_time

    def do_enable(self, enable):
        self.sync_print_time()
        stepper_enable = self.printer.lookup_object('stepper_enable')
        if enable:
            for s in self.steppers:
                se = stepper_enable.lookup_enable(s.get_name())
                se.motor_enable(self.next_cmd_time)
        else:
            for s in self.steppers:
                se = stepper_enable.lookup_enable(s.get_name())
                se.motor_disable(self.next_cmd_time)
        self.sync_print_time()

    def do_set_position(self, setpos):
        self.rail.set_position([setpos, 0., 0.])

    def do_move(self, movepos, speed, accel, sync=True, drip_completion=None):
        self.sync_print_time()
        toolhead = self.printer.lookup_object('toolhead')
        self.print_time = toolhead.get_last_move_time()
        cp = self.rail.get_commanded_position()
        dist = movepos - cp
        axis_r, accel_t, cruise_t, cruise_v = force_move.calc_move_time(
            dist, speed, accel)
        
        self.trapq_append(self.trapq, self.next_cmd_time,
                          accel_t, cruise_t, accel_t,
                          cp, 0., 0., axis_r, 0., 0.,
                          0., cruise_v, accel)
        self.next_cmd_time = self.next_cmd_time + accel_t + cruise_t + accel_t
        reactor = self.printer.get_reactor()
        if drip_completion != None:
            flush_delay = 0.5
            curtime = reactor.monotonic()
            est_print_time = self.printer.lookup_object('mcu').estimated_print_time(curtime)
            try:
                while self.print_time < self.next_cmd_time:
                    if drip_completion.test():
                        if self.print_time != 0.0:
                            self.next_cmd_time = self.print_time + 0.5
                        else:
                            self.next_cmd_time = toolhead.get_last_move_time() + 2.0
                        self.sync_print_time()
                        raise DripModeEndSignal()
                    curtime = reactor.monotonic()
                    est_print_time = self.printer.lookup_object('mcu').estimated_print_time(curtime)
                    wait_time = self.print_time - est_print_time - flush_delay  
                    if wait_time > 0. :
                        drip_completion.wait(curtime + wait_time)
                        continue
                    npt = min(self.print_time + 0.50, self.next_cmd_time)
                    toolhead.note_mcu_movequeue_activity(npt, set_step_gen_time=True)
                    pt_delay = 0.1
                    flush_time = max(self.last_flush_time, self.print_time - pt_delay)
                    self.print_time = max(self.print_time, npt)
                    want_flush_time = max(flush_time, self.print_time - pt_delay)
                    self.rail.generate_steps(npt)
                    self.trapq_finalize_moves(self.trapq, npt, npt + 2)
            except DripModeEndSignal as e: 
                self.trapq_finalize_moves(self.trapq, reactor.NEVER, 0)
        else:
            self.rail.generate_steps(self.next_cmd_time)
            self.trapq_finalize_moves(self.trapq, self.next_cmd_time + 99999.9,
                                  self.next_cmd_time + 99999.9)
            toolhead.note_mcu_movequeue_activity(self.next_cmd_time)
            if sync:
                self.sync_print_time()
    def _query_endstop(self):
        toolhead = self.printer.lookup_object('toolhead')
        print_time = toolhead.get_last_move_time()
        return self.rail.endstops[0][0].query_endstop(print_time)
    def do_homing_move(self, movepos, speed, accel, triggered, check_trigger):
        self.homing_accel = accel
        pos = [movepos, 0., 0., 0.]
        endstops = self.rail.get_endstops()
        phoming = self.printer.lookup_object('homing')
        phoming.manual_home(self, endstops, pos, speed,
                            triggered, check_trigger)

    def cmd_ECHELON_ENDSTOP_INVERT(self, gcmd):
        self.rail.endstops[0][0]._invert = ~self.rail.endstops[0][0]._invert

    def cmd_ECHELON_PRINT_DIR(self, gcmd):
        feed_dir = self.steppers[0].get_cur_dir()
        extruder_obj = self.printer.lookup_object("extruder_stepper extruder1", None)
        if extruder_obj is None:
            raise self.printer.command_error("extruder1 is not a valid extruder.")

        extruder_dir = extruder_obj.extruder_stepper.stepper.get_cur_dir()
        logging.info(f"echelon cur dir: {feed_dir}, extruder cur dir: {extruder_dir}")

        invert_dir, orig_invert_dir = extruder_obj.extruder_stepper.stepper.get_dir_inverted()
        logging.info(f"extruder inverted: {invert_dir}")

    def cmd_ECHELON_STEPPER_INVERT_DIR(self, gcmd):
        invert_ext = gcmd.get_int('INVERT_EXT', 0)
        cur_dir = self.steppers[0].get_cur_dir()
        logging.info("Before:")
        logging.info(f"echelon cur dir: {cur_dir}")

        extruder_obj = self.printer.lookup_object("extruder_stepper extruder1", None)
        if extruder_obj is None:
            raise self.printer.command_error("extruder1 is not a valid extruder.")

        extruder_dir = extruder_obj.extruder_stepper.stepper.get_cur_dir()
        logging.info(f"extruder cur dir: {extruder_dir}")

        invert_dir, orig_invert_dir = self.steppers[0].get_dir_inverted()
        next_invert_dir = invert_dir

        toolhead = self.printer.lookup_object('toolhead')
        toolhead.flush_step_generation()
        #self.steppers[0].set_dir_inverted(next_invert_dir)
        #if (enable == 1) and ((extruder_dir == 0) or (extruder_dir == -1)):
        #if (enable == 1) and ((self.last_extruder_dir != extruder_dir)):
            #next_invert_dir = not invert_dir
        if (invert_ext == 0):
            if (self.last_extruder_dir == 1) or (self.last_extruder_dir == -1):
                set_ext_dir = 1
                self.gcode.run_script("M83\nG92 E0\nG91\nG1 E1 F300\nG90\nG4 P1000")
            else:
                self.gcode.run_script("M83\nG92 E0\nG91\nG1 E-1 F300\nG90\nG4 P1000")
                set_ext_dir = 0
        elif (invert_ext == 1):
            if (self.last_extruder_dir == 1) or (self.last_extruder_dir == -1):
                set_ext_dir = 0
                self.gcode.run_script("M83\nG92 E0\nG91\nG1 E-1 F300\nG90\nG4 P1000")
        
            else:
                set_ext_dir = 1
                self.gcode.run_script("M83\nG92 E0\nG91\nG1 E1 F300\nG90\nG4 P1000")

        extruder_obj.extruder_stepper.stepper.set_step_dir(set_ext_dir)
        logging.info(f"need invert extruder dir to {set_ext_dir}")    
            

        cur_dir = self.steppers[0].get_cur_dir()
        extruder_dir = extruder_obj.extruder_stepper.stepper.get_cur_dir()
        
        self.last_extruder_dir = set_ext_dir
        logging.info(f"after invert: echelon cur dir: {cur_dir}")
        logging.info(f"extruder cur dir: {extruder_dir}")

        # invert_dir, orig_invert_dir = self.steppers[0].get_dir_inverted()
        # next_invert_dir = orig_invert_dir
        # if (enable == 1) :
        #     next_invert_dir = not orig_invert_dir
        # toolhead = self.printer.lookup_object('toolhead')
        # toolhead.flush_step_generation()
        # self.steppers[0].set_dir_inverted(next_invert_dir)
            
    def cmd_ECHELON_STEPPER_DISABLE(self, gcmd): 
        self.do_enable(False)
        
    def cmd_ECHELON_SP(self, gcmd):
        self.do_set_position(0.)
    def cmd_ECHELON_STEPPER_QUERY(self, gcmd):
        self.gcode.respond_info(f"ENDSTOP: {self._query_endstop()}")
    def cmd_ECHELON_STEPPER(self, gcmd):
        
        self.print_time = self.print_time + 5
        # self.next_cmd_time = self.next_cmd_time + 5
        speed = gcmd.get_float('SPEED', self.velocity, above=0.)
        accel = gcmd.get_float('ACCEL', self.accel, minval=0.)
        movepos = gcmd.get_float('MOVE')
        sync = gcmd.get_int('SYNC', 1)
        if sync == 0:
            self.do_move(movepos, speed, accel, False)
        else:
            self.do_move(movepos, speed, accel, True)
        

    cmd_ECHELON_STEPPER_HOMING_help = "Command a stepper homing"
    def cmd_ECHELON_STEPPER_HOMING(self, gcmd):
        # color_feeder = self.printer.lookup_object(self.color_feeder)        
        # self.homing_move = True
        speed = gcmd.get_float('SPEED', self.velocity, above=0.)
        accel = gcmd.get_float('ACCEL', self.accel, minval=0.)
        movepos = gcmd.get_float('MOVE')
        post_dist = gcmd.get_float('PDI', 0.0)
        sync = gcmd.get_int('SYNC', 1)
        logging.info(f"echelon_stepper_homing,sync is {sync}")
        try:
            self.do_homing_move(movepos, speed, accel,
                            True, 1)
        except Exception:
            eventtime = self.reactor.monotonic()
            idle_timeout = self.printer.lookup_object("idle_timeout")
            is_printing = idle_timeout.get_status(eventtime)["state"] == "Printing"

            # if is_printing:
            #     logging.warning(f"Printing is paused: homing failed")   
            #     self.gcode.run_script_from_command("PAUSE\n")  

            #current_feed = self.printer.lookup_object("color_feeder")
            #_current_feed = current_feed.get_status(eventtime)["current_feed"]
            # 一直进料没成功
            # 同时记录日志
            logging.warning(f"WARNING: UNLOCK TOOL FAILED")
        #if movepos >= 0.0:
        #    self.steppers[0].set_step_dir(1)
        #else:
        #    self.steppers[0].set_step_dir(0)

       
        # if post_dist > 0.0:
        #     self.steppers[0].set_step_dir(1)
        #     self.do_set_position(0.)
        #     self.do_move(post_dist, speed, accel, True)
        # elif post_dist < 0.0:
        #     self.steppers[0].set_step_dir(0)
        #     self.do_set_position(0.)
        #     self.do_move(post_dist, speed, accel, True)
        self.do_set_position(0.)
        if sync == 0:
            self.do_move(post_dist, speed, accel, False)
        else:
            self.do_move(post_dist, speed, accel, True)


    cmd_ECH_SYNC_EXTRUDER_MOTION_help = "Set extruder stepper motion queue"
    def cmd_ECH_SYNC_EXTRUDER_MOTION(self, gcmd):
        ename = gcmd.get('MOTION_QUEUE')
        self.sync_to_extruder(ename)
        gcmd.respond_info("ECHELON_STEP '%s' now syncing with '%s'"
                          % (self.name, ename))

    def sync_to_extruder(self, extruder_name):
        toolhead = self.printer.lookup_object('toolhead')
        toolhead.flush_step_generation()
        if not extruder_name:
            self.rail.set_trapq(None)
            self.motion_queue = None
            return
        extruder_obj = self.printer.lookup_object(extruder_name, None)
        logging.info(f"self.steppers = {self.steppers[0]}")
        if extruder_obj is None or not isinstance(extruder_obj, extruder.PrinterExtruder):
            raise self.printer.command_error("'%s' is not a valid extruder."
                                             % (extruder_name,))

        self.rail.set_position([extruder_obj.last_position, 0., 0.])
        self.rail.set_trapq(extruder_obj.get_trapq())

        self.motion_queue = extruder_name


    def save_to_json(self, data, filename):
        with open(filename, 'w') as json_file:
            json.dump(data, json_file, indent=4)

    # Toolhead wrappers to support homing
    def flush_step_generation(self):
        toolhead = self.printer.lookup_object('toolhead')
        toolhead.flush_step_generation()
    def get_position(self):
        return [self.rail.get_commanded_position(), 0., 0., 0.]
    def set_position(self, newpos, homing_axes=()):
        self.do_set_position(newpos[0])
    def get_last_move_time(self):
        self.sync_print_time()
        return self.next_cmd_time
    def dwell(self, delay):
        self.next_cmd_time += max(0., delay)
    def drip_move(self, newpos, speed, drip_completion):
        self.do_move(newpos[0], speed, self.homing_accel, True, drip_completion)
    def get_kinematics(self):
        return self
    def get_steppers(self):
        return self.steppers
    def calc_position(self, stepper_positions):
        return [stepper_positions[self.rail.get_name()], 0., 0.]
    
    # def get_status(self, eventtime):
    #     return {
    #         'query_endstop': self._query_endstop()
    #     }

def load_config_prefix(config):
    return EchelonStepper(config)
