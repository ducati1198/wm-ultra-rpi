# Changelog

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
