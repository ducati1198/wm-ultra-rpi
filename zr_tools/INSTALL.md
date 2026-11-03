# ZR Tools v1 – KlipperScreen panel for the WonderMaker ZR Ultra-S

## Files
| File | Goes to | What it does |
|---|---|---|
| `zr_tools.py` | `~/KlipperScreen/panels/` | The touch panel |
| `zr_tools.cfg` | `~/printer_data/config/` | Helper macros used by the panel |
| `install_zr_tools.sh` | run once | Copies everything, edits configs (with backups), restarts |

## Install (on the Pi / Klipper host)
```bash
cd ~/zr_tools          # folder where you copied these files
bash install_zr_tools.sh
```
The installer:
1. copies `zr_tools.cfg` and adds `[include zr_tools.cfg]` to `printer.cfg` (backup kept)
2. leaves WonderMaker's `change_macros.cfg` untouched – pressure advance is managed by
   your slicer's filament profiles
3. copies the panel and adds **ZR Tools** to the KlipperScreen main menu
4. restarts Klipper and KlipperScreen

## What the panel does
- **Main:** 4 toolhead cards – colour, material, temperature, filament sensor, dock state,
  active toolhead, and which slicer tool each toolhead prints.
- **Tap a toolhead:** Select, Heat, Cool, Load, Unload, Purge; set material, colour and
  temperature, then **Save**.
- **Mapping:** choose which toolhead prints slicer T0–T3 (set it just before a print;
  WonderMaker resets it to 1:1 after each print).
- **Utilities:** home, offset calibration (fine/rapid), Z and XY offset of the active
  toolhead, bed mesh, wipe, park, motors off, gripper lock/unlock – all with confirmation.
- **Chamber:** chamber heater presets and ±5 °C, air-filter fan, door switches.

## Macros you can also use in the console / slicer
`ZR_SET_TOOL_INFO T= HEX=|COLOR= MAT= TEMP=` · `ZR_SET_TOOL_PA T= PA=` ·
`ZR_MAP_TOOL T= H=` · `ZR_MAP_RESET` · `ZR_LOAD T=` · `ZR_UNLOAD T=` ·
`ZR_PURGE [LENGTH=] [TEMP=] [WIPE=0|1]` · `ZR_CHAMBER S=` · `ZR_AIR_FILTER S=0|1`

## Notes
- Actions are blocked while printing (except heat/cool and chamber).
- The air-filter fan only runs if `air_filter=1` in `tmt1.ini` (WonderMaker's fan code checks it).
- Some icons may not exist in your KlipperScreen theme; buttons still work, just without an icon.
- Pressure advance: set it in your OrcaSlicer filament profiles. (`ZR_SET_TOOL_PA` still
  exists for manual use, but tool changes keep WonderMaker's default.)
- To undo: remove the `[include zr_tools.cfg]` line from `printer.cfg`, and delete the `[menu __main zr_tools]` block from `KlipperScreen.conf`.
- First version, written without access to a running KlipperScreen: if something looks
  wrong, send a screenshot and `~/printer_data/logs/KlipperScreen.log`.
