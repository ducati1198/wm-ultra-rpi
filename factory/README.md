# Factory files in this repository

For people who do **not** have a copy of the files from their own printer.

| Folder | Printer | Source | Contents |
|---|---|---|---|
| `ultra-s/` | WonderMaker ZR Ultra-S | the original screen-board image (Klipper + Moonraker + factory settings) | `klipper.tgz`, `moonraker.tgz`, `config/`, `modules.sha256`, `SHA256SUMS` |
| `ultra/` | WonderMaker ZR Ultra | **not available yet** | needs files from an Ultra owner: send an image or a `pull_from_board.sh` result |

## What is here and what is not (licenses)

| Part | In this repo? | Why |
|---|---|---|
| Klipper (WonderMaker's modified copy, Python and C source) | yes | Klipper is GPL v3; the license text (`klipper/COPYING`) is inside the archive and the full source is the archive itself |
| Moonraker (WonderMaker's copy) | yes | GPL v3, license inside the archive |
| Factory printer settings (`config/`) | yes, see note | plain-text configuration and macros of the original firmware, unchanged |
| The 5 compiled modules (`cs1237`, `hx711`, `heater_air_core`, `heater_feng`, `xy_offset_calibrator_core`) | **no** | they are binaries without source and without a license that allows redistribution |
| MCU firmware (`klipper*.bin`), WonderMaker's touchscreen app, OTA tools | **no** | not needed here and not ours to publish |
| Your own calibration and `saved_variables` | **no** | they belong to your printer |

The 5 binary modules come from **your own printer or its image** (`--modules`, or the normal sources). `modules.sha256` lists the exact factory files so the installer can refuse anything modified.

Note on `config/`: these are WonderMaker's original default files, included so a printer can be set up without any other source. If WonderMaker objects, they will be removed. Nothing in them is personal: CAN ids are the factory placeholders (`aa0000000000`, ...).

## Rebuild or verify

```
cd factory/ultra-s && sha256sum -c SHA256SUMS
```
