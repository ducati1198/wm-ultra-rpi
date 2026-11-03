# Wiring the main board to the Raspberry Pi

> Use at your own risk. Photos of the real board are still to come; until then these are the steps and what to check. Do not trust a connector position from a drawing: compare with your board and the WonderMaker manual.

![Wiring](img/wiring.svg)

## Steps

1. **Power off** the printer and unplug the Pi.
2. Leave the **CAN cable to the toolhead hub** on the main board as it is. It is the same bus the old board used.
3. Connect a **USB cable from the Pi to the main board**. This is the Klipper USB-CAN bridge. Use a Pi USB port; a USB 3 (blue) port is fine.
4. Give the Pi its **own 5 V supply**. Do not power the Pi from the printer through the USB cable.
5. Power the printer first, then the Pi. On the Pi run `scripts/board_check.sh`:
   - `1d50:606f` must appear in `lsusb`;
   - `can0` must exist and be up at 1 Mbit.
6. With Klipper still stopped, the script queries the CAN bus and shows the `canbus_uuid` values. Put the main board's uuid in `wm_zru_mcu.cfg` (copy the file first).

## Checks if it does not show up

| Symptom | Check |
|---|---|
| No `1d50:606f` | different cable (data, not charge-only), other Pi port, main board powered? |
| `can0` missing or down | udev rule installed (`ls /etc/udev/rules.d/99-wm-can0.rules`), unplug and replug the board |
| Bus query lists nothing | CAN cable to the hub, hub powered, CAN termination as on the original wiring |

## Photos

Photos with labels for: the main board USB port, the CAN connector, the Pi USB port, and the whole chain, will be added in `docs/img/`.
