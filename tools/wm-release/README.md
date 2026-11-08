# wm_release.py - private WonderMaker release tool

For bringing a new WonderMaker System release (for example 1.1.14) to your Pi **without losing your own changes**.
It is not part of any installer and no installer runs it. It lives in the `tools/wm-release/` folder of the repo, so `git pull` brings it to the Pi (the repo is public, so this folder is public too).

## Where the files are

| What | Where |
|---|---|
| The tool, this README, the tests | `wm-ultra-rpi/tools/wm-release/` (on the Pi: `~/wm-ultra-rpi/tools/wm-release/`) (`wm_release.py`, `README.md`, `test.sh`) |
| What the tool saves (baselines, releases, reports, backups, notes, history) | `~/wm-private-data/` on the machine where you run it (change with `WMR_HOME`) |
| The files it compares against and changes | your home folder, `~` (change with `WMR_LIVE_HOME`) |

Inside `~/wm-private-data/`:

| Folder / file | Holds |
|---|---|
| `baseline/<version>/` | the older version you compare against (1.1.13, later 1.1.14, ...) |
| `releases/<version>/` | the new version you fetched |
| `reports/` | every diff report as a text file |
| `backups/` | the backup made just before `apply` (used by `rollback`) |
| `conflicts/<version>/` | files where you and WonderMaker changed the same place (`.theirs` and `.merge`) |
| `notes/` | your notes and the test list for each version |
| `release-log.jsonl` | the history of everything the tool did (`log` prints it) |

## The idea in one minute

1. **Before** you update the board, save its current files as the **baseline** (the version before).
2. Update the board with WonderMaker's own updater (the encrypted `TM_T1_SOC` file cannot be opened by this tool).
3. **Fetch** the new files from the board (read-only).
4. **Diff**: it shows what WonderMaker changed, what you changed, and what clashes.
5. **Apply** (only the printer's own files), after a backup. **Rollback** if you do not like it.
6. **Promote** the new version, so it becomes the baseline for the next release.

Nothing is ever changed unless you run `apply --apply` and type `APPLY` (or `rollback` and type `ROLLBACK`). It never flashes MCU firmware.

## The menu (easiest way)

```
python3 wm_release.py
```
With no command it opens a numbered menu. The top shows where you are (baseline saved, new version fetched, board address, last action) and the next step is the first one that is still empty.

| Key | Does | Same as |
|---|---|---|
| 1 | Save the baseline from the board (do it before the update) | `init-baseline --from-board` |
| 2 | Fetch the new version from the board | `fetch --from-board` |
| 3 | Show the differences | `diff` |
| 4 | Check MCU firmware | `mcu` |
| 5 | Apply: shows the plan, then asks again; you type `yes`, then `APPLY` | `apply` / `apply --apply` |
| 6 | Test list and a note | `checklist`, `notes` |
| 7 | Roll back the last apply | `rollback` |
| 8 | Keep this version as the next baseline | `promote` |
| 9 | History | `log` |
| s | Set the board address (remembered in `config.json` in the data folder) | |

The commands below still work on their own.

## How to use (step by step)

Run everything from the folder that holds `wm_release.py`.

### One-time: let the Pi log in to the board without a password
The tool reads the board over SSH in batch mode. Either run `ssh-copy-id t13dp@ADDRESS` from the Pi, or use a key the board already accepts and tell the tool: `export WMR_BOARD_KEY=/path/to/key`. You give the board's address each time (`--from-board ADDRESS`) or set it once with `export WMR_BOARD_HOST=ADDRESS`. The user is `t13dp` (change with `WMR_BOARD_USER`).

### Step 1 - save the baseline (BEFORE the update)
```
python3 wm_release.py init-baseline --from-board ADDRESS
```
Reads the version from the board's `iso_version.txt` (today: 1.1.13) and records its files. If you cannot reach the board, `init-baseline` alone records the copy of 1.1.13 that is in this repo (`factory/ultra-s`), but then the checks of the rest of the board (screen app, Fluidd, services, pip) are not possible.

### Step 2 - update the board
With WonderMaker's own procedure. Wait until it finished and restarted.

### Step 3 - fetch the new version
```
python3 wm_release.py fetch --from-board ADDRESS
```
Copies the printer's own folders and notes checksums of everything else. Nothing is changed on the board.
If you copied the updated folders to a folder yourself: `fetch --from-dir /path --version 1.1.14`.

### Step 4 - read the difference
```
python3 wm_release.py diff 1.1.14
```
The baseline used is the newest one **older** than 1.1.14. The report shows:

| Section | Meaning |
|---|---|
| TAKE | WonderMaker changed it, you did not: safe to take |
| ADD | new in the release, not on your Pi: safe to add |
| MERGE | both changed it, in different places: merges cleanly |
| CONFLICT | both changed the same place, or a binary: you decide |
| KEEP_MINE | only you changed it: stays |
| WHITESPACE | your file differs only in line endings or trailing spaces: harmless, stays (and never causes a conflict) |
| PROTECTED | `printer.cfg`, `saved_variables.cfg`, `tmt1.ini`: never applied, look yourself |
| REMOVED | removed in the release: nothing is deleted on your Pi |
| Everything else on the board | screen app, Fluidd, crowsnest, services, nginx, udev: checksums only, never applied |
| Python package versions | `pip freeze` differences of `klippy-env` and `moonraker-env` |
| Python files changed or new | every `.py` that differs |
| Macros defined in more than one file | the later include wins in Klipper |
| Things to do | restart needed, requirements changed, macros to re-test |

The report is also saved in `reports/`. Read it fully before step 5.

### Step 5 - MCU firmware (if the report says `mcu_update/` changed)
```
python3 wm_release.py mcu ~/wm-private-data/releases/1.1.14/mcu_update
```
(or a WonderMaker zip/folder that has `mcu_info.ini`). It checks every part's md5, compares versions with the baseline and with what Klipper reports, warns if `can0` is down, and prints WonderMaker's own flashing commands. It never flashes. A part whose md5 does not match is marked `BAD`: do not flash it.

### Step 6 - plan, then apply
```
python3 wm_release.py apply 1.1.14             # only shows the plan, changes nothing
python3 wm_release.py apply 1.1.14 --apply     # makes a backup, asks you to type APPLY, then changes the files
```
It refuses while a print is running (add `--force` only if you are sure). Conflicts are left alone: their versions are saved in `conflicts/1.1.14/` for you to merge by hand. Afterwards restart Klipper: `sudo systemctl restart klipper`.

### Step 7 - test
```
python3 wm_release.py checklist 1.1.14
python3 wm_release.py notes 1.1.14 --add "tool change T2 now slower, re-check offsets"
```
The checklist has the usual items plus extra ones for what actually changed (macros, offsets, tool change, load cell, hub, extruder, Moonraker, Klipper core).

### Step 8 - undo, or keep
```
python3 wm_release.py rollback            # newest backup; asks you to type ROLLBACK
python3 wm_release.py promote 1.1.14      # when you are happy: it becomes the next baseline
```

## All commands

| Command | What it does | Changes files? |
|---|---|---|
| `status` | baselines, fetched releases, backups | no |
| `init-baseline [--from-board [HOST]] [--from-dir DIR] [--src DIR] [--version V] [--force]` | records a baseline | only the data folder |
| `fetch --from-board [HOST]` / `--from-dir DIR [--version V]` | copies a release for comparing | only the data folder |
| `diff VERSION` | the comparison and the saved report | no |
| `mcu ZIP_OR_FOLDER` | MCU firmware check and flashing steps | no |
| `apply VERSION [--apply] [--force]` | plan; with `--apply`: backup, then change | yes, after `APPLY` |
| `rollback [BACKUP] [--force]` | puts the backup back | yes, after `ROLLBACK` |
| `promote VERSION` | makes a fetched release the next baseline | only the data folder |
| `checklist VERSION` | test list | no |
| `notes VERSION [--add TEXT]` | your notes | only the data folder |
| `log` | history | no |

## What is compared in detail

- **Copied and compared line by line, and applied by `apply`:** `~/klipper`, `~/moonraker`, `~/printer_data/config`, `~/mcu_update`, `~/TM_T1/scripts`.
- **Compared by checksum, never applied:** `~/TM_T1/bin`, `~/TM_T1/other`, `~/TM_T1/access`, `~/moonraker-timelapse`, `~/fluidd-config`, `~/crowsnest`, `~/fluidd`, `~/access`, `/etc/systemd/system/*.service`, `/etc/nginx/conf.d`, `/etc/nginx/sites-enabled`, `/etc/udev/rules.d/*wm*.rules`, and the `pip freeze` of the two Python environments.
- **Ignored:** `.git`, `__pycache__`, `*.pyc`, `*.log`, `plr*.ini*`, `client_log.txt`, `*.zrbak_*`, `*.bkp`, `KlipperScreen` (your own installation).
- **Never changed by `apply`:** `printer.cfg`, `saved_variables.cfg`, `tmt1.ini`, and anything outside the five printer folders.
- Merging uses `git merge-file` (git must be installed). A file changed by both of you in different places merges; the same place is a conflict.

## Limits - read this

- **`TM_T1_SOC` (the file in WonderMaker's firmware zip) is encrypted.** This tool does not open it. It works from the files on the board after WonderMaker's own updater applied the update.
- The tool was tested only on made-up 1.1.14 files. The first real run needs your attention: read the `diff` report before `apply`.
- MCU boards are flashed by WonderMaker's scripts, by you, one part at a time. Fix `can0` first.
- System files (`/etc/...`) need sudo and are only reported.
- After an `apply` that touched Klipper or Moonraker code, restart the services; if `requirements` changed, the Python environments need rebuilding (the installer's `--update` does that).

## Settings (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `WMR_HOME` | `~/wm-private-data` | where the tool keeps its data |
| `WMR_LIVE_HOME` | `~` | the folder holding your live files |
| `WMR_MOONRAKER` | `http://127.0.0.1:7125` | used to see if a print runs and which MCU versions are installed |
| `WMR_BOARD_HOST` | (none) | address of the screen board, used when `--from-board` has no address |
| `WMR_BOARD_USER` | `t13dp` | user on the screen board |
| `WMR_BOARD_KEY` | (none) | SSH key for the board |

## Tests

`bash tools/wm-release/test.sh` runs 57 checks on throwaway folders (it never touches your real files).
