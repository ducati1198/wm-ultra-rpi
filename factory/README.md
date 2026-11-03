# Factory files in this repository

For people who do **not** have a copy of the files from their own printer. Taken from the original screen-board image of a ZR Ultra-S.

## One set for both models

The ZR Ultra and ZR Ultra-S run the **same** firmware and files. The only difference is one include line in `printer.cfg`: `[include zru-s.cfg]` (chamber heater, air filter fan, door buttons) is on for the **Ultra-S** and off (`#`) for the **Ultra**. WonderMaker's own script `scripts/set_zru_include.sh` does this toggle. The installer does it for you with `--model ultra` or `--model ultra-s`.

(The Ultra case follows from that toggle. It has not been tested on an Ultra: if you own one, please report.)

## What is in `zru/`

| Item | Files |
|---|---|
| Klipper (WonderMaker's modified copy) | [`klipper/`](zru/klipper): browsable source folder, GPL v3 (`COPYING`) |
| Moonraker (WonderMaker's copy) | [`moonraker/`](zru/moonraker): browsable source folder, GPL v3 (`LICENSE`) |
| Factory settings | `config/`: `printer.cfg`, macros, extruders, hub, load cell, offset calibration, Moonraker config, `tmt1.ini`, `saved_variables.cfg`, `zru-s.cfg` |
| `printer.cfg` per toolhead count | `config-variants/printer1.cfg` ... `printer4.cfg` (1 to 4 toolheads, as WonderMaker ships them) |
| WonderMaker's helper scripts | `scripts/` (CAN id tools, restore factory settings, `set_zru_include.sh`, ...) |
| MCU update scripts and info | `mcu/*.sh`, `mcu/mcu_info.ini` (never run by the installer) |
| Python environments | not stored (machine-built folders): rebuilt from `config/klippy-requirements.txt` and `config/moonraker-requirements.txt` |
| Checksums | `SHA256SUMS`, `modules.sha256` (compiled modules), `mcu/binaries.sha256` (MCU firmware and flasher) |

## Binary files from WonderMaker (included at the repository owner's request)

| Item | Where | Note |
|---|---|---|
| The 5 compiled Python modules: `cs1237`, `hx711`, `heater_air_core`, `heater_feng`, `xy_offset_calibrator_core` | `zru/klipper/klippy/extras/` | WonderMaker's binaries, copied unchanged from a ZR Ultra-S. **No source and no license to redistribute are published by WonderMaker.** They stay WonderMaker's property |
| MCU firmware `klipper*.bin` and the `hid-flash` tool | `zru/mcu/` | Never used or run by the installer, which never flashes anything |
| `c_helper.so` | `zru/klipper/klippy/chelper/` | Klipper rebuilds it by itself if needed |

Not included: WonderMaker's touchscreen app and its encrypted update package, and your own calibration, saved variables and logs.

**Takedown:** if WonderMaker or any rights holder asks, these binaries will be removed. Their checksums stay in `modules.sha256` and `mcu/binaries.sha256`, so you can still verify files taken from your own printer. `--modules DIR` makes the installer use your own copies instead of the bundled ones.

WonderMaker's official firmware download: https://wondermaker3d.gitbook.io/wondermaker3d/printer-series/zr-ultra/documentation-package/firmware-file-download

Note: three Moonraker Python files (`server.py`, `application.py`, `storage_monitor.py`) had Windows line endings in WonderMaker's copy; they are stored with Unix line endings (Git converts them on upload). Nothing else differs.

## Verify

```
cd factory/zru && sha256sum -c SHA256SUMS
```
