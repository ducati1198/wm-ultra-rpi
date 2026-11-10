<div align="center">

# WonderMaker ZR Ultra / Ultra-S: Raspberry Pi replacement

**Replace screen/host board with a Raspberry Pi running WonderMaker's own Klipper, Moonraker and Fluidd.**

**Related projects:** [wm-ultra-fluidd-acepro-panel](https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel) (Fluidd Toolheads card, ACE Pro, [OrcaSlicer plugin](https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel/tree/main/orca_plugin)) · [acepro-any-klipper](https://github.com/ducati1198/acepro-any-klipper) (ACE Pro on any Klipper printer)

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE) ![Status: untested on hardware](https://img.shields.io/badge/status-untested%20on%20hardware-orange)

</div>

> **The ACE Pro is not an MMU.** The WonderMaker has four toolheads that do the switching, so the ACE Pro here is used **only to load and unload the filament and to dry it**.

> **Status:** tested with a fake home folder, on a fresh Raspberry Pi (install, doctor, Fluidd, Moonraker, Klipper loading the config) and on one WonderMaker screen board. **Not tested with a running printer yet.** Use at your own risk, see the [full disclaimer](#disclaimer-use-at-your-own-risk).

## Contents

- [Quick start](#quick-start) · [Everyday cheat sheet](#everyday-cheat-sheet) · [How it works](#how-it-works) · [If something goes wrong](#if-something-goes-wrong)

Details:

1. [Disclaimer](#disclaimer-use-at-your-own-risk) · [What you get](#what-you-get)
2. [Hardware](#2-hardware)
3. [Install](#3-install) (including [the installer menu](#the-installer-menu) and the [command table](#34-command-table))
4. [When the main board is connected](#4-when-the-main-board-is-connected)
5. [Fluidd (web panel and ZR Tools)](#5-fluidd-web-panel-and-zr-tools) (including the [OrcaSlicer plugin](#install-the-orcaslicer-plugin-optional-works-without-an-ace-pro))
6. [KlipperScreen on the Raspberry Pi (touchscreen)](#6-klipperscreen-on-the-raspberry-pi-touchscreen)
7. [KlipperScreen on the WonderMaker screen board (optional)](#7-klipperscreen-on-the-wondermaker-screen-board-optional)
8. [Go back / uninstall](#8-go-back--uninstall)
9. [Troubleshooting](#9-troubleshooting)
10. [Repository layout](#10-repository-layout)
11. [Credits and license](#11-credits-and-license)

More:

- [Tools: new WonderMaker releases](#tools-new-wondermaker-releases-toolswm-release) (`tools/wm-release`)
- [The menu](#the-menu)
- [Backup before every update](#backup-before-every-update)
- [Status page and Network and system](#status-page-and-network-and-system)
- [Klipper gcode shell command (installed automatically)](#klipper-gcode-shell-command-installed-automatically)
- Optional add-ons: [Anycubic ACE Pro](#anycubic-ace-pro-optional-add-on) · [Spoolman](#spoolman-optional-add-on) · [Klippain Shake&Tune](#klippain-shaketune-optional-add-on) · [Remote access: Obico, OctoApp, OctoEverywhere](#remote-access-add-ons-obico-octoapp-octoeverywhere-optional)

## Quick start

The idea: a Raspberry Pi takes over the job of the WonderMaker screen/host board (it runs Klipper, Moonraker and the web page). You copy WonderMaker's own software and your settings to it once; after that the Pi runs everything.

1. **Write the SD card** with Raspberry Pi Imager: *Raspberry Pi OS (Legacy, 64-bit) Lite* (Debian 12 Bookworm), username **`t13dp`**, SSH on, your Wi-Fi or a cable. Details in [2.1](#21-what-you-need).
2. **Log in as `t13dp` and run the installer.** It opens a menu: choose **1) Install or reinstall** (or run `./installer.sh --install` to skip the menu). It asks which printer you have, then where the WonderMaker software comes from (the original screen board's address, or the factory files in this repository):

   ```bash
   sudo apt-get update && sudo apt-get install -y git
   git clone https://github.com/ducati1198/wm-ultra-rpi.git && cd wm-ultra-rpi
   chmod +x installer.sh && ./installer.sh
   ```

   The menu (press **2** for Update to see its second page):

   ![Installer menu](docs/img/menu-pi-main.png)
   ![Update page](docs/img/menu-pi-update.png)

   *You should see:* a list of steps with a green tick each, then a self-test, then "next steps". It builds software, so let it finish.
3. **Open `http://<pi address>/` in a browser.** *You should see Fluidd with the Toolheads card.* If the printer's main board is not connected or powered yet, Fluidd shows `ZRU-B001: Screen–Mainboard communication error`. That is expected.

   ![Fluidd Toolheads card](docs/img/fluidd-toolheads-card.png)
4. **Connect the printer:** connect the USB cable between the Pi and the main board ([wiring](docs/WIRING.md)), power the printer and run `./installer.sh --first-start`. It checks the connection first and only then starts Klipper.

Optional later: [use the original screen board as the touchscreen](#7-klipperscreen-on-the-wondermaker-screen-board-optional) or [add the ACE Pro panel and the OrcaSlicer plugin](#5-fluidd-web-panel-and-zr-tools).

## Everyday cheat sheet

Run these in `~/wm-ultra-rpi` on the Pi.

| I want to... | Run | What happens to my data |
|---|---|---|
| **Check** that everything is fine | `./installer.sh --doctor` | Nothing changes unless you accept a fix |
| **Fix everything** at once | `./installer.sh --doctor --fix-all` | Asks once, then applies every safe fix |
| Do any of this from a **menu** | `./installer.sh` (opens the menu, also on an empty Pi) or `./installer.sh --menu` | Same as the options below; nothing changes until you pick something and confirm |
| See what is new first | `./installer.sh --check-updates` | Nothing is changed |
| **Update** to the latest version | `./installer.sh --get-latest && ./installer.sh --update` (works with or without git) | Kept: `printer_data`, calibration, settings |
| Take a **new WonderMaker System release** (from their website, no screen board) | `python3 tools/wm-release/wm_release.py` then **1** → `web` | Plan first; your changes kept; backup before you type `APPLY`. See [Tools](#tools-new-wondermaker-releases-toolswm-release) |
| **Repair** a broken service, nginx or can0 rule | `./installer.sh --repair` | Kept |
| **Back up** my settings | `./installer.sh --backup` | Saved to `~/wm-backups/` as a private `.tgz`. Copy it off the Pi. |
| **Restore** a backup | `./installer.sh --restore FILE` | A safety copy is made first |
| **Undo** the last install | `./installer.sh --undo` | Folders the installer moved aside come back (`~/wm-rpi-backup/`) |
| **Uninstall** | `./installer.sh --uninstall` | Removes the services, nginx files and can0 rule it added. Your folders in `~` stay. |
| **Preview** any of the above | add `--dry-run` | Nothing changes |
| See the **log** of the last run | `./installer.sh --show-log` | Prints where the log is (`~/wm-install-logs/`) and its last 40 lines |
| **Ask for help** | `./installer.sh --support-bundle` | One `.tgz` with passwords, tokens, Wi-Fi and private IPs removed |

The full command list is in [3.4](#34-command-table). The installer **never flashes any board** and never writes to the original screen board.

## How it works

![How it works](docs/img/how-it-works.svg)

1. The **main board stays in the printer**. It carries the USB-CAN bridge, and the toolheads and filament hub stay on its CAN bus.
2. The **Pi takes over from the screen/host board**: it runs WonderMaker's own Klipper and Moonraker, so the printer behaves as before.
3. **Fluidd** (the web page) is served by nginx on the Pi. Open it from a phone or computer on your network.
4. The installer **copies the software and your settings once** from the original screen board (or from the factory files in this repository). After that the Pi does not need it.
5. An **optional screen** (KlipperScreen on the Pi, or on the original screen board) shows the same ZR Tools pages as the original touchscreen.

## If something goes wrong

| What you see | What to do |
|---|---|
| Fluidd shows `ZRU-B001: Screen–Mainboard communication error` | Expected while the main board is not connected or powered (section 4). |
| Fluidd page shows 403 | `./installer.sh --doctor` and accept the home-folder fix. |
| Fluidd shows "PolKit warnings detected" | Open the menu (or run `./installer.sh --repair`): it installs PackageKit and Moonraker's PolicyKit rule. `--doctor` also fixes it |
| Screen board: KlipperScreen will not start | A rescue window opens by itself after 3 failed starts. No screen? USB stick with an empty file `WM-FACTORY`, reboot (section 7). |
| Not sure what is wrong | `./installer.sh --doctor`: it explains each problem and offers a fix. |
| Asking someone for help | `./installer.sh --support-bundle` and send the `.tgz`. |

More in [Troubleshooting](#9-troubleshooting).

---

## Disclaimer (use at your own risk)

This is a community project, not made or supported by WonderMaker. It is provided "as is", without warranty. **It has been tested with a fake home folder, on a fresh Raspberry Pi OS Bookworm Pi (install, `--doctor`, Fluidd, Moonraker, Klipper loading the config) and on one WonderMaker screen board (section 7). It has not been tested with a running printer yet**. Please report what works and what does not.

The installer never flashes any board and never starts Klipper unless you ask for it. You still work on a printer with mains power and heaters: you are responsible for what you connect and run.

## What you get

| | |
|---|---|
| A Pi that takes over from the screen/host board | Raspberry Pi 4 or 5 (64-bit) with Raspberry Pi OS Bookworm |
| WonderMaker's own software, copied from your printer | Klipper and Moonraker forks, your `printer.cfg`, calibration, factory settings |
| Python 3.9 next to Bookworm's 3.11 | needed for WonderMaker's compiled modules |
| Exact package versions of WonderMaker's `klippy-env` and `moonraker-env` | pinned lists in `config/`, read from the factory image |
| Webcams and timelapse | crowsnest and Moonraker timelapse, the versions WonderMaker ships |
| Fluidd with a **Toolheads** panel | four toolheads, chamber, air filter, doors, print with colours, filament mapping |
| Safe without the printer | Moonraker and Fluidd work right away. Without the main board Klipper starts but only reports "cannot connect" (nothing moves); `--no-start` leaves it off until `--first-start` |
| Optional touchscreen | KlipperScreen with a **ZR Tools** page, if you connect a screen to the Pi (**not yet tested on hardware**) |

![Before and after](docs/img/overview.svg)

## 2. Hardware

### 2.1 What you need

- A Raspberry Pi 4 or 5 (64-bit), its official power supply, an SD card of 16 GB or more.
- **Raspberry Pi OS Lite (64-bit), Debian 12 "Bookworm"**, written with Raspberry Pi Imager. Newer Raspberry Pi OS releases are based on Debian 13 "Trixie" and are **not tested**: in the Imager choose **Raspberry Pi OS (other) → Raspberry Pi OS (Legacy, 64-bit) Lite**, which is the Bookworm release. Not the 32-bit image and not the Trixie one. (The Desktop version also works, but Lite is all you need: you use Fluidd in a browser.) In the imager's settings set the **username to `t13dp`** (WonderMaker's software has `/home/t13dp` built in), enable SSH, and set your Wi-Fi or use a cable.
- The printer's **main board** (WM-ZR-D V1.2): it carries the Klipper USB-CAN bridge (USB id `1d50:606f`), and the toolheads and filament hub stay on its CAN bus.
- A **USB-A to JST-XH 2.54 mm 4-pin cable**, bought or made, from the Pi's USB-A port to the red 4-pin connector of the main board. A ready-made one must be **re-pinned** to the board's order (DM, DP, G; leave VIN empty). **VIN is 24 V: cut or do not connect the red wire, never feed it to the Pi.** See [docs/WIRING.md](docs/WIRING.md).

  ![USB 2.0 to JST-XH 4-pin cable for the main board](docs/img/cable-usb-a-to-jst-xh-mcu.jpg)
- A **USB-A to MX1.25 (1.25 mm pitch) 4-pin camera cable, at least 1 m (3 ft) long**, from the printer's camera to a USB port of the Pi. Wire colours: red 5 V, white Data-, green Data+, black GND. Not needed if you do not use the camera. Details: [docs/WIRING.md](docs/WIRING.md#camera-cable-usb-a-to-mx125-4-pin).

  ![USB-A to MX1.25 4-pin camera cable](docs/img/cable-usb-a-to-mx125-camera.jpg)
- The WonderMaker software: from **your own printer** (the original screen board, if it is reachable) or the factory files in this repo (see 3.1). 

### 2.2 How it is connected

![Wiring](docs/img/wiring.svg)

![Red connector of the main board](docs/img/wiring-photo-connector.jpg)

**Careful:** the red connector's VIN pin carries 24 V. Only DM, DP and G go to the Pi's USB-A plug.

The screen/host board's job (screen, Wi-Fi, running Klipper) moves to the Pi. Step by step with photos: [docs/WIRING.md](docs/WIRING.md). The main board, CAN bus, toolheads and hub are untouched. Details and checks: [docs/HARDWARE.md](docs/HARDWARE.md).

### 2.3 What is not covered

The original touchscreen of the Ultra-S is not replaced one-to-one. Use Fluidd in a browser, or connect a screen to the Pi (see 6, KlipperScreen on the Raspberry Pi).

## 3. Install

Log in to the Pi as `t13dp` and:

```bash
sudo apt-get update
sudo apt-get install -y git
cd ~
git clone https://github.com/ducati1198/wm-ultra-rpi.git
cd wm-ultra-rpi
chmod +x installer.sh
./installer.sh
```

> **"destination path 'wm-ultra-rpi' already exists"?** You already downloaded it once. Do not clone again. Update the folder instead:
>
> ```bash
> cd ~/wm-ultra-rpi
> ./installer.sh --get-latest
> ```
>
> That only gets the newest files from GitHub and changes nothing else. To also apply the update to the printer, run `./installer.sh --update` afterwards (optional).

### The installer menu

`./installer.sh` opens this menu (also on an empty Pi). Nothing changes until you pick an entry and confirm. To skip the menu, run `./installer.sh --install`.

![Installer menu](docs/img/menu-pi-main.png)

**2 Update** has two entries: *See what is new* (reads GitHub, changes nothing) and *Update now* (works without git).

![Update page](docs/img/menu-pi-update.png)

**3 Add-ons**: touchscreen, webcam, timelapse, shell command, Shake&Tune, Spoolman, Anycubic ACE Pro, Obico, OctoApp, OctoEverywhere, and ZR Tools macros (for the screen board). Each shows whether it is installed.

![Add-ons page](docs/img/menu-pi-addons.png)

**4 Check and fix**: Doctor, Repair, Hardware test, Quick check, Status, Fix everything.

![Check and fix page](docs/img/menu-pi-check.png)

**5 Backup and restore**: back up your settings, restore one, or undo the last install.

![Backup and restore page](docs/img/menu-pi-backup.png)

**6 Uninstall** ends with *Free up disk space*: it lists leftover downloads in `/tmp`, the pip and apt caches, old log history and the installer's git history, each with its size and a warning. You pick the numbers, it shows **This will ERASE** and asks before it deletes. Your printer data, gcode files and backups are never listed.

**7 Advanced**: first start, start or stop Klipper, support bundle, last log, network and system.

![Advanced page](docs/img/menu-pi-advanced.png)

![Installer steps](docs/img/install-flow.svg)

### 3.1 The questions

The installer first asks **which printer you have** (ZR Ultra or ZR Ultra-S; or give `--model ultra|ultra-s`) and then **where the WonderMaker software is**:

1. **The original screen board is reachable (SSH). Recommended.** If your WonderMaker screen board starts and is on your network, use this one: the installer fetches `printer_data` (config, calibration, saved variables), `klipper`, `moonraker`, `fluidd` and the factory settings from it, so the Pi gets exactly what your printer ran, with your own settings and the original compiled modules. Find its IP in your router, then `./installer.sh --from-board <IP>`. The default WonderMaker login is user `t13dp`, password `TM88888`. The password is typed **once**: the installer opens one SSH connection and reuses it for klipper, moonraker and your data. Only `tar` is run there, nothing is written.
2. **Nothing at all: the factory files inside this repository** (`--from-github`). The repo carries the original Klipper and Moonraker (both GPL v3, license included) and the factory settings, with SHA256 checksums that are verified first. There is a folder for each model: [`factory/ultra/`](factory/ultra) and [`factory/ultra-s/`](factory/ultra-s). See [factory/README.md](factory/README.md).

   WonderMaker's **5 compiled modules** (`cs1237`, `hx711`, `heater_air_core`, `heater_feng`, `xy_offset_calibrator_core`: heaters, load cells, calibration) are bundled in the repo too, copied unchanged from an Ultra-S and checked against their factory checksums. They are WonderMaker's binaries (no published license): see the takedown note in [factory/README.md](factory/README.md). `--modules DIR` uses your own copies instead.

### 3.2 What it does

| Step | What and why |
|---|---|
| Checks | user is `t13dp`, 64-bit ARM, enough disk space |
| Model | asks Ultra or Ultra-S and sets `printer.cfg` for it (the Ultra-S includes `zru-s.cfg`: chamber heater, air filter fan, door sensors). This applies to every source; your old `printer.cfg` is saved as `printer.cfg.wm-model-bak` if it had to change |
| Pi's own config | copies [`rpi-cfg/`](rpi-cfg) (calibration macros for Fluidd that do what the screen app's Maintenance menu does) into `~/printer_data/config` and adds an `[include]` line to `printer.cfg` (a copy of the old one is kept). Not WonderMaker's files: a WonderMaker update never changes them |
| printer.cfg merge | `~/printer_data/wm-baseline/` keeps the factory `printer.cfg` the Pi was set up from. On `--update`, when the repository's factory file is newer, the difference is merged into your `printer.cfg` (preview, ask, copy kept) |
| PID settings | moves the chamber heater's `control` and `pid_*` lines from `zru-s.cfg` into `printer.cfg` and gives every hotend `control: pid`, so a PID tuning can be saved with SAVE_CONFIG (your values are kept; copies of the changed files are made) |
| Packages | nginx, can-utils, build tools, libraries (apt) |
| Groups | `moonraker-admin`, plus `dialout` and `plugdev` |
| Python 3.9 | installed with `uv` into `~/.pythons` |
| Unpack | `klipper`, `moonraker`, `printer_data`, `fluidd`, factory settings into `~`. Anything already there is moved to `~/wm-rpi-backup/old-<time>/` |
| Environments | `klippy-env` and `moonraker-env` built from `config/klippy-requirements.txt` and `config/moonraker-requirements.txt` (exact versions of WonderMaker's image). The environments themselves are not stored in git: they are machine-built folders, so they are rebuilt on the Pi |
| Module check | tries to import the 10 compiled WonderMaker modules and tells you if one fails |
| Services | `moonraker.service` enabled; `klipper.service` installed but **disabled and stopped** while the install runs (the last step enables and starts it, see 3.3) |
| PolicyKit | installs PackageKit and Moonraker's PolicyKit rule (its own script), so Fluidd can start, stop and restart Klipper, crowsnest and KlipperScreen. Without it Fluidd shows "PolKit warnings detected" |
| nginx | Fluidd on port 80 with the websocket, API and webcam routes. Also lets nginx pass through your home folder (`chmod o+x ~`, Debian 12 makes it private, which gives a 403) |
| CAN rule | brings `can0` up at 1 Mbit when the main board appears |
| Fluidd panel | optional, see 5. The panel is **downloaded from [wm-ultra-fluidd-acepro-panel](https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel) every time** (so you always get its latest), checked against the checksum published next to it. It needs internet (no copy is kept in this repo); if the download fails the web page is skipped with a warning and `--update` retries. `--update` installs a newer panel when there is one |
| Timelapse | `ffmpeg` and `moonraker-timelapse` at a pinned commit (see `config/pins/addons.txt`), downloaded from mainsail-crew on GitHub and checked |
| Klipper gcode shell command (installed automatically; `--shell-command off` skips it) | `config/gcode_shell_command.py`, copied into `~/klipper/klippy/extras/`. It is the module by Arksine (GPLv3, the same one KIAUH installs) and is kept in this repository, so no download is needed |
| Obico, OctoApp, OctoEverywhere (optional add-ons, not asked during the install; menu → Add-ons) | the makers' own projects, cloned from GitHub into `~/moonraker-obico`, `~/octoapp`, `~/octoeverywhere` and installed with their own installers, pointed at this Pi's Moonraker. See "Remote access add-ons" below |
| Webcams | `crowsnest` at a pinned commit (see `config/pins/addons.txt`), installed unattended (builds `ustreamer`); your camera goes in `~/printer_data/config/crowsnest.conf` |

### 3.3 Safety checks

- It never flashes any firmware and never writes to the original screen board.
- At the very end the installer **enables and starts Klipper, Moonraker, nginx and crowsnest**, so everything comes back after a reboot. It first runs the checks (USB bridge, can0, CAN devices, config, modules); a failed check is reported, and Klipper then shows the problem until you fix it. `--no-start` starts nothing; `--first-start` later does the checks and stops without starting if one fails.
- Nothing runs on a schedule and nothing is backed up unless you ask (`--backup`).
- A running print stops `--update`, `--repair`, `--restore`, `--undo` and `--first-start` (override with `--force`).
- It replaces the Fluidd folder only after the zip's checksum matches, keeps your `config.json`, and saves the old Fluidd.
- `--dry-run` goes through everything and changes nothing.

### 3.4 Command table

| Command | What it does |
|---|---|
| `./installer.sh` | install (asks first) |
| `./installer.sh --from-board IP` / `--from-github` | choose the source without being asked |
| `./installer.sh --from-github --model ultra --modules DIR` | use the factory files in this repo; modules from your printer |
| `./installer.sh --check` | report problems, change nothing |
| `./installer.sh --dry-run` | show the plan and what would change. The plan lists every optional program (panel, webcam, timelapse, shell command, touchscreen, Obico, OctoApp, OctoEverywhere) as yes or no |
| `./installer.sh --shell-command on` | with `--update` or a first install: installs or skips the Klipper gcode shell command extension (it is installed by default; `off` stops updating it and the file stays) |
| `./installer.sh --obico on` / `--octoapp on` / `--octoeverywhere on` | with `--update` or a first install: adds that remote-access add-on (see below) |
| `./installer.sh --screen-remove` | removes KlipperScreen from the Pi (Klipper, Moonraker, Fluidd stay) |
| `./installer.sh --first-start` | checks with the main board connected, fixes `canbus_uuid` (asks, keeps a copy), then enables and starts Klipper and the other services |
| `./installer.sh --hw-test` | read-only live test: USB bridge, can0, CAN devices, camera picture, services |
| `./installer.sh --doctor` | finds problems, explains them, offers a fix for each (asks first) |
| `./installer.sh --repair` | puts back services, nginx files, can0 rule, groups; your data is untouched |
| `./installer.sh --free-space` | lists what is safe to erase (sizes and a warning for each), erases only what you pick and confirm. The install offers it when the SD card is nearly full (about 2500 MB needed) |
| `./installer.sh --cfg-merge` | when this repository holds a newer WonderMaker version, brings the changes in its factory `printer.cfg` (and new `saved_variables.cfg` keys) into the Pi's `printer.cfg` with a 3-way merge: old factory file, new factory file, yours. WonderMaker's new settings are added; your own lines, sections, `[include]` lines and the SAVE_CONFIG block stay; a setting you both changed differently is asked one by one. A copy is kept as `printer.cfg.wm-before-cfgmerge-<time>`. `--update` does this too. The release tool does the same for a release from the board or from WonderMaker's site |
| `./installer.sh --can-ids` | asks the boards on the CAN bus for their ids and shows which ids in the config answer (main board, hub, extruder board, T0-T3, load cell). A board whose id does not answer is offered the unknown id on the bus (a copy of the file is saved first); with several unknown ids it asks which one. Klipper is stopped for the scan and started again. `./installer.sh --can-ids set T2 ac8b57e80210` sets one id by hand. The same check runs at first start, in the Doctor and in Fix everything. |
| `./installer.sh --pid-cfg` | checks that the PID settings of the hotends and the bed are in `printer.cfg`, where Klipper's `SAVE_CONFIG` can store a PID result, and fixes them. The chamber heater is left as `zru-s.cfg` has it (see `chamber_test/README.md`). A copy of every changed file is kept as `<file>.wm-before-pidcfg-<time>`. The install, `--update` and the Doctor do this too |
| `./installer.sh --pi-sensors` | once Klipper is running: adds the chip temperature of every printer board and connects Klipper to the host MCU (`[mcu rpi]`, the Klipper-Mcu service). Klipper restarts; if it does not come back the change is undone. Details: [docs/HOST_MCU.md](docs/HOST_MCU.md). Also done at the end of an install and an update. |
| `./installer.sh --rpi-cfg` | installs or repairs the Pi's own config files from [`rpi-cfg/`](rpi-cfg) (the calibration macros `WM_BED_LEVELING`, `WM_FULL_CALIBRATION`, ... and their include line in `printer.cfg`), then restarts Klipper (not during a print). The install, `--update` and the Doctor do this too |
| `./installer.sh --zr-tools` | checks the ZR Tools macros on this Pi (for the screen board); says "already installed" or installs what is missing, then restarts Klipper (not during a print) |
| `./installer.sh --check-updates` | read-only: lists what is new on GitHub since your copy, and says how to update |
| `./installer.sh --update` | after `git pull`: refreshes services, packages, panel, add-ons; shows what changed; keeps `printer_data` (an edited `zr_tools.cfg` is saved as `zr_tools.cfg.zrbak_<date>` before it is replaced) |
| `./installer.sh --undo [DIR]` | puts back the folders the installer moved aside (latest by default) |
| `./installer.sh --backup [DIR]` | saves config, calibration and database to a private `.tgz` (only when you run it) |
| `./installer.sh --restore FILE` | restores such a backup after making a safety copy |
| `./installer.sh --support-bundle` | scrubbed logs and config in one `.tgz` for asking for help (passwords, tokens, Wi-Fi, private IPs removed) |
| `./installer.sh --no-start` / `--force` | do not start Klipper at the end / ignore an active print |
| `./installer.sh --disable-klipper` | stop Klipper and disable it |
| `./installer.sh --uninstall` | remove what the installer added to the system |
| `bash scripts/screen_board.sh --zr-pi --pi IP` | on the screen board: checks the ZR Tools macros on the Pi over ssh (asks its user name and password), installs them if missing |
| `bash scripts/screen_board.sh --free-space` | on the screen board: lists what is safe to erase (sizes, warnings), erases only what you pick and confirm |
| `bash scripts/screen_board.sh --fix-clock` | on the screen board: turns on automatic time sync (NTP) and fixes apt's date check |
| `scripts/board_check.sh` | read-only: main board on USB, can0, CAN devices, services, Moonraker |

### 3.5 Open Fluidd

After the install, open `http://<pi address>/`. Without the main board, Klipper starts but cannot reach it, so Fluidd shows an error such as `mcu 'mcu': ZRU-B001: Screen–Mainboard communication error`. That is expected until the main board is connected (section 4).

## 4. When the main board is connected

1. Power the printer, connect the USB cable between Pi and main board (see [docs/WIRING.md](docs/WIRING.md)).
2. Run `./installer.sh --first-start`. It checks the USB bridge (`1d50:606f`), brings `can0` up, asks the CAN bus which devices answer, and compares them with `canbus_uuid` in your config.
3. A **new main board may have a new `canbus_uuid`**. If the bus shows one device the config does not know, the installer offers to put it into `wm_zru_mcu.cfg` (a copy of the old file is kept in `~/wm-rpi-backup/uuid-*`). Toolhead and hub uuids are only reported, never changed.
4. If every check passes it enables and starts Klipper, Moonraker, nginx and crowsnest. If not, the failing checks are listed and nothing is started.
5. Do not run heaters or moves unattended on the first start.

## 5. Fluidd (web panel and ZR Tools)

Fluidd is the web page you use to control the printer from a phone or computer: open `http://<pi address>/` (see 3.5). The installer puts WonderMaker's Fluidd on the Pi, and adds the **Toolheads** panel (and the ACE Pro parts, if you add one). Update it later with `./installer.sh --update`.

**Without an ACE Pro** (the default):

![Fluidd without an ACE Pro](docs/img/fluidd-without-acepro.png)

**With an ACE Pro** (the same Fluidd build: the installer downloads the newest panel straight from [wm-ultra-fluidd-acepro-panel](https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel); run that repo's `installer.sh` to add the ACE Pro driver, and the ACE section appears in the Toolheads card):

![Fluidd with an ACE Pro](docs/img/fluidd-with-acepro.png)

**ACE Pro or ACE 2 Pro?** The ACE driver is for the first-generation **ACE Pro** (USB). The **ACE 2 Pro** talks RS-485 and needs Anycubic's own USB-to-RS485 signal cable; it is **not tested** on this printer. What is known so far (cable, driver, installer) is in [ACE 2 Pro: what is known](https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel#22-which-ace-do-you-have) in the panel repo.

Full dashboard without an ACE Pro:

![Fluidd dashboard without an ACE Pro](docs/img/fluidd-dashboard-no-ace.png)

![Toolheads card](docs/img/fluidd-toolheads-card.png)

The Fluidd build from [wm-ultra-fluidd-acepro-panel](https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel) adds the Toolheads card (toolhead status, colours and materials, chamber, air filter, doors, **Print with colours**) and the **Choose toolheads** window at print start, shown only when a colour or material does not match.

![Toolhead dialog](docs/img/fluidd-toolhead-dialog.png)
*Toolhead dialog: colour, material, ACE feeder and the endless-spool chain (demo data).*

![Tool change in progress](docs/img/fluidd-tool-change-progress.png)
*The card shows a progress bar while a tool change runs (demo data).*

![Choose toolheads](docs/img/fluidd-choose-toolheads.png)

Without an Anycubic ACE Pro the ACE parts stay hidden. If you add one later, use [wm-ultra-fluidd-acepro-panel](https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel).

### Install the OrcaSlicer plugin (optional, works without an ACE Pro)

> **Not yet tested in OrcaSlicer or on a printer.** You need OrcaSlicer **2.5 or newer** (it has the plugin system).

The plugin ([WM Toolhead Mapper](https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel/tree/main/orca_plugin), from the [wm-ultra-fluidd-acepro-panel](https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel) repository) lets you pick, inside Orca, which toolhead prints each filament. When you send or export, it writes the choice at the top of the G-code, so the print needs no popup at start. It reads your four toolheads (colour, material, loaded or empty) from the printer, so an ACE Pro is not needed.

**On the Pi (once):** the plugin calls a macro (`WM_SET_TOOL_MAP`) that lives in the panel repository's `wm_stats.cfg`. Install it with that repository's installer, then restart Klipper:

```bash
cd ~
git clone https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel
cd wm-ultra-fluidd-acepro-panel
./installer.sh
```

(Already cloned? `cd ~/wm-ultra-fluidd-acepro-panel && git pull && ./installer.sh --update`.) Say **no** to the ACE Pro question if you have none.

**In OrcaSlicer (once):**

1. Download the plugin file: [`wm_toolhead_mapper.py`](https://raw.githubusercontent.com/ducati1198/wm-ultra-fluidd-acepro-panel/main/orca_plugin/wm_toolhead_mapper.py) (right-click, save as; keep the `.py` name). You can also download it from the [orca_plugin folder of the wm-ultra-fluidd-acepro-panel repository](https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel/tree/main/orca_plugin): open `wm_toolhead_mapper.py` there and use the download button.
2. Open Orca's **Printer settings → Connection** and make sure the host is your Pi's address, for example `192.168.0.50:7125`. The plugin uses it to read the toolheads.
3. Open **File → Plugins**, use the split button **Browse plugins → Install local plugin**, and pick `wm_toolhead_mapper.py`.
4. When Orca asks whether the plugin may connect to your printer, click **Yes**.
5. The plugin brings two parts, **WM Toolheads** (the panel) and **WM Tool Map** (the G-code step). If the Plugins window shows them disabled, enable both.
6. Switch Orca to **Advanced** mode. Open your **Process** settings → **Others** → **Slicing Pipeline Plugin**, add **WM Tool Map**, and save the process preset. Do this for each process preset you print with.
7. Restart Orca. The **WM Toolheads** panel docks on the right of the 3D view.

**Use it:** in the panel, each filament shows its best toolhead (**Auto**: same material, closest colour, each toolhead used once). Change a row to a specific toolhead or **As sliced**, then slice and use **Upload and Print**. If you choose toolheads in Fluidd's **Choose toolheads** window for the same file, the Fluidd choice wins. Full details: [`orca_plugin/INSTALL.md`](https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel/blob/main/orca_plugin/INSTALL.md).

## 6. KlipperScreen on the Raspberry Pi (touchscreen)

Use this if you connect a touchscreen directly to the Raspberry Pi. KlipperScreen runs on the Pi next to Klipper and Moonraker, with the ZR Tools panel. For the original WonderMaker screen board as the screen, see section 7 instead.

> **Not yet tested on hardware.** It was built against the KlipperScreen documentation and checked with automated tests, but nobody has run it on a Pi with a screen yet. Please report what you see.

The installer asks **"Add a touchscreen?"** (default yes). Skip it with `--screen off`. Options:

| Option | Meaning |
|---|---|
| `--screen on\|off\|macros` | `on`: KlipperScreen on the Pi (for a screen plugged into the Pi). `off`: nothing. `macros`: only the ZR Tools macros in `printer.cfg`, for people who use the WonderMaker screen board (section 7) |
| `--network-manager on\|off` | NetworkManager, for KlipperScreen's own **Network** panel (choose Wi-Fi on the screen). Default **off**. KlipperScreen's installer is run without it on purpose: switching a Pi to NetworkManager can **drop the network connection** (your SSH session and Fluidd) and Wi-Fi may need its password again (screen's Network panel, or `sudo nmtui`). The installer therefore installs and enables it but does **not** restart anything: it takes over at the next reboot. If NetworkManager is already running (Raspberry Pi OS Bookworm uses it), nothing is changed. Asked during the install only when you add a touchscreen |
| `--screen-layout tabs\|grid` | `tabs` (default): big touch buttons with bottom tabs. `grid`: cards on a home page |
| `--screen-backend x11\|weston\|cage` | graphics stack, default `x11` |
| `--screen-test` | read-only: shows the screen and touch device found |

What it does: installs [KlipperScreen](https://github.com/KlipperScreen/KlipperScreen) pinned to one tested commit (`34610ce`, so a later upstream change cannot break it), copies the ZR Tools panel into it, adds the helper macros (`zr_tools.cfg`) to `printer.cfg` and enables the `KlipperScreen` service. KlipperScreen's own home screen and menus stay as they are; ZR Tools is one extra menu entry.

The screen is detected for you (the video output and the touch device through udev). The default size is **Comfortable** (big touch buttons); on the Settings page you can pick Compact, or Auto.

**Screen sizes and orientation.** ZR Tools adapts to the size and to wide or tall screens. The sizes it is built for:

| Screen | Wide (horizontal) | Tall (vertical) | Auto size picks |
|---|---|---|---|
| 5 inch | 800x480 | 480x800 | Compact |
| 7 inch | 1024x600 | 600x1024 | Comfortable |
| 7 inch | 800x480 | 480x800 | Compact |

Other sizes are scaled from the real pixel size: buttons, text and colour dots shrink or grow with the screen (never below 75% or above 150% of the sizes above, so 800x480 and 1024x600 look exactly as before). Two more cases:

- **Tiny screens** (short side 400 px or less, such as 3.5 or 4 inch at 480x320 or 480x272): the tab bar keeps five tabs at most, because Calibrate moves into **More**.
- **Wide screens** (1280x800 and up, 9 to 10 inch): the hub and Calibrate pages show 4 tiles per row instead of 3.

Auto uses Compact when the short side is 520 px or less, or the long side is 900 px or less. On a tall screen the four toolhead cards sit 2 x 2 instead of in a row, the toolhead page puts the spool card on top as a strip, the tool mapping uses short labels (`T0 ->`, `1` to `4`), and the bottom tabs use short names (Heads, Calib.) when the width is tight. Tall or wide is read from the screen size, so it follows the rotation you set in the operating system (see **Rotation** below). `--screen-test` shows the size, Auto's pick and whether the screen is wide or tall.


**ZR Tools pages:** Toolheads (select, heat, load, unload, purge, colour, material), Filament, Climate (chamber, air filter), Calibrate (only the macros that exist on your printer: Z and XY offsets, bed mesh, PID, wipe position, input shaper via the accelerometer), **ACE Pro** (only when an ACE Pro is present: slots, load/unload, feed assist, dryer presets, endless spool), More (collision detection settings, **read-only**; timelapse; restart; system page with Pi temperature, power flags, can0, Klipper state, the Fluidd address (the one entered under Pi address) and a backup button) and Settings. Fan, Z offset, pressure advance and camera use KlipperScreen's own pages. The emergency stop is KlipperScreen's own button, shown while printing.

**Settings page:** layout (tabs/grid), size (auto/compact/comfortable, default comfortable) and light/dark theme. They are stored in `~/printer_data/config/zr_screen.conf` (not in KlipperScreen's own settings). You can also change the layout with `./installer.sh --screen-layout grid`.

**What it looks like** (real captures from the WonderMaker screen board, 800x480, layout `tabs`, size Comfortable, with demo data: temperatures, colours and ACE slots are made up):

| | |
|---|---|
| ![Toolheads](docs/img/screen-toolheads.png) | ![Filament](docs/img/screen-filament.png) |
| Toolheads: tall cards with status, spool colour, material and temperature | One toolhead: select, heat, cool, load, unload, purge, edit filament |
| ![Edit filament](docs/img/screen-edit.png) | ![Colour picker](docs/img/screen-colour.png) |
| Edit filament: colour first, then material and temperature | The colour dots and a custom colour |
| ![Climate](docs/img/screen-climate.png) | ![Calibrate](docs/img/screen-utilities.png) |
| Climate: chamber, air filter, doors | Calibrate: home, offsets, wipe, park, motors off |
| ![ACE Pro](docs/img/screen-ace.png) | ![More](docs/img/screen-more.png) |
| ACE Pro page (only shown when an ACE Pro is present) | More: ACE Pro, toolhead choice, fans, pressure advance, camera, system, screen settings |
| ![Tool mapping](docs/img/screen-mapping.png) | ![System](docs/img/screen-system.png) |
| Tool mapping: which head prints each slicer tool | System: Pi temperature, Fluidd address from "Pi address", factory mode, reboot |
| ![Screen settings](docs/img/screen-settings.png) | |
| Screen settings: layout, size, colours | |

The `grid` layout shows the same pages as cards instead of tabs;.

**Rotation** is an operating-system setting, not a ZR Tools one, and the installer does not change it. ZR Tools follows the size X reports after the rotation. On X11 use `xrandr --output <name> --rotate left` (and a matching touch matrix); for Weston, `transform=90` in `weston.ini`. See the KlipperScreen documentation.

`--update`, `--repair` and `--doctor` copy the panel files back if a KlipperScreen update removed them. Using the original WonderMaker screen board as the KlipperScreen is section 7.

## 7. KlipperScreen on the WonderMaker screen board (optional)

Run `bash scripts/screen_board.sh` on the board to get this menu:

![Screen board menu](docs/img/menu-board-main.png)
![Screen board update page](docs/img/menu-board-update.png)

### Not enough free space

The install needs about 1500 MB free. If there is less, it stops with "only N MB free" and offers to look for files that are safe to erase. You can also run it any time: menu 9 (Uninstall installer files) > 5 Free up disk space, or `bash scripts/screen_board.sh --free-space`.

It lists each candidate with its size and a warning, you pick the numbers, then it shows **This will ERASE** and asks before deleting anything:

| Candidate | What goes | What the warning says |
|---|---|---|
| Leftover installer downloads in `/tmp` | Copies of this installer that older "Update now" runs left behind (about 50 MB each) | nothing else is in them |
| pip cache `~/.cache/pip` | Downloaded Python packages | downloaded again only if you reinstall something |
| apt package cache | `.deb` files of packages already installed (needs sudo) | installed programs are not touched |
| Old system log history | everything except the newest 50 MB of the journal (needs sudo) | only useful for finding an old problem |
| Old rotated printer logs | `~/printer_data/logs/*.log.*` | the current logs stay |
| Installer git history | `.git` in the downloaded installer folder | `git pull` stops working there; "Update now" downloads instead |

Your gcode files, settings, KlipperScreen and the factory software are never in the list. `--yes` alone never erases anything.

### Clock, and ZR Tools on the Pi

- **Clock.** A wrong date makes HTTPS downloads and apt fail. The install starts by checking whether the board's clock is synchronised. If not, it asks once and turns on automatic time sync (NTP, `systemd-timesyncd`). If no time server answers (some networks block it), it sets the clock once from GitHub's reply. apt's expired-date check is switched off as before. Run it alone with `bash scripts/screen_board.sh --fix-clock` or Settings > Fix the clock.
- **ZR Tools on the Pi.** The ZR Tools page on the board sends macros such as `ZR_LOAD` to Klipper on the Pi, so the Pi needs `zr_tools.cfg` too. During the install the board asks *Also check and set up the ZR Tools macros on the Pi now?* (default **no**). If you say yes it asks the Pi user name (default `t13dp`) and password. The password is used for this run only and is never saved. The board logs in over ssh (it installs `sshpass` for that), then:
  1. checks `zr_tools.cfg`, the `[include zr_tools.cfg]` line in `printer.cfg` and `[save_variables]`;
  2. if all three are fine it says **already installed** and changes nothing;
  3. if something is missing it installs it (your old files are kept as `.zrbak_<date>`), then restarts Klipper on the Pi (never during a print).

  A `zr_tools.cfg` you edited counts as installed as long as it still has every macro the screen needs; it is never replaced behind your back. To replace it with the bundled copy on the Pi: `ZR_REPLACE=1 ./installer.sh --zr-tools`.

  Later, run it alone with `bash scripts/screen_board.sh --zr-pi --pi <Pi address>` or Settings > Set up ZR Tools on the Pi. On the Pi itself: `./installer.sh --zr-tools`, or menu 3 Add-ons > ZR Tools macros (screen board).

> The board's kernel has no virtual console (`/dev/tty0`), so the installer runs X on its own seat (display, framebuffer and touch assigned to `seat1`) with a custom service.

Instead of buying a screen for the Pi, the original screen board can run KlipperScreen and talk to the Pi's Klipper/Moonraker over the network. The Pi is never checked or contacted by the install; KlipperScreen connects once the Pi is running. The screen board only shows the screen: every button on the ZR Tools page (Save filament, Load, Unload, Purge, Chamber, Mapping) sends a command to a helper macro such as `ZR_SET_TOOL_INFO` or `ZR_LOAD`, and those macros must exist on the **Pi**, in `zr_tools.cfg`, which `printer.cfg` has to include. Without them those buttons do nothing (heating and moving still work). On the Pi, run `./installer.sh --screen macros` to add only the macros, which is all you need when the screen board is your only screen (the installer also offers this when you answer no to "Add a touchscreen?"). `./installer.sh --screen on` adds the macros too, but also installs a KlipperScreen on the Pi itself, which is only useful if you plug a screen into the Pi; you can remove that one later with `./installer.sh --screen-remove` (the macros stay).

**Before you start: fix the board's clock and apt (other users need this).** On a factory screen board `sudo apt-get update` fails (Debian 11 was moved to an archive and the clock is often wrong), so even `sudo apt-get install -y git` fails. The script repairs apt itself, but if you want to do it by hand, or the script says apt fails, run this on the board:

```bash
# 1. Set the date and time (HTTPS to GitHub fails if the clock is wrong). Use your own date/time, UTC:
date                                   # check it first
sudo date -s "2026-11-03 18:00:00"     # example only: put today's date and time here
# 2. Point apt at the Debian archive and stop it rejecting old package lists
sudo cp /etc/apt/sources.list /etc/apt/sources.list.orig
sudo sed -i -E 's#https?://[^ /]+/debian-security#http://archive.debian.org/debian-security#; t; s#https?://[^ /]+/debian/?#http://archive.debian.org/debian/#' /etc/apt/sources.list
printf 'Acquire::Check-Valid-Until "false";\nAcquire::Check-Date "false";\n' | sudo tee /etc/apt/apt.conf.d/99no-check-valid-until
# 3. Now this works
sudo apt-get update
sudo apt-get install -y git
```

Never run `apt upgrade` or `apt full-upgrade` on this board: it can replace WonderMaker's held X server and break the screen. The script only uses `apt-get install --no-upgrade`.

Then on the **screen board** (SSH in as `t13dp`, it needs internet). Pick one way to get the files:

**Option A: no git needed** (works even if apt is broken)

```bash
cd ~
curl -fsSL https://codeload.github.com/ducati1198/wm-ultra-rpi/tar.gz/refs/heads/main | tar xz && cd wm-ultra-rpi-main
```

**Option B: with git** (after the clock and apt fix above, so `apt-get install -y git` works)

```bash
cd ~
git clone https://github.com/ducati1198/wm-ultra-rpi && cd wm-ultra-rpi
```

If you cloned it before, a `git clone` copy does **not** update by itself: run `cd wm-ultra-rpi && git pull` first (or delete the folder and clone again). With Option A, delete the old `wm-ultra-rpi-main` folder before downloading again.

Then, inside the folder you just downloaded (you are already in it after Option A or B), run:

```bash
bash scripts/screen_board.sh               # opens the menu (see "The screen board menu" below); Install is entry 1 and asks for your Pi's IP address
bash scripts/screen_board.sh --dry-run     # shows every change, changes nothing (it asks for the Pi's IP address)
bash scripts/screen_board.sh --install     # skips the menu and goes straight to the install
```

### The screen board menu

`bash scripts/screen_board.sh` with no options at a terminal opens a numbered menu (`--menu` does the same any time). Every entry runs an option you could also type yourself.

```
KlipperScreen on the WonderMaker screen board
  Mode: KlipperScreen
   1) Install KlipperScreen + ZR Tools   asks for the Pi address, shows the plan, then asks
   2) Update                             see what is new, then update the ZR Tools screen files (backup first)
   3) Check and fix                      doctor, status, logs, restart the screen, board report
   4) Backup and restore                 screen settings
   5) Settings                           Pi address, network and system, ZR Tools on the Pi, clock
   6) Support bundle                     scrubbed .tgz of logs and config to share when asking for help
   7) Dry run of the install             shows what would happen, changes nothing
   8) Back to factory mode               removes KlipperScreen, factory services return, reboot
   9) Uninstall installer files          rescue tool, backups, saved restore data, the installer folder, free up disk space
   0) Exit
```

| Menu page | What it has | Command line |
|---|---|---|
| **Update** | **See what is new** reads only two small files from GitHub (`VERSION` and `CHANGELOG.md`) and lists the changes since your version; nothing is downloaded. **Update now** downloads the newest version, makes a backup of your screen settings, copies the new ZR Tools panels, refreshes the installer folder and restarts the menu on the new version. KlipperScreen itself (the pinned commit) is not changed | `--check-updates`, `--update` |
| **Check and fix** | **Doctor** (asks before each fix: KlipperScreen enabled and running, ZR Tools files, factory services still enabled, the System version file `~/iso_version.txt`, the Pi answers at its address, disk space), **Fix everything** (the Doctor applies every safe fix after one question), Status, the last log lines, Restart the screen, a read-only board report (`/tmp/screen_board_report.txt`) and the Pre-check (READY / NOT READY) | `--doctor [--fix-all]`, `--status`, `--log`, `--restart-screen` |
| **Backup and restore** | Saves `KlipperScreen.conf`, the ZR Tools settings and the list of factory services to `~/wm-screen-backups/`; a restore lists them, newest first, and makes a safety copy first | `--backup`, `--restore-backup [N]` |
| **Settings** | Change the Pi address; Network and system (host name, time zone, clock, addresses, Wi-Fi); **Set up ZR Tools on the Pi** (checks the Pi, installs the macros if missing); **Fix the clock** (automatic time sync) | `--set-pi ADDR`, `--system [tz:Zone\|host:name]`, `--zr-pi --pi ADDR`, `--fix-clock` |
| **Support bundle** | A scrubbed `~/wm-screen-support-<date>.tgz` (passwords, tokens, Wi-Fi names, private IP and MAC addresses removed; look inside before you send it) | `--support-bundle` |
| **Uninstall installer files** | Each one asks first: the rescue tool and the on-screen Factory mode button; backups, support bundles and the board report; the saved restore data `~/wm-screen-backup` (refused while KlipperScreen is installed, because a factory restore needs it, unless `--force`); the downloaded installer folder; **Free up disk space** (see below). KlipperScreen itself is only removed by **Back to factory mode** | `--remove rescue\|backups\|restoredata\|installer`, `--free-space` |

- **Progress bars:** the install shows "Install step N of 7" with a percent bar, Back to factory mode shows "Factory restore step N of 3", and slow steps (apt packages, the KlipperScreen Python build) print "still working" with the elapsed time every 30 seconds.
- **Klipper restart:** after an install or update the board restarts KlipperScreen and asks the Pi's Moonraker to restart Klipper on the Pi (never during a print; skipped with a note if the Pi does not answer or does not trust the board's address).
- **Reboot question:** the install ends with "Reboot the board now?" (default yes; Enter reboots after a 10 second countdown). `--no-reboot` skips the question.
- **A print stops changes:** while the factory Moonraker on the board reports a print, every entry that changes something refuses (add `--force` to override).
- **An old copy has an old menu.** A `git clone` copy does not update by itself: run `cd ~/wm-ultra-rpi && git pull` once. From then on **Update > Update now** refreshes the installer folder too.

**To uninstall KlipperScreen and go back to the factory screen** (over SSH, as `t13dp`):

```bash
bash ~/wm-screen-backup/screen_board.sh --factory-restore
```

It removes KlipperScreen, turns the factory services back on exactly as they were, and reboots the board. Nothing is deleted.

The script asks for your Pi's IP address. You can also give it with `--pi <address>`. To change it later, tap **Pi address** (on the start screen while the Pi cannot be reached, or in the More menu), or run `bash scripts/screen_board.sh --set-pi <address>`. The Pi does not have to be running during the install.

What it does, in this order (everything that can fail comes before the factory app is stopped):

1. Checks: nothing is printing, disk space, apt works, GitHub reachable. If a check fails nothing is changed.
2. Debian 11 is archived, so apt is pointed at `archive.debian.org` with the date checks off (the same fix as on the original board). It only runs `apt-get install --no-upgrade`, **never `apt upgrade`**.
3. Installs the X11 and KlipperScreen packages (and a Wi-Fi page that uses the board's own `wpa_supplicant`, because the stock KlipperScreen Network page needs NetworkManager, which this board does not use: scan, tap a network, type the password; nothing is saved unless the connection works), KlipperScreen at the pinned commit, and ZR Tools. WonderMaker's own held X server is kept; its matching `xserver-xorg-legacy` is taken from `/packages/xserver` on the board.
4. Stops and **disables** (deletes nothing) `makerbase-client` (the factory screen app), klipper, moonraker, nginx, crowsnest, makerbase-webcam, janus, klipper-mcu and hostapd, and obico/octoapp if you installed them. The previous state is saved in `~/wm-screen-backup/disabled.list`.
5. Starts KlipperScreen with the Rockchip modesetting driver; if X does not start it switches to the plain framebuffer (`fbdev`) driver by itself (`--screen-driver fbdev` forces it).

**What you need before you start:** the screen board powered, on your network (it keeps using its own Wi-Fi settings) and reachable over SSH as `t13dp` (default password in WonderMaker's image); about 1.5 GB free disk (the install needs it); and your Pi's IP address. The install takes about 20 minutes (the Python packages are built on the board).

**On the screen after the install**

- The ZR Tools tile is in the main menu. If the Pi cannot be reached, the start screen shows **Network**, **Pi address** and the usual buttons.
- **Network** is the Wi-Fi page: it shows the current network and IP, **Scan again** lists the networks, tap one, type the password on the on-screen keyboard. If the connection fails it goes back to the previous network.
- **Pi address** changes the Pi's IP address (also under More). It saves and restarts KlipperScreen.
- The Pi's `moonraker.conf` must trust the board's address (`trusted_clients`), otherwise the Pi refuses the connection.
- The board has 487 MB of RAM and no swap, so do not run other heavy programs on it.

**Go back to the factory software** (any of these, nothing is lost):

| How | What happens |
|---|---|
| On the screen: **ZR Tools > More > System > Factory mode** | asks to confirm, then does the same as the command below |
| `bash ~/wm-screen-backup/screen_board.sh --factory-restore` | removes KlipperScreen, re-enables exactly the services that were enabled before, reboots |
| `bash scripts/screen_board.sh --uninstall-klipperscreen` | same as `--factory-restore`: KlipperScreen is never removed without turning the factory services back on |
| `bash scripts/screen_board.sh --status` | read-only: what is enabled, running and installed |

**If KlipperScreen stops working: the rescue tool** (installed by default, `--no-rescue` skips it;)

| Situation | What happens |
|---|---|
| KlipperScreen fails to start 3 times within 2 minutes | The board stops retrying and opens a **rescue window** with big touch buttons: **Restart KlipperScreen**, **Factory restore**, **Reboot board**, and **More**: error details, network status, reset KlipperScreen settings, reinstall KlipperScreen files. Every action that changes something asks "Are you sure?" first, and factory restore, reset settings and reinstall show a progress bar with the step it is on (the last part of a factory restore, while the board reboots, is an estimate). The window takes a few seconds to open because KlipperScreen is stopped and a second screen server is started. |
| The window is wanted on purpose | **ZR Tools > More > System > Rescue**, or a USB stick (below). KlipperScreen stops while it is open; **Restart KlipperScreen** brings it back. |
| No network, no working screen app | **USB flag:** use a USB stick: plug a FAT32 or exFAT stick into the board and create an **empty file** on it named `WM-FACTORY` (go back to the factory software, no questions asked) or `WM-RESCUE` (open the rescue window), then **reboot the board**. The stick is checked once, at boot. |

![Rescue window](docs/img/rescue-window.png)
*The rescue window (800x480). Drawn on the screen board in test mode.*

Details:
- **Factory restore** never leaves the board stuck. It uses the saved list `~/wm-screen-backup/disabled.list`. If that file is missing, it uses a built-in list of the 8 factory services (`makerbase-client`, `klipper`, `moonraker`, `nginx`, `crowsnest`, `makerbase-webcam`, `klipper-mcu`, `hostapd`, each in the state a factory board has). `klipper` and `hostapd` are not enabled on a factory board; the WonderMaker app starts Klipper itself.
- **After a factory restore the screen turns black for about 5 minutes** (the board removes KlipperScreen and reboots), then the WonderMaker app appears by itself. The rescue window and the Factory mode button say so before you confirm. Do not switch the board off.
- Before any restore your KlipperScreen settings and the Pi address are copied to `~/wm-screen-backup/rescue-snapshots/`.
- **USB flag files to download:** [`usb_flags/`](usb_flags/) has the empty `WM-RESCUE` and `WM-FACTORY` files and two zips with one file each (use only one per stick).
- The USB flag file is renamed to `WM-FACTORY.done` (or `WM-RESCUE.done`) after it is used, so a stick left in does not trigger it again. A short report, `WM-RESCUE-LOG.txt`, is written to the stick. The USB check works only while KlipperScreen is installed (the factory restore removes the rescue tool).
- If the screen server itself cannot start, the window tries a second graphics driver; if that fails too, a message is drawn straight on the screen and the USB stick is the way out (best effort).
- Not covered: a KlipperScreen that is running but frozen or black (a stick with `WM-RESCUE` or `WM-FACTORY` still works).
- Files: `screen_rescue/wm-screen-rescue`, `screen_rescue/wm-rescue-window.py`; log in `/var/log/wm-screen-rescue.log`.
- To test it safely: first check that a stick shows up (`lsblk` over SSH), then try `WM-RESCUE`, then break KlipperScreen on purpose (for example rename `/usr/local/sbin/wm-ks-start` and reboot) and watch the window appear, then try **Factory restore** and `WM-FACTORY` last.
- `scripts/screen_board.sh` asks "Reboot the board now?" when the install finishes (default yes), so everything starts clean (`--no-reboot` skips the question and the reboot).

To read the board first (nothing is changed): `scripts/screen_board_inspect.sh`. Notes: the board's Reboot/Shut down buttons in ZR Tools act on the **Pi**; the Pi's `moonraker.conf` must trust the board's address; the apt packages stay installed after a restore.

On the Pi, `./installer.sh --screen-remove` removes KlipperScreen again (Klipper, Moonraker and Fluidd stay).

## 8. Go back / uninstall

- The menu's **Uninstall** section (or `./installer.sh --remove NAME`, see [The menu](#the-menu)) removes any single part: the add-ons, Fluidd, Moonraker, Klipper, your printer data, or everything except your data and backups.
- `./installer.sh --uninstall` removes the services, nginx files and can0 rule the installer added. Your folders in `~` stay.
- Moved folders are in `~/wm-rpi-backup/`.
- Nothing was changed on the original screen board or on any firmware, so there is nothing to restore there.

## 9. Troubleshooting

| Problem | What to try |
|---|---|
| "you are user ..., expected t13dp" | Create the card again with username `t13dp`. WonderMaker's paths are fixed to `/home/t13dp`. |
| Can't read the original screen board | Check IP, power and the password. Or use the factory files (`--from-github`). |
| A compiled module "does not import" | Python must be 3.9 and the CPU 64-bit ARM. Check: `cd ~/klipper/klippy && ~/klippy-env/bin/python -c "import sys; sys.path.insert(0, '.'); import extras.cs1237"` (no output means it works; importing from inside the `extras` folder gives a false error) |
| Fluidd blank / old page | Hard-refresh (Ctrl/Cmd+Shift+R). Check `sudo nginx -t` and `systemctl status nginx`. |
| No picture from the camera | `ls /dev/v4l/by-id/`, put that path on the `device:` line of `~/printer_data/config/crowsnest.conf`, `sudo systemctl restart crowsnest` |
| Moonraker does not answer | `journalctl -u moonraker -n 50` |
| Fluidd page shows 403 Forbidden | nginx cannot read your home folder (Debian 12 makes it private). `chmod o+x ~ && sudo systemctl reload nginx`, or `./installer.sh --doctor` and accept the fix. |
| Fluidd says "PolKit warnings detected" | The `packagekit` package or Moonraker's PolicyKit rule is missing. The installer fixes it by itself when the menu opens; or run `./installer.sh --repair`. |
| Fluidd says `mcu 'mcu': ZRU-B001: Screen–Mainboard communication error` | Expected while the main board is not connected: Klipper cannot reach it over CAN. Connect it (section 4). |
| No `can0` | Main board not powered or not on USB. `lsusb` should show `1d50:606f`. |
| Klipper "mcu ... uuid" error | New board, new `canbus_uuid` (see 4). |
| Klipper "Duplicate canbus_uuid" | The factory files have empty uuids for the toolheads and load cell. Since 1.13.1 the installer fills unique placeholders (`b00000000000`...); run `./installer.sh --repair` on an older install. Then set the real uuids with `scripts/read_write_can_id.sh`. |
| Screen board: `apt-get update` fails | Fix the clock and apt first (the block at the start of section 7). |
| Screen board: KlipperScreen says it cannot connect | Open **Pi address** on the screen and enter the Pi's IP; check the Pi is on and trusts the board in `moonraker.conf`. |
| Screen board: black or wrong screen | `bash ~/wm-screen-backup/screen_board.sh --factory-restore` from SSH, or `--screen-driver fbdev` when installing. With no network: the rescue window (opens after 3 failed starts) or a USB stick with an empty file `WM-FACTORY` (section 7). |

## 10. Repository layout

```
installer.sh            the Pi installer
factory/ultra/          WonderMaker ZR Ultra: Klipper, Moonraker, settings, scripts, checksums
factory/ultra-s/        WonderMaker ZR Ultra-S: same, with the chamber/air-filter/door settings on
tools/devbox/           dev box (for testing only): run WonderMaker's Klipper on a Pi with no printer, see README-DEVBOX.md
rpi-cfg/                the Pi's own config files (not WonderMaker's): wm_calibration.cfg (calibration macros) and wm_nozzle.cfg (Nozzle Type, Extruder Setup and tool head matching wizards); installed by the installer
screen_rescue/          rescue window and USB-stick check for the screen board
scripts/                pull_from_board.sh, stage_from_repo.sh, board_check.sh, screen_board.sh (+ _inspect, _precheck, _preflight_mac) for the screen board
config/                 systemd units, nginx files, can0 udev rule, pinned Python requirements, crowsnest template, addon version pins
zr_tools/               ZR Tools KlipperScreen panel (copied by the installer)
tools/wm-release/       release tool: takes a new WonderMaker System version (from their website, a TM_T1_SOC file or the screen board) and keeps your changes; not used by the installer
docs/                   HARDWARE.md, WIRING.md, HOST_MCU.md (the Klipper-Mcu service) and images
tests/                  run_tests.sh (installer, fake home) and test_screen.py (ZR Tools panel)
```

`factory/` holds WonderMaker's Klipper and Moonraker (GPL), the factory settings, helper scripts, and their compiled modules and MCU firmware (WonderMaker's binaries, see [factory/README.md](factory/README.md)). Your own calibration is not in the repository.

## 11. Credits and license

Klipper, Moonraker and Fluidd are their own projects and licenses. The Anycubic ACE Pro and WonderMaker are trademarks of their owners; this project is unaffiliated. Layout inspired by [acepro-any-klipper](https://github.com/ducati1198/acepro-any-klipper). The Fluidd Toolheads card, the ACE Pro driver config and the OrcaSlicer plugin live in [wm-ultra-fluidd-acepro-panel](https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel) ([plugin](https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel/tree/main/orca_plugin)). This repository is under the GPL v3, see [LICENSE](LICENSE).

## Tools: new WonderMaker releases (tools/wm-release)

> **Permitted use.** This tool exists only to let a Raspberry Pi interoperate with, and maintain, WonderMaker printers that you own. Its ability to open WonderMaker's encrypted `TM_T1_SOC` files may only be used for that purpose: do not use it, or the information it produces, for anything else, and do not redistribute WonderMaker's firmware or decrypted files.

`tools/wm-release/wm_release.py` brings a new WonderMaker System release (1.1.14 and later) to the Pi **without losing your own changes**. It is separate from the installer; `git pull` or `./installer.sh --get-latest` keeps it up to date with the rest of this folder.

```bash
cd ~/wm-ultra-rpi
python3 tools/wm-release/wm_release.py        # menu; option 1 asks: old screen board, or WonderMaker website
```

- **From WonderMaker's website, no screen board needed:** it downloads the encrypted `TM_T1_SOC` from their firmware page, decrypts it on the Pi, compares it with the previous version and your live files, and shows the plan. Your files change only after you type `APPLY` (a backup is made first; `rollback` undoes it). `printer.cfg`, `saved_variables.cfg` and `tmt1.ini` are never changed.
- **Also:** open a `TM_T1_SOC` file you already have, keep downloaded versions for offline reinstall or downgrade, compare two versions, settings, and a guarded MCU flash step that only runs after you type `FLASH`.
- **First time:** let option 1 (web) record the version you run now as the baseline. When WonderMaker publishes a newer one, run option 1 again.

Full guide: [tools/wm-release/README.md](tools/wm-release/README.md). Like the rest of this project it is **not tested with a running printer yet**.

## Klipper gcode shell command (installed automatically)

The installer copies it into Klipper without asking (`--shell-command off` skips it, and the menu can remove it). It copies Arksine's `gcode_shell_command` module into Klipper. It adds one command, `RUN_SHELL_COMMAND CMD=name`, which runs a Linux command or script from a G-code macro. It does nothing until you define a command in `printer.cfg` and restart Klipper:

```
[gcode_shell_command hello]
command: echo hello
timeout: 2.0
verbose: True
```

Run it with `RUN_SHELL_COMMAND CMD=hello`; extra words go in `PARAMS="a b"`. Commands run as the Pi user `t13dp` and are stopped after `timeout` seconds. Only add commands you trust, since anything that can send G-code to the printer (Fluidd console, a sliced file) can start them. If you remove the extension while `printer.cfg` still has a `[gcode_shell_command ...]` section, Klipper will not start. `--doctor` checks that the file is in place, and `--uninstall` removes it.

## Backup before every update

`./installer.sh --update` (and every add-on install from the menu) first saves your config, calibration and database to `~/wm-backups/wm-backup-<model>-before-update-<date>.tgz` and prints its path. The newest 5 of these are kept. Put one back with `./installer.sh --restore <file>` (Backup and restore in the menu). Skip it with `--no-backup`. It is private (mode 600); do not publish it.

## Status page and Network and system

- **Status** (Check and fix → Status, or `./installer.sh --status`): one read-only page with the version, address, Pi temperature, power flags, disk and memory, Klipper / Moonraker / nginx state, can0 and the CAN ids in the config (placeholders are called out), every add-on's state, the newest backup and the newest log.
- **Network and system** (Advanced → Network and system): **Show** (`--system-info`: host name, time zone, clock, addresses, Wi-Fi, gateway), **Set the time zone** (`--set-timezone America/Toronto`) and **Change the host name** (`--set-hostname name`). Both changes ask first; the host name default is no and warns that `oldname.local` stops working. Nothing restarts.

## Anycubic ACE Pro (optional add-on)

If you have an Anycubic ACE Pro (feeder and dryer), the install asks **"Do you have an Anycubic ACE Pro to connect?"** (default no). Answer yes there, or add it later from the menu (Add-ons) or with `./installer.sh --update --acepro on`. The ACE Pro is only used to load, unload and dry filament; the four toolheads still do the switching.

The ACE Pro driver and its config belong to the project [wm-ultra-fluidd-acepro-panel](https://github.com/ducati1198/wm-ultra-fluidd-acepro-panel). This installer downloads it to `~/wm-ultra-fluidd-acepro-panel` (updated with `git pull` on every `--update`) and runs **its own installer** with the default answers, so you get what that project's README describes: the driver linked into Klipper's `extras` (`ace`, `temperature_ace.py`, `virtual_pins.py`), the four config files `wm_ace_driver.cfg`, `wm_ace.cfg`, `wm_endless.cfg`, `wm_stats.cfg` with their include lines in `printer.cfg`, and the endless-spool macros. Keep the downloaded folder: the links point into it. Klipper loads the driver at its next restart, and the ACE Pro is plugged into a USB port of the Pi. The Fluidd Toolheads panel itself is installed by this installer in any case; the ACE parts of that panel appear once Klipper reports an ACE.

Without an ACE Pro none of this is installed. The Doctor checks the folder, the config and the link, and Fix everything repairs them.

**Remove it:** Uninstall → Anycubic ACE Pro, or `./installer.sh --remove acepro`. It runs the project's uninstaller and then removes anything left: the four config files and their include lines (a copy of `printer.cfg` is kept as `printer.cfg.wm-before-acepro-removal-<time>`), the links in Klipper's `extras`, the downloaded `~/wm-ultra-fluidd-acepro-panel` and its saved settings file. It asks whether to also delete `~/acepro-backup`, the saved copies the ACE installer made (they are the only way to bring the ACE install back; Erase everything deletes them). The Fluidd panel stays: it works without an ACE. Klipper needs a restart afterwards.

## Spoolman (optional add-on)

[Spoolman](https://github.com/Donkie/Spoolman) by Donkie tracks your filament spools; Fluidd shows them. Add it from the menu (Add-ons) or with `./installer.sh --update --spoolman on`. It follows the steps KIAUH uses: downloads Spoolman's latest release (`spoolman.zip`) to `~/Spoolman`, runs its own `scripts/install.sh` (service `Spoolman`, port 7912), adds `[spoolman]` and an update entry to `moonraker.conf` (a copy is kept) and lets Moonraker manage the service (`moonraker.asvc`). Open `http://<Pi address>:7912` to add spools. Remove it with Uninstall → Spoolman: your spool database in `~/.local/share/spoolman` is kept unless you answer yes to its own question (Erase everything deletes it). Not yet tried on a WonderMaker printer.

## Klippain Shake&Tune (optional add-on)

[Klippain Shake&Tune](https://github.com/Frix-x/klippain-shaketune) by Frix-x makes input shaper and vibration graphs. Add it from the menu (Add-ons) or with `./installer.sh --update --shaketune on`. The installer follows the maker's install steps but never restarts Klipper or Moonraker: it installs `libopenblas-dev`, clones the pinned version to `~/klippain_shaketune`, installs its Python packages in `~/klippy-env`, links it into Klipper's extras (only if it imports), adds `shaketune.cfg` and `[include shaketune.cfg]` to `printer.cfg` (a copy is kept) and a Fluidd update entry. Restart Klipper from Fluidd afterwards. It uses the `[resonance_tester]` and accelerometer already in WonderMaker's config. Not yet tried on a WonderMaker printer. Remove it with Uninstall → Shake&Tune.

## Remote access add-ons: Obico, OctoApp, OctoEverywhere (optional)

Three optional services that let you watch and control the printer from outside the house, from a phone app, and get notifications. Each is made by someone else, needs an account of yours, and sends data to its own service: install only what you want. They are not part of the install questions: add them from the menu (Add-ons) or use `--obico on`, `--octoapp on`, `--octoeverywhere on` (`off` to skip). All three are installed **next to** WonderMaker's Klipper and Moonraker: each gets its own Python environment, so the Python 3.9 environments used by Klipper and Moonraker are not touched.

| Add-on | Installed with | Link it to your account |
|---|---|---|
| **Obico** | `git clone` of moonraker-obico, then its own plain `./install.sh`. Obico asks you itself which server to use (app.obico.io or your own) and links the printer | its installer shows the 6-digit code |
| **OctoApp** | OctoApp's own method 1c: `git clone` then `./install.sh <moonraker.conf> moonraker.service` | open the OctoApp phone app on the same network; it registers by itself |
| **OctoEverywhere** | `git clone` then `./install.sh <moonraker.conf> moonraker.service` | its installer prints a link to open in a browser |

Obico, like OctoApp and OctoEverywhere, asks its own questions, so the installer only starts it when you run it in a terminal without `--yes`. Otherwise it downloads it and prints the command to finish: `cd ~/moonraker-obico && ./install.sh`.

OctoApp and OctoEverywhere ask questions while they install, so the installer only starts them when you run it in a terminal without `--yes`. Otherwise it downloads them and prints the exact command to finish (`cd ~/octoapp && ./install.sh ~/printer_data/config/moonraker.conf moonraker.service`).

**Why these work with WonderMaker's Klipper and Moonraker.** The checks I could do without a printer:
- OctoApp's and OctoEverywhere's code that finds Moonraker (it reads `moonraker.service` and its `moonraker.env`) was run against this repository's `moonraker.service`, and finds `~/printer_data/config/moonraker.conf`.
- WonderMaker's `printer.cfg` already has what Obico's macros use: `[pause_resume]`, `[respond]`, `[virtual_sdcard]`, `[display_status]`, `[exclude_object]`, and the `PAUSE`, `RESUME` and `CANCEL_PRINT` macros. WonderMaker's Klipper supports `action_call_remote_method`.
- WonderMaker's `moonraker.conf` trusts `127.0.0.0/8`, which is where the add-ons connect from.

**Not tested on a real Pi:** nobody has run these three installers on a Pi with this repository. Their downloads and account steps could not be tried from the build environment.

**Things to know**
- Each add-on adds an `[update_manager ...]` section to `moonraker.conf`. WonderMaker's Klipper and Moonraker are not git clones, so Fluidd may list them as not updatable or invalid. Do not press update on those two; use `./installer.sh --update`.
- `./installer.sh --update` does not run these installers again once installed; update them from Fluidd or with `git pull` in their folder. `--doctor` checks they are downloaded and running.
- `./installer.sh --uninstall` does not remove them (they are linked to your accounts). Use `cd ~/octoapp && ./uninstall.sh`, `cd ~/octoeverywhere && ./uninstall.sh`, or the Uninstall steps in `~/moonraker-obico/README.md`.

## The menu

`./installer.sh` with no options at a terminal always opens a numbered menu, also on a Pi where nothing is installed yet (choose **1) Install or reinstall** there). `./installer.sh --menu` opens it any time; `./installer.sh --install`, or any other option, skips the menu and does that one thing. Each menu entry runs the same installer option you could type yourself, so nothing works differently from the command line.

```
WonderMaker Ultra Raspberry Pi replacement - installer 1.12.0
  Klipper: active   Moonraker: active   nginx: active
  3 new change(s) on GitHub (version 1.6.1). Choose 2 to see them and update.

   1) Install or reinstall         Sets up Klipper, Moonraker and Fluidd; asks a few plain questions
   2) Update                       See what is new, then download the newest version and update (your printer_data is kept)
   3) Add-ons                      Touchscreen, webcam, timelapse, shell command, Klippain Shake&Tune, Spoolman, Anycubic ACE Pro, Obico, OctoApp, OctoEverywhere
   4) Check and fix                Doctor, repair, hardware test, status page
   5) Backup and restore           Save and restore config, calibration and database
   6) Uninstall                    Remove any add-on, Fluidd, Moonraker, Klipper, your data, or erase everything
   7) Advanced                     First start, start or stop Klipper, support bundle, last log, network and system
   8) Dry run of the install       Asks the same questions, shows every change, changes nothing
   0) Exit
```

- **Klipper is restarted** at the end of every install and update, and the installer waits for "ready". It is never started this way when it is off (a fresh install): `--first-start` does that after the connection check.
- **Update** works without git: *Update now* runs `./installer.sh --get-latest` (a `git pull` in a clone, the GitHub download otherwise) and then the update. On a Pi where nothing is installed yet it says so instead of failing. **Dry run** is `./installer.sh --install --dry-run`.
- **Progress bars:** the install shows "Step N of 14" with a percent bar, the update "Update step N of 8", and *All programs* / *Erase everything* "Removing <name> (step N of M)". Slow steps print "still working" with the elapsed time every 30 seconds.
- **Status on top:** the version, whether Klipper, Moonraker and nginx are running, and (if the Pi is online) whether GitHub has newer changes.
- **A print stops changes:** while a print is running the menu says so and every entry that changes something refuses, as the command line does. Looking (status, quick check) still works.
- **Add-ons** shows `[installed]`, `[running]` or `[not installed]` for each add-on. Pick one to install it, or to remove it after a confirmation (`./installer.sh --remove obico|octoapp|octoeverywhere|shell-command|shaketune|spoolman|acepro`). Removing uses the makers' own uninstallers where they have one; your account on their website stays. Removing Obico also removes the include line it added to `printer.cfg` (a copy is saved first), because Klipper would not start with it pointing at a deleted file. Removing the shell command extension is refused while `printer.cfg` still has a `[gcode_shell_command ...]` section.
- **Backup and restore:** *Restore a backup* shows the folder the backups are kept in (`~/wm-backups`) and lists the backup files there, newest first, with size and date. Press the number of the one you want; a safety copy of the current settings is made before anything is replaced. The last number lets you type the path of a backup file somewhere else.
- **Uninstall** (menu entry 6) lists everything the installer puts on the Pi, each with `[installed]` or `[not installed]`. Pick a number to see what goes and confirm; nothing changes before you confirm. The same removals work from the command line with `./installer.sh --remove NAME`:

  | NAME | What it removes |
  |---|---|
  | `screen` | KlipperScreen: runs its own `scripts/Uninstall.sh` first (the ZR Tools macros and `zr_screen.conf` stay) |
  | `webcam` | runs crowsnest's own `make uninstall` first, then removes the service and `~/crowsnest` (your `crowsnest.conf` stays; crowsnest asks for a reboot afterwards) |
  | `timelapse` | the timelapse component and `~/moonraker-timelapse`; the `[timelapse]` section in `moonraker.conf` is commented out (a copy is saved) |
  | `shell-command` | the gcode shell command extension (refused while `printer.cfg` still uses it) |
  | `obico`, `octoapp`, `octoeverywhere` | OctoApp and OctoEverywhere: their own `./uninstall.sh` runs first (at a terminal it asks you its own questions). Obico has no uninstall script (`./install.sh -u` only prints the steps), so the installer does exactly the steps it lists: stop, disable and delete the service, `reset-failed`, delete `~/moonraker-obico` and its environment, and remove the two include lines. Your account on their website stays |
  | `fluidd` | the Fluidd web page (with the Toolheads panel) and its nginx site; `./installer.sh --update` puts it back |
  | `moonraker`, `klipper` | the service, the program folder and its Python environment; `~/printer_data` stays |
  | `network-manager` | switches the Pi back to dhcpcd, only if this installer switched it (effective at the next reboot) |
  | `data` | `~/printer_data` and `~/TM_T1` (config, calibration, database, gcode files, factory settings). A backup is made first and you must type `DELETE` |
  | `system` | the services, nginx files and can0 rule listed in the install record (same as `--uninstall`) |
  | `cleanup` | a page of installer-made files with their sizes, see below |
  | `all` | **All programs** (menu entry "All programs"): every program above and the system files, but not `data`, not `cleanup` and not NetworkManager. It lists what is installed, then you must type `REMOVE`. At the end it lists what is still on the Pi and how to remove it. Your printer data, backups and installer files are not touched |
  | `erase` | everything: every program, the system files, NetworkManager switched back (if the installer switched it), **your printer data** (`~/printer_data`, `~/TM_T1`), and every installer file (backups, support bundles, logs, the copy from the old board, moved-aside folders, saved copies, the records). **No backup is made.** Only the installer folder stays, and the log of the run itself. It lists everything first and you must type `ERASE` |

  A running print blocks all of them.

  **Clean up installer files** (`./installer.sh --remove cleanup`) lists these groups with their size, and you delete them one at a time. Your printer data is never in the list. Groups that may hold the only copy of something need you to type `DELETE`; the others ask y/n.

  | Group | What it is | Confirmation |
  |---|---|---|
  | Settings backups | `~/wm-backups` (backups and the safety copies made before a restore or a data delete) | type `DELETE` |
  | Support bundles | `~/wm-support-*.tgz` | y/n |
  | Installer logs | `~/wm-install-logs`, the log of each run that changed something | y/n |
  | Software copied from the old board | `~/wm-stage`, the copy of klipper, moonraker and data an install made from the old board (pull it again if you need it) | type `DELETE` |
  | Folders moved aside | `~/wm-rpi-backup/old-*`, the old klipper, moonraker and printer_data folders an install moved out of the way | type `DELETE` |
  | Old Fluidd copies | `~/wm-rpi-backup/fluidd-*` | type `DELETE` |
  | Config safety copies | files like `printer.cfg.wm-model-bak` in your config folder | y/n |
  | Add-on download copies | the panel download cache and Obico, OctoApp or OctoEverywhere folders that have no service installed | y/n |
  | Installer records | `~/wm-rpi-backup` (saved answers and the install record; afterwards the installer no longer knows what is installed) | type `DELETE` |
  | The installer folder | the repository folder this script is in | type `DELETE` |
- **Advanced → Start Klipper again** (`./installer.sh --start-klipper`) undoes *Stop Klipper*: it enables Klipper at boot and starts it now, without the hardware checks. *First start* does the same after checking the main board and can0.
- **NetworkManager (for the screen's Network panel):** off by default. Add it later with `./installer.sh --update --network-manager on` or from **Add-ons → NetworkManager**. If the Pi was switched by this installer, **Uninstall → NetworkManager** (`./installer.sh --remove network-manager`) enables dhcpcd again and disables NetworkManager, again taking effect at the next reboot. If NetworkManager was already in use, the installer leaves your network setup alone. If the network does not come back after the reboot: plug in a cable, or use the screen's Network panel, or `sudo nmtui` on the Pi.
- **Logs:** every run that changes something (install, update, repair, remove, restore, undo, uninstall, first start, start or stop Klipper, doctor, backup, hardware test) is written to `~/wm-install-logs/installer-<what>-<date>.log`, and its path is printed at the end. At a terminal the installer runs itself inside `script`, so the screen behaves exactly as before (colours, prompts, the add-ons' own questions) and everything shown is recorded; without a terminal the output is copied with `tee`. In the file, colour codes are removed, progress bars are reduced to their last line, and passwords and tokens are replaced by `<removed>`. The folder and files are private (`700` / `600`), the newest 20 logs are kept, `./installer.sh --show-log` shows the newest one, and `--support-bundle` includes it (with private addresses removed too). Dry runs, read-only checks and the menu itself write no log. Delete the logs under Uninstall → Clean up installer files.
- **Deleting needs no manual sudo:** when a file or folder cannot be deleted as the Pi user (an uninstaller that ran as root can leave root-owned files, for example `~/octoeverywhere-env`), the installer retries with `sudo` and says so. It also removes what the add-ons leave next to their folders: `~/crowsnest-env`, `~/octoapp-installer.log`, `~/octoeverywhere-installer.log` and the add-on's own files in your config folder. Nothing is removed without a confirmation first: a y/n, or typing `DELETE` or `REMOVE` for the bigger ones.
- **Official uninstallers first:** every removal that has an official uninstaller runs it first (KlipperScreen, crowsnest, OctoApp, OctoEverywhere). The installer then checks the result and finishes anything left (service file, folders), so a failed official uninstaller does not leave a half-removed add-on. It also removes the add-on's `[update_manager ...]` section from `moonraker.conf` (a copy is kept), so Fluidd stops listing it. Moonraker timelapse and the shell command have no uninstaller; their files are removed by the installer.
- **PolKit warning:** if Fluidd shows "PolKit warnings detected" (Moonraker says `org.freedesktop.packagekit.* is not registered`), the cause is the missing `packagekit` package. The installer checks for this after every install, update and repair, every time the menu opens, and in `--doctor`. It asks Moonraker for its warnings; when it finds this one it installs PackageKit, installs Moonraker's PolicyKit rule, restarts Moonraker and looks again. During a print it only tells you. If PackageKit cannot be installed (no internet), it sets `enable_system_updates: False` in `moonraker.conf` (a copy is saved), so Moonraker stops managing Debian packages.
- **KIAUH:** if `~/kiauh` exists the menu warns you. KIAUH installs stock Klipper and Moonraker and would break WonderMaker's compiled modules; this installer manages the WonderMaker versions.
- `./installer.sh --webcam on|off` and `--timelapse on|off` (with `--update`) are the matching options for those two add-ons.
