import logging
from collections import deque

class StallSensor:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.name = config.get_name().split(' ')[-1]
        self.pin = config.get('pin')
        self.last_state = 0
        # === press 时间窗口控制 ===
        self.press_times = deque()
        self.press_window = 0.5    # 秒
        self.press_count = 3
        buttons = self.printer.load_object(config, "buttons")
        buttons.register_buttons([self.pin], self.button_callback)
        gcode_macro = self.printer.load_object(config, 'gcode_macro')
        self.press_template = gcode_macro.load_template(config, 'press_gcode', '')
        self.release_template = gcode_macro.load_template(config, 'release_gcode', '')
        self.gcode = self.printer.lookup_object('gcode')
        self.gcode.register_mux_command("QUERY_STALL", "STALL", self.name,
                                        self.cmd_QUERY_STALL,
                                        desc=self.cmd_QUERY_STALL_help)

    cmd_QUERY_STALL_help = "Report on the state of a stall sensor"
    def cmd_QUERY_STALL(self, gcmd):
        gcmd.respond_info(self.name + ": " + self.get_status()['state'])

    def button_callback(self, eventtime, state):
        self.last_state = state
        template = self.press_template
        if not state:
            template = self.release_template
        try:
            if state:
                logging.info("触发！！！")
                # === 记录 press 时间 ===
                self.press_times.append(eventtime)
                # === 清理 0.5s 之前的 press ===
                cutoff = eventtime - self.press_window
                while self.press_times and self.press_times[0] < cutoff:
                    self.press_times.popleft()
                # === 未达到 3 次，不处理 ===
                if len(self.press_times) < self.press_count:
                    return
                # === 达到条件，清空队列，正式触发 ===
                self.press_times.clear()
                self.printer.command_error("STALL_SENSOR triggered")
                if self.name == "Z_STALL_SENSOR":
                    # raise shutdown
                    raise self.printer.invoke_shutdown("ZRU-C016: Platform lowering error. Restart and remove obstacles underneath.")
                elif self.name == "ET_STALL_SENSOR":
                    raise self.printer.invoke_shutdown("ET_STALL_SENSOR triggered!")
                else:
                    raise self.printer.invoke_shutdown("STALL_SENSOR triggered!")
            else:
                self.gcode.run_script(template.render())
        except:
            logging.exception("Script running error")

    def get_status(self, eventtime=None):
        if self.last_state:
            return {'state': "PRESSED"}
        return {'state': "RELEASED"}

def load_config_prefix(config):
    return StallSensor(config)
