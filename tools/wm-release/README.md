# wm_release.py - WonderMaker release tool (version 1.5.0)

For bringing a new WonderMaker System release (for example 1.1.14) to your Pi **without losing your own changes**.
It is not part of any installer and no installer runs it. It lives in the `tools/wm-release/` folder of the repo, so `git pull` brings it to the Pi (the repo is public, so this folder is public too).

> **Permitted use.** This tool exists only to let a Raspberry Pi interoperate with, and maintain, WonderMaker printers that you own. Its ability to open WonderMaker's encrypted `TM_T1_SOC` files may only be used for that purpose: do not use it, or the information it produces, for anything else, and do not redistribute WonderMaker's firmware or decrypted files.

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
2. Get the new version. Either update the factory board with WonderMaker's own updater and then **fetch** from it, **or** — new — point the tool straight at the encrypted **`TM_T1_SOC`** file on the Pi with `--from-soc` (menu option **f**); it decrypts it locally, so no factory board is needed.
3. **Fetch** the new files from the board (read-only).
4. **Diff**: it shows what WonderMaker changed, what you changed, and what clashes.
5. **Apply** (only the printer's own files), after a backup. **Rollback** if you do not like it.
6. **Promote** the new version, so it becomes the baseline for the next release.

Nothing is ever changed unless you run `apply --apply` and type `APPLY` (or `rollback` and type `ROLLBACK`). MCU firmware is only flashed by the separate, guarded `flash --run` (menu `m`), after you type `FLASH`; option 1 never flashes.

## The menu (easiest way)

```
python3 wm_release.py
```
With no command it opens a numbered menu. The top shows where you are (baselines saved, new version fetched, board address, last action).

**Option 1 does all the steps for you.** It looks at where you are and does what is needed next:

| Where you are | What option 1 does |
|---|---|
| (always first) | Asks for the board address: the saved one is shown, press Enter to keep it or type another. |
| No baseline saved yet | Logs in to the board, saves its files as the baseline (the version before the update), and tells you to update the board next. |
| The board still has the baseline version | Says there is nothing new yet. |
| The board has a newer System version | Fetches it, compares it with the baseline and your live files, checks the MCU firmware, shows the plan, then asks if you want to apply it (backup first, you type `yes` and then `APPLY`), prints the test list, and asks if this version becomes the next baseline. |

The same thing from the command line: `python3 wm_release.py all`.

| Key | Does | Same as |
|---|---|---|
| 1 | All steps (above). **Asks first: the old screen board, or WonderMaker's website** | `all` (`--source board\|web`) |
| 2 | Save the baseline from the board (before the update) | `init-baseline --from-board` |
| 3 | Fetch the new version from the board | `fetch --from-board` |
| f | Open a `TM_T1_SOC` file on the Pi (decrypt it here; no board needed) | `fetch --from-soc FILE` |
| w | Download the newest from WonderMaker's website, then decrypt it here | `fetch --from-web` |
| a | Saved firmware: list the kept SOC zips; reinstall or downgrade one offline | `firmware`, `fetch --from-archive VER` |
| v | Compare two versions: what WonderMaker changed between them (read only) | `compare OLD NEW` |
| 4 | Show the differences | `diff` |
| 5 | Check MCU firmware | `mcu` |
| 6 | Apply: shows the plan, then asks again; you type `yes`, then `APPLY` | `apply` / `apply --apply` |
| 7 | Test list and a note | `checklist`, `notes` |
| 8 | Roll back the last apply | `rollback` |
| m | Flash MCU firmware (guarded: dry run first, then you type `FLASH`) | `flash [main\|thr\|ext\|hub\|cell] --run` |
| 9 | Keep this version as the next baseline | `promote` |
| x | Clean up: delete every file this tool created (dry run first; you type `DELETE`) | `clean [--run] [--keep-firmware] [--keep-backups]` |
| g | Settings: decrypt key, firmware page URL, board address | `settings` |
| h | History | `log` |
| s | Board address and user name (remembered in `config.json` in the data folder) | |

### Opening a `TM_T1_SOC` file on the Pi (no factory board)

A `TM_T1_SOC` file is WonderMaker's encrypted System package. It is a Debian
package wrapped in two layers: a repeating-key XOR, then OpenSSL AES-256-CBC
(`Salted__` + salt, key derived with `EVP_BytesToKey`/SHA-256). The tool now
decrypts it **on the Pi** and feeds it into the same diff/apply flow, so you no
longer need the factory screen board to take a new release:

```bash
# treat the encrypted file as the new version, then compare and apply as usual
python3 wm_release.py fetch --from-soc ~/TM_T1_SOC
python3 wm_release.py diff 1.1.14
python3 wm_release.py apply 1.1.14 --apply     # after you type APPLY
```

**Or download it straight from WonderMaker** (same firmware page the `check`
command reads) with `--from-web` (menu option **w**). It finds the
`tm_t1_soc(version).zip` link, downloads it, pulls the `TM_T1_SOC` out of the
zip, and decrypts it here — no board, no manual download:

```bash
python3 wm_release.py fetch --from-web            # newest version on the page
python3 wm_release.py fetch --from-web 1.1.14     # a specific version
python3 wm_release.py diff 1.1.14
```

If WonderMaker ever changes that page's layout and the link isn't found, the
tool says so and prints what it did find; download the zip yourself and fall
back to `--from-soc FILE`. Point it at a mirror with `WMR_WIKI_URL` if needed.

- Only `openssl` is required (already on Raspberry Pi OS); no extra Python packages.
- The bundled Klipper MCU firmware is read for the `mcu` check but, as always,
  **nothing is ever flashed** by this tool.
- The SoC's own Android `boot.img` and kernel modules are ignored — the Pi boots
  its own kernel.
- The key is WonderMaker's own, read from the stock `client` binary. If a future
  firmware changes it, set `WMR_SOC_KEY=<newkey>`.

### Option 1 from the website (no screen board)

Option 1 (`all`) now asks first: **board** or **web**. The web path:
1. reads WonderMaker's firmware page for the newest System version;
2. if you have no baseline yet, offers to record the current published version as one (needed to keep your own changes on the next update), then stops;
3. if the page has nothing newer than your baseline, says "Up to date";
4. otherwise downloads it (kept in the firmware archive), compares it with your baseline and live files, checks the MCU firmware, shows the plan, and asks before applying — you type `yes` and then `APPLY`. Nothing is applied automatically.

Skip the question with `all --source web` / `all --source board`, or `WMR_SOURCE=web`.

### Firmware archive, compare, settings

- **Firmware archive** - every web download keeps the `tm_t1_soc(x.y.z).zip` in `~/wm-firmware` (change with `WMR_FIRMWARE_DIR`). `firmware` (menu `a`) lists them; `fetch --from-archive 1.1.13` reinstalls or downgrades one with no internet. A repeat download of the same version uses the kept copy.
- **Compare two versions** - `compare 1.1.13 1.1.14` (menu `v`) lists what WonderMaker changed, added and removed between two fetched releases. Read only; your live files are not involved.
- **Settings** - `settings` (menu `g`) shows and changes the decrypt key, the firmware page URL and the board address (saved in `config.json`). `WMR_SOC_KEY` / `WMR_WIKI_URL` in the environment still win over saved values.

### Flashing MCU firmware (guarded)

`flash [main|thr|ext|hub|cell]` (menu `m`) runs the flash script that a release installed in `~/mcu_update` (`mcu_update.sh`, `mcu_update_THRs.sh`, ...).
- Without `--run` it is a dry run: it shows `mcu_info.ini` and the exact script it would run.
- With `--run` it refuses while a print is running, then asks you to type `FLASH`.
- It is never part of option 1. Run `mcu` first and do not flash a part marked `BAD`. Wrong or interrupted firmware can leave a board unbootable until it is flashed by hand.

### Logging in to the board (user name and password)
- The tool logs in **once** per run and reuses that connection for every step, so you type the password once.
- It first tries without a password (an SSH key or agent). If the board refuses, it asks for the **user name** (default `t13dp`, remembered) and the **password**.
- The password is typed hidden, kept only in memory, given to `ssh` through a one-shot helper (`SSH_ASKPASS`), **never put on a command line and never saved**. Only the address and the user name are saved.
- You get 3 tries. Needs OpenSSH 8.4 or newer on the Pi (Raspberry Pi OS Bookworm has 9.2). The board must allow SSH password login.
- Prefer a key? `export WMR_BOARD_KEY=/path/to/key` and no password is asked.

The single commands below still work on their own.

## How to use (step by step)

Run everything from the folder that holds `wm_release.py`.

### Logging in
Every step that reads the board asks for its user name and password if it needs to (see "Logging in to the board" above). Nothing to set up first.

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
| `init-baseline [--from-board [HOST]] [--from-dir DIR] [--from-soc FILE] [--src DIR] [--version V] [--force]` | records a baseline | only the data folder |
| `fetch --from-board [HOST]` / `--from-dir DIR` / `--from-soc FILE` / `--from-web [VERSION]` | copies a release for comparing | only the data folder (plus the download for `--from-web`) |
| `diff VERSION` | the comparison and the saved report | no |
| `clean [--run] [--keep-firmware] [--keep-backups]` | lists, then deletes all files the tool created | only the tool's own folders, after `DELETE` |
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
- **Ignored:** `.git`, `__pycache__`, `*.pyc`, `*.log`, `plr*.ini*`, `client_log.txt`, `*.zrbak_*`, `*.bkp`, `*.wm-before-*` (the installer's safety copies), the Pi's own files from `rpi-cfg/`, `KlipperScreen` (your own installation).
- **Never changed by `apply`:** `printer.cfg`, `saved_variables.cfg`, `tmt1.ini`, the Pi's own files from `rpi-cfg/` (`wm_calibration.cfg`), and anything outside the five printer folders.
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
| `WMR_BOARD_USER` | `t13dp` | user on the screen board (asked and remembered when not set) |
| `WMR_BOARD_KEY` | (none) | SSH key for the board |

## Updating the tool

To get the newest version of the tool onto the Pi:

```
cd ~/wm-ultra-rpi
./installer.sh --get-latest
python3 tools/wm-release/wm_release.py --version
```

- The first command downloads the newest files from GitHub. It replaces the tool's files (`wm_release.py`, this README, the tests) along with the rest of the installer folder, and changes nothing else on the printer. It does **not** apply the printer update.
- **Important:** `--get-latest` decides by the installer's version number. If it says "Already up to date" but you know the tool changed, the installer version was not raised yet. Then download just the tool's files:

  ```
  cd ~/wm-ultra-rpi/tools/wm-release
  for f in wm_release.py README.md test.sh; do curl -fsSL -o $f https://raw.githubusercontent.com/ducati1198/wm-ultra-rpi/main/tools/wm-release/$f; done
  ```
- The last command prints the tool's version (`wm_release.py 1.0.0` or newer). Check the "Version history" below to see what changed.
- Your saved data is safe: baselines, fetched releases, reports, backups, the board address and user name, and notes live in `~/wm-private-data`, outside the installer folder, so updating the tool does not touch them.

## Version

`python3 wm_release.py --version` prints the tool's version; the menu title and `status` show it too, and every line in the history (`log`) records the version that wrote it. It is the tool's own number and has nothing to do with the installer's `VERSION` file, so changing the tool's version alone does not publish a GitHub release (the installer's `VERSION` does).

Version history:
- **1.5.0** - knows the Pi's own config files in the repo folder `rpi-cfg/` (today `wm_calibration.cfg`, the calibration macros `WM_BED_LEVELING`, `WM_CAL_ALL`, ...). They are not WonderMaker's, so no release contains them: `apply` never changes them (a release that ships a file with the same name is ignored for it), the baseline and the file lists skip them, `status` reports each one (ok, missing, not included in printer.cfg, or different from the repo copy), `apply` and `diff` warn when a release defines a macro with the same name as one of theirs, and the test list now includes "WM_CAL_HELP lists the calibration macros". Install or repair them with `./installer.sh --rpi-cfg`.
- **1.4.1** - `flash` shows an access check (script, hid-flash, firmware file) and says what to do if the bootloader device needs permissions. It still changes nothing and makes no root change.
- **1.4.0** - knows the machine's version from `~/iso_version.txt` (a short log with `Add System_x.y.z` lines; the newest one is the version in use, the same file the old board has in the home folder). The installer now puts it there (`factory/<model>/iso_version.txt`, System_1.1.13), `apply` adds a line `<date>: Add System_x.y.z` to it, like the factory image, keeping its header and history (rollback puts the old file back), and `status`, the menu header and option 1 (website) use it: they say "up to date" by it, warn when it differs from your baseline, and offer to record the baseline for the version it names. Without the file the tool falls back to its newest baseline, as before.
- **1.3.0** - `clean` (menu `x`): lists and then deletes everything the tool created (`~/wm-private-data`, `~/wm-firmware`, temp files) after you type `DELETE`. It never touches the printer's live files, so updates you applied stay applied; it also removes the baseline and backups, so there is nothing left to roll back to. `--keep-firmware` and `--keep-backups` keep those.
- **1.2.0** - takes WonderMaker releases without the factory screen board: `fetch --from-soc FILE` (decrypts a `TM_T1_SOC` on the Pi) and `fetch --from-web [VERSION]` (menu `w`; downloads it from WonderMaker's firmware page). Option 1 asks first: old screen board or website. Firmware archive (`~/wm-firmware`, `firmware`, `fetch --from-archive`, menu `a`), `compare OLD NEW` (menu `v`), `settings` (menu `g`), guarded `flash` (menu `m`). The tool now finds the repo root from any folder.
- **1.1.0** - checks WonderMaker's firmware page for a newer System version: menu item `c`, command `check`, a line in the menu header and a note at the start of option 1. Read only; works offline too (it just says the page could not be read).
- **1.0.1** - option 1 / `all` always asks for the board address first (the saved one is shown; press Enter to keep it).
- **1.0.0** - option 1 / `all` does every needed step; asks the board's user name and password (hidden, one login, never saved); line-ending and trailing-space differences are not conflicts; board-wide checksums, pip freeze, baseline chosen as the version before the release, `promote`; numbered menu.

## Tests

`bash tools/wm-release/test.sh` runs 119 checks on throwaway folders (it never touches your real files).

## Checking for a new WonderMaker version

`python3 wm_release.py check` (or menu item `c`) reads WonderMaker's firmware download page and finds the highest `tm_t1_soc(x.y.z).zip` listed. It compares that with your newest baseline or fetched release and says "up to date" or "NEW: WonderMaker published x.y.z". The menu header shows the same line, and option 1 prints it before logging in. Nothing is downloaded. If the page cannot be read, or WonderMaker changes its layout, the tool says so and carries on. The page address can be changed with `WMR_WIKI_URL`.
