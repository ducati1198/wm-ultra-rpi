# Klipper host MCU (the Klipper-Mcu service)

The installer builds Klipper's **Linux host MCU** and installs it as the service `klipper-mcu`. It shows in Fluidd's Services list as **Klipper-Mcu**, and Klipper connects to it as `[mcu rpi]`.

## What it is

A small Klipper program that runs on the Pi itself and acts like one more microcontroller. Klipper uses it for parts wired **directly to the Pi's pins**: an ADXL345 accelerometer on the SPI pins (input shaping), or a GPIO pin for a relay or LED. It does **not** reset or control your printer's real boards (main board and CAN toolboards). `FIRMWARE_RESTART` is what resets those.

## What the installer does

1. **Builds and installs it** (step 7b). WonderMaker's `~/klipper` has no MCU source folder, so the installer clones the official Klipper source (pinned in `config/pins/addons.txt`, line `klipper-upstream`) into `~/klipper-host-mcu`, builds it for the Linux process target, installs `/usr/local/bin/klipper_mcu` and `/etc/systemd/system/klipper-mcu.service`, and enables and starts the service.
2. **Adds the user to the `tty` group** (step 2). The host MCU runs as root and its socket `/tmp/klipper_host_mcu` belongs to group `tty`; without that group Klipper gets "Permission denied" and `[mcu rpi]` fails. Klipper must be restarted once after the group is added (the next step does that).
3. **Connects Klipper to it, after Klipper is running.** At the end of an install or update, and with `./installer.sh --pi-sensors`, the installer writes `~/printer_data/config/wm_rpi_mcu.cfg`:

   ```
   [mcu rpi]
   serial: /tmp/klipper_host_mcu
   ```

   includes it from `printer.cfg` (after the other includes, above the `SAVE_CONFIG` block), saves a copy of `printer.cfg` (`printer.cfg.wm-before-wm_rpi_mcu-<time>`) and restarts Klipper. **If Klipper does not come back to "ready", the include line and the file are taken out again, the old `printer.cfg` is restored and Klipper is restarted once more.** The refused file is kept as `wm_rpi_mcu.cfg.wm-failed-<time>`, and the reason is in `~/printer_data/logs/klippy.log`.

   It is not added while a print is running, while Klipper is stopped, or when the `klipper-mcu` service is not running.

The same step also adds the chip temperature of every printer board (see below). Both are skipped, never forced, when something is not ready, and `./installer.sh --pi-sensors` can be run again at any time.

## Temperatures it adds

- `wm_pi.cfg` (installed with the other Pi config files): `[temperature_sensor raspberry_pi]`, the Pi's own CPU temperature (`temperature_host`, limit 85 C). It does not need the host MCU.
- `wm_mcu_temps.cfg` (written by the `--pi-sensors` step, one section for every `[mcu]` board found in your config): `mcu_main`, `mcu_hub`, `mcu_extruder`, `mcu_t0` .. `mcu_t3`, `mcu_loadcell`. They read the processor chip of each board (`temperature_mcu`), so they are a few degrees above the air around the board. The range is -20 to 110 C on purpose: outside it Klipper stops the printer, and a wide range keeps a cold room or one bad reading from doing that.

## Using it for your own parts

With `[mcu rpi]` in use you can write pins as `rpi:gpio4`. Example, an ADXL345 on the Pi's SPI bus (check your wiring against Klipper's page "Measuring Resonances"):

```
[adxl345]
cs_pin: rpi:None
spi_bus: spidev0.3

[resonance_tester]
accel_chip: adxl345
probe_points: 150, 150, 20
```

SPI must be enabled on the Pi first (`sudo raspi-config`, Interface Options, SPI). The Pi 5 has its GPIO pins on a different chip (`gpiochip4`); check Klipper's page for the pin names on your model. Official guide: https://www.klipper3d.org/RPi_microcontroller.html

## If something goes wrong

- Fluidd shows "mcu 'rpi': Unable to connect": run `./installer.sh --doctor`. It checks that the `klipper-mcu` service is running and that your user is in the `tty` group, and offers a fix for each.
- To go back to how it was: remove `[include wm_rpi_mcu.cfg]` and `[include wm_mcu_temps.cfg]` from `printer.cfg` (or restore one of the `printer.cfg.wm-before-...` copies) and restart Klipper. The service can stay installed; it does nothing on its own.
