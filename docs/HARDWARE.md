# Hardware notes

Use at your own risk. These notes describe what the software side expects; they are not a wiring manual.

## The two boards

| Board | Role | After the swap |
|---|---|---|
| WM-ZR-M V1.2 (RK3308B), screen/host board | ran Klipper, Moonraker, Fluidd and the touchscreen app | replaced by the Pi |
| WM-ZR-D V1.2, main board | Klipper USB-CAN bridge (USB `1d50:606f`), CAN bus at 1 Mbit to the toolheads and hub | stays (or its replacement) |

Klipper talks to the main board over USB; the main board bridges to the CAN bus. On the Pi the CAN interface is `can0`, set to 1 Mbit and `txqueuelen 1024` by the udev rule in `config/99-wm-can0.rules`.

## Software expectations

- User **`t13dp`**, home `/home/t13dp`: WonderMaker's service files, nginx root and config paths are fixed to it.
- **Python 3.9** for Klipper: WonderMaker's compiled modules (`cs1237`, `hx711`, `heater_air_core`, `heater_feng`, `xy_offset_calibrator_core`, `heater_air`, `xy_offset_calibrator`, `tools_calibrate`, `echelon_stepper`, `custom_hall`) are built for it only. Moonraker uses the same version for simplicity.
- 64-bit ARM (the factory board is aarch64).
- Moonraker group `moonraker-admin`; user in `dialout` and `plugdev`.

## Checks before the first Klipper start

1. `scripts/board_check.sh`: USB id present, `can0` up.
2. Klipper stopped: the same script runs `canbus_query.py` and lists the CAN uuids it finds.
3. `canbus_uuid` in your config must match the main board that is installed now.
4. Compare against your old working config (saved in `~/wm-rpi-backup/` if the installer replaced folders).

## Not covered

Touchscreen replacement, webcams (the nginx routes for four mjpg-streamer cameras are included but no camera service is installed), firmware flashing of any board.
