# rpi-cfg: the Pi's own config files

Files in this folder are **not WonderMaker's**. They are made for the Raspberry Pi. The installer copies them into `~/printer_data/config` and adds an `[include ...]` line for each to `printer.cfg`. A WonderMaker update never changes them (`tools/wm-release/wm_release.py` knows these file names and leaves them alone).

| File | What it is |
|---|---|
| [`wm_calibration.cfg`](wm_calibration.cfg) | The calibration items of the WonderMaker screen app (General > Maintenance) as macros you start from Fluidd |
| [`wm_nozzle.cfg`](wm_nozzle.cfg) | The screen app's General > Nozzle Type and Extruder Setup pages as Fluidd window wizards (`WM_NOZZLE_TYPE`, `WM_EXTRUDER_SETUP`, `WM_EXTRUDER_MATCH`). Needs Klipper's gcode shell command extension, so the installer only adds it where that is installed |

## `wm_calibration.cfg`: macros

| Macro | Same as the app's | What it runs |
|---|---|---|
| `WM_BED_LEVELING` | Bed Leveling | `G28`, `G29` (heat bed 55 C and nozzle 140 C, wipe, 49 point mesh), heaters off, `SAVE_CONFIG` |
| `WM_PROBE_CALIBRATE` | PROBE_CALIBRATE | warms the bed (`BED=60`, max 100), then WonderMaker's `PROBE_CALIBRATE`; you adjust with `TESTZ Z=-0.1` and so on, run `ACCEPT`, then `WM_PROBE_DONE` |
| `WM_TOOL_OFFSETS MODE=rapid` or `MODE=accurate` | Extruder Offsets Calibration (Rapid / Accurate) | `CALIBRATE_OFFSET_ALL_RAPID_MODE` or `CALIBRATE_OFFSET_ALL_FINE_MODE`, then heaters off |
| `WM_VIBRATION_COMP` | Vibration Compensation | `G28`, `SHAPER_CALIBRATE` (the `lis2dw` accelerometer on the EX_T board), `SAVE_CONFIG` |
| `WM_BED_PID TARGET=60` | (no button in the app) | `PID_CALIBRATE HEATER=heater_bed` for the heated bed (40 to 110 C), `SAVE_CONFIG`. Needs `control: pid`, which the factory bed has |
| `WM_CHAMBER_PID TARGET=45` | (no button in the app) | `PID_CALIBRATE HEATER=chamber` for the ZR Ultra-S chamber heater (30 to 60 C), `SAVE_CONFIG`. Refuses on the Ultra (no chamber heater) |
| `WM_NOZZLE_TEMP_CAL T=0 TARGET=220` | Nozzle Temperature Calibration | `PID_CALIBRATE` for hotend T (fan full, tool head at X150 Y150), `SAVE_CONFIG`. Refuses when that heater uses `control: watermark`: PID tuning does nothing then (`./installer.sh --pid-cfg` gives every hotend `control: pid`) |
| `WM_FULL_CALIBRATION` | all calibrations in one go | opens a Fluidd window that explains what will run, how long it takes and what to check; Start Calibration then runs bed leveling, rapid tool offsets, vibration compensation, bed PID, hotend PID (only hotends with `control: pid`) and chamber PID (Ultra-S) with no more questions, and one Save and Restart window at the end. Z height is not included (it needs you at the printer); the end window points to `WM_PROBE_CALIBRATE` |
| `WM_CAL_STOP` | | heaters and fan off |
| `WM_CAL_HELP` | | lists the macros |
| `WM_ZOFFSET_UP` / `WM_ZOFFSET_DOWN` `STEP=0.025` | the Z-Offset + and - buttons | `SET_GCODE_OFFSET Z_ADJUST=...` (live only, not saved) |

Safety, in every macro: it refuses to start while a print runs or while any heater has a target above 0, it asks you to confirm in a Fluidd window (Start / Cancel), and it turns the heaters off at the end. `SAVE_CONFIG` restarts Klipper. Stay at the printer.

Not included on purpose: Feed & Discharge (it needs the nozzle removed and your hands on the printer). Nozzle Type and Extruder Setup are in `wm_nozzle.cfg`, below.

The macros call WonderMaker's own macros (`G29`, `PROBE_CALIBRATE`, `CALIBRATE_OFFSET_ALL_*`), so the factory `macros.cfg` and `offset_calibrate.cfg` must be installed too (they are, from `factory/<model>/config`).

**Where the commands come from:** the G-code sequences were read from the strings in the screen app (`TM_T1/bin/client`, System 1.1.13). The app's own progress names `CHECK_AUTO_LEVEL_*`, `CHECK_SHAPPER_*` and `CHECK_PID_*` are not G-code and are not used. The app also saves a `probe_position` value after PROBE_CALIBRATE; how it is calculated is not known, so `WM_PROBE_CALIBRATE` does only the Klipper side. **Not tested on a real printer.**

## Install and update

- The installer does it (step 4c) on every install and `--update`.
- Only this: `./installer.sh --rpi-cfg`
- `./installer.sh --doctor` checks that each file is there, included in `printer.cfg` and the same as this folder; Fix everything repairs it. An edited copy is kept as `<name>.wm-before-rpicfg-<time>` before it is replaced.
- `python3 tools/wm-release/wm_release.py status` shows the state of each file.

## Where the PID settings must live

Klipper's `SAVE_CONFIG` stores a PID result in `printer.cfg`. It **refuses** when an included file sets the same option (`control`, `pid_Kp`, `pid_Ki`, `pid_Kd`) for that heater, with the error `SAVE_CONFIG section ... option ... conflicts with included value`, and then nothing in that save is stored (bed mesh and input shaper included). WonderMaker's `zru-s.cfg` sets them for the chamber heater, so on the ZR Ultra-S they have to be moved into `printer.cfg`. Every hotend also needs `control: pid` (WonderMaker leaves it commented out in the `[extruder]` sections and relies on the saved block at the end of `printer.cfg`; a printer without that block has watermark hotends).

`scripts/wm_pidcfg.py check|fix CONFIG_DIR` does both. The installer runs it (step 4d, also `./installer.sh --pid-cfg`), the Doctor and Fix everything repair it, and `python3 tools/wm-release/wm_release.py pid-cfg [--fix]` does the same from the release tool. Every file it changes is first copied to `<file>.wm-before-pidcfg-<time>`; your values are kept.

## `wm_nozzle.cfg`: Nozzle Type and Extruder Setup

These macros open a window in Fluidd and take you through it step by step, like `WM_FULL_CALIBRATION`. They refuse to start during a print.

| Macro | Same as the app's | What it does |
|---|---|---|
| `WM_NOZZLE_TYPE` | General > Nozzle Type | Pick the nozzle (1 to 4), its material (hardened or stainless steel) and its diameter (0.2, 0.4, 0.6, 0.8 mm), then confirm. Saves the material as `nozzle_typeN` in `saved_variables.cfg` and writes the diameter into `nozzle_diameter:` of `[extruder]` / `[extruderN]` in `printer.cfg` (a copy `printer.cfg.wm-before-nozzle-<time>` is kept; a value inside the SAVE_CONFIG block is changed too). The last window offers to restart Klipper, which is what makes it read the new diameter. |
| `WM_EXTRUDER_SETUP` | General > Extruder Setup | Shows the app's instruction (hang the extruders on the rear support, avoid tangling of the wires). On Next it checks that every heater is off and the hotends are below 50 C, sets `is_nozzle_setting = 1`, parks the tool that is on the carriage in its dock and unlocks it (WonderMaker's `_UNLOCK_TOOL`). You change the nozzles, put the tools back and click Done. |
| `WM_EXTRUDER_SETUP_END` | (the app does this when you leave the page) | Sets `is_nozzle_setting = 0` again and tells you which dock sensor shows an empty dock. Run it yourself if the wizard stopped half way. |
| `WM_EXTRUDER_MATCH` | Extruder Setup > Set Up (matching) | Picks up T0, T1, T2 and T3 one after the other (about 2 minutes, all tool heads must hang in their docks, heaters off and cold) and after each pick looks for the first empty dock sensor. Tool n gets the CAN id stored for the dock it came out of. If every tool came out of its own dock, nothing changes. Otherwise a window lists the new ids; **Apply and restart** writes them into `wm_zru_thr0.cfg` ... `wm_zru_thr3.cfg` through `wm_canids.py` (a copy `wm_zru_thrN.cfg.wm-before-match-<time>` of each changed file is kept) and does `FIRMWARE_RESTART`. Two tools with the same id: nothing is written. Nothing is written while it runs. |

Things to know:
- Klipper uses `nozzle_diameter` only as a label (the factory `max_extrude_cross_section` is fixed), so the slicer's nozzle setting is what counts. The material is only recorded: nothing in Klipper reads it. The factory screen app keeps it in `tmt1.ini` (`[nozzle] type0..3`, 0 = hardened steel is what the app shows by default); the helper also updates that file when it exists.
- `is_nozzle_setting = 1` is WonderMaker's own switch: while it is on, the tool change macros do not complain that a tool is missing from its dock. That is why the calibration macros refuse to start while it is on, and why `WM_EXTRUDER_SETUP_END` exists.
- After a real nozzle change run `WM_NOZZLE_TEMP_CAL` (hotend PID) and `WM_TOOL_OFFSETS`.
- The diameter is written by `wm_nozzle.py` (`scripts/` in the repository, copied by the installer to `~/printer_data/wm-tools/`) through the gcode shell command extension. Without that extension (`--shell-command off`) the installer leaves `wm_nozzle.cfg` out, because Klipper would not start with its `[gcode_shell_command]` section. `./installer.sh --remove shell-command` takes `wm_nozzle.cfg` out of `printer.cfg` first and keeps the file as `wm_nozzle.cfg.wm-removed-<time>`.
- `WM_EXTRUDER_MATCH` is the app's matching, read from the app's code (`start_nozzle_setting`): per tool it asks for `Tn`, reads which dock sensor is empty, and takes the id stored for that dock. Differences: this one stops at the first tool that cannot be picked up (the app goes on), and asks before it writes (the app writes and restarts by itself). If something goes wrong half way it puts `is_nozzle_setting` back to 0 and writes nothing; a tool may still be on the carriage, so look at the printer first. The ids are written by `wm_canids.py` (same folder as `wm_nozzle.py`); by hand: `python3 ~/printer_data/wm-tools/wm_canids.py show` or `... apply ID0 ID1 ID2 ID3`.
- You can also run the helper by hand: `python3 ~/printer_data/wm-tools/wm_nozzle.py show` or `... set 1 0.6 1` (tool 0 to 3, diameter, type).
- Extruder Setup follows what the factory macros do (`_UNLOCK_TOOL`, `is_nozzle_setting`) and the app's instruction text. The matching follows the app's code. Not tested on a real printer.
