import time
import json
import os

from . import bus

import logging

      

class FeedSlotHelper:
    def __init__(self, config):
        self.name = config.get_name().split()[-1]
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.gcode = self.printer.lookup_object('gcode')

        self.fila_info_file_path = '/home/t13dp/.' + self.name 

        logging.info(f"fila info file path: {self.fila_info_file_path}")

        self.event_delay = 3.
        #self.slot_stepper = stepper

        #self.rfid_reader = RFIDHelper(config)

        # speed accel
        self.velocity = config.getfloat('velocity', 5., above=0.)
        self.accel = config.getfloat('accel', 0., minval=0.)

        self.is_pending = False

        self.first_run = True #模块第一次加载的时候，防止插着材料上电误判

        
        self.invert_feed_dir = config.getboolean('invert_feed_dir', False)

        self.trans_dist = config.getfloat('trans_dist', 0.)
        

        # Internal state
        self.min_event_systime = self.reactor.NEVER
        self.last_state = None        
        self.button_state = 0

        self.state = 'EMPTY'

        self.info_manufacturer = 0

        self.info_color = None
        self.info_material = None
        self.info_temp = None

        self.printer.register_event_handler("klippy:ready", self._handle_ready)
        

        self.read_json_file(self.fila_info_file_path)

        self.gcode.respond_info(f"Init slot state: {self.state}")


        self.gcode.register_mux_command('CONFIG_SLOT_COLOR', "SLOT", 
                                    self.name, self.cmd_CONFIG_SLOT_COLOR)
        self.gcode.register_mux_command('CONFIG_SLOT_MATERIAL', "SLOT", 
                                    self.name, self.cmd_CONFIG_SLOT_MATERIAL)
        self.gcode.register_mux_command('READ_SLOT_STATE', "SLOT", 
                                    self.name, self.cmd_READ_SLOT_STATE)

    def _handle_ready(self):
        self.min_event_systime = self.reactor.monotonic() + 2.

    

    def _note_slot_state(self, slot_detect_state, slot_obj):
        
        color_feeder = self.printer.lookup_object("color_feeder")
        _is_feeding = color_feeder._is_feeding        

        #需要按键状态变化才触发 
        if self.first_run: 
            self.first_run = False      
            if slot_detect_state == self.last_state or self.last_state == None:
                logging.info(f"last_state is also {self.last_state}")
                return
            
        self.last_state = slot_detect_state
        
        self.is_pending = True #默认先排队，看下面的状态是否能通过再取消排队

        logging.info(f"_is_feeding ====== {_is_feeding}")
        if color_feeder._is_feeding is True:
            return
        
        eventtime = self.reactor.monotonic()

        idle_timeout = self.printer.lookup_object("idle_timeout")
        is_printing = idle_timeout.get_status(eventtime)["state"] == "Printing"
        

        # 在这里做一下打印头是否有耗材
        logging.info(f"eventtime:{eventtime}, min_event_systime:{self.min_event_systime}")

        # 正在打印，需要退出
        if eventtime < self.min_event_systime or is_printing:
            return
        
        

        toolhead = self.printer.lookup_object('toolhead')

        if slot_detect_state:
            color_feeder._is_feeding = True
                       
            toolhead.dwell(1.5)
            
            self.gcode.respond_info(f"Slot state: {self.state}")
            self.min_event_systime = self.reactor.NEVER
            logging.info(f"{self.name} detected, Time {eventtime}")
            # self.slot_stepper.do_set_position(0.)
            # self.slot_stepper.do_move(40)

            if color_feeder.detect_helper._current_feed_state == "detected":
                # 如果不清楚当前在四进一出的是哪个slot，就所有slot都做一遍退料
                if color_feeder._current_feed == None:
                    logging.warn(f"color_feeder._current_feed is None, would retract all the 4 slots!")
                    script = "cut_filament\nBOX_OUT_FILAMENT SLOT=slot0\nBOX_OUT_FILAMENT SLOT=slot1\nBOX_OUT_FILAMENT SLOT=slot2\nBOX_OUT_FILAMENT SLOT=slot3\n"      
                    # 换挡到要进料的耗材
                    script = script + "\nECHELON_SP STEPPER=trans_stepper" #设置当前为0点
                    script = script + "\nECHELON_STEPPER_HOMING STEPPER=trans_stepper MOVE=" + str(color_feeder.trans_max_dist) #回零换挡电机
                    script = script + "\nECHELON_STEPPER STEPPER=trans_stepper MOVE=" + str(slot_obj.trans_dist)  #移动换挡电机到对应料槽
                    # 再进料新的耗材
                    #script = script + "\nECHELON_INVERT STEPPER=feed_stepper"
                    script = script + "\nECHELON_SP STEPPER=feed_stepper"
                    if self.invert_feed_dir:
                        script = script + "\nECHELON_STEPPER_HOMING STEPPER=feed_stepper MOVE=-" + str(color_feeder.feed_max_dist) + " PDI=" + str(color_feeder.retract_dist) + "\n"
                    else:
                        script = script + "\nECHELON_STEPPER_HOMING STEPPER=feed_stepper MOVE=" + str(color_feeder.feed_max_dist) + " PDI=-"  + str(color_feeder.retract_dist) + "\n"  
                        

                    self.gcode.run_script(script)     
                    color_feeder._current_feed = self.name        
                else:
                    logging.info(f"there is marterial in the 4 in 1 endstop: {color_feeder._current_feed}")
                    # 如果当前占用的料槽是要进料的料槽
                    if color_feeder._current_feed == self.name:      
                        logging.info("it is the same slot")        
                        # 先换挡
                        script = "ECHELON_SP STEPPER=trans_stepper" #设置当前为0点
                        script = script + "\nECHELON_STEPPER_HOMING STEPPER=trans_stepper MOVE=500" #回零换挡电机
                        script = script + "\nECHELON_STEPPER STEPPER=trans_stepper MOVE=" + str(slot_obj.trans_dist) #移动换挡电机到对应料槽
                        # 再进料
                        script = script + "\nECHELON_SP STEPPER=feed_stepper"
                        script = script + "\nG4 P1000\n"
                        if self.invert_feed_dir:
                            script = script + "\nECHELON_STEPPER_HOMING STEPPER=feed_stepper MOVE=-" + str(color_feeder.feed_max_dist) + " PDI=" + str(color_feeder.retract_dist) + "\n"
                        else:
                            script = script + "\nECHELON_STEPPER_HOMING STEPPER=feed_stepper MOVE=" + str(color_feeder.feed_max_dist) + " PDI=-"  + str(color_feeder.retract_dist) + "\n"  
                        self.gcode.run_script(script)
                    
                    # 如果当前占用的料槽不是要进料的料槽
                    else:
                        logging.info("it is the different slot")       
                        cur_object = 'feed_slot ' + color_feeder._current_feed
                        logging.info(f"cur_object is {cur_object}")
                        cur_slot_obj = self.printer.lookup_object(cur_object)
                        # 先换挡到当前占用四进一出的耗材
                        script = "ECHELON_SP STEPPER=trans_stepper" #设置当前为0点
                        script = script + "\nECHELON_STEPPER_HOMING STEPPER=trans_stepper MOVE=" + str(color_feeder.trans_max_dist) #回零换挡电机
                        script = script + "\nECHELON_STEPPER STEPPER=trans_stepper MOVE=" + str(cur_slot_obj.trans_dist) #移动换挡电机到对应料槽
                        # 然后退料
                        script = script + "\ncut_filament\nBOX_OUT_FILAMENT SLOT=" + color_feeder._current_feed
                        # script = script + "\nECHELON_INVERT STEPPER=feed_stepper"
                        # script = script + "\nECHELON_SP STEPPER=feed_stepper"
                        # if cur_slot_obj.slot_helper.invert_feed_dir:
                        #     script = script + "\nECHELON_STEPPER_HOMING STEPPER=feed_stepper MOVE=" + str(color_feeder.feed_max_dist) + " PDI=" + str(color_feeder.retract_dist) + "\n"
                        # else:
                        #     script = script + "\nECHELON_STEPPER_HOMING STEPPER=feed_stepper MOVE=-" + str(color_feeder.feed_max_dist) + " PDI=-"  + str(color_feeder.retract_dist) + "\n"  
                        
                        # 换挡到要进料的耗材
                        script = script + "\nECHELON_SP STEPPER=trans_stepper" #设置当前为0点
                        script = script + "\nECHELON_STEPPER_HOMING STEPPER=trans_stepper MOVE=" + str(color_feeder.trans_max_dist) #回零换挡电机
                        script = script + "\nECHELON_STEPPER STEPPER=trans_stepper MOVE=" + str(slot_obj.trans_dist)  #移动换挡电机到对应料槽
                        # 再进料新的耗材
                        #script = script + "\nECHELON_INVERT STEPPER=feed_stepper"
                        script = script + "\nECHELON_SP STEPPER=feed_stepper"
                        if self.invert_feed_dir:
                            script = script + "\nECHELON_STEPPER_HOMING STEPPER=feed_stepper MOVE=-" + str(color_feeder.feed_max_dist) + " PDI=" + str(color_feeder.retract_dist) + "\n"
                        else:
                            script = script + "\nECHELON_STEPPER_HOMING STEPPER=feed_stepper MOVE=" + str(color_feeder.feed_max_dist) + " PDI=-"  + str(color_feeder.retract_dist) + "\n"  
                        
                        # 非打印状态下，去到排料口
                        print_stats = self.printer.lookup_object("print_stats")
                        is_printing = print_stats.get_status(eventtime)["state"] == "printing"
                        if is_printing == False:
                            toolhead = self.printer.lookup_object('toolhead')
                            curtime = self.printer.get_reactor().monotonic()
                            if 'xy' not in toolhead.get_status(curtime)['homed_axes']:
                                script = script + "\nG28 X Y"
                            script = script + "\nG0 X277.5 F6000"
                            script = script + "\nG0 Y321 F6000"
                        self.gcode.run_script(script)
                        color_feeder._current_feed = self.name
            # 如果当前四进一出限位没有检测到耗材
            else:
                logging.info("no material in the 4 in 1 endstop")       
                # 先换挡
                script = "ECHELON_SP STEPPER=trans_stepper" #设置当前为0点
                script = script + "\nECHELON_STEPPER_HOMING STEPPER=trans_stepper MOVE=" + str(color_feeder.trans_max_dist) #回零换挡电机
                script = script + "\nECHELON_STEPPER STEPPER=trans_stepper MOVE=" + str(slot_obj.trans_dist) + "\n"  #移动换挡电机到对应料槽
                # 再进料
                script = script + "\nECHELON_SP STEPPER=feed_stepper"
                if self.invert_feed_dir:
                    script = script + "\nECHELON_STEPPER_HOMING STEPPER=feed_stepper MOVE=-" + str(color_feeder.feed_max_dist) + " PDI=" + str(color_feeder.retract_dist) + "\n"
                else:
                    script = script + "\nECHELON_STEPPER_HOMING STEPPER=feed_stepper MOVE=" + str(color_feeder.feed_max_dist) + " PDI=-"  + str(color_feeder.retract_dist) + "\n"  
              
                self.gcode.run_script(script)
                color_feeder._current_feed = self.name

            script = "ECHELON_SP STEPPER=trans_stepper"
            script = script + "\nECHELON_STEPPER_HOMING STEPPER=trans_stepper MOVE=" + str(color_feeder.trans_max_dist) + " PDI=5.5" 
            script = script + "\nECHELON_STEPPER_DISABLE STEPPER=feed_stepper"
            # 非打印状态下，去到排料口
            print_stats = self.printer.lookup_object("print_stats")
            is_printing = print_stats.get_status(eventtime)["state"] == "printing"
            if is_printing == False:
                toolhead = self.printer.lookup_object('toolhead')
                curtime = self.printer.get_reactor().monotonic()
                if 'xy' not in toolhead.get_status(curtime)['homed_axes']:
                    script = script + "\nG28 X Y"
                script = script + "\nG0 X277.5 F6000"
                script = script + "\nG0 Y321 F6000"
            self.gcode.run_script(script)

            self.state = "Loaded"
            self.gcode.respond_info(f"Slot state: {self.state}")

            logging.info(f"Now color_feeder._current_feed is: {color_feeder._current_feed}")

            self.min_event_systime = self.reactor.monotonic() + self.event_delay            
        
            self.is_pending = False
            color_feeder._is_feeding = False
            

        else:
            self.state = "EMPTY"
            self.gcode.respond_info(f"Slot state: {self.state}")

      

    def read_json_file(self, file_path):
        if not os.path.exists(file_path):
            return None  #
        
        try:
            with open(file_path, 'r') as file:
                data = json.load(file)
        except (json.JSONDecodeError, IOError) as e:
            logging.warning(f"Failed to read JSON file {file_path}: {str(e)}")
            return None
        
        # 更新实例变量
        self.info_color = data.get("color")
        self.info_material = data.get("material")
        self.info_temp = data.get("temperature")
        
        # 直接返回数据字典，避免重复 .get() 调用
        return {
            "color": self.info_color,
            "material": self.info_material,
            "temperature": self.info_temp
        }

    def write_json_file(self, file_path, color=None, material=None, temperature=None):
        """Write color, material, and temperature data to a JSON file.
        
        Args:
            file_path (str): Path to the JSON file
            color: Color value to update (None means no update)
            material: Material value to update (None means no update)
            temperature: Temperature value to update (None means no update)
        """
        # Prepare new data (only include non-None values)
        new_data = {
            k: v for k, v in [
                ("color", color),
                ("material", material),
                ("temperature", temperature)
            ] if v is not None
        }
        
        # Try to read existing data if file exists
        existing_data = {}
        if os.path.exists(file_path):
            try:
                with open(file_path, 'r') as file:
                    existing_data = json.load(file)
            except (json.JSONDecodeError, IOError) as e:
                logging.warning(f"Failed to read existing JSON file {file_path}: {str(e)}")
                # Continue with empty dict if reading fails
        
        # Merge data (new_data overwrites existing_data)
        merged_data = {**existing_data, **new_data}
        
        # Write to file
        try:
            with open(file_path, 'w') as file:
                json.dump(merged_data, file, indent=4)
                file.flush()  # Ensure Python buffer is flushed
                os.fsync(file.fileno())  # Ensure OS buffer is flushed to disk
            logging.info(f"Data successfully written to '{file_path}'")
        except IOError as e:
            logging.error(f"Failed to write to {file_path}: {str(e)}")
            raise  # Re-raise the exception or handle it as needed

    def get_status(self, eventtime):
        # if self.slot_stepper._query_endstop() == True:
        #     self.state = "Busy"
        # else:
        #     if self.last_state == False:
        #         self.state = "EMPTY"
        return {
            "slot_name": self.name,
            "slot_detected": bool(self.button_state),
            "slot_state": self.state,
            # "last_state": self.slot_stepper.get_status
            "slot_color": self.info_color,
            "slot_material": self.info_material,
            "trans_dist": self.trans_dist,
            "invert_feed_dir": self.invert_feed_dir,
        }

    
    def cmd_CONFIG_SLOT_COLOR(self, gcmd):
        color = gcmd.get('COLOR')
        if not color:  # 简单的参数校验
            logging.error("No COLOR parameter provided")
            return
        
        slot_fila_info = self.read_json_file(self.fila_info_file_path)
        if not slot_fila_info:
            slot_fila_info = {"material": None, "temperature": None}  # 提供默认值

        self.info_color = color
        
        self.write_json_file(
            self.fila_info_file_path, 
            color, 
            slot_fila_info.get("material")  # 使用 .get() 避免 KeyError
        )
        logging.info(f"config {self.name} color: {color}")

    def cmd_CONFIG_SLOT_MATERIAL(self, gcmd):
        material = gcmd.get('MATERIAL')
        if not material:  # 简单的参数校验
            logging.error("No MATERIAL parameter provided")
            return
        
        slot_fila_info = self.read_json_file(self.fila_info_file_path)
        if not slot_fila_info:
            slot_fila_info = {"material": None, "temperature": None}  # 提供默认值

        self.info_material = material

        
        self.write_json_file(
            self.fila_info_file_path, 
            slot_fila_info.get("color"),  # 使用 .get() 避免 KeyError
            material            
        )
        
        logging.info(f"config {self.name} material: {material}")


    def cmd_READ_SLOT_STATE(self, gcmd):
        self.gcode.respond_info(f"Slot state: {self.button_state}")

class FeedSlot:
    def __init__(self, config):
        self.printer = printer = config.get_printer()

        self.name = config.get_name().split()[-1]

        self.reactor = printer.get_reactor()        

        self.invert = False
        
        self.last_eventtime = 0.0


        self.buttons = buttons = printer.load_object(config, 'buttons')
        switch_pin = config.get('switch_pin')
        mask = buttons.register_buttons_ret([switch_pin], self._button_handler)
        self.slot_helper = FeedSlotHelper(config)

        self.check_pendding_period = 5.0

        # 定时器检测是否有pending状态的装料
        self.check_pending_timer = self.reactor.register_timer(self._check_pending_loading)
        self.reactor.update_timer(self.check_pending_timer, self.reactor.NOW + 5.0)

        self.printer.register_event_handler("klippy:ready", self._handle_ready)

        ppins = self.printer.lookup_object('pins')
        self.chip_name = self._get_pin_chip_name(switch_pin)
        self.mcu = ppins.chips[self.chip_name]

        self.shift = self.find_bit_position(mask) - 1

        logging.info(f"{self.find_bit_position(mask)}\n {self.name}\033[0m")

        # 换挡距离
        self.trans_dist = config.getfloat('trans_dist', 0., minval=0.)

        self.get_status = self.slot_helper.get_status

        

    def _handle_ready(self):
        # logging.info(f"\033[93m  {self.name} {type(self.buttons.mcu_buttons)}\n{(self.buttons.mcu_buttons['mcu'])} \033[0m")
        if hasattr(self.buttons.mcu_buttons[self.chip_name], 'oid'):
            oid = self.buttons.mcu_buttons[self.chip_name].oid
            cmdqueue = self.mcu.alloc_command_queue()
            buttons_read_cmd = self.mcu.lookup_query_command(
                "buttons_read oid=%c pos=%u",
                "buttons_read_state oid=%c state=%u",
                oid=oid, cq=cmdqueue
            )
            params = buttons_read_cmd.send([oid, self.shift])
            logging.info(f"\033[93m  {(params['state'])} \033[0m")

            #注意这里的state是管脚的裸电平
            if params['state'] == 1:
                self.slot_helper.last_state = not self.invert
            else:
                self.slot_helper.last_state = self.invert

            logging.info(f"\033[93m last_state == {self.slot_helper.last_state} \033[0m")

    def _check_pending_loading(self, eventtime):
        try:
            #logging.info(f"_check_pending_loading....")
            if self.slot_helper.button_state == 0:
                    self.slot_helper.is_pending = False

            if self.slot_helper.is_pending:                
                logging.info(f"found {self.name} is pending")
                self.slot_helper._note_slot_state(1, self)

        except Exception:
            logging.exception("_check_pending_loading: Error")
            return self.reactor.NEVER

        check_time = self.reactor.monotonic()
        return check_time + self.check_pendding_period

    def _button_handler(self, eventtime, state):#注意这里的state已经在button库里面处理过invert逻辑，所以它是表征是否有效电平
        logging.info(f"_button_handler: {self.name}, state = {state}， last_event = {self.last_eventtime}, event_time = {eventtime}")
         # 消抖逻辑改进
        if self.last_eventtime != 0.0:
            diff = eventtime - self.last_eventtime
            # 只有当时间间隔过短且状态没有变化时才忽略
            if diff < 0.5 and state == self.last_state:
                logging.info(f"忽略可能的抖动事件: {diff}秒, 状态未变化")
                return
    
        # 更新最后事件时间和状态
        self.last_eventtime = eventtime
        self.last_state = state  
        self.slot_helper.button_state = state
        logging.info(f"_button_handler: {self.name}, state = {state}")
        if state:
            self.slot_helper._note_slot_state(state, self)
        

    def _get_pin_chip_name(self, pin_desc, can_invert=True, can_pullup=True):
        desc = pin_desc.strip()
        self.invert = False
        pullup = invert = 0
        if can_pullup and (desc.startswith('^') or desc.startswith('~')):
            pullup = 1
            if desc.startswith('~'):
                pullup = -1
            desc = desc[1:].strip()
        if can_invert and desc.startswith('!'):
            self.invert = True
            invert = 1
            desc = desc[1:].strip()
        if ':' not in desc:
            chip_name, pin = 'mcu', desc
        else:
            chip_name, pin = [s.strip() for s in desc.split(':', 1)]
        return chip_name

    def find_bit_position(self, n):
        return n.bit_length()
    
    

def load_config_prefix(config):
    return FeedSlot(config)