import logging, time, collections, multiprocessing, os
from . import bus, bulk_sensor


class FM17550Command:
    def __init__(self, config, chip):
        self.chip = chip
        self.config = config
        self.printer = config.get_printer()
        name_parts = config.get_name().split()
        self.base_name = name_parts[0]
        self.name = name_parts[-1]
        self.register_commands(self.name)
        if len(name_parts) == 1:
            if self.name == "fm17550" or not config.has_section("fm17550"):
                self.register_commands(None)

    def register_commands(self, name):
        gcode = self.printer.lookup_object('gcode')
        gcode.register_mux_command("CARD_ACTIVATE_START", "CHIP", name, self.cmd_card_activate_start, desc="start")
        gcode.register_mux_command("CARD_ACTIVATE_STOP", "CHIP", name, self.cmd_card_activate_stop, desc="stop")
        gcode.register_mux_command("READ_ALL_REGS", "CHIP", name, self.cmd_read_regs, desc="fm17550 read all regs")
        gcode.register_mux_command("READ_FIFO", "CHIP", name, self.cmd_read_fifo, desc="fm17550 read fifo")
        gcode.register_mux_command("RFID_INIT", "CHIP", name, self.cmd_init, desc="fm17550 init")
        gcode.register_mux_command("READ_CARD", "CHIP", name, self.cmd_read_card, desc="read card")
        gcode.register_mux_command("WRITE_CARD", "CHIP", name, self.cmd_write_card, desc="write card")

    def cmd_card_activate_start(self, gcmd):
        self.chip.start()
        gcmd.respond_info("fm17550 start !!!")

    def cmd_card_activate_stop(self, gcmd):
        self.chip.stop()
        gcmd.respond_info("fm17550 stop !!!")

    def cmd_read_regs(self, gcmd):
        cb = self.chip.fm17550_read_regs.send([self.chip.oid])
        reg_data = cb['data']
        gcmd.respond_info(f"reg_data: {reg_data}")
        for i in range(0, 31):
            gcmd.respond_info(f"reg_data[{i}]: {reg_data[i]}")

    def cmd_read_fifo(self, gcmd):
        cb = self.chip.fm17550_read_fifo.send([self.chip.oid])
        fifo_data = cb['data']
        gcmd.respond_info(f"fifo_data: {fifo_data}")
        for i in range(0, 16):
            gcmd.respond_info(f"fifo_data[{i}]: {fifo_data[i]}")

    def cmd_init(self, gcmd):
        self.chip.fm17550_init.send([self.chip.oid])
        gcmd.respond_info("fm17550 init")

    def cmd_read_card(self, gcmd):
        cb = self.chip.fm17550_read_card.send([self.chip.oid])
        status = cb['status']
        data = cb['data']
        if status == 2:
            gcmd.respond_info("card not found")
            return
        gcmd.respond_info(f"status: {status}")
        gcmd.respond_info(f"data: {data}")

    def cmd_write_card(self, gcmd):
        cb = self.chip.fm17550_write_card.send([self.chip.oid])
        status = cb['status']
        gcmd.respond_info(f"status: {status}")




# Printer class that controls FM17550 chip
class FM17550:  
    def __init__(self, config):
        self.printer = config.get_printer()
        FM17550Command(config, self)
        self.spi = bus.MCU_SPI_from_config(config, 0, default_speed=5000000)
        self.mcu = self.spi.get_mcu()
        self.oid = self.mcu.create_oid()
        self.fm17550_start_stop = None
        self.fm17550_read_regs = None
        self.fm17550_read_fifo = None
        self.fm17550_init = None
        self.fm17550_read_card = None
        self.mcu.add_config_cmd("query_fm17550 oid=%d rest_ticks=0" % (self.oid), on_restart=True)
        self.mcu.add_config_cmd("config_fm17550 oid=%d spi_oid=%d" % (self.oid, self.spi.get_oid()))   
        self.mcu.register_config_callback(self._build_config)

    def _build_config(self):
        cmdqueue = self.spi.get_command_queue()
        self.fm17550_start_stop = self.mcu.lookup_command("query_fm17550 oid=%c rest_ticks=%u", cq=cmdqueue)
        
        self.fm17550_read_regs = self.mcu.lookup_query_command(
            "fm17550_read_regs_cb oid=%c",
            "fm17550_read_regs_return oid=%c data=%*s",
            oid=self.oid, cq=cmdqueue)
        
        self.fm17550_read_fifo = self.mcu.lookup_query_command(
            "fm17550_read_fifo_cb oid=%c",
            "fm17550_read_fifo_return oid=%c data=%*s",
            oid=self.oid, cq=cmdqueue)
        
        self.fm17550_init = self.mcu.lookup_query_command(
            "fm17550_init_cb oid=%c",
            "fm17550_init_return oid=%c",
            oid=self.oid, cq=cmdqueue)
        
        self.fm17550_read_card = self.mcu.lookup_query_command(
            "fm17550_read_card_cb oid=%c",
            "fm17550_read_card_return oid=%c status=%c data=%*s",
            oid=self.oid, cq=cmdqueue)
        
        self.fm17550_write_card = self.mcu.lookup_query_command(
            "fm17550_write_card_cb oid=%c",
            "fm17550_write_card_return oid=%c status=%c",
            oid=self.oid, cq=cmdqueue)
    
    def start(self):
        rest_ticks = self.mcu.seconds_to_clock(10)
        self.fm17550_start_stop.send([self.oid, rest_ticks])

    def stop(self):
        self.fm17550_start_stop.send_wait_ack([self.oid, 0])

        


def load_config(config):
    return FM17550(config)

def load_config_prefix(config):
    return FM17550(config)
