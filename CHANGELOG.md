# Changelog

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
