# Finding: WonderMaker's heaters.py changes the chamber temperature reading

Found on the Pi while the chamber PID tune (`PID_CALIBRATE HEATER=chamber`) kept ending too early and gave bogus values.
File: `~/klipper/klippy/extras/heaters.py`, function `temperature_callback`. This is **not** in standard Klipper (the K1 with Kalico does not have it and tunes the chamber normally).

```python
# 应用校准  (= "apply calibration")
if self.target_temp > self.last_temp and self.short_name == "chamber":
    calibrated_temp = temp * 1.18
else:
    calibrated_temp = temp * self.calibration_factor
```

## Why it breaks tuning
- While the chamber heater is heating (target above the last reading) the reading is multiplied by 1.18, so 38 C real shows as about 45 C.
- Klipper's autotune swings the target between TARGET and TARGET-5. When the target drops, the factor goes away and the reading falls by up to 18% in one step. The tuner sees fake jumps, ends early (it stopped right after reaching 50 C) and the Ziegler-Nichols step produced nonsense (Kp 56.2, Ki 187, Kd 4.2).
- The K1 swings 50 / 45 / 50 / 45 as expected, because its reading is not scaled.

## What it means for normal use
- While heating, the displayed chamber temperature can be up to 18% above the real value; the heater switches off earlier than the real temperature would justify.
- The factory chamber PID (63.418 / 1.342 / 749.125) was probably tuned with this skew, so keep it.

## Options
1. Leave it (chosen on 2026-11-10). The chamber stays as zru-s.cfg has it, and the installer and calibration macros do not touch it.
2. Remove the 1.18 branch from heaters.py (a WonderMaker file, changes their behaviour), then tune the chamber again.

Related files in this folder: `wm_chamber_pid_macro.cfg` (the removed WM_CHAMBER_PID macro), `wm_pidcfg_with_chamber.py`, `README.md`.
