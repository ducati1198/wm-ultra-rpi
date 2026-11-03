# Hardware notes

Use at your own risk. These notes describe what the software side expects; they are not a wiring manual.

## The two boards

| Board | Role | After the swap |
|---|---|---|
| WM-ZR-M V1.2 (RK3308B), screen/host board | ran Klipper, Moonraker, Fluidd and the touchscreen app | replaced by the Pi |
| WM-ZR-D V1.2, main board | Klipper USB-CAN bridge (USB `1d50:606f`), CAN bus at 1 Mbit to the toolheads and hub | stays (or its replacement) |

Klipper talks to the main board over USB; the main board bridges to the CAN bus. On the Pi the CAN interface is `can0`, set to 1 Mbit and `txqueuelen 1024` by the udev rule in `config/99-wm-can0.rules`.

## Software expectations

- User **`t13dp`**, home `/home/t13dp`: WonderMaker's service files, nginx root and config paths are fixed to it.
- **Python 3.9** for Klipper: WonderMaker's compiled modules (`cs1237`, `hx711`, `heater_air_core`, `heater_feng`, `xy_offset_calibrator_core`, `heater_air`, `xy_offset_calibrator`, `tools_calibrate`, `echelon_stepper`, `custom_hall`) are built for it only. Moonraker uses the same version for simplicity.
- 64-bit ARM (the factory board is aarch64).
- Moonraker group `moonraker-admin`; user in `dialout` and `plugdev`.

## Checks before the first Klipper start

1. `scripts/board_check.sh`: USB id present, `can0` up.
2. Klipper stopped: the same script runs `canbus_query.py` and lists the CAN uuids it finds.
3. `canbus_uuid` in your config must match the main board that is installed now.
4. Compare against your old working config (saved in `~/wm-rpi-backup/` if the installer replaced folders).

## Not covered

Touchscreen replacement, webcams (the nginx routes for four mjpg-streamer cameras are included but no camera service is installed), firmware flashing of any board.

## Screen board display and touch (from photos of the panel's back)

- Touch controller: **Goodix GT911** on a 6-pin flex (1 VDD, 2 SCL, 3 SDA, 4 RST, 5 INT, 6 GND), flex marked `YZ-GG500890`. It is an **I2C** touch panel (not USB), driven by the board's own kernel (`goodix` driver).
- LCD flex marked `INANBO-T50CRCBHi-V12`: a 5.0 inch module, so ZR Tools uses the compact size.
- The display and touch are wired to the screen board (WM-ZR-M), so they only work when that board runs KlipperScreen itself. They cannot be plugged into a Raspberry Pi as a USB screen.

### What the factory screen board runs (read from the factory image, not from a live board)

| Item | Finding |
|---|---|
| OS | Debian 11 (bullseye) aarch64, Python 3.9.2, image `KLP_IMG_WM_ZRU_V1.0.26` |
| Screen app | `makerbase-client` (service) runs `~/TM_T1/bin/client`, an LVGL program that draws straight to `/dev/fb0` and reads the touch from `/dev/input/event0`. It links no GTK/Qt, and no X server or display manager is enabled |
| Kernel | Rockchip RK3308B kernel in the `boot` partition (Android boot image). Device tree: Goodix GT911 at I2C 0x5d, touch area 800x480; simple RGB panel, native 800x480 (also 1024x600 and 480x272 timings), PWM backlight |
| X11 | `xserver-xorg-core`, `-input-libinput`, `-input-evdev`, `-video-fbdev` installed; `/etc/X11/xorg.conf.d/20-modesetting.conf` (Rockchip modesetting, glamor) exists. No GTK, PyGObject or libmpv; `gcc` and `make` are present |
| Services enabled | klipper, moonraker, nginx, crowsnest, janus, hostapd, klipper-mcu, makerbase-client, makerbase-webcam, makerbase-wlan0, makerbase-mac, makerbase-net-mods, makerbase-exfat, ssh, networking |
| apt | `/etc/apt/sources.list` points to archive.debian.org (bullseye is archived); `Check-Valid-Until`/`Check-Date` are off |

Not verified (needs the live board): whether apt reaches the archive from it, whether X11 starts on this kernel, free disk and RAM.

### Result of the live check on the screen board (Nov 3, 2026)

- The board (Debian 11, kernel 5.10.160) has **no virtual console**: no `/dev/tty0`, no `/sys/class/vtconsole`, the only console is the serial `ttyFIQ0`.
- Live X test (reversible): X starts and stays up at 800x480 (modesetting with `AccelMethod none`, and fbdev) when run with `-seat seat1 -novtswitch -sharevts` after `loginctl attach seat1` for `card0` and `fb0`, a udev rule putting the Goodix touchscreen on `seat1`, and `xkb-data` reinstalled (the image has `/usr/share/X11` removed). A fake `/dev/tty0` does not work (VT ioctls fail). udev tags the touchscreen as "Keyboard Touchscreen"; touch events through X are not yet verified.
- WonderMaker's X server (1.20.11) starts, loads the `modesetting`/`fbdev` drivers, then stops with `Fatal server error: parse_vt_settings: Cannot open /dev/tty0`. The flags `-novtswitch -sharevts -keeptty` do not help. So stock KlipperScreen (GTK on X11) cannot run on this board without a workaround.
- Everything else checked fine: 800x480 framebuffer, Goodix touch, apt (archive.debian.org), GitHub/PyPI access. RAM is 487 MB with no swap (the installer adds a temporary swap file).
