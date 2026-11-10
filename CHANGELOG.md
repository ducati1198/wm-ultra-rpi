# Changelog

## 1.23.46

- **Z calibrate page no longer crashes on the screen board.** Starting `WM_PROBE_CALIBRATE` opened KlipperScreen's Z calibrate page, which stopped with `KeyError: 'z_offset'` because WonderMaker's `printer.cfg` has `# z_offset:0` commented out under `[probe]` (Klipper itself does not mind). `screen_board.sh` now patches `panels/zcalibrate.py` on install and update to use 0.0 when the line is missing; the original is kept as `zcalibrate.py.wm-orig`.

## 1.23.45

- **ZR Tools buttons work on the current KlipperScreen.** Every button that sends G-code (chamber, tool change, ACE, ...) failed with "Connection error" because the panel called `_ws.klippy.gcode_script`, which newer KlipperScreen no longer has. It now uses `_ws.api.gcode_script`, falls back to the old call, then to a plain Moonraker request.
- **Park tool button** on each toolhead page (next to Edit filament): asks first, then runs `PARK_CURRENT_TOOL`.
- **Tool colours are shared with Fluidd and the touchscreen.** The panel reads and writes the `[slot]` section of `tmt1.ini` (through Moonraker), the same file the Fluidd panel and the factory touchscreen use. The colour dots are now the touchscreen's own 21 swatches, same order as Fluidd. A custom colour snaps to the closest swatch when saved. The factory touchscreen app re-reads `tmt1.ini` only after it restarts.

## 1.23.44

- **The host MCU is now connected to Klipper by the installer.** New step `step_pi_sensors` (also `./installer.sh --pi-sensors`), run after Klipper is running at the end of an install and an update. It writes `wm_rpi_mcu.cfg` (`[mcu rpi]` with `serial: /tmp/klipper_host_mcu`), includes it from `printer.cfg` after the other includes and above the `SAVE_CONFIG` block, restarts Klipper and waits for "ready". If Klipper does not come back, the include and the file are taken out again, `printer.cfg` is restored and Klipper is restarted once more (the refused file is kept as `*.wm-failed-<time>`). Not done during a print, while Klipper is stopped, or when `klipper-mcu` is not running. A copy of `printer.cfg` is kept each time.
- **The user is added to the `tty` group** (install step 2). The host MCU runs as root and its socket belongs to group `tty`; without it Klipper says "Permission denied" for `/tmp/klipper_host_mcu`. Found by trying `[mcu rpi]` on a real Pi (built, connected, ready with all eight boards).
- **Temperatures in Fluidd.** `rpi-cfg/wm_pi.cfg`: `[temperature_sensor raspberry_pi]` (the Pi's CPU temperature, limit 85 C; only where Klipper has `temperature_host`). The same step writes `wm_mcu_temps.cfg` with the chip temperature of every `[mcu]` board found in the config (`mcu_main`, `mcu_hub`, `mcu_extruder`, `mcu_t0`..`mcu_t3`, `mcu_loadcell`; -20 to 110 C). All eight read correctly on a real Pi.
- **The installer reads the Pi model and memory** (from the device tree) and shows them in the check at the start, the plan, `--status` and the support bundle. A Pi 3, 2, 1 or Zero, or less than 1.8 GB of memory, gets a warning (slow, not blocked). Nothing else depends on the model; a Pi 4 and a Pi 5 are treated the same.
- **Doctor:** checks that the `klipper-mcu` service runs (and that a printer.cfg using `[mcu rpi]` has it) and that the user is in the `tty` group, with a fix for each.
- `docs/HOST_MCU.md` rewritten: what is installed, the rollback, the temperatures and an ADXL345 example with `rpi:` pins. The message after step 7b no longer tells you to add `[mcu host]` yourself.

## 1.23.43

- New install step 7b: **Klipper host MCU**. The installer builds Klipper's Linux MCU from the official Klipper source (pinned in `config/pins/addons.txt` as `klipper-upstream`, v0.12.0, into `~/klipper-host-mcu`), installs `/usr/local/bin/klipper_mcu` and the `klipper-mcu` service, enables and starts it, and restarts Moonraker so Fluidd lists **Klipper-Mcu** under Services. WonderMaker's `~/klipper` has no MCU source folder, which is why the official one is used. Nothing in `printer.cfg` changes: Klipper only uses it once you add `[mcu host]` (see the new `docs/HOST_MCU.md`). It runs on a new install and on `--update` (skipped when already installed); a failed build or download only warns. Uninstall stops and disables the service. Tried on a fresh Pi (build, service active, Moonraker lists it); the installer step itself is covered by the mock tests.
- Fluidd has no "Firmware Restart" entry in its Services list (only on the red status card when Klipper is down); use the console command `FIRMWARE_RESTART`.

## 1.23.42

- The tool offsets are now two macros, one for each button of the screen: `WM_OFFSETS_RAPID` and `WM_OFFSETS_ACCURATE` (option `TEMP`, default 220). `WM_TOOL_OFFSETS` (with `MODE=`) and its four helper macros (`_WM_TO_PREP`, `_WM_TO_CLEAN`, `_WM_TO_RAPID`, `_WM_TO_END`) from 1.23.41 are gone. Same order as the screen as in 1.23.41. Klipper does not let a macro call itself and has no "wait for a button", so `WM_OFFSETS_ACCURATE` ends after each tool is prepared and shows the debris window; its OK button starts the same macro again with `STEP=clean N=<tool>`, which wipes that tool and prepares the next one (or, after the last tool, measures all tools, parks and turns the heaters off). `WM_FULL_CALIBRATION` calls `WM_OFFSETS_RAPID`. A Pi that has the old `wm_calibration.cfg` gets the new one with Doctor Fix. Not tested on a real printer.

## 1.23.41

- `WM_TOOL_OFFSETS MODE=accurate` now follows the order the screen app uses (read from its code and from the log of a real run on a screen board): `G28`; for every tool `NOZZLE_PREPARE S=220 T=n`, then a window with the app's text ("ensure the button-like purged debris has been manually removed from the nozzle tip") and an OK button, then `NOZZLE_CALIBRATE_TOOL_OFFSET T=n`; after the last tool `RAPID_MODE T=n` for every tool; `PARK_CURRENT_TOOL`. Before it called WonderMaker's `CALIBRATE_OFFSET_ALL_FINE_MODE`, which does one tool after the other and which the screen never calls. New option `TEMP` (default 220, the app uses the filament's extrude temperature). `MODE=rapid` is as before and now also parks the tool at the end, like the screen. New helper macros `_WM_TO_PREP`, `_WM_TO_CLEAN`, `_WM_TO_RAPID`, `_WM_TO_END`. If Klipper stops with an error the chain stops; WM_CAL_STOP turns the heaters off (the screen skips the failed tool instead). Tested with mocks only, not on a real printer.

## 1.23.40

- Docs only: the tool alignment (Rapid / Accurate) can fail on every try with `Probe samples exceed samples_tolerance` at `TOOL_LOCATE_SENSOR` when the saved `probe_position` in `saved_variables.cfg` is wrong. Seen on a new screen board: the saved value was `(299.0, 290.0, 4, 6.9, 5.8)`; the printer that had worked before had `(299.0, 289.0, 8.87, 6.9, 5.8)`. After setting the old value (`SAVE_VARIABLE VARIABLE=probe_position VALUE=299.0,289.0,8.87,6.9,5.8`) Rapid passed for T0 to T3. The alignment takes the sensor position from the saved value, not from `probe_position` in `offset_calibrate.cfg` (that one is only used when nothing is saved). The values are not changed in `factory/`: the right Z is a calibrated number of that printer. Written in `rpi-cfg/README.md`.

## 1.23.39

- `WM_EXTRUDER_SETUP` is now the screen's Extruder Setup page: the app's instructions and a **Set Up** button that does the matching (what `WM_EXTRUDER_MATCH` did in 1.23.38; that macro is gone, it is this one now). The earlier "release the tool heads so you can change nozzles" workflow was not something the app does, so it moved to its own name: `WM_NOZZLE_CHANGE` and `WM_NOZZLE_CHANGE_END` (was `WM_EXTRUDER_SETUP_END`). Its Done window has an Extruder Setup button for the matching. The README said the old workflow was the app's; it now says it is Pi only. If a nozzle change is left on, `WM_NOZZLE_CHANGE_END` clears it.

## 1.23.38

- New macro `WM_EXTRUDER_MATCH` (in `rpi-cfg/wm_nozzle.cfg`), the "Set Up" matching of the screen's Extruder Setup. Read from the screen app's code, not guessed: with `is_nozzle_setting = 1` it picks up T0 to T3 one after the other, and after each pick takes the first dock sensor that shows an empty dock. Tool n gets the CAN id that was stored for that dock. If every tool came out of its own dock nothing changes. If the ids would change, a window shows them and asks; Apply writes them into `wm_zru_thr0.cfg` ... `wm_zru_thr3.cfg` (a copy of each changed file is kept) and does FIRMWARE_RESTART. Two tools with the same id: nothing is written. Different from the screen: it stops at the first tool that cannot be picked up and asks before it writes. The Done window of `WM_EXTRUDER_SETUP` offers it.
- New helper `scripts/wm_canids.py` (`show`, `apply ID0 ID1 ID2 ID3`), installed with `wm_nozzle.py` into `~/printer_data/wm-tools/`; the Doctor checks it.
- Not tested on a real printer.

## 1.23.37

- `WM_QUICK_START` is now `WM_FULL_CALIBRATION` (same one-click calibration, new name, window texts and messages say "Full calibration"). `WM_CAL_ALL` and its helper macros are removed: the single macros (`WM_BED_LEVELING`, `WM_PROBE_CALIBRATE`, `WM_TOOL_OFFSETS`, `WM_VIBRATION_COMP`, ...) can be run one at a time instead. A Pi that has the old `rpi-cfg/wm_calibration.cfg` is told by the Doctor that the file differs and gets the new one with Fix.

## 1.23.36

- `tools/wm-release/wm_release.py` 1.8.0: `flash` shows the version each board runs now and the one in `~/mcu_update`, refuses an empty or placeholder CAN id and an id that does not answer on the bus (unless `--force`), and the new `flash [board] --verify` compares what the boards report with the package after FIRMWARE_RESTART. Still a dry run unless `--run` and FLASH is typed. The load cell has no firmware file in the repo or on the screen board, so `flash cell` cannot run yet.

## 1.23.35

- CAN ids of every board are checked and can be fixed, not only the main board's: hub, extruder board, T0-T3 and load cell. New `./installer.sh --can-ids` shows which ids in the config answer on the bus and offers the unknown id on the bus to the board that does not answer (a copy of the file is saved first); `--can-ids set T2 ID` sets one by hand. The same check is in the first-start checks and in the Doctor (so also in Fix everything). Unattended it only changes an id when exactly one board is wrong and exactly one unknown id is on the bus. The warning no longer points at a script that is not on the Pi. 614 installer tests.

## 1.23.34

- `factory/ultra-s/config/`: main board CAN id `aa157497ce9c` and load cell id `af2a269ae807`, as on the screen board once the right main board (ZRU firmware) was connected and every MCU answered. `factory/ultra/` unchanged.

## 1.23.33

- `factory/ultra-s/config/` is now the configuration of the new screen board after switching it to the Ultra-S setup (`model=2`, `[include zru-s.cfg]` on, screen shows ZR Ultra-S). Changes against the old folder: board's CAN ids, `saved_variables.cfg`, `offset_calibrate.cfg`, `zru-s.cfg`, `printer.cfg` (older WonderMaker version, no saved PID values for extruders 1 to 3) and `tmt1.ini` (camera, timelapse, air_filter and auxiliary_fan now 1). `factory/ultra/` unchanged.

## 1.23.32

- `factory/ultra/config/` now holds the configuration files of a new factory screen board for the ZR Ultra (image V1.0.26), copied unchanged: `tmt1.ini` has `model=1` (it was `model=2`, so an Ultra install showed up as an Ultra-S on the screen), `saved_variables.cfg` has `adaptive_mesh_enable = 0`, and `printer.cfg`, `offset_calibrate.cfg`, the CAN ids and `zru-s.cfg` are that board's own (older WonderMaker versions of `printer.cfg` and `offset_calibrate.cfg` than the Ultra-S folder, no saved PID values). `factory/ultra-s/` is unchanged. 606 installer tests.

## 1.23.31

- Fluidd's update manager now lists this installer's repository (`wm-ultra-rpi`) and, when the ACE Pro is chosen, the ACE Pro project (`wm-ultra-fluidd-acepro-panel`): the installer adds `[update_manager ...]` sections to `moonraker.conf` on install and update (a copy `moonraker.conf.wm-before-updatemgr-STAMP` is kept; nothing is added twice). Updating there only downloads the files; run `./installer.sh --update` afterwards to apply them. `--remove acepro` takes the panel entry out again.
- The update screen is now honest about what it touches: it names the ACE Pro files (rewritten by the project's own updater, settings kept), the Fluidd update entries in `moonraker.conf`, and the ACE Pro driver. While dev mode is on it prints the dev-box notice (Klipper reads a private copy of the config, so refreshed files only show after `devbox.py off` and `on`). 606 installer tests.

## 1.23.30

- Dev box: no more Moonraker warning "Klipper configuration file not located in 'config' folder". `devbox.py on` adds `check_klipper_config_path: False` to `[file_manager]` in `moonraker.conf` (a copy `moonraker.conf.wm-before-devbox` is kept) and restarts Moonraker; `devbox.py off` takes it out again.

## 1.23.29

- Dev box: the ACE Pro driver now starts in dev mode. The factory weight-cell module (cs1237) waits for its fake board and never returns from its "ready" step, so every step after it (including the ACE driver's first connection) was skipped, and the ACE rebooted itself every ~3 s because nobody talked to it. `devbox_sim` now moves the ACE driver's ready step to just before the weight-cell module.

## 1.23.28

- The dev box (`tools/devbox/`, `README-DEVBOX.md`: run WonderMaker's Klipper on a Pi with no printer, fake boards and simulated heaters and tool changer) is part of `main`. It is not used by the installers.
- `devbox.py on` refuses when the Pi looks connected to a real printer (the main board's USB bridge 1d50:606f, or `can0` up) unless `--force`. The private config copy no longer includes `*.wm-before-*` / `*.wm-removed-*` saved copies. `--doctor`, `--cfg-merge` and `--pid-cfg` print a notice while dev mode is on (what Klipper saves then goes to the private copy). No banner in the main README. 604 installer tests.

## 1.23.27

- Anycubic ACE Pro. The install now asks "Do you have an Anycubic ACE Pro to connect?" (default no); `--acepro on|off`; Add-ons menu entry; step 12h downloads the project wm-ultra-fluidd-acepro-panel to `~/wm-ultra-fluidd-acepro-panel` (git pull on `--update`) and runs its own installer with the default answers (driver links in Klipper's extras, `wm_ace_driver.cfg`, `wm_ace.cfg`, `wm_endless.cfg`, `wm_stats.cfg` and their include lines). Checked against the project's real installer in test mode.
- Uninstall: `--remove acepro` (also in the Uninstall menu, All programs and Erase everything) runs the project's uninstaller, then removes the config files, include lines (printer.cfg copy kept), links, the downloaded project and its settings file; asks before deleting `~/acepro-backup`. The Doctor checks the ACE install and Fix everything repairs it. 599 installer tests.

## 1.23.26

- New `rpi-cfg/wm_nozzle.cfg`: `WM_NOZZLE_TYPE` (pick nozzle 1 to 4, material hardened or stainless steel, diameter 0.2 to 0.8 mm, confirm, optional Klipper restart) and `WM_EXTRUDER_SETUP` / `WM_EXTRUDER_SETUP_END` (the app's instruction, heater and temperature check, `is_nozzle_setting` on, park and unlock the tool on the carriage, Done puts it back and checks the dock sensors), as Fluidd window wizards like `WM_QUICK_START`. The calibration macros now refuse to start while `is_nozzle_setting` is 1.
- New `scripts/wm_nozzle.py`: writes `nozzle_diameter` into printer.cfg (copy `.wm-before-nozzle-<time>`, SAVE_CONFIG block value changed too) and the type into `tmt1.ini`. Run through Klipper's gcode shell command extension; the installer copies it to `~/printer_data/wm-tools/`, installs `wm_nozzle.cfg` only where that extension is (or will be) installed, the Doctor checks the script, and `--remove shell-command` takes `wm_nozzle.cfg` out of printer.cfg first. 581 installer tests, 31 macros in the render test. Not tested on a real printer.
- Release tool 1.7.1: `status` does not report `wm_nozzle.cfg` as missing where the shell command extension is not installed.

## 1.23.25

- printer.cfg now follows WonderMaker's versions. New `scripts/wm_cfgmerge.py`: a 3-way merge by setting (old factory file, new factory file, the Pi's file). WonderMaker's new and changed settings and sections arrive; the Pi's own lines, sections and `[include]` lines stay; `canbus_uuid` / `serial` stay the Pi's; the SAVE_CONFIG block is kept byte for byte; a setting both sides changed differently is asked one by one (mine / theirs). `saved_variables.cfg` only gets new keys, never a changed value.
- Installer: step 4e on install and `--update` (preview, question, copy `printer.cfg.wm-before-cfgmerge-<time>`), new `./installer.sh --cfg-merge`, the starting point is kept in `~/printer_data/wm-baseline/` (part of the backups), a Doctor check for it. The chamber PID fix only acts on a printer whose `printer.cfg` includes `zru-s.cfg` (the Ultra-S); the Ultra has no chamber heater and is left alone. 565 installer tests.
- Release tool 1.7.0: `apply` and `diff` merge `printer.cfg` and `saved_variables.cfg` as above instead of leaving them alone, with a preview and per-setting questions; the choices are in the history. 136 tests.

## 1.23.24

- PID results can be saved. Klipper's `SAVE_CONFIG` refuses when an included file sets `control` / `pid_Kp` / `pid_Ki` / `pid_Kd` for a heater it has to save: on the ZR Ultra-S `zru-s.cfg` does that for the chamber heater, which would also have blocked everything saved with it. New `scripts/wm_pidcfg.py` (check and fix): moves those lines into `printer.cfg` and gives each hotend `control: pid` where it has none (commented `#pid_*` values or the saved block supply the numbers; nothing else is touched; copies `<file>.wm-before-pidcfg-<time>`).
- Installer: new step 4d on install and `--update`, new `./installer.sh --pid-cfg`, a Doctor check with a fix (also in Fix everything), and a warning after `--restore` when the restored config has the problem. 554 installer tests.
- Release tool 1.6.0: new `pid-cfg [--fix]`, the same check in `status`, a warning in `apply` when a release would bring the conflict back, and a line in the test list. 126 tests.

## 1.23.23

- New `WM_BED_PID` (heated bed, TARGET=60) and `WM_CHAMBER_PID` (ZR Ultra-S chamber heater, TARGET=45) in `rpi-cfg/wm_calibration.cfg`; `WM_QUICK_START` now runs 6 stages: bed leveling, tool offsets, vibration compensation, bed PID, hotend PID, chamber PID (about 55 to 80 minutes). Bed and chamber PID are skipped when the heater is not `control: pid` or absent (Ultra has no chamber heater).

## 1.23.22

- `rpi-cfg/wm_calibration.cfg`: new `WM_QUICK_START`, a one-click hands-off calibration modeled on the K1's QUICK_START. A Fluidd window explains what runs (bed leveling, rapid tool offsets, vibration compensation, hotend PID where `control: pid`), the checks to make and the time, then runs everything and asks once to Save and Restart. Z height is offered at the end instead. 18 macros in the render test. Not tested on a real printer.

## 1.23.21

- New folder `rpi-cfg/` for config files made for the Pi (not WonderMaker's). First file: `wm_calibration.cfg`, the calibration items of the screen app (General > Maintenance) as Fluidd macros: `WM_BED_LEVELING`, `WM_PROBE_CALIBRATE`, `WM_TOOL_OFFSETS MODE=rapid|accurate`, `WM_VIBRATION_COMP`, `WM_NOZZLE_TEMP_CAL`, `WM_CAL_ALL` (asks before each stage), `WM_CAL_STOP`, `WM_CAL_HELP`, `WM_ZOFFSET_UP/DOWN`. Each refuses to run during a print or with a heater on, asks for confirmation, and turns the heaters off at the end. The G-code sequences come from the screen app's own strings. Not tested on a real printer.
- Installer: new step 4c copies `rpi-cfg/*.cfg` into the config folder and adds the include line to `printer.cfg` (copy kept); `--update` refreshes them (an edited copy is kept as `.wm-before-rpicfg-<time>`); new `./installer.sh --rpi-cfg`; the Doctor and Fix everything check that each file is there, included and the same as the repository. 538 installer tests (a jinja2 render test of every macro is part of them).
- Release tool 1.5.0: knows the Pi's own files: `apply` never changes them, the baseline and file lists skip them, `status` reports them, `apply` and `diff` warn when a release defines a macro with the same name, and the test list mentions the calibration macros. 119 tests.

## 1.23.20

- `factory/ultra-s` and `factory/ultra` `config/offset_calibrate.cfg` are now the version running on a real Ultra-S board: `NOZZLE_PREPARE` takes a temperature `S` (default 220), so the nozzle heats to `S` instead of a fixed 220 degrees. (The board's own `TM_T1/factory_settings` copy still has the fixed value; this change is on the live file only.)

## 1.23.19

- Test only: Fix everything (`--doctor --fix-all`) is checked to restore a missing `~/iso_version.txt`. 522 installer tests.

## 1.23.18

- The Doctor (and Fix everything) now checks `~/iso_version.txt`, the System version: it shows the version when the file is there, reports it when missing, and offers to copy the factory one from this repository (never replaces an existing file). 521 installer tests.

## 1.23.17

- Release tool 1.4.1: `flash` now shows an access check before it asks you to type FLASH (flash script, `hid-flash`, firmware file) and explains what to do if the bootloader device needs permissions. It changes nothing and makes no root change.

## 1.23.16

- Support bundle: the system report now also has `lsusb -t`, the serial ports in `/dev` (`ttyACM*`, `ttyUSB*`), the list of serial ports Klipper's Python sees, and the last USB/serial kernel messages. This helps when a USB device (the CAN bridge, or an ACE Pro) shows in `lsusb` but does not work.

## 1.23.15

- `~/iso_version.txt` (the System version, `System_1.1.13`) is now installed in the home folder by `installer.sh` for both models, and kept if one already exists (a copy goes to the backup folder). Release tool 1.4.0 reads it to know which version the machine has, adds a line to it after `apply` (rollback restores it), and shows it in `status` and the menu. 514 installer tests, 109 tool tests.

## 1.23.14

- Release tool 1.3.0 (`tools/wm-release/`): new `clean` command (menu `x`) that lists and then deletes every file the tool created (`~/wm-private-data`, `~/wm-firmware`, temporary files) after you type `DELETE`. Dry run unless you add `--run`; `--keep-firmware` and `--keep-backups` keep those. It never touches the printer's live files. 105 tests.

## 1.23.13

- Release tool 1.2.0 (`tools/wm-release/`): takes a new WonderMaker System release **without the factory screen board**. `fetch --from-soc FILE` decrypts a `TM_T1_SOC` file on the Pi, and `fetch --from-web [VERSION]` (menu `w`) downloads it from WonderMaker's firmware page first. Option 1 now asks where the update comes from: the old screen board or the website; the website path downloads, compares with your baseline and live files, checks MCU firmware and always asks before applying.
- Release tool: kept copies of every downloaded version in `~/wm-firmware` for offline reinstall or downgrade (`firmware`, `fetch --from-archive`, menu `a`); `compare OLD NEW` shows what WonderMaker changed between two versions (menu `v`); `settings` for the decrypt key, firmware page URL and board address (menu `g`); a guarded `flash` step for MCU firmware that is a dry run unless you add `--run` and type `FLASH` (menu `m`, never part of option 1). The SoC's own `boot.img` and kernel modules are never used on the Pi. 99 tests.
- README: new section "Tools: new WonderMaker releases", a cheat-sheet line, and `tools/wm-release/` in the repository layout.

## 1.23.12

- Release tool 1.1.0 (`tools/wm-release/`): it can now read WonderMaker's firmware download page and tell you when a newer System version than yours is published (new menu item `c` and command `check`; a line in the menu header; a note at the start of option 1). It only reads the page: nothing is downloaded or changed, and if the page cannot be read the tool carries on.

## 1.23.11

- Release tool 1.0.1 (`tools/wm-release/`): option 1 (all steps) now always asks for the board address first. The saved address is shown; press Enter to keep it or type another.

## 1.23.10

- New folder `tools/wm-release/`: a separate tool (not used by the installer) that brings a new WonderMaker System release to the Pi: it saves the board's files as a baseline, compares the new version with the baseline and your live files, checks MCU firmware (never flashes), applies the safe changes after a backup, and can roll back. Option 1 does all the steps. Run it with `python3 tools/wm-release/wm_release.py`; see its README. Before this release `--get-latest` said "already up to date" because only the tool had changed.
- The "destination path already exists" note in the README now uses `./installer.sh --get-latest`, which also works on a folder that was downloaded without git.

## 1.23.9

- Screen board, Update now: the backup it saves first is named `screen-backup-<date>-before-update.tgz`, and only the newest 5 of those are kept in `~/wm-screen-backups`. Backups you make yourself are never deleted.

## 1.23.8

- The automatic backup saved before `--update` (and before an add-on install) now also holds `~/TM_T1/factory_settings`, WonderMaker's factory settings. `--restore` puts it back when the backup has it.

## 1.23.7

- The progress bar no longer repeats itself on a timer. The repeated bar lines landed on top of questions (user name, password, IP address, yes/no) and made them hard to read. The bar is printed once at the start of each step again. A slow command still prints "still working: ... (N min N s)" every 15 seconds.
- A step that fails no longer ends with a 100% "Done" bar (ZR Tools on the Pi, ZR Tools macros).

## 1.23.6

- Screen board, Update now: waiting for Klipper on the Pi is now limited to 60 seconds and prints a line every 15 seconds ("still waiting: Klipper on the Pi is 'startup' (30 s)"). Before, it could wait up to 3 minutes without a word, which looked like a hang.
- Pressing Ctrl-C during an update (board, Pi installer) now removes the 51 MB download from /tmp.
- The error message in the board script about a missing installer file named an option that does not exist (`--get-latest`); it now says `--update`.
- Pi installer: waiting for Klipper to be ready prints a progress line every 14 seconds.

## 1.23.5

- The live bar no longer uses a pinned bottom line (it came out garbled in some phone terminal apps). While a slow step runs, the same bar is now printed again on its own line every 15 seconds with the time so far, like `[███░░░]  32%  Step 5 of 14  | 2m25s`. It works in every terminal.
- pip no longer checks PyPI for a newer pip. On a slow link that check printed "There was an error checking the latest version of pip" twice during a fresh install; it was harmless, and now it does not appear.

## 1.23.4

- The live bar now also covers the sections that had none. Pi installer: Check, Doctor, support bundle, backup, ZR Tools and Free up disk space. Screen board: clock fix, ZR Tools on the Pi, support bundle and Free up disk space.

## 1.23.3

- The progress bar is now live. In a terminal the current bar stays on the last screen line with a spinner and the time the step has taken (`[████░░░░]  20%  Step 3 of 8  / 1m05s`), so a slow step (apt, pip, a download) visibly keeps running. Before, the bar was printed once per step and stayed still. The normal log lines are unchanged, and nothing is drawn when the output is not a terminal.

## 1.23.2

- The "Free up disk space" code now lives in one shared file, `scripts/lib_free_space.sh`, loaded by both the Pi installer and the screen board script, so the two cannot drift apart.
- Screen board clock fix: the fallback that reads the time from GitHub no longer skips certificate checks (`curl -k` is gone; it reads the `Date` header over plain http). The question about automatic time sync is asked once; after a yes it is not asked again for an hour.

## 1.23.1

- `screen_board.sh --help` printed only the two-line title. It now prints the full list of options.
- `installer.sh --help` now lists `--zr-tools`.
- ZR Tools on the Pi: a `zr_tools.cfg` you edited now counts as installed as long as it still has every macro the screen needs. Before, any difference made the installer replace it (old copy kept) and restart Klipper each time. To replace it on purpose: `ZR_REPLACE=1 ./installer.sh --zr-tools`.
- README: the screen board tables and menu text now list Set up ZR Tools on the Pi, Fix the clock and Free up disk space.
- Tests always run on a throwaway copy of the repository, never on the real folder.

## 1.23.0

- Pi installer: **Free up disk space**, same as on the screen board. New last entry in the Uninstall page and the option `--free-space`: lists what is safe to erase (leftover installer downloads in /tmp, pip cache, apt package cache, old system log history, old rotated printer logs, the installer's git history) with sizes and a warning for each, you pick, it shows "This will ERASE" and asks first. Your printer data, gcode files and backups are never listed; `--yes` alone never erases.
- Pi installer: when the install finds less than 2500 MB free it now offers that cleanup on the spot and re-checks, instead of only stopping.

## 1.22.0

- Screen board installer: **Free up disk space.** New entry in the Uninstall page (menu 9, entry 5) and the option `--free-space`. It lists what is safe to erase, each with its size and a warning about what it is (leftover installer downloads in /tmp, the pip cache, the apt package cache, old system log history, old rotated printer logs, the installer's git history), you type the numbers, it shows "This will ERASE" and asks before deleting. Gcode files, settings, KlipperScreen and the factory software are never listed. `--yes` alone never erases.
- Screen board installer: when the install stops because there is not enough free space (about 1500 MB are needed), it now offers that same cleanup right there, then re-checks.
- Fixed a leak: "Update now" on the board (and `--get-latest` on the Pi) left a downloaded copy of about 50 MB in /tmp on every run. It is now removed when the command finishes, fails or is cancelled. Run Free up disk space once to clear old ones.
- Fixed: the clock step of the board install printed "why: command not found" (harmless).

## 1.21.2

- Screen board menu: Update now on a board where KlipperScreen is not installed yet (factory mode) no longer stops with "KlipperScreen is not installed here". It updates the installer files, says so, and reopens the menu on the new version; choose 1 (Install) next.

## 1.21.1

- Pi installer menu: Update, Update now on a Pi with nothing installed yet updated the installer files but left the old menu open. It now reopens the menu on the new version, like the other cases.
- Screen board menu: a backup that cannot be made (nothing to back up yet) no longer ends the update silently before the files are copied and the menu reopens.

## 1.21.0

- Screen board installer: the install now starts with the clock. If the board's time is not synchronised it asks once and turns on automatic time sync (NTP); if no time server answers, it sets the clock once from GitHub's reply. apt's expired-date check is still switched off. Also available alone: `--fix-clock` and Settings > Fix the clock.
- Screen board installer: new optional question in the install (default no): "Also check and set up the ZR Tools macros on the Pi?". It asks the Pi user name (default t13dp) and password once; the password is used for that run only and is never saved or put on a command line. It checks the Pi first and says "already installed" when nothing is missing, otherwise installs what is missing (`zr_tools.cfg`, the include line, `[save_variables]`) and restarts Klipper on the Pi (not during a print). Also available alone: `--zr-pi --pi HOST` and Settings > Set up ZR Tools on the Pi.
- Pi installer: new Add-ons entry "ZR Tools macros (screen board)" and option `--zr-tools`: checks, then installs only what is missing, restarts Klipper after a change. Both installers use the same script, `zr_tools/ensure_zr_tools_pi.sh`.

## 1.20.9

- Screen board menu: the header now shows the installer version (like the Pi installer menu).

## 1.20.8

- Screen board installer and README section 7: removed the "not tested on hardware" notes (script banner, menu title, rescue tool, USB flag, factory restore). No code changes.

## 1.20.7

- **Progress bars are weighted** by how long each step takes (the long Python and KlipperScreen builds count for most), so the percent no longer jumps. Install, update, factory restore and every uninstall end at 100%.
- **Update now has a bar** on the screen board ("Update step N of 6") and its percentages are weighted on the Pi too.
- **Uninstall has bars**: removing a single add-on or part on the Pi shows stopping, its own uninstaller, removing files and cleaning settings; the board's "Uninstall installer files" shows its bar as well.
- **Screen board Doctor:** a KlipperScreen that is still starting is waited for (up to 60 s) before it is called a problem; the "start it" fix now waits for KlipperScreen to run, shows its last log lines when it does not, and the summary says how many problems were fixed and how many are still open.
- **Screen board:** the "Change the screen driver" entry is removed from Settings (`--set-driver` still works on the command line).

## 1.20.6

- **Klipper is restarted after every install and update.** Pi installer: at the end of an install or update, if Klipper is running it is restarted and the installer waits for "ready" (and says so when Klipper reports an error). If Klipper is off (a fresh install), it is not started: `--first-start` does that after the connection check. Never during a print, and not in a dry run.
- **Screen board:** after an install or update the board restarts KlipperScreen and asks the Pi's Moonraker to restart Klipper there (skipped with a note when the Pi does not answer, is printing, or does not trust the board's address).

## 1.20.4

- **Screen board: "See what is new" downloads nothing.** It reads only two small text files from GitHub (VERSION and CHANGELOG.md) and shows the changes since your version. The full download happens only when you choose "Update now".

## 1.20.3

- **Screen board: Update now refreshes the installer folder too** (git pull, or a copy of the new files), and the menu restarts itself on the new version. Before, an update only replaced the ZR Tools panels, so the menu you were looking at stayed the old one (for example without the "See what is new / Update now" page).

## 1.20.2

- **Progress bars in the uninstall sections.** Pi: "Remove all programs" and "Erase everything" show "Removing <name> (step N of M)" with a percent bar and end at 100%. Screen board: "Back to factory mode" shows "Factory restore step N of 3". The add-ons' own uninstallers print a "still working" line every 30 seconds when they are slow.

## 1.20.1

- **Screen board: Update page** now has **See what is new** (`--check-updates`: installed and newest version and the changes in between, read-only) and **Update now**.
- **Screen board install ends with a question: "Reboot the board now?"** The default is yes (Enter reboots, after a 10 second countdown). `--no-reboot` skips the question.

## 1.20.0

- **Progress bars.** Pi install: every step shows a bar with percent and "Step N of 14" and the install ends at 100%. Pi update: "Update step N of 8". Screen board install: "Install step N of 7". Slow single steps (apt packages, Python packages, the webcam build, the KlipperScreen build) print "still working ..." with the elapsed time every 30 seconds, so a long wait does not look frozen.

## 1.19.2

- **Update on a Pi with nothing installed** no longer ends in an error: the menu says "Nothing is installed on this Pi yet, so there is nothing to update" and points to Install, after still fetching the newest installer files. `--update` gives the same plain explanation.

## 1.19.1

- **Damaged repository copy is repaired, not a dead end.** When the install uses the factory files of this repository and some of them are missing or changed (for example after a wipe of the home folder), the installer now says so and offers `git checkout -- factory` instead of stopping with "Checksum of the factory files does not match". The error message also names that command.

## 1.19.0

- **Update works without git** (like the screen board): `--get-latest` and menu → Update → Update now show your version and GitHub's, then download the newest installer folder (git pull in a clone, the GitHub tarball otherwise) before running the update. `--check-updates` now also works in a folder that came from a tar download.
- **Main menu: Dry run of the install** (entry 8, or `--install --dry-run`): asks the same questions, shows every change, changes nothing.

## 1.18.1

- **Screen board:** `bash scripts/screen_board.sh` with no options now opens the menu when run at a terminal (Install is entry 1). `--install` goes straight to the install as before.

## 1.18.0

- **Screen board: Uninstall installer files** (menu entry 9, or `--remove rescue|backups|restoredata|installer`). Removes, each after a question: the rescue tool and the on-screen Factory mode button; screen backups, support bundles and the board report; the saved restore data (`~/wm-screen-backup`, refused while KlipperScreen is installed because a factory restore needs it, unless `--force`); the downloaded installer folder. KlipperScreen itself is only removed by Back to factory mode.

## 1.17.0

- **Screen board menu is now complete** (`bash scripts/screen_board.sh --menu`): Install, **Update** (newest ZR Tools screen files from GitHub, backup first), **Check and fix** (doctor with Fix everything, status, last log, restart the screen, board report, pre-check), **Backup and restore** (screen settings, safety copy before a restore), **Settings** (Pi address, screen driver, network and system with time zone and host name), **Support bundle**, dry run and factory mode. Each entry is also an option: `--update`, `--doctor [--fix-all]`, `--backup`, `--restore-backup [N]`, `--support-bundle`, `--log`, `--restart-screen`, `--system [tz:Zone|host:name]`. Not yet tried on the real screen board.

## 1.16.0

- **Menu for the screen board:** `bash scripts/screen_board.sh --menu` has numbered entries for install, status, changing the Pi address, changing the screen driver, back to factory mode, a read-only board report, the pre-check and a dry run. New option `--set-driver modesetting|fbdev` switches the driver without reinstalling. Not yet tried on the real screen board.

## 1.15.1

Fixes from a full test on a real Raspberry Pi (install, every section, uninstall one by one).

- **Webcam starts only with a camera.** crowsnest is installed and enabled as before, but only started when a camera is found in `/dev/v4l/by-id`. Without one, Status shows "waiting for a camera" and the Doctor does not complain; with one, the Doctor offers to start it.
- **Check and fix → Fix everything** (`--doctor --fix-all`): the Doctor applies every safe fix after one question.
- **Self-test waits for Moonraker** (up to 30 s) instead of warning right after a restart. Waiting for Klipper stops early when it stays in error/shutdown.
- **Doctor checks Spoolman and Shake&Tune.** The "not part of this install" note names Spoolman.
- **Removing the webcam** answers crowsnest's own "(y/N)" question for you, so its uninstaller finishes.
- **Remove all programs / Erase everything** also remove the Python 3.9 the installer added (asks; a Python you had before is never touched).
- **Quieter:** no more "Unit not loaded" messages when a service is already gone; no "Needs administrator rights" line for system files; changing the host name updates `/etc/hosts` first (no "unable to resolve host"); First start says when Klipper was already running.

## 1.15.0

- **Backup before every update.** `--update` and every add-on install from the menu first save config, calibration and database to `~/wm-backups/...-before-update-<date>.tgz` (newest 5 kept, `--no-backup` skips it).
- **Status page** (`--status`, Check and fix → Status): one read-only overview of services, Klipper, Pi health, CAN ids, add-ons, newest backup and log.
- **Network and system page** (Advanced): show host name, time zone, clock and addresses; set the time zone (`--set-timezone`) and the host name (`--set-hostname`), each after a confirmation.
- **New add-on: Spoolman** (filament spool tracking, shown in Fluidd). Menu → Add-ons or `--spoolman on`; removal keeps your spool database unless you ask for it, and Erase everything deletes it. Not yet tried on a WonderMaker printer.

## 1.14.2

- The Ultra factory files carry the same real CAN uuids as the Ultra-S ones (see 1.14.1), copied from the owner's printer. On other printers they will not match the boards: `--first-start` still checks them, and toolheads and the hub need their own uuids.

## 1.14.1

- **The Ultra-S factory files now carry the real CAN uuids** of the owner's printer, copied from its working board (main board, hub, extruder, T0-T3 and the load cell) instead of empty or placeholder values. A repo install on that printer's hardware therefore starts with the right ids and no "Duplicate canbus_uuid". **They belong to those boards:** on a different printer they will not be on the bus, so `--first-start` still checks them (it only changes the main board's uuid) and a toolhead or the hub still needs its own uuid (`scripts/read_write_can_id.sh`).

## 1.14.0

- **Obico is installed with its own plain installer** (`git clone` then `./install.sh`, as on Obico's wiki). The installer no longer asks for the Obico server and no longer passes server or Moonraker flags: Obico's installer asks that itself. `--obico-server` is removed. Like OctoApp and OctoEverywhere, it starts only in a terminal without `--yes`; otherwise it is downloaded and the command to finish is printed (`cd ~/moonraker-obico && ./install.sh`).

## 1.13.2

- **Installing an add-on from the menu no longer updates the whole system.** Menu → Add-ons used a full update, which also refreshed system packages, services, nginx, the can0 rule, Python packages and the Fluidd panel (and restarted nginx). It now installs only the add-on you picked (`./installer.sh --update --only-addon NAME --NAME on`). A plain `./installer.sh --update` still updates everything.

## 1.13.1

- **Fixed "Duplicate canbus_uuid" after installing from the repository.** The factory files ship an empty `canbus_uuid:` for the four toolheads and the load cell, and Klipper treats every empty one as the same id, so it refused to read the config. The installer (install, `--first-start`, `--doctor`, `--repair`) now gives each a unique placeholder (`b00000000000` to `b30000000000` for T0-T3, `b40000000000` for the load cell), keeping a copy in `~/wm-rpi-backup/uuid-*`. Set the real uuid when the toolhead is connected (`scripts/read_write_can_id.sh <0-3> 1 <uuid>`). Real uuids are never changed. Installing from the printer (option 1) was not affected.

## 1.13.0

- **Install no longer asks about Obico, OctoApp and OctoEverywhere.** They need an account and their own questions, so they are offered only under Add-ons (or `--obico on`, `--octoapp on`, `--octoeverywhere on`). The plan shows them as "no (add later: menu, Add-ons)".
- **New add-on: Klippain Shake&Tune** (by Frix-x, pinned to a tested commit). Menu → Add-ons, or `--shaketune on`. It does the steps of the maker's `install.sh` without its restarts of Klipper and Moonraker: `libopenblas-dev`, Python packages in `~/klippy-env`, the link in Klipper's extras, `shaketune.cfg` + `[include shaketune.cfg]` (printer.cfg copy kept), and the Fluidd update entry. If the import check fails it is not linked and Klipper stays unchanged. Removal: Uninstall → Shake&Tune (or `--remove shaketune`), also covered by All programs and Erase everything. Not yet tried on a WonderMaker printer.

## 1.12.0

- **Uninstall → Erase everything** (`--remove erase`): removes every program, the system files, NetworkManager's switch (if the installer made it), your printer data (`~/printer_data`, `~/TM_T1`) and every installer file (backups, support bundles, logs, the copy from the old board, moved-aside folders, saved copies, the records). It lists all of it first, makes no backup, and you must type `ERASE`. Only the installer folder, and the log of that run, stay.
- The old "Everything above" entry is renamed **All programs**, because it never included your data, the clean-up files or NetworkManager. It still keeps those, and its list says so.

## 1.11.0

- **The installer now keeps a log.** Every run that changes something is written to `~/wm-install-logs/installer-<what>-<date>.log` (its path is printed at the end). At a terminal the installer re-runs itself inside `script`, so the screen behaves as before and everything shown is recorded; without a terminal it uses `tee`. Colour codes are removed, progress bars are reduced to their last line, passwords and tokens become `<removed>`, files are private, the newest 20 are kept.
- `./installer.sh --show-log` (and Advanced → Show the last log) shows where the newest log is and its last 40 lines. The support bundle includes the newest log. Uninstall → Clean up installer files can delete the logs.

## 1.10.3

- **Leftovers after Uninstall are gone.** Seen after "Everything" and the clean-up: `~/crowsnest-env`, `~/octoeverywhere-env`, `~/octoapp-installer.log`, `~/octoeverywhere-installer.log`, `~/wm-stage` and `~/TM_T1` stayed. Now: crowsnest's environment, the Octo add-ons' installer logs and config files are removed with the add-on; the copy from the old board (`~/wm-stage`) is a clean-up group (type `DELETE`); `~/TM_T1` goes with "My printer data".
- **Files the Pi user cannot delete** (left root-owned by an uninstaller) are deleted with `sudo` automatically; the installer says "Needs administrator rights" and, if even that fails, prints the exact `sudo rm -rf` command.
- **Uninstall "Everything" asks more clearly:** it first lists what is installed and will be removed, each add-on's own uninstaller still runs (and asks its own questions at a terminal), you type `REMOVE`, and at the end it lists what is still on the Pi (printer data, backups, the installer folder) and which menu entry removes each.

## 1.10.2

- **Removing an add-on now runs its own official uninstaller first:** KlipperScreen (`scripts/Uninstall.sh`), crowsnest (`make uninstall`), OctoApp and OctoEverywhere (`./uninstall.sh`; at a terminal you answer its own questions). Before, OctoApp and OctoEverywhere only did it at a terminal, and KlipperScreen and crowsnest were removed by the installer alone. Obico has no uninstall script (`./install.sh -u` only prints the steps), so its listed steps are done, now including `systemctl reset-failed`.
- After the official uninstaller the installer finishes anything it left behind, and removes the add-on's `[update_manager ...]` section from `moonraker.conf` (a dated copy is kept), so Fluidd stops listing a removed add-on.

## 1.10.1

- **Obico used the website although a self-hosted server was chosen.** Obico's installer keeps an existing `moonraker-obico.cfg` and ignores the server it is given. The installer now checks that file: when its server differs from your choice, the file is reset (`-f`, Obico keeps a dated copy) and you are told to link the printer again. After the install it checks again and corrects the address if needed.
- `./installer.sh --update --obico-server URL` now changes the server of an Obico that is already installed (copy of the old settings, old link token set aside, service restarted, link command shown).
- Removing Obico sets `moonraker-obico.cfg` aside so a new install asks for the server again.

## 1.10.0

- **NetworkManager as an option** for KlipperScreen's Network panel (`--network-manager on|off`, menu: Add-ons). Default **off**. It is asked when you add a touchscreen, with a note that switching to NetworkManager can drop the network connection. KlipperScreen's own script reboots the Pi when it installs NetworkManager, so the installer does it itself: it installs and enables NetworkManager, turns dhcpcd off, and restarts nothing, so the change starts at the next reboot. If NetworkManager is already running, nothing is changed.
- Add it later with `./installer.sh --update --network-manager on` or from Add-ons. Go back with `./installer.sh --remove network-manager` (or Uninstall in the menu), which enables dhcpcd again; it only does that when this installer made the switch.
- The plan lists "network manager" with yes or no.

## 1.9.2

- The plan shown before an install now lists every optional program with yes or no: panel, webcam, timelapse, shell command, touchscreen, Obico (with the chosen server), OctoApp and OctoEverywhere. Before, Obico, OctoApp and OctoEverywhere were missing. The list is one array (`PLAN_OPTIONS`), and a test fails when an installer answer is saved but not in that list, so a program added later cannot be left out of the plan.

## 1.9.1

- `./installer.sh` with no options now always opens the menu at a terminal, also on a Pi with nothing installed. Before, a Pi without an install record went straight to the install questions. Choose 1 in the menu to install; `--install` still skips the menu.

## 1.9.0

- **Advanced → Start Klipper again** (`--start-klipper`): undoes *Stop Klipper* (enables Klipper at boot and starts it) without the hardware checks. *First start* is still there for the full checks.
- **Uninstall → Clean up installer files** (`--remove cleanup`): delete settings backups, support bundles, folders moved aside by installs, old Fluidd copies, config safety copies (`*.wm-*`), add-on download copies, the installer records, or the installer folder itself. Sizes are shown, your printer data is never listed, and anything that may be the only copy needs you to type `DELETE`.

## 1.8.0

- **PolKit warning fixed.** Fluidd showed "PolKit warnings detected" (`org.freedesktop.packagekit.* is not registered`) because the `packagekit` package was missing. The installer now installs it, together with Moonraker's PolicyKit rule. It also asks Moonraker for its warnings after every install, update and repair, every time the menu opens, and in `--doctor` (which could not fix this before), and repairs the problem when Moonraker reports it. During a print it only tells you. If PackageKit cannot be installed, it sets `enable_system_updates: False` in `moonraker.conf` (a copy is saved).
- **Restore from a numbered list.** The menu shows the folder the backups are kept in and lists the backup files there; you press a number. A last entry takes a path to a file somewhere else.
- The "Touchscreen settings" menu page is gone (the touchscreen can still be installed and removed under Add-ons).
- **New Uninstall section** in the menu, and `--remove NAME` now covers everything the installer installs: `screen`, `webcam`, `timelapse`, `shell-command`, `obico`, `octoapp`, `octoeverywhere`, `fluidd`, `moonraker`, `klipper`, `data` (backup first, type `DELETE`), `system` and `all` (type `REMOVE`; keeps your printer data and backups).

## 1.7.0

- Copying from the old board over SSH asks for the password **once**. Before, klipper, moonraker and the data were three more connections, so the password was asked for each. All steps now share one connection (SSH ControlMaster), which is closed at the end.
- The Klipper gcode shell command extension is installed automatically, with no question (`--shell-command off` skips it). It still does nothing until you add a `[gcode_shell_command ...]` section.
- Obico: the installer now asks whether to use Obico's website (app.obico.io) or your own self-hosted server, and asks for the server address. It is remembered. `--obico-server URL` gives it up front; `--yes` uses app.obico.io.

## 1.6.0

- New numbered menu: `./installer.sh --menu`, which also opens by itself when you run `./installer.sh` with no options at a terminal on a Pi that is already installed (a first-time install is unchanged; `--install` skips the menu). Sections: install, update (see what is new, then update), add-ons, check and fix, backup and restore, touchscreen settings, advanced. Each entry runs the same installer option, so there is one code path.
- Status on top (version, services, newer version on GitHub, print in progress) and a one-line help text per entry. A running print still blocks every change.
- Add-ons page with a status per add-on; install or remove from the list. New `--remove obico|octoapp|octoeverywhere|shell-command` (asks first). New `--webcam on|off` and `--timelapse on|off`.
- Warns if KIAUH is on the Pi.

## 1.5.0

- New optional remote-access add-ons, each asked during install (default no): Obico for Klipper (`--obico on`), OctoApp (`--octoapp on`, its method 1c: git clone + install.sh) and OctoEverywhere (`--octoeverywhere on`). They are installed with the makers' own installers, pointed at this Pi's Moonraker, in their own Python environments. Linking to your account is left to you and explained on screen. `printer.cfg` is copied before Obico adds its include line.
- `--update` does not re-run them once installed; `--doctor` checks them; `--uninstall` leaves them and tells you how to remove them.
- Not yet run on a real Pi.

## 1.4.0

- New optional add-on: the Klipper gcode shell command extension (`RUN_SHELL_COMMAND CMD=name`, module by Arksine, GPLv3, bundled as `config/gcode_shell_command.py`). Asked during install (default no), or `./installer.sh --shell-command on|off`. It is copied into `~/klipper/klippy/extras/`, put back by `--update`, checked by `--doctor` and removed by `--uninstall`. It does nothing until you add a `[gcode_shell_command ...]` section to `printer.cfg`.

## 1.3.0

- New `./installer.sh --check-updates`: read-only, lists the changes on GitHub that your copy does not have yet and the new version number, then says how to update.
- `--update` and the ZR Tools install script now keep your old `zr_tools.cfg` as `zr_tools.cfg.zrbak_<date>` when it differs from the new one, instead of replacing it silently. Nothing else in `printer_data` is touched.

## 1.2.0

- KlipperScreen / ZR Tools now fits 5 inch (800x480, 480x800) and 7 inch (1024x600, 600x1024, 800x480) screens, wide and tall. On a tall screen the toolhead cards sit 2 x 2, the toolhead page stacks, and the mapping and tabs use short labels.
- Buttons, text and colour dots scale from the real pixel size (75% to 150%); 800x480 and 1024x600 look as before.
- Tiny screens (short side 400 px or less, 480x320 and 480x272): Calibrate moves from the tab bar into More. Wide screens (1280x800 and up): 4 tiles per row.
- Auto size looks at both sides of the screen. `--screen-test` also shows whether the screen is wide or tall.
- Tests for the screen profile, the scaling and every page at 11 sizes. The tall, tiny, wide and 7 inch layouts have not been seen on a real screen yet.

## 1.1.0

- Version renumbered to 1.1.0 so it matches [acepro-any-klipper](https://github.com/ducati1198/acepro-any-klipper) 1.1.0. No code changes. The earlier numbers below are kept as history.

## 0.13.24

- README (top): the ACE Pro is not an MMU here; it is used only to load and unload the filament and to dry it.

## 0.13.23

- README (section 5): note that the ACE 2 Pro (RS-485, needs Anycubic's USB-to-RS485 signal cable) is not tested on this printer, with a link to what is known in the panel repo.

## 0.13.22

- `docs/wondermaker-plus-notes.md`: notes on how the Wondermaker+ community config differs from the factory config and from this printer, with a plan to review it after the new MCU is installed. Nothing from it is installed.

## 0.13.21

- `docs/WIRING.md`: added the USB-A to MX1.25 4-pin camera cable (at least 1 m long, photo and wire colours) and a second photo of the USB-A to JST-XH cable for the main board; both photos are also in the README hardware list.

## 0.13.20

- Rescue tool: the settings snapshots in `~/wm-screen-backup/rescue-snapshots` now belong to the board user (they were root-owned, so deleting them asked about write-protected files).

## 0.13.19

- `scripts/screen_board.sh`: the board reboots at the end of the install (10 second warning, `--no-reboot` skips it).
- Factory restore: the rescue window's confirmation, its progress page, the Factory mode button on the System page and the README now say that the screen turns black for about 5 minutes before the WonderMaker app appears.
- Tested on one board: the factory restore from the rescue window brought the WonderMaker app back and Klipper started by itself (`klipper`, `makerbase-client`, `moonraker`, `nginx` all active).
- New folder `usb_flags/` with the empty `WM-RESCUE` and `WM-FACTORY` flag files and a zip for each (one file per zip), linked from the README. Still not tested on hardware.

## 0.13.18

- README: the USB flag (`WM-FACTORY` / `WM-RESCUE`) is marked as not tested on hardware. On the one board tested, the USB-A port detected no stick at all (several sticks, kernel error -32 while reading the device descriptor; the board's internal USB hub showed the same error on another port at boot), so only the automated tests cover it. The rescue window (manual, after 3 failed starts, with confirmations and progress bars) was tested on the board.

## 0.13.17

- Rescue window: it now fills the whole screen. On the board's own screen server there is no window manager, so the full-screen request was ignored and the window opened smaller than the screen. It now sets its size to the screen size.

## 0.13.16

- Rescue window (screen board): every button now asks for a confirmation first (Restart KlipperScreen, Reboot board, Factory restore, Reset KlipperScreen settings, Reinstall KlipperScreen files). Factory restore, Reset settings and Reinstall show a progress bar with the current step (`STEP n/4` lines from `wm-screen-rescue act`); the end of a factory restore, while the board reboots, is an estimated bar. **Not yet tested on hardware**; the first rescue window test (manual open, 3 failed starts) worked.

## 0.13.15

- ZR Tools touchscreen: new look (design A) on every page: tall toolhead cards with status chips and round spools drawn in the filament colour, a rounded bottom tab bar, a toolhead page with a big action grid, a bigger colour preview and dots on the Edit filament page (colour first, then material). The default size is now **Comfortable** (`zr_screen.conf`, `screen_board.sh`, `installer.sh`); existing settings files are kept as they are.
- The System page shows the Fluidd address from the Pi address that was entered on the screen board (`moonraker_host` in `KlipperScreen.conf`); on the Pi itself it still shows the Pi's own name.
- `scripts/screen_board.sh`: the printer in `KlipperScreen.conf` is named `WonderMaker` (it was `wmpi`), so the title bar reads "WonderMaker". Existing boards keep their name until the script is run again. **Looks tested on one screen board with a simulated Klipper; not yet tested with a real printer, on a 7 inch screen, or with the card grid, light theme and other looks.**
- README: new screenshots of every ZR Tools page.

## 0.13.14

- README and docs: wording written for any working printer (no mention of a dead or replacement board; "original screen board" instead of "old board"; the main board is "the printer's main board"). The ZRU-B001 note now says it is expected while the main board is not connected or powered.

## 0.13.13

- README: new top part with a Quick start, an everyday cheat sheet (install, update, check, repair, backup, restore, undo, uninstall), a "How it works" diagram (`docs/img/how-it-works.svg`) and a short "If something goes wrong" table. The detailed sections are unchanged.

## 0.13.12

- README fixes to match the installer: what was tested, PolicyKit and nginx home-folder steps in the table, pinned crowsnest/timelapse commits, what Fluidd shows without the main board, the screen-board `cd` step, three new troubleshooting rows, complete repository layout.
- `.gitignore` now ignores `__pycache__`; the committed `.pyc` files are removed from git.

## 0.13.11

- Removed the "disk image" and "stage folder" sources from the installer (`--from-image`, `--from-stage`, menu options 2 and 3) and the script `scripts/extract_from_image.sh`. The two sources left are the old board over SSH and the factory files in this repository. (`--from-stage` still exists, undocumented, for the tests.)

## 0.13.10

- README: the OrcaSlicer plugin step says the file can also be downloaded from the orca_plugin folder of the panel repository.

## 0.13.9

- README: links to wm-ultra-fluidd-acepro-panel and its OrcaSlicer plugin at the top, in the plugin section and in the credits.

## 0.13.8

- README: step-by-step install of the OrcaSlicer plugin (section 5), including the panel repository install it needs on the Pi.

## 0.13.7

- README: section 5 now mentions the OrcaSlicer plugin of the panel repo (works without an ACE Pro; not yet tested).

## 0.13.6

- Fix: the PolicyKit check could not see the rule (its folder is root-only), so it reported a false problem. It now checks with sudo.

## 0.13.5

- Fix: Fluidd showed "PolKit warnings detected / Moonraker not authorized for PolicyKit" on a fresh Pi, so it could not restart services. The installer now installs Moonraker's PolicyKit rule (its own script), `--repair` re-installs it, and `--doctor` checks for it.

## 0.13.4

- Fix: the installer reported 7 WonderMaker modules as "do not import" on a good install (a false alarm: they were tested from the wrong folder, not the way Klipper loads them). They are now imported as `extras.<name>`, like Klipper does.

## 0.13.3

- Fix (found on the first real Pi install): on Debian 12 the home folder is private, so nginx answered "403 Forbidden" and Fluidd did not open. The installer now runs `chmod o+x ~` (pass-through only), `--repair` does the same, and `--doctor` checks that the Fluidd page opens.

## 0.13.2

- Pi installer: `--screen macros` adds only the ZR Tools macros to `printer.cfg` (no KlipperScreen on the Pi), for people who use the WonderMaker screen board. Answering no to "Add a touchscreen?" now offers it. `--screen-remove` keeps the macros.

## 0.13.1

- ZR Tools screen: slim, uniform buttons (icon beside the label, no vertical stretching), a smaller Back button, smaller tiles and tab bar, so more options fit before you scroll.

## 0.13.0

- ZR Tools screen: the toolhead page now scrolls as one page (summary, six actions, Edit filament). New filament editor with material chips, round colour swatches (the RGB sliders only appear under Custom colour) and a visible scrollbar. New Look setting: Soft (default), Flat, Bold, Classic, each in dark and light. Not yet tested on hardware.

## 0.12.1

- Screen board: Wi-Fi page (`zr_tools/wifi_panel.py`, installed as KlipperScreen's Network panel) using `wpa_cli`, because the stock panel needs NetworkManager. The installer asks only for the Pi's IP address (no default). New **Pi address** page on the screen (More menu and the start screen) to change it without SSH; `--set-pi <address>` does the same from a shell.

## 0.12.0

- `scripts/screen_board.sh`: there is no Pi check at all any more (the install never contacts the Pi; `--pi` only sets the address written into KlipperScreen.conf, default wmpi.local). It no longer needs a virtual console. X runs on its own seat (`seat1`) with display, framebuffer and touch assigned by udev rules, started by a custom `KlipperScreen.service` (no tty0, no chvt). Restores the missing X keyboard data (`xkb-data`). The udev rules are recorded and removed on uninstall/factory restore. **Not yet tested end to end on hardware.**

## 0.11.0

- New: `scripts/screen_board.sh` runs KlipperScreen on the original WonderMaker screen board (Debian 11) and connects it to the Pi. It stops and disables the factory screen app and the Klipper/Moonraker services (nothing deleted, state saved), uses `apt-get install --no-upgrade` only, keeps WonderMaker's held X server, and falls back from the modesetting to the fbdev driver if X does not start. **Not yet tested on hardware.**
- Go back: on-screen **Factory mode** button (ZR Tools > More > System), `--factory-restore` (`--uninstall-klipperscreen` does the same, so the screen never stays black), `--status`, `--dry-run`. Refuses if the Pi does not answer or a print is running.
- New on the Pi: `./installer.sh --screen-remove`.
- `scripts/screen_board_precheck.sh`: one read-only script you run from your Mac before installing on the screen board; checks display/touch/console, resources, services, X server, the Pi, network and an apt dry run, and prints READY or NOT READY. `--backup` saves the board config to the Mac.
- `scripts/screen_board_inspect.sh`: read-only report of the screen board. Panel hardware facts in `docs/HARDWARE.md`.

## 0.10.0

- New: optional touchscreen. The installer asks "Add a touchscreen?" (default yes; `--screen on|off`) and installs KlipperScreen pinned to commit 34610ce with X11 (`--screen-backend x11|weston|cage`), plus the ZR Tools pages: Toolheads, Filament, Climate, Calibrate, ACE Pro (only if present), More, Settings.
- Layouts `tabs` and `grid`, compact/comfortable density from the detected screen size, light/dark theme; stored in `zr_screen.conf`; `--screen-layout`, `--screen-test`.
- `--update`, `--repair` and `--doctor` look after the screen files. **Not yet tested on hardware.**
- The old "copy ZR Tools to ~/zr_tools" step is replaced by this.

## 0.9.1

- Raspberry Pi 400 removed from the docs and pictures: the target is a regular Raspberry Pi 4 or 5.

## 0.9.0

- The `fluidd/` folder (zip, checksum, patch) is removed. The panel only comes from `wm-ultra-fluidd-acepro-panel`. If it cannot be downloaded the install goes on without the web page and says to run `--update` when online.

## 0.8.1

- Option 1 (copy from the old board over SSH) is now marked as the recommended source, in the README and in the installer menu.

## 0.8.0

- The Fluidd panel is downloaded from `ducati1198/wm-ultra-fluidd-acepro-panel` (`fluidd/` on `main`) at install and by `--update`, verified with the `.sha256` published there. The copy in `fluidd/` is only the offline fallback.

## 0.7.1

- The installer now enables and starts Klipper, Moonraker, nginx and crowsnest at the end of every install (failed checks are reported, not blocking). `--no-start` starts nothing.
- Fix: `klipper.service` had no `[Install]` section, so enabling it did nothing at boot. Added.

## 0.7.0

- New: `--first-start` (hardware checks, `canbus_uuid` fix, then enables and starts Klipper and the other services when everything passes; the installer does this automatically at the end), `--hw-test`, `--doctor`, `--repair`, `--update`, `--undo`, `--backup`, `--restore`, `--support-bundle`, `--no-start`, `--force`.
- Pre-flight checks (internet, power, clock), a plan screen before any change, saved answers (`~/wm-rpi-backup/install.conf`), a print guard, a config validator and a self-test after install.
- `--enable-klipper` is now the same as `--first-start`.

## 0.6.0

- Separate folders `factory/ultra/` and `factory/ultra-s/`.
- The installer asks for the model (or `--model`) and sets `printer.cfg` for it with every source (board, image, folder, repo).

## 0.5.0

- Klipper and Moonraker are plain folders in `factory/zru/` (the earlier archives were never pushed).
- WonderMaker's 5 compiled modules, `c_helper.so`, the MCU firmware and `hid-flash` are now included, with checksums and a takedown note. `--from-github` no longer needs a modules folder.

## 0.4.1

- crowsnest is now v5.0.12 (latest release) instead of WonderMaker's 2023 version. Same install method, config keys and service. Moonraker timelapse was already the latest upstream version.

## 0.4.0

- Exact package lists of WonderMaker's `klippy-env` (numpy 2.0.2 etc.) and `moonraker-env`, read from the factory image.
- Installer steps for crowsnest and Moonraker timelapse, pinned to the commits in WonderMaker's image; `timelapse.cfg` added to the factory settings (printer.cfg includes it).

## 0.3.0

- One factory set for Ultra and Ultra-S (`factory/zru/`); `--model ultra|ultra-s` switches `[include zru-s.cfg]`.
- Added `printer1-4.cfg` variants, WonderMaker helper scripts, MCU update scripts and checksums.
- Wiring guide with annotated photos of the red USB connector (DM, DP, G; VIN is 24 V, not connected).

## 0.2.0

- New source: factory Klipper, Moonraker and settings of the Ultra-S inside the repo (`--from-github`), with SHA256 checks. Compiled WonderMaker modules are not included; they are verified against factory checksums when you supply them.
- `scripts/stage_from_repo.sh`, `factory/`, `docs/WIRING.md`.
- `--enable-klipper` refuses to start when the compiled modules are missing.

## 0.1.0

- First version: Pi installer (source from old board, disk image or stage folder), Moonraker and nginx services, can0 rule, Klipper kept off until `--enable-klipper`.
- Scripts: `pull_from_board.sh`, `extract_from_image.sh`, `board_check.sh`.
- Fluidd v1.37.7 with the WonderMaker Toolheads panel and the Choose toolheads window.
- Optional ZR Tools KlipperScreen panel.
- Tests with a fake home and a synthetic disk image. Not yet tested on a real printer.
