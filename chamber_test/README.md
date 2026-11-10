# chamber_test

Not used by the installer. This folder keeps the old way the installer handled the chamber heater's PID, in case it is wanted again.

## What is in here

`wm_pidcfg_with_chamber.py` is `scripts/wm_pidcfg.py` as it was in 1.23.47. Besides the hotends and the heated bed it also looked at `[heater_generic chamber]`. On the ZR Ultra-S the factory file `zru-s.cfg` sets the chamber's `control` and `pid_Kp/Ki/Kd`. The old script moved those lines out of `zru-s.cfg` into a `[heater_generic chamber]` section in `printer.cfg` (the other options of the section stay in `zru-s.cfg`), so Klipper's `SAVE_CONFIG` could store a chamber PID result.

Use it by hand, on the Pi (a copy of each changed file is kept as `<file>.wm-before-pidcfg-<time>`):

    python3 chamber_test/wm_pidcfg_with_chamber.py check ~/printer_data/config
    python3 chamber_test/wm_pidcfg_with_chamber.py fix   ~/printer_data/config

`fix` also gives the hotends `control: pid`, like the current script does. The 1.23.47 tests for the chamber move are in `tests/run_tests.sh` of that commit (`ad2da64`).

## Why the installer no longer does it

Tuning the chamber heater with `PID_CALIBRATE HEATER=chamber` gives wrong values on the Pi. WonderMaker's Klipper changes `temperature_callback` in `klippy/extras/heaters.py`:

    if self.target_temp > self.last_temp and self.short_name == "chamber":
        calibrated_temp = temp * 1.18
    else:
        calibrated_temp = temp * self.calibration_factor

For the chamber only, the reading is multiplied by 1.18 while the target is above it. `PID_CALIBRATE` switches the target between TARGET and TARGET-5 every cycle, which flips that factor, so the reading jumps by about 7 C each sample. The tuner then counts a "cycle" every 0.3 s, reaches its 12 cycles within 3 seconds and finishes with meaningless values (Ki in the hundreds, Kd under 10, instead of Ki about 1 and Kd in the hundreds). Seen twice on a ZR Ultra-S on 2026-11-10; the second run had a TARGET of 50 and stopped just after the first peak. Putting the whole `[heater_generic chamber]` section into `printer.cfg` did not change it.

So the chamber is left exactly as `zru-s.cfg` has it, and the chamber is not tuned on the Pi for now.

## Related

- While it heats, the chamber temperature Klipper shows can be up to 18% higher than the real sensor value (same code).
- `WM_CHAMBER_PID` (and the last stage of `WM_FULL_CALIBRATION`) run `PID_CALIBRATE` on the chamber and would give the same wrong values.


## Added in 1.23.49
- `wm_chamber_pid_macro.cfg`: the WM_CHAMBER_PID macro and the chamber stage of WM_FULL_CALIBRATION, removed from rpi-cfg/wm_calibration.cfg.
- `heaters_py_finding.md`: the heaters.py 1.18 factor, why it breaks the tune, options.
