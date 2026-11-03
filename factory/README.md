# Factory files in this repository

For people who do **not** have a copy of the files from their own printer. Taken from the original screen-board image of a ZR Ultra-S.

## One set for both models

The ZR Ultra and ZR Ultra-S run the **same** firmware and files. The only difference is one include line in `printer.cfg`: `[include zru-s.cfg]` (chamber heater, air filter fan, door buttons) is on for the **Ultra-S** and off (`#`) for the **Ultra**. WonderMaker's own script `scripts/set_zru_include.sh` does this toggle. The installer does it for you with `--model ultra` or `--model ultra-s`.

(The Ultra case follows from that toggle. It has not been tested on an Ultra: if you own one, please report.)

## What is in `zru/`

| Item | Files |
|---|---|
| Klipper (WonderMaker's modified copy) | `klipper.tgz`: GPL v3, `COPYING` inside |
| Moonraker (WonderMaker's copy) | `moonraker.tgz`: GPL v3, license inside |
| Factory settings | `config/`: `printer.cfg`, macros, extruders, hub, load cell, offset calibration, Moonraker config, `tmt1.ini`, `saved_variables.cfg`, `zru-s.cfg` |
| `printer.cfg` per toolhead count | `config-variants/printer1.cfg` ... `printer4.cfg` (1 to 4 toolheads, as WonderMaker ships them) |
| WonderMaker's helper scripts | `scripts/` (CAN id tools, restore factory settings, `set_zru_include.sh`, ...) |
| MCU update scripts and info | `mcu/*.sh`, `mcu/mcu_info.ini` (never run by the installer) |
| Python environments | not stored (machine-built folders): rebuilt from `config/klippy-requirements.txt` and `config/moonraker-requirements.txt` |
| Checksums | `SHA256SUMS`, `modules.sha256` (compiled modules), `mcu/binaries.sha256` (MCU firmware and flasher) |

## What is NOT here, and why

| Item | Why |
|---|---|
| The 5 compiled Python modules: `cs1237`, `hx711`, `heater_air_core`, `heater_feng`, `xy_offset_calibrator_core` | Binaries without source and without any license that allows copying them. Klipper is GPL v3, so a copy of derived binaries without their source would break that license as well |
| MCU firmware `klipper*.bin` and the `hid-flash` tool | Same reason (no matching source in the package). Also never needed: this project never flashes any board |
| WonderMaker's touchscreen app and encrypted update package | Not ours to publish |
| Your calibration, saved variables, logs | They belong to your printer |

Where they come from: your own printer or its image, or WonderMaker's official download page (the update package there is encrypted for the printer's own updater, so it cannot be unpacked here). The installer checks the 5 modules against `modules.sha256` and refuses a modified file.

WonderMaker's official firmware download: https://wondermaker3d.gitbook.io/wondermaker3d/printer-series/zr-ultra/documentation-package/firmware-file-download

If WonderMaker gives written permission to redistribute the binaries, they can be added here.

## Verify

```
cd factory/zru && sha256sum -c SHA256SUMS
```
