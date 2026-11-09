# Dev box: a WonderMaker Klipper with no printer

> **For testing only.** Do not switch dev mode on for the Pi that runs your printer (`devbox.py on` refuses when it sees the printer's USB bridge or an up `can0`; `--force` overrides). The normal project: [README.md](README.md).

## What it is

A Raspberry Pi with **no printer, no main board, no toolheads and no sensors** that still runs **WonderMaker's real Klipper, the real config and the real macros**. Klipper is started with *fake MCUs* (Klipper's own file-output mode): every board accepts every command, so the whole configuration loads and "Printer is ready" appears. A small simulator (`devbox_sim`) adds what the fake boards cannot:

| Simulated | How |
|---|---|
| Temperatures | Nozzles, bed and chamber warm up to the target and cool down to room temperature. Fluidd shows live curves. |
| Tool changer | `T0`..`T3`, `PARK_CURRENT_TOOL`, `LOAD_FILAMENT`, `UNLOAD_FILAMENT` run the real macros. The lock, the hall sensor, the lock sensor and the four dock sensors answer like a real changer. |
| Filament sensors | Always "filament present" (change with `DEVBOX_FILAMENT`). |
| Time | The fake boards' clock runs 50 times faster, so `M400` and `G4` after long moves do not take minutes. |

You can use it to try a new macro, a new Fluidd panel, a slicer plugin, KlipperScreen pages, a G-code file's start and end macros, or an update of WonderMaker's software, without a printer and without risk.

### What it can NOT do

- **No real motion.** Axes "move" instantly; positions are not checked against real endstops. `GET_TOOL_POSITION` (it reads stepper counters) gives nonsense and can leave the toolhead "out of range": run `G28` or switch dev mode off and on.
- **Probing and bed mesh give flat numbers** (`z=-5.0` everywhere). The load cell is not simulated.
- **Offset calibration does not finish** (`CALIBRATE_TOOL_OFFSET`, `TOOL_LOCATE_SENSOR`, `CALIBRATE_OFFSET_*`): they wait for a physical contact. Klipper has to be restarted if you start one.
- **`M109`, `M190`, `M191` return at once.** Klipper never waits for temperatures when it has no real MCU. The curves still move; a macro just does not stop to wait for them. To make up for that, the minimum extrusion temperature is set to 0 in dev mode.
- **The CELL board has no firmware in this repository**, so it uses the toolhead board's description. It is fine for loading the config; do not trust it for anything about the load cell.
- **Tool changes are logic only.** The macro sequence, the checks and the saved variables are tested; the mechanics are not.
- The ACE Pro is not part of this.

If a test passes here it means "the macros and settings run"; it does not mean "it works on the printer".

## What you need

- A Raspberry Pi 4 or 5 (64-bit), a power supply, an SD card of 16 GB or more, and a network cable or Wi-Fi.
- **No other parts.** No USB cable to a main board, no camera, no screen (a KlipperScreen display is optional). The Pi never talks to a printer.

## Install on a new SD card

1. **Write the SD card** with Raspberry Pi Imager: *Raspberry Pi OS (Legacy, 64-bit) Lite* (Debian 12 "Bookworm"). In the Imager's settings use the user name **`t13dp`**, switch SSH on and enter your Wi-Fi if you need it. (The WonderMaker files expect that user name and the home folder `/home/t13dp`.)
2. **Log in over SSH** and get the project:

   ```bash
   sudo apt-get update && sudo apt-get install -y git
   git clone https://github.com/ducati1198/wm-ultra-rpi.git
   cd wm-ultra-rpi
   chmod +x installer.sh
   ```
3. **Install the WonderMaker software from the factory files inside the repository**, and do not start the printer side yet:

   ```bash
   ./installer.sh --install --from-github --model ultra-s --no-start
   ```

   Use `--model ultra` for a ZR Ultra. It builds software (Python 3.9, Klipper, Moonraker, Fluidd), so let it finish; it takes a while. Answer the questions it asks.
4. **Do not run `./installer.sh --first-start`.** That step checks for a real main board and would stop. The dev box replaces it:

   ```bash
   python3 tools/devbox/devbox.py on
   ```

   Type `DEVBOX` when asked. Klipper restarts with the fake boards (sudo may ask for the password of `t13dp`; it is never stored). When it says **Dev mode is ON**, open `http://<pi address>/` in a browser. Fluidd shows a ready printer.
5. **Check that everything works:**

   ```bash
   python3 tools/devbox/devbox.py smoke
   ```

   It runs 33 commands (homing, heating, fans, the four tool changes, filament, probing, bed mesh, nozzle preparation, a short print start / pause / resume / end) and prints `ok` or `FAIL` for each. A good run ends with `0 failed`. It takes about two minutes.

## Use

```bash
python3 tools/devbox/devbox.py status          # dev mode on or off, Klipper ready, simulated temperatures
python3 tools/devbox/devbox.py gcode "T2" "M104 S200"      # send G-code to Klipper
python3 tools/devbox/devbox.py on --speed 5    # heat 5 times faster (default 2)
python3 tools/devbox/devbox.py off             # back to the normal config (restarts Klipper)
```

Or use Fluidd's console as always. Extra commands in dev mode:

| Command | What it does |
|---|---|
| `DEVBOX_STATUS` | all simulated temperatures and filament sensors |
| `DEVBOX_AMBIENT T=30` | change the room temperature |
| `DEVBOX_FILAMENT SENSOR=sensor_b PRESENT=0` | take filament away from a sensor (to see the macros' error handling) |
| `DEVBOX_HALL LOCK=0` | force the tool changer state (unlocked) |

Start a print by uploading a G-code file in Fluidd and pressing **Print**: the start and end macros, pause and resume run. The print itself is "instant".

### Good to know

- **Your real config is never changed.** Dev mode copies `~/printer_data/config` to `~/printer_data/devbox/config` and runs Klipper on the copy. `SAVE_CONFIG`, the bed mesh and the tool-change variables go to the copy. `devbox.py off` deletes the copy. Edit macros in the real folder (or in Fluidd), then `off` and `on` again to pick the change up.
- **Switching on or off restarts Klipper.** It refuses while a print is running.
- **A macro that never finishes** blocks Klipper's command queue (for example `CALIBRATE_TOOL_OFFSET`). `sudo systemctl restart klipper` frees it. `devbox.py smoke` does this by itself.
- **After `off`** Fluidd shows `ZRU-B001: Screen–Mainboard communication error`: that is the real config looking for a printer that is not there. Normal.
- Everything dev mode adds sits in `tools/devbox/` and `~/printer_data/devbox/`. The installers never switch it on. While it is on, `./installer.sh --doctor`, `--cfg-merge` and `--pid-cfg` print a notice, because Klipper then runs on a private copy of the config: a PID result or a bed mesh saved in dev mode goes to that copy, not to your real `printer.cfg`.

## What is in the folder

| File | What |
|---|---|
| `tools/devbox/devbox.py` | the command (`on`, `off`, `status`, `smoke`, `gcode`, `dicts`); standard library only |
| `tools/devbox/devbox_sim.py` | the Klipper module with the temperature and tool changer simulation |
| `tests/test_devbox.py` | unit tests (run by `bash tests/run_tests.sh`) |

How the fake boards work: Klipper starts with `-o <file>` (write the MCU traffic to files instead of a serial port) and one `-d <dictionary>` per board. The dictionaries (the lists of commands each board's firmware understands) are taken out of the firmware files already in this repository (`factory/<model>/mcu/*.bin`), so they always match WonderMaker's software.
