# Dev box: simulated temperatures and filament sensors for a Klipper that has no MCU attached.
#
# Klipper "extra" module. devbox.py links it into klippy/extras and adds a [devbox_sim] section when dev mode is on.
# Without it, Klipper started with a fake MCU reads every temperature as 0 and every wait ("M109", "M190", "M191",
# TEMPERATURE_WAIT) never finishes. With it, heaters warm up toward their target and cool back down to room temperature,
# so Fluidd shows live curves and the WonderMaker macros run to the end.
#
# What is simulated:   heater temperatures (extruders, bed, chamber, any heater), temperature sensors and temperature fans
#                      (room temperature), filament sensors (filament present).
# What is NOT:         motion, endstops, probing, load cells, fans speed feedback, CAN. A fake MCU accepts every command.
import logging
import os

# degrees per second at speed 1.0 (a hotend heats much faster than a bed)
RATES = (("extruder", 4.0), ("bed", 1.5), ("chamber", 0.8))
DEFAULT_RATE = 2.0
WARP = 50.                  # the fake MCU clock runs this many times faster than real time (M400 and G4 must not take minutes)
TRIM_SECONDS = 30.          # the fake MCUs write every command into a file: empty those files now and then
SKIP_FILAMENT = ("docked", "sensor_b")     # "docked0" means the toolhead sits in its dock: not a filament sensor


class DevboxSim:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.ambient = config.getfloat("ambient", 25., minval=-20., maxval=60.)
        self.speed = config.getfloat("speed", 1., above=0.)
        self.cool_rate = config.getfloat("cool_rate", 0.5, above=0.)
        self.filament_present = config.getboolean("filament_present", True)
        self.interval = 0.5
        self.locked = None      # tool changer: is a toolhead held? (None = not decided yet)
        self.held = None        # which toolhead (0..3)
        self.pending = None     # toolhead the next LOCK will take
        self.in_dock = None     # toolhead that is back at its dock (still locked), about to be released
        self.applied = {}
        self.state = {}
        self.warned = set()
        self.last = None
        self.timer = None
        gcode = self.printer.lookup_object("gcode")
        gcode.register_command("DEVBOX_STATUS", self.cmd_status, desc="Show the dev box simulation: temperatures and sensors")
        gcode.register_command("DEVBOX_AMBIENT", self.cmd_ambient, desc="DEVBOX_AMBIENT T=<degrees>: set the room temperature")
        gcode.register_command("DEVBOX_FILAMENT", self.cmd_filament,
                               desc="DEVBOX_FILAMENT SENSOR=<name> PRESENT=<0|1>: set a filament sensor")
        gcode.register_command("DEVBOX_HALL", self.cmd_hall,
                               desc="DEVBOX_HALL [TOOL=<0-3>] [DOCK=<0-3>] [LOCK=<0|1>]: simulate the tool changer lock and its sensors")
        self.printer.register_event_handler("klippy:ready", self._handle_ready)
        # run first: on this firmware an earlier "ready" handler can end the chain, and then nothing below would start
        hs = self.printer.event_handlers.get("klippy:ready")
        if hs and hs[-1] == self._handle_ready:
            hs.insert(0, hs.pop())

    # ---- objects to drive -------------------------------------------------------------------------------------
    def _things(self):
        """(name, object, is_heater) for everything that takes temperature readings"""
        out, seen = [], set()
        try:
            heaters = self.printer.lookup_object("heaters").heaters
        except Exception:
            heaters = {}
        for name, h in heaters.items():
            if id(h) not in seen and hasattr(h, "temperature_callback"):
                seen.add(id(h))
                out.append((name, h, True))
        for name, obj in self.printer.lookup_objects():
            if id(obj) in seen or not hasattr(obj, "temperature_callback"):
                continue
            seen.add(id(obj))
            out.append((name, obj, False))
        return out

    def _rate(self, name):
        for key, rate in RATES:
            if key in name:
                return rate * self.speed
        return DEFAULT_RATE * self.speed

    @staticmethod
    def _factor(name, h):
        """WonderMaker's heater multiplies readings by a calibration factor (and 1.18 for a heating chamber)"""
        try:
            if getattr(h, "short_name", "") == "chamber" and h.target_temp > h.last_temp:
                return 1.18
            return float(getattr(h, "calibration_factor", 1.) or 1.)
        except Exception:
            return 1.

    # ---- simulation --------------------------------------------------------------------------------------------
    def _handle_ready(self):
        self.last = self.reactor.monotonic()
        self.timer = self.reactor.register_timer(self._tick, self.reactor.NOW)
        self.reactor.register_timer(self._trim, self.reactor.monotonic() + TRIM_SECONDS)
        if self.filament_present:
            for name, obj in self.printer.lookup_objects():
                if name.startswith("filament_switch_sensor") and not any(s in name for s in SKIP_FILAMENT):
                    self._set_filament(obj, True)
        self._init_changer()
        self._warp_clocks()
        logging.info("devbox_sim: running, room %.0f C, speed x%.1f", self.ambient, self.speed)

    def _tick(self, eventtime):
        dt = max(0., min(eventtime - (self.last or eventtime), 2.))
        self.last = eventtime
        pt = eventtime      # a steadily rising clock: the fake MCU's own print time does not advance
        for name, obj, is_heater in self._things():
            t = self.state.get(name, self.ambient)
            if is_heater:
                target = float(getattr(obj, "target_temp", 0.) or 0.)
                if target > t:
                    t = min(target, t + self._rate(name) * dt)
                elif target > 0.:
                    t = max(target, t - self.cool_rate * dt)
                else:
                    t = max(self.ambient, t - self.cool_rate * dt)
            else:
                t += (self.ambient - t) * min(1., dt)
            self.state[name] = t
            raw = t / (self._factor(name, obj) if is_heater else 1.)
            try:
                obj.temperature_callback(pt, raw)
            except Exception:
                if name not in self.warned:
                    self.warned.add(name)
                    logging.exception("devbox_sim: could not feed %s", name)
        self._apply_changer()
        return eventtime + self.interval

    def _warp_clocks(self):
        """A fake MCU never says that time passes, so every wait for the toolhead to finish ("M400") would last forever.
        Give each MCU a clock that runs fast instead."""
        t0 = self.reactor.monotonic()
        for name, obj in self.printer.lookup_objects():
            if name == "mcu" or name.startswith("mcu "):
                try:
                    obj.estimated_print_time = lambda eventtime, t0=t0: (eventtime - t0) * WARP
                except Exception:
                    logging.exception("devbox_sim: could not speed up the clock of %s", name)

    # ---- tool changer: hall sensor, lock sensor and the four dock sensors --------------------------------------
    def _init_changer(self):
        cur = 99
        try:
            cur = int(self.printer.lookup_object("save_variables").allVariables.get("current_extruder", 99))
        except Exception:
            pass
        self.locked = 0 <= cur <= 3
        self.held = cur if self.locked else None

    def _apply_changer(self):
        if self.locked is None:
            return
        hall = self.printer.lookup_object("custom_hall", None)
        if hall is not None:
            hall.last_adc_value_raw = 4000 if self.locked else 5200      # below 4700 = a toolhead is gripped
            if hasattr(hall, "last_adc_value"):
                hall.last_adc_value = hall.last_adc_value_raw
        want = {"filament_switch_sensor sensor_b": self.locked}
        for i in range(4):
            want["filament_switch_sensor docked%d" % i] = not (self.locked and self.held == i and self.in_dock != i)
        for name, present in want.items():
            if self.applied.get(name) == present:
                continue
            obj = self.printer.lookup_object(name, None)
            if obj is not None and self._set_filament(obj, present):
                self.applied[name] = present

    def cmd_hall(self, gcmd):
        if self.locked is None:
            self._init_changer()
        tool = gcmd.get_int("TOOL", None)
        if tool is not None:
            self.pending = tool if 0 <= tool <= 3 else None
        dock = gcmd.get_int("DOCK", None)
        if dock is not None:
            self.in_dock = dock
        lock = gcmd.get_int("LOCK", None)
        if lock is not None:
            self.in_dock = None
            self.locked = bool(lock)
            self.held = self.pending if self.locked else None
            if self.locked and self.held is None:
                self.held = 0
        self._apply_changer()
        gcmd.respond_info("devbox_sim: changer %s%s" % ("locked" if self.locked else "unlocked",
                                                         " on tool %d" % self.held if self.held is not None else ""))

    def _trim(self, eventtime):
        """keep the fake-MCU output files small (Klipper writes every command it would send to a real MCU)"""
        for name, obj in self.printer.lookup_objects():
            if name != "mcu" and not name.startswith("mcu "):
                continue
            try:
                fd = obj._serial.serial_dev.fileno()
                os.ftruncate(fd, 0)
                os.lseek(fd, 0, os.SEEK_SET)
            except Exception:
                pass
        return eventtime + TRIM_SECONDS

    def _set_filament(self, obj, present):
        helper = getattr(obj, "runout_helper", None)
        if helper is None:
            return False
        now = self.reactor.monotonic()
        for call in (lambda: helper.note_filament_present(now, present), lambda: helper.note_filament_present(present)):
            try:
                call()
                return True
            except TypeError:
                continue
            except Exception:
                return False
        return False

    # ---- commands ----------------------------------------------------------------------------------------------
    def cmd_status(self, gcmd):
        lines = ["devbox_sim: room %.1f C, speed x%.1f, cool %.2f C/s" % (self.ambient, self.speed, self.cool_rate)]
        for name, obj, is_heater in self._things():
            target = getattr(obj, "target_temp", 0.) if is_heater else None
            lines.append("  %-28s %6.1f C%s" % (name, self.state.get(name, self.ambient),
                                                "   target %.0f" % target if target else ""))
        sensors = [n for n, _ in self.printer.lookup_objects() if n.startswith("filament_switch_sensor")]
        for n in sensors:
            h = getattr(self.printer.lookup_object(n), "runout_helper", None)
            lines.append("  %-28s filament %s" % (n.split(" ", 1)[1], "present" if getattr(h, "filament_present", False) else "none"))
        gcmd.respond_info("\n".join(lines))

    def cmd_ambient(self, gcmd):
        self.ambient = gcmd.get_float("T", self.ambient, minval=-20., maxval=60.)
        gcmd.respond_info("devbox_sim: room temperature %.1f C" % self.ambient)

    def cmd_filament(self, gcmd):
        want = gcmd.get("SENSOR")
        present = bool(gcmd.get_int("PRESENT", 1))
        hit = 0
        for name, obj in self.printer.lookup_objects():
            if name.startswith("filament_switch_sensor") and name.split(" ", 1)[1] == want:
                hit += self._set_filament(obj, present)
        if not hit:
            raise gcmd.error("devbox_sim: no filament sensor named %s" % want)
        gcmd.respond_info("devbox_sim: %s filament %s" % (want, "present" if present else "removed"))


def load_config(config):
    return DevboxSim(config)
