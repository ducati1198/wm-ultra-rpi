# Notes: Wondermaker+ (anselor/Wondermaker_plus) compared with this printer

Written 2026-11-05 so the review can be picked up again after the new MCU is installed.
Source: <https://github.com/anselor/Wondermaker_plus> (an independent community project, not affiliated with WonderMaker).
Nothing from it is installed on the printer. This page only records what was found and what to do next.

## What was compared

The repo's `config/live/` (its changed config) against `config/stock/` (its copy of the factory baseline, vendor System 1.1.13),
and against the config files read from this printer's Pi (read-only, nothing written).

## Result for this printer

- All vendor `.cfg` files on the Pi are identical to the repo's 1.1.13 baseline, ignoring whitespace. The exception is `printer.cfg`, which has this project's own `[include]` lines (ZR Tools, ACE, endless spool, stats), and one older-style `M104 T{i} S0` line in the idle timeout block.
- The Pi's files contain zero Wondermaker+ markers: **none of its changes are installed.**
- Its installer (`tools/deploy.py install config`) replaces the body of `printer.cfg`, so our `[include]` lines would be lost. Merge by hand instead, and keep a backup.
- The touchscreen, `material` and `preload` parts only patch the factory screen app. That app is switched off on the Pi setup, so they do not apply. Power-loss recovery needs those patches too.
- The author lists print, tool-change and calibration trials on 1.1.13 as still pending. Earlier versions completed two-colour prints and power-loss tests.
- Its tool mapping uses the same `box_modify_t*` variables as our `WM_SET_TOOL_MAP`, so the two fit together.

## Changed `.cfg` files (12 of 26; the CAN, hub, load-cell and `change_extruder.cfg` files are untouched)

| File | What changes |
|---|---|
| `printer.cfg` | New sections `[wmp_recovery]`, `[include wm_material*.cfg]`, `[include openace*.cfg]`. Real bottom-Z home instead of `SET_KINEMATIC_POSITION Z=3`. Safer recovery `G28` order. `Z_HOMING` uses the first print tool. `max_accel` 20000 to 5000. New `REHOME` macro. |
| `macros.cfg` | START_PRINT probes with the first print tool (`PROBE_WITH_INITIAL_TOOL ENABLE=0/1`), saves the print mesh as `wmp_print`, purges on the left edge (X0, Y100 to 150) instead of the front (Y-1). PRINT_END lowers the bed up to 50 mm (stock 10) and wipes. PAUSE parks at Y20 (stock Y1) and saves the tool mapping. RESUME restores heaters by physical head. `M24` and `BED_MESH_PROFILE` are wrapped to check mesh, file and mapping before recovery. Load/unload lift first and leave the bed sideways. Unload uses `_TIP_SHAPE_RETRACT` (sequences by material, from Snapmaker U1 and Prusa profiles). |
| `change_macros.cfg` | Tool change keeps the slicer's feedrate, wipes the new nozzle, returns with a 2 mm lift. Z lift and pickup use the real bottom-Z helper. A failed change is no longer counted as success. |
| `offset_calibrate.cfg` | At least 7 mm clearance before and during calibration travel. Cooldown waits only until the temperature falls (no reheat after an undershoot). Blob cleaning refused during a print. |
| `fz-wipe-nozzle.cfg` | Wipe speed is a variable, 50 to 200 mm/s. The slicer's feedrate is restored after the wipe (stock leaves the slow wipe feedrate on). |
| `extruder0.cfg` to `extruder3.cfg` | Inserting filament no longer starts an automatic load; use Load on the screen. |
| `fluidd.cfg`, `timelapse.cfg`, `test_macro.cfg` | Descriptions and messages reworded or translated. No logic change. |

## The `.py` files (all new; none exist in the factory firmware)

- `klipper_extras/wmp_recovery.py`: bottom-Z helper. Adds `_WMP_HOME_Z_BOTTOM`, tracks whether Z is really homed, and checks that `stepper_z` is the supported setup (pin PD2, endstop 300, retract 2, corexy, `LEVELING` and `GANTRY` pins inactive). Any failure shuts Klipper down. Our `printer.cfg` matches those settings.
- `klipper_extras/wm_material.py`: reads each slot's material from `tmt1.ini` for the unload macros.
- `klipper_extras/wmp_z_diagnostics.py`: manual Z-max test, never installed by default.
- `tools/` and `utils/`: installer and preflight checks, config diff/upload/migration, resonance and input-shaper measurement, touchscreen helpers.
- `device/wmp_screen.py`: streams the factory screen into Fluidd (not useful here).
- `tests/`: 15 test files. `client-preload/*.c`: patches for the factory screen app (not Python).

## Verdict per change (my own assessment, not tested on this printer)

- **Worth taking first:** real bottom-Z home (`wmp_recovery.py`), the wipe feedrate fix, left-edge purge, the print-end bed drop and wipe.
- **Check before taking:** `wmp_print` mesh naming (does Fluidd or KlipperScreen use the old profile names?), `max_accel` (the 5000 comes from the author's own shaper tests, measure this printer first), wipe speed, tip-shaping unload (try `_TIP_SHAPE_RETRACT DRY_RUN=1`), probing with the first tool.
- **Behaviour change:** inserting filament will no longer auto-load.
- **Skip:** everything for the factory touchscreen.
- Not read line by line: the full text of `macros.cfg` and `change_macros.cfg` beyond the changes listed above.

## Plan for after the new MCU is installed

1. Install and check the new MCU first (`./installer.sh --first-start`, `--hw-test`), and print once with the current config as a reference.
2. Back up the Pi's config. Build a merge candidate off the printer: bottom-Z helper and its `printer.cfg` sections first, then the wipe fix, print start/end, pause/resume, keeping all of our `[include]` lines.
3. Review the candidate (diff) before anything is copied to the printer.
4. Apply it a few pieces at a time and test each: a homing and tool-change test, then a short two-colour print, then a pause/resume.
5. Re-check that `WM_SET_TOOL_MAP` from the OrcaSlicer plugin still maps the tools correctly after the merge.
