# Changelog

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
