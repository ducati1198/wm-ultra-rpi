# rpi-cfg: the Pi's own config files

Files in this folder are **not WonderMaker's**. They are made for the Raspberry Pi. The installer copies them into `~/printer_data/config` and adds an `[include ...]` line for each to `printer.cfg`. A WonderMaker update never changes them (`tools/wm-release/wm_release.py` knows these file names and leaves them alone).

| File | What it is |
|---|---|
| [`wm_calibration.cfg`](wm_calibration.cfg) | The calibration items of the WonderMaker screen app (General > Maintenance) as macros you start from Fluidd |

## `wm_calibration.cfg`: macros

| Macro | Same as the app's | What it runs |
|---|---|---|
| `WM_BED_LEVELING` | Bed Leveling | `G28`, `G29` (heat bed 55 C and nozzle 140 C, wipe, 49 point mesh), heaters off, `SAVE_CONFIG` |
| `WM_PROBE_CALIBRATE` | PROBE_CALIBRATE | warms the bed (`BED=60`, max 100), then WonderMaker's `PROBE_CALIBRATE`; you adjust with `TESTZ Z=-0.1` and so on, run `ACCEPT`, then `WM_PROBE_DONE` |
| `WM_TOOL_OFFSETS MODE=rapid` or `MODE=accurate` | Extruder Offsets Calibration (Rapid / Accurate) | `CALIBRATE_OFFSET_ALL_RAPID_MODE` or `CALIBRATE_OFFSET_ALL_FINE_MODE`, then heaters off |
| `WM_VIBRATION_COMP` | Vibration Compensation | `G28`, `SHAPER_CALIBRATE` (the `lis2dw` accelerometer on the EX_T board), `SAVE_CONFIG` |
| `WM_BED_PID TARGET=60` | (no button in the app) | `PID_CALIBRATE HEATER=heater_bed` for the heated bed (40 to 110 C), `SAVE_CONFIG`. Needs `control: pid`, which the factory bed has |
| `WM_CHAMBER_PID TARGET=45` | (no button in the app) | `PID_CALIBRATE HEATER=chamber` for the ZR Ultra-S chamber heater (30 to 60 C), `SAVE_CONFIG`. Refuses on the Ultra (no chamber heater) |
| `WM_NOZZLE_TEMP_CAL T=0 TARGET=220` | Nozzle Temperature Calibration | `PID_CALIBRATE` for hotend T (fan full, tool head at X150 Y150), `SAVE_CONFIG`. Refuses when that heater uses `control: watermark` (WonderMaker's default): PID tuning does nothing then |
| `WM_QUICK_START` | the K1's Quick Start | opens a Fluidd window that explains what will run, how long it takes and what to check; Start Calibration then runs bed leveling, rapid tool offsets, vibration compensation, bed PID, hotend PID (only hotends with `control: pid`) and chamber PID (Ultra-S) with no more questions, and one Save and Restart window at the end. Z height is not included (it needs you at the printer); the end window points to `WM_PROBE_CALIBRATE` |
| `WM_CAL_ALL MODE=rapid PID=0` | the whole menu | one stage at a time: leveling, probe, tool offsets, vibration (and hotend PID with `PID=1`). Asks Run / Skip / Stop before each stage and saves once at the end |
| `WM_CAL_STOP` | | heaters and fan off |
| `WM_CAL_HELP` | | lists the macros |
| `WM_ZOFFSET_UP` / `WM_ZOFFSET_DOWN` `STEP=0.025` | the Z-Offset + and - buttons | `SET_GCODE_OFFSET Z_ADJUST=...` (live only, not saved) |

Safety, in every macro: it refuses to start while a print runs or while any heater has a target above 0, it asks you to confirm in a Fluidd window (Start / Cancel), and it turns the heaters off at the end. `SAVE_CONFIG` restarts Klipper. Stay at the printer.

Not included on purpose: Feed & Discharge and Extruder Setup (they need the nozzle removed and your hands on the printer).

The macros call WonderMaker's own macros (`G29`, `PROBE_CALIBRATE`, `CALIBRATE_OFFSET_ALL_*`), so the factory `macros.cfg` and `offset_calibrate.cfg` must be installed too (they are, from `factory/<model>/config`).

**Where the commands come from:** the G-code sequences were read from the strings in the screen app (`TM_T1/bin/client`, System 1.1.13). The app's own progress names `CHECK_AUTO_LEVEL_*`, `CHECK_SHAPPER_*` and `CHECK_PID_*` are not G-code and are not used. The app also saves a `probe_position` value after PROBE_CALIBRATE; how it is calculated is not known, so `WM_PROBE_CALIBRATE` does only the Klipper side. **Not tested on a real printer.**

## Install and update

- The installer does it (step 4c) on every install and `--update`.
- Only this: `./installer.sh --rpi-cfg`
- `./installer.sh --doctor` checks that each file is there, included in `printer.cfg` and the same as this folder; Fix everything repairs it. An edited copy is kept as `<name>.wm-before-rpicfg-<time>` before it is replaced.
- `python3 tools/wm-release/wm_release.py status` shows the state of each file.
