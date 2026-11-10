# Klipper host MCU (the Klipper-Mcu service)

The installer builds Klipper's **Linux host MCU** and installs it as the service `klipper-mcu`. It shows in Fluidd's Services list as **Klipper-Mcu**.

## What it is

A small Klipper program that runs on the Pi itself and acts like one more microcontroller. Klipper uses it for parts wired **directly to the Pi's pins**: an ADXL345 accelerometer on the SPI pins (input shaping), or a GPIO pin for a relay or LED. It does **not** reset or control your printer's real boards (main board and CAN toolboards). `FIRMWARE_RESTART` is what resets those.

You do not need it for the printer to work. It sits idle until `printer.cfg` has an `[mcu host]` section.

## How it is installed

- WonderMaker's `~/klipper` has no MCU source folder, so the installer clones the official Klipper source (pinned in `config/pins/addons.txt`, line `klipper-upstream`) into `~/klipper-host-mcu`.
- It builds it for the Linux process target, installs the program as `/usr/local/bin/klipper_mcu` and the service file as `/etc/systemd/system/klipper-mcu.service`, enables the service and starts it.
- `moonraker.asvc` already lists `klipper_mcu`, so Moonraker may restart it from Fluidd.
- Nothing in `printer.cfg` changes. If the build fails the installer only warns; Klipper is not affected.
- Update (`./installer.sh --update`) installs it on a Pi that does not have it yet. Uninstall stops and disables it.

## Using it

Add this to `printer.cfg` (the socket `/tmp/klipper_host_mcu` is the service's):

```
[mcu host]
serial: /tmp/klipper_host_mcu
```

Klipper then refuses to start while the `klipper-mcu` service is not running, so only add it when you need it. Example, ADXL345 on the Pi's SPI bus (check your wiring against Klipper's page "Measuring Resonances"):

```
[adxl345]
cs_pin: host:None
spi_bus: spidev0.3

[resonance_tester]
accel_chip: adxl345
probe_points: 150, 150, 20
```

SPI must be enabled on the Pi first (`sudo raspi-config`, Interface Options, SPI). Official guide: https://www.klipper3d.org/RPi_microcontroller.html
