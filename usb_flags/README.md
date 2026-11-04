# USB flag files (rescue by USB stick)

Put ONE of these empty files in the top folder of a USB stick (FAT32/ext4/exFAT), plug it into the screen board and reboot it.

| File | What the board does |
|---|---|
| `WM-RESCUE` | opens the rescue window |
| `WM-FACTORY` | does a factory restore (removes KlipperScreen, turns the factory app back on, reboots; the screen is black for about 5 minutes) |

Do not put both on one stick: `WM-FACTORY` wins and the factory restore runs.
`wm-rescue-flag.zip` and `wm-factory-flag.zip` each hold exactly one file. You can also just create an empty file with that exact name.

After use the file is renamed to `.done` and a report `WM-RESCUE-LOG.txt` is written to the stick.
Not tested on hardware (the test board's USB port did not detect any stick).
