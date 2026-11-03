# Wiring the main board to the Raspberry Pi

> Use at your own risk. This is a **custom cable** and one wrong wire (24 V into the Pi's USB port) can destroy the Pi. Read the whole page first, measure before you plug in.

Board: **WM-ZR-D V1.2** (photos below). The Pi connects to the **red 4-pin connector** next to the reset button. It is the Klipper USB connection of the main board (it shows up on the Pi as USB device `1d50:606f`).

![The main board](img/wiring-photo-board.jpg)

## The connector

The four pins are printed on the board, top to bottom in the photo:

![Red connector pinout](img/wiring-photo-connector.jpg)

| Board pin | What it is | Goes to the Pi's USB-A plug |
|---|---|---|
| **DM** | USB data minus (D-) | pin 2, white wire |
| **DP** | USB data plus (D+) | pin 3, green wire |
| **G** | ground | pin 4, black wire |
| **VIN** | **24 V** supply | **nothing. Do not connect.** Cut the wire off or leave the pin empty and insulate it |

The red wire of a USB cable (5 V, pin 1) is **not used** either: the Pi has its own power supply, and the main board gets its power from the printer.

## Making the cable

1. Take a USB-A **male** cable (a cut USB cable works) and a **matching 4-pin plug** for the red connector (it looks like a JST-XH type, 2.5 mm pitch: compare with the connector, or ask WonderMaker for the exact part).
2. Wire **DM to white, DP to green, G to black**. Cut off and insulate red (5 V) at the USB side and VIN at the board side.
3. Put the plug in the right way round: the plug is keyed; the pin order must match the table above (DM at the top in the photo).
4. Keep the cable short and away from the heater and motor wires.

![Wiring overview](img/wiring.svg)

## Before the first power-up

1. With the printer on and **nothing connected** to the red connector, measure with a multimeter: **VIN to G should read about 24 V**. This confirms which pin is which.
2. Also confirm **DM and DP read about 0 to 3.3 V, never 24 V**.
3. Plug the cable into the main board only, then the Pi's USB-A. Power the printer first, then the Pi (own 5 V supply).
4. On the Pi: `scripts/board_check.sh`. `1d50:606f` must appear in `lsusb`, and `can0` must come up.

## If it does not show up

| Symptom | Check |
|---|---|
| No `1d50:606f` | D+ and D- swapped (DM and DP), a bad crimp, G not connected, main board not powered |
| `can0` missing or down | udev rule installed (`ls /etc/udev/rules.d/99-wm-can0.rules`), unplug and replug the cable |
| Bus query lists nothing | CAN cable to the hub, hub powered |

## What stays as it is

The CAN cable to the toolhead hub, the motors, heaters and everything else on the main board stay exactly as they were on the printer. Only the old board's cable is replaced by this one.
